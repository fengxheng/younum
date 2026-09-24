/// 整理进度与「月份是否完整」的口径。
///
/// 指南 3.4 强调必须区分两个概念，这里把它们做成两个字段而不是一个布尔：
///
/// * [isFullyProcessed] —— 该月**已纳入**的记录是否都处理完了；
/// * [coverageConfirmed] —— 用户是否显式确认过这个月的账单范围完整。
///
/// 前者可由数据算出，后者**只能由用户确认**：不能因为文件碰巧有月初和月底的
/// 记录就自动判定完整。
library;

import '../models/ledger_transaction.dart';
import '../models/year_month.dart';

/// 一个月的整理进度。
final class ReviewProgress {
  const ReviewProgress({
    required this.month,
    required this.resolvedCount,
    required this.pendingCount,
    required this.deferredCount,
    required this.coverageConfirmed,
  });

  factory ReviewProgress.empty(YearMonth month) => ReviewProgress(
        month: month,
        resolvedCount: 0,
        pendingCount: 0,
        deferredCount: 0,
        coverageConfirmed: false,
      );

  final YearMonth month;

  /// 已处理完成。
  final int resolvedCount;

  /// 仍在主队列等待。
  final int pendingCount;

  /// 已稍后处理。**不计入完成数**（指南 3.3）。
  final int deferredCount;

  /// 用户是否确认过当月账单范围完整。
  final bool coverageConfirmed;

  /// 本月纳入整理的记录总数。
  int get totalCount => resolvedCount + pendingCount + deferredCount;

  /// 整理进度 0–1。
  double get ratio => totalCount == 0 ? 0 : resolvedCount / totalCount;

  /// 进度百分比（四舍五入，仅用于展示）。
  int get percent => (ratio * 100).round();

  /// 已纳入的记录全部处理完。
  bool get isFullyProcessed => pendingCount == 0 && deferredCount == 0;

  /// 主队列空了但稍后队列还有东西。
  ///
  /// 这时应该进稍后列表，而**不是**完成页（指南 3.3 与 14.2 的验收项）。
  bool get queueDrainedWithDeferred => pendingCount == 0 && deferredCount > 0;

  /// 可以展示完整月报：既处理完了，用户也确认了范围完整。
  bool get isCompleteMonth => isFullyProcessed && coverageConfirmed;

  /// 处理完了但范围未确认：只能展示「部分账单 / 截至某日」，不冒充完整月报。
  bool get isPartialMonth => isFullyProcessed && !coverageConfirmed;

  @override
  String toString() => 'ReviewProgress($month, $resolvedCount/$totalCount)';
}

/// 从交易记录推导整理进度。
///
/// 只统计**属于该月**的记录：其它月份的在途记录不影响本月的进度。
abstract final class ReviewProgressRules {
  static ReviewProgress compute({
    required YearMonth month,
    required Iterable<LedgerTransaction> transactions,
    required bool coverageConfirmed,
  }) {
    var resolved = 0;
    var pending = 0;
    var deferred = 0;
    for (final transaction in transactions) {
      if (transaction.month != month) continue;
      switch (transaction.reviewStatus) {
        case ReviewStatus.resolved:
          resolved++;
        case ReviewStatus.pending:
          pending++;
        case ReviewStatus.deferred:
          deferred++;
      }
    }
    return ReviewProgress(
      month: month,
      resolvedCount: resolved,
      pendingCount: pending,
      deferredCount: deferred,
      coverageConfirmed: coverageConfirmed,
    );
  }
}
