import 'package:flutter/material.dart';

import 'color_math.dart';
import 'theme_presets.dart';

/// 应用语义色令牌。
///
/// 分两类，界限不能模糊（实现指南 7.3）：
///
/// 1. **主题派生色**：由用户选择的原始主色计算得出，随主题变化。
/// 2. **固定语义色**：危险 / 警告 / 分类系列色 / 图片占位等，**不随主题变化**，
///    否则「危险删除」可能看起来像普通操作，或让图表图例与实际颜色不一致。
///
/// 所有组件只能从这里取色，Screen 内不得硬编码颜色。
@immutable
class YounumColors extends ThemeExtension<YounumColors> {
  const YounumColors({
    required this.raw,
    required this.presetId,
    required this.primary,
    required this.onPrimary,
    required this.pressed,
    required this.ink,
    required this.soft,
    required this.wash,
    required this.tint,
    required this.border,
    required this.muted,
    required this.darkPanel,
    required this.onDarkPanel,
    required this.onDarkPanelMuted,
    required this.primaryAdjusted,
  });

  /// 从原始主色派生整套令牌。
  factory YounumColors.fromRaw(int raw) {
    final primary = ColorMath.readableOnWhite(raw);
    return YounumColors(
      raw: raw,
      presetId: ThemePresets.idForColor(raw),
      primary: primary,
      onPrimary: 0xFFFFFF,
      pressed: ColorMath.mix(primary, 0x000000, 0.14),
      ink: ColorMath.mix(primary, 0x182126, 0.55),
      soft: ColorMath.mix(raw, 0xFFFFFF, 0.90),
      wash: ColorMath.mix(raw, 0xFFFFFF, 0.97),
      tint: ColorMath.mix(raw, 0xFFFFFF, 0.80),
      border: ColorMath.mix(raw, 0xFFFFFF, 0.72),
      muted: ColorMath.mix(primary, 0x707570, 0.60),
      darkPanel: primary,
      onDarkPanel: 0xFFFFFF,
      onDarkPanelMuted: 0xFFFFFFD9,
      primaryAdjusted: primary != raw,
    );
  }

  /// 用户选择的原始色值。
  final int raw;

  /// 原始色值对应的预设 ID，或 [ThemePresets.customId]。
  final String presetId;

  /// 主操作色：已保证与白色文字对比度 ≥ 4.5:1。
  final int primary;

  final int onPrimary;

  /// 按下态。
  final int pressed;

  /// 正文墨色。
  final int ink;

  /// 淡色衬底（卡片底、选中态、图标底）。
  final int soft;

  /// 页面底色（最浅）。
  final int wash;

  /// 中等淡色。
  final int tint;

  /// 描边色。
  final int border;

  /// 次级文字 / 辅助说明。
  final int muted;

  /// 深色面板背景（首页金额卡）。
  final int darkPanel;

  final int onDarkPanel;

  final int onDarkPanelMuted;

  /// 原始色是否因对比度不足被自动加深。用于告知用户，而不是回写。
  final bool primaryAdjusted;

  // ---------------------------------------------------------------------------
  // 固定语义色：以下全部与主题无关。
  // ---------------------------------------------------------------------------

  /// 以下固定语义色全部写成 **8 位 `0xAARRGGBB`**，alpha 固定为 `FF`。
  ///
  /// ⚠️ 这是一条硬约束，很容易踩坑：
  /// `Color(int)` 按 `0xAARRGGBB` 解释，所以 `Color(0xF5EBE0)` 的 alpha 是 `00`，
  /// 元素会**完全透明地消失**（分隔线、面板描边、徽标底都会看不见），
  /// 而且不会报任何错。因此常量必须自带 `FF`。
  /// 若需要重新导出成渲染用的 [Color]，用 `ColorMath.toColor` 也能正确处理
  /// （它做的 `0xFF000000 | rgb` 对已带 alpha 的值是幂等的）。
  ///
  /// `allFixedColorValues` 与单元测试一起防止回归。

  /// 卡片 / 面板白底。
  static const int surface = 0xFFFFFFFF;

  /// 面板描边。
  static const int panelBorder = 0xFFEEEEE7;

  /// 分隔线。
  static const int line = 0xFFE8E9E1;

  /// 列表行分隔线。
  static const int rowLine = 0xFFEFF0E8;

  /// 圆形图标按钮底色。
  static const int iconButton = 0xFFEFF0E9;

  /// 默认图标块的底色与前景（暖灰）。
  static const int neutralTile = 0xFFF2EEE1;
  static const int neutralOnTile = 0xFF9B8654;

  /// 蓝色图标块（支付宝等）。
  static const int blueTile = 0xFFE9EFF1;
  static const int blueOnTile = 0xFF718E9B;

  /// 紫色图标块（通用表格）。
  static const int purpleTile = 0xFFEFEBF2;
  static const int purpleOnTile = 0xFF9C86A3;

  /// 危险操作：背景 / 前景。
  static const int dangerContainer = 0xFFF5E6DF;
  static const int danger = 0xFFA7664D;

  /// 提示条：背景 / 前景。
  static const int noticeContainer = 0xFFF4EEE1;
  static const int notice = 0xFF9A7856;

  /// 警告徽标。
  static const int warmBadgeContainer = 0xFFF5EBE0;
  static const int warmBadge = 0xFFB98757;

  /// 错误圆形图标底。
  static const int errorCircle = 0xFFF3E9DF;
  static const int errorCircleOn = 0xFFB48460;

  /// 关闭状态的开关轨道。
  static const int switchTrack = 0xFFD3D9CE;

  /// 输入控件描边，比 [border] 略深，保证在浅色主题下可见。
  static const int inputBorder = 0xFFDCE2D6;

  /// 键盘焦点环。
  static const int focus = 0xFFDF9471;

  /// 未重点强调的柱状图柱体（趋势页）。
  static const int chartBar = 0xFFD4DECA;

  /// 消费分类系列色。
  ///
  /// 与图例、环形图、分类详情严格一一对应；主题变化不得影响它们，
  /// 否则图例与图形会对不上（指南 7.3）。
  static const List<int> categorySeries = <int>[
    0xFF416B54, // 深绿
    0xFF97AC7B, // 鼠尾草绿
    0xFFEDC66C, // 暖黄
    0xFF8EAFBC, // 雾蓝
    0xFFA99AC1, // 淡紫
    0xFFDBDED1, // 中性灰绿
  ];

  /// 供 `bar-row` / 环形图使用的「其余」色。
  static const int categorySeriesRest = 0xFFDBDED1;

  /// 遮罩层（底部弹层背景）。
  static const int scrim = 0xFF26392D;

  /// 全部固定语义色，供测试断言它们都是不透明的。
  static const List<int> allFixedColorValues = <int>[
    surface,
    panelBorder,
    line,
    rowLine,
    iconButton,
    neutralTile,
    neutralOnTile,
    blueTile,
    blueOnTile,
    purpleTile,
    purpleOnTile,
    dangerContainer,
    danger,
    noticeContainer,
    notice,
    warmBadgeContainer,
    warmBadge,
    errorCircle,
    errorCircleOn,
    switchTrack,
    inputBorder,
    focus,
    chartBar,
    categorySeriesRest,
    scrim,
    ...categorySeries,
  ];

  // ---------------------------------------------------------------------------
  // Color 便捷读取
  // ---------------------------------------------------------------------------

  Color get primaryColor => ColorMath.toColor(primary);
  Color get onPrimaryColor => ColorMath.toColor(onPrimary);
  Color get pressedColor => ColorMath.toColor(pressed);
  Color get inkColor => ColorMath.toColor(ink);
  Color get softColor => ColorMath.toColor(soft);
  Color get washColor => ColorMath.toColor(wash);
  Color get tintColor => ColorMath.toColor(tint);
  Color get borderColor => ColorMath.toColor(border);
  Color get mutedColor => ColorMath.toColor(muted);
  Color get darkPanelColor => ColorMath.toColor(darkPanel);
  Color get onDarkPanelColor => ColorMath.toColor(onDarkPanel);
  Color get onDarkPanelMutedColor => ColorMath.toColor(onDarkPanelMuted);

  /// 语义令牌的便捷访问入口。
  ///
  /// 用法：`YounumColors.of(context).primaryColor`
  static YounumColors of(BuildContext context) {
    final colors = Theme.of(context).extension<YounumColors>();
    assert(colors != null, 'YounumTheme 未安装，请检查 MaterialApp 的 theme 配置。');
    return colors ?? YounumColors.fromRaw(ThemePresets.defaultPreset.color);
  }

  @override
  YounumColors copyWith({
    int? raw,
    String? presetId,
    int? primary,
    int? onPrimary,
    int? pressed,
    int? ink,
    int? soft,
    int? wash,
    int? tint,
    int? border,
    int? muted,
    int? darkPanel,
    int? onDarkPanel,
    int? onDarkPanelMuted,
    bool? primaryAdjusted,
  }) {
    return YounumColors(
      raw: raw ?? this.raw,
      presetId: presetId ?? this.presetId,
      primary: primary ?? this.primary,
      onPrimary: onPrimary ?? this.onPrimary,
      pressed: pressed ?? this.pressed,
      ink: ink ?? this.ink,
      soft: soft ?? this.soft,
      wash: wash ?? this.wash,
      tint: tint ?? this.tint,
      border: border ?? this.border,
      muted: muted ?? this.muted,
      darkPanel: darkPanel ?? this.darkPanel,
      onDarkPanel: onDarkPanel ?? this.onDarkPanel,
      onDarkPanelMuted: onDarkPanelMuted ?? this.onDarkPanelMuted,
      primaryAdjusted: primaryAdjusted ?? this.primaryAdjusted,
    );
  }

  @override
  YounumColors lerp(ThemeExtension<YounumColors>? other, double t) {
    if (other is! YounumColors) return this;
    int l(int a, int b) => ColorMath.mix(a, b, t);
    return YounumColors(
      raw: l(raw, other.raw),
      presetId: t < 0.5 ? presetId : other.presetId,
      primary: l(primary, other.primary),
      onPrimary: l(onPrimary, other.onPrimary),
      pressed: l(pressed, other.pressed),
      ink: l(ink, other.ink),
      soft: l(soft, other.soft),
      wash: l(wash, other.wash),
      tint: l(tint, other.tint),
      border: l(border, other.border),
      muted: l(muted, other.muted),
      darkPanel: l(darkPanel, other.darkPanel),
      onDarkPanel: l(onDarkPanel, other.onDarkPanel),
      onDarkPanelMuted: l(onDarkPanelMuted, other.onDarkPanelMuted),
      primaryAdjusted: t < 0.5 ? primaryAdjusted : other.primaryAdjusted,
    );
  }
}
