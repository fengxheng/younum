import 'package:flutter/material.dart';

import '../../app/app_routes.dart';
import '../../app/route_args.dart';
import '../../core/components/amount_text.dart';
import '../../core/components/buttons.dart';
import '../../core/components/category_grid.dart';
import '../../core/components/fields.dart';
import '../../core/components/list_row.dart';
import '../../core/components/primitives.dart';
import '../../core/components/progress.dart';
import '../../core/components/screen_scaffold.dart';
import '../../core/components/sheets.dart';
import '../../core/designsystem/color_math.dart';
import '../../core/designsystem/younum_colors.dart';
import '../../core/designsystem/younum_dimens.dart';
import '../../core/designsystem/younum_icons.dart';
import '../../core/designsystem/younum_text.dart';
import '../../core/money/money.dart';
import '../../core/time/statistics_time.dart';
import '../../domain/models/ledger_dataset.dart';
import '../../domain/models/ledger_transaction.dart';
import '../../domain/models/year_month.dart';
import '../../domain/repositories/document_saver.dart';
import '../../domain/rules/export_rules.dart';
import '../../domain/rules/month_insights.dart';
import '../../domain/rules/month_overview.dart';
import '../../domain/rules/monthly_stats.dart';
import '../../domain/rules/share_poster_rules.dart';
import '../export/export_files.dart';
import '../export/export_scope.dart';
import '../export/poster_preview.dart';
import '../organize/category_registry.dart';
import '../organize/review_session.dart';

/// 分类系列色。与图例、环形图、分类详情一一对应，**不随主题变化**
/// （指南 7.3：主题不能造成图表图例与实际颜色不一致）。
Color _seriesColor(int index) => ColorMath.toColor(
      YounumColors.categorySeries[index % YounumColors.categorySeries.length],
    );

/// 基点转百分比文本，保留一位小数。
String _percentText(int basisPoints) =>
    '${(basisPoints / 100).toStringAsFixed(1)}%';

/// 交易性质的中文说明。
/// 金额前缀：支出是负方向，收入与退款是正方向。
///
/// 金额在库里一律存**非负绝对值**，方向由交易性质表达（指南 3.1），
/// 因此符号必须在这里显式补上，不能指望数值自带正负。
String _signedAmount(LedgerTransaction transaction) {
  final body = '¥${Money.format(transaction.amountCents, grouped: true)}';
  return switch (transaction.nature) {
    TransactionNature.expense => '\u2212$body',
    TransactionNature.income || TransactionNature.refund => '+$body',
    TransactionNature.transfer ||
    TransactionNature.excluded ||
    TransactionNature.unknown =>
      body,
  };
}

/// 载入中占位。避免在拿到数据之前先把 0 画出来闪一下。
class _ReportLoading extends StatelessWidget {
  const _ReportLoading({this.title, this.bottomBar = false});

  final String? title;
  final bool bottomBar;

  @override
  Widget build(BuildContext context) {
    final body = const Center(child: YounumMutedText('正在读取本地账单…'));
    return YounumScreen(
      title: title,
      bottomBar: bottomBar ? const AppBottomBar() : null,
      child: body,
    );
  }
}

/// 当前月份还没有可展示的消费。
///
/// 指南 3.4：只有收入或没有消费时使用空状态，**不能除以零绘制环形图**。
class _NoExpense extends StatelessWidget {
  const _NoExpense({required this.month, required this.description});

  final YearMonth month;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        YounumEmptyState(
          icon: YounumIcons.navReport,
          title: '${month.label}还没有消费记录',
          description: description,
        ),
        const SizedBox(height: YounumDimens.gap),
        PrimaryAction(
          label: '导入月账单',
          trailingArrow: true,
          onPressed: () => context.open(AppRoutes.billImport),
        ),
      ],
    );
  }
}

/// 「部分账单」的原因与下一步。
///
/// 两种原因完全不同，混成一句话用户就不知道该点哪里：
///
/// * **还有记录没整理完** → 给进度和「继续整理」；
/// * **整理完了、只是没确认范围完整** → 给一个确认入口。
///   指南 3.4 要求 `coverageConfirmed` 只能由用户**显式**给出，
///   不能因为数据里恰好有月初和月底的记录就自动判定 ——
///   所以必须有一个能点的地方。原先只有整理完成页有这个开关，
///   只想看账、不走完整理流程的用户会一直看到「部分账单」却找不到出口。
class _PartialMonthPanel extends StatelessWidget {
  const _PartialMonthPanel({required this.overview, required this.session});

  final MonthOverview overview;
  final ReviewSession session;

  /// 确认前先问一句。
  ///
  /// 这是一个**关于数据完整性的断言**：说出口之后，日均、环比、分类变化
  /// 都会按完整自然月展示。带副作用的断言不能一按就生效。
  Future<void> _confirmCoverage(BuildContext context) async {
    final month = overview.month;
    final agreed = await showConfirmSheet(
      context: context,
      title: '确认${month.shortLabel}账单范围完整？',
      description:
          '确认后这个月按完整自然月展示：日均消费除以当月天数，'
          '环比与分类变化也会出现（前提是上个月也已确认）。\n\n'
          '请确认你已经导入这个月月初到月末的全部记录。',
      confirmLabel: '确认范围完整',
      cancelLabel: '再看看',
    );
    if (!agreed || !context.mounted) return;

    await session.confirmCoverage(true);
    if (!context.mounted) return;
    showYounumToast(
      context,
      session.coverageConfirmed
          ? '已确认${month.shortLabel}账单范围完整'
          : session.lastFailure ?? '确认没有保存成功，可以重试',
    );
  }

  @override
  Widget build(BuildContext context) {
    final month = overview.month;
    final progress = overview.progress;

    if (overview.hasPendingReview) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          YounumNotice(
            '${month.shortLabel}还有 '
            '${progress.pendingCount + progress.deferredCount} 笔没有整理完，'
            '上面的金额只统计了已归类的部分。',
          ),
          PrimaryAction(
            label: '继续整理',
            trailingArrow: true,
            onPressed: () => context.selectTab(1),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        YounumNotice(
          '你还没有确认 ${month.month} 月账单范围完整。上面的金额只代表已导入的部分，'
          '不能直接与完整自然月比较。',
        ),
        PrimaryAction(
          label: '我确认${month.shortLabel}账单范围完整',
          style: YounumActionStyle.secondary,
          onPressed: () => _confirmCoverage(context),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// report —— 月度消费概况
// -----------------------------------------------------------------------------

/// 月度概况。
///
/// 三条硬规则（指南 3.4）：
/// * 范围未确认完整时标注「部分账单」，不冒充完整月报；
/// * 没有消费时用空状态，不画空环形图、不除以零；
/// * 环比只在两个月都完整且上月净消费大于 0 时显示百分比。
///
/// 数字全部来自 `MonthReport`：与首页、趋势、明细、分享用的是**同一份**计算结果。
class ReportScreen extends StatelessWidget {
  const ReportScreen({super.key, this.debugForceEmpty = false});

  /// 走查用：强制渲染「无消费」空状态。
  final bool debugForceEmpty;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final session = ReviewSessionScope.of(context);
    final overview = session.overview;
    final insights = session.insights;
    if (overview == null || insights == null) {
      return const _ReportLoading(bottomBar: true);
    }

    final month = overview.month;
    final summary = overview.summary;
    final routeArgs = <Widget>[
      Row(
        children: <Widget>[
          Expanded(child: Text('YOUR MONTH IN REVIEW', style: text.eyebrow)),
          PlainTextButton(
            label: month.label,
            trailingIcon: YounumIcons.expandMore,
            semanticLabel: '切换月份，当前 ${month.label}',
            onTap: () => context.open(AppRoutes.months),
          ),
        ],
      ),
      Text('${month.month} 月消费手记', style: text.screenTitle),
      const SizedBox(height: YounumDimens.gap),
    ];

    if (debugForceEmpty || !summary.hasExpense) {
      return YounumScreen(
        bottomBar: const AppBottomBar(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ...routeArgs,
            _NoExpense(
              month: month,
              description: debugForceEmpty
                  ? '设计走查：这一屏用来检查没有消费时的呈现。'
                      '没有消费时不展示占比，也不计算环比。'
                  : summary.importedExpenseCount == 0
                      ? '这个月还没有导入账单。导入后完成整理，这里会出现分类结构、趋势与环比。'
                      : '这个月已导入 ${summary.importedExpenseCount} 笔记录，'
                          '但还没有确认归类的消费，所以暂时没有可展示的占比。',
            ),
          ],
        ),
      );
    }

    return YounumScreen(
      bottomBar: const AppBottomBar(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ...routeArgs,
          YounumPanel(
            tone: YounumPanelTone.dark,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                YounumMutedText(
                  overview.progress.isCompleteMonth
                      ? '这个月，一共花了'
                      // 没确认范围完整时要说清「截至哪天」，
                      // 不能把已导入的一部分说成一整月。
                      : '这个月，截至 ${month.month}月'
                          '${insights.averageDenominatorDays}日一共花了',
                  style: text.body.copyWith(fontSize: 13),
                ),
                const SizedBox(height: YounumDimens.gapSm),
                AmountText(
                  cents: summary.netExpenseCents,
                  scale: AmountScale.panel,
                  color: YounumColors.of(context).onDarkPanelColor,
                ),
                const SizedBox(height: YounumDimens.gap),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    if (insights.canShowMonthOverMonthPercent)
                      YounumBadge(
                        '${insights.monthOverMonthBasisPoints! > 0 ? '↗' : '↘'} '
                        '环比 ${_percentText(insights.monthOverMonthBasisPoints!.abs())}',
                      ),
                    YounumBadge('${summary.expenseCount} 笔消费'),
                    if (summary.refundCents != 0)
                      YounumBadge(
                        '已抵扣退款 ¥${Money.format(summary.refundCents, grouped: true)}',
                        tone: YounumBadgeTone.onDark,
                      ),
                    if (!overview.progress.isCompleteMonth)
                      const YounumBadge('部分账单', tone: YounumBadgeTone.onDark),
                  ],
                ),
              ],
            ),
          ),
          if (!overview.progress.isCompleteMonth)
            _PartialMonthPanel(overview: overview, session: session),
          if (summary.issues.isNotEmpty)
            YounumNotice('有几笔记录的数据需要核对：${summary.issues.join('；')}'),
          YounumPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(child: Text('钱都去了哪里', style: text.sectionTitle)),
                    PlainTextButton(
                      label: '详情 ›',
                      onTap: () => context.open(AppRoutes.breakdown),
                    ),
                  ],
                ),
                YounumDonutChart(
                  centerLabel: '消费分布',
                  centerValue: '${summary.byCategory.length} 类',
                  slices: _donutSlices(summary),
                ),
                const SizedBox(height: YounumDimens.gapLg),
                YounumLegend(entries: _legendEntries(summary)),
              ],
            ),
          ),
          YounumSectionHeader(
            title: '这个月的发现',
            trailing: PlainTextButton(
              label: '查看趋势 ›',
              onTap: () => context.open(AppRoutes.trends),
            ),
          ),
          YounumMutedText(insights.findings.join('\n')),
          const SizedBox(height: YounumDimens.gapLg),
          PrimaryAction(
            label: '保存我的月度回顾',
            style: YounumActionStyle.secondary,
            onPressed: () => context.open(AppRoutes.share),
          ),
        ],
      ),
    );
  }

  /// 环形图切片。净额为 0 的分类不会出现在 [MonthlySummary.byCategory] 里，
  /// 所以这里不需要再过滤。
  static List<YounumDonutSlice> _donutSlices(MonthlySummary summary) {
    if (summary.netExpenseCents <= 0) return const <YounumDonutSlice>[];
    return <YounumDonutSlice>[
      for (var index = 0; index < summary.byCategory.length; index++)
        YounumDonutSlice(
          label: summary.byCategory[index].categoryName,
          value: summary.byCategory[index].netCents.toDouble(),
          color: _seriesColor(index),
        ),
    ];
  }

  /// 图例取前 5 类，其余合并，避免图例过长。
  static List<YounumLegendEntry> _legendEntries(MonthlySummary summary) {
    const visible = 5;
    final entries = <YounumLegendEntry>[];
    for (var index = 0;
        index < summary.byCategory.length && index < visible;
        index++) {
      final category = summary.byCategory[index];
      final basisPoints = summary.shareBasisPointsOf(category.categoryId);
      entries.add(
        YounumLegendEntry(
          label: category.categoryName,
          value: basisPoints == null ? '—' : _percentText(basisPoints),
          color: _seriesColor(index),
        ),
      );
    }
    if (summary.byCategory.length > visible) {
      var rest = 0;
      for (final category in summary.byCategory.skip(visible)) {
        rest += category.netCents;
      }
      final total = summary.netExpenseCents;
      entries.add(
        YounumLegendEntry(
          label: '其余',
          value: total <= 0
              ? '—'
              : '${(rest * 100 / total).toStringAsFixed(1)}%',
          color: const Color(YounumColors.categorySeriesRest),
        ),
      );
    }
    return entries;
  }
}

// -----------------------------------------------------------------------------
// breakdown —— 消费分类详情
// -----------------------------------------------------------------------------

/// 分类金额与占比。
///
/// 分类金额之和等于消费净额；占比以分类净额除以总净消费计算
/// （指南 3.4）。四舍五入导致占比和不为 100% 时只展示精度差异，不改金额。
class BreakdownScreen extends StatelessWidget {
  const BreakdownScreen({super.key, this.args = const BreakdownArgs()});

  final BreakdownArgs args;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final registry = CategoryRegistryScope.of(context);
    final overview = ReviewSessionScope.of(context).overview;
    if (overview == null) return const _ReportLoading(title: '消费分布');

    final month = overview.month;
    final summary = overview.summary;
    final categories = summary.byCategory;

    return YounumScreen(
      title: '消费分布',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text('钱花在了这里', style: text.screenTitle)),
              YounumBadge(month.shortLabel),
            ],
          ),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText(
            '共 ${categories.length} 类用途 · '
            '¥${Money.format(summary.netExpenseCents, grouped: true)}',
          ),
          const SizedBox(height: YounumDimens.gap),
          if (categories.isEmpty)
            const YounumEmptyState(
              icon: YounumIcons.navReport,
              title: '这个月还没有可展示的消费',
              description: '完成归类之后，这里会按用途列出每一类的净额与占比。',
            )
          else
            for (var index = 0; index < categories.length; index++)
              YounumListRow(
                leading: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SizedBox(
                      width: 26,
                      child: Text(
                        '${index + 1}'.padLeft(2, '0'),
                        style: text.caption,
                      ),
                    ),
                    YounumTileIcon(
                      iconKey:
                          registry.iconKeyOf(categories[index].categoryName) ??
                          YounumIcons.defaultCategoryIconKey,
                      imagePath: registry.imagePathOfName(
                        categories[index].categoryName,
                      ),
                    ),
                  ],
                ),
                title: categories[index].categoryName,
                subtitleWidget: YounumProgressTrack(
                  // 用「相对最高一项」画长度条，视觉上最长的正好占满。
                  value: categories.first.netCents == 0
                      ? 0
                      : categories[index].netCents / categories.first.netCents,
                  height: 4,
                  margin: const EdgeInsets.only(top: 8, bottom: 2),
                  semanticLabel: '${categories[index].categoryName} 占比',
                ),
                trailingWidget: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Text(
                      '¥${Money.format(categories[index].netCents, grouped: true)}',
                      style: text.amountRow,
                    ),
                    const SizedBox(height: 4),
                    YounumCaptionText(
                      switch (summary.shareBasisPointsOf(categories[index].categoryId)) {
                        final basisPoints? => _percentText(basisPoints),
                        _ => '—',
                      },
                    ),
                  ],
                ),
                // 下钻到该分类的具体消费记录（指南 10.3）。
                onTap: () => context.open(
                  AppRoutes.transactions,
                  arguments: TransactionsArgs(
                    categoryName: categories[index].categoryName,
                  ),
                ),
                showDivider: index != categories.length - 1,
              ),
          const YounumPillNote('点击任一分类，查看对应的消费记录'),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// trends —— 月度趋势与对比
// -----------------------------------------------------------------------------

/// 趋势与环比。
///
/// 缺失的月份不伪造数据；零分母与部分月份单独处理（指南 3.4 / 第 5 节 trends）。
class TrendsScreen extends StatelessWidget {
  const TrendsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final session = ReviewSessionScope.of(context);
    final report = session.report;
    final insights = session.insights;
    if (report == null || insights == null) {
      return const _ReportLoading(title: '消费趋势');
    }

    final summary = report.overview.summary;
    final month = report.overview.month;
    final window = report.trend;
    final recordedCount = window.where((point) => point.hasRecords).length;

    return YounumScreen(
      title: '消费趋势',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('留一点空间，给下个月', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText('看见变化，不给生活打分。'),
          const SizedBox(height: YounumDimens.gap),
          YounumPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text('近 ${window.length} 个月', style: text.sectionTitle),
                    ),
                    const YounumCaptionText('单位 / 元'),
                  ],
                ),
                const SizedBox(height: YounumDimens.gap),
                AmountText(
                  cents: summary.netExpenseCents,
                  scale: AmountScale.panel,
                ),
                const SizedBox(height: YounumDimens.gapSm),
                if (insights.canShowMonthOverMonthPercent)
                  YounumBadge(
                    '环比 ${insights.monthOverMonthBasisPoints! > 0 ? '+' : '\u2212'}'
                    '${_percentText(insights.monthOverMonthBasisPoints!.abs())}',
                  )
                else if (insights.canShowMonthOverMonthDelta)
                  YounumBadge(
                    '比上月${(insights.monthOverMonthDeltaCents ?? 0) > 0 ? '多' : '少'} '
                    '¥${Money.format((insights.monthOverMonthDeltaCents ?? 0).abs(), grouped: true)}',
                  )
                else
                  // 这里是浅色面板，不能用 onDark 色调：那套配色是给
                  // 首页的深色面板用的，浅底浅字会直接看不见。
                  const YounumBadge('暂无可比月份'),
                _TrendChart(points: window, peak: report.trendPeakCents),
              ],
            ),
          ),
          YounumPanel(
            child: Column(
              children: <Widget>[
                YounumLineInfo(
                  label: insights.averageUsesFullMonth ? '日均消费' : '已覆盖范围日均',
                  value: insights.dayAverageCents == null
                      ? '—'
                      : '¥${Money.format(insights.dayAverageCents!, grouped: true)}'
                          '${insights.averageUsesFullMonth ? '' : '（${insights.averageDenominatorDays} 天）'}',
                ),
                YounumLineInfo(
                  label: '单笔最高',
                  value: insights.highestSingle == null
                      ? '—'
                      : '¥${Money.format(insights.highestSingle!.amountCents, grouped: true)}'
                          ' · ${insights.highestSingleCategoryName ?? insights.highestSingle!.nature.label}',
                ),
                YounumLineInfo(
                  label: '消费最少的一天',
                  value: insights.lowestSpendingDay == null
                      ? '—'
                      : '${month.month}月${insights.lowestSpendingDay!.day}日 '
                          '¥${Money.format(insights.lowestSpendingDay!.expenseCents, grouped: true)}',
                ),
              ],
            ),
          ),
          const YounumSectionHeader(title: '变化来自哪里'),
          if (insights.categoryChanges.isEmpty)
            YounumMutedText(
              insights.canShowMonthOverMonthDelta
                  ? '这个月与上月相比，各分类没有变化。'
                  : '需要连续两个范围完整的月份才能比较分类变化。'
                      '现在只有 $recordedCount 个月有记录。',
            )
          else
            for (final change in insights.categoryChanges)
              YounumLineInfo(
                label: change.categoryName,
                value:
                    '比上月${change.isIncrease ? '增加' : '减少'} '
                    '¥${Money.format(change.deltaCents.abs(), grouped: true)}',
              ),
          const YounumNotice(
            '按完整自然月比较，包含已确认消费及关联退款，不含收入与账户转账。'
            '首次使用时不展示环比；上月为零时只显示金额差，不显示「无限增长」。',
          ),
        ],
      ),
    );
  }
}

/// 趋势柱状图。
///
/// 用普通 Widget 搭建而不是截图，并给出文字摘要（指南 6.2）。
class _TrendChart extends StatelessWidget {
  const _TrendChart({required this.points, required this.peak});

  final List<MonthTrendPoint> points;
  final int peak;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final colors = YounumColors.of(context);

    final summary = points
        .map(
          (point) => point.hasRecords
              ? '${point.month.month}月 ${Money.format(point.netExpenseCents, grouped: true)}元'
              : '${point.month.month}月 无记录',
        )
        .join('，');

    return Semantics(
      label: '近 ${points.length} 个月消费',
      value: summary,
      child: ExcludeSemantics(
        child: SizedBox(
          height: 140,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              for (var index = 0; index < points.length; index++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: FractionallySizedBox(
                              // 没有记录的月份柱子高度为 0，但月份标签仍然保留，
                              // 不把空月份从窗口里抹掉。
                              heightFactor: peak <= 0
                                  ? 0
                                  : (points[index].netExpenseCents / peak)
                                      .clamp(0.0, 1.0),
                              child: Container(
                                width: 26,
                                decoration: BoxDecoration(
                                  color: index == points.length - 1
                                      ? colors.primaryColor
                                      : const Color(YounumColors.chartBar),
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(5),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text('${points[index].month.month}月', style: text.micro),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// transactions —— 交易明细 · 搜索与筛选
// -----------------------------------------------------------------------------

/// 明细检索。
///
/// 支持按整理状态筛选与按商户 / 用途搜索；修改后所有相关页面金额一致
/// （指南第 5 节 transactions）。
class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key, this.args = const TransactionsArgs()});

  final TransactionsArgs args;

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  static const List<String> _filters = <String>['全部', '待整理', '已归类', '非消费'];

  final TextEditingController _searchController = TextEditingController();
  String _filter = '全部';
  String _query = '';

  /// 从分类详情下钻进来时预先应用的分类筛选（指南 10.3）。
  String? _category;

  @override
  void initState() {
    super.initState();
    _category = widget.args.categoryName;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 当月的全部记录。
  List<LedgerTransaction> get _all {
    final report = ReviewSessionScope.of(context).report;
    if (report == null) return const <LedgerTransaction>[];
    final month = report.overview.month;
    return <LedgerTransaction>[
      for (final transaction in report.dataset.transactions)
        if (transaction.month == month) transaction,
    ]..sort((a, b) {
        final byTime = b.occurredAtMs.compareTo(a.occurredAtMs);
        return byTime != 0 ? byTime : b.id.compareTo(a.id);
      });
  }

  /// 某笔记录归类到的分类名。
  String? _categoryOf(LedgerTransaction transaction) {
    final dataset = ReviewSessionScope.of(context).report?.dataset;
    if (dataset == null) return null;
    final allocations = dataset.allocationsOf(transaction.id);
    if (allocations.isEmpty) return null;
    return dataset.categoryName(allocations.first.categoryId);
  }

  /// 当前筛选 + 搜索之后的记录。
  List<LedgerTransaction> _visible(List<LedgerTransaction> all) {
    var list = all.where((transaction) {
      if (_category != null && _categoryOf(transaction) != _category) {
        return false;
      }
      switch (_filter) {
        case '待整理':
          return transaction.reviewStatus != ReviewStatus.resolved &&
              transaction.nature.isExpense;
        case '已归类':
          return transaction.reviewStatus == ReviewStatus.resolved;
        case '非消费':
          return !transaction.nature.isExpense;
        default:
          return true;
      }
    }).toList();

    final needle = _query.trim().toLowerCase();
    if (needle.isNotEmpty) {
      list = list
          .where(
            (transaction) =>
                transaction.merchant.toLowerCase().contains(needle) ||
                (_categoryOf(transaction) ?? '')
                    .toLowerCase()
                    .contains(needle) ||
                transaction.nature.label.contains(needle),
          )
          .toList();
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final session = ReviewSessionScope.of(context);
    final report = session.report;
    if (report == null) return const _ReportLoading(title: '全部明细');

    final month = report.overview.month;
    final all = _all;
    final visible = _visible(all);
    final registry = CategoryRegistryScope.of(context);

    return YounumScreen(
      title: '全部明细',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            _filter == '全部' && _category == null
                ? '每一笔，都能找到'
                : '${_category ?? ''}$_filter记录',
            style: text.screenTitle,
          ),
          const SizedBox(height: YounumDimens.gap),
          TextField(
            controller: _searchController,
            decoration: const InputDecoration(
              hintText: '搜索商户或用途',
              prefixIcon: Icon(YounumIcons.search),
            ),
            textInputAction: TextInputAction.search,
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: YounumDimens.gap),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              if (_category != null)
                YounumChip(
                  label: '$_category ✕',
                  selected: true,
                  semanticPrefix: '清除分类筛选',
                  onTap: () => setState(() => _category = null),
                ),
              for (final filter in _filters)
                YounumChip(
                  label: filter,
                  selected: _filter == filter,
                  semanticPrefix: '筛选',
                  onTap: () => setState(() => _filter = filter),
                ),
            ],
          ),
          const SizedBox(height: YounumDimens.gap),
          Row(
            children: <Widget>[
              Expanded(
                child: YounumMutedText(
                  '${month.label} · ${session.isDemoLedger ? '示例账本 ' : ''}'
                  '${visible.length} / ${all.length} 笔',
                ),
              ),
              PlainTextButton(
                label: '切换月份',
                onTap: () => context.open(AppRoutes.months),
              ),
            ],
          ),
          const SizedBox(height: YounumDimens.gapSm),
          if (visible.isEmpty)
            const YounumEmptyState(
              icon: YounumIcons.search,
              title: '暂无符合条件的记录',
              description: '换一个筛选条件或清空搜索词再试。',
            )
          else
            for (var index = 0; index < visible.length; index++)
              YounumListRow(
                key: ValueKey<int>(visible[index].id),
                title: visible[index].merchant,
                subtitle:
                    '${StatisticsTime.formatShort(visible[index].occurredAtMs)} · '
                    '${_categoryOf(visible[index]) ?? visible[index].nature.label}'
                    '${visible[index].reviewStatus == ReviewStatus.deferred ? ' · 稍后处理' : ''}',
                iconKey: registry.iconKeyOf(_categoryOf(visible[index]) ?? '') ??
                    YounumIcons.defaultCategoryIconKey,
                imagePath: registry.imagePathOfName(
                  _categoryOf(visible[index]) ?? '',
                ),
                trailingText: _signedAmount(visible[index]),
                onTap: () => context.open(
                  AppRoutes.transactionDetail,
                  arguments: TransactionDetailArgs(
                    transactionId: '${visible[index].id}',
                  ),
                ),
                showDivider: index != visible.length - 1,
              ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// share —— 月报分享与导出
// -----------------------------------------------------------------------------

/// 分享与导出。
///
/// 指南 8.1 的三条硬要求在这里落地：
///
/// * 隐私开关必须作用于**最终文件**，不只是屏幕上的遮罩 —— 所以开关先变成
///   `SharePosterSpec` 的一部分，再交给渲染器；渲染器拿不到交易，漏不出金额。
/// * 每次进入默认隐藏金额，不沿用上次公开出去的设置。
/// * 用户取消保存**不显示成功**；写失败要如实说原因。
class ShareScreen extends StatefulWidget {
  const ShareScreen({super.key});

  @override
  State<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends State<ShareScreen> {
  /// 每次进入默认隐藏金额，避免沿用上次公开设置。
  bool _showAmount = false;

  /// 正在渲染或保存：按钮置灰，避免连点两次弹出两个系统界面。
  bool _busy = false;

  ExportPrivacy get _privacy => ExportPrivacy(showAmount: _showAmount);

  PosterPalette _paletteOf(BuildContext context) {
    final colors = YounumColors.of(context);
    return PosterPalette(
      background: colors.tintColor,
      foreground: colors.inkColor,
      muted: colors.mutedColor,
    );
  }

  Future<void> _export({
    required MonthOverview overview,
    required LedgerDataset dataset,
    required ExportScope ports,
    required bool poster,
  }) async {
    if (_busy) return;
    final saver = ports.documentSaver;
    // 保存前先确认平台真的有这个能力，避免点了之后才弹一句「不支持」。
    if (!await saver.isAvailable()) {
      if (!mounted) return;
      showYounumToast(context, '这个平台上还不能保存文件');
      return;
    }
    if (!mounted) return;

    // 先算内容再动手：海报的隐私开关在这里就定型了（不在渲染之后补遮罩）。
    final spec = poster
        ? SharePosterRules.build(
            overview: overview,
            privacy: _privacy,
            palette: _paletteOf(context),
          )
        : null;

    setState(() => _busy = true);
    final SaveOutcome outcome;
    try {
      outcome = poster
          ? await savePoster(
              saver: saver,
              maker: ports.posterMaker,
              spec: spec!,
              month: overview.month,
            )
          : await saveDetailCsv(
              saver: saver,
              dataset: dataset,
              month: overview.month,
            );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;

    switch (outcome) {
      case DocumentSaved(:final name):
        showYounumToast(context, '已保存：$name');
      case SaveCanceled():
        // 取消不是错误，也不是成功：什么都不说，安静回到原样。
        break;
      case SaveFailed(:final message):
        showYounumToast(context, message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final session = ReviewSessionScope.of(context);
    final overview = session.overview;
    final dataset = session.report?.dataset;
    if (overview == null || dataset == null) {
      return const _ReportLoading(title: '保存月度回顾');
    }

    final ports = ExportScope.of(context);
    final spec = SharePosterRules.build(
      overview: overview,
      privacy: _privacy,
      palette: _paletteOf(context),
    );

    return YounumScreen(
      title: '保存月度回顾',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('把这个月，轻轻收好', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gap),
          // 预览就是导出文件的内容：同一份 SharePosterSpec、同一份版式。
          PosterPreview(
            spec: spec,
            semanticLabel: _showAmount
                ? '月度回顾预览，含金额'
                : '月度回顾预览，金额已隐藏',
          ),
          YounumSwitchRow(
            label: '展示具体金额',
            description: _showAmount
                ? '导出的图片会包含金额数字。'
                : '默认隐藏金额：导出的图片里不会出现金额。',
            value: _showAmount,
            onChanged: (value) => setState(() => _showAmount = value),
          ),
          const YounumPillNote('不展示商户、交易单号和个人身份信息。'),
          PrimaryAction(
            label: _busy ? '正在保存…' : '导出月度回顾',
            onPressed: _busy
                ? null
                : () => _export(
                    overview: overview,
                    dataset: dataset,
                    ports: ports,
                    poster: true,
                  ),
          ),
          const SizedBox(height: YounumDimens.gap),
          PrimaryAction(
            label: '导出明细 CSV',
            style: YounumActionStyle.secondary,
            onPressed: _busy
                ? null
                : () => _export(
                    overview: overview,
                    dataset: dataset,
                    ports: ports,
                    poster: false,
                  ),
          ),
          const YounumDemoNote(
            '导出走系统的「创建文档」流程，由你选保存位置；取消不会有任何提示，'
            '失败会说明原因。CSV 是数据导出，不等同于完整备份。',
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// months —— 月份切换与历史记录
// -----------------------------------------------------------------------------

/// 历史月份。
///
/// 切月后必须读取对应月份的数据，不能展示同一份固定报告（阶段 5 验收）。
class MonthsScreen extends StatefulWidget {
  const MonthsScreen({super.key});

  @override
  State<MonthsScreen> createState() => _MonthsScreenState();
}

class _MonthsScreenState extends State<MonthsScreen> {
  int? _year;
  int? _pickedMonth;

  /// 年份默认取当前会话所在月份，切换年份后按用户选择走。
  int _effectiveYear(YearMonth current) => _year ?? current.year;

  int get _selectedMonth => _pickedMonth ?? 0;

  /// 某个月的状态说明。
  String _statusOf(MonthOverview overview) {
    if (!overview.summary.hasRecords) return '—';
    if (overview.progress.isCompleteMonth) return '已完成';
    if (overview.progress.isFullyProcessed) return '待确认';
    return '整理中';
  }

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final session = ReviewSessionScope.of(context);
    final report = session.report;
    final current = session.month;
    if (report == null || current == null) {
      return const _ReportLoading(title: '我的月份');
    }

    final year = _effectiveYear(current);
    final selected = _selectedMonth;
    YearMonth monthOf(int month) => YearMonth(year, month);
    MonthOverview overviewOf(int month) => report.overviewOf(monthOf(month));

    return YounumScreen(
      title: '我的月份',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('生活一月一页', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gap),
          Row(
            children: <Widget>[
              YounumIconButton(
                icon: YounumIcons.back,
                semanticLabel: '上一年',
                onPressed: () => setState(() {
                  _year = year - 1;
                  _pickedMonth = null;
                }),
              ),
              Expanded(
                child: Text(
                  '$year 年',
                  style: text.sectionTitle,
                  textAlign: TextAlign.center,
                ),
              ),
              YounumIconButton(
                icon: YounumIcons.forward,
                semanticLabel: '下一年',
                onPressed: () => setState(() {
                  _year = year + 1;
                  _pickedMonth = null;
                }),
              ),
            ],
          ),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText(
            '已记录 ${report.recordedMonths.length} 个月'
            '${report.recordedMonths.isEmpty ? '' : '，最近的是 ${report.recordedMonths.first.label}'}',
          ),
          const SizedBox(height: YounumDimens.gap),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.6,
            children: <Widget>[
              for (var month = 1; month <= 12; month++)
                _MonthCell(
                  month: month,
                  status: _statusOf(overviewOf(month)),
                  selected: month == selected ||
                      (selected == 0 && monthOf(month) == current),
                  onTap: () => setState(() => _pickedMonth = month),
                ),
            ],
          ),
          const SizedBox(height: YounumDimens.gap),
          YounumPanel(
            tone: YounumPanelTone.soft,
            child: Builder(
              builder: (context) {
                final target = selected == 0 ? current : monthOf(selected);
                final overview = report.overviewOf(target);
                final hasRecords = overview.summary.hasRecords;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            '${target.month} 月账单',
                            style: text.sectionTitle,
                          ),
                        ),
                        YounumBadge(
                          hasRecords ? _statusOf(overview) : '尚无记录',
                        ),
                      ],
                    ),
                    const SizedBox(height: YounumDimens.gapSm),
                    YounumMutedText(
                      hasRecords
                          // 有记录就如实给出金额，不等到「整理完」才显示。
                          ? '已导入 ${overview.summary.importedExpenseCount} 笔 · '
                              '净消费 ¥${Money.format(overview.summary.netExpenseCents, grouped: true)}'
                          : '${target.month} 月还没有导入账单，不会有任何金额或分类数据。',
                    ),
                    const SizedBox(height: YounumDimens.gap),
                    PrimaryAction(
                      label: '查看这个月',
                      trailingArrow: true,
                      onPressed: hasRecords
                          ? () async {
                              await session.selectMonth(target);
                              if (!context.mounted) return;
                              Navigator.of(context).maybePop();
                            }
                          : null,
                    ),
                  ],
                );
              },
            ),
          ),
          const YounumDemoNote(
            '切换月份会读取对应月份的真实数据；没有记录的月份不显示任何金额。',
          ),
        ],
      ),
    );
  }
}

class _MonthCell extends StatelessWidget {
  const _MonthCell({
    required this.month,
    required this.status,
    required this.selected,
    required this.onTap,
  });

  final int month;
  final String status;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final text = YounumText.of(context);
    final hasRecords = status != '—';
    return Semantics(
      selected: selected,
      button: true,
      label: '$month 月，${hasRecords ? status : '没有记录'}',
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? colors.primaryColor : colors.softColor,
              borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  '$month月',
                  style: text.body.copyWith(
                    fontWeight: FontWeight.w500,
                    color: selected ? colors.onPrimaryColor : colors.inkColor,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  status,
                  style: text.micro.copyWith(
                    color: selected ? colors.onPrimaryColor : colors.mutedColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
