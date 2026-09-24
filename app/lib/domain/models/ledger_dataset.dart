/// 参与账目计算的一组记录。
///
/// 设计要点：**业务规则是唯一真源，SQL 只负责取行**。
///
/// 月度净消费、分类净额、退款抵扣这些口径如果各写一遍 SQL 聚合、
/// 各写一遍 Dart 函数，迟早会出现「月报和明细对不上」。因此这里把
/// 相关记录一次读出来，交给 [MonthlyStats] 这类纯函数计算 ——
/// 单元测试里验证的公式，和界面上跑的是**同一份代码**。
///
/// 个人账单的数据量远小于需要为此担心的规模；真到需要时，
/// 再按月份分区下推聚合，而不是现在就把公式拆成两份。
///
/// 为了方便一次算清「跨月退款」，数据集里**允许包含目标月份之外的交易**：
/// 9 月的账单可能被 10 月发生的退款抵扣。取数范围由仓库层决定。
library;

import 'allocation.dart';
import 'category.dart';
import 'ledger_transaction.dart';

/// 一组记录 + 常用索引。
final class LedgerDataset {
  LedgerDataset({
    Iterable<LedgerTransaction> transactions = const <LedgerTransaction>[],
    Iterable<Allocation> allocations = const <Allocation>[],
    Iterable<RefundLink> refundLinks = const <RefundLink>[],
    Iterable<RefundAllocation> refundAllocations = const <RefundAllocation>[],
    Iterable<Category> categories = const <Category>[],
  })  : transactions = List<LedgerTransaction>.unmodifiable(transactions),
        allocations = List<Allocation>.unmodifiable(allocations),
        refundLinks = List<RefundLink>.unmodifiable(refundLinks),
        refundAllocations = List<RefundAllocation>.unmodifiable(refundAllocations),
        categories = List<Category>.unmodifiable(categories);

  /// 空数据集。空月份统计走的就是它。
  factory LedgerDataset.empty() => LedgerDataset();

  final List<LedgerTransaction> transactions;
  final List<Allocation> allocations;
  final List<RefundLink> refundLinks;
  final List<RefundAllocation> refundAllocations;
  final List<Category> categories;

  late final Map<int, LedgerTransaction> _byId = <int, LedgerTransaction>{
    for (final transaction in transactions) transaction.id: transaction,
  };

  late final Map<int, List<Allocation>> _allocationsByTransaction =
      _groupBy(allocations, (a) => a.transactionId);

  late final Map<int, List<RefundLink>> _linksByOriginal =
      _groupBy(refundLinks, (l) => l.originalTransactionId);

  late final Map<int, RefundLink> _linkByRefund = <int, RefundLink>{
    for (final link in refundLinks) link.refundTransactionId: link,
  };

  late final Map<int, List<RefundAllocation>> _refundAllocationsByLink =
      _groupBy(refundAllocations, (r) => r.refundLinkId);

  late final Map<int, Category> _categoryById = <int, Category>{
    for (final category in categories) category.id: category,
  };

  static Map<int, List<T>> _groupBy<T>(
    List<T> items,
    int Function(T) keyOf,
  ) {
    final result = <int, List<T>>{};
    for (final item in items) {
      (result[keyOf(item)] ??= <T>[]).add(item);
    }
    return result;
  }

  LedgerTransaction? transaction(int id) => _byId[id];

  Category? category(int id) => _categoryById[id];

  /// 分类显示名。分类被删掉时给出可读占位，不抛出。
  String categoryName(int id) => _categoryById[id]?.name ?? '已删除分类';

  /// 某笔消费的全部拆分项。
  List<Allocation> allocationsOf(int transactionId) =>
      _allocationsByTransaction[transactionId] ?? const <Allocation>[];

  /// 某笔消费的分配合计（分）。
  int allocatedTotalOf(int transactionId) {
    var total = 0;
    for (final allocation in allocationsOf(transactionId)) {
      total += allocation.amountCents;
    }
    return total;
  }

  /// 关联到某笔原消费的全部退款。
  List<RefundLink> refundsOf(int originalTransactionId) =>
      _linksByOriginal[originalTransactionId] ?? const <RefundLink>[];

  /// 某笔原消费**已被关联**的抵扣合计（分）。
  ///
  /// 不计入 [excludingLinkId]，便于「修改某条关联」时排除它自己重算。
  int linkedRefundTotalOf(int originalTransactionId, {int? excludingLinkId}) {
    var total = 0;
    for (final link in refundsOf(originalTransactionId)) {
      if (link.id == excludingLinkId) continue;
      total += link.amountCents;
    }
    return total;
  }

  /// 这笔退款已经关联到哪笔原消费。
  RefundLink? linkForRefund(int refundTransactionId) =>
      _linkByRefund[refundTransactionId];

  /// 某条退款关联的明确分配。空表示走「单分类直接抵扣」。
  List<RefundAllocation> refundAllocationsOf(int refundLinkId) =>
      _refundAllocationsByLink[refundLinkId] ?? const <RefundAllocation>[];

  /// 某个原拆分项**已被抵扣**的合计（分）。
  int refundedAgainstAllocation(int originalAllocationId, {int? excludingLinkId}) {
    var total = 0;
    for (final refundAllocation in refundAllocations) {
      if (refundAllocation.originalAllocationId != originalAllocationId) continue;
      if (excludingLinkId != null &&
          refundAllocation.refundLinkId == excludingLinkId) {
        continue;
      }
      total += refundAllocation.amountCents;
    }
    return total;
  }

  /// 在数据集里找出一条分配记录。
  Allocation? allocation(int id) {
    for (final allocation in allocations) {
      if (allocation.id == id) return allocation;
    }
    return null;
  }
}
