/// 一个月的完整概况：金额 + 进度 + 来源。
///
/// 首页、月报、完成页都从这里取数，保证「同一笔交易在各页面金额一致」
/// （指南阶段 5 的验收条件从源头成立，而不是靠各页面各自小心）。
library;

import '../models/ledger_dataset.dart';
import '../models/ledger_source.dart';
import '../models/year_month.dart';
import 'monthly_stats.dart';
import 'review_progress.dart';

/// 某个账单来源在当月的消费合计。
final class SourceBreakdown {
  const SourceBreakdown({
    required this.namespace,
    required this.label,
    required this.iconKey,
    required this.count,
    required this.amountCents,
  });

  /// 稳定命名空间，可能为 null（未标注来源）。
  final String? namespace;

  /// 展示名称。
  final String label;

  final String iconKey;

  /// 计入的消费笔数。
  final int count;

  final int amountCents;

  @override
  String toString() => 'SourceBreakdown($label, $count, $amountCents)';
}

/// 一个月的概况。
final class MonthOverview {
  const MonthOverview({
    required this.month,
    required this.summary,
    required this.progress,
    required this.sources,
    required this.isDemoLedger,
  });

  /// 从数据集算出概况。
  ///
  /// [coverageConfirmed] 来自用户的显式确认（`month_review` 表），
  /// **不能**由数据推导 —— 文件恰好有月初和月底记录不等于整月完整（指南 3.4）。
  factory MonthOverview.compute({
    required YearMonth month,
    required LedgerDataset dataset,
    required bool coverageConfirmed,
    required bool isDemoLedger,
  }) {
    final summary = MonthlyStats.compute(month: month, dataset: dataset);
    final progress = ReviewProgressRules.compute(
      month: month,
      transactions: dataset.transactions,
      coverageConfirmed: coverageConfirmed,
    );
    return MonthOverview(
      month: month,
      summary: summary,
      progress: progress,
      sources: _sourcesOf(month: month, dataset: dataset),
      isDemoLedger: isDemoLedger,
    );
  }

  final YearMonth month;

  final MonthlySummary summary;

  final ReviewProgress progress;

  final List<SourceBreakdown> sources;

  /// 当前是否处于演示账本。界面据此决定是否显示「示例账本」徽标。
  final bool isDemoLedger;

  /// 本月是否纳入了任何记录。
  bool get hasAnyRecord => progress.totalCount > 0;

  /// 还有待整理的记录 —— 月报入口应该先去完成/继续整理页，
  /// 不展示没有标识的最终报告（指南 3.4）。
  bool get hasPendingReview => !progress.isFullyProcessed;

  /// 可以展示完整月报。
  bool get canOpenCompleteReport => progress.isCompleteMonth;

  /// 只能展示「部分账单」。
  bool get isPartialMonth => progress.isPartialMonth;

  static List<SourceBreakdown> _sourcesOf({
    required YearMonth month,
    required LedgerDataset dataset,
  }) {
    final counts = <String, int>{};
    final amounts = <String, int>{};

    for (final transaction in dataset.transactions) {
      if (transaction.month != month) continue;
      if (!transaction.nature.isExpense) continue;
      final key = transaction.sourceNamespace ?? '';
      // 首页的「本月账单」按**已导入**口径统计：
      // 还没整理完也要能看出这个月有多少钱、来自哪几个平台。
      // 已确认归类后的口径在 [MonthlySummary.expenseCents] 里，两者不互相冒充。
      counts.update(key, (value) => value + 1, ifAbsent: () => 1);
      amounts.update(
        key,
        (value) => value + transaction.amountCents,
        ifAbsent: () => transaction.amountCents,
      );
    }

    final keys = counts.keys.toList()
      ..sort((a, b) => amounts[b]!.compareTo(amounts[a]!));
    return List<SourceBreakdown>.unmodifiable(<SourceBreakdown>[
      for (final key in keys)
        SourceBreakdown(
          namespace: key.isEmpty ? null : key,
          label: LedgerSource.labelOf(key.isEmpty ? null : key),
          iconKey: LedgerSource.iconKeyOf(key.isEmpty ? null : key),
          count: counts[key]!,
          amountCents: amounts[key]!,
        ),
    ]);
  }
}
