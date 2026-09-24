import 'package:flutter_test/flutter_test.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/core/time/statistics_time.dart';
import 'package:younum/domain/models/ledger_transaction.dart';
import 'package:younum/domain/models/year_month.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';

/// 整理流程的**编排**测试。
///
/// 跑在内存存储上（`flutter test` 没有原生 SQLite 可用），验证的是：
/// 提交、稍后、重新整理、撤销、持久化、失败处理的行为是否与指南 3.3 / 10.3 一致。
///
/// 存储层自己的约束（外键、唯一约束、迁移）由真机集成测试负责。
void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;

  final ledgerId = DemoLedgerSeed.demoLedgerId;
  final month = DemoLedgerSeed.month;

  setUp(() async {
    store = InMemoryLedgerStore();
    repository = LedgerRepository(store);
    await repository.initialize();
  });

  /// 当前卡片的商户名，方便断言。
  String? currentMerchant(ReviewSnapshot snapshot) => snapshot.current?.merchant;

  test('演示账本初始为 6 笔待整理，真实账本为空', () async {
    final demo = await repository.loadSnapshot(ledgerId: ledgerId, month: month);
    expect(demo.mainQueue, hasLength(6));
    expect(demo.deferred, isEmpty);
    expect(demo.resolvedCount, 0);
    expect(demo.totalCount, 6);
    expect(currentMerchant(demo), 'MANNER COFFEE');
    expect(demo.canUndo, isFalse);

    final realLedger = await repository.ledgerFor(isDemo: false);
    final real = await repository.loadSnapshot(
      ledgerId: realLedger.id,
      month: month,
    );
    expect(real.mainQueue, isEmpty, reason: '真实账本不应该有演示数据');
    expect(real.resolvedCount, 0);
  });

  test('队列顺序按交易时间倒序，稳定可复现', () async {
    final snapshot = await repository.loadSnapshot(ledgerId: ledgerId, month: month);
    expect(
      snapshot.mainQueue.map((transaction) => transaction.merchant).toList(),
      <String>[
        'MANNER COFFEE',
        '优衣库 UNIQLO',
        '滴滴出行',
        '盒马鲜生',
        '周末电影',
        '社区药房',
      ],
    );
  });

  test('确认后完成数 +1、卡片推进、本月金额跟着变', () async {
    final snapshot = await repository.loadSnapshot(ledgerId: ledgerId, month: month);
    final current = snapshot.current!;

    final outcome = await repository.confirm(
      ledgerId: ledgerId,
      month: month,
      transactionId: current.id,
      categoryId: SeedCategoryIds.food,
    );

    expect(outcome, isA<ReviewSucceeded>());
    final next = (outcome as ReviewSucceeded).snapshot;
    expect(next.resolvedCount, 1);
    expect(currentMerchant(next), '优衣库 UNIQLO');
    expect(next.overview.summary.netExpenseCents, 2800);
    expect(next.canUndo, isTrue);
  });

  test('稍后处理不增加完成数，而是进入稍后队列', () async {
    final snapshot = await repository.loadSnapshot(ledgerId: ledgerId, month: month);
    final outcome = await repository.defer(
      ledgerId: ledgerId,
      month: month,
      transactionId: snapshot.current!.id,
    );

    final next = (outcome as ReviewSucceeded).snapshot;
    expect(next.resolvedCount, 0);
    expect(next.deferred, hasLength(1));
    expect(next.deferred.single.merchant, 'MANNER COFFEE');
    expect(currentMerchant(next), '优衣库 UNIQLO');
    expect(next.totalCount, 6);
  });

  test('撤销恢复完成数与**队列位置**，而不只是最后一笔', () async {
    // 连续确认两笔。
    for (final categoryId in <int>[
      SeedCategoryIds.food,
      SeedCategoryIds.shopping,
    ]) {
      final snapshot = await repository.loadSnapshot(ledgerId: ledgerId, month: month);
      await repository.confirm(
        ledgerId: ledgerId,
        month: month,
        transactionId: snapshot.current!.id,
        categoryId: categoryId,
      );
    }

    var snapshot = await repository.loadSnapshot(ledgerId: ledgerId, month: month);
    expect(snapshot.resolvedCount, 2);
    expect(currentMerchant(snapshot), '滴滴出行');

    // 撤销一次 → 回到第二笔。
    var outcome = await repository.undo(ledgerId: ledgerId, month: month);
    snapshot = (outcome as ReviewSucceeded).snapshot;
    expect(snapshot.resolvedCount, 1);
    expect(currentMerchant(snapshot), '优衣库 UNIQLO');

    // 再撤销一次 → 回到第一笔，且队列长度恢复。
    outcome = await repository.undo(ledgerId: ledgerId, month: month);
    snapshot = (outcome as ReviewSucceeded).snapshot;
    expect(snapshot.resolvedCount, 0);
    expect(currentMerchant(snapshot), 'MANNER COFFEE');
    expect(snapshot.mainQueue, hasLength(6));

    // 没有可撤销的了。
    final none = await repository.undo(ledgerId: ledgerId, month: month);
    expect(none, isA<ReviewRejected>());
  });

  test('撤销也能回退稍后处理，并恢复该笔原来的队列位置', () async {
    final snapshot = await repository.loadSnapshot(ledgerId: ledgerId, month: month);
    await repository.defer(
      ledgerId: ledgerId,
      month: month,
      transactionId: snapshot.current!.id,
    );

    final outcome = await repository.undo(ledgerId: ledgerId, month: month);
    final restored = (outcome as ReviewSucceeded).snapshot;
    expect(restored.deferred, isEmpty);
    expect(currentMerchant(restored), 'MANNER COFFEE');
    expect(restored.mainQueue, hasLength(6));
  });

  test('重新整理稍后队列后可以继续完成', () async {
    final first = await repository.loadSnapshot(ledgerId: ledgerId, month: month);
    await repository.defer(
      ledgerId: ledgerId,
      month: month,
      transactionId: first.current!.id,
    );

    // 完成其余 5 笔：主队列空了但稍后队列还有记录 —— 不是完成态。
    for (final categoryId in <int>[
      SeedCategoryIds.shopping,
      SeedCategoryIds.transport,
      SeedCategoryIds.food,
      SeedCategoryIds.entertainment,
      SeedCategoryIds.health,
    ]) {
      final snapshot = await repository.loadSnapshot(ledgerId: ledgerId, month: month);
      await repository.confirm(
        ledgerId: ledgerId,
        month: month,
        transactionId: snapshot.current!.id,
        categoryId: categoryId,
      );
    }

    var snapshot = await repository.loadSnapshot(ledgerId: ledgerId, month: month);
    expect(snapshot.resolvedCount, 5);
    expect(snapshot.mainQueue, isEmpty);
    expect(snapshot.deferred, hasLength(1));
    expect(snapshot.overview.progress.isFullyProcessed, isFalse);

    // 重新整理后回到主队列末尾。
    final reopened = await repository.reopenDeferred(ledgerId: ledgerId, month: month);
    snapshot = (reopened as ReviewSucceeded).snapshot;
    expect(snapshot.mainQueue, hasLength(1));
    expect(currentMerchant(snapshot), 'MANNER COFFEE');

    final done = await repository.confirm(
      ledgerId: ledgerId,
      month: month,
      transactionId: snapshot.current!.id,
      categoryId: SeedCategoryIds.other,
    );
    final complete = (done as ReviewSucceeded).snapshot;
    expect(complete.resolvedCount, 6);
    expect(complete.overview.progress.isFullyProcessed, isTrue);
    // 范围完整性仍然要用户确认，不能自动判定（指南 3.4）。
    expect(complete.overview.canOpenCompleteReport, isFalse);
    expect(complete.overview.isPartialMonth, isTrue);
  });

  test('全部归类后金额与指南 10.1 的基准一致', () async {
    const categories = <int>[
      SeedCategoryIds.food,
      SeedCategoryIds.shopping,
      SeedCategoryIds.transport,
      SeedCategoryIds.food,
      SeedCategoryIds.entertainment,
      SeedCategoryIds.health,
    ];
    for (final categoryId in categories) {
      final snapshot = await repository.loadSnapshot(ledgerId: ledgerId, month: month);
      await repository.confirm(
        ledgerId: ledgerId,
        month: month,
        transactionId: snapshot.current!.id,
        categoryId: categoryId,
      );
    }

    final snapshot = await repository.loadSnapshot(ledgerId: ledgerId, month: month);
    expect(snapshot.resolvedCount, 6);
    expect(snapshot.overview.summary.netExpenseCents, 63330);
    expect(snapshot.overview.summary.expenseCount, 6);
    expect(snapshot.overview.summary.categoryNetTotalCents, 63330);
    final food = snapshot.overview.summary.byCategory
        .firstWhere((category) => category.categoryId == SeedCategoryIds.food);
    expect(food.netCents, 15480);

    // 用户确认范围完整后才是完整月报。
    await repository.setCoverageConfirmed(
      ledgerId: ledgerId,
      month: month,
      value: true,
    );
    final confirmed =
        await repository.loadSnapshot(ledgerId: ledgerId, month: month);
    expect(confirmed.overview.canOpenCompleteReport, isTrue);
    expect(confirmed.overview.isPartialMonth, isFalse);
  });

  test('进度持久化：换一个仓库实例仍然读得到已确认的进度', () async {
    final snapshot = await repository.loadSnapshot(ledgerId: ledgerId, month: month);
    await repository.confirm(
      ledgerId: ledgerId,
      month: month,
      transactionId: snapshot.current!.id,
      categoryId: SeedCategoryIds.food,
    );

    // 模拟「杀进程重启」：同一个底层存储，新的仓库实例。
    final restarted = LedgerRepository(store);
    final reloaded = await restarted.loadSnapshot(ledgerId: ledgerId, month: month);
    expect(reloaded.resolvedCount, 1);
    expect(currentMerchant(reloaded), '优衣库 UNIQLO');
    expect(reloaded.overview.summary.netExpenseCents, 2800);
    // 撤销能力也要跨重启保留（指南 3.3）。
    expect(reloaded.canUndo, isTrue);
    final undone = await restarted.undo(ledgerId: ledgerId, month: month);
    expect((undone as ReviewSucceeded).snapshot.resolvedCount, 0);
  });

  test('保存失败时返回失败结果，界面状态不变', () async {
    final snapshot = await repository.loadSnapshot(ledgerId: ledgerId, month: month);
    store.failNextWrite = StateError('磁盘写入失败');

    final outcome = await repository.confirm(
      ledgerId: ledgerId,
      month: month,
      transactionId: snapshot.current!.id,
      categoryId: SeedCategoryIds.food,
    );

    expect(outcome, isA<ReviewFailed>());
    final after = await repository.loadSnapshot(ledgerId: ledgerId, month: month);
    expect(after.resolvedCount, 0);
    expect(currentMerchant(after), 'MANNER COFFEE');
  });

  test('撤销遇到版本冲突时明确失败，不覆盖新数据', () async {
    final snapshot =
        await repository.loadSnapshot(ledgerId: ledgerId, month: month);
    final target = snapshot.current!;
    await repository.confirm(
      ledgerId: ledgerId,
      month: month,
      transactionId: target.id,
      categoryId: SeedCategoryIds.food,
    );

    // 模拟「别的页面又改了这笔」：走一次带版本校验的修改。
    final changed = await store.transactionById(target.id);
    final updated = await store.updateTransaction(
      transaction: changed!.copyWith(
        reviewStatus: ReviewStatus.pending,
        version: changed.version + 1,
      ),
      expectedVersion: changed.version,
    );
    expect(updated, isTrue);

    final outcome = await repository.undo(ledgerId: ledgerId, month: month);
    expect(outcome, isA<ReviewConflict>());
    expect((outcome as ReviewConflict).message, contains('又被修改过'));

    // 那条操作日志应被标记失效，不会反复尝试。
    final again = await repository.undo(ledgerId: ledgerId, month: month);
    expect(again, isA<ReviewRejected>());
  });

  test('有关联退款时拒绝撤销原消费，避免退款去抵扣不存在的消费', () async {
    final snapshot =
        await repository.loadSnapshot(ledgerId: ledgerId, month: month);
    final target = snapshot.current!;
    await repository.confirm(
      ledgerId: ledgerId,
      month: month,
      transactionId: target.id,
      categoryId: SeedCategoryIds.food,
    );

    final refundId = await store.insertTransaction(
      (await store.transactionById(target.id))!.copyWith(
        id: LedgerTransaction.idUnassigned,
        merchant: '退款',
        nature: TransactionNature.refund,
        sourceTransactionId: 'refund-undo-guard',
      ),
    );
    expect(
      await repository.linkRefund(
        ledgerId: ledgerId,
        month: month,
        refundTransactionId: refundId,
        originalTransactionId: target.id,
        amountCents: 1000,
      ),
      isA<ReviewSucceeded>(),
    );

    // 直接撤销会让「退款去抵扣一笔不再计入消费的记录」，必须拦住并说明原因。
    final outcome = await repository.undo(ledgerId: ledgerId, month: month);
    expect(outcome, isA<ReviewRejected>());
    expect((outcome as ReviewRejected).message, contains('解除退款关联'));

    final after = await repository.loadSnapshot(ledgerId: ledgerId, month: month);
    // 原消费必须仍然是「已确认 + 有分配」的状态，而不是被撤销掉。
    final original = after.dataset.transaction(target.id)!;
    expect(original.reviewStatus, ReviewStatus.resolved);
    expect(after.dataset.allocationsOf(target.id), hasLength(1));
  });

  test('月份之间互不干扰', () async {
    final october = YearMonth(2026, 10);
    final snapshot = await repository.loadSnapshot(ledgerId: ledgerId, month: october);
    expect(snapshot.mainQueue, isEmpty);
    expect(snapshot.overview.summary.hasRecords, isFalse);
    expect(snapshot.overview.summary.netExpenseCents, 0);
  });

  test('跨月退款通过仓库写入后，原消费月份的净额被正确抵扣', () async {
    // 先把 6 笔全部归类。
    const categories = <int>[
      SeedCategoryIds.food,
      SeedCategoryIds.shopping,
      SeedCategoryIds.transport,
      SeedCategoryIds.food,
      SeedCategoryIds.entertainment,
      SeedCategoryIds.health,
    ];
    for (final categoryId in categories) {
      final snapshot = await repository.loadSnapshot(ledgerId: ledgerId, month: month);
      await repository.confirm(
        ledgerId: ledgerId,
        month: month,
        transactionId: snapshot.current!.id,
        categoryId: categoryId,
      );
    }

    // 10 月发生、关联 9 月优衣库的 10000 分退款。
    final uniqloIndex = DemoLedgerSeed.baseline
        .indexWhere((entry) => entry.merchant.contains('优衣库'));
    final uniqloId = DemoLedgerSeed.transactionIdAt(uniqloIndex);
    final refundId = await store.insertTransaction(
      (await store.transactionById(uniqloId))!.copyWith(
        id: LedgerTransaction.idUnassigned,
        merchant: '优衣库退款',
        nature: TransactionNature.refund,
        reviewStatus: ReviewStatus.resolved,
        amountCents: 10000,
        occurredAtMs:
            StatisticsTime.epochMsFor(2026, 10, 5, 12),
        sourceTransactionId: 'refund-uniqlo-1',
      ),
    );

    final outcome = await repository.linkRefund(
      ledgerId: ledgerId,
      month: month,
      refundTransactionId: refundId,
      originalTransactionId: uniqloId,
      amountCents: 10000,
    );
    expect(outcome, isA<ReviewSucceeded>());

    // 9 月净消费 53330。
    final september = await repository.monthOverview(ledgerId: ledgerId, month: month);
    expect(september.summary.netExpenseCents, 53330);
    expect(september.summary.refundCents, 10000);

    // 10 月不因为这笔退款变成负数，但仍能看到这笔退款记录。
    final october = await repository.monthOverview(
      ledgerId: ledgerId,
      month: YearMonth(2026, 10),
    );
    expect(october.summary.netExpenseCents, 0);
    expect(october.summary.hasRecords, isTrue);

    // 重复关联同一笔退款必须被拒绝 —— 否则会重复抵扣。
    final duplicate = await repository.linkRefund(
      ledgerId: ledgerId,
      month: month,
      refundTransactionId: refundId,
      originalTransactionId: uniqloId,
      amountCents: 10000,
    );
    expect(duplicate, isA<ReviewRejected>());

    final stillSeptember =
        await repository.monthOverview(ledgerId: ledgerId, month: month);
    expect(stillSeptember.summary.netExpenseCents, 53330);

    // 超过原消费剩余额度的退款也必须被拒绝。
    final secondRefundId = await store.insertTransaction(
      (await store.transactionById(uniqloId))!.copyWith(
        id: LedgerTransaction.idUnassigned,
        merchant: '优衣库超额退款',
        nature: TransactionNature.refund,
        reviewStatus: ReviewStatus.resolved,
        amountCents: 25000,
        sourceTransactionId: 'refund-uniqlo-2',
      ),
    );
    final over = await repository.linkRefund(
      ledgerId: ledgerId,
      month: month,
      refundTransactionId: secondRefundId,
      originalTransactionId: uniqloId,
      amountCents: 25000,
    );
    expect(over, isA<ReviewRejected>());
    expect((over as ReviewRejected).message, contains('超过原消费金额'));

    final unchanged =
        await repository.monthOverview(ledgerId: ledgerId, month: month);
    expect(unchanged.summary.netExpenseCents, 53330);
  });
}
