import 'package:flutter/material.dart';

import '../../app/app_routes.dart';
import '../../app/route_args.dart';
import '../../core/components/amount_text.dart';
import '../../core/components/buttons.dart';
import '../../core/components/category_grid.dart';
import '../../core/components/primitives.dart';
import '../../core/components/progress.dart';
import '../../core/components/screen_scaffold.dart';
import '../../core/components/sheets.dart';
import '../../core/components/transaction_card_stack.dart';
import '../../core/designsystem/younum_colors.dart';
import '../../core/designsystem/younum_dimens.dart';
import '../../core/designsystem/younum_icons.dart';
import '../../core/designsystem/younum_text.dart';
import 'category_registry.dart';
import 'review_card.dart';
import 'review_session.dart';

/// 堆叠卡片主界面。
///
/// 手势与按钮走**同一条**提交路径（[ReviewSession.confirmCurrent] /
/// [ReviewSession.deferCurrent]），因此撤销日志只有一份，不会出现
/// 「滑一下记一次、点一下记另一次」的偏差（指南 14.2）。
class CardsScreen extends StatefulWidget {
  const CardsScreen({super.key});

  @override
  State<CardsScreen> createState() => _CardsScreenState();
}

class _CardsScreenState extends State<CardsScreen> {
  /// 卡片自己的分类选择。
  ///
  /// 与 [ReviewSession.selectedCategory] 保持同步；使用会话里的值而不是本地
  /// `remember`，这样杀进程重启后选择不会丢（指南 2.3.4）。
  ReviewSession get _session => ReviewSessionScope.of(context);

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final session = _session;
    final current = session.current;

    return YounumScreen(
      bottomBar: const AppBottomBar(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(session.month?.englishLabel ?? '', style: text.eyebrow),
              ),
              YounumIconButton(
                icon: YounumIcons.cards,
                semanticLabel: '查看全部明细',
                onPressed: () => context.open(AppRoutes.transactions),
              ),
            ],
          ),
          Text('这笔钱，用在了哪里？', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          Row(
            children: <Widget>[
              Expanded(
                child: YounumMutedText(
                  '${session.isDemoLedger ? '示例账单 · ' : ''}'
                  '已整理 ${session.doneCount} / ${session.totalCount} 笔',
                ),
              ),
              YounumBadge('还剩 ${session.remainingCount} 笔'),
            ],
          ),
          YounumProgressTrack(
            value: session.progress,
            semanticLabel: '整理进度',
          ),
          if (!session.isReady) ...<Widget>[
            const SizedBox(height: YounumDimens.gapXxl),
            Center(
              child: YounumMutedText(
                session.loadError == null ? '正在读取本地账单…' : '读取失败：${session.loadError}',
                textAlign: TextAlign.center,
              ),
            ),
          ] else if (current != null) ...<Widget>[
            TransactionCardStack(
              key: const ValueKey<String>('review-card-stack'),
              transactionId: '${current.id}',
              selectedCategory: session.selectedCategory,
              card: TransactionCardView(card: current),
              onConfirm: session.confirmCurrent,
              onDefer: session.deferCurrent,
              onCommitted: () {
                if (!context.mounted) return;
                showYounumToast(context, '已确认 · ${session.lastActionLabel ?? '用途已保存'}');
              },
            ),
            // 手势提示行（「← 左滑：稍后处理 / 右滑：确认已选分类 →」）按需求不展示。
            //
            // 注意：这与实现指南 14.1「卡片下方始终显示方向提示」不一致，
            // 是需求方在阶段 1 走查时提出的调整，优先级高于文档规则。
            // 手势本身仍然有效，且拖动过程中卡片顶部会实时显示「确认 · 分类 →」
            // 或「先选择分类」的反馈；卡片下方也保留了确认 / 稍后 / 撤销按钮，
            // 因此手势不是唯一入口，只是不再常驻一行说明。
            // 如需恢复，把 SwipeGuideRow 加回这里即可（组件仍在 transaction_card_stack.dart）。
            Row(
              children: <Widget>[
                Expanded(child: YounumMutedText('选择用途')),
                YounumPressable(
                  onTap: () => context.open(
                    AppRoutes.allCategories,
                    // 分类选择必须带调用目的，返回时才能回到正确页面（指南 5.1）。
                    arguments: const CategoryPickArgs(
                      purpose: CategoryPickPurpose.card,
                    ),
                  ),
                  semanticLabel: '打开全部分类',
                  borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                    child: Text(
                      '全部分类 ›',
                      style: text.label.copyWith(
                        color: YounumColors.of(context).primaryColor,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            CategoryGrid(
              items: _categoryItemsOf(context),
              selectedName: session.selectedCategory,
              onSelected: session.select,
            ),
            const SizedBox(height: YounumDimens.gapSm),
            PrimaryAction(
              label: session.selectedCategory == null
                  ? '确认分类'
                  : '确认 · ${session.selectedCategory}',
              trailingArrow: true,
              onPressed: session.selectedCategory == null || session.isCommitting
                  ? null
                  : _confirmByButton,
            ),
            YounumActionRow(
              actions: <YounumActionRowItem>[
                YounumActionRowItem(
                  label: '撤销',
                  icon: YounumIcons.undo,
                  onPressed: session.isCommitting ? null : _undo,
                ),
                YounumActionRowItem(
                  label: '稍后处理',
                  icon: YounumIcons.clock,
                  onPressed: session.isCommitting ? null : _deferByButton,
                ),
                YounumActionRowItem(
                  label: '更多操作 ···',
                  onPressed: () => context.open(
                    AppRoutes.transactionDetail,
                    arguments: TransactionDetailArgs(transactionId: '${current.id}'),
                  ),
                ),
              ],
            ),
          ] else ...<Widget>[
            const SizedBox(height: YounumDimens.gapXxl),
            _QueueEmptyState(session: session),
          ],
        ],
      ),
    );
  }

  /// 卡片上「选择用途」网格里的分类 = 用户在「用途快捷项」里配好的那几个。
  ///
  /// 以前写死成「内置的 8 个一级分类」（见 `review_session.dart` 里那段说明），
  /// 用户既不能换掉、也不能换顺序。现在这两件事都交给用户，默认仍是那 8 个，
  /// 所以不改设置的人看到的和以前一模一样。
  ///
  /// 图标从**同一个注册表**取（含自定义图片图标），不再只看名字 ——
  /// 指南 14.4.7 要求所有页面从同一个分类仓库解析资源。
  List<YounumCategoryItem> _categoryItemsOf(BuildContext context) {
    final registry = CategoryRegistryScope.of(context);
    return <YounumCategoryItem>[
      for (final category in registry.quickPick)
        YounumCategoryItem(
          name: category.name,
          iconKey: category.iconKey ?? YounumIcons.defaultCategoryIconKey,
          imagePath: registry.imagePathOf(category),
        ),
    ];
  }

  Future<void> _confirmByButton() async {
    final session = _session;
    final transaction = session.current;
    final category = session.selectedCategory;
    if (transaction == null || category == null) return;
    final ok = await session.confirmCurrent();
    if (!mounted) return;
    showYounumToast(
      context,
      // ⚠️ 必须是 `${...}`：`$transaction.merchant` 只取 `$transaction`
      // 再把 `.merchant` 当字面量拼上去，于是提示条上会出现
      // 「ReviewCard(6, 社区药房, 6500).merchant → 餐饮」这种调试味的字符串
      // （真机截图上看到过）。
      ok
          ? '已确认 · ${transaction.merchant} → $category'
          : '保存失败，卡片已保留，请重试',
    );
  }

  Future<void> _deferByButton() async {
    final session = _session;
    final ok = await session.deferCurrent();
    if (!mounted) return;
    showYounumToast(
      context,
      ok ? '已放入稍后处理' : '保存失败，卡片已保留，请重试',
    );
  }

  Future<void> _undo() async {
    final session = _session;
    final label = session.lastActionLabel;
    if (!session.canUndo) {
      showYounumToast(context, '还没有可以撤销的操作');
      return;
    }
    final ok = await session.undo();
    if (!mounted) return;
    showYounumToast(
      context,
      ok
          ? '已撤销${label == null ? '' : '：$label'}'
          : session.lastFailure ?? '撤销失败，请重试',
    );
  }
}

/// 主队列已空时的两种去向。
///
/// 指南 14.2：主队列结束但还有稍后记录时，进稍后列表而**不是**完成页。
class _QueueEmptyState extends StatelessWidget {
  const _QueueEmptyState({required this.session});

  final ReviewSession session;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);

    // 这本账本一笔都没有：不是「整理完了」，而是还没有账单。
    if (!session.hasAnyRecord) {
      return YounumPanel(
        tone: YounumPanelTone.soft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('这个月还没有账单', style: text.sectionTitle),
            const SizedBox(height: YounumDimens.gapSm),
            YounumMutedText('导入一份月账单，就能开始一笔一笔地整理。'),
            const SizedBox(height: YounumDimens.gap),
            PrimaryAction(
              label: '导入月账单',
              trailingArrow: true,
              onPressed: () => context.open(AppRoutes.billImport),
            ),
          ],
        ),
      );
    }

    if (session.hasDeferred) {
      return YounumPanel(
        tone: YounumPanelTone.soft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('主队列整理完了', style: text.sectionTitle),
            const SizedBox(height: YounumDimens.gapSm),
            YounumMutedText(
              '还有 ${session.deferred.length} 笔放在稍后处理里，'
              '它们还没有归属，不计入已完成。',
            ),
            const SizedBox(height: YounumDimens.gap),
            PrimaryAction(
              label: '去整理稍后记录',
              trailingArrow: true,
              onPressed: () => context.open(AppRoutes.pendingQueue),
            ),
          ],
        ),
      );
    }

    return YounumPanel(
      tone: YounumPanelTone.soft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('这个月，理清了。', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText(
            '${session.doneCount} 笔花费，都有了自己的位置。',
          ),
          const SizedBox(height: YounumDimens.gap),
          PrimaryAction(
            label: '看看我的整理结果',
            trailingArrow: true,
            onPressed: () => context.open(AppRoutes.reviewComplete),
          ),
        ],
      ),
    );
  }
}

/// 卡片外观。
class TransactionCardView extends StatelessWidget {
  const TransactionCardView({super.key, required this.card});

  final ReviewCard card;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final text = YounumText.of(context);

    return Semantics(
      label: '${card.merchant}，'
          '${card.directionLabel} ¥${_formatForScreenReader(card.amountCents)}，'
          '${card.dateText}，${card.source}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: YounumDimens.transactionCardPaddingH,
          vertical: YounumDimens.transactionCardPaddingV,
        ),
        decoration: BoxDecoration(
          color: const Color(YounumColors.surface),
          border: Border.all(color: colors.softColor),
          borderRadius: BorderRadius.circular(YounumDimens.radiusCard),
          // 刻意不加 BoxShadow：原型里的阴影只有约 3% 不透明度，肉眼几乎看不出，
          // 但模糊阴影在卡片拖动与页面转场时每帧都要重新栅格化，是掉帧的常见来源。
          // 卡片与背景的区分交给描边。
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                ExcludeSemantics(
                  child: Container(
                    width: YounumDimens.tileIconSize,
                    height: YounumDimens.tileIconSize,
                    decoration: BoxDecoration(
                      color: colors.softColor,
                      borderRadius: BorderRadius.circular(YounumDimens.radiusTile),
                    ),
                    child: Icon(
                      YounumIcons.categoryIcon(card.categoryIconKey),
                      size: 20,
                      color: colors.primaryColor,
                    ),
                  ),
                ),
                const Spacer(),
                // 徽标跟着交易性质走：写死「支出」会让收入那张卡片说反话
                // （见 `ReviewCard.directionLabel` 与 `DECISIONS.md` 77 节）。
                YounumBadge(card.directionLabel),
              ],
            ),
            const SizedBox(height: YounumDimens.gap),
            AmountText(
              cents: card.amountCents,
              scale: AmountScale.card,
              semanticLabel:
                  '${card.merchant} ${card.directionLabel} '
                  '${_formatForScreenReader(card.amountCents)} 元',
            ),
            const SizedBox(height: YounumDimens.gapSm),
            Text(card.merchant, style: text.listPrimary),
            const Spacer(),
            YounumDashedDivider(margin: const EdgeInsets.only(bottom: 16)),
            Row(
              children: <Widget>[
                Expanded(child: YounumCaptionText(card.dateText)),
                YounumCaptionText('${card.source} · 人民币'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _formatForScreenReader(int cents) =>
      '${cents ~/ 100}${cents % 100 == 0 ? '' : '.${(cents % 100).toString().padLeft(2, '0')}'}';
}
