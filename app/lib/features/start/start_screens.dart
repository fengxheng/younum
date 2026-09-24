import 'package:flutter/material.dart';

import '../../app/app_routes.dart';
import '../../core/components/amount_text.dart';
import '../../core/components/buttons.dart';
import '../../core/components/list_row.dart';
import '../../core/components/primitives.dart';
import '../../core/components/progress.dart';
import '../../core/components/screen_scaffold.dart';
import '../../core/designsystem/younum_colors.dart';
import '../../core/designsystem/younum_dimens.dart';
import '../../core/designsystem/younum_icons.dart';
import '../../core/designsystem/younum_text.dart';
import '../../core/money/money.dart';
import '../../core/preferences/app_state_store.dart';
import '../organize/review_session.dart';

/// 示例账本标记。
///
/// 演示账本必须有可见标识，避免用户把样例数字当成自己的账目
/// （实现指南 1.3：示例体验只能进入独立的演示账本）。
class DemoLedgerBadge extends StatelessWidget {
  const DemoLedgerBadge({super.key});

  @override
  Widget build(BuildContext context) {
    if (!AppStateScope.of(context).isDemoLedger) return const SizedBox.shrink();
    return const YounumBadge('示例账本', tone: YounumBadgeTone.warm);
  }
}

// -----------------------------------------------------------------------------
// welcome —— 首次引导
// -----------------------------------------------------------------------------

/// 欢迎与产品引导（三屏）。
///
/// 开始后持久化完成状态，不会每次启动重复出现（阶段 1 验收条件）。
///
/// 三屏缺一不可。首版只做了第一屏，第 2、3 屏（导入整理、月度回顾）是后补的 ——
/// 少掉的那两屏正是产品最需要说清的事：第一次打开的人并不知道「导入账单」
/// 和「月报」是干什么用的。
///
/// 交互按交互补充规范：左滑前进、右滑返回，**首尾不循环**；竖向滑动与不足
/// 50dp 的横向位移都不翻页；前两屏是「下一步」，最后一屏是「开启我的第一份
/// 月账单」；每一屏都能「跳过」。
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  static const List<_OnboardingPage> _pages = <_OnboardingPage>[
    _OnboardingPage(
      eyebrow: 'MAKE SENSE OF YOUR SPENDING',
      title: '钱花在哪，\n心里有数。',
      body: '一张卡片，一笔生活。\n用一点时间，看懂一个月的自己。',
      art: _WelcomeArt(),
    ),
    _OnboardingPage(
      eyebrow: 'ONE TRANSACTION, ONE CARD',
      title: '导入一个月，\n一笔一张整理。',
      body: '导入微信、支付宝或银行卡账单。\n选择用途，让每一笔花费各就各位。',
      art: _OrganizeArt(),
    ),
    _OnboardingPage(
      eyebrow: 'A LITTLE CLARITY, EVERY MONTH',
      title: '看见花费，\n也看见生活。',
      body: '从消费结构到月度回顾，\n看懂钱的去向，找到自己的生活节奏。',
      art: _ReviewArt(),
    ),
  ];

  final PageController _controller = PageController();
  int _index = 0;

  bool get _isLastPage => _index == _pages.length - 1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _goTo(int index) {
    if (index < 0 || index >= _pages.length || index == _index) return;
    // 「减少动画」是系统设置，不只是观感偏好：开启时直接换页。
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _controller.animateToPage(
      index,
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  /// 结束引导。
  ///
  /// 「跳过」与最后一屏的主按钮走同一条路，都要落盘完成状态，
  /// 否则下次启动还会再看到引导页。
  void _finish() {
    AppStateScope.read(context).completeOnboarding();
    context.openAsRoot(AppRoutes.root);
  }

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);

    return YounumScreen(
      // 自己管滚动。外层若再套一个纵向滚动视图，PageView 就拿不到确定高度，
      // 会直接报无界高度。
      scrollable: false,
      padding: const EdgeInsets.fromLTRB(
        YounumDimens.pageHorizontal,
        YounumDimens.pageTop,
        YounumDimens.pageHorizontal,
        YounumDimens.pageBottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('∷ 有数', style: text.sectionTitle.copyWith(fontSize: 18)),
              const Spacer(),
              PlainTextButton(
                label: '跳过',
                semanticLabel: '跳过产品引导',
                onTap: _finish,
              ),
            ],
          ),
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: _pages.length,
              onPageChanged: (int index) => setState(() => _index = index),
              itemBuilder: (BuildContext context, int index) => _OnboardingSlide(
                page: _pages[index],
                index: index,
                total: _pages.length,
              ),
            ),
          ),
          _PageDots(count: _pages.length, index: _index, onTap: _goTo),
          const SizedBox(height: YounumDimens.gapLg),
          PrimaryAction(
            label: _isLastPage ? '开启我的第一份月账单' : '下一步',
            trailingArrow: true,
            onPressed: _isLastPage ? _finish : () => _goTo(_index + 1),
          ),
          const YounumMetaRow(
            icon: YounumIcons.shield,
            text: '无需注册，先体验整理',
          ),
        ],
      ),
    );
  }
}

/// 一屏引导的内容。
class _OnboardingPage {
  const _OnboardingPage({
    required this.eyebrow,
    required this.title,
    required this.body,
    required this.art,
  });

  /// 全大写英文小标。
  final String eyebrow;

  final String title;

  final String body;

  /// 装饰插画（对读屏隐藏）。
  final Widget art;
}

/// 单屏：插画 + 文案。
///
/// 内容装不下时**自己纵向滚动**，而不是把布局挤坏 —— 大字号或多语言下
/// 这里最容易溢出（指南 6.3）。
class _OnboardingSlide extends StatelessWidget {
  const _OnboardingSlide({
    required this.page,
    required this.index,
    required this.total,
  });

  final _OnboardingPage page;
  final int index;
  final int total;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);

    return Semantics(
      // 读屏时需要知道「这是第几屏」，否则三屏内容听不出先后顺序。
      container: true,
      label: '产品介绍，第 ${index + 1} 页，共 $total 页',
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: YounumDimens.gapLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ExcludeSemantics(child: page.art),
              const SizedBox(height: YounumDimens.gapXl),
              Text(
                page.eyebrow,
                textAlign: TextAlign.center,
                style: text.eyebrow,
              ),
              const SizedBox(height: YounumDimens.gap),
              Text(
                page.title,
                textAlign: TextAlign.center,
                style: text.screenTitle.copyWith(fontSize: 29),
              ),
              const SizedBox(height: YounumDimens.gap),
              YounumMutedText(page.body, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}

/// 三屏插画共用的底座：轨道圆圈 + 右下角的圆形浮标。
class _ArtFrame extends StatelessWidget {
  const _ArtFrame({required this.badge, required this.children});

  /// 右下角浮标里的图标。
  final IconData badge;

  /// 叠在轨道上的票据 / 报告卡，自己用 `Positioned` 定位。
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);

    return SizedBox(
      height: 250,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: colors.borderColor),
            ),
          ),
          ...children,
          Positioned(
            right: 8,
            // 放在票据下方，避免遮住卡片文字。
            bottom: 0,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: colors.primaryColor,
                shape: BoxShape.circle,
              ),
              child: Icon(badge, color: colors.onPrimaryColor, size: 22),
            ),
          ),
        ],
      ),
    );
  }
}

/// 第 1 屏的装饰插画：轨道 + 两张小票据 + 浮动对勾。
class _WelcomeArt extends StatelessWidget {
  const _WelcomeArt();

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final text = YounumText.of(context);

    return _ArtFrame(
      badge: Icons.check,
      children: <Widget>[
        Positioned(
          left: 10,
          top: 26,
          child: Transform.rotate(
            angle: -14 * 3.141592653589793 / 180,
            child: _MiniReceipt(
              background: const Color(YounumColors.surface),
              borderColor: colors.borderColor,
              lines: <Widget>[
                Text('一顿好好吃的饭', style: text.micro),
                const Spacer(),
                Text('¥ 48.00', style: text.amountInline),
                const YounumDashedDivider(margin: EdgeInsets.symmetric(vertical: 10)),
                Text('LITTLE MOMENTS', style: text.micro),
              ],
            ),
          ),
        ),
        Positioned(
          right: 12,
          top: 34,
          child: Transform.rotate(
            angle: 11 * 3.141592653589793 / 180,
            child: _MiniReceipt(
              background: colors.tintColor,
              borderColor: colors.borderColor,
              lines: <Widget>[
                Icon(YounumIcons.categoryIcon('coffee'),
                    size: 20, color: colors.inkColor),
                const Spacer(),
                Text('¥ 28.00', style: text.amountInline),
                const SizedBox(height: 6),
                // 限制行数，避免文案过长时撑破固定高度的卡片。
                Text(
                  '给自己的片刻放松',
                  style: text.micro,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 第 2 屏：一张「月账单」票据 + 一张已经归好类的消费票据。
class _OrganizeArt extends StatelessWidget {
  const _OrganizeArt();

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final text = YounumText.of(context);

    return _ArtFrame(
      badge: Icons.check,
      children: <Widget>[
        Positioned(
          left: 10,
          top: 26,
          child: Transform.rotate(
            angle: -14 * 3.141592653589793 / 180,
            child: _MiniReceipt(
              background: const Color(YounumColors.surface),
              borderColor: colors.borderColor,
              lines: <Widget>[
                Icon(YounumIcons.file, size: 20, color: colors.inkColor),
                const SizedBox(height: 18),
                Text('月账单', style: text.amountInline.copyWith(fontSize: 24)),
                const YounumDashedDivider(margin: EdgeInsets.symmetric(vertical: 10)),
                Text('一次导入 · 开始整理', style: text.micro),
              ],
            ),
          ),
        ),
        Positioned(
          right: 12,
          top: 34,
          child: Transform.rotate(
            angle: 11 * 3.141592653589793 / 180,
            child: _MiniReceipt(
              background: colors.tintColor,
              borderColor: colors.borderColor,
              lines: <Widget>[
                Icon(YounumIcons.categoryIcon('food'),
                    size: 20, color: colors.inkColor),
                const Spacer(),
                Text('¥ 48.00', style: text.amountInline),
                const SizedBox(height: 6),
                Text(
                  '餐饮 · 好好吃饭',
                  style: text.micro,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 第 3 屏：一张月度消费手记 + 浮动图表。
class _ReviewArt extends StatelessWidget {
  const _ReviewArt();

  @override
  Widget build(BuildContext context) {
    // 注意：`Transform.rotate` 不是 const 构造，所以这里不能写成 const。
    return _ArtFrame(
      badge: YounumIcons.chart,
      children: <Widget>[
        Transform.rotate(
          angle: -5 * 3.141592653589793 / 180,
          child: const _MonthlyNote(),
        ),
      ],
    );
  }
}

/// 月度消费手记卡片。
///
/// 它比小票据宽（204dp），旋转 5° 后的包围盒还在 250dp 的插画高度内，
/// 再放大就会顶到上方的品牌行。
class _MonthlyNote extends StatelessWidget {
  const _MonthlyNote();

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final text = YounumText.of(context);

    return Container(
      width: 204,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: const Color(YounumColors.surface),
        border: Border.all(color: colors.borderColor),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('我的月度消费手记', style: text.micro),
          const SizedBox(height: 10),
          Text('一月有数', style: text.screenTitle.copyWith(fontSize: 25)),
          const _MonthlyNoteChart(),
          Text('看懂结构 · 回顾生活', style: text.micro),
        ],
      ),
    );
  }
}

/// 手记里的柱状图：五根柱子按固定比例排开，纯装饰。
class _MonthlyNoteChart extends StatelessWidget {
  const _MonthlyNoteChart();

  /// 由高到低的高度比例，与原型一致。
  static const List<double> _heights = <double>[0.80, 0.55, 0.68, 0.35, 0.24];

  static const List<double> _opacities = <double>[1, 0.8, 0.65, 0.5, 0.35];

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);

    return Container(
      height: 82,
      margin: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.borderColor)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          for (var i = 0; i < _heights.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: 10),
            Expanded(
              child: FractionallySizedBox(
                heightFactor: _heights[i],
                alignment: Alignment.bottomCenter,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.primaryColor.withValues(alpha: _opacities[i]),
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(5),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MiniReceipt extends StatelessWidget {
  const _MiniReceipt({
    required this.background,
    required this.borderColor,
    required this.lines,
  });

  final Color background;
  final Color borderColor;
  final List<Widget> lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 152,
      height: 172,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(YounumDimens.radiusPanel),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: lines,
      ),
    );
  }
}

/// 分页圆点：当前页是一条短横，其余是圆点。
///
/// 圆点本身只有 6dp，但每个圆点的**点击区域补足到 48dp**
/// （指南 6.2：不得因为图形小而缩小可点击范围）。点击可以直接跳页，
/// 与原型一致，也省得大屏用户反复滑。
class _PageDots extends StatelessWidget {
  const _PageDots({
    required this.count,
    required this.index,
    required this.onTap,
  });

  final int count;
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        for (var i = 0; i < count; i++)
          YounumPressable(
            onTap: () => onTap(i),
            borderRadius: BorderRadius.circular(YounumDimens.minTouchTarget / 2),
            // 把「第几页 / 当前页」写进朗读文本，否则三个「第 n 页」听不出差异。
            semanticLabel: i == index
                ? '第 ${i + 1} 页，共 $count 页，当前页'
                : '第 ${i + 1} 页，共 $count 页',
            child: SizedBox(
              width: YounumDimens.minTouchTarget,
              height: YounumDimens.minTouchTarget,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: i == index ? 20 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == index ? colors.primaryColor : colors.tintColor,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// empty —— 首页 · 首次使用
// -----------------------------------------------------------------------------

class EmptyHomeScreen extends StatelessWidget {
  const EmptyHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final session = ReviewSessionScope.of(context);

    return YounumScreen(
      bottomBar: const AppBottomBar(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('有数', style: text.sectionTitle.copyWith(fontSize: 20)),
              const Spacer(),
              PlainTextButton(
                label: session.month?.label ?? '',
                trailingIcon: YounumIcons.expandMore,
                semanticLabel: '切换月份，当前 ${session.month?.label ?? ''}',
                onTap: () => context.open(AppRoutes.months),
              ),
            ],
          ),
          const SizedBox(height: YounumDimens.sectionGap),
          Text('这个月的生活，\n从一份账单开始。', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gap),
          YounumMutedText('不用每天记账，也能了解自己的花费。'),
          const SizedBox(height: YounumDimens.gapLg),
          const ExcludeSemantics(child: _WelcomeArt()),
          const SizedBox(height: YounumDimens.gapLg),
          PrimaryAction(
            label: '导入月账单',
            icon: YounumIcons.add,
            onPressed: () => context.open(AppRoutes.billImport),
          ),
          const SizedBox(height: YounumDimens.gap),
          PrimaryAction(
            label: '先用示例账单体验',
            style: YounumActionStyle.secondary,
            onPressed: () async {
              await AppStateScope.read(context).enterDemoLedger();
            },
          ),
          const YounumMetaRow(
            icon: YounumIcons.lock,
            text: '你的账单，仅用于整理和统计',
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// home —— 首页 · 本月整理进度
// -----------------------------------------------------------------------------

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final session = ReviewSessionScope.of(context);
    final overview = session.overview;

    // 还没读到数据前不要先把 0 画出来，否则会闪一下「¥0.00」。
    if (overview == null) {
      return const YounumScreen(
        bottomBar: AppBottomBar(),
        child: Center(child: YounumMutedText('正在读取本地账单…')),
      );
    }

    final summary = overview.summary;
    final progress = overview.progress;
    final monthLabel = session.month?.shortLabel ?? '';

    return YounumScreen(
      bottomBar: const AppBottomBar(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('有数.', style: text.sectionTitle.copyWith(fontSize: 20)),
              const SizedBox(width: YounumDimens.gapSm),
              const DemoLedgerBadge(),
              const Spacer(),
              PlainTextButton(
                label: session.month?.shortLabel ?? '',
                trailingIcon: YounumIcons.expandMore,
                semanticLabel: '切换月份，当前 ${session.month?.label ?? ''}',
                onTap: () => context.open(AppRoutes.months),
              ),
            ],
          ),
          YounumMutedText('慢慢理清，也是一种生活秩序。'),
          const SizedBox(height: YounumDimens.gapLg),

          // 本月已导入支出
          YounumPanel(
            tone: YounumPanelTone.dark,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: YounumMutedText(
                        '$monthLabel已导入支出',
                        style: text.body.copyWith(fontSize: 13),
                      ),
                    ),
                    YounumCaptionText('${session.month?.year ?? ''}'),
                  ],
                ),
                const SizedBox(height: YounumDimens.gap),
                AmountText(
                  cents: summary.importedExpenseCents,
                  scale: AmountScale.panel,
                  color: YounumColors.of(context).onDarkPanelColor,
                ),
                const YounumDivider(),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: YounumCaptionText(
                        '${summary.importedExpenseCount} 笔消费 · '
                        '${overview.sources.length} 个来源',
                      ),
                    ),
                    PlainTextButton(
                      label: '查看明细 ›',
                      onTap: () => context.open(AppRoutes.transactions),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // 整理进度
          YounumPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text('给每笔花费一个归属', style: text.sectionTitle),
                    ),
                    YounumBadge('${progress.percent}%'),
                  ],
                ),
                const SizedBox(height: YounumDimens.gapSm),
                YounumMutedText(
                  '已经整理 ${progress.resolvedCount} 笔，'
                  '剩下 ${progress.pendingCount + progress.deferredCount} 笔慢慢来。',
                ),
                YounumProgressTrack(
                  value: progress.ratio,
                  semanticLabel: '本月整理进度',
                ),
                const SizedBox(height: YounumDimens.gapSm),
                PrimaryAction(
                  label: progress.isFullyProcessed ? '查看整理结果' : '继续整理',
                  trailingArrow: true,
                  onPressed: () => context.selectTab(1),
                ),
              ],
            ),
          ),

          Row(
            children: <Widget>[
              Expanded(child: Text('本月账单', style: text.sectionTitle)),
              PlainTextButton(
                label: '追加导入 +',
                onTap: () => context.open(AppRoutes.billImport),
              ),
            ],
          ),
          const SizedBox(height: YounumDimens.gapSm),
          for (final source in overview.sources)
            YounumListRow(
              title: source.label,
              subtitle: '$monthLabel · ${source.count} 笔',
              icon: YounumIcons.wallet,
              iconTone: YounumTileTone.primary,
              trailingText: '¥${Money.format(source.amountCents, grouped: true)}',
              onTap: () => context.open(AppRoutes.importHistory),
            ),
          YounumPillNote(
            overview.canOpenCompleteReport
                ? '本月账单已整理完，可以去看看回顾'
                : '整理完成后，为你生成完整的消费回顾',
          ),
        ],
      ),
    );
  }
}

/// 首页 tab：按**真实数据**在空状态与进度状态之间切换。
///
/// 不能再用「是不是演示账本」近似判断 —— 真实账本在导入之前确实一笔都没有。
class HomeTabScreen extends StatelessWidget {
  const HomeTabScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = ReviewSessionScope.of(context);
    if (!session.isReady) {
      return const YounumScreen(
        bottomBar: AppBottomBar(),
        child: Center(child: YounumMutedText('正在读取本地账单…')),
      );
    }
    return session.hasAnyRecord ? const HomeScreen() : const EmptyHomeScreen();
  }
}
