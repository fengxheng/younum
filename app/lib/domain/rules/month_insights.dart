/// 月度洞察：日均、单笔最高、最低消费日、环比与分类变化。
///
/// 指南 3.4 里几条容易被做错的规则集中在这里：
///
/// * **完整月日均按当月自然日数**；范围不完整时按已覆盖天数，并**明确分母**，
///   不能仍然除以 30。
/// * **只有两个月范围都完整、且上月净消费大于零才显示环比百分比**；
///   上月为零时只显示金额差，不显示「无限增长」。
/// * 收入、转账、排除统计不计入消费，所以这里的数字都建立在
///   [MonthlySummary] 的净额之上，不另算一套。
library;

import '../../core/money/money.dart';
import '../../core/time/statistics_time.dart';
import '../models/ledger_dataset.dart';
import '../models/ledger_transaction.dart';
import '../models/year_month.dart';
import 'month_overview.dart';
import 'monthly_stats.dart';

/// 某一天的消费合计。
final class DayExpense {
  const DayExpense({
    required this.day,
    required this.expenseCents,
    required this.count,
  });

  /// 当月第几天（1–31）。
  final int day;

  final int expenseCents;

  /// 当天的消费笔数。
  final int count;

  @override
  String toString() => 'DayExpense($day, $expenseCents, $count)';
}

/// 某个分类与上月的差额。
final class CategoryChange {
  const CategoryChange({
    required this.categoryId,
    required this.categoryName,
    required this.deltaCents,
  });

  final int categoryId;
  final String categoryName;

  /// 本月净额 − 上月净额。正数是变多。
  final int deltaCents;

  bool get isIncrease => deltaCents > 0;

  @override
  String toString() => 'CategoryChange($categoryName, $deltaCents)';
}

/// 趋势图上的一根柱子。
final class MonthTrendPoint {
  const MonthTrendPoint({
    required this.month,
    required this.netExpenseCents,
    required this.hasRecords,
    required this.isComplete,
  });

  final YearMonth month;

  /// 净消费（分）。
  final int netExpenseCents;

  /// 该月有没有任何记录。
  final bool hasRecords;

  /// 该月是否已确认范围完整。
  final bool isComplete;

  @override
  String toString() => 'MonthTrendPoint($month, $netExpenseCents)';
}

/// 一个月的洞察。
final class MonthInsights {
  const MonthInsights({
    required this.month,
    required this.coverageConfirmed,
    required this.dayAverageCents,
    required this.averageDenominatorDays,
    required this.averageUsesFullMonth,
    required this.highestSingle,
    required this.highestSingleCategoryName,
    required this.lowestSpendingDay,
    required this.previousMonth,
    required this.previousNetExpenseCents,
    required this.previousIsComplete,
    required this.monthOverMonthDeltaCents,
    required this.monthOverMonthBasisPoints,
    required this.categoryChanges,
    required this.findings,
  });

  final YearMonth month;

  final bool coverageConfirmed;

  /// 日均消费（分）。分母见 [averageDenominatorDays]。
  ///
  /// 没有任何消费时为 null —— 不能凭空给出「日均 0 元」。
  final int? dayAverageCents;

  /// 计算日均时用的天数。
  final int averageDenominatorDays;

  /// 分母是否为「当月自然日数」。
  ///
  /// 为 false 时界面必须说明这是「已覆盖范围日均」，不能标成整月日均。
  final bool averageUsesFullMonth;

  /// 金额最高的一笔消费。
  final LedgerTransaction? highestSingle;

  /// 最高那笔的分类名。
  final String? highestSingleCategoryName;

  /// 消费最少的一天（**只在有消费的日子里比较**）。
  final DayExpense? lowestSpendingDay;

  /// 上一个月。
  final YearMonth? previousMonth;

  /// 上个月的净消费。
  final int? previousNetExpenseCents;

  /// 上个月是否已确认范围完整。
  final bool previousIsComplete;

  /// 与上月的差额（分）。只有两个月都完整时才有值。
  final int? monthOverMonthDeltaCents;

  /// 环比，单位「基点」（万分之一）。
  ///
  /// 只有两个月都完整、**且上月净消费大于零**时才有值；
  /// 上月为零时这里为 null，界面只显示金额差。
  final int? monthOverMonthBasisPoints;

  /// 变化最大的分类，按绝对变动降序，最多 3 条。
  final List<CategoryChange> categoryChanges;

  /// 「这个月的发现」文案。
  final List<String> findings;

  bool get canShowMonthOverMonthPercent => monthOverMonthBasisPoints != null;

  bool get canShowMonthOverMonthDelta => monthOverMonthDeltaCents != null;

  @override
  String toString() => 'MonthInsights($month)';
}

/// 由一个月的数据算出的完整报告。
///
/// 首页、月报、趋势、明细、分享、月份页都从这一个对象取数，
/// 因此不可能出现「同一笔交易在两个页面金额不一致」。
final class MonthReport {
  MonthReport({
    required this.overview,
    required this.insights,
    required this.trend,
    required this.recordedMonths,
    required this.dataset,
    required this.confirmedMonths,
  });

  /// 当前月份的概况。
  final MonthOverview overview;

  final MonthInsights insights;

  /// 趋势窗口，按时间**升序**，最后一个是当前月。
  final List<MonthTrendPoint> trend;

  /// 有记录的月份，按时间**倒序**。
  final List<YearMonth> recordedMonths;

  /// 账本的完整数据集。明细、分类下钻、月份切换都从这里取，
  /// 避免每个页面各自查一次、各算一套。
  final LedgerDataset dataset;

  /// 已确认范围完整的月份。
  final Set<YearMonth> confirmedMonths;

  /// 任意月份的概况。
  ///
  /// 月份页会问「3 月有多少钱」，用它按需计算，不必预先算好 12 个月。
  MonthOverview overviewOf(YearMonth month) => MonthOverview.compute(
        month: month,
        dataset: dataset,
        coverageConfirmed: confirmedMonths.contains(month),
        isDemoLedger: overview.isDemoLedger,
      );

  /// 该月有没有任何记录。
  bool hasRecordsOf(YearMonth month) => overviewOf(month).summary.hasRecords;

  /// 趋势窗口里净消费最高的一条，用于图表缩放。
  int get trendPeakCents {
    var peak = 0;
    for (final point in trend) {
      if (point.netExpenseCents > peak) peak = point.netExpenseCents;
    }
    return peak;
  }
}

/// 报告计算。
abstract final class MonthReports {
  /// 趋势窗口的默认长度。
  static const int defaultTrendMonths = 6;

  /// 构建报告。
  ///
  /// [dataset] 应当是**整本账本**的记录：跨月退款、趋势、分类变化都需要
  /// 目标月份之外的数据。
  static MonthReport build({
    required YearMonth month,
    required LedgerDataset dataset,
    required bool isDemoLedger,
    Set<YearMonth> coverageConfirmed = const <YearMonth>{},
    int trendMonths = defaultTrendMonths,
  }) {
    final overview = MonthOverview.compute(
      month: month,
      dataset: dataset,
      coverageConfirmed: coverageConfirmed.contains(month),
      isDemoLedger: isDemoLedger,
    );

    // 趋势窗口：以当前月结尾的连续 N 个月。没有记录的月份照样留在窗口里，
    // 界面负责把它画成空柱，而不是把窗口压缩掉。
    final window = <YearMonth>[];
    var cursor = month;
    for (var index = 0; index < trendMonths; index++) {
      window.insert(0, cursor);
      cursor = cursor.previous;
    }

    final trends = <MonthTrendPoint>[];
    final summaries = <YearMonth, MonthlySummary>{};
    for (final each in window) {
      final summary = each == month
          ? overview.summary
          : MonthlyStats.compute(month: each, dataset: dataset);
      summaries[each] = summary;
      trends.add(
        MonthTrendPoint(
          month: each,
          netExpenseCents: summary.netExpenseCents,
          hasRecords: summary.hasRecords,
          isComplete: coverageConfirmed.contains(each),
        ),
      );
    }

    // 有记录的月份：倒序。月份页用它决定哪些格子可点。
    final recorded = <YearMonth>[];
    final seen = <YearMonth>{};
    for (final transaction in dataset.transactions) {
      if (seen.add(transaction.month)) recorded.add(transaction.month);
    }
    recorded.sort((a, b) => b.compareTo(a));

    final insights = _insightsOf(
      month: month,
      overview: overview,
      dataset: dataset,
      previousSummary: summaries[month.previous],
      previousIsComplete: coverageConfirmed.contains(month.previous),
    );

    return MonthReport(
      overview: overview,
      insights: insights,
      trend: List<MonthTrendPoint>.unmodifiable(trends),
      recordedMonths: List<YearMonth>.unmodifiable(recorded),
      dataset: dataset,
      confirmedMonths: Set<YearMonth>.unmodifiable(coverageConfirmed),
    );
  }

  static MonthInsights _insightsOf({
    required YearMonth month,
    required MonthOverview overview,
    required LedgerDataset dataset,
    required MonthlySummary? previousSummary,
    required bool previousIsComplete,
  }) {
    final summary = overview.summary;
    final confirmed = overview.progress.coverageConfirmed;

    // ---- 逐日消费 + 单笔最高 ----
    final dayTotals = <int, int>{};
    final dayCounts = <int, int>{};
    var coveredDays = 0;
    LedgerTransaction? highest;
    var highestAmount = 0;
    int? highestCategoryId;

    for (final transaction in dataset.transactions) {
      if (transaction.month != month) continue;
      if (!transaction.nature.isExpense) continue;

      final day = StatisticsTime.toLocal(transaction.occurredAtMs).day;
      if (day > coveredDays) coveredDays = day;

      if (transaction.reviewStatus != ReviewStatus.resolved) continue;
      final allocated = dataset.allocatedTotalOf(transaction.id);
      dayTotals.update(day, (value) => value + allocated, ifAbsent: () => allocated);
      dayCounts.update(day, (value) => value + 1, ifAbsent: () => 1);

      if (allocated > highestAmount) {
        highestAmount = allocated;
        highest = transaction;
        final allocations = dataset.allocationsOf(transaction.id);
        highestCategoryId =
            allocations.isEmpty ? null : allocations.first.categoryId;
      }
    }

    // ---- 日均 ----
    // 完整月除以自然日数；范围不完整就除以「已覆盖到的天数」，
    // 并把分母交出去，让界面能如实写「已覆盖范围日均」。
    final denominator = confirmed ? month.daysInMonth : coveredDays;
    final dayAverage = (summary.hasExpense && denominator > 0)
        ? (summary.netExpenseCents / denominator).round()
        : null;

    // ---- 最低消费日 ----
    // 设计稿的样例月份每天都有消费，所以「最低日」看起来自然；
    // 真实数据下大多数日子是 0，展示「¥0.00」没有信息量，
    // 因此只在**有消费的日子**里比较。见 docs/DECISIONS.md 第 24 节。
    DayExpense? lowest;
    for (final entry in dayTotals.entries) {
      if (lowest != null && entry.value >= lowest.expenseCents) continue;
      lowest = DayExpense(
        day: entry.key,
        expenseCents: entry.value,
        count: dayCounts[entry.key] ?? 0,
      );
    }

    // ---- 环比 ----
    // 只有两个月都完整才有得比；上月为零或负数时不给百分比，
    // 否则会算出「无限增长」这种没法看的数字。
    final previousNet = previousSummary?.netExpenseCents;
    final bothComplete =
        confirmed && previousIsComplete && previousNet != null;
    final delta = bothComplete ? summary.netExpenseCents - previousNet : null;
    final basisPoints = (bothComplete && previousNet > 0)
        ? ((summary.netExpenseCents - previousNet) * 10000 / previousNet).round()
        : null;

    // ---- 分类变化 ----
    final changes = <CategoryChange>[];
    if (bothComplete) {
      final current = <int, int>{
        for (final each in summary.byCategory) each.categoryId: each.netCents,
      };
      final before = <int, int>{
        for (final each in previousSummary!.byCategory)
          each.categoryId: each.netCents,
      };
      for (final categoryId in <int>{...current.keys, ...before.keys}) {
        final value = (current[categoryId] ?? 0) - (before[categoryId] ?? 0);
        if (value == 0) continue;
        changes.add(
          CategoryChange(
            categoryId: categoryId,
            categoryName: dataset.categoryName(categoryId),
            deltaCents: value,
          ),
        );
      }
      changes.sort((a, b) => b.deltaCents.abs().compareTo(a.deltaCents.abs()));
      if (changes.length > 3) changes.removeRange(3, changes.length);
    }

    return MonthInsights(
      month: month,
      coverageConfirmed: confirmed,
      dayAverageCents: dayAverage,
      averageDenominatorDays: denominator,
      averageUsesFullMonth: confirmed,
      highestSingle: highest,
      highestSingleCategoryName: highestCategoryId == null
          ? null
          : dataset.categoryName(highestCategoryId),
      lowestSpendingDay: lowest,
      previousMonth: month.previous,
      previousNetExpenseCents: previousNet,
      previousIsComplete: previousIsComplete,
      monthOverMonthDeltaCents: delta,
      monthOverMonthBasisPoints: basisPoints,
      categoryChanges: List<CategoryChange>.unmodifiable(changes),
      findings: _findingsOf(
        summary: summary,
        changes: changes,
        deltaCents: delta,
      ),
    );
  }

  /// 「这个月的发现」文案。
  ///
  /// 文案放在领域层而不是界面里：它完全由数字决定（占比最高的分类、
  /// 变动最大的分类），放在这里才能被测试固定住，
  /// 不会出现「改了统计口径但句子还是旧的」。
  static List<String> _findingsOf({
    required MonthlySummary summary,
    required List<CategoryChange> changes,
    required int? deltaCents,
  }) {
    final findings = <String>[];

    if (summary.hasExpense && summary.netExpenseCents > 0) {
      final top = summary.byCategory.first;
      final basisPoints = summary.shareBasisPointsOf(top.categoryId);
      if (basisPoints != null) {
        findings.add('${top.categoryName}占比最高，${_percentText(basisPoints)}。');
      }
    }

    if (deltaCents != null && deltaCents != 0) {
      findings.add(
        '这个月比上月${deltaCents > 0 ? '多' : '少'} '
        '¥${Money.format(deltaCents.abs(), grouped: true)}。',
      );
    }

    for (final change in changes) {
      findings.add(
        '${change.categoryName}比上月${change.isIncrease ? '多' : '少'} '
        '¥${Money.format(change.deltaCents.abs(), grouped: true)}。',
      );
    }

    if (findings.isEmpty) {
      findings.add('这个月的记录还不多，先慢慢整理，再看能发现什么。');
    }
    findings.add('日常的小选择，也在慢慢改变。');
    return List<String>.unmodifiable(findings);
  }

  /// 基点转百分比文本，保留一位小数。
  static String _percentText(int basisPoints) =>
      '${(basisPoints / 100).toStringAsFixed(1)}%';
}
