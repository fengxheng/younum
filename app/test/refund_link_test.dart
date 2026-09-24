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

/// 退款关联（「收到退款」那次提交）。
///
/// 指南 3.5：退款抵扣原消费；跨月退款归回原消费月份；拆分过的消费需要
/// 指定退款分配。这里走真仓库（后端换内存存储），所以也是界面那条路径。
void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late ReviewSession session;

  final YearMonth september = DemoLedgerSeed.month;
  final YearMonth august = YearMonth(2026, 8);
  const int ledgerId = DemoLedgerSeed.demoLedgerId;

  setUp(() async {
    store = InMemoryLedgerStore();
    repository = LedgerRepository(store);
    await repository.initialize();
    session = ReviewSession(repository: repository);
    await session.useLedger(isDemo: true);
  });

  tearDown(() {
    session.dispose();
  });

  /// 造一笔退款（默认落在 9 月、待整理）。
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
          sourceTransactionId: 'refund-test-$day',
        ),
      );

  Future<LedgerTransaction> reload(int id) async =>
      (await repository.dataset(ledgerId: ledgerId)).transaction(id)!;

  /// 退款有没有关联过。
  ///
  /// 两个要点，都是实现的真实语义，不是绕开检查：
  /// 1. 必须**按月**取数：`dataset()` 不给月份时只返回交易，不带退款连接。
  /// 2. 连接是跟着**原消费**所在的月份带出来的，跨月退款要把两个月都给上。
  Future<bool> hasLink(int refundId) async {
    final dataset = await store.dataset(
      ledgerId: ledgerId,
      months: <YearMonth>{september, august},
    );
    return dataset.refundLinks.any(
      (link) => link.refundTransactionId == refundId,
    );
  }

  test('关联之后：性质变退款、处理完成、离开待整理队列', () async {
    // 原消费先归类，退款才有「抵扣到哪一笔」可说。
    final original = session.current!;
    await session.saveDetails(
      transactionId: original.id,
      note: null,
      categoryId: SeedCategoryIds.food,
    );
    final refundId = await insertRefund();
    await session.reload();
    final queueBefore = session.remainingCount - 1; // 含刚进来的那笔退款
    expect(session.remainingCount, queueBefore + 1, reason: '新导入的退款也进待整理队列');

    final ok = await session.linkRefundAndResolve(
      refundTransactionId: refundId,
      originalTransactionId: original.id,
    );

    expect(ok, isTrue, reason: 'linkRefundAndResolve 返回 false：${session.lastFailure}');
    final updated = await reload(refundId);
    expect(updated.nature, TransactionNature.refund);
    expect(updated.reviewStatus, ReviewStatus.resolved);
    expect(await hasLink(refundId), isTrue);
    expect(session.remainingCount, queueBefore, reason: '退款处理完了，队列里只剩原来那几笔');
  });

  test('退款金额超过原消费剩余额度时被拒', () async {
    final original = session.current!; // 2800 分
    await session.saveDetails(
      transactionId: original.id,
      note: null,
      categoryId: SeedCategoryIds.food,
    );
    // 退款 5000 分 > 原消费 2800 分。
    final refundId = await insertRefund(amountCents: 5000);

    final outcome = await repository.linkRefundAndResolve(
      ledgerId: ledgerId,
      month: september,
      refundTransactionId: refundId,
      originalTransactionId: original.id,
    );

    expect(outcome, isA<ReviewRejected>());
    expect(await hasLink(refundId), isFalse);
    expect((await reload(refundId)).nature, TransactionNature.refund);
  });

  test('不能把退款关联到它自己', () async {
    final refundId = await insertRefund();

    final outcome = await repository.linkRefundAndResolve(
      ledgerId: ledgerId,
      month: september,
      refundTransactionId: refundId,
      originalTransactionId: refundId,
    );

    expect(outcome, isA<ReviewRejected>());
    expect(await hasLink(refundId), isFalse);
  });

  test('原消费已经不是消费（被标成转账）时被拒', () async {
    final original = session.current!;
    await session.setNature(
      transactionId: original.id,
      nature: TransactionNature.transfer,
    );
    final refundId = await insertRefund();

    final outcome = await repository.linkRefundAndResolve(
      ledgerId: ledgerId,
      month: september,
      refundTransactionId: refundId,
      originalTransactionId: original.id,
    );

    expect(outcome, isA<ReviewRejected>());
    expect(await hasLink(refundId), isFalse);
  });

  test('同一笔退款不能关联两次', () async {
    final original = session.current!;
    await session.saveDetails(
      transactionId: original.id,
      note: null,
      categoryId: SeedCategoryIds.food,
    );
    final refundId = await insertRefund();

    expect(
      await session.linkRefundAndResolve(
        refundTransactionId: refundId,
        originalTransactionId: original.id,
      ),
      isTrue,
    );

    final again = await repository.linkRefundAndResolve(
      ledgerId: ledgerId,
      month: september,
      refundTransactionId: refundId,
      originalTransactionId: original.id,
    );

    expect(again, isA<ReviewRejected>());
  });

  test('拆分过的原消费要求先指定抵扣用途，本轮明确拒绝', () async {
    final original = session.current!;
    expect(
      await session.splitTransaction(
        transactionId: original.id,
        items: <AllocationDraft>[
          const AllocationDraft(categoryId: SeedCategoryIds.food, amountCents: 1400),
          const AllocationDraft(categoryId: SeedCategoryIds.shopping, amountCents: 1400),
        ],
      ),
      isTrue,
    );
    final refundId = await insertRefund();

    final outcome = await repository.linkRefundAndResolve(
      ledgerId: ledgerId,
      month: september,
      refundTransactionId: refundId,
      originalTransactionId: original.id,
    );

    expect(outcome, isA<ReviewRejected>());
    expect(
      (outcome as ReviewRejected).message,
      contains('拆分'),
      reason: '要说清为什么不行，而不是默默建一条抵扣不到用途的连接',
    );
    expect(await hasLink(refundId), isFalse);
  });

  test('跨月退款：原消费在上个月也能关联（指南 3.5.4）', () async {
    final augustId = await store.insertTransaction(
      LedgerTransaction(
        id: LedgerTransaction.idUnassigned,
        ledgerId: ledgerId,
        occurredAtMs: StatisticsTime.epochMsFor(2026, 8, 20, 12),
        amountCents: 5000,
        merchant: '上个月的消费',
        nature: TransactionNature.expense,
        reviewStatus: ReviewStatus.resolved,
        timeZone: StatisticsTime.timeZone,
        sourceNamespace: LedgerSource.wechat,
        sourceTransactionId: 'aug-1',
      ),
    );
    // 归个类，让它有「可抵扣的分配」。
    await repository.saveDetails(
      ledgerId: ledgerId,
      month: august,
      transactionId: augustId,
      note: null,
      categoryId: SeedCategoryIds.food,
    );
    final refundId = await insertRefund(amountCents: 3000);

    final outcome = await repository.linkRefundAndResolve(
      ledgerId: ledgerId,
      month: september,
      refundTransactionId: refundId,
      originalTransactionId: augustId,
    );

    expect(
      outcome,
      isA<ReviewSucceeded>(),
      reason: 'cross-month: $outcome',
    );
    expect(await hasLink(refundId), isTrue);
  });
}



