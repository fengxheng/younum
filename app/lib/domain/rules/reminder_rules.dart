/// 每月整理提醒的时间推算。
///
/// 指南 8.2 里几条容易做错的规则集中在这里：
///
/// * **按日历推算，不能把「每月」实现成固定 30 天**；
/// * 日期允许选 29/30/31：短月顺延到**当月最后一天**，不能默默跳过这个月；
/// * 时区口径与账目一致（`Asia/Shanghai`），否则「月初提醒」会在跨时区旅行时
///   提醒到错误的月份；
/// * 提醒关掉之后就不该再有「下次提醒」这种说法，[nextRun] 返回 null。
///
/// 全部是纯函数：真机上那套调度与这里读的是同一份推算结果。
library;

import '../../core/preferences/reminder_store.dart';
import '../../core/time/statistics_time.dart';

abstract final class ReminderRules {
  /// 允许选择的日期范围。29/30/31 都在里面 —— 短月按当月最后一天处理。
  static const int minDay = 1;
  static const int maxDay = 31;

  /// 默认：关着、每月 1 日 20:00。
  ///
  /// 月初提醒上一个月的账，最贴近「一月一次」的节奏。
  static const ReminderSettings defaults = ReminderSettings(
    enabled: false,
    day: 1,
    hour: 20,
    minute: 0,
  );

  /// 「每月第 [day] 日」在 [year] 年 [month] 月实际落在哪一天。
  ///
  /// 31 日在 2 月 → 28（闰年 29）日。顺延到月末，而不是跳过这个月。
  static int effectiveDay(int year, int month, int day) {
    // DateTime(年, 月 + 1, 0) 就是「下个月的第 0 天」= 当月最后一天。
    final lastDay = DateTime(year, month + 1, 0).day;
    final wanted = day < minDay ? minDay : (day > maxDay ? maxDay : day);
    return wanted > lastDay ? lastDay : wanted;
  }

  /// 下一次提醒时间。关闭时返回 null。
  static DateTime? nextRun(ReminderSettings settings, {required DateTime now}) {
    if (!settings.enabled) return null;
    final hour = settings.hour.clamp(0, 23);
    final minute = settings.minute.clamp(0, 59);

    final thisMonthDay = effectiveDay(now.year, now.month, settings.day);
    final candidate = DateTime(
      now.year,
      now.month,
      thisMonthDay,
      hour,
      minute,
    );
    if (candidate.isAfter(now)) return candidate;

    final nextMonth = now.month == 12 ? 1 : now.month + 1;
    final nextYear = now.month == 12 ? now.year + 1 : now.year;
    return DateTime(
      nextYear,
      nextMonth,
      effectiveDay(nextYear, nextMonth, settings.day),
      hour,
      minute,
    );
  }

  /// 「11 月 1 日 20:00」。
  static String describe(DateTime next) =>
      '${next.month} 月 ${next.day} 日 ${_two(next.hour)}:${_two(next.minute)}';

  /// 「今天 / 明天 / 约 N 天后」。
  ///
  /// 只按**日期**算差，不算小时 —— 用户关心的是「哪一天」。
  static String remainingLabel(DateTime next, {required DateTime now}) {
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(next.year, next.month, next.day);
    final days = target.difference(today).inDays;
    if (days <= 0) return '今天';
    if (days == 1) return '明天';
    return '约 $days 天后';
  }

  /// 提醒时间的时区口径。与账目一致，不读设备当前时区（指南 3.1）。
  static String get timeZone => StatisticsTime.timeZone;

  static String _two(int value) => value.toString().padLeft(2, '0');
}
