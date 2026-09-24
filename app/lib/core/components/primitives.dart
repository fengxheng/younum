import 'package:flutter/material.dart';

import '../designsystem/color_math.dart';
import '../designsystem/younum_colors.dart';
import '../designsystem/younum_dimens.dart';
import '../designsystem/younum_icons.dart';
import '../designsystem/younum_text.dart';

/// 面板外观。
enum YounumPanelTone {
  /// 白底 + 细描边。用于信息分组。
  surface,

  /// 主题淡色衬底，无描边。用于说明、引导、提醒。
  soft,

  /// 主题主色实底 + 白色文字。用于首页的金额卡。
  dark,
}

/// 通用面板。
///
/// 对应原型的 `.panel` / `.panel.green` / `.panel.dark`，但圆角按指南 6.2
/// 统一到 16dp。
class YounumPanel extends StatelessWidget {
  const YounumPanel({
    super.key,
    required this.child,
    this.tone = YounumPanelTone.surface,
    this.padding,
    this.margin,
  });

  final Widget child;
  final YounumPanelTone tone;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final (Color background, Border? border) = switch (tone) {
      YounumPanelTone.surface => (
          const Color(YounumColors.surface),
          Border.all(color: Color(YounumColors.panelBorder)),
        ),
      YounumPanelTone.soft => (colors.softColor, null),
      YounumPanelTone.dark => (colors.darkPanelColor, null),
    };

    return Container(
      width: double.infinity,
      margin: margin ?? const EdgeInsets.symmetric(vertical: YounumDimens.gap),
      padding: padding ?? const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: background,
        border: border,
        borderRadius: BorderRadius.circular(YounumDimens.radiusPanel),
      ),
      // 深色面板里的文字由调用方用 YounumPanelTextScope 取白色样式。
      child: tone == YounumPanelTone.dark
          ? _DarkPanelScope(isDark: true, child: child)
          : child,
    );
  }
}

/// 标记「当前子树处在一个深色面板内」。
///
/// 让 [YounumLineInfo] / [YounumMutedText] 之类的原子无需逐个传色。
class _DarkPanelScope extends InheritedWidget {
  const _DarkPanelScope({required this.isDark, required super.child});

  final bool isDark;

  static bool isDarkPanel(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_DarkPanelScope>()?.isDark ?? false;

  @override
  bool updateShouldNotify(_DarkPanelScope oldWidget) => oldWidget.isDark != isDark;
}

/// 面板内是否处于深色底。
bool isOnDarkPanel(BuildContext context) => _DarkPanelScope.isDarkPanel(context);

/// 次级说明文字。自动适配深色面板。
class YounumMutedText extends StatelessWidget {
  const YounumMutedText(this.text, {super.key, this.style, this.textAlign});

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final text_ = YounumText.of(context);
    final base = isOnDarkPanel(context)
        ? text_.body.copyWith(color: YounumColors.of(context).onDarkPanelMutedColor)
        : text_.bodyMuted;
    return Text(text, style: base.merge(style), textAlign: textAlign);
  }
}

/// 极短辅助说明。字号下限 12sp（指南 6.2）。
class YounumCaptionText extends StatelessWidget {
  const YounumCaptionText(this.text, {super.key, this.style, this.textAlign});

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final text_ = YounumText.of(context);
    final base = isOnDarkPanel(context)
        ? text_.caption.copyWith(color: YounumColors.of(context).onDarkPanelMutedColor)
        : text_.caption;
    return Text(text, style: base.merge(style), textAlign: textAlign);
  }
}

/// 分隔线。深色面板上自动改为半透明白。
class YounumDivider extends StatelessWidget {
  const YounumDivider({super.key, this.margin});

  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    return Container(
      height: 1,
      margin: margin ?? const EdgeInsets.symmetric(vertical: 16),
      color: isOnDarkPanel(context)
          ? colors.onDarkPanelColor.withValues(alpha: 0.16)
          : const Color(YounumColors.line),
    );
  }
}

/// 虚线分隔线（票据风格，用于卡片底部）。
///
/// 用 `CustomPaint` 画，而不是摆一排 `Container`：
/// 后者的实现每行会产生几十个 RenderObject，而这张卡片在拖动时每帧都要重绘，
/// 渲染对象越多越容易掉帧。
class YounumDashedDivider extends StatelessWidget {
  const YounumDashedDivider({super.key, this.margin});

  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    return Padding(
      padding: margin ?? const EdgeInsets.symmetric(vertical: 16),
      // SizedBox 给一个确定高度，CustomPaint 就用宽度约束铺满整行。
      child: SizedBox(
        height: 1,
        child: CustomPaint(
          painter: _DashedLinePainter(color: colors.borderColor),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _DashedLinePainter extends CustomPainter {
  const _DashedLinePainter({required this.color});

  final Color color;

  static const double _dash = 5;
  static const double _gap = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += _dash + _gap) {
      final end = (x + _dash).clamp(0.0, size.width);
      canvas.drawLine(Offset(x, 0.5), Offset(end, 0.5), paint);
    }
  }

  @override
  bool shouldRepaint(_DashedLinePainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 「标签 : 值」信息行。
class YounumLineInfo extends StatelessWidget {
  const YounumLineInfo({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final dark = isOnDarkPanel(context);
    final colors = YounumColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: text.body.copyWith(color: dark ? colors.onDarkPanelMutedColor : null),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: text.body.copyWith(
                fontWeight: FontWeight.w500,
                color: dark ? colors.onDarkPanelColor : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 小徽标。
class YounumBadge extends StatelessWidget {
  const YounumBadge(this.label, {super.key, this.tone = YounumBadgeTone.primary});

  final String label;
  final YounumBadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final (Color background, Color foreground) = switch (tone) {
      YounumBadgeTone.primary => (colors.softColor, colors.primaryColor),
      YounumBadgeTone.warm => (
          const Color(YounumColors.warmBadgeContainer),
          const Color(YounumColors.warmBadge),
        ),
      YounumBadgeTone.onDark => (
          colors.onDarkPanelColor.withValues(alpha: 0.22),
          colors.onDarkPanelColor,
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(YounumDimens.radiusBadge),
      ),
      child: Text(
        label,
        style: YounumText.of(context).badge.copyWith(color: foreground),
      ),
    );
  }
}

enum YounumBadgeTone { primary, warm, onDark }

/// 提示条。语义色独立于主题，避免被误认为普通信息（指南 7.3）。
class YounumNotice extends StatelessWidget {
  const YounumNotice(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: YounumDimens.gap),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(YounumColors.noticeContainer),
        borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
      ),
      child: Text(
        text,
        style: YounumText.of(context).body.copyWith(
              fontSize: 13,
              height: 1.8,
              color: const Color(YounumColors.notice),
            ),
      ),
    );
  }
}

/// 居中细注释。
class YounumPillNote extends StatelessWidget {
  const YounumPillNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: YounumCaptionText(text, textAlign: TextAlign.center),
    );
  }
}

/// 标题 + 右侧操作的区块头。
class YounumSectionHeader extends StatelessWidget {
  const YounumSectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.titleStyle,
    this.padding = const EdgeInsets.only(top: 12, bottom: 8),
  });

  final String title;
  final Widget? trailing;
  final TextStyle? titleStyle;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    return Padding(
      padding: padding,
      child: Row(
        children: <Widget>[
          Expanded(child: Text(title, style: titleStyle ?? text.sectionTitle)),
          ?trailing,
        ],
      ),
    );
  }
}

/// 居中的小字说明（无需圆角的场景）。
class YounumMetaRow extends StatelessWidget {
  const YounumMetaRow({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: YounumDimens.gap),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          ExcludeSemantics(
            child: Icon(icon, size: YounumDimens.iconSm, color: colors.mutedColor),
          ),
          const SizedBox(width: 6),
          Flexible(child: YounumCaptionText(text)),
        ],
      ),
    );
  }
}

/// 设计走查提示。
///
/// 用于那些「界面已按设计稿实现、但对应能力尚未接入」的页面。
///
/// 这不是装饰：实现指南 1.3 与 12 要求不得留下伪造成功返回的占位功能。
/// 与其假装可用，不如就地写明当前状态，让走查者和用户都能准确判断。
/// 阶段 2-6 每接通一项真实能力，就删掉对应页面上的这个提示。
class YounumDemoNote extends StatelessWidget {
  const YounumDemoNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: YounumDimens.gap),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.tintColor.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
        border: Border.all(color: colors.borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ExcludeSemantics(
            child: Icon(
              Icons.info_outline,
              size: YounumDimens.iconSm,
              color: colors.primaryColor,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: YounumText.of(context)
                  .caption
                  .copyWith(color: colors.primaryColor),
            ),
          ),
        ],
      ),
    );
  }
}

/// 空状态。
class YounumEmptyState extends StatelessWidget {
  const YounumEmptyState({
    super.key,
    required this.title,
    this.description,
    this.icon = Icons.inbox_outlined,
    this.action,
  });

  final String title;
  final String? description;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final text = YounumText.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: YounumDimens.pageHorizontal,
          vertical: 48,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ExcludeSemantics(
              child: Icon(icon, size: 56, color: colors.tintColor),
            ),
            const SizedBox(height: YounumDimens.gapLg),
            Text(title, textAlign: TextAlign.center, style: text.sectionTitle),
            if (description != null) ...<Widget>[
              const SizedBox(height: YounumDimens.gapSm),
              YounumCaptionText(description!, textAlign: TextAlign.center),
            ],
            if (action != null) ...<Widget>[
              const SizedBox(height: YounumDimens.gapXl),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 错误状态。错误色独立于主题。
class YounumErrorState extends StatelessWidget {
  const YounumErrorState({
    super.key,
    required this.title,
    this.description,
    this.action,
  });

  final String title;
  final String? description;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: YounumDimens.pageHorizontal,
          vertical: 48,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const ExcludeSemantics(child: YounumCircleSymbol(icon: YounumIcons.alert, tone: YounumCircleTone.error)),
            const SizedBox(height: YounumDimens.gapLg),
            Text(title, textAlign: TextAlign.center, style: text.sectionTitle),
            if (description != null) ...<Widget>[
              const SizedBox(height: YounumDimens.gapSm),
              YounumCaptionText(description!, textAlign: TextAlign.center),
            ],
            if (action != null) ...<Widget>[
              const SizedBox(height: YounumDimens.gapXl),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 圆形符号，用于引导、完成、错误三类整页状态。
enum YounumCircleTone { primary, error }

class YounumCircleSymbol extends StatelessWidget {
  const YounumCircleSymbol({
    super.key,
    required this.icon,
    this.tone = YounumCircleTone.primary,
    this.diameter = YounumDimens.circleSymbolLarge,
    this.borderWidth = 0,
  });

  final IconData icon;
  final YounumCircleTone tone;
  final double diameter;

  /// 完成页的白色外环用边框实现。
  final double borderWidth;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final (Color background, Color foreground) = switch (tone) {
      YounumCircleTone.primary => (colors.softColor, colors.primaryColor),
      YounumCircleTone.error => (
          const Color(YounumColors.errorCircle),
          const Color(YounumColors.errorCircleOn),
        ),
    };
    return Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        color: background,
        shape: BoxShape.circle,
        border: borderWidth > 0
            ? Border.all(color: colors.washColor, width: borderWidth)
            : null,
      ),
      child: Icon(icon, size: diameter * 0.42, color: foreground),
    );
  }
}

/// 虚线圆角容器（文件上传区）。
class YounumDashedBox extends StatelessWidget {
  const YounumDashedBox({
    super.key,
    required this.child,
    required this.color,
    this.radius = YounumDimens.radiusPanel,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 32),
  });

  final Widget child;
  final Color color;
  final double radius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedRectPainter(color: color, radius: radius),
      child: Padding(padding: padding, child: child),
    );
  }
}

class _DashedRectPainter extends CustomPainter {
  const _DashedRectPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color;

    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          Radius.circular(radius),
        ),
      );

    // 沿路径等距打点，得到虚线效果；纯 Dart 实现，不引入额外依赖。
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + 5).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + 4;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRectPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}

/// 主题色块。
class YounumColorSwatch extends StatelessWidget {
  const YounumColorSwatch({
    super.key,
    required this.color,
    this.width = YounumDimens.themeSwatchWidth,
    this.height = YounumDimens.themeSwatchHeight,
  });

  final int color;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(9),
          // BoxDecoration 不允许同时设置 color 与 gradient，因此整块用渐变表达：
          // 上半是原始主色，下半淡出，暗示按钮底色由主色派生。
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              ColorMath.toColor(color),
              ColorMath.toColor(color),
              ColorMath.toColor(color).withValues(alpha: 0.34),
            ],
            stops: const <double>[0, 0.62, 1],
          ),
        ),
      ),
    );
  }
}
