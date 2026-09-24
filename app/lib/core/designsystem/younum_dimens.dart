import 'package:flutter/widgets.dart';

/// 尺寸令牌。
///
/// 原型画板宽度 375px 只作**比例参考**，这里按实现指南 6.2 的数值区间重新取值，
/// 不做 px → dp 的机械等值复制；所有可点击目标不小于 [minTouchTarget]。
abstract final class YounumDimens {
  /// 页面横向留白（指南建议 20–24dp）。
  static const double pageHorizontal = 22;

  /// 页面底部留白。
  static const double pageTop = 8;
  static const double pageBottom = 24;

  /// 无障碍最小触控目标（6.2：不得因为图标小而缩小点击区域）。
  static const double minTouchTarget = 48;

  // 圆角
  static const double radiusCard = 20;
  static const double radiusPanel = 16;
  static const double radiusSheet = 24;
  static const double radiusControl = 12;
  static const double radiusControlSmall = 10;
  static const double radiusTile = 12;
  static const double radiusBadge = 6;

  // 间距
  static const double gapXs = 4;
  static const double gapSm = 8;
  static const double gap = 12;
  static const double gapLg = 16;
  static const double gapXl = 20;
  static const double gapXxl = 24;
  static const double sectionGap = 28;

  // 组件
  static const double primaryButtonHeight = 48;
  static const double progressTrackHeight = 6;
  static const double bottomNavHeight = 64;
  static const double tileIconSize = 40;
  static const double tileIconInset = 10;

  /// 圆形图标按钮的可视直径；外层补足到 [minTouchTarget]。
  static const double iconButtonVisual = 40;

  /// 堆叠卡片。
  ///
  /// 高度与内边距一起决定卡片内容能否放下：可用内容高度 = 高度 - 2×竖向内边距，
  /// 目前需要约 177dp（图标 40 + 间距 12 + 金额 46 + 间距 8 + 商户 20 + 虚线 33 + 底行 18）。
  /// 改动这里时必须同步核对 `TransactionCardView`，否则大字号下会溢出。
  static const double transactionCardHeight = 236;
  static const double transactionCardPaddingH = 20;
  static const double transactionCardPaddingV = 18;

  /// 后层卡片的水平内缩量。
  static const double stackBackLayerInsetNear = 2;
  static const double stackBackLayerInsetFar = 6;

  /// 后层卡片的旋转角度（度），与原型 `theme.css` 的 +5° / -6° 一致。
  static const double stackBackLayerAngleNear = 5;
  static const double stackBackLayerAngleFar = 6;

  /// 为后层卡片的旋转预留的上下空间。
  ///
  /// 旋转会把矩形的包围盒撑高，超出量 ≈（宽 × sinθ + 高 × cosθ − 高）/ 2。
  /// 以 348dp 宽、236dp 高、6° 计算约为 17dp。
  ///
  /// **不留这段空间，旋转后的后层卡片会向上压到整理进度条上** —— 这是阶段 1
  /// 走查时发现的真实问题。改角度、宽度或卡片高度时必须按上面的公式重算。
  static const double stackSwingReserve = 17;

  /// 分类格子。
  static const double categoryCellMinHeight = 62;
  static const double categoryIconSize = 22;
  static const double categoryGridGap = 8;

  /// 图标尺寸。
  static const double iconXs = 14;
  static const double iconSm = 18;
  static const double iconMd = 20;
  static const double iconLg = 24;
  static const double iconXl = 36;

  /// 圆形装饰图标（成功 / 错误 / 引导）。
  static const double circleSymbolLarge = 88;
  static const double circleSymbolSmall = 60;

  /// 主题预览卡与色块。
  static const double themeSwatchWidth = 28;
  static const double themeSwatchHeight = 36;

  /// 环形图。
  static const double donutSize = 152;
  static const double donutHole = 22;

  /// 趋势柱状图。
  static const double chartHeight = 120;

  /// 表单控件高度。
  static const double fieldHeight = 48;

  static const EdgeInsets pagePadding = EdgeInsets.symmetric(
    horizontal: pageHorizontal,
  );

  /// 弹层内边距（指南：底部弹层圆角 24dp）。
  static const EdgeInsets sheetPadding = EdgeInsets.fromLTRB(
    pageHorizontal,
    10,
    pageHorizontal,
    28,
  );
}
