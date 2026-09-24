import 'package:younum/core/time/statistics_time.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/allocation.dart';
import 'package:younum/domain/models/category.dart';
import 'package:younum/domain/models/ledger_dataset.dart';
import 'package:younum/domain/models/ledger_source.dart';
import 'package:younum/domain/models/ledger_transaction.dart';

/// 账目测试的公开夹具。
///
/// 所有内容都来自指南 10.1 的固定基准，不使用任何真实账单。
LedgerDataset buildDataset({
  List<LedgerTransaction> transactions = const <LedgerTransaction>[],
  List<Allocation> allocations = const <Allocation>[],
  List<RefundLink> refundLinks = const <RefundLink>[],
  List<RefundAllocation> refundAllocations = const <RefundAllocation>[],
  List<Category>? categories,
}) =>
    LedgerDataset(
      transactions: transactions,
      allocations: allocations,
      refundLinks: refundLinks,
      refundAllocations: refundAllocations,
      categories: categories ?? DemoLedgerSeed.categories(),
    );

/// 演示账本的 6 笔基准，保持 `PENDING`。
List<LedgerTransaction> pendingBaseline() => DemoLedgerSeed.baselineTransactions();

/// 把某笔记录标记为已处理。
LedgerTransaction resolve(LedgerTransaction transaction) => transaction.copyWith(
      reviewStatus: ReviewStatus.resolved,
      version: transaction.version + 1,
    );

/// 6 笔基准全部按指南 10.1 的「建议用途」归类，得到基准数据集。
///
/// 归类完成后：总消费 63330 分、餐饮 15480 分、消费笔数 6。
LedgerDataset resolvedBaseline({
  List<LedgerTransaction> extraTransactions = const <LedgerTransaction>[],
  List<RefundLink> refundLinks = const <RefundLink>[],
  List<RefundAllocation> refundAllocations = const <RefundAllocation>[],
}) {
  final transactions = <LedgerTransaction>[
    for (final transaction in DemoLedgerSeed.baselineTransactions())
      resolve(transaction),
    ...extraTransactions,
  ];

  final allocations = <Allocation>[];
  for (var index = 0; index < DemoLedgerSeed.baseline.length; index++) {
    allocations.add(
      Allocation(
        id: index + 1,
        transactionId: DemoLedgerSeed.transactionIdAt(index),
        categoryId: DemoLedgerSeed.baseline[index].suggestedCategoryId,
        amountCents: DemoLedgerSeed.baseline[index].amountCents,
      ),
    );
  }

  return buildDataset(
    transactions: transactions,
    allocations: allocations,
    refundLinks: refundLinks,
    refundAllocations: refundAllocations,
  );
}

/// 基准数据集，但把「盒马鲜生」拆成 餐饮 8680 + 购物 4000。
///
/// 指南 10.1：拆分后总额仍是 63330，餐饮变 11480，购物变 33900，笔数仍为 6。
LedgerDataset baselineWithHemaSplit() {
  final base = resolvedBaseline();
  final hemaIndex = DemoLedgerSeed.baseline
      .indexWhere((entry) => entry.merchant == '盒马鲜生');
  final hemaTransactionId = DemoLedgerSeed.transactionIdAt(hemaIndex);

  final allocations = <Allocation>[
    for (final allocation in base.allocations)
      if (allocation.transactionId != hemaTransactionId) allocation,
    Allocation(
      id: 100,
      transactionId: hemaTransactionId,
      categoryId: SeedCategoryIds.food,
      amountCents: 8680,
    ),
    Allocation(
      id: 101,
      transactionId: hemaTransactionId,
      categoryId: SeedCategoryIds.shopping,
      amountCents: 4000,
    ),
  ];

  return buildDataset(
    transactions: base.transactions,
    allocations: allocations,
    categories: base.categories,
  );
}

/// 造一笔退款交易。
///
/// [yearMonth] 用 `(year, month)` 传入，允许它落在原消费之外的月份 ——
/// 这正是「跨月退款」要覆盖的情形。
LedgerTransaction refundTransaction({
  required int id,
  required int amountCents,
  required int year,
  required int month,
  required int day,
  String merchant = '退款',
  ReviewStatus reviewStatus = ReviewStatus.resolved,
}) =>
    LedgerTransaction(
      id: id,
      ledgerId: DemoLedgerSeed.demoLedgerId,
      occurredAtMs: StatisticsTime.epochMsFor(year, month, day, 12),
      amountCents: amountCents,
      merchant: merchant,
      nature: TransactionNature.refund,
      reviewStatus: reviewStatus,
      timeZone: StatisticsTime.timeZone,
      sourceNamespace: LedgerSource.alipay,
      sourceTransactionId: 'refund-$id',
    );

/// 优衣库那笔（29900 分）的稳定 ID。
int get uniqloTransactionId {
  final index =
      DemoLedgerSeed.baseline.indexWhere((entry) => entry.merchant.contains('优衣库'));
  return DemoLedgerSeed.transactionIdAt(index);
}

/// 餐饮一级分类 ID。
const int foodCategoryId = SeedCategoryIds.food;

/// 购物一级分类 ID。
const int shoppingCategoryId = SeedCategoryIds.shopping;
