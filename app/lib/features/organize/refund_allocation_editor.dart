import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/components/fields.dart';
import '../../core/components/primitives.dart';
import '../../core/designsystem/younum_colors.dart';
import '../../core/designsystem/younum_dimens.dart';
import '../../core/designsystem/younum_text.dart';
import '../../core/money/money.dart';
import '../../domain/models/allocation.dart';
import '../../domain/models/category.dart';
import 'review_card.dart';
import 'review_session.dart';

/// 退款分配编辑器（指南 3.5.5）。
///
/// 拆分过的消费被退款时，必须说清「退款抵扣到哪几项、各多少」：合计要精确
/// 等于退款金额，单项不能超过它原本的金额。不这样做的话，退款会被摊到哪个
/// 分类上全靠猜，两个分类的净额都会悄悄算错。
///
/// 默认全填 0，而不是替用户分好：指南要的正是「明确」。分错比多点几下贵得多。
class RefundAllocationEditor extends StatefulWidget {
  const RefundAllocationEditor({
    super.key,
    required this.card,
    required this.refundCents,
    required this.onChanged,
  });

  /// 原消费那张卡（含它的拆分项）。
  final ReviewCard card;

  /// 退款金额（分）。
  final int refundCents;

  /// 草稿变化时回调，父页面据此决定能不能提交。
  ///
  /// [balanced] 为 true 表示合计精确等于退款金额，且每一项都没超过它自己的金额。
  final void Function(List<RefundAllocationDraft> drafts, bool balanced) onChanged;

  @override
  State<RefundAllocationEditor> createState() => _RefundAllocationEditorState();
}

class _RefundAllocationEditorState extends State<RefundAllocationEditor> {
  late final List<_RefundDraft> _items = <_RefundDraft>[
    for (final allocation in widget.card.allocations)
      _RefundDraft(allocation: allocation),
  ];

  @override
  void initState() {
    super.initState();
    // `initState` 里不能直接回调父页面：此刻父页面正在 build，
    // 它的 `setState` 会被判成「build 期间 setState」。
    WidgetsBinding.instance.addPostFrameCallback((_) => _notify());
  }

  @override
  void dispose() {
    for (final item in _items) {
      item.controller.dispose();
    }
    super.dispose();
  }

  /// 解析一项金额；null 表示格式不对（或超过两位小数）。
  int? _centsOf(_RefundDraft item) {
    final (cents, error) = Money.parseYuan(item.controller.text);
    if (error != null) return null;
    return cents;
  }

  /// 非零项的草稿。
  ///
  /// 0 表示「这一项不抵扣」，不进草稿 —— 规则层要求每一项都大于 0，
  /// 送一堆 0 过去只会被挡回来。
  List<RefundAllocationDraft> get _drafts {
    final drafts = <RefundAllocationDraft>[];
    for (final item in _items) {
      final cents = _centsOf(item);
      if (cents == null || cents <= 0) continue;
      drafts.add(
        RefundAllocationDraft(
          originalAllocationId: item.allocation.id,
          amountCents: cents,
        ),
      );
    }
    return drafts;
  }

  int? get _total {
    var total = 0;
    for (final item in _items) {
      final cents = _centsOf(item);
      if (cents == null) return null;
      total += cents;
    }
    return total;
  }

  bool get _withinItems {
    for (final item in _items) {
      if ((_centsOf(item) ?? 0) > item.allocation.amountCents) return false;
    }
    return true;
  }

  bool get _balanced => _total == widget.refundCents && _withinItems;

  void _notify() {
    if (!mounted) return;
    widget.onChanged(_drafts, _balanced);
  }

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final colors = YounumColors.of(context);
    final byId = <int, Category>{
      for (final category in ReviewSessionScope.of(context).allCategories)
        category.id: category,
    };
    final total = _total;
    final remaining = total == null ? null : widget.refundCents - total;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const YounumFieldLabel('抵扣到哪几项'),
        YounumMutedText('这笔消费拆成了 ${_items.length} 项，请说明退款分别抵扣哪几项。'),
        const SizedBox(height: YounumDimens.gapSm),
        for (var index = 0; index < _items.length; index++) ...<Widget>[
          YounumPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  _labelOf(byId, _items[index].allocation.categoryId),
                  style: text.listPrimary,
                ),
                const SizedBox(height: 4),
                YounumCaptionText(
                  '原金额 ¥${Money.format(_items[index].allocation.amountCents)}',
                ),
                const SizedBox(height: YounumDimens.gapSm),
                YounumTextField(
                  controller: _items[index].controller,
                  hintText: '0.00',
                  suffixText: '元',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  onChanged: (value) {
                    setState(() {});
                    _notify();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: YounumDimens.gapSm),
        ],
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
                        text: total == null
                            ? '金额格式有误'
                            : '¥${Money.format(total)}',
                        style: text.body.copyWith(
                          fontWeight: FontWeight.w600,
                          color: total == null
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
        YounumPillNote(
          '分配合计必须精确等于退款金额（¥${Money.format(widget.refundCents)}），'
          '某一项最多只能抵扣它自己的金额。',
        ),
      ],
    );
  }

  /// 分类展示名；子分类带上母类，否则只看一个「买菜」不知道属于哪一类。
  static String _labelOf(Map<int, Category> byId, int id) {
    final category = byId[id];
    if (category == null) return '未知分类';
    final parentId = category.parentId;
    final parent = parentId == null ? null : byId[parentId];
    return parent == null ? category.name : '${parent.name} · ${category.name}';
  }
}

class _RefundDraft {
  _RefundDraft({required this.allocation});

  final Allocation allocation;

  /// 空字符串表示还没填（0 分本来也不合法：要么抵扣、要么不抵扣）。
  final TextEditingController controller = TextEditingController();
}
