import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_routes.dart';
import '../../app/route_args.dart';
import '../../core/components/amount_text.dart';
import '../../core/components/buttons.dart';
import '../../core/components/fields.dart';
import '../../core/components/list_row.dart';
import '../../core/components/primitives.dart';
import '../../core/components/screen_scaffold.dart';
import '../../core/components/sheets.dart';
import '../../core/designsystem/younum_colors.dart';
import '../../core/designsystem/younum_dimens.dart';
import '../../core/designsystem/younum_icons.dart';
import '../../core/designsystem/younum_text.dart';
import '../../core/money/money.dart';
import 'category_registry.dart';
import 'review_card.dart';
import 'review_session.dart';

/// 按 ID 解析交易。
///
/// 详情页必须依据**实际交易 ID** 展示与编辑，不能固定成某一笔
/// （指南第 5 节 detail）。找不到时返回 null，由调用方给出解释与返回入口。
///
/// 从会话的完整数据集里找，而不是只翻当前队列：明细、分类下钻、分享
/// 都可能指向已归类、收入、退款或别的月份的记录。
ReviewCard? _resolveTransaction(BuildContext context, String? id) {
  final session = ReviewSessionScope.of(context);
  final target = int.tryParse(id ?? '');
  if (target == null) return session.current;
  return session.cardFor(target);
}

/// 交易不存在时的解释页。
class _MissingTransaction extends StatelessWidget {
  const _MissingTransaction();

  @override
  Widget build(BuildContext context) {
    return YounumScreen(
      title: '账单详情',
      child: YounumEmptyState(
        icon: YounumIcons.search,
        title: '这笔记录已经不在了',
        description: '它可能已经被撤回导入，或者属于另一个月份。可以返回明细重新选择。',
        action: PrimaryAction(
          label: '返回明细',
          onPressed: () => context.openAsRoot(AppRoutes.root),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// detail —— 交易详情与更多操作
// -----------------------------------------------------------------------------

/// 账单详情。
class TransactionDetailScreen extends StatefulWidget {
  const TransactionDetailScreen({super.key, this.args = const TransactionDetailArgs()});

  final TransactionDetailArgs args;

  @override
  State<TransactionDetailScreen> createState() => _TransactionDetailScreenState();
}

class _TransactionDetailScreenState extends State<TransactionDetailScreen> {
  late final TextEditingController _noteController = TextEditingController();
  String? _category;

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final transaction = _resolveTransaction(context, widget.args.transactionId);
    if (transaction == null) return const _MissingTransaction();

    final text = YounumText.of(context);
    final registry = CategoryRegistryScope.of(context);
    final displayCategory = _category ?? transaction.categoryName ?? '待确认';

    return YounumScreen(
      title: '账单详情',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Center(
            child: Column(
              children: <Widget>[
                YounumTileIcon(
                  iconKey: registry.iconFor(displayCategory).iconKey,
                  imagePath: registry.iconFor(displayCategory).imagePath,
                  size: 46,
                ),
                const SizedBox(height: YounumDimens.gap),
                AmountText(cents: transaction.amountCents, scale: AmountScale.panel),
                const SizedBox(height: YounumDimens.gapSm),
                Text(transaction.merchant, style: text.listPrimary),
                const SizedBox(height: YounumDimens.gapSm),
                YounumBadge(
                  _category == null ? '待确认用途' : '已归类 · $displayCategory',
                  tone: _category == null
                      ? YounumBadgeTone.warm
                      : YounumBadgeTone.primary,
                ),
              ],
            ),
          ),
          const SizedBox(height: YounumDimens.gapLg),
          YounumPanel(
            child: Column(
              children: <Widget>[
                YounumLineInfo(label: '交易时间', value: transaction.dateText),
                YounumLineInfo(label: '支付来源', value: transaction.source),
                const YounumLineInfo(label: '交易类型', value: '商户消费'),
                const YounumLineInfo(label: '原始单号', value: '•••• 0826'),
              ],
            ),
          ),
          YounumListRow(
            title: '修改用途',
            subtitle: '选择或重新归类',
            iconKey: displayCategory == '待整理' ? 'file' : null,
            icon: displayCategory == '待整理' ? null : YounumIcons.edit,
            trailingWidget: const _Chevron(),
            onTap: () async {
              // 用 dynamic 接收再自行收窄，避免命名路由的泛型不匹配。
              final picked = await Navigator.of(context).pushNamed<dynamic>(
                AppRoutes.allCategories,
                arguments: CategoryPickArgs(
                  purpose: CategoryPickPurpose.detail,
                  currentCategory: displayCategory,
                  transactionId: '${transaction.id}',
                ),
              );
              if (picked is String && mounted) {
                setState(() => _category = picked);
              }
            },
          ),
          YounumListRow(
            title: '拆分这笔消费',
            subtitle: '一笔金额，多个用途',
            icon: YounumIcons.split,
            trailingWidget: const _Chevron(),
            onTap: () => context.open(AppRoutes.splitTransaction),
          ),
          YounumListRow(
            title: '设为转账 / 退款',
            subtitle: '从消费统计中单独处理',
            icon: YounumIcons.link,
            trailingWidget: const _Chevron(),
            showDivider: false,
            onTap: () => context.open(AppRoutes.transactionNature),
          ),
          const YounumFieldLabel('给这笔花费加个备注'),
          YounumTextField(
            controller: _noteController,
            hintText: '例如：午后和朋友喝咖啡',
          ),
          const SizedBox(height: YounumDimens.gapLg),
          PrimaryAction(
            label: '保存修改',
            onPressed: () => showYounumToast(
              context,
              '已保存：${_category ?? displayCategory}',
            ),
          ),
          const YounumDemoNote(
            '设计走查：本页按实际交易 ID 展示，未写死的商户。'
            '保存操作在阶段 2 起写入数据库事务。',
          ),
        ],
      ),
    );
  }
}

class _Chevron extends StatelessWidget {
  const _Chevron();

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Icon(
          YounumIcons.chevronRight,
          size: YounumDimens.iconMd,
          color: YounumColors.of(context).mutedColor,
        ),
      );
}

// -----------------------------------------------------------------------------
// split —— 拆分一笔消费
// -----------------------------------------------------------------------------

/// 拆分用途。
///
/// 硬性校验（指南 3.5.1）：各项金额必须大于 0，且合计**精确等于**原始金额。
/// 校验不过时确认按钮不可提交。
class SplitScreen extends StatefulWidget {
  const SplitScreen({super.key});

  @override
  State<SplitScreen> createState() => _SplitScreenState();
}

class _SplitScreenState extends State<SplitScreen> {
  /// 示例：盒马鲜生 126.80 拆成 买菜 86.80 + 日用品 40.00。
  static const int _originalCents = 12680;
  static const List<String> _options = <String>[
    '餐饮 · 买菜',
    '购物 · 日用品',
    '餐饮 · 日常三餐',
    '健康 · 日常用药',
  ];

  final List<_SplitDraft> _items = <_SplitDraft>[
    _SplitDraft(optionIndex: 0, amount: '86.80'),
    _SplitDraft(optionIndex: 1, amount: '40.00'),
  ];

  @override
  void dispose() {
    for (final item in _items) {
      item.controller.dispose();
    }
    super.dispose();
  }

  /// 解析一项金额；返回 null 表示非法（含超过两位小数）。
  int? _centsOf(_SplitDraft item) {
    final (cents, error) = Money.parseYuan(item.controller.text);
    if (error != null) return null;
    return cents;
  }

  /// 已分配合计。出现非法项时返回 null，避免把错误金额算进合计。
  int? get _allocated {
    var total = 0;
    for (final item in _items) {
      final cents = _centsOf(item);
      if (cents == null) return null;
      total += cents;
    }
    return total;
  }

  bool get _allPositive =>
      _items.isNotEmpty && _items.every((item) => (_centsOf(item) ?? 0) > 0);

  /// 只有「全部大于 0」且「合计精确相等」才允许提交。
  bool get _canSubmit => _allPositive && _allocated == _originalCents;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final colors = YounumColors.of(context);
    final allocated = _allocated;
    final remaining = allocated == null ? null : _originalCents - allocated;

    return YounumScreen(
      title: '拆分消费',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('一笔花费，多种用途', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText('盒马鲜生 · 9月21日 19:05'),
          const SizedBox(height: YounumDimens.gap),
          const YounumPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                YounumCaptionText('原始金额'),
                SizedBox(height: 8),
                AmountText(cents: _originalCents, scale: AmountScale.panel),
              ],
            ),
          ),
          for (var index = 0; index < _items.length; index++) ...<Widget>[
            YounumFieldLabel(
              '用途${_indexLabel(index)}',
              trailing: _items.length > 1
                  ? YounumPressable(
                      onTap: () => setState(() {
                        _items.removeAt(index).controller.dispose();
                      }),
                      semanticLabel: '删除用途${_indexLabel(index)}',
                      borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                        child: Text(
                          '删除',
                          style: text.label.copyWith(color: colors.mutedColor),
                        ),
                      ),
                    )
                  : null,
            ),
            YounumSelectField<int>(
              options: List<int>.generate(_options.length, (i) => i),
              labelBuilder: (i) => _options[i],
              selected: _items[index].optionIndex,
              semanticLabel: '用途${_indexLabel(index)}分类',
              onSelected: (value) => setState(() => _items[index].optionIndex = value),
            ),
            const SizedBox(height: YounumDimens.gapSm),
            YounumTextField(
              controller: _items[index].controller,
              hintText: '0.00',
              suffixText: '元',
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              onChanged: (value) => setState(() {}),
            ),
            const SizedBox(height: YounumDimens.gap),
          ],
          PrimaryAction(
            label: '增加一项用途',
            style: YounumActionStyle.secondary,
            onPressed: () => setState(
              () => _items.add(_SplitDraft(optionIndex: 0, amount: '')),
            ),
          ),
          YounumPanel(
            tone: YounumPanelTone.soft,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: <InlineSpan>[
                        TextSpan(text: '已分配 ', style: text.body),
                        TextSpan(
                          text: allocated == null
                              ? '金额格式有误'
                              : '¥${Money.format(allocated)}',
                          style: text.body.copyWith(
                            fontWeight: FontWeight.w600,
                            color: allocated == null
                                ? const Color(YounumColors.danger)
                                : colors.primaryColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                YounumBadge(
                  remaining == null
                      ? '待修正'
                      : remaining == 0
                          ? '剩余 ¥0.00'
                          : '剩余 ¥${Money.format(remaining)}',
                  tone: remaining == 0
                      ? YounumBadgeTone.primary
                      : YounumBadgeTone.warm,
                ),
              ],
            ),
          ),
          PrimaryAction(
            label: '确认拆分',
            onPressed: _canSubmit
                ? () {
                    showYounumToast(context, '拆分已保存，统计时按用途汇总');
                    Navigator.of(context).pop();
                  }
                : null,
          ),
          const YounumPillNote(
            '保留原始交易，统计时按拆分后的用途汇总；'
            '每项金额必须大于 0，且合计精确等于原始金额。',
          ),
        ],
      ),
    );
  }

  /// 中文序号。超过 5 项时回退到数字，避免越界。
  static String _indexLabel(int index) => index < 5
      ? const <String>['一', '二', '三', '四', '五'][index]
      : '${index + 1}';
}

class _SplitDraft {
  _SplitDraft({required this.optionIndex, required String amount})
      : controller = TextEditingController(text: amount);

  int optionIndex;
  final TextEditingController controller;
}

// -----------------------------------------------------------------------------
// nonexpense —— 转账、退款与排除统计
// -----------------------------------------------------------------------------

/// 交易性质调整。
class TransactionNatureScreen extends StatefulWidget {
  const TransactionNatureScreen({super.key});

  @override
  State<TransactionNatureScreen> createState() => _TransactionNatureScreenState();
}

class _TransactionNatureScreenState extends State<TransactionNatureScreen> {
  static const List<String> _natures = <String>[
    '普通消费',
    '账户间转账',
    '收入',
    '收到退款',
    '暂不计入统计',
  ];

  static const List<String> _originalOptions = <String>[
    '优衣库 · 9月12日 · ¥299.00',
    '找不到原消费，保留待核对',
  ];

  int _nature = 3;
  int _original = 0;
  final TextEditingController _reasonController = TextEditingController();

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  String get _natureName => _natures[_nature];

  /// 退款必须完成关联，或明确选择排除统计并保留原因后才能处理完成（指南 3.3）。
  String? get _blockingReason {
    if (_natureName == '收到退款' && _originalOptions[_original].startsWith('找不到')) {
      return '退款需要关联到原消费；确实找不到时，请改为「暂不计入统计」并说明原因。';
    }
    if (_natureName == '暂不计入统计' && _reasonController.text.trim().isEmpty) {
      return '排除统计需要保留原因，便于以后回看时理解这笔记录。';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final blocking = _blockingReason;

    return YounumScreen(
      title: '调整交易性质',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('它不一定是一笔消费', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText('确认交易性质，让月报更准确。'),
          const SizedBox(height: YounumDimens.gapLg),
          YounumPanel(
            child: YounumRadioGroup<int>(
              options: List<int>.generate(_natures.length, (i) => i),
              selected: _nature,
              labelBuilder: (index) => _natures[index],
              groupLabel: '交易性质',
              onSelected: (value) => setState(() => _nature = value),
            ),
          ),
          if (_natureName == '收到退款') ...<Widget>[
            const YounumFieldLabel('关联原消费'),
            YounumSelectField<int>(
              options: List<int>.generate(_originalOptions.length, (i) => i),
              labelBuilder: (index) => _originalOptions[index],
              selected: _original,
              semanticLabel: '关联原消费',
              onSelected: (value) => setState(() => _original = value),
            ),
          ],
          if (_natureName == '暂不计入统计') ...<Widget>[
            const YounumFieldLabel('不计入统计的原因'),
            YounumTextField(
              controller: _reasonController,
              hintText: '例如：这是朋友还我的钱',
              onChanged: (value) => setState(() {}),
            ),
          ],
          const YounumNotice(
            '退款默认抵扣原消费；跨月退款归回原消费月份，并提示相关月报已更新。',
          ),
          if (blocking != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: YounumCaptionText(
                blocking,
                style: TextStyle(color: YounumColors.of(context).primaryColor),
              ),
            ),
          PrimaryAction(
            label: '确认调整',
            onPressed: blocking == null
                ? () {
                    showYounumToast(context, '已按「$_natureName」处理');
                    Navigator.of(context).pop();
                  }
                : null,
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// pending —— 稍后处理 · 待确认清单
// -----------------------------------------------------------------------------

/// 稍后队列。
class PendingQueueScreen extends StatelessWidget {
  const PendingQueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final session = ReviewSessionScope.of(context);
    final items = session.deferred;

    return YounumScreen(
      title: '稍后处理',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('不着急，再想一想', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText(
            items.isEmpty
                ? '当前没有放在稍后处理的记录。'
                : '${items.length} 笔花费还没有找到归属。',
          ),
          const SizedBox(height: YounumDimens.gap),
          if (items.isEmpty)
            const YounumEmptyState(
              icon: YounumIcons.clock,
              title: '稍后队列是空的',
              description: '在卡片上左滑，或点「稍后处理」，记录会来到这个清单。',
            )
          else
            YounumPanel(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: <Widget>[
                  for (var index = 0; index < items.length; index++)
                    YounumListRow(
                      title: items[index].merchant,
                      subtitle: items[index].dateText,
                      iconKey: 'clock',
                      trailingText:
                          '¥${Money.format(items[index].amountCents, grouped: true)}',
                      showDivider: index != items.length - 1,
                    ),
                ],
              ),
            ),
          YounumPanel(
            tone: YounumPanelTone.soft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    ExcludeSemantics(
                      child: Icon(
                        YounumIcons.categoryIcon('leaf'),
                        size: YounumDimens.iconMd,
                        color: YounumColors.of(context).primaryColor,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text('给记忆一点提示', style: text.sectionTitle)),
                  ],
                ),
                const SizedBox(height: YounumDimens.gapSm),
                const YounumMutedText(
                  '回看交易时间、商户名称或原平台记录。确实想不起来，'
                  '可以在卡片上主动选择「其他」，系统不会替你决定。',
                ),
              ],
            ),
          ),
          if (items.isNotEmpty)
            PrimaryAction(
              label: '重新整理这些账单',
              onPressed: () {
                session.resumeDeferred();
                context.selectTab(1);
                showYounumToast(context, '已放回整理队列');
              },
            ),
          const SizedBox(height: YounumDimens.gap),
          PrimaryAction(
            label: '先保存，稍后再来',
            style: YounumActionStyle.secondary,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// complete —— 整理完成
// -----------------------------------------------------------------------------

/// 整理完成。
///
/// 只在**没有待处理记录**时出现，并且必须说明范围是否完整（指南 3.4 / 5）。
/// 还有待整理时不会展示完成态。
class ReviewCompleteScreen extends StatefulWidget {
  const ReviewCompleteScreen({super.key});

  @override
  State<ReviewCompleteScreen> createState() => _ReviewCompleteScreenState();
}

class _ReviewCompleteScreenState extends State<ReviewCompleteScreen> {
  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final session = ReviewSessionScope.of(context);

    if (!session.isComplete) {      return YounumScreen(
        title: '整理完成',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            YounumPanel(
              tone: YounumPanelTone.soft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('还不能生成完整月报', style: text.screenTitle),
                  const SizedBox(height: YounumDimens.gapSm),
                  YounumMutedText(
                    '还有 ${session.remainingCount} 笔记录没有处理完。'
                    '跳过不代表完成，全部确认后才会出现完整概况。',
                  ),
                  const SizedBox(height: YounumDimens.gap),
                  PrimaryAction(
                    label: '继续整理',
                    trailingArrow: true,
                    onPressed: () => context.selectTab(1),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final categoryCount =
        session.done.map((entry) => entry.category).toSet().length;

    return YounumScreen(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SizedBox(height: YounumDimens.gapXl),
          const Center(
            child: YounumCircleSymbol(
              icon: Icons.check,
              diameter: 104,
              borderWidth: 9,
            ),
          ),
          const SizedBox(height: YounumDimens.gapXl),
          Text(
            'EVERY PENNY HAS A PLACE',
            textAlign: TextAlign.center,
            style: text.eyebrow,
          ),
          const SizedBox(height: YounumDimens.gap),
          Text(
            '这个月，理清了。',
            textAlign: TextAlign.center,
            style: text.screenTitle.copyWith(fontSize: 28),
          ),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText(
            '${session.doneCount} 笔花费，都有了自己的位置。\n谢谢你，认真对待每一份生活。',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: YounumDimens.gapLg),
          YounumPanel(
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    children: <Widget>[
                      YounumCaptionText('已整理'),
                      const SizedBox(height: 6),
                      Text('${session.doneCount} 笔', style: text.statNumber),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    children: <Widget>[
                      YounumCaptionText('消费用途'),
                      const SizedBox(height: 6),
                      Text('$categoryCount 类', style: text.statNumber),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // 范围完整性由用户确认，不自动判定。
          //
          // 月份必须取自会话，不能写死：用户可以切到别的月份再来完成页，
          // 写死「9 月」会让这句确认词与实际确认的月份对不上。
          YounumCheckRow(
            label: '我确认${session.month?.shortLabel ?? '当月'}账单范围完整'
                '（含月初到月末的全部记录）',
            value: session.coverageConfirmed,
            onChanged: session.confirmCoverage,
          ),
          const YounumPillNote(
            '未确认范围完整时，概况页会标注「截至某日 / 部分账单」，'
            '不会冒充完整月报。',
          ),
          PrimaryAction(
            label: '看看我的月度消费',
            trailingArrow: true,
            onPressed: () => context.selectTab(2),
          ),
          const SizedBox(height: YounumDimens.gap),
          PrimaryAction(
            label: '先检查一下账单',
            style: YounumActionStyle.plain,
            onPressed: () => context.open(AppRoutes.transactions),
          ),
        ],
      ),
    );
  }
}
