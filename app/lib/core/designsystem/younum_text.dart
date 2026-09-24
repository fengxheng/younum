import 'package:flutter/material.dart';

import 'younum_colors.dart';

/// 字体层级。
///
/// 取值为实现指南 6.2 的目标区间（页标题 24sp、核心金额 36–44sp、正文 14sp、
/// 辅助文案 12sp）。原型里的 9–10px 微小标注**已被整体上调**，不再照搬。
///
/// 通过 `YounumText.of(context)` 获取，颜色随主题变化。
@immutable
class YounumText {
  const YounumText(this.colors);

  final YounumColors colors;

  static YounumText of(BuildContext context) => YounumText(YounumColors.of(context));

  static const List<FontFeature> _tabular = <FontFeature>[FontFeature.tabularFigures()];

  /// 页面主标题。
  TextStyle get screenTitle => TextStyle(
        fontSize: 24,
        height: 1.35,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.6,
        color: colors.inkColor,
      );

  /// 底部弹层标题，略小于页面标题。
  TextStyle get sheetTitle => screenTitle.copyWith(fontSize: 22, fontWeight: FontWeight.w600);

  /// 区块小标题。
  TextStyle get sectionTitle => TextStyle(
        fontSize: 15,
        height: 1.4,
        fontWeight: FontWeight.w600,
        color: colors.inkColor,
      );

  /// 正文。
  TextStyle get body => TextStyle(fontSize: 14, height: 1.7, color: colors.inkColor);

  /// 次级正文（说明性段落）。
  TextStyle get bodyMuted => TextStyle(fontSize: 14, height: 1.75, color: colors.mutedColor);

  /// 表单标签 / 列表次要信息。
  TextStyle get label => TextStyle(fontSize: 13, height: 1.5, color: colors.mutedColor);

  /// 辅助文案下限（指南要求 ≥ 12sp）。
  TextStyle get caption => TextStyle(fontSize: 12, height: 1.7, color: colors.mutedColor);

  /// 极短标注，例如徽标内的数字。不再低于 11sp。
  TextStyle get micro => TextStyle(fontSize: 11, height: 1.5, color: colors.mutedColor);

  /// 全大写英文小标。
  TextStyle get eyebrow => TextStyle(
        fontSize: 11,
        height: 1.5,
        letterSpacing: 1.3,
        fontWeight: FontWeight.w600,
        color: colors.primaryColor,
      );

  /// 列表主文案。
  TextStyle get listPrimary => TextStyle(
        fontSize: 14,
        height: 1.4,
        fontWeight: FontWeight.w500,
        color: colors.inkColor,
      );

  /// 列表副文案。
  TextStyle get listSecondary => TextStyle(fontSize: 12, height: 1.5, color: colors.mutedColor);

  /// 卡片里的核心金额（指南：36–44sp）。
  TextStyle get amountCard => TextStyle(
        fontSize: 40,
        height: 1.15,
        fontWeight: FontWeight.w500,
        letterSpacing: -1.2,
        fontFeatures: _tabular,
        color: colors.inkColor,
      );

  /// 面板里的金额。
  TextStyle get amountPanel => TextStyle(
        fontSize: 34,
        height: 1.2,
        fontWeight: FontWeight.w500,
        letterSpacing: -1.0,
        fontFeatures: _tabular,
        color: colors.inkColor,
      );

  /// 列表行内金额。
  TextStyle get amountInline => TextStyle(
        fontSize: 20,
        height: 1.3,
        fontWeight: FontWeight.w500,
        fontFeatures: _tabular,
        color: colors.inkColor,
      );

  /// 行内金额的小字号变体（明细列表）。
  TextStyle get amountRow => TextStyle(
        fontSize: 15,
        height: 1.3,
        fontWeight: FontWeight.w500,
        fontFeatures: _tabular,
        color: colors.inkColor,
      );

  /// 按钮文字。
  TextStyle get button => TextStyle(
        fontSize: 14,
        height: 1.2,
        fontWeight: FontWeight.w500,
        color: colors.inkColor,
      );

  /// 卡片底部的票据信息（时间 / 来源）。
  TextStyle get receipt => TextStyle(
        fontSize: 12,
        height: 1.5,
        color: colors.mutedColor,
      );

  /// 轻量引用句。
  TextStyle get quote => TextStyle(
        fontSize: 14,
        height: 1.9,
        color: colors.primaryColor,
      );

  /// 深色面板上的正文。
  TextStyle get onDarkPanel => TextStyle(fontSize: 14, height: 1.6, color: colors.onDarkPanelColor);

  /// 徽标文字。
  TextStyle get badge => TextStyle(
        fontSize: 11,
        height: 1.3,
        fontWeight: FontWeight.w500,
        color: colors.primaryColor,
      );

  /// 大号数字（完成页统计）。
  TextStyle get statNumber => TextStyle(
        fontSize: 22,
        height: 1.3,
        fontWeight: FontWeight.w500,
        fontFeatures: _tabular,
        color: colors.inkColor,
      );

  /// 输入框内文字。
  TextStyle get input => TextStyle(fontSize: 14, height: 1.4, color: colors.inkColor);

  /// 组装 Material 的 [TextTheme]，让未显式取样的默认组件也不跑偏。
  TextTheme toTextTheme() {
    return TextTheme(
      displaySmall: amountPanel,
      headlineSmall: screenTitle,
      titleLarge: screenTitle,
      titleMedium: sectionTitle,
      bodyLarge: body,
      bodyMedium: body,
      bodySmall: caption,
      labelLarge: button,
      labelMedium: label,
      labelSmall: micro,
    );
  }
}
