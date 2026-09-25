# release 构建的 R8 保留规则。
#
# 背景：release 会跑 R8（代码压缩 + 混淆），debug **不会**。所以下面这些
# 「反射调用」的坑只在正式包里发作，而且症状特别难看 —— 不是编译报错，
# 而是应用启动即退出、连白屏都没有。真机上对应的崩溃是：
#
#   FATAL EXCEPTION: main
#   java.lang.RuntimeException: Unable to get provider
#       androidx.startup.InitializationProvider: ...
#   Caused by: java.lang.NoSuchMethodException:
#       androidx.work.impl.WorkDatabase_Impl.<init> []
#       at androidx.work.WorkManagerInitializer...
#
# 这个崩溃发生在 Flutter 引擎起来**之前**（WorkManager 是用 androidx.startup 的
# ContentProvider 在进程启动时自动初始化的），所以 logcat 里一条 flutter 日志
# 都没有，只看得到「进程刚建就没了」。定位这类问题时先看 AndroidRuntime 的
# FATAL EXCEPTION，别被「没有白屏」带偏。


# ── Room / WorkManager 的数据库 ────────────────────────────────────────────
# Room 生成的 `XxxDatabase_Impl` 是**反射**实例化的：
#   Class.getDeclaredConstructor().newInstance()
# R8 静态分析看不到这个调用点，会把无参构造当成死代码删掉。
# WorkManager 的 WorkDatabase_Impl 就是这个下场（每月整理提醒要用）。
-keep class * extends androidx.room.RoomDatabase { <init>(); }


# ── Worker 类 ─────────────────────────────────────────────────────────────
# WorkManager 从数据库里读出 Worker 的**类名**，再反射构造它。
# 被裁掉或改名的话，提醒会静默失效 —— 不报错，只是再也不响。
-keep class * extends androidx.work.ListenableWorker {
    public <init>(android.content.Context, androidx.work.WorkerParameters);
}
