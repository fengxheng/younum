import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/app/app.dart';
import 'package:younum/app/app_routes.dart';
import 'package:younum/app/route_args.dart';
import 'package:younum/core/components/screen_scaffold.dart';
import 'package:younum/core/preferences/app_state_store.dart';
import 'package:younum/core/preferences/theme_controller.dart';
import 'package:younum/core/preferences/theme_store.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/allocation.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/features/organize/review_screens.dart';

/// 拆分页的界面接线测试。
///
/// 为什么值得写：拆分页原先整个是**样例**（写死的盒马 126.80、写死的四个
/// 用途选项、按了只弹提示不落库），从详情页进来时连交易 ID 都没传 ——
/// 也就是说用户点「拆分这笔消费」看到的是别人的账。这类问题
/// `flutter analyze` 与仓库层单测都看不出来。
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

  /// 断言限定在拆分页内。
  ///
  /// 路由下面的页面**仍留在树里**（整理页的卡片也写着同样的商户名），
  /// 不限定范围就会匹配到别的屏。
  Finder inSplit(Finder matching) =>
      find.descendant(of: find.byType(SplitScreen), matching: matching);

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

  /// 从整理页第一张卡片走到拆分页：整理 → 更多操作 → 拆分这笔消费。
  Future<void> openSplit(WidgetTester tester) async {
    await pumpApp(tester);

    await tester.tap(
      find.descendant(
        of: find.byType(AppBottomBar),
        matching: find.text('整理'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('更多操作'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('拆分这笔消费'));
    await tester.pumpAndSettle();
  }

  /// 直接压拆分路由。
  ///
  /// 用于「已拆过的记录」这类情形：拆分会把那笔置为已处理，它就从整理队列里
  /// 消失了，走整理页那条路已经到不了它（到的是下一笔）。
  Future<void> pushSplit(WidgetTester tester, int transactionId) async {
    await pumpApp(tester);
    final NavigatorState navigator = Navigator.of(
      tester.element(find.byType(AppBottomBar)),
    );
    navigator.pushNamed(
      AppRoutes.splitTransaction,
      arguments: SplitArgs(transactionId: transactionId),
    );
    await tester.pumpAndSettle();
  }

  /// 给第 [row] 行（从 1 数）选一个用途。
  Future<void> chooseCategory(
    WidgetTester tester,
    int row,
    String label,
  ) async {
    await tester.tap(
      inSplit(find.bySemanticsLabel(RegExp('用途${'一二三四五'[row - 1]}分类'))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('拆分页展示的是**从详情页传来的那一笔**，不是样例', (WidgetTester tester) async {
    await openSplit(tester);

    expect(inSplit(find.text('拆分消费')), findsOneWidget);
    // 商户与时间来自真实交易。
    expect(inSplit(find.textContaining('MANNER COFFEE')), findsOneWidget);
    // 原始金额也是真实的那一笔（¥28.00），且已按现有分配回填成一行。
    expect(inSplit(find.text('28.00')), findsWidgets);
    // 未选用途时不能提交。
    await tester.tap(inSplit(find.text('确认拆分')));
    await tester.pumpAndSettle();
    expect(
      (await repository.dataset(ledgerId: ledgerId)).allocationsOf(firstCardId),
      isEmpty,
      reason: '没选用途就点提交，不能写进任何分配',
    );
  });

  testWidgets('选好用途与金额后确认拆分，真的写进两条分配', (WidgetTester tester) async {
    await openSplit(tester);

    // 第一行：餐饮 18.00（先把回填的全额改小，否则合计对不上）。
    await chooseCategory(tester, 1, '餐饮');
    await tester.enterText(inSplit(find.byType(TextField)).first, '18.00');
    await tester.pumpAndSettle();

    // 第二行：购物 10.00。
    await tester.tap(inSplit(find.text('增加一项用途')));
    await tester.pumpAndSettle();
    await chooseCategory(tester, 2, '购物');
    await tester.enterText(inSplit(find.byType(TextField)).at(1), '10.00');
    await tester.pumpAndSettle();

    // 合计精确相等，界面先说清楚。
    expect(inSplit(find.text('剩余 ¥0.00')), findsOneWidget);

    await tester.tap(inSplit(find.text('确认拆分')));
    await tester.pumpAndSettle();

    final allocations =
        (await repository.dataset(ledgerId: ledgerId)).allocationsOf(firstCardId);
    expect(allocations, hasLength(2));
    expect(
      allocations.map((allocation) => allocation.amountCents).toList()..sort(),
      <int>[1000, 1800],
    );
    expect(
      allocations.map((allocation) => allocation.categoryId).toSet(),
      <int>{SeedCategoryIds.food, SeedCategoryIds.shopping},
    );
    // 保存后离开拆分页。
    expect(find.byType(SplitScreen), findsNothing);
  });

  testWidgets('合计不等于原始金额时不能提交', (WidgetTester tester) async {
    await openSplit(tester);

    await chooseCategory(tester, 1, '餐饮');
    await tester.enterText(inSplit(find.byType(TextField)).first, '20.00');
    await tester.pumpAndSettle();

    expect(inSplit(find.text('剩余 ¥8.00')), findsOneWidget);
    await tester.tap(inSplit(find.text('确认拆分')));
    await tester.pumpAndSettle();

    expect(
      (await repository.dataset(ledgerId: ledgerId)).allocationsOf(firstCardId),
      isEmpty,
    );
    expect(find.byType(SplitScreen), findsOneWidget, reason: '没保存就不该离开');
  });

  testWidgets('已拆过的记录再进来时回填原来的分配', (WidgetTester tester) async {
    // 先用仓库把第一笔拆成 18.00 + 10.00。
    await repository.split(
      ledgerId: ledgerId,
      month: DemoLedgerSeed.month,
      transactionId: firstCardId,
      items: <AllocationDraft>[
        const AllocationDraft(categoryId: SeedCategoryIds.food, amountCents: 1800),
        const AllocationDraft(categoryId: SeedCategoryIds.shopping, amountCents: 1000),
      ],
    );

    await pushSplit(tester, firstCardId);

    // 两行都在，且金额就是原来那两条 —— 改一项不用从头再输一遍。
    expect(inSplit(find.byType(TextField)), findsNWidgets(2));
    expect(inSplit(find.text('18.00')), findsWidgets);
    expect(inSplit(find.text('10.00')), findsWidgets);
    expect(inSplit(find.text('剩余 ¥0.00')), findsOneWidget);
    expect(inSplit(find.text('确认拆分')), findsOneWidget);
  });
}
