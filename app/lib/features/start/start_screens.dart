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

/// 欢迎与产品引导。
///
/// 开始后持久化完成状态，不会每次启动重复出现（阶段 1 验收条件）。
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);

    return YounumScreen(
      fillViewport: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        // 短内容在大屏上均匀分布：顶部品牌、中间主张、底部行动，而不是全部挤在顶部。
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('∷ 有数', style: text.sectionTitle.copyWith(fontSize: 18)),
              const Spacer(),
              Text('YOUNUM', style: text.micro.copyWith(letterSpacing: 2)),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const ExcludeSemantics(child: _WelcomeArt()),
              const SizedBox(height: YounumDimens.gapXl),
              Text(
                'MAKE SENSE OF YOUR SPENDING',
                textAlign: TextAlign.center,
                style: text.eyebrow,
              ),
              const SizedBox(height: YounumDimens.gap),
              Text(
                '钱花在哪，\n心里有数。',
                textAlign: TextAlign.center,
                style: text.screenTitle.copyWith(fontSize: 29),
              ),
              const SizedBox(height: YounumDimens.gap),
              YounumMutedText(
                '一张卡片，一笔生活。\n用一点时间，看懂一个月的自己。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: YounumDimens.gapXl),
              const ExcludeSemantics(child: _PageDots()),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              PrimaryAction(
                label: '开启我的第一份月账单',
                trailingArrow: true,
                onPressed: () {
                  AppStateScope.read(context).completeOnboarding();
                  context.openAsRoot(AppRoutes.root);
                },
              ),
              const YounumMetaRow(icon: YounumIcons.shield, text: '无需注册，先体验整理'),
            ],
          ),
        ],
      ),
    );
  }
}

/// 引导页的装饰插画：轨道 + 两张小票据 + 浮动对勾。
class _WelcomeArt extends StatelessWidget {
  const _WelcomeArt();

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final text = YounumText.of(context);

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
              child: Icon(Icons.check, color: colors.onPrimaryColor, size: 22),
            ),
          ),
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

class _PageDots extends StatelessWidget {
  const _PageDots();

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Container(
          width: 18,
          height: 5,
          decoration: BoxDecoration(
            color: colors.primaryColor,
            borderRadius: BorderRadius.circular(5),
          ),
        ),
        const SizedBox(width: 5),
        for (var i = 0; i < 2; i++) ...<Widget>[
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              color: colors.tintColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
        ],
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
