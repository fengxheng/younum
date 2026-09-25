import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/app/app.dart';
import 'package:younum/app/app_routes.dart';
import 'package:younum/core/preferences/app_state_store.dart';
import 'package:younum/core/preferences/reminder_store.dart';
import 'package:younum/core/preferences/theme_controller.dart';
import 'package:younum/core/preferences/theme_store.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/domain/repositories/reminder_scheduler.dart';

/// 提醒设置页。
///
/// 指南 8.2 的验收点：**通知被拒绝或系统关闭时，设置页显示实际状态，
/// 不显示「已开启」而无法通知**。这里把那条路径走一遍 —— 打开开关却拿不到
/// 权限时，开关必须回到关闭，并说清楚为什么。
final class _FakeScheduler implements ReminderScheduler {
  _FakeScheduler({
    this.available = true,
    this.permissionGranted = true,
    this.notificationsEnabled = true,
  });

  bool available;
  bool permissionGranted;
  bool notificationsEnabled;
  final List<DateTime> scheduled = <DateTime>[];
  int cancelCount = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<ReminderCapability> status() async => ReminderCapability(
    available: available,
    permissionGranted: permissionGranted,
    notificationsEnabled: notificationsEnabled,
    scheduled: scheduled.isNotEmpty,
  );

  @override
  Future<bool> requestPermission() async => permissionGranted;

  @override
  Future<bool> schedule(
    ReminderSettings settings, {
    required DateTime nextRun,
  }) async {
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
  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late ThemeController themeController;
  late AppStateController appStateController;
  late InMemoryReminderStore reminderStore;

  setUp(() async {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(1080, 2400);
    view.devicePixelRatio = 2.75;

    store = InMemoryLedgerStore();
    repository = LedgerRepository(store);
    await repository.initialize();
    themeController = await ThemeController.restore(InMemoryThemeStore());
    appStateController = await AppStateController.restore(
      InMemoryAppStateStore(),
    );
    await appStateController.completeOnboarding();
    await appStateController.enterDemoLedger();
    reminderStore = InMemoryReminderStore();
  });

  tearDown(() {
    themeController.dispose();
  });

  Future<void> openReminder(
    WidgetTester tester, {
    required ReminderScheduler scheduler,
  }) async {
    await tester.pumpWidget(
      YounumApp(
        themeController: themeController,
        appStateController: appStateController,
        ledgerRepository: repository,
        ledgerFileSource: const UnsupportedFileSource(),
        reminderStore: reminderStore,
        reminderScheduler: scheduler,
      ),
    );
    await tester.pumpAndSettle();

    final navigator = Navigator.of(tester.element(find.byType(Navigator).first));
    unawaited(navigator.pushNamed(AppRoutes.reminder));
    await tester.pumpAndSettle();
  }

  Future<void> toggleSwitch(WidgetTester tester) async {
    final target = find.byType(Switch);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets('默认关闭：不会有下次提醒时间', (tester) async {
    final scheduler = _FakeScheduler();
    await openReminder(tester, scheduler: scheduler);

    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(find.textContaining('下次提醒约在'), findsNothing);
    expect(find.text('关闭时不会有任何通知。'), findsOneWidget);
  });

  testWidgets('打开提醒：申请权限并排期，页面出现下次时间与「约」的说明', (tester) async {
    final scheduler = _FakeScheduler();
    await openReminder(tester, scheduler: scheduler);

    await toggleSwitch(tester);

    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(scheduler.scheduled, hasLength(1));
    expect(find.textContaining('下次提醒约在'), findsOneWidget);
    expect(find.textContaining('系统省电策略可能造成合理延迟'), findsOneWidget);
    // 设置也要真的落盘。
    expect((await reminderStore.load())!.enabled, isTrue);
  });

  testWidgets('拒绝通知权限：开关不会留在「已开启」，并说明原因', (tester) async {
    final scheduler = _FakeScheduler(permissionGranted: false);
    await openReminder(tester, scheduler: scheduler);

    await toggleSwitch(tester);

    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(scheduler.scheduled, isEmpty);
    expect(find.textContaining('没有允许通知'), findsOneWidget);
    expect((await reminderStore.load())!.enabled, isFalse);
  });

  testWidgets('系统里把通知关掉：显示发不出去，而不是「已开启」', (tester) async {
    final scheduler = _FakeScheduler(notificationsEnabled: false);
    await openReminder(tester, scheduler: scheduler);

    await toggleSwitch(tester);

    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.textContaining('系统里把通知关掉了'), findsOneWidget);
    expect(find.textContaining('提醒现在发不出去'), findsOneWidget);
  });

  testWidgets('平台不支持：开关显灰并说明', (tester) async {
    final scheduler = _FakeScheduler(available: false, permissionGranted: false);
    await openReminder(tester, scheduler: scheduler);

    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    expect(find.text('这个平台上还不能发通知，所以提醒暂时用不了。'), findsOneWidget);
  });

  testWidgets('从已有设置进入：显示存下来的日期与时间', (tester) async {
    await reminderStore.save(
      const ReminderSettings(enabled: true, day: 15, hour: 9, minute: 0),
    );
    final scheduler = _FakeScheduler();
    await openReminder(tester, scheduler: scheduler);

    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.text('每月 15 日'), findsWidgets);
    expect(find.text('09:00'), findsWidgets);
    expect(find.textContaining('下次提醒约在'), findsOneWidget);
  });
}
