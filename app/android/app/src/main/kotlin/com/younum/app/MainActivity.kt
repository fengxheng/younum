package com.younum.app

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.FileProvider
import androidx.work.WorkInfo
import androidx.work.WorkManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/**
 * 单 Activity 入口，带一个「选择账单文件」的平台通道。
 *
 * 为什么手写 Kotlin 而不是引第三方文件选择插件：这个工程只用得上一个能力
 * （读用户选的文件），多引一个插件就多一份需要跟着 Flutter/AGP 升级维护的
 * 原生代码。本机 Android 工具链本来就很脆（见
 * docs/IMPLEMENTATION_STATUS.md 的「环境遗留问题」），不值得。
 *
 * 实现要点来自实现指南 4.2：
 *
 * * 用**系统文件选择器**（`ACTION_OPEN_DOCUMENT`），拿到的是 `content://` URI，
 *   不尝试把它转成真实磁盘路径；
 * * **不申请全盘文件访问权限**，只用系统授权的那一个 URI；
 * * `takePersistableUriPermission` 把读取授权持久化，这样进程被杀之后
 *   「导入历史」里还能重新读这份文件；用户丢弃批次时再释放它；
 * * 文件 I/O 放到**后台线程**，不阻塞 UI；
 * * 大文件在读之前就按 provider 报的大小挡掉，不去读一遍再判断。
 *
 * MIME 用了通配：很多文件管理器会把 CSV 报成 `text/plain` 或
 * `application/octet-stream`，写死类型会让用户在列表里根本选不到自己的文件。
 * 内容是否真的是账单，交给 Dart 侧按**后缀 + 内容**联合判断（指南 4.2.3）。
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "YounumFiles"
        private const val CHANNEL = "com.younum.app/files"

        /** 单个账单文件的上限。真实的年度账单通常不到 1MB。 */
        private const val MAX_BYTES = 64L * 1024L * 1024L

        /**
         * 请求码。刻意用一个不常见的值：`onActivityResult` 是所有请求共用的
         * 一个回调，插件也会走它，所以不能随便拿 1 这种小数字。
         */
        private const val REQUEST_PICK_DOCUMENT = 0x594E // "YN"

        /** 导出文件用的请求码（与选择文件分开，否则分不清回来的是哪个）。 */
        private const val REQUEST_SAVE_DOCUMENT = 0x594F

        /** 申请通知权限用的请求码（同上的理由，单独一个）。 */
        private const val REQUEST_NOTIFICATION_PERMISSION = 0x5950

        /** 旧系统（Android 9 及以下）写相册要的存储权限。 */
        private const val REQUEST_GALLERY_PERMISSION = 0x5951

        /**
         * 在线升级单独一条通道。
         *
         * 这是全应用**唯一**会联网的地方：只向 GitHub 要一个公开的版本号，
         * 再（经用户同意后）下载安装包。账单数据一个字节都不发出去。
         */
        private const val UPDATE_CHANNEL = "com.younum.app/update"

        /** 安装包存在应用私有缓存里，不占用户的可见空间。 */
        private const val UPDATE_DIR = "updates"

        /** 下载缓冲区大小。8KB 是 HttpURLConnection 的常用值。 */
        private const val DOWNLOAD_BUFFER = 8 * 1024

        /**
         * 数据库口令（加密用）。单独一条通道。
         *
         * ⚠️ 这条通道回的是**口令本身**，因此它不出现在日志里、
         * 也不做任何持久化 —— 只交给 Dart 侧去开库。
         */
        private const val SECURITY_CHANNEL = "com.younum.app/security"

        /** 每月提醒的通道名。与文件通道分开：两件事互不相干。 */
        private const val REMINDER_CHANNEL = "com.younum.app/reminder"

        /** 存到相册时的子目录：Pictures/有数。 */
        private const val GALLERY_FOLDER = "有数"
    }

    /** 同一时刻只允许一个选择请求。 */
    private var pendingPick: MethodChannel.Result? = null

    /**
     * 等保存结果的请求。
     *
     * 字节拿在内存里等用户选位置 —— 导出物最大也就是一两张海报，
     * 不先写临时文件，也就没有「取消后要清理的残片」。
     */
    private var pendingSave: PendingSave? = null

    private class PendingSave(
        val result: MethodChannel.Result,
        val bytes: ByteArray,
        val name: String,
    )

    /** 等通知权限结果的请求。 */
    private var pendingPermission: MethodChannel.Result? = null

    /** 等存储权限、拿到就写相册的请求（仅旧系统用得上）。 */
    private var pendingGallerySave: PendingGallerySave? = null

    /**
     * 通知带过来的路由提示。
     *
     * 冷启动从 [configureFlutterEngine] 里的 intent 取，热启动（应用已经在跑）
     * 从 [onNewIntent] 取 —— 两条路都要照顾到，否则「点通知没反应」会时有时无。
     */
    private var pendingRoute: String? = null

    /**
     * 从系统「分享 / 用其他应用打开」进来、还没被 Dart 取走的那个文件。
     *
     * 不在这里读字节：读文件是 IO，要放在 [fileExecutor] 上，而且只有 Dart
     * 真的来要的时候才读 —— 用户可能根本没想把它导进来。
     *
     * 取走即清（见 `consumeSharedFile`）：不清的话每次回到前台都会重导一遍。
     */
    private var pendingSharedUri: Uri? = null

    private class PendingGallerySave(
        val result: MethodChannel.Result,
        val bytes: ByteArray,
        val name: String,
    )

    /** 文件读写一律在这个线程上做，不占 UI 线程。 */
    private val fileExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 冷启动：如果这次启动是点通知进来的，先把路由记下来等价 Dart 来取。
        pendingRoute = intent?.getStringExtra(ReminderWorker.EXTRA_ROUTE)
        // 冷启动：也可能是「分享一份账单到有数」。
        captureShared(intent)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickDocument" -> handlePick(result, call.argument<String>("mimeType"))

                    // 导出：把生成好的字节交给系统「创建文档」流程，由用户选位置。
                    // 不先写临时文件、也不把应用私有路径告诉系统（指南 8.1）。
                    "saveDocument" -> handleSave(
                        result,
                        call.argument<String>("fileName"),
                        call.argument<String>("mimeType"),
                        call.argument<ByteArray>("bytes"),
                    )

                    // 图片直接进相册：月报回顾是拿来分享的图，让用户再跳一次
                    // 系统「保存到哪儿」没有意义，直接放进 Pictures/有数。
                    "saveImageToGallery" -> handleSaveImageToGallery(
                        result,
                        call.argument<String>("fileName"),
                        call.argument<ByteArray>("bytes"),
                    )

                    // 应用私有目录。分类图片要落在自己拥有的目录里
                    // （指南 14.4.2：不能长期依赖选择器给的临时 URI）。
                    "filesDir" -> result.success(filesDir.absolutePath)

                    "readDocument" -> {
                        val uri = call.argument<String>("uri")
                        if (uri == null) {
                            result.error("bad_arguments", "缺少 uri", null)
                        } else {
                            readInto(result, Uri.parse(uri))
                        }
                    }

                    // 系统分享进来的那份文件。**没有就回 null**（不是错误）：
                    // 启动与每次回到前台都会问一次，绝大多数时候答案就是「没有」。
                    "consumeSharedFile" -> {
                        val uri = pendingSharedUri
                        pendingSharedUri = null
                        if (uri == null) {
                            result.success(null)
                        } else {
                            // 与「选文件」走同一段读取代码：大小上限、持久化授权、
                            // 错误码的语义两边必须一致，不能有两个脾气不同的读取器。
                            readInto(result, uri)
                        }
                    }

                    "releaseDocument" -> {
                        val uri = call.argument<String>("uri")
                        if (uri == null) {
                            result.error("bad_arguments", "缺少 uri", null)
                        } else {
                            fileExecutor.execute {
                                try {
                                    contentResolver.releasePersistableUriPermission(
                                        Uri.parse(uri),
                                        Intent.FLAG_GRANT_READ_URI_PERMISSION,
                                    )
                                } catch (error: Exception) {
                                    // 没授权过就没什么可释放的，不算失败。
                                    Log.d(TAG, "release 失败（可能本来就没授权）：${error.message}")
                                }
                                runOnUiThread { result.success(null) }
                            }
                        }
                    }

                    // 给界面判断要不要启用「选择文件」按钮，
                    // 也方便真机测试断言这条通道确实活着。
                    "describe" -> result.success(
                        mapOf(
                            "supported" to true,
                            "maxBytes" to MAX_BYTES,
                            "pickerAvailable" to pickerAvailable(),
                            "saverAvailable" to saverAvailable(),
                            "busy" to (pendingPick != null),
                        ),
                    )

                    else -> result.notImplemented()
                }
            }

        // 每月整理提醒（指南 8.2）。与文件通道分开，两件事互不相干。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, REMINDER_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 如实上报**实际状态**：权限有没有、系统里通知开没开。
                    // 设置页拿它显示状态，而不是拿我们自己的开关骗自己。
                    "status" -> handleReminderStatus(result)

                    "requestPermission" -> handleNotificationPermission(result)

                    "schedule" -> {
                        val day = call.argument<Int>("day")
                        val hour = call.argument<Int>("hour")
                        val minute = call.argument<Int>("minute")
                        if (day == null || hour == null || minute == null) {
                            result.error("bad_arguments", "缺少提醒时间", null)
                        } else {
                            ReminderWorker.ensureChannel(this)
                            ReminderWorker.scheduleNext(this, day, hour, minute)
                            result.success(true)
                        }
                    }

                    "cancel" -> {
                        ReminderWorker.cancel(this)
                        result.success(true)
                    }

                    // Dart 侧在启动与回到前台时各问一次；取走即清，
                    // 免得到前台一次就多跳一次页面。
                    "consumeLaunchRoute" -> {
                        val route = pendingRoute
                        pendingRoute = null
                        result.success(route)
                    }

                    else -> result.notImplemented()
                }
            }

        // 在线升级。与提醒、文件通道都无关，单独一条。
        val updateChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATE_CHANNEL)
        updateChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                // 有没有「安装未知应用」的权限。没有的话下一步就会失败。
                "canInstall" -> result.success(canInstallPackages())

                // 当前安装的版本号。**从系统读**，不是从 pubspec 抄一份 ——
                // 抄过来的那份迟早会和真正装上的包对不上。
                "appVersion" -> result.success(appVersion())

                // 打开系统的「安装未知应用」设置页。这一下必须用户自己点。
                "openInstallSettings" -> result.success(openInstallSettings())

                "downloadAndInstall" ->
                    handleUpdateDownload(call, result, updateChannel)

                else -> result.notImplemented()
            }
        }

        // 数据库口令（加密）。与文件、提醒、升级都无关，单独一条。
        val keyStore = DatabaseKeyStore(filesDir)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SECURITY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 取数据库口令。第一次调用会生成并由 Keystore 包住。
                    // 取不出来时**报错而不是造一把新的** —— 后者会让用户在
                    // 毫无察觉的情况下看到空账本，那看起来就像账单被删了。
                    "databasePassphrase" -> {
                        try {
                            result.success(keyStore.getOrCreatePassphrase())
                        } catch (error: DatabaseKeyUnavailable) {
                            result.error("key_unavailable", error.message, null)
                        } catch (error: Exception) {
                            Log.d(TAG, "取数据库口令失败：${error.message}")
                            result.error("key_unavailable", "取不到数据库口令", null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 这台设备允不允许「有数」安装应用。
     *
     * Android 8 起这是**每应用**一个开关（「安装未知应用」），而且只能由用户
     * 在系统设置里打开 —— 应用不能替他点。所以这一条只是「能不能」，
     * 界面据此把话说在前面。
     */
    private fun canInstallPackages(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    /**
     * 当前安装的版本。
     *
     * `versionCode` 在 API 28 起换成 `longVersionCode`（旧字段对
     * 大版本号会截断）。两个字段都回，Dart 侧只用 versionCode。
     */
    private fun appVersion(): Map<String, Any?> = try {
        val info = packageManager.getPackageInfo(packageName, 0)
        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
        mapOf("versionName" to info.versionName, "versionCode" to code)
    } catch (error: Exception) {
        Log.d(TAG, "读不到版本号：${error.message}")
        mapOf("versionName" to null, "versionCode" to null)
    }

    /** 跳系统的「安装未知应用」页。取不到就退回应用详情页。 */
    private fun openInstallSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val direct = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:$packageName"),
        )
        val fallback = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.parse("package:$packageName"),
        )
        return startSettingIntent(direct) || startSettingIntent(fallback)
    }

    private fun startSettingIntent(intent: Intent): Boolean = try {
        startActivity(intent)
        true
    } catch (error: ActivityNotFoundException) {
        Log.d(TAG, "打不开设置页：${error.message}")
        false
    }

    /**
     * 下载安装包并交给**系统安装器**。
     *
     * 最后那一下「安装」必须用户自己点：我们不静默安装，也做不到。
     * 下载过程中通过同一条通道发 `progress`，让界面能显示进度 ——
     * 几十兆的东西转上一分钟而屏幕上什么都没动，用户会以为卡死了。
     */
    private fun handleUpdateDownload(
        call: MethodCall,
        result: MethodChannel.Result,
        channel: MethodChannel,
    ) {
        val url = call.argument<String>("url")
        val fileName = call.argument<String>("fileName") ?: "younum-update.apk"
        if (url.isNullOrBlank()) {
            result.error("bad_arguments", "缺少下载地址", null)
            return
        }
        if (!canInstallPackages()) {
            result.success("needPermission")
            return
        }

        fileExecutor.execute {
            try {
                val dir = File(cacheDir, UPDATE_DIR).apply { mkdirs() }
                // 文件名固定：同一次升级不会在缓存里留下一堆几十兆的残留。
                val apk = File(dir, fileName)

                downloadTo(url, apk) { percent ->
                    runOnUiThread { channel.invokeMethod("progress", percent) }
                }

                val uri = FileProvider.getUriForFile(
                    this,
                    "$packageName.fileprovider",
                    apk,
                )
                val install = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                if (install.resolveActivity(packageManager) == null) {
                    runOnUiThread {
                        result.success("failed:这台设备上没有能安装应用的界面")
                    }
                    return@execute
                }
                runOnUiThread {
                    try {
                        startActivity(install)
                        result.success("handedOff")
                    } catch (error: ActivityNotFoundException) {
                        result.success("failed:打不开系统安装界面：${error.message}")
                    }
                }
            } catch (error: Exception) {
                val reason = error.message ?: error.javaClass.simpleName
                runOnUiThread { result.success("failed:下载没有完成：$reason") }
            }
        }
    }

    /** 下载到 [target]，边下边报百分比（内容长度未知时不报）。 */
    private fun downloadTo(
        url: String,
        target: File,
        onProgress: (Int) -> Unit,
    ) {
        var connection: HttpURLConnection? = null
        try {
            connection = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 15_000
                readTimeout = 30_000
                // GitHub 的资源地址会 302 到 CDN，必须跟随。
                instanceFollowRedirects = true
                setRequestProperty("User-Agent", "younum-app")
            }
            val code = connection.responseCode
            if (code != HttpURLConnection.HTTP_OK) {
                throw IOException("服务器返回 $code")
            }
            val total = connection.contentLengthLong
            connection.inputStream.use { input ->
                target.outputStream().use { output ->
                    val buffer = ByteArray(DOWNLOAD_BUFFER)
                    var written = 0L
                    var lastPercent = -1
                    while (true) {
                        val read = input.read(buffer)
                        if (read <= 0) break
                        output.write(buffer, 0, read)
                        written += read
                        if (total > 0) {
                            val percent = ((written * 100) / total).toInt()
                            if (percent != lastPercent) {
                                lastPercent = percent
                                onProgress(percent)
                            }
                        }
                    }
                    output.flush()
                }
            }
        } finally {
            connection?.disconnect()
        }
    }

    /** 应用已经在跑时点通知：路由从新的 intent 里取。 */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val route = intent.getStringExtra(ReminderWorker.EXTRA_ROUTE)
        if (!route.isNullOrBlank()) pendingRoute = route
        // 应用已经在跑时被分享：同样要接住，否则「分享过来没反应」。
        captureShared(intent)
    }

    /**
     * 这个应用不用深链，路由完全由自己接（通知的 extras、分享的文件）。
     *
     * ⚠️ 必须显式关掉：Flutter 已默认开启 deep linking，而「用有数打开一份账单」
     * 是 `ACTION_VIEW` + `content://` 的 intent —— 引擎会把它当成深链推进
     * 路由表，于是用户先看到一个「未知路由 /document/1234」的页面，
     * 真正的导入反而要自己再找一遍。
     */
    override fun shouldHandleDeeplinking(): Boolean = false

    /**
     * 把「分享 / 用其他应用打开」的 intent 里的文件记下来。
     *
     * 只认 [Intent.ACTION_SEND] 与 [Intent.ACTION_VIEW]：启动器的 `ACTION_MAIN`
     * 会带上别的 data，不能一看到 data 就当文件。
     *
     * MIME 在这里**不判真伪**：清单里已经声明了 CSV / XLS / XLSX 的几种子类型，
     * 但很多发送方（尤其是微信）只会报 `application/octet-stream`，写死就会让
     * 用户在分享列表里根本看不到有数。内容是不是账单，交给 Dart 侧按**内容**
     * 判断（指南 4.2.3：不能仅依据后缀或 MIME 就信任文件）。
     */
    private fun captureShared(intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_VIEW) return
        val uri = sharedUriOf(intent) ?: return
        val scheme = uri.scheme
        if (scheme != "content" && scheme != "file") return
        pendingSharedUri = uri
    }

    /**
     * 从各种发送方的写法里把文件 URI 取出来。
     *
     * 三种都真实存在：文件管理器里「用其他应用打开」走 `data`，标准的
     * 分享走 `EXTRA_STREAM`，部分应用（包括一些国产 IM）只往 `ClipData` 里放。
     */
    private fun sharedUriOf(intent: Intent): Uri? {
        intent.data?.let { return it }
        // Android 13 起 getParcelableExtra(String) 已弃用，但 FlutterActivity 的
        // API 面下这是可用且最小的做法（与 onActivityResult 同一个理由）。
        //
        // ⚠️ 类型参数必须写出来：这个重载的返回类型是平台类型 `T!`，
        // 光靠 `is Uri` 推不出 `T`，Kotlin 会直接编译不过（release 构建时才炸）。
        @Suppress("DEPRECATION")
        val stream = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        if (stream != null) return stream
        val clip = intent.clipData
        if (clip != null && clip.itemCount > 0) return clip.getItemAt(0).uri
        return null
    }

    private fun handleReminderStatus(result: MethodChannel.Result) {
        // WorkManager 的查询是阻塞式 Future，不能在主线程上等 —— 放到后台线程查完
        // 再回 UI 线程回复。
        fileExecutor.execute {
            val permissionGranted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                    PackageManager.PERMISSION_GRANTED
            } else {
                true
            }
            val notificationsEnabled =
                NotificationManagerCompat.from(this).areNotificationsEnabled()

            val scheduled = try {
                WorkManager.getInstance(this)
                    .getWorkInfosForUniqueWork(ReminderWorker.WORK_NAME)
                    .get()
                    .any { info: WorkInfo ->
                        info.state == WorkInfo.State.ENQUEUED || info.state == WorkInfo.State.RUNNING
                    }
            } catch (error: Exception) {
                Log.d(TAG, "查不到提醒任务状态：${error.message}")
                false
            }

            runOnUiThread {
                result.success(
                    mapOf(
                        "supported" to true,
                        "permissionGranted" to permissionGranted,
                        "notificationsEnabled" to notificationsEnabled,
                        "scheduled" to scheduled,
                    ),
                )
            }
        }
    }

    /**
     * 请求通知权限（Android 13 起为运行时权限）。
     *
     * 只在用户**主动打开提醒开关**时调用 —— 启动时不弹，与指南 8.2
     * 「用户主动开启时，解释用途并按系统版本申请」一致。
     */
    private fun handleNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            // 老系统没有这个权限，装上就能发。
            result.success(true)
            return
        }
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        if (pendingPermission != null) {
            result.error("busy", "已经有一个权限申请在进行中", null)
            return
        }
        ReminderWorker.ensureChannel(this)
        pendingPermission = result
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_NOTIFICATION_PERMISSION,
        )
    }

    @Deprecated("与 onActivityResult 同理：这是可用的最小做法")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode != REQUEST_NOTIFICATION_PERMISSION) {
            if (requestCode == REQUEST_GALLERY_PERMISSION) {
                val pending = pendingGallerySave
                pendingGallerySave = null
                val granted = grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
                if (pending == null) return
                if (granted) {
                    writeImageToGallery(pending)
                } else {
                    pending.result.error("forbidden", "没有存储权限，存不进相册", null)
                }
                return
            }
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
            return
        }
        val pending = pendingPermission
        pendingPermission = null
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pending?.success(granted)
    }

    private fun handlePick(result: MethodChannel.Result, mimeType: String?) {
        if (pendingPick != null) {
            // 连点两次「选择文件」时，第二个请求直接拒绝，而不是覆盖第一个的
            // 回调 —— 覆盖会让第一个 Future 永远不完成，界面卡在加载中。
            result.error("busy", "已经有一个文件选择在进行中", null)
            return
        }

        pendingPick = result
        try {
            startActivityForResult(pickIntent(mimeType), REQUEST_PICK_DOCUMENT)
        } catch (error: ActivityNotFoundException) {
            pendingPick = null
            result.error("unavailable", "这台设备上没有可用的文件选择器", null)
        }
    }

    /**
     * 系统「打开文档」的选择器。
     *
     * `FLAG_GRANT_READ_URI_PERMISSION` 是必须的：`takePersistableUriPermission`
     * 只能持久化系统真的授予过的权限，不带这个标记就会直接抛 SecurityException。
     *
     * [mimeType] 为空表示账单文件（任意类型）；选分类图片时传图片通配，
     * 让选择器先帮用户过滤一遍，而不是选完再拒绝。
     *
     * ⚠️ 这里的注释不能出现斜杠加星号（哪怕是写成路径样式）：
     * Kotlin 的块注释是**可嵌套**的，那会开一个新的注释层，
     * 把后面整段代码吞掉 —— 编译器的报错会指向很远的地方。
     */
    private fun pickIntent(mimeType: String?): Intent =
        Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType ?: "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

    /**
     * 选择器的返回。
     *
     * 用 `startActivityForResult` 而不是 `registerForActivityResult`：后者是
     * `ComponentActivity` 的 API，而 `FlutterActivity` 继承的是
     * `android.app.Activity`，拿不到。改用 `FlutterFragmentActivity` 能拿到，
     * 但那要多一份 androidx.fragment 依赖 —— 为了一个文件选择不值得动
     * 这个工程本来就很脆的原生依赖。
     */
    @Deprecated("startActivityForResult 已被官方标记为弃用，但这里是可用且最小的做法")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_SAVE_DOCUMENT) {
            val pending = pendingSave
            pendingSave = null
            if (pending == null) return
            val uri = if (resultCode == RESULT_OK) data?.data else null
            when (uri) {
                // 用户取消：这不是错误，回 null 让界面安静回到原样。
                null -> pending.result.success(null)
                // data 仍然是可空的：uri 非空不代表整个 Intent 非空。
                else -> writeInto(pending, uri, data?.type)
            }
            return
        }

        if (requestCode != REQUEST_PICK_DOCUMENT) {
            // 别的请求（插件自己的）交给引擎处理。
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        val result = pendingPick
        pendingPick = null
        if (result == null) return

        val uri = if (resultCode == RESULT_OK) data?.data else null
        when (uri) {
            // 用户取消：这不是错误，回 null 让界面安静地回到原样。
            null -> result.success(null)
            else -> readInto(result, uri)
        }
    }

    /**
     * 判断系统里有没有能响应「打开文档」的界面。
     *
     * ⚠️ 从 API 30 起有**包可见性**限制：不声明 `<queries>` 的话，
     * 即使系统里明明有文件选择器，`resolveActivity` 也会返回 null。
     * 清单里已经声明了；但这个方法仍只当作「参考信息」用
     * —— 真正能不能开，以 [handlePick] 里捕获 ActivityNotFoundException 为准。
     */
    private fun pickerAvailable(): Boolean = try {
        pickIntent(null).resolveActivity(packageManager) != null
    } catch (error: Exception) {
        false
    }

    private fun readInto(result: MethodChannel.Result, uri: Uri) {
        fileExecutor.execute {
            try {
                val described = describe(uri)
                val name = described.first
                val declaredSize = described.second
                if (declaredSize != null && declaredSize > MAX_BYTES) {
                    runOnUiThread {
                        result.error(
                            "too_large",
                            "这个文件有 ${declaredSize / 1024 / 1024} MB，" +
                                "超过上限 ${MAX_BYTES / 1024 / 1024} MB",
                            null,
                        )
                    }
                    return@execute
                }

                val buffer = ByteArrayOutputStream()
                var tooLarge = false
                contentResolver.openInputStream(uri)?.use { input ->
                    val chunk = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val read = input.read(chunk)
                        if (read < 0) break
                        total += read
                        // provider 报的大小可能是错的，所以边读边再挡一次。
                        if (total > MAX_BYTES) {
                            tooLarge = true
                            break
                        }
                        buffer.write(chunk, 0, read)
                    }
                }

                if (tooLarge) {
                    runOnUiThread { result.error("too_large", "文件超过上限", null) }
                    return@execute
                }

                val bytes = buffer.toByteArray()
                if (bytes.isEmpty()) {
                    runOnUiThread { result.error("empty", "这个文件是空的", null) }
                    return@execute
                }

                // 拿到读取授权就持久化它，否则进程重启后「导入历史」里
                // 想重新读这份文件会直接被拒绝。
                try {
                    contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION,
                    )
                } catch (error: SecurityException) {
                    // 有些 provider（例如部分网盘）不支持持久化授权。
                    // 这不是致命问题：本次导入已经拿到字节了，
                    // 只是将来「重新选择」时要用户再选一次。
                    Log.d(TAG, "该 provider 不支持持久化授权：${error.message}")
                }

                runOnUiThread {
                    result.success(
                        mapOf(
                            "name" to name,
                            "uri" to uri.toString(),
                            "sizeBytes" to bytes.size,
                            "bytes" to bytes,
                        ),
                    )
                }
            } catch (error: SecurityException) {
                // 持久化授权被系统回收、或文件在别的应用里被删掉了。
                runOnUiThread {
                    result.error("forbidden", "没有读取这个文件的权限，请重新选择一次", null)
                }
            } catch (error: IOException) {
                runOnUiThread {
                    result.error("unreadable", "读不了这个文件：${error.message}", null)
                }
            } catch (error: Exception) {
                Log.e(TAG, "读取文件失败", error)
                runOnUiThread {
                    result.error("unreadable", error.message ?: "读不了这个文件", null)
                }
            }
        }
    }

    /**
     * 系统「创建文档」的选择器。
     *
     * `EXTRA_TITLE` 只是**建议**的文件名，用户可以改；真正的文件由系统
     * 在用户选的位置创建，我们只拿到一个可写的 `content://` URI。
     */
    private fun saveIntent(name: String, mimeType: String?): Intent =
        Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType ?: "application/octet-stream"
            putExtra(Intent.EXTRA_TITLE, name)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }

    private fun handleSave(
        result: MethodChannel.Result,
        fileName: String?,
        mimeType: String?,
        bytes: ByteArray?,
    ) {
        if (fileName.isNullOrBlank()) {
            result.error("bad_arguments", "缺少文件名", null)
            return
        }
        if (bytes == null || bytes.isEmpty()) {
            result.error("bad_arguments", "没有可保存的内容", null)
            return
        }
        if (bytes.size > MAX_BYTES) {
            result.error("too_large", "导出文件超过上限，暂时保存不了", null)
            return
        }
        if (pendingSave != null) {
            result.error("busy", "已经有一个保存操作在进行中", null)
            return
        }

        pendingSave = PendingSave(result, bytes, fileName)
        try {
            startActivityForResult(saveIntent(fileName, mimeType), REQUEST_SAVE_DOCUMENT)
        } catch (error: ActivityNotFoundException) {
            pendingSave = null
            result.error("unavailable", "这台设备上没有可用的文件保存界面", null)
        }
    }

    /**
     * 写字节到用户选中的位置。
     *
     * 失败一律如实上报：磁盘满、URI 失效、目标应用被卸载都会走到这里，
     * 不能吞掉 —— 用户以为存下来了、其实没有，比报错严重得多。
     */
    private fun writeInto(pending: PendingSave, uri: Uri, mimeType: String?) {
        fileExecutor.execute {
            try {
                val output = contentResolver.openOutputStream(uri)
                if (output == null) {
                    runOnUiThread {
                        pending.result.error("unwritable", "这个位置写不进去，请换一个位置", null)
                    }
                    return@execute
                }
                output.use { stream ->
                    stream.write(pending.bytes)
                    stream.flush()
                }
                runOnUiThread {
                    pending.result.success(
                        mapOf(
                            "uri" to uri.toString(),
                            "name" to pending.name,
                            "sizeBytes" to pending.bytes.size,
                            "mimeType" to mimeType,
                        ),
                    )
                }
            } catch (error: SecurityException) {
                runOnUiThread {
                    pending.result.error("unwritable", "这个位置的写入权限已经失效，请重新保存一次", null)
                }
            } catch (error: IOException) {
                runOnUiThread {
                    pending.result.error("unwritable", "写不了这个位置：${error.message}", null)
                }
            } catch (error: Exception) {
                Log.e(TAG, "保存文件失败", error)
                runOnUiThread {
                    pending.result.error("unwritable", error.message ?: "保存失败", null)
                }
            }
        }
    }

    /**
     * 把图片写进相册。
     *
     * Android 10 起用 MediaStore 直接写 `Pictures/有数`，**不需要任何权限**，
     * 写进前先标 `IS_PENDING`，写完再清 —— 这样相册不会扫到半张图。
     * Android 9 及以下没有分区存储，只能写公开目录，需要存储权限，
     * 所以先要权限、拿到再写，并用 MediaScanner 让它出现在相册里。
     */
    private fun handleSaveImageToGallery(
        result: MethodChannel.Result,
        fileName: String?,
        bytes: ByteArray?,
    ) {
        if (fileName.isNullOrBlank()) {
            result.error("bad_arguments", "缺少文件名", null)
            return
        }
        if (bytes == null || bytes.isEmpty()) {
            result.error("bad_arguments", "没有可保存的内容", null)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            writeImageToGallery(PendingGallerySave(result, bytes, fileName))
            return
        }

        if (checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            writeImageToGallery(PendingGallerySave(result, bytes, fileName))
            return
        }
        if (pendingGallerySave != null) {
            result.error("busy", "已经有一个保存操作在进行中", null)
            return
        }
        pendingGallerySave = PendingGallerySave(result, bytes, fileName)
        requestPermissions(
            arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
            REQUEST_GALLERY_PERMISSION,
        )
    }

    private fun writeImageToGallery(pending: PendingGallerySave) {
        fileExecutor.execute {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val values = ContentValues().apply {
                        put(MediaStore.Images.Media.DISPLAY_NAME, pending.name)
                        put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                        put(
                            MediaStore.Images.Media.RELATIVE_PATH,
                            Environment.DIRECTORY_PICTURES + "/" + GALLERY_FOLDER,
                        )
                        put(MediaStore.Images.Media.IS_PENDING, 1)
                    }
                    val uri = contentResolver.insert(
                        MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                        values,
                    ) ?: throw IOException("相册不接受这个文件")

                    contentResolver.openOutputStream(uri)?.use { stream ->
                        stream.write(pending.bytes)
                        stream.flush()
                    } ?: throw IOException("写不进相册")

                    values.clear()
                    values.put(MediaStore.Images.Media.IS_PENDING, 0)
                    contentResolver.update(uri, values, null, null)

                    runOnUiThread {
                        pending.result.success(
                            mapOf(
                                "uri" to uri.toString(),
                                "name" to pending.name,
                                "gallery" to true,
                            ),
                        )
                    }
                    return@execute
                }

                // Android 9 及以下：写公开目录再通知相册扫描。
                val folder = File(
                    Environment.getExternalStoragePublicDirectory(
                        Environment.DIRECTORY_PICTURES,
                    ),
                    GALLERY_FOLDER,
                )
                if (!folder.exists() && !folder.mkdirs()) {
                    throw IOException("建不了相册目录")
                }
                val target = File(folder, pending.name)
                target.writeBytes(pending.bytes)

                MediaScannerConnection.scanFile(
                    this,
                    arrayOf(target.absolutePath),
                    arrayOf("image/png"),
                    null,
                )

                runOnUiThread {
                    pending.result.success(
                        mapOf(
                            "uri" to Uri.fromFile(target).toString(),
                            "name" to pending.name,
                            "gallery" to true,
                        ),
                    )
                }
            } catch (error: SecurityException) {
                runOnUiThread {
                    pending.result.error("forbidden", "没有存储权限，存不进相册", null)
                }
            } catch (error: IOException) {
                runOnUiThread {
                    pending.result.error("unwritable", "存相册失败：${error.message}", null)
                }
            } catch (error: Exception) {
                Log.e(TAG, "存相册失败", error)
                runOnUiThread {
                    pending.result.error("unwritable", error.message ?: "存相册失败", null)
                }
            }
        }
    }

    /**
     * 判断系统里有没有能响应「创建文档」的界面（理由同 [pickerAvailable]）。
     */
    private fun saverAvailable(): Boolean = try {
        saveIntent("younum.csv", "text/csv").resolveActivity(packageManager) != null
    } catch (error: Exception) {
        false
    }

    /** 从 provider 查文件名与它声明的大小。 */
    private fun describe(uri: Uri): Pair<String, Long?> {
        var name: String? = null
        var size: Long? = null
        try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                        name = cursor.getString(nameIndex)
                    }
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                        size = cursor.getLong(sizeIndex)
                    }
                }
            }
        } catch (error: Exception) {
            // 有些 URI 根本没有对应的 provider（例如 file://），query 会直接抛。
            // 这不是失败：真正要做的只是读字节，名字可以退回 URI 末段，
            // 大小就交给「边读边挡上限」那一步。让元信息查询把整个读取带崩
            // 就本末倒置了。
            Log.d(TAG, "查不到文件元信息（不影响读取）：${error.message}")
        }
        // provider 没给名字时退回 URI 最后一段，至少让用户认得出是哪个文件。
        return (name ?: uri.lastPathSegment ?: "bill.csv") to size
    }

    override fun onDestroy() {
        pendingPick?.error("detached", "界面已经关闭", null)
        pendingPick = null
        pendingSave?.result?.error("detached", "界面已经关闭", null)
        pendingSave = null
        pendingPermission?.error("detached", "界面已经关闭", null)
        pendingPermission = null
        pendingGallerySave?.result?.error("detached", "界面已经关闭", null)
        pendingGallerySave = null
        fileExecutor.shutdown()
        super.onDestroy()
    }
}


