import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/app/app.dart';
import 'package:younum/core/components/buttons.dart';
import 'package:younum/core/components/screen_scaffold.dart';
import 'package:younum/core/preferences/app_state_store.dart';
import 'package:younum/core/time/statistics_time.dart';
import 'package:younum/core/preferences/theme_controller.dart';
import 'package:younum/core/preferences/theme_store.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/allocation.dart';
import 'package:younum/domain/models/ledger_source.dart';
import 'package:younum/domain/models/ledger_transaction.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/features/organize/refund_allocation_editor.dart';
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

  testWidgets('收到退款：先选原消费才让提交，提交后落下退款关联', (WidgetTester tester) async {
    // 原消费先得有用途：退款要抵扣到具体分类上，没用途就没有可抵扣的东西
    // （仓库层会明确拒绍）。这里拿**另一笔**来当原消费，
    // 当前这笔（MANNER COFFEE）仍旧留在待整理里。
    final secondId = DemoLedgerSeed.transactionIdAt(1);
    await repository.saveDetails(
      ledgerId: ledgerId,
      month: DemoLedgerSeed.month,
      transactionId: secondId,
      note: null,
      categoryId: SeedCategoryIds.food,
    );
    final second = (await repository.dataset(
      ledgerId: ledgerId,
      months: {DemoLedgerSeed.month},
    )).transaction(secondId)!;
    // 造一笔金额正好等于原消费的退款（金额一样，抵扣额度才够）。
    await store.insertTransaction(
      LedgerTransaction(
        id: LedgerTransaction.idUnassigned,
        ledgerId: ledgerId,
        occurredAtMs: StatisticsTime.epochMsFor(2026, 9, 25, 12),
        amountCents: second.amountCents,
        merchant: '退款 · 某笔消费',
        nature: TransactionNature.income,
        reviewStatus: ReviewStatus.pending,
        timeZone: StatisticsTime.timeZone,
        sourceNamespace: LedgerSource.alipay,
        sourceTransactionId: 'refund-pick-1',
      ),
    );

    await openNature(tester);

    await tester.tap(inNature(find.text('收到退款')));
    await tester.pumpAndSettle();

    // 还没选原消费：按钮是灰的，并且说清为什么必须选。
    expect(inNature(find.textContaining('退款要关联到原消费')), findsOneWidget);
    await tester.tap(inNature(find.text('确认调整')));
    await tester.pumpAndSettle();
    expect(
      (await reload()).nature,
      TransactionNature.expense,
      reason: '没选原消费就不该写库 —— 退款抵扣不到东西就等于没记',
    );

    // 候选是「这个月的消费，除了这笔本身」。
    await tester.tap(inNature(find.text('选择原消费')));
    await tester.pumpAndSettle();

    final sheet = find.byType(BottomSheet);
    expect(sheet, findsOneWidget);
    expect(
      find.descendant(of: sheet, matching: find.textContaining('MANNER COFFEE')),
      findsNothing,
      reason: '这笔自己不能当自己的原消费，不该出现在候选里',
    );

    await tester.tap(
      find.descendant(
        of: sheet,
        matching: find.textContaining(second.merchant),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(inNature(find.text('确认调整')));
    await tester.pumpAndSettle();

    final updated = await reload();
    expect(updated.nature, TransactionNature.refund);
    expect(updated.reviewStatus, ReviewStatus.resolved);
    expect(
      find.byType(TransactionNatureScreen),
      findsNothing,
      reason: '处理完就该回到整理页，而不是停在这一页',
    );

    // 关键：性质和关联是一次写完的，不会只改性质不建连接。
    final dataset = await store.dataset(
      ledgerId: ledgerId,
      months: {DemoLedgerSeed.month},
    );
    final link = dataset.refundLinks.single;
    expect(link.refundTransactionId, firstCardId);
    expect(link.originalTransactionId, isNot(firstCardId));
  });

  testWidgets('已关联的退款：预填原消费、说清不能再关联、能取消关联', (WidgetTester tester) async {
    // 先造一笔已关联的退款 —— 这是上一块做出来的能力，这一块要做它的反向。
    // 原消费要先有用途（退款要抵扣到具体分类），用的就是当前这张卡。
    await repository.saveDetails(
      ledgerId: ledgerId,
      month: DemoLedgerSeed.month,
      transactionId: firstCardId,
      note: null,
      categoryId: SeedCategoryIds.food,
    );
    final originalId = firstCardId;
    final refundId = await store.insertTransaction(
      LedgerTransaction(
        id: LedgerTransaction.idUnassigned,
        ledgerId: ledgerId,
        occurredAtMs: StatisticsTime.epochMsFor(2026, 9, 25, 12),
        amountCents: 1000,
        merchant: '退款 · 某笔消费',
        nature: TransactionNature.income,
        reviewStatus: ReviewStatus.pending,
        timeZone: StatisticsTime.timeZone,
        sourceNamespace: LedgerSource.alipay,
        sourceTransactionId: 'unlink-ui-1',
      ),
    );
    expect(
      await repository.linkRefundAndResolve(
        ledgerId: ledgerId,
        month: DemoLedgerSeed.month,
        refundTransactionId: refundId,
        originalTransactionId: originalId,
      ),
      isA<ReviewSucceeded>(),
    );

    await tester.pumpWidget(
      YounumApp(
        themeController: themeController,
        appStateController: appStateController,
        ledgerRepository: repository,
        ledgerFileSource: const UnsupportedFileSource(),
      ),
    );
    await tester.pumpAndSettle();

    // 已处理的记录不在整理队列里，从「查看全部明细」进去。
    await tester.tap(
      find.descendant(
        of: find.byType(AppBottomBar),
        matching: find.text('整理'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is YounumIconButton &&
            widget.semanticLabel == '查看全部明细',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('退款 · 某笔消费').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('设为转账 / 收入 / 不计入'));
    await tester.pumpAndSettle();

    // 预填原消费，而不是留一个空选择器让人以为「这笔还没关联」。
    expect(inNature(find.textContaining('MANNER COFFEE')), findsWidgets);
    // 并且说清：现在这个状态不能再提交，要改关联得先取消关联。
    expect(inNature(find.textContaining('已经关联到')), findsOneWidget);
    await tester.tap(inNature(find.text('确认调整')));
    await tester.pumpAndSettle();
    expect((await store.transactionById(refundId))!.nature, TransactionNature.refund);

    // 取消关联：先问一句，再真的断。
    await tester.tap(inNature(find.text('取消退款关联')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消关联'));
    await tester.pumpAndSettle();

    expect(await store.refundLinkOf(refundId), isNull);
    final refund = (await store.transactionById(refundId))!;
    expect(refund.nature, TransactionNature.unknown);
    expect(refund.reviewStatus, ReviewStatus.pending, reason: '指南 3.5.7：恢复待核对');
  });

  testWidgets('拆分过的原消费：必须填清退款分配才能提交', (WidgetTester tester) async {
    // 把第一笔拆成两项，再造一笔待整理的退款。
    expect(
      await repository.split(
        ledgerId: ledgerId,
        month: DemoLedgerSeed.month,
        transactionId: firstCardId,
        items: <AllocationDraft>[
          const AllocationDraft(
            categoryId: SeedCategoryIds.food,
            amountCents: 1400,
          ),
          const AllocationDraft(
            categoryId: SeedCategoryIds.shopping,
            amountCents: 1400,
          ),
        ],
      ),
      isA<ReviewSucceeded>(),
    );
    final refundId = await store.insertTransaction(
      LedgerTransaction(
        id: LedgerTransaction.idUnassigned,
        ledgerId: ledgerId,
        occurredAtMs: StatisticsTime.epochMsFor(2026, 9, 25, 12),
        amountCents: 1000,
        merchant: '退款 · 某笔消费',
        nature: TransactionNature.income,
        reviewStatus: ReviewStatus.pending,
        timeZone: StatisticsTime.timeZone,
        sourceNamespace: LedgerSource.alipay,
        sourceTransactionId: 'refund-split-ui-1',
      ),
    );

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
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is YounumIconButton &&
            widget.semanticLabel == '查看全部明细',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('退款 · 某笔消费').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('设为转账 / 收入 / 不计入'));
    await tester.pumpAndSettle();

    await tester.tap(inNature(find.text('收到退款')));
    await tester.pumpAndSettle();
    await tester.tap(inNature(find.text('选择原消费')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.textContaining('MANNER COFFEE'),
      ),
    );
    await tester.pumpAndSettle();

    // 拆分消费必须说明抵扣到哪几项：编辑器出现，并且未填完不能提交。
    final editor = find.byType(RefundAllocationEditor);
    expect(editor, findsOneWidget);
    expect(
      inNature(find.textContaining('拆成了多项')),
      findsOneWidget,
      reason: '要说清为什么还不能提交',
    );
    await tester.ensureVisible(inNature(find.text('确认调整')));
    await tester.pumpAndSettle();
    await tester.tap(inNature(find.text('确认调整')));
    await tester.pumpAndSettle();
    expect(await store.refundLinkOf(refundId), isNull, reason: '没填分配就不该写库');

    // 两项合计必须精确等于退款金额（1000 分）。
    final fields = find.descendant(
      of: editor,
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), '6.00');
    await tester.pumpAndSettle();
    await tester.enterText(fields.at(1), '3.00');
    await tester.pumpAndSettle();
    await tester.ensureVisible(inNature(find.text('确认调整')));
    await tester.pumpAndSettle();
    await tester.tap(inNature(find.text('确认调整')));
    await tester.pumpAndSettle();
    expect(
      await store.refundLinkOf(refundId),
      isNull,
      reason: '合计 900 分 ≠ 退款 1000 分，不能提交',
    );

    await tester.enterText(fields.at(1), '4.00');
    await tester.pumpAndSettle();
    expect(
      inNature(find.textContaining('拆成了多项')),
      findsNothing,
      reason: '合计对上了就不该再拦着用户',
    );
    await tester.ensureVisible(inNature(find.text('确认调整')));
    await tester.pumpAndSettle();
    await tester.tap(inNature(find.text('确认调整')));
    await tester.pumpAndSettle();

    final link = await store.refundLinkOf(refundId);
    expect(link, isNotNull, reason: '合计对上了就该真的关联');
    final dataset = await store.dataset(
      ledgerId: ledgerId,
      months: {DemoLedgerSeed.month},
    );
    final allocations = <int>[
      for (final allocation in dataset.refundAllocations)
        if (allocation.refundLinkId == link!.id) allocation.amountCents,
    ];
    expect(allocations.toSet(), <int>{600, 400});
  });
}





