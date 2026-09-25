import 'package:flutter_test/flutter_test.dart';
import 'package:younum/core/time/statistics_time.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/allocation.dart';
import 'package:younum/domain/models/ledger_source.dart';
import 'package:younum/domain/models/ledger_transaction.dart';
import 'package:younum/domain/models/year_month.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/features/organize/review_session.dart';

/// 拆分消费的退款分配（指南 3.5.5）。
///
/// 规则本身早就写好了（`RefundRules.validateRefundAllocations`）并有单测，
/// 但仓库层当时是**直接拒绝**拆分过的原消费：能力在、用户走不到。
/// 这些用例锁住「明确分配之后真的能关联，而且分配合计落库」。
void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late ReviewSession session;

  const int ledgerId = DemoLedgerSeed.demoLedgerId;
  final YearMonth september = DemoLedgerSeed.month;

  setUp(() async {
    store = InMemoryLedgerStore();
    repository = LedgerRepository(store);
    await repository.initialize();
    session = ReviewSession(repository: repository);
    await session.useLedger(isDemo: true);
  });

  tearDown(() => session.dispose());

  /// 把这个月第一笔消费拆成两项，返回 (原消费 ID, 两项分配)。
  Future<(int, List<Allocation>)> splitFirstCard() async {
    final original = session.current!;
    expect(
      await session.splitTransaction(
        transactionId: original.id,
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
      isTrue,
    );
    final dataset = await store.dataset(
      ledgerId: ledgerId,
      months: <YearMonth>{september},
    );
    return (original.id, dataset.allocationsOf(original.id));
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
          sourceTransactionId: 'refund-alloc-$day',
        ),
      );

  Future<List<RefundAllocation>> refundAllocationsOf(int refundId) async {
    // 连接与退款分配只在**按月**取数时才带出来（见 `LedgerStore.dataset`）。
    final dataset = await store.dataset(
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

  test('拆分消费：给出明确分配后能关联，并落库', () async {
    final (originalId, items) = await splitFirstCard();
    final refundId = await insertRefund(amountCents: 1000);

    final outcome = await repository.linkRefundAndResolve(
      ledgerId: ledgerId,
      month: september,
      refundTransactionId: refundId,
      originalTransactionId: originalId,
      allocations: <RefundAllocationDraft>[
        RefundAllocationDraft(originalAllocationId: items[0].id, amountCents: 600),
        RefundAllocationDraft(originalAllocationId: items[1].id, amountCents: 400),
      ],
    );

    expect(outcome, isA<ReviewSucceeded>(), reason: '$outcome');

    final saved = await refundAllocationsOf(refundId);
    expect(saved, hasLength(2));
    expect(
      saved.fold<int>(0, (sum, item) => sum + item.amountCents),
      1000,
      reason: '分配合计要精确等于退款金额',
    );
    expect(
      saved.map((item) => item.originalAllocationId).toSet(),
      <int>{items[0].id, items[1].id},
    );
  });

  test('拆分消费：合计不等于退款金额时被拒，并且什么都没写', () async {
    final (originalId, items) = await splitFirstCard();
    final refundId = await insertRefund(amountCents: 1000);

    final outcome = await repository.linkRefundAndResolve(
      ledgerId: ledgerId,
      month: september,
      refundTransactionId: refundId,
      originalTransactionId: originalId,
      allocations: <RefundAllocationDraft>[
        RefundAllocationDraft(originalAllocationId: items[0].id, amountCents: 600),
        RefundAllocationDraft(originalAllocationId: items[1].id, amountCents: 300),
      ],
    );

    expect(outcome, isA<ReviewRejected>());
    expect((outcome as ReviewRejected).message, contains('精确等于'));
    expect(await refundAllocationsOf(refundId), isEmpty);
    expect((await store.transactionById(refundId))!.nature, TransactionNature.refund);
  });

  test('拆分消费：不给出分配时被拒（不能靠猜）', () async {
    final (originalId, _) = await splitFirstCard();
    final refundId = await insertRefund();

    final outcome = await repository.linkRefundAndResolve(
      ledgerId: ledgerId,
      month: september,
      refundTransactionId: refundId,
      originalTransactionId: originalId,
    );

    expect(outcome, isA<ReviewRejected>());
    expect((outcome as ReviewRejected).message, contains('抵扣哪几项'));
  });

  test('单项抵扣不能超过该项自己的金额', () async {
    final (originalId, items) = await splitFirstCard();
    final refundId = await insertRefund(amountCents: 2000);

    final outcome = await repository.linkRefundAndResolve(
      ledgerId: ledgerId,
      month: september,
      refundTransactionId: refundId,
      originalTransactionId: originalId,
      allocations: <RefundAllocationDraft>[
        // 这一项只有 1400，却抵 1600。
        RefundAllocationDraft(originalAllocationId: items[0].id, amountCents: 1600),
        RefundAllocationDraft(originalAllocationId: items[1].id, amountCents: 400),
      ],
    );

    expect(outcome, isA<ReviewRejected>());
    expect((outcome as ReviewRejected).message, contains('超过了它原本的金额'));
  });

  test('已经抵过的那一项，第二笔退款只能抵剩下的额度', () async {
    final (originalId, items) = await splitFirstCard();

    final first = await insertRefund(amountCents: 1400, day: 25);
    expect(
      await repository.linkRefundAndResolve(
        ledgerId: ledgerId,
        month: september,
        refundTransactionId: first,
        originalTransactionId: originalId,
        allocations: <RefundAllocationDraft>[
          RefundAllocationDraft(
            originalAllocationId: items[0].id,
            amountCents: 1400,
          ),
        ],
      ),
      isA<ReviewSucceeded>(),
      reason: '第一笔把第一项抵满',
    );

    final second = await insertRefund(amountCents: 100, day: 26);
    final outcome = await repository.linkRefundAndResolve(
      ledgerId: ledgerId,
      month: september,
      refundTransactionId: second,
      originalTransactionId: originalId,
      allocations: <RefundAllocationDraft>[
        // 第一项已经抵满 1400，这里只能抵第二项。
        RefundAllocationDraft(originalAllocationId: items[0].id, amountCents: 100),
      ],
    );

    expect(outcome, isA<ReviewRejected>(), reason: '抵满的那一项不能再抵');
    expect(
      await repository.linkRefundAndResolve(
        ledgerId: ledgerId,
        month: september,
        refundTransactionId: second,
        originalTransactionId: originalId,
        allocations: <RefundAllocationDraft>[
          RefundAllocationDraft(
            originalAllocationId: items[1].id,
            amountCents: 100,
          ),
        ],
      ),
      isA<ReviewSucceeded>(),
      reason: '换成还有额度的第二项就该成功',
    );
  });

  test('原消费还没有用途时明确拒绝，并告诉用户先去定用途', () async {
    // 造一笔没有分类的消费：导入进来的记录大多如此。
    final bare = await store.insertTransaction(
      LedgerTransaction(
        id: LedgerTransaction.idUnassigned,
        ledgerId: ledgerId,
        occurredAtMs: StatisticsTime.epochMsFor(2026, 9, 20, 12),
        amountCents: 3000,
        merchant: '还没归类的消费',
        nature: TransactionNature.expense,
        reviewStatus: ReviewStatus.pending,
        timeZone: StatisticsTime.timeZone,
        sourceNamespace: LedgerSource.wechat,
        sourceTransactionId: 'bare-1',
      ),
    );
    final refundId = await insertRefund();

    final outcome = await repository.linkRefundAndResolve(
      ledgerId: ledgerId,
      month: september,
      refundTransactionId: refundId,
      originalTransactionId: bare,
    );

    expect(outcome, isA<ReviewRejected>());
    expect(
      (outcome as ReviewRejected).message,
      contains('还没有用途'),
      reason: '要说清下一步做什么，而不是只说不行',
    );
  });

  test('解除关联会把退款分配一起清掉', () async {
    final (originalId, items) = await splitFirstCard();
    final refundId = await insertRefund();

    await repository.linkRefundAndResolve(
      ledgerId: ledgerId,
      month: september,
      refundTransactionId: refundId,
      originalTransactionId: originalId,
      allocations: <RefundAllocationDraft>[
        RefundAllocationDraft(originalAllocationId: items[0].id, amountCents: 1000),
      ],
    );
    expect(await refundAllocationsOf(refundId), hasLength(1));

    expect(
      await repository.unlinkRefund(
        ledgerId: ledgerId,
        refundTransactionId: refundId,
      ),
      isA<ReviewSucceeded>(),
    );

    expect(
      await refundAllocationsOf(refundId),
      isEmpty,
      reason: '连接没了，挂在它上面的退款分配也不能留着',
    );
  });
}
