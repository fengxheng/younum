import 'package:flutter_test/flutter_test.dart';
import 'package:younum/core/preferences/reminder_controller.dart';
import 'package:younum/core/preferences/reminder_store.dart';
import 'package:younum/domain/repositories/reminder_scheduler.dart';
import 'package:younum/domain/rules/reminder_rules.dart';

/// 提醒控制器：开关、权限、排期与「如实上报状态」。
///
/// 指南 8.2 要求「通知被拒绝或系统关闭时，设置页显示实际状态，
/// 不显示「已开启」而无法通知」—— 这里把那些分支都走一遍。

/// 可控的假调度器。
final class _FakeScheduler implements ReminderScheduler {
  _FakeScheduler({
    this.available = true,
    this.permissionGranted = true,
    this.notificationsEnabled = true,
    this.scheduleSucceeds = true,
  });

  bool available;
  bool permissionGranted;
  bool notificationsEnabled;
  bool scheduleSucceeds;

  /// 已经排下的任务（时间）。
  final List<DateTime> scheduled = <DateTime>[];
  int cancelCount = 0;
  int permissionRequests = 0;
  ReminderSettings? lastScheduled;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<ReminderCapability> status() async => ReminderCapability(
    available: available,
    permissionGranted: permissionGranted,
    notificationsEnabled: notificationsEnabled,
    scheduled: scheduled.isNotEmpty && cancelCount == 0,
  );

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return permissionGranted;
  }

  @override
  Future<bool> schedule(
    ReminderSettings settings, {
    required DateTime nextRun,
  }) async {
    if (!scheduleSucceeds) return false;
    lastScheduled = settings;
    scheduled.add(nextRun);
    return true;
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
    scheduled.clear();
  }
}

void main() {
  late InMemoryReminderStore store;
  late _FakeScheduler scheduler;
  late ReminderController controller;

  /// 固定时钟：2026-09-03 09:00。
  final now = DateTime(2026, 9, 3, 9, 0);

  ReminderController build({
    ReminderSettings? initial,
    _FakeScheduler? fake,
  }) {
    store = InMemoryReminderStore(initial);
    scheduler = fake ?? _FakeScheduler();
    return ReminderController(
      store: store,
      scheduler: scheduler,
      clock: () => now,
    );
  }

  test('默认关闭，读完设置也不会有「下次提醒」', () async {
    controller = build();
    await controller.load();

    expect(controller.isLoaded, isTrue);
    expect(controller.settings.enabled, isFalse);
    expect(controller.nextRun, isNull);
    expect(controller.nextRunLabel, isNull);
  });

  test('打开提醒：先申请权限，再排期，并记下设置', () async {
    controller = build();
    await controller.load();

    await controller.setEnabled(true);

    expect(scheduler.permissionRequests, 1);
    expect(scheduler.scheduled, hasLength(1));
    expect(controller.settings.enabled, isTrue);
    expect(await store.load(), controller.settings, reason: '设置要落盘');
    expect(controller.lastFailure, isNull);
  });

  test('拒绝权限：开关不会留在「已开启」，并说明原因', () async {
    controller = build(fake: _FakeScheduler(permissionGranted: false));
    await controller.load();

    await controller.setEnabled(true);

    expect(controller.settings.enabled, isFalse, reason: '开不了就别显示已开启');
    expect(controller.nextRun, isNull);
    expect(scheduler.scheduled, isEmpty);
    expect(controller.lastFailure, contains('没有允许通知'));
    expect((await store.load())!.enabled, isFalse);
  });

  test('权限给了但系统里通知被关：如实显示为「发不出去」', () async {
    controller = build(fake: _FakeScheduler(notificationsEnabled: false));
    await controller.load();

    await controller.setEnabled(true);

    expect(controller.settings.enabled, isTrue);
    expect(controller.capability.notificationsEnabled, isFalse);
    expect(controller.capability.canDeliver, isFalse, reason: '状态必须如实');
  });

  test('排期失败：不假装成功，开关回到关闭', () async {
    controller = build(fake: _FakeScheduler(scheduleSucceeds: false));
    await controller.load();

    await controller.setEnabled(true);

    expect(controller.settings.enabled, isFalse);
    expect(controller.lastFailure, contains('没能排上'));
    expect((await store.load())!.enabled, isFalse);
  });

  test('关闭提醒：取消任务并落盘', () async {
    controller = build(initial: ReminderRules.defaults.copyWith(enabled: true));
    await controller.load();

    await controller.setEnabled(false);

    expect(scheduler.cancelCount, 1);
    expect(scheduler.scheduled, isEmpty);
    expect(controller.settings.enabled, isFalse);
    expect((await store.load())!.enabled, isFalse);
  });

  test('改日期或时间会立刻重排，不留旧任务', () async {
    controller = build(initial: ReminderRules.defaults.copyWith(enabled: true));
    await controller.load();

    await controller.setDay(15);
    expect(scheduler.lastScheduled!.day, 15);
    expect(scheduler.scheduled.last, DateTime(2026, 9, 15, 20, 0));

    await controller.setTime(hour: 8, minute: 30);
    expect(scheduler.scheduled.last, DateTime(2026, 9, 15, 8, 30));
    expect(controller.lastFailure, isNull);
  });

  test('关闭状态下改时间只存设置，不动任务', () async {
    controller = build();
    await controller.load();

    await controller.setDay(20);

    expect(scheduler.scheduled, isEmpty);
    expect((await store.load())!.day, 20);
  });

  test('平台不支持：没有下次提醒，开关也开不出任务', () async {
    controller = build(
      fake: _FakeScheduler(available: false, permissionGranted: false),
    );
    await controller.load();

    expect(controller.isSupported, isFalse);
    expect(controller.nextRun, isNull);

    await controller.setEnabled(true);
    expect(scheduler.scheduled, isEmpty);
    expect(controller.settings.enabled, isFalse);
  });

  test('清除本地数据：取消提醒并关掉开关，但保留用户选的时间', () async {
    controller = build(
      initial: const ReminderSettings(
        enabled: true,
        day: 15,
        hour: 9,
        minute: 30,
      ),
    );
    await controller.load();

    await controller.cancelReminder();

    expect(scheduler.cancelCount, 1);
    expect(controller.settings.enabled, isFalse);
    expect(controller.settings.day, 15, reason: '日期时间是用户偏好，与账单无关');
    expect(controller.settings.hour, 9);
  });

  test('下次提醒与设置一致：9 月 3 日已过 1 日，就是 10 月 1 日', () async {
    controller = build(initial: ReminderRules.defaults.copyWith(enabled: true));
    await controller.load();

    expect(controller.nextRun!, DateTime(2026, 10, 1, 20, 0));
    expect(controller.nextRunLabel, '10 月 1 日 20:00');
    expect(controller.remainingLabel, '约 28 天后');
  });
}
