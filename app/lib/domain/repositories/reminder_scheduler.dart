/// 每月整理提醒的调度端口（指南 8.2）。
///
/// 拆成「设置」与「能力」两件事：
///
/// * 用户设的日期 / 时间 / 开关存在 [ReminderSettings]（见 core/preferences）；
/// * 而**能不能真的发出去**由平台决定 —— 权限有没有给、系统里通知有没有被关。
///
/// 后者必须如实上报：设置页显示「已开启」却发不出通知，比不显示更糟。
library;

import '../../core/preferences/reminder_store.dart';

/// 平台的实际能力与状态。
final class ReminderCapability {
  const ReminderCapability({
    required this.available,
    required this.permissionGranted,
    required this.notificationsEnabled,
    required this.scheduled,
  });

  /// 这个平台支不支持提醒（桌面与测试环境不支持）。
  final bool available;

  /// 通知权限是否已授予。Android 13 以下是 true（装上就能发）。
  final bool permissionGranted;

  /// 系统里通知是否处于开启状态（用户在系统设置里可能整个关掉）。
  final bool notificationsEnabled;

  /// 现在是否真的有排好的任务。
  final bool scheduled;

  /// 真的能发出去吗。
  bool get canDeliver => available && permissionGranted && notificationsEnabled;

  static const ReminderCapability unsupported = ReminderCapability(
    available: false,
    permissionGranted: false,
    notificationsEnabled: false,
    scheduled: false,
  );

  @override
  String toString() =>
      'ReminderCapability(available: $available, permission: $permissionGranted, '
      'enabled: $notificationsEnabled, scheduled: $scheduled)';
}

/// 提醒调度。
abstract interface class ReminderScheduler {
  /// 这个平台支不支持。
  Future<bool> isAvailable();

  /// 读实际状态。
  Future<ReminderCapability> status();

  /// 申请通知权限。返回是否已授予。
  ///
  /// 只应在用户**主动打开提醒开关**时调用（指南 8.2），不要在启动时弹。
  Future<bool> requestPermission();

  /// 按设置排下一次提醒（会覆盖旧任务，避免重复提醒）。
  ///
  /// [nextRun] 由 `ReminderRules.nextRun` 算好后传进来：界面上的说明文字与
  /// 真正排的时间读同一份推算结果。
  Future<bool> schedule(ReminderSettings settings, {required DateTime nextRun});

  /// 取消提醒。
  Future<void> cancel();
}

/// 当前环境不支持提醒。
final class UnsupportedReminderScheduler implements ReminderScheduler {
  const UnsupportedReminderScheduler();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<ReminderCapability> status() async => ReminderCapability.unsupported;

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<bool> schedule(
    ReminderSettings settings, {
    required DateTime nextRun,
  }) async => false;

  @override
  Future<void> cancel() async {}
}
