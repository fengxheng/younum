import 'package:flutter/material.dart';

import '../designsystem/younum_text.dart';
import '../money/money.dart';

/// 金额显示规格。
enum AmountScale {
  /// 卡片里的核心金额（40sp）。
  card,

  /// 面板里的金额（34sp）。
  panel,

  /// 列表行内金额（20sp）。
  inline,

  /// 明细行金额（15sp）。
  row,

  /// 完成页统计数字（22sp）。
  stat,
}

/// 金额文本。
///
/// 设计稿把金额当作视觉重点，因此这里统一负责三件事：
/// 1. 千分位与两位小数由 [Money] 决定，界面上不出现浮点拼接；
/// 2. 使用等宽数字（tabular figures），让多行金额竖向对齐；
/// 3. 向 TalkBack 朗读「¥ 8,432.60」这样的完整金额，而不是拆开的符号（指南 6.3）。
class AmountText extends StatelessWidget {
  const AmountText({
    super.key,
    required this.cents,
    this.scale = AmountScale.panel,
    this.grouped = true,
    this.showSign = false,
    this.currencySymbol = '¥',
    this.color,
    this.semanticLabel,
  });

  final int cents;
  final AmountScale scale;

  /// 是否显示千分位。卡片上的核心金额保留分组，便于快速读数。
  final bool grouped;

  /// 支出为 `−`，退款为 `+`（指南 3.1：金额保存为绝对值，方向由性质表达）。
  final bool showSign;

  final String currencySymbol;
  final Color? color;

  /// 覆盖朗读文本，例如「退款 28.00 元，已抵扣原消费」。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);

    final (TextStyle style, double symbolSize) = switch (scale) {
      AmountScale.card => (text.amountCard, 20),
      AmountScale.panel => (text.amountPanel, 18),
      AmountScale.inline => (text.amountInline, 13),
      AmountScale.row => (text.amountRow, 11),
      AmountScale.stat => (text.statNumber, 13),
    };
    final resolved = style.copyWith(color: color ?? style.color);

    final body = showSign
        ? Money.formatWithSign(cents, grouped: grouped)
        : Money.format(cents.abs(), grouped: grouped);

    return Semantics(
      // 合并成一个朗读单位，避免「¥」「8」「,」「432」被逐个读出。
      label: semanticLabel ??
          '${showSign ? (cents < 0 ? '支出 ' : '收入 ') : ''}$currencySymbol$body',
      excludeSemantics: true,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            Text(
              currencySymbol,
              style: resolved.copyWith(fontSize: symbolSize),
            ),
            const SizedBox(width: 3),
            Text(body, style: resolved),
          ],
        ),
      ),
    );
  }
}
