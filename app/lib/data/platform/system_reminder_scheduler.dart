/// 提醒调度的接入实现（Android）。
///
/// 走 `com.younum.app/reminder` 这条自写的平台通道 —— 原生侧代码在
/// `android/app/src/main/kotlin/com/younum/app/`（MainActivity + ReminderWorker）。
///
/// 这一层只做翻译：原生 map → `ReminderCapability`，原生错误码 → 可展示的中文。
/// 调度本身（WorkManager、通知渠道）都在原生侧，Dart 只负责「什么时候该有提醒」。
library;

import 'package:flutter/services.dart';

import '../../core/preferences/reminder_store.dart';
import '../../domain/repositories/reminder_scheduler.dart';

/// 系统提醒。
final class SystemReminderScheduler implements ReminderScheduler {
  SystemReminderScheduler({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  /// 与 MainActivity 里注册的名字必须一致。
  static const String channelName = 'com.younum.app/reminder';

  final MethodChannel _channel;

  @override
  Future<bool> isAvailable() async {
    try {
      final status = await _channel.invokeMapMethod<String, Object?>('status');
      return status?['supported'] == true;
    } on MissingPluginException {
      // 桌面或 Web：通道不存在，不是故障，就是没这个能力。
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<ReminderCapability> status() async {
    try {
      final status = await _channel.invokeMapMethod<String, Object?>('status');
      if (status == null) return ReminderCapability.unsupported;
      return ReminderCapability(
        available: status['supported'] == true,
        permissionGranted: status['permissionGranted'] == true,
        notificationsEnabled: status['notificationsEnabled'] == true,
        scheduled: status['scheduled'] == true,
      );
    } on MissingPluginException {
      return ReminderCapability.unsupported;
    } on PlatformException {
      // 读不到状态就当不支持：宁可少显示一个「已开启」，也不要凭猜。
      return ReminderCapability.unsupported;
    }
  }

  @override
  Future<bool> requestPermission() async {
    try {
      final granted = await _channel.invokeMethod<bool>('requestPermission');
      return granted ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> schedule(
    ReminderSettings settings, {
    required DateTime nextRun,
  }) async {
    try {
      final ok = await _channel.invokeMethod<bool>('schedule', <String, Object?>{
        'day': settings.day,
        'hour': settings.hour,
        'minute': settings.minute,
        'nextRunMs': nextRun.millisecondsSinceEpoch,
      });
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } on MissingPluginException {
      // 没有这个能力就没什么可取消的。
    } on PlatformException {
      // 取消失败不影响用户手上的数据，不值得打断他；状态页会如实显示。
    }
  }
}
