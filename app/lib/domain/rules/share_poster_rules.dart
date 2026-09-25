/// 月报分享海报：内容与隐私开关。
///
/// 指南 8.1 / 10.4 的硬要求落在这里：
///
/// * 海报要按**当前主题**和隐私开关重新生成；
/// * 默认**不含商户、交易单号、身份信息**，默认**隐藏金额**；
/// * 开关必须作用于**最终文件**，不是屏幕上的遮罩。
///
/// 做法是把「要画什么」独立成一份纯数据（[SharePosterSpec]）：渲染器只能照着
/// 这份清单画，画不出清单之外的东西。于是「隐藏金额」在单元测试里可以直接
/// 断言（清单里根本没有那个数字），而不用对着导出的 PNG 猜。
///
/// 尺寸沿用原型的 750×1000（3:4）。渲染时整体等比放大，不改版式。
library;

import 'dart:ui' show Color;

import '../../core/money/money.dart';
import 'export_rules.dart';
import 'month_overview.dart';
import 'monthly_stats.dart';

/// 海报用色。
///
/// 由调用方从当前主题解析后传进来 —— 规则层不认识主题实现，
/// 这样「换主题换封面」既是事实，也能被测试构造出任意配色。
final class PosterPalette {
  const PosterPalette({
    required this.background,
    required this.foreground,
    required this.muted,
  });

  /// 卡面底色。
  final Color background;

  /// 主文字色（标题、金额）。
  final Color foreground;

  /// 次要文字色。
  final Color muted;
}

/// 海报上要画的全部内容。
final class SharePosterSpec {
  const SharePosterSpec({
    required this.width,
    required this.height,
    required this.palette,
    required this.brand,
    required this.periodLabel,
    required this.headline,
    required this.subtitle,
    required this.amountText,
    required this.showsAmount,
    required this.statsLine,
    required this.footer,
  });

  /// 设计尺寸（会整体等比放大后绘制）。
  final double width;
  final double height;

  final PosterPalette palette;

  /// 品牌字样。
  final String brand;

  /// 「2026 / 09」。
  final String periodLabel;

  /// 大标题，一行一条。
  final List<String> headline;

  /// 「我的 9 月消费手记」。
  final String subtitle;

  /// 金额那一行；隐藏时是占位符。
  final String amountText;

  /// 这一份是否真的展示了金额。
  final bool showsAmount;

  /// 「N 笔生活记录 · M 种生活用途」。
  final String statsLine;

  final String footer;

  /// 海报上的所有文字，按绘制顺序。
  ///
  /// 测试拿它来断言「不该出现的东西一个都没漏出去」。
  List<String> get allText => <String>[
    brand,
    periodLabel,
    ...headline,
    subtitle,
    amountText,
    statsLine,
    footer,
  ];

  @override
  String toString() => 'SharePosterSpec($periodLabel, showsAmount: $showsAmount)';
}

abstract final class SharePosterRules {
  /// 设计单位下的尺寸，与原型一致（3:4）。
  static const double designWidth = 750;
  static const double designHeight = 1000;

  /// 隐藏金额时的占位符。和原型一致：看得见「这里本来有个数」。
  static const String hiddenAmountText = '¥ ••••';

  /// 没有记录时金额位置写的东西。
  ///
  /// 不能写「¥ 0.00」—— 空月份不是「花了 0 元」。
  static const String emptyAmountText = '—';

  /// 没有记录时的统计行。
  static const String emptyStatsLine = '这个月还没有记录';

  static const String brand = '∷ 有数';

  static const List<String> headline = <String>[
    '把钱花在',
    '有意义的生活里。',
  ];

  static const String footer = '每一次看见，都是更了解自己的开始。';

  /// 按真实数据与隐私开关生成海报内容。
  ///
  /// 默认**不出现**商户、交易单号、用途名称：用途是用户自建的词
  /// （「医疗」「心理咨询」之类），默认不往外带最稳妥。
  static SharePosterSpec build({
    required MonthOverview overview,
    required ExportPrivacy privacy,
    required PosterPalette palette,
  }) {
    final summary = overview.summary;
    final month = overview.month;
    final hasRecords = summary.recordCount > 0;

    final String amountText;
    if (!privacy.showAmount) {
      amountText = hiddenAmountText;
    } else if (!hasRecords) {
      amountText = emptyAmountText;
    } else {
      amountText = '¥ ${Money.format(summary.netExpenseCents, grouped: true)}';
    }

    return SharePosterSpec(
      width: designWidth,
      height: designHeight,
      palette: palette,
      brand: brand,
      periodLabel: '${month.year} / ${_two(month.month)}',
      headline: headline,
      subtitle: '我的 ${month.month} 月消费手记',
      amountText: amountText,
      showsAmount: privacy.showAmount && hasRecords,
      statsLine: hasRecords ? _statsLine(summary) : emptyStatsLine,
      footer: footer,
    );
  }

  /// 「N 笔生活记录 · M 种生活用途」。
  ///
  /// 用**消费笔数**而不是记录总数：收入、转账、退款不是「生活记录」里那件
  /// 花钱的事。用**用途个数**而不是分类名。
  static String _statsLine(MonthlySummary summary) {
    final purposes = summary.byCategory.length;
    return '${summary.expenseCount} 笔生活记录 · $purposes 种生活用途';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}
