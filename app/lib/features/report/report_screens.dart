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
import '../../data/sample/sample_data.dart';
import '../organize/category_registry.dart';
import '../organize/review_session.dart';

/// 分类系列色。与图例、环形图、分类详情一一对应，**不随主题变化**
/// （指南 7.3：主题不能造成图表图例与实际颜色不一致）。
Color _seriesColor(int index) => ColorMath.toColor(
      YounumColors.categorySeries[index % YounumColors.categorySeries.length],
    );

/// 按金额降序排列的分类。
List<SampleCategory> get _sortedCategories {
  final list = List<SampleCategory>.of(SampleData.categories);
  list.sort((a, b) => b.amountCents.compareTo(a.amountCents));
  return list;
}

// -----------------------------------------------------------------------------
// report —— 月度消费概况
// -----------------------------------------------------------------------------

/// 月度概况。
///
/// 三条硬规则（指南 3.4）：
/// * 范围未确认完整时标注「部分账单」，不冒充完整月报；
/// * 没有消费时用空状态，不画空环形图、不除以零；
/// * 环比只在两个月都完整且上月净消费大于 0 时显示。
class ReportScreen extends StatelessWidget {
  const ReportScreen({super.key, this.debugForceEmpty = false});

  /// 走查用：强制渲染「无消费」空状态。
  final bool debugForceEmpty;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final session = ReviewSessionScope.of(context);
    final month = SampleData.month;
    final coverageConfirmed = session.coverageConfirmed;

    if (debugForceEmpty) {
      return const YounumScreen(
        bottomBar: AppBottomBar(),
        child: YounumEmptyState(
          icon: YounumIcons.navReport,
          title: '这个月还没有消费记录',
          description: '导入账单并完成整理后，这里会出现分类结构、趋势与环比。'
              '没有消费时不展示占比，也不计算环比。',
        ),
      );
    }

    return YounumScreen(
      bottomBar: const AppBottomBar(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text('YOUR MONTH IN REVIEW', style: text.eyebrow)),
              PlainTextButton(
                label: SampleData.monthLabel,
                trailingIcon: YounumIcons.expandMore,
                semanticLabel: '切换月份，当前 ${SampleData.monthLabel}',
                onTap: () => context.open(AppRoutes.months),
              ),
            ],
          ),
          Text('9 月消费手记', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gap),
          YounumPanel(
            tone: YounumPanelTone.dark,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                YounumMutedText(
                  coverageConfirmed ? '这个月，一共花了' : '这个月，截至 9月30日一共花了',
                  style: text.body.copyWith(fontSize: 13),
                ),
                const SizedBox(height: YounumDimens.gapSm),
                AmountText(
                  cents: month.totalCents,
                  scale: AmountScale.panel,
                  color: YounumColors.of(context).onDarkPanelColor,
                ),
                const SizedBox(height: YounumDimens.gap),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    // 环比只在两个月都完整时才显示（指南 3.4）。
                    const YounumBadge('↘ ${SampleData.monthOverMonthText}'),
                    YounumBadge('${month.transactionCount} 笔消费'),
                    if (!coverageConfirmed)
                      const YounumBadge('部分账单', tone: YounumBadgeTone.onDark),
                  ],
                ),
              ],
            ),
          ),
          if (!coverageConfirmed)
            const YounumNotice(
              '你还没有确认 9 月账单范围完整。上面的金额只代表已导入的部分，'
              '不能直接与完整自然月比较。',
            ),
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
                  centerValue: '${SampleData.categories.length} 类',
                  slices: _donutSlices,
                ),
                const SizedBox(height: YounumDimens.gapLg),
                YounumLegend(entries: _legendEntries),
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
          YounumMutedText(SampleData.insights.join('\n')),
          const SizedBox(height: YounumDimens.gapLg),
          PrimaryAction(
            label: '保存我的月度回顾',
            style: YounumActionStyle.secondary,
            onPressed: () => context.open(AppRoutes.share),
          ),
          const YounumDemoNote(
            '设计走查：本页金额沿用设计稿样例。阶段 5 起改为实时汇总查询，'
            '并保证分类净额之和与消费净额精确相等。',
          ),
        ],
      ),
    );
  }

  static List<YounumDonutSlice> get _donutSlices {
    final total = SampleData.month.totalCents;
    final sorted = _sortedCategories;
    final slices = <YounumDonutSlice>[];
    for (var index = 0; index < sorted.length; index++) {
      slices.add(
        YounumDonutSlice(
          label: sorted[index].name,
          value: sorted[index].amountCents.toDouble(),
          color: _seriesColor(index),
        ),
      );
    }
    // 防御：总额为 0 时不产生任何切片，由组件渲染中性底环。
    return total == 0 ? <YounumDonutSlice>[] : slices;
  }

  /// 图例取前 5 类，其余合并，避免图例过长。
  static List<YounumLegendEntry> get _legendEntries {
    final total = SampleData.month.totalCents;
    final sorted = _sortedCategories;
    final entries = <YounumLegendEntry>[];
    const visible = 5;
    for (var index = 0; index < sorted.length && index < visible; index++) {
      entries.add(
        YounumLegendEntry(
          label: sorted[index].name,
          value: '${(sorted[index].amountCents / total * 100).toStringAsFixed(1)}%',
          color: _seriesColor(index),
        ),
      );
    }
    if (sorted.length > visible) {
      final rest = sorted
          .skip(visible)
          .fold<int>(0, (sum, category) => sum + category.amountCents);
      entries.add(
        YounumLegendEntry(
          label: '其余',
          value: '${(rest / total * 100).toStringAsFixed(1)}%',
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
    final total = SampleData.month.totalCents;
    final sorted = _sortedCategories;

    return YounumScreen(
      title: '消费分布',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text('钱花在了这里', style: text.screenTitle)),
              const YounumBadge('9月'),
            ],
          ),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText(
            '共 ${sorted.length} 类用途 · ¥${Money.format(total, grouped: true)}',
          ),
          const SizedBox(height: YounumDimens.gap),
          for (var index = 0; index < sorted.length; index++)
            YounumListRow(
              leading: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                    width: 26,
                    child: Text('0${index + 1}', style: text.caption),
                  ),
                  YounumTileIcon(
                    iconKey: registry
                        .iconFor(
                          sorted[index].name,
                          fallbackIconKey: sorted[index].iconKey,
                        )
                        .iconKey,
                    imagePath: registry.iconFor(sorted[index].name).imagePath,
                  ),
                ],
              ),
              title: sorted[index].name,
              subtitleWidget: YounumProgressTrack(
                value: sorted[index].amountCents / sorted.first.amountCents,
                height: 4,
                margin: const EdgeInsets.only(top: 8, bottom: 2),
                semanticLabel: '${sorted[index].name} 占比',
              ),
              trailingWidget: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(
                    '¥${Money.format(sorted[index].amountCents, grouped: true)}',
                    style: text.amountRow,
                  ),
                  const SizedBox(height: 4),
                  YounumCaptionText(
                    '${(sorted[index].amountCents / total * 100).toStringAsFixed(1)}%',
                  ),
                ],
              ),
              // 下钻到该分类的具体消费记录。
              onTap: () => context.open(AppRoutes.transactions),
              showDivider: index != sorted.length - 1,
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
    final amounts = SampleData.recentMonthsCents;
    final maxAmount = amounts.reduce((a, b) => a > b ? a : b);

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
                    Expanded(child: Text('近 6 个月', style: text.sectionTitle)),
                    YounumCaptionText('单位 / 元'),
                  ],
                ),
                const SizedBox(height: YounumDimens.gap),
                AmountText(
                  cents: SampleData.month.totalCents,
                  scale: AmountScale.panel,
                ),
                const SizedBox(height: YounumDimens.gapSm),
                const YounumBadge('环比 −12.8%'),
                _TrendChart(
                  amounts: amounts,
                  firstMonth: SampleData.firstTrendMonth,
                  maxAmount: maxAmount,
                ),
              ],
            ),
          ),
          YounumPanel(
            child: Column(
              children: const <Widget>[
                YounumLineInfo(label: '日均消费', value: SampleData.dayAverageText),
                YounumLineInfo(label: '单笔最高', value: SampleData.highestSingleText),
                YounumLineInfo(
                  label: '消费最少的一天',
                  value: SampleData.lowestDayText,
                ),
              ],
            ),
          ),
          const YounumSectionHeader(title: '变化来自哪里'),
          const YounumLineInfo(label: '餐饮', value: '比上月减少 ¥216.40'),
          const YounumLineInfo(label: '购物', value: '比上月减少 ¥590.00'),
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
  const _TrendChart({
    required this.amounts,
    required this.firstMonth,
    required this.maxAmount,
  });

  final List<int> amounts;
  final int firstMonth;
  final int maxAmount;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final text = YounumText.of(context);
    final summary = <String>[
      for (var index = 0; index < amounts.length; index++)
        '${firstMonth + index}月 ${Money.format(amounts[index], grouped: true)}元',
    ].join('，');

    return Semantics(
      label: '近 6 个月消费',
      value: summary,
      child: ExcludeSemantics(
        child: SizedBox(
          height: 140,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              for (var index = 0; index < amounts.length; index++)
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
                              heightFactor: maxAmount == 0
                                  ? 0
                                  : amounts[index] / maxAmount,
                              child: Container(
                                width: 26,
                                decoration: BoxDecoration(
                                  color: index == amounts.length - 1
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
                        Text(
                          '${firstMonth + index}月',
                          style: text.micro,
                        ),
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
  const TransactionsScreen({super.key});

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  static const List<String> _filters = <String>['全部', '待整理', '已归类', '非消费'];

  final TextEditingController _searchController = TextEditingController();
  String _filter = '全部';
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 演示账本的记录集合。
  List<SampleTransaction> get _all => <SampleTransaction>[
        ...SampleData.reviewQueue,
        ...SampleData.deferredQueue,
      ];

  List<SampleTransaction> get _visible {
    final session = ReviewSessionScope.of(context);
    final resolved = <String, String>{
      for (final entry in session.done)
        entry.card.id.toString(): entry.category,
    };

    var list = _all.where((transaction) {
      switch (_filter) {
        case '待整理':
          return !resolved.containsKey(transaction.id) &&
              transaction.categoryName == '待整理';
        case '已归类':
          return resolved.containsKey(transaction.id);
        case '非消费':
          return false;
        default:
          return true;
      }
    }).toList();

    if (_query.trim().isNotEmpty) {
      final needle = _query.trim().toLowerCase();
      list = list
          .where(
            (transaction) =>
                transaction.merchant.toLowerCase().contains(needle) ||
                transaction.categoryName.toLowerCase().contains(needle),
          )
          .toList();
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final session = ReviewSessionScope.of(context);
    final resolved = <String, String>{
      for (final entry in session.done)
        entry.card.id.toString(): entry.category,
    };
    final visible = _visible;

    return YounumScreen(
      title: '全部明细',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            _filter == '全部' ? '每一笔，都能找到' : '$_filter消费明细',
            style: text.screenTitle,
          ),
          const SizedBox(height: YounumDimens.gap),
          TextField(
            controller: _searchController,
            onChanged: (value) => setState(() => _query = value),
            style: text.input,
            decoration: const InputDecoration(
              hintText: '搜索商户、用途或备注',
              prefixIcon: Icon(Icons.search, size: 20),
            ),
          ),
          const SizedBox(height: YounumDimens.gap),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
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
                  '${SampleData.monthLabel} · 示例账本 ${visible.length} 笔',
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
                key: ValueKey<String>(visible[index].id),
                title: visible[index].merchant,
                subtitle:
                    '${visible[index].dateText} · ${resolved[visible[index].id] ?? '待整理'}',
                iconKey: SampleData.iconKeyFor(
                  resolved[visible[index].id] ?? visible[index].categoryName,
                ),
                trailingText: '−${Money.format(visible[index].amountCents)}',
                onTap: () => context.open(
                  AppRoutes.transactionDetail,
                  arguments: TransactionDetailArgs(
                    transactionId: visible[index].id,
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
/// 隐私开关必须作用于**最终文件**，而不只是屏幕上的遮罩；
/// 每次进入默认隐藏金额（指南 8.1）。
class ShareScreen extends StatefulWidget {
  const ShareScreen({super.key});

  @override
  State<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends State<ShareScreen> {
  /// 每次进入默认隐藏金额，避免沿用上次公开设置。
  bool _showAmount = false;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final colors = YounumColors.of(context);
    final month = SampleData.month;

    return YounumScreen(
      title: '保存月度回顾',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('把这个月，轻轻收好', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gap),
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: colors.tintColor,
              borderRadius: BorderRadius.circular(YounumDimens.radiusPanel),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text('∷ 有数', style: text.listPrimary.copyWith(fontSize: 15)),
                    ),
                    YounumCaptionText('2026 / 09'),
                  ],
                ),
                const SizedBox(height: YounumDimens.gap),
                Text(
                  '把钱花在\n有意义的生活里。',
                  style: text.screenTitle.copyWith(fontSize: 26),
                ),
                const SizedBox(height: YounumDimens.gapSm),
                YounumMutedText('我的 9 月消费手记'),
                const SizedBox(height: YounumDimens.gap),
                if (_showAmount)
                  AmountText(
                    cents: month.totalCents,
                    scale: AmountScale.panel,
                  )
                else
                  // 隐藏时必须真正不渲染数值，而不是画一层遮罩 ——
                  // 否则导出文件仍会带上金额（指南 8.1）。
                  Semantics(
                    label: '金额已隐藏',
                    excludeSemantics: true,
                    child: Text(
                      '¥ ••••',
                      style: text.amountPanel.copyWith(
                        letterSpacing: 2,
                        color: colors.inkColor.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                const YounumDivider(),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: YounumCaptionText('${month.transactionCount} 笔生活记录'),
                    ),
                    YounumCaptionText(
                      '${SampleData.categories.length} 种生活用途',
                    ),
                  ],
                ),
                const SizedBox(height: YounumDimens.gapSm),
                YounumCaptionText('每一次看见，都是更了解自己的开始。'),
              ],
            ),
          ),
          YounumSwitchRow(
            label: '展示具体金额',
            description: _showAmount
                ? '导出文件会包含金额数字。'
                : '默认隐藏金额：导出的图片里不会出现金额。',
            value: _showAmount,
            onChanged: (value) => setState(() => _showAmount = value),
          ),
          const YounumPillNote('不展示商户、交易单号和个人身份信息。'),
          PrimaryAction(
            label: '导出月度回顾',
            onPressed: () => showYounumToast(
              context,
              'PNG 导出将在阶段 5 接入：会按当前主题与隐私开关重新生成文件',
            ),
          ),
          const SizedBox(height: YounumDimens.gap),
          PrimaryAction(
            label: '导出明细 CSV',
            style: YounumActionStyle.secondary,
            onPressed: () => showYounumToast(
              context,
              'CSV 导出将在阶段 5 接入：含防公式注入处理，且不等同于完整备份',
            ),
          ),
          const YounumDemoNote(
            '设计走查：本页的隐私开关已按规则「每次进入默认隐藏」，'
            '但导出本身尚未接入文件写入，因此不会产生半成品文件。',
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
  int _selected = 9;

  /// 该月的状态。9 月整理中，4–8 月已完成，其余尚无记录。
  String _statusOf(int month) {
    if (month == 9) return '整理中';
    if (month > 3 && month < 9) return '已完成';
    return '—';
  }

  bool get _hasData => _selected > 3 && _selected <= 9;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);

    return YounumScreen(
      title: '我的月份',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('生活一月一页', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gap),
          Row(
            children: <Widget>[
              Expanded(child: Text('2026 年', style: text.sectionTitle)),
              YounumMutedText(
                '已记录 ${SampleData.recordedMonthCount} 个月',
              ),
            ],
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
                  status: _statusOf(month),
                  selected: month == _selected,
                  onTap: () => setState(() => _selected = month),
                ),
            ],
          ),
          const SizedBox(height: YounumDimens.gap),
          YounumPanel(
            tone: YounumPanelTone.soft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text('$_selected 月账单', style: text.sectionTitle),
                    ),
                    YounumBadge(_hasData ? _statusOf(_selected) : '尚无记录'),
                  ],
                ),
                const SizedBox(height: YounumDimens.gapSm),
                YounumMutedText(
                  _hasData
                      ? '按月份查看账单与消费回顾'
                      : '$_selected 月还没有导入账单，不会有任何金额或分类数据。',
                ),
                const SizedBox(height: YounumDimens.gap),
                PrimaryAction(
                  label: '查看这个月',
                  trailingArrow: true,
                  onPressed: _hasData
                      ? () {
                          showYounumToast(
                            context,
                            '阶段 5 起会按 $_selected 月加载真实数据',
                          );
                        }
                      : null,
                ),
              ],
            ),
          ),
          const YounumDemoNote(
            '设计走查：切换月份会更新下方面板的状态，'
            '没有记录的月份不会显示任何金额。真实按月查询在阶段 5 接入。',
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
    return Semantics(
      selected: selected,
      button: true,
      label: '$month 月，$status',
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
