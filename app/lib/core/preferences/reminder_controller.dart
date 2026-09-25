/// 每月整理提醒的控制器。
///
/// 指南 8.2 的几条要求在这里落地：
///
/// * 默认关闭；用户主动开启时才申请通知权限；
/// * **通知被拒绝或系统关闭时，显示实际状态**，不显示「已开启」却发不出去；
/// * 改时间或重开都替换旧任务，不留下重复提醒；
/// * 状态存下来（日期、时间、开关、时区口径），重启后还在。
library;

import 'package:flutter/foundation.dart';

import '../../domain/repositories/reminder_scheduler.dart';
import '../../domain/rules/reminder_rules.dart';
import 'reminder_store.dart';

/// 提醒的界面状态。
class ReminderController extends ChangeNotifier {
  ReminderController({
    required this.store,
    required this.scheduler,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final ReminderStore store;
  final ReminderScheduler scheduler;
  final DateTime Function() _clock;

  ReminderSettings _settings = ReminderRules.defaults;
  ReminderCapability _capability = ReminderCapability.unsupported;
  bool _loaded = false;
  bool _busy = false;
  String? _lastFailure;

  /// 当前设置。
  ReminderSettings get settings => _settings;

  /// 平台实际状态。
  ReminderCapability get capability => _capability;

  /// 是否已经读过设置。没读完之前界面不要显示开关的「真实」值。
  bool get isLoaded => _loaded;

  /// 正在申请权限或排期：按钮该置灰。
  bool get isBusy => _busy;

  /// 最近一次失败的原因，可以直接展示；null 表示没有失败。
  String? get lastFailure => _lastFailure;

  /// 这个平台支不支持提醒。
  bool get isSupported => _capability.available;

  /// 下次提醒时间。关闭或平台不支持时是 null。
  DateTime? get nextRun {
    if (!_capability.available) return null;
    return ReminderRules.nextRun(_settings, now: _clock());
  }

  /// 「11 月 1 日 20:00」。
  String? get nextRunLabel {
    final next = nextRun;
    return next == null ? null : ReminderRules.describe(next);
  }

  /// 「约 7 天后」。
  String? get remainingLabel {
    final next = nextRun;
    return next == null ? null : ReminderRules.remainingLabel(next, now: _clock());
  }

  /// 读设置与平台状态。
  Future<void> load() async {
    final stored = await store.load();
    _settings = stored ?? ReminderRules.defaults;
    _capability = await scheduler.status();
    _loaded = true;
    notifyListeners();
  }

  /// 开 / 关提醒。
  ///
  /// 打开时**先申请权限再排期**：拒绝权限就不把开关留在「已开启」，
  /// 否则设置页会显示一个发不出通知的提醒。
  Future<void> setEnabled(bool enabled) async {
    if (_busy) return;
    _busy = true;
    _lastFailure = null;
    notifyListeners();

    try {
      if (!enabled) {
        _settings = _settings.copyWith(enabled: false);
        await store.save(_settings);
        await scheduler.cancel();
        _capability = await scheduler.status();
        return;
      }

      final granted = await scheduler.requestPermission();
      if (!granted) {
        _settings = _settings.copyWith(enabled: false);
        await store.save(_settings);
        _lastFailure = '系统里还没有允许通知，所以提醒暂时开不了。';
        _capability = await scheduler.status();
        return;
      }

      final next = ReminderRules.nextRun(
        _settings.copyWith(enabled: true),
        now: _clock(),
      );
      if (next == null) {
        _lastFailure = '算不出下一次提醒时间，先按默认值重设一次吧。';
        return;
      }
      final ok = await scheduler.schedule(
        _settings.copyWith(enabled: true),
        nextRun: next,
      );
      if (!ok) {
        _settings = _settings.copyWith(enabled: false);
        await store.save(_settings);
        _lastFailure = '没能排上提醒，请再试一次。';
        _capability = await scheduler.status();
        return;
      }

      _settings = _settings.copyWith(enabled: true);
      await store.save(_settings);
      _capability = await scheduler.status();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 改每月第几天。开启状态下会立刻重排，不留下旧任务。
  Future<void> setDay(int day) async {
    final next = _settings.copyWith(day: day);
    if (next == _settings) return;
    _settings = next;
    notifyListeners();
    await _persistAndReschedule();
  }

  /// 改时间。
  Future<void> setTime({required int hour, required int minute}) async {
    final next = _settings.copyWith(hour: hour, minute: minute);
    if (next == _settings) return;
    _settings = next;
    notifyListeners();
    await _persistAndReschedule();
  }

  /// 清除本地数据时调用：取消提醒并关掉开关。
  ///
  /// 保留用户选的日期与时间 —— 那是他的偏好，与账单无关。
  Future<void> cancelReminder() async {
    _settings = _settings.copyWith(enabled: false);
    await store.save(_settings);
    await scheduler.cancel();
    _capability = await scheduler.status();
    notifyListeners();
  }

  Future<void> _persistAndReschedule() async {
    await store.save(_settings);
    if (!_settings.enabled) return;
    final next = ReminderRules.nextRun(_settings, now: _clock());
    if (next == null) return;
    final ok = await scheduler.schedule(_settings, nextRun: next);
    _lastFailure = ok ? null : '新时间没能排上，请重新打开一次提醒。';
    _capability = await scheduler.status();
    notifyListeners();
  }
}




