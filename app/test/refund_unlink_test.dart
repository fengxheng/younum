import 'package:flutter_test/flutter_test.dart';
import 'package:younum/core/time/statistics_time.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/ledger_source.dart';
import 'package:younum/domain/models/ledger_transaction.dart';
import 'package:younum/domain/models/year_month.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/features/organize/review_session.dart';

/// 解除退款关联（指南 3.5.7）。
///
/// 建立关联那一轮没做这件反向的事：一笔已经关联上的退款，用户既不能改回去，
/// 也不能撤销（`linkRefundAndResolve` 刻意不写撤销日志）。这里把反向做出来 ——
/// 一次写入：断连接、退款回到待核对。
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

  /// 造一笔「收到钱」的记录：导入时多半是收入，等着被标成退款。
  Future<int> insertRefund({int amountCents = 1000, int day = 25}) =>
      store.insertTransaction(
        LedgerTransaction(
          id: LedgerTransaction.idUnassigned,
          ledgerId: ledgerId,
          occurredAtMs: StatisticsTime.epochMsFor(2026, 9, day, 12),
          amountCents: amountCents,
          merchant: '退款 · 某笔消费',
          nature: TransactionNature.income,
          reviewStatus: ReviewStatus.pending,
          timeZone: StatisticsTime.timeZone,
          sourceNamespace: LedgerSource.alipay,
          sourceTransactionId: 'unlink-test-$day',
        ),
      );

  /// 本月可用于抵扣的消费。
  Future<List<LedgerTransaction>> expenses() async {
    final dataset = await repository.dataset(ledgerId: ledgerId);
    return <LedgerTransaction>[
      for (final transaction in dataset.transactions)
        if (transaction.nature.isExpense) transaction,
    ];
  }

  /// 给一笔消费定用途。
  ///
  /// 退款要抵扣到具体的分类上，所以原消费必须有用途 —— 没有用途的连接
  /// 会在仓库层被拒（「这笔消费还没有用途」）。
  Future<void> categorize(int transactionId) async {
    expect(
      await repository.confirm(
        ledgerId: ledgerId,
        month: september,
        transactionId: transactionId,
        categoryId: SeedCategoryIds.food,
      ),
      isA<ReviewSucceeded>(),
    );
  }

  /// 建好一个「已关联」的退款，返回它的 ID。
  Future<int> linkedRefund() async {
    final original = (await expenses()).first;
    await categorize(original.id);
    final refundId = await insertRefund();
    expect(
      await session.linkRefundAndResolve(
        refundTransactionId: refundId,
        originalTransactionId: original.id,
      ),
      isTrue,
    );
    return refundId;
  }

  bool inQueue(int transactionId) =>
      session.queue.any((card) => card.id == transactionId);

  test('解除关联：退款回到待整理，连接断掉', () async {
    final refundId = await linkedRefund();
    await session.reload();
    expect(inQueue(refundId), isFalse, reason: '前提：关联完就不在待整理里了');

    final outcome = await repository.unlinkRefund(
      ledgerId: ledgerId,
      refundTransactionId: refundId,
    );
    expect(outcome, isA<ReviewSucceeded>(), reason: '$outcome');

    final refund = (await store.transactionById(refundId))!;
    expect(
      refund.nature,
      TransactionNature.unknown,
      reason: '断掉之后「这是什么」要重新看，不能留着一个像是处理好的退款性质',
    );
    expect(refund.reviewStatus, ReviewStatus.pending);
    expect(await store.refundLinkOf(refundId), isNull, reason: '连接必须真的没了');

    await session.reload();
    expect(inQueue(refundId), isTrue, reason: '解除之后要回到待整理队列');
  });

  test('没有关联时明确拒绝，而不是默默成功', () async {
    final refundId = await insertRefund();

    final outcome = await repository.unlinkRefund(
      ledgerId: ledgerId,
      refundTransactionId: refundId,
    );

    expect(outcome, isA<ReviewRejected>());
    expect(
      (outcome as ReviewRejected).message,
      contains('没有关联'),
      reason: '用户点的那句「取消关联」如果什么都没取消，ta 应该知道',
    );
    expect((await store.transactionById(refundId))!.nature, TransactionNature.income);
  });

  test('解除之后可以重新关联到另一笔消费', () async {
    final refundId = await linkedRefund();
    final candidates = await expenses();
    final first = (await store.refundLinkOf(refundId))!.originalTransactionId;

    await repository.unlinkRefund(
      ledgerId: ledgerId,
      refundTransactionId: refundId,
    );

    // 换一笔金额够大、且已经有用途的消费 —— 能成功就说明旧连接真的腾开了
    // （否则会被「这笔退款已经关联过一笔消费」挡下）。
    final other = candidates.firstWhere(
      (transaction) =>
          transaction.id != first &&
          transaction.amountCents >= 1000 &&
          transaction.nature.isExpense,
    );
    await categorize(other.id);
    final again = await repository.linkRefundAndResolve(
      ledgerId: ledgerId,
      month: september,
      refundTransactionId: refundId,
      originalTransactionId: other.id,
    );

    expect(again, isA<ReviewSucceeded>(), reason: '$again');
    expect((await store.refundLinkOf(refundId))!.originalTransactionId, other.id);
  });
}
