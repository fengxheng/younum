package com.younum.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.util.Calendar
import java.util.TimeZone
import java.util.concurrent.TimeUnit

/**
 * 每月整理提醒。
 *
 * 为什么用 WorkManager 而不是精确闹钟：这是「提醒你整理账单」，不是日历事件。
 * 系统省电造成的合理延迟可以接受，换来的是**不必申请精确闹钟权限**（指南 8.2）。
 * 通知文案用「约」，与这个取舍一致。
 *
 * 调度方式：一次性任务，跑完自己排下一次；唯一任务名 + REPLACE，所以用户改时间
 * 或关掉提醒都不会留下重复任务。
 *
 * ⚠️ 这里的「每月第几天的下一次」与 Dart 侧 `ReminderRules.nextRun` 是同一套
 * 规则的两份实现：界面上的说明文字用 Dart 那份（有单元测试），任务自己续期只能
 * 用 Kotlin 这份。改规则时**两处都要改** —— 这也是为什么两边都把短月顺延
 * 写得很显眼。
 */
class ReminderWorker(context: Context, params: WorkerParameters) : Worker(context, params) {

    override fun doWork(): Result {
        val day = inputData.getInt(KEY_DAY, DEFAULT_DAY)
        val hour = inputData.getInt(KEY_HOUR, DEFAULT_HOUR)
        val minute = inputData.getInt(KEY_MINUTE, DEFAULT_MINUTE)

        // 到点、且这个月还没提醒过才发。晚几天醒过来（省电策略）也照样发 ——
        // 提醒迟到几天仍有意义，直接跳过反而像丢了提醒。
        if (isDueNow(day, hour, minute) && !alreadyNotifiedThisMonth()) {
            notifyUser()
            markNotified()
        }

        // 无论这次发没发，都排下一次。
        scheduleNext(applicationContext, day, hour, minute)
        return Result.success()
    }

    /** 现在是不是已经过了本月的提醒时刻。 */
    private fun isDueNow(day: Int, hour: Int, minute: Int): Boolean {
        val now = nowInZone()
        val lastDay = now.getActualMaximum(Calendar.DAY_OF_MONTH)
        val effectiveDay = minOf(day, lastDay)
        val nowMinutes = now.get(Calendar.HOUR_OF_DAY) * 60 + now.get(Calendar.MINUTE)
        return now.get(Calendar.DAY_OF_MONTH) >= effectiveDay &&
            nowMinutes >= hour * 60 + minute
    }

    /** 同一个自然月里只提醒一次。 */
    private fun alreadyNotifiedThisMonth(): Boolean {
        val now = nowInZone()
        val key = "${now.get(Calendar.YEAR)}-${now.get(Calendar.MONTH)}"
        return prefs().getString(KEY_LAST_NOTIFIED, null) == key
    }

    private fun markNotified() {
        val now = nowInZone()
        prefs()
            .edit()
            .putString(KEY_LAST_NOTIFIED, "${now.get(Calendar.YEAR)}-${now.get(Calendar.MONTH)}")
            .apply()
    }

    private fun notifyUser() {
        ensureChannel(applicationContext)

        val intent = Intent(applicationContext, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pending = PendingIntent.getActivity(
            applicationContext,
            REQUEST_OPEN,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_menu_agenda)
            .setContentTitle("该整理上个月的账单了")
            .setContentText("花几分钟分个类，月报才是准的。")
            .setContentIntent(pending)
            .setAutoCancel(true)
            .build()

        try {
            NotificationManagerCompat.from(applicationContext)
                .notify(NOTIFICATION_ID, notification)
        } catch (error: SecurityException) {
            // 用户没给通知权限（或后来在系统设置里关了）：什么都不做，
            // 设置页会如实显示「系统里没有允许通知」。
        }
    }

    private fun nowInZone(): Calendar =
        Calendar.getInstance(TimeZone.getTimeZone(ZONE))

    private fun prefs(): SharedPreferences =
        applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    companion object {
        const val CHANNEL_ID = "younum_reminder"
        const val CHANNEL_NAME = "每月整理提醒"
        const val WORK_NAME = "younum_reminder"
        const val KEY_DAY = "day"
        const val KEY_HOUR = "hour"
        const val KEY_MINUTE = "minute"
        const val DEFAULT_DAY = 1
        const val DEFAULT_HOUR = 20
        const val DEFAULT_MINUTE = 0

        private const val PREFS = "younum_reminder"
        private const val KEY_LAST_NOTIFIED = "lastNotifiedMonth"
        private const val NOTIFICATION_ID = 0x594E
        private const val REQUEST_OPEN = 0x594E

        /** 提醒时间按账目那套时区口径解读（指南 3.1 / 8.2）。 */
        const val ZONE = "Asia/Shanghai"

        /** 建通知渠道。渠道重复建不会报错，系统只保留第一次的配置。 */
        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_DEFAULT,
                ),
            )
        }

        /**
         * 排下一次提醒。改成新时间时用 REPLACE 覆盖旧任务，避免留下两个任务。
         */
        fun scheduleNext(context: Context, day: Int, hour: Int, minute: Int) {
            val delay = nextRunMillis(day, hour, minute) - System.currentTimeMillis()
            val request = OneTimeWorkRequestBuilder<ReminderWorker>()
                .setInitialDelay(if (delay > 0) delay else 0, TimeUnit.MILLISECONDS)
                .setInputData(
                    Data.Builder()
                        .putInt(KEY_DAY, day)
                        .putInt(KEY_HOUR, hour)
                        .putInt(KEY_MINUTE, minute)
                        .build(),
                )
                .build()

            WorkManager.getInstance(context).enqueueUniqueWork(
                WORK_NAME,
                ExistingWorkPolicy.REPLACE,
                request,
            )
        }

        /** 关掉提醒：取消任务并清掉「本月已提醒」的记录。 */
        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .remove(KEY_LAST_NOTIFIED)
                .apply()
        }

        /**
         * 「每月第 day 日的 hour:minute」下一次的毫秒时间戳（按 [ZONE] 时区）。
         *
         * 短月顺延到当月最后一天，与 Dart 侧 `ReminderRules.effectiveDay` 一致。
         */
        fun nextRunMillis(
            day: Int,
            hour: Int,
            minute: Int,
            fromMs: Long = System.currentTimeMillis(),
        ): Long {
            val zone = TimeZone.getTimeZone(ZONE)
            val now = Calendar.getInstance(zone).apply { timeInMillis = fromMs }

            fun candidate(year: Int, monthIndex: Int): Long {
                val calendar = Calendar.getInstance(zone)
                calendar.set(Calendar.YEAR, year)
                calendar.set(Calendar.MONTH, monthIndex)
                calendar.set(Calendar.DAY_OF_MONTH, 1)
                val lastDay = calendar.getActualMaximum(Calendar.DAY_OF_MONTH)
                calendar.set(Calendar.DAY_OF_MONTH, minOf(day, lastDay))
                calendar.set(Calendar.HOUR_OF_DAY, hour)
                calendar.set(Calendar.MINUTE, minute)
                calendar.set(Calendar.SECOND, 0)
                calendar.set(Calendar.MILLISECOND, 0)
                return calendar.timeInMillis
            }

            val thisMonth = candidate(now.get(Calendar.YEAR), now.get(Calendar.MONTH))
            if (thisMonth > fromMs) return thisMonth
            val shifted = Calendar.getInstance(zone).apply {
                timeInMillis = thisMonth
                add(Calendar.MONTH, 1)
            }
            return candidate(shifted.get(Calendar.YEAR), shifted.get(Calendar.MONTH))
        }
    }
}
