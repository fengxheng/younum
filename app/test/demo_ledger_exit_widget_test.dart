import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/app/app.dart';
import 'package:younum/core/preferences/app_state_store.dart';
import 'package:younum/core/preferences/theme_controller.dart';
import 'package:younum/core/preferences/theme_store.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';

/// 「示例账单体验」的进出。
///
/// 为什么值得写：进得去、出不来是这类「试一下」功能的经典毛病 —— 用户点了
/// 「先用示例账单体验」之后，界面上再也找不到回自己账单的路，只能怀疑自己的
/// 数据被样例数据顶掉了。所以这里钉住三件事：
///
/// * 示例账本里**有**一条说清楚的出口（首页徽标与「我的」页各一个入口）；
/// * 点下去真的回到自己的账本；
/// * 真实账本里**不显示**这两个入口（不该看到「示例」两个字）。
void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late ThemeController themeController;
  late AppStateController appStateController;

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
  });

  tearDown(() {
    themeController.dispose();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      YounumApp(
        themeController: themeController,
        appStateController: appStateController,
        ledgerRepository: repository,
        ledgerFileSource: const UnsupportedFileSource(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  /// 从空首页进示例账单体验。
  Future<void> enterDemo(WidgetTester tester) async {
    await tester.tap(find.text('先用示例账单体验'));
    await tester.pumpAndSettle();
  }

  testWidgets('「我的」页给出一条说得清的出口，点了就回到自己的账本', (tester) async {
    await pumpApp(tester);
    await enterDemo(tester);
    expect(appStateController.isDemoLedger, isTrue);

    await openTab(tester, '我的');
    expect(find.text('退出示例账本'), findsOneWidget);
    expect(
      find.textContaining('真实账单在另一个账本里'),
      findsOneWidget,
      reason: '要讲清「退出不是删数据」',
    );

    await tester.tap(find.text('退出示例账本'));
    await tester.pumpAndSettle();

    expect(appStateController.isDemoLedger, isFalse);
    // 真实账本还没有账单 → 回到空首页（而不是还停在样例数字上）。
    // 刚才是从「我的」页退出的，所以先切回本月。
    await openTab(tester, '本月');
    expect(find.text('先用示例账单体验'), findsOneWidget);
    expect(find.text('示例账本'), findsNothing);
  });

  testWidgets('首页的「示例账本」徽标也能点开说明并退出', (tester) async {
    await pumpApp(tester);
    await enterDemo(tester);

    await tester.tap(find.text('示例账本'));
    await tester.pumpAndSettle();

    expect(find.text('当前是示例账本'), findsOneWidget);
    await tester.tap(find.text('退出示例账本'));
    await tester.pumpAndSettle();

    expect(appStateController.isDemoLedger, isFalse);
  });

  testWidgets('弹层里点「继续体验」什么都不改', (tester) async {
    await pumpApp(tester);
    await enterDemo(tester);

    await tester.tap(find.text('示例账本'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续体验'));
    await tester.pumpAndSettle();

    expect(appStateController.isDemoLedger, isTrue);
  });

  testWidgets('自己的账本里看不到任何「退出示例账本」的入口', (tester) async {
    await pumpApp(tester);
    await openTab(tester, '我的');

    expect(find.text('退出示例账本'), findsNothing);
    expect(find.text('示例账本'), findsNothing);
  });
}
