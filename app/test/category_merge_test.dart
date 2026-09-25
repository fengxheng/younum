import 'package:flutter_test/flutter_test.dart';
import 'package:younum/core/time/statistics_time.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/allocation.dart';
import 'package:younum/domain/models/category.dart';
import 'package:younum/domain/models/ledger_source.dart';
import 'package:younum/domain/models/ledger_transaction.dart';
import 'package:younum/domain/models/year_month.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/domain/rules/category_rules.dart';

/// 分类合并（指南 3.5.8：「分类删除默认归档，历史引用继续有效。
/// 重命名保留稳定 ID；**分类合并需显式迁移分配关系**」）。
///
/// 这里锁住的是最容易出错、也最不该出错的那部分：**真的把账搬过去**。
/// 归档只要改一个布尔值，合并却要把 `allocation` 行搬走、还要照顾
/// 指在具体拆分项上的 `refund_allocation`。搬错了用户会看到
/// 「分类没了、钱也不知道去哪了」。
void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;

  const int ledgerId = DemoLedgerSeed.demoLedgerId;
  final YearMonth september = DemoLedgerSeed.month;

  setUp(() async {
    store = InMemoryLedgerStore();
    repository = LedgerRepository(store);
    await repository.initialize();
  });

  Future<List<Category>> categories() =>
      repository.categories(ledgerId: ledgerId);

  Future<Category> categoryNamed(String name) async {
    final all = await categories();
    return all.firstWhere((category) => category.name == name);
  }

  Future<int> firstCardId() async {
    final snapshot = await repository.loadSnapshot(
      ledgerId: ledgerId,
      month: september,
    );
    return snapshot.current!.id;
  }

  /// 这笔记录当前的分配合计与项数。
  Future<List<Allocation>> allocationsOf(int transactionId) async {
    final dataset = await repository.dataset(
      ledgerId: ledgerId,
      months: <YearMonth>{september},
    );
    return dataset.allocationsOf(transactionId);
  }

  /// 把第一笔消费拆成「餐饮 + 购物」。两个都是种子里的**一级**分类。
  Future<(int, List<Allocation>)> splitIntoTracking() async {
    final transactionId = await firstCardId();
    final outcome = await repository.split(
      ledgerId: ledgerId,
      month: september,
      transactionId: transactionId,
      items: const <AllocationDraft>[
        AllocationDraft(categoryId: SeedCategoryIds.food, amountCents: 1400),
        AllocationDraft(
          categoryId: SeedCategoryIds.shopping,
          amountCents: 1400,
        ),
      ],
    );
    expect(outcome, isA<ReviewSucceeded>(), reason: '$outcome');
    return (transactionId, await allocationsOf(transactionId));
  }

  Future<int> insertRefund({int amountCents = 1000, int day = 25}) =>
      store.insertTransaction(
        LedgerTransaction(
          id: LedgerTransaction.idUnassigned,
          ledgerId: ledgerId,
          occurredAtMs: StatisticsTime.epochMsFor(2026, 9, day, 12),
          amountCents: amountCents,
          merchant: '退款 · 某笔消费',
          nature: TransactionNature.refund,
          reviewStatus: ReviewStatus.pending,
          timeZone: StatisticsTime.timeZone,
          sourceNamespace: LedgerSource.alipay,
          sourceTransactionId: 'merge-refund-$day',
        ),
      );

  Future<List<RefundAllocation>> refundAllocationsOf(int refundId) async {
    final dataset = await repository.dataset(
      ledgerId: ledgerId,
      months: <YearMonth>{september},
    );
    final link = dataset.linkForRefund(refundId);
    if (link == null) return const <RefundAllocation>[];
    return <RefundAllocation>[
      for (final allocation in dataset.refundAllocations)
        if (allocation.refundLinkId == link.id) allocation,
    ];
  }

  group('规则', () {
    const roots = <Category>[
      Category(
        id: 1,
        name: '餐饮',
        iconType: CategoryIconType.builtin,
        iconKey: 'food',
        sortOrder: 1,
        isBuiltin: true,
      ),
      Category(
        id: 2,
        name: '购物',
        iconType: CategoryIconType.builtin,
        iconKey: 'shopping',
        sortOrder: 2,
        isBuiltin: true,
      ),
      Category(
        id: 11,
        parentId: 1,
        name: '咖啡茶饮',
        iconType: CategoryIconType.builtin,
        iconKey: 'coffee',
        sortOrder: 1,
        isBuiltin: true,
      ),
      Category(
        id: 12,
        parentId: 1,
        name: '早餐',
        iconType: CategoryIconType.builtin,
        iconKey: 'breakfast',
        sortOrder: 2,
        isBuiltin: true,
      ),
    ];

    test('同层级、目标存在且未归档才放行', () {
      // 一级 → 一级：可以。源用「购物」—— 它下面没有细分用途，
      // 否则会先被「源还有子级」那一条挡下（那是另一个用例的事）。
      expect(
        CategoryRules.validateMerge(source: roots[1], all: roots, targetId: 1),
        isNull,
      );
      // 同父级的细分 → 细分：可以。
      expect(
        CategoryRules.validateMerge(source: roots[2], all: roots, targetId: 12),
        isNull,
      );
      // 自己 → 自己：不行。
      expect(
        CategoryRules.validateMerge(source: roots[1], all: roots, targetId: 2),
        isA<CategoryMergeSelf>(),
      );
      // 没选目标：不行。
      expect(
        CategoryRules.validateMerge(
          source: roots[1],
          all: roots,
          targetId: null,
        ),
        isA<CategoryMergeTargetMissing>(),
      );
      // 目标不存在：不行。
      expect(
        CategoryRules.validateMerge(
          source: roots[1],
          all: roots,
          targetId: 999,
        ),
        isA<CategoryMergeTargetMissing>(),
      );
    });

    test('跨层级不让合：一级并进别人的细分，那笔账以后根本找不到', () {
      expect(
        CategoryRules.validateMerge(source: roots[1], all: roots, targetId: 11),
        isA<CategoryMergeLevelMismatch>(),
      );
      // 反过来也不行。
      expect(
        CategoryRules.validateMerge(source: roots[2], all: roots, targetId: 2),
        isA<CategoryMergeLevelMismatch>(),
      );
    });

    test('目标已归档时不给合：那等于把账藏进「已归档」里', () {
      // 只放两个一级分类：子级不在列表里，「源还有子级」就不会先插队。
      final all = <Category>[roots[0], roots[1].copyWith(archived: true)];
      expect(
        CategoryRules.validateMerge(source: all[0], all: all, targetId: 2),
        isA<CategoryMergeTargetArchived>(),
      );
    });

    test('源下面还有细分用途时不给合：子级的账不会跟着搬，会被藏在归档的父级下', () {
      expect(
        CategoryRules.validateMerge(source: roots[0], all: roots, targetId: 2),
        isA<CategoryMergeHasChildren>(),
        reason: '「餐饮」下面还有咖啡茶饮和早餐',
      );
      // 源侧的问题单独也能问出来（界面靠它决定入口置不置灰）。
      expect(
        CategoryRules.mergeSourceBlocked(source: roots[0], all: roots),
        isA<CategoryMergeHasChildren>(),
      );
      expect(
        CategoryRules.mergeSourceBlocked(source: roots[1], all: roots),
        isNull,
      );
    });

    test('候选列表与校验用的是同一份规则：列出来的都能直接点', () {
      final onlyRoots = <Category>[roots[0], roots[1]];
      final targets = CategoryRules.mergeTargets(
        source: roots[1],
        all: onlyRoots,
      );
      expect(targets.map((category) => category.id), <int>[1]);
      expect(
        CategoryRules.validateMerge(
          source: roots[1],
          all: onlyRoots,
          targetId: targets.single.id,
        ),
        isNull,
      );

      // 源自己有子级时，一个候选都不给 —— 而不是列出一堆点下去会被拒的。
      expect(CategoryRules.mergeTargets(source: roots[0], all: roots), isEmpty);
    });
  });

  group('真的把账搬过去', () {
    test('迁移分配 + 归档源分类，并如实报回「搬了几笔」', () async {
      // 源用「购物」：它下面没有细分用途。
      // （「餐饮」不能当源 —— 它下面还有咖啡茶饮和早餐，会被规则拦下。）
      final transactionId = await firstCardId();
      final confirmed = await repository.confirm(
        ledgerId: ledgerId,
        month: september,
        transactionId: transactionId,
        categoryId: SeedCategoryIds.shopping,
      );
      expect(confirmed, isA<ReviewSucceeded>(), reason: '$confirmed');

      final food = await categoryNamed('餐饮');

      final result = await repository.mergeCategories(
        ledgerId: ledgerId,
        sourceId: SeedCategoryIds.shopping,
        targetId: food.id,
      );

      expect(result, isA<CategoryMerged>(), reason: '$result');
      final merged = result as CategoryMerged;
      expect(merged.movedTransactions, 1);
      expect(merged.targetName, '餐饮');

      final items = await allocationsOf(transactionId);
      expect(items, hasLength(1));
      expect(
        items.single.categoryId,
        food.id,
        reason: '账目要真的改成目标分类，不是在统计里悄悄换算',
      );
      expect(items.single.amountCents, 2800, reason: '迁移不改金额');

      // 源分类按指南 3.5.8 的默认语义归档，不删。
      final all = await categories();
      final shopping = all.firstWhere(
        (category) => category.id == SeedCategoryIds.shopping,
      );
      expect(shopping.archived, isTrue);
      expect(
        all.map((category) => category.id),
        contains(SeedCategoryIds.shopping),
        reason: '归档不是删除：行还在，历史引用才有地方落',
      );
    });

    test('同一笔交易同时拆给了源和目标：金额相加，不撞唯一索引，合计不变', () async {
      // allocation(transaction_id, category_id) 上有唯一索引。
      // 直接把源那行改成目标会撞上，所以必须先合流再删。
      final (transactionId, before) = await splitIntoTracking();
      expect(before, hasLength(2));
      final total = before.fold<int>(0, (sum, item) => sum + item.amountCents);

      final result = await repository.mergeCategories(
        ledgerId: ledgerId,
        sourceId: SeedCategoryIds.shopping,
        targetId: SeedCategoryIds.food,
      );
      expect(result, isA<CategoryMerged>(), reason: '$result');
      expect((result as CategoryMerged).movedTransactions, 1);

      final after = await allocationsOf(transactionId);
      expect(after, hasLength(1), reason: '同一笔交易不能对同一分类出现两项（指南 4.3 的重复拆分项）');
      expect(after.single.categoryId, SeedCategoryIds.food);
      expect(after.single.amountCents, total, reason: '相加正好保住分配合计');
      expect(
        after.single.amountCents,
        before
                .firstWhere((item) => item.categoryId == SeedCategoryIds.food)
                .amountCents +
            before
                .firstWhere(
                  (item) => item.categoryId == SeedCategoryIds.shopping,
                )
                .amountCents,
      );
    });

    test('退款分配跟着走：改指向目标那一项，合计仍然是退款金额', () async {
      // 最难的一条：refund_allocation 指在**具体的拆分项**上，
      // 而合并会把源那一项删掉（ON DELETE RESTRICT，不处理就直接报错）。
      final (originalId, items) = await splitIntoTracking();
      final foodItem = items.firstWhere(
        (item) => item.categoryId == SeedCategoryIds.food,
      );
      final shoppingItem = items.firstWhere(
        (item) => item.categoryId == SeedCategoryIds.shopping,
      );

      final refundId = await insertRefund(amountCents: 1000);
      final linked = await repository.linkRefundAndResolve(
        ledgerId: ledgerId,
        month: september,
        refundTransactionId: refundId,
        originalTransactionId: originalId,
        allocations: <RefundAllocationDraft>[
          RefundAllocationDraft(
            originalAllocationId: foodItem.id,
            amountCents: 600,
          ),
          RefundAllocationDraft(
            originalAllocationId: shoppingItem.id,
            amountCents: 400,
          ),
        ],
      );
      expect(linked, isA<ReviewSucceeded>(), reason: '$linked');

      final result = await repository.mergeCategories(
        ledgerId: ledgerId,
        sourceId: SeedCategoryIds.shopping,
        targetId: SeedCategoryIds.food,
      );
      expect(result, isA<CategoryMerged>(), reason: '$result');

      final after = await allocationsOf(originalId);
      expect(after, hasLength(1));
      final survivor = after.single;
      expect(survivor.categoryId, SeedCategoryIds.food);
      expect(survivor.amountCents, 2800);

      final refundAllocations = await refundAllocationsOf(refundId);
      expect(refundAllocations, isNotEmpty, reason: '退款分配不能被合并吃掉');
      expect(
        refundAllocations.every(
          (allocation) => allocation.originalAllocationId == survivor.id,
        ),
        isTrue,
        reason: '源那一项已经不存在了，退款分配必须改指向留下来的那一项',
      );
      expect(
        refundAllocations.fold<int>(0, (sum, item) => sum + item.amountCents),
        1000,
        reason: '分配合计必须仍然等于退款金额（指南 3.5.5）',
      );
      for (final allocation in refundAllocations) {
        expect(
          allocation.amountCents,
          lessThanOrEqualTo(survivor.amountCents),
          reason: '单项累计抵扣不能超过它原本的金额（指南 3.5.5）',
        );
      }

      // 合并之后这笔消费还能正常展示：分配与退款关联都没有变味。
      final dataset = await repository.dataset(
        ledgerId: ledgerId,
        months: <YearMonth>{september},
      );
      expect(dataset.linkForRefund(refundId), isNotNull);
      expect(dataset.allocationsOf(originalId), hasLength(1));
    });

    test('没有账目的分类也能合：报回 0 而不是编一个数字', () async {
      final created = await repository.createCategory(
        ledgerId: ledgerId,
        name: '养花',
        iconKey: 'leaf',
      );
      final empty = (created as CategorySaved).category;

      final result = await repository.mergeCategories(
        ledgerId: ledgerId,
        sourceId: empty.id,
        targetId: SeedCategoryIds.food,
      );

      expect(result, isA<CategoryMerged>(), reason: '$result');
      expect((result as CategoryMerged).movedTransactions, 0);
      final all = await categories();
      expect(
        all.firstWhere((category) => category.id == empty.id).archived,
        isTrue,
        reason: '空分类一样归档，否则它永远留在用途列表里',
      );
    });
  });

  group('拒绝时什么都不写', () {
    test('并到自己、并到已归档的分类：都被拒，库里的状态不变', () async {
      final before = await categories();

      // 源统一用「购物」：它下面没有细分用途，
      // 免得每条拒绝都先被「源还有子级」那条规则接下。
      final self = await repository.mergeCategories(
        ledgerId: ledgerId,
        sourceId: SeedCategoryIds.shopping,
        targetId: SeedCategoryIds.shopping,
      );
      expect(self, isA<CategoryMergeRejected>());
      expect(
        (self as CategoryMergeRejected).message,
        contains('自己'),
        reason: '不能合并到自己',
      );

      await repository.setCategoryArchived(
        ledgerId: ledgerId,
        categoryId: SeedCategoryIds.food,
        archived: true,
      );
      final archivedStates = await categories();

      final intoArchived = await repository.mergeCategories(
        ledgerId: ledgerId,
        sourceId: SeedCategoryIds.shopping,
        targetId: SeedCategoryIds.food,
      );
      expect(intoArchived, isA<CategoryMergeRejected>());
      expect((intoArchived as CategoryMergeRejected).message, contains('已归档'));

      final after = await categories();
      expect(after, hasLength(before.length));
      for (final category in after) {
        final original = archivedStates.firstWhere(
          (item) => item.id == category.id,
        );
        expect(category.archived, original.archived, reason: '被拒之后连归档状态都不能动');
      }
    });

    test('源下面还有细分用途：被拒，而且子级和账目都没动', () async {
      final all = await categories();
      final foodChildren = <Category>[
        for (final category in all)
          if (category.parentId == SeedCategoryIds.food && !category.archived)
            category,
      ];
      expect(foodChildren, isNotEmpty, reason: '前提：餐饮下面确实有细分用途');

      final transactionId = await firstCardId();
      await repository.confirm(
        ledgerId: ledgerId,
        month: september,
        transactionId: transactionId,
        categoryId: SeedCategoryIds.food,
      );

      final result = await repository.mergeCategories(
        ledgerId: ledgerId,
        sourceId: SeedCategoryIds.food,
        targetId: SeedCategoryIds.shopping,
      );
      expect(result, isA<CategoryMergeRejected>());
      expect((result as CategoryMergeRejected).message, contains('细分用途'));

      final items = await allocationsOf(transactionId);
      expect(
        items.single.categoryId,
        SeedCategoryIds.food,
        reason: '被拒的合并不许动账',
      );
      final after = await categories();
      expect(
        after
            .firstWhere((category) => category.id == SeedCategoryIds.food)
            .archived,
        isFalse,
      );
      for (final child in foodChildren) {
        expect(
          after.firstWhere((item) => item.id == child.id).archived,
          isFalse,
        );
      }
    });

    test('找不到源分类：明确拒绝', () async {
      final result = await repository.mergeCategories(
        ledgerId: ledgerId,
        sourceId: 99999,
        targetId: SeedCategoryIds.food,
      );
      expect(result, isA<CategoryMergeRejected>());
      expect((result as CategoryMergeRejected).message, contains('找不到'));
    });
  });
}
