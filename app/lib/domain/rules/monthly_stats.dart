/// 月度统计口径。
///
/// 指南 3.4 的硬规则，全部在这里落地：
///
/// * **月度净消费 = 已确认消费分配总额 − 归属于这些消费的已确认退款。**
/// * 消费笔数按**原消费交易**计数；拆成两类仍算一笔，退款不增加笔数。
/// * 收入、转账、排除统计不计入消费。
/// * 跨月退款归回**原消费月份**（3.5.4）：10 月发生的退款抵扣 9 月消费，
///   10 月不会因此出现负数。
/// * 分类占比 = 分类净额 ÷ 总净消费；总额为零不显示占比。
/// * 分类金额之和等于总额（守恒）。
library;

import '../models/ledger_dataset.dart';
import '../models/ledger_transaction.dart';
import '../models/year_month.dart';

/// 某个分类在当月的净额。
final class CategoryNet {
  const CategoryNet({
    required this.categoryId,
    required this.categoryName,
    required this.expenseCents,
    required this.refundCents,
  });

  final int categoryId;
  final String categoryName;

  /// 该分类分到的消费额（分）。
  final int expenseCents;

  /// 被退款抵扣掉的金额（分）。
  final int refundCents;

  /// 净额（分）。0 表示这个月该分类已被全额退掉，不应出现在占比里。
  int get netCents => expenseCents - refundCents;

  @override
  String toString() => 'CategoryNet($categoryName, $netCents)';
}

/// 一个月的金额概况。
final class MonthlySummary {
  const MonthlySummary({
    required this.month,
    required this.expenseCents,
    required this.refundCents,
    required this.unattributedRefundCents,
    required this.expenseCount,
    required this.importedExpenseCents,
    required this.importedExpenseCount,
    required this.recordCount,
    required this.byCategory,
    required this.issues,
  });

  /// 空月份：没有任何记录，也没有金额。
  ///
  /// 指南 3.4「无记录的月份不显示任何金额」—— 用这个而不是让界面自己判断。
  factory MonthlySummary.empty(YearMonth month) => MonthlySummary(
        month: month,
        expenseCents: 0,
        refundCents: 0,
        unattributedRefundCents: 0,
        expenseCount: 0,
        importedExpenseCents: 0,
        importedExpenseCount: 0,
        recordCount: 0,
        byCategory: const <CategoryNet>[],
        issues: const <String>[],
      );

  final YearMonth month;

  /// 已确认消费的分配总额（分）。
  final int expenseCents;

  /// 归属于本月消费的已确认退款（分）。
  final int refundCents;

  /// 无法归属到具体分类的退款（分）。
  ///
  /// 正常情况恒为 0：拆分消费的退款必须有明确分配，规则层会拦住。
  /// 只有数据被外部改坏时才会非零，此时**不能**画分类占比
  /// （见 [isCategoryBreakdownComplete]），否则占比和不等于 100%。
  final int unattributedRefundCents;

  /// 消费笔数（按原消费交易计数，**只算已确认归类的**）。
  final int expenseCount;

  /// 本月**已导入**的支出金额（分），不区分是否已整理。
  ///
  /// 与 [expenseCents] 是两个不同的口径，不能互相冒充：
  /// [expenseCents] 是「已确认归类」的消费，只有它参与净消费与分类占比；
  /// 这个是「账单里一共有多少支出」，首页的「本月已导入支出」用它。
  final int importedExpenseCents;

  /// 本月已导入的支出笔数。
  final int importedExpenseCount;

  /// 本月记录总数（含未整理、收入、退款等），用于区分「空月份」。
  final int recordCount;

  /// 分类净额，按净额降序；净额为 0 的分类不出现。
  final List<CategoryNet> byCategory;

  /// 计算过程中发现的数据一致性问题。
  ///
  /// 不抛异常：月报要能打开并说明「这里有问题」，
  /// 而不是整页崩掉、让用户不知道哪笔数据坏了。
  final List<String> issues;

  int get netExpenseCents => expenseCents - refundCents;

  /// 分类净额之和。
  ///
  /// 守恒关系：等于 `netExpenseCents + unattributedRefundCents`。
  /// 后者正常为 0，于是「分类金额之和等于总额」始终成立。
  int get categoryNetTotalCents {
    var total = 0;
    for (final category in byCategory) {
      total += category.netCents;
    }
    return total;
  }

  /// 分类占比是否可以可信展示。
  bool get isCategoryBreakdownComplete => unattributedRefundCents == 0;

  /// 本月有没有任何记录。
  bool get hasRecords => recordCount > 0;

  /// 本月有没有可展示的消费。
  ///
  /// 指南 3.4：只有收入或没有消费时走空状态，**不能除以零绘制环形图**。
  bool get hasExpense => expenseCount > 0 && expenseCents > 0;

  /// 净消费是否为零或负。为零时不显示占比；为负说明退款口径有问题。
  bool get isNetNonPositive => netExpenseCents <= 0;

  /// 某个分类净额占总净消费的比例，单位「基点」（万分之一）。
  ///
  /// 返回 null 表示总额为零，**不应显示占比**。
  /// 用整数基点而不是 `double`：占比只用于展示，但四舍五入要在最后一步做，
  /// 中间不留浮点误差（指南 3.1）。
  int? shareBasisPointsOf(int categoryId) {
    final total = netExpenseCents;
    if (total <= 0) return null;
    for (final category in byCategory) {
      if (category.categoryId != categoryId) continue;
      return (category.netCents * 10000 / total).round();
    }
    return 0;
  }

  @override
  String toString() =>
      'MonthlySummary($month, net=$netExpenseCents, count=$expenseCount)';
}

/// 月度统计。
abstract final class MonthlyStats {
  /// 计算 [month] 的金额概况。
  ///
  /// [dataset] 允许包含其它月份的记录：跨月退款需要它们才能算对。
  static MonthlySummary compute({
    required YearMonth month,
    required LedgerDataset dataset,
  }) {
    final issues = <String>[];
    final expenseByCategory = <int, int>{};
    final refundByCategory = <int, int>{};

    var expenseCents = 0;
    var refundCents = 0;
    var unattributedRefundCents = 0;
    var expenseCount = 0;
    var importedExpenseCents = 0;
    var importedExpenseCount = 0;
    var recordCount = 0;

    for (final transaction in dataset.transactions) {
      if (transaction.month != month) continue;
      recordCount++;
      if (!transaction.nature.isExpense) continue;

      // 已导入口径：不管整理到哪一步都算。
      importedExpenseCents += transaction.amountCents;
      importedExpenseCount++;

      if (transaction.reviewStatus != ReviewStatus.resolved) continue;

      // 消费只有完成有效分配才可 RESOLVED（指南 3.3），
      // 但外部改坏数据时可能不成立 —— 记下来，不崩。
      final allocations = dataset.allocationsOf(transaction.id);
      if (allocations.isEmpty) {
        issues.add('「${transaction.merchant}」已整理但没有分类分配，未计入本月消费');
        continue;
      }

      var allocatedTotal = 0;
      for (final allocation in allocations) {
        allocatedTotal += allocation.amountCents;
        expenseByCategory.update(
          allocation.categoryId,
          (value) => value + allocation.amountCents,
          ifAbsent: () => allocation.amountCents,
        );
      }

      // 以分配额为准而不是交易金额：这样「分类金额之和 = 总额」永远成立，
      // 环形图不会和总额对不上。不一致本身就作为问题暴露出来。
      if (allocatedTotal != transaction.amountCents) {
        issues.add(
          '「${transaction.merchant}」的分类合计与原金额不一致，已按分类合计统计',
        );
      }
      expenseCents += allocatedTotal;
      expenseCount++;
    }

    for (final link in dataset.refundLinks) {
      final original = dataset.transaction(link.originalTransactionId);
      if (original == null) {
        issues.add('有一笔退款关联指向了不存在的交易，已跳过');
        continue;
      }
      // 跨月退款归回原消费月份（指南 3.5.4）。
      if (original.month != month) continue;

      final refund = dataset.transaction(link.refundTransactionId);
      if (refund == null) {
        issues.add('有一笔退款关联缺少退款记录，已跳过');
        continue;
      }
      // 未处理完的退款不参与抵扣：它还在待核对队列里。
      if (refund.nature != TransactionNature.refund ||
          refund.reviewStatus != ReviewStatus.resolved) {
        continue;
      }

      refundCents += link.amountCents;

      final refundAllocations = dataset.refundAllocationsOf(link.id);
      if (refundAllocations.isEmpty) {
        final originalAllocations = dataset.allocationsOf(original.id);
        if (originalAllocations.length == 1) {
          final categoryId = originalAllocations.first.categoryId;
          refundByCategory.update(
            categoryId,
            (value) => value + link.amountCents,
            ifAbsent: () => link.amountCents,
          );
        } else {
          // 规则层会阻止建立这种关联，走到这里说明数据被外部改过。
          unattributedRefundCents += link.amountCents;
          issues.add('「${original.merchant}」的退款缺少明确分配，分类占比暂不可用');
        }
        continue;
      }

      for (final refundAllocation in refundAllocations) {
        final target = dataset.allocation(refundAllocation.originalAllocationId);
        if (target == null) {
          unattributedRefundCents += refundAllocation.amountCents;
          issues.add('有一笔退款分配指向了不存在的拆分项，分类占比暂不可用');
          continue;
        }
        refundByCategory.update(
          target.categoryId,
          (value) => value + refundAllocation.amountCents,
          ifAbsent: () => refundAllocation.amountCents,
        );
      }
    }

    final categoryIds = <int>{...expenseByCategory.keys, ...refundByCategory.keys};
    final byCategory = <CategoryNet>[];
    for (final categoryId in categoryIds) {
      final net = CategoryNet(
        categoryId: categoryId,
        categoryName: dataset.categoryName(categoryId),
        expenseCents: expenseByCategory[categoryId] ?? 0,
        refundCents: refundByCategory[categoryId] ?? 0,
      );
      // 净额为 0 的分类（被全额退掉）不进入占比，否则会出现「0 元占比 3%」。
      if (net.netCents != 0) byCategory.add(net);
    }
    byCategory.sort((a, b) {
      final byNet = b.netCents.compareTo(a.netCents);
      return byNet != 0 ? byNet : a.categoryId.compareTo(b.categoryId);
    });

    return MonthlySummary(
      month: month,
      expenseCents: expenseCents,
      refundCents: refundCents,
      unattributedRefundCents: unattributedRefundCents,
      expenseCount: expenseCount,
      importedExpenseCents: importedExpenseCents,
      importedExpenseCount: importedExpenseCount,
      recordCount: recordCount,
      byCategory: List<CategoryNet>.unmodifiable(byCategory),
      issues: List<String>.unmodifiable(issues),
    );
  }
}
