import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/app/app.dart';
import 'package:younum/core/components/screen_scaffold.dart';
import 'package:younum/core/preferences/app_state_store.dart';
import 'package:younum/core/preferences/theme_controller.dart';
import 'package:younum/core/preferences/theme_store.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/ledger_transaction.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/features/organize/review_screens.dart';

/// 交易性质页的界面接线测试。
///
/// 原先这一页整个是样例：五个写死的选项、写死的「优衣库 · 9月12日 · ¥299.00」
/// 候选原消费、按了只弹提示不落库，进页面时连交易 ID 都没传。
void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late ThemeController themeController;
  late AppStateController appStateController;

  const int ledgerId = DemoLedgerSeed.demoLedgerId;
  final int firstCardId = DemoLedgerSeed.transactionIdAt(0);

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
  });

  tearDown(() {
    themeController.dispose();
  });

  /// 路由下面的页面仍留在树里，断言必须限定在性质页内。
  Finder inNature(Finder matching) => find.descendant(
    of: find.byType(TransactionNatureScreen),
    matching: matching,
  );

  Future<LedgerTransaction> reload() async {
    final dataset = await repository.dataset(ledgerId: ledgerId);
    return dataset.transaction(firstCardId)!;
  }

  /// 整理 → 更多操作 → 设为转账 / 收入 / 不计入。
  Future<void> openNature(WidgetTester tester) async {
    await tester.pumpWidget(
      YounumApp(
        themeController: themeController,
        appStateController: appStateController,
        ledgerRepository: repository,
        ledgerFileSource: const UnsupportedFileSource(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byType(AppBottomBar),
        matching: find.text('整理'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('更多操作'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('设为转账 / 收入 / 不计入'));
    await tester.pumpAndSettle();
  }

  testWidgets('性质页展示的是传进来的那一笔，且默认不预选任何性质', (WidgetTester tester) async {
    await openNature(tester);

    expect(inNature(find.text('调整交易性质')), findsOneWidget);
    expect(inNature(find.text('MANNER COFFEE')), findsOneWidget);
    expect(inNature(find.textContaining('¥28.00')), findsWidgets);
    // 没选之前不能提交：替用户预选一个性质，会让人顺手确认下去。
    await tester.tap(inNature(find.text('确认调整')));
    await tester.pumpAndSettle();
    expect((await reload()).nature, TransactionNature.expense);
    expect(find.byType(TransactionNatureScreen), findsOneWidget);
  });

  testWidgets('标成转账后真的落库，并离开这一笔的待整理状态', (WidgetTester tester) async {
    await openNature(tester);

    await tester.tap(inNature(find.text('账户间转账')));
    await tester.pumpAndSettle();
    await tester.tap(inNature(find.text('确认调整')));
    await tester.pumpAndSettle();

    final updated = await reload();
    expect(updated.nature, TransactionNature.transfer);
    expect(updated.reviewStatus, ReviewStatus.resolved);
    expect(find.byType(TransactionNatureScreen), findsNothing);
  });

  testWidgets('排除统计：没写原因不能提交，写了才落库', (WidgetTester tester) async {
    await openNature(tester);

    await tester.tap(inNature(find.text('暂不计入统计')));
    await tester.pumpAndSettle();

    // 原因还没填：按钮应当是灰的。
    await tester.tap(inNature(find.text('确认调整')));
    await tester.pumpAndSettle();
    expect((await reload()).nature, TransactionNature.expense);
    expect(inNature(find.textContaining('排除统计需要写明原因')), findsOneWidget);

    await tester.enterText(inNature(find.byType(TextField)).first, '朋友还我的钱');
    await tester.pumpAndSettle();
    await tester.tap(inNature(find.text('确认调整')));
    await tester.pumpAndSettle();

    final updated = await reload();
    expect(updated.nature, TransactionNature.excluded);
    expect(updated.excludeReason, '朋友还我的钱');
  });

  testWidgets('选「普通消费」但还没有用途时被拦下并说明原因', (WidgetTester tester) async {
    await openNature(tester);

    await tester.tap(inNature(find.text('普通消费')));
    await tester.pumpAndSettle();

    expect(inNature(find.textContaining('需要一个用途')), findsOneWidget);
    await tester.tap(inNature(find.text('确认调整')));
    await tester.pumpAndSettle();

    expect((await reload()).reviewStatus, ReviewStatus.pending);
    expect(find.byType(TransactionNatureScreen), findsOneWidget);
  });
}
