/// 把月报海报画成 PNG（指南 8.1）。
///
/// 只用 `dart:ui`，**不引图片处理插件**：需要的只有「按清单画文字与色块 →
/// 导出 PNG」这几步，引擎本来就带得动（和分类图标同一个思路）。
///
/// 关键约束：渲染器的**唯一输入**是 `SharePosterSpec`。它拿不到交易、找不到
/// 商户，所以画不出清单之外的东西 —— 这正是「隐私开关作用于文件而不是屏幕遮罩」
/// 能被单元测试断言的原因（见 `DECISIONS.md` 第 55 节）。
///
/// 版式沿用原型（750×1000 的坐标系，绘制时整体等比放大）。
library;

import 'dart:ui' as ui;

import '../../domain/repositories/poster_ports.dart';
import '../../domain/rules/share_poster_rules.dart';

/// 海报渲染器。
final class SharePosterRenderer implements PosterMaker {
  const SharePosterRenderer();

  // 版式坐标全部是**设计单位**（750×1000），改这里等于改版式。
  static const double _marginX = 70;
  static const double _brandY = 110;
  static const double _brandSize = 34;
  static const double _periodSize = 30;
  static const List<double> _headlineY = <double>[290, 375];
  static const double _headlineSize = 58;
  static const double _subtitleY = 500;
  static const double _subtitleSize = 25;
  static const double _amountY = 600;
  static const double _amountSize = 65;
  static const double _dividerY = 668;
  static const double _statsY = 735;
  static const double _statsSize = 25;
  static const double _footerY = 910;
  static const double _footerSize = 21;

  @override
  Future<PosterRenderResult> render(
    SharePosterSpec spec, {
    double scale = posterExportScale,
  }) async {
    if (!scale.isFinite || scale <= 0) {
      return const PosterRenderFailed('缩放比例不合法，无法生成图片');
    }

    final width = (spec.width * scale).round();
    final height = (spec.height * scale).round();
    if (width <= 0 || height <= 0) {
      return const PosterRenderFailed('海报尺寸不合法，无法生成图片');
    }

    final palette = spec.palette;
    try {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.scale(scale);

      canvas.drawRect(
        ui.Rect.fromLTWH(0, 0, spec.width, spec.height),
        ui.Paint()..color = palette.background,
      );

      _draw(
        canvas,
        spec.brand,
        x: _marginX,
        bottom: _brandY,
        size: _brandSize,
        color: palette.foreground,
        weight: ui.FontWeight.w600,
        maxWidth: spec.width - _marginX * 2,
      );
      _draw(
        canvas,
        spec.periodLabel,
        x: _marginX,
        bottom: _brandY,
        size: _periodSize,
        color: palette.muted,
        align: ui.TextAlign.right,
        maxWidth: spec.width - _marginX * 2,
      );

      for (var index = 0; index < spec.headline.length; index++) {
        _draw(
          canvas,
          spec.headline[index],
          x: _marginX,
          bottom: index < _headlineY.length ? _headlineY[index] : _headlineY.last,
          size: _headlineSize,
          color: palette.foreground,
          weight: ui.FontWeight.w500,
          maxWidth: spec.width - _marginX * 2,
        );
      }

      _draw(
        canvas,
        spec.subtitle,
        x: _marginX,
        bottom: _subtitleY,
        size: _subtitleSize,
        color: palette.muted,
        maxWidth: spec.width - _marginX * 2,
      );

      _draw(
        canvas,
        spec.amountText,
        x: _marginX,
        bottom: _amountY,
        size: _amountSize,
        color: palette.foreground,
        weight: ui.FontWeight.w600,
        maxWidth: spec.width - _marginX * 2,
      );

      // 细分隔线：和原型一样，把金额和笔数分开。用次要色的半透明，不抢视线。
      canvas.drawRect(
        ui.Rect.fromLTWH(_marginX, _dividerY, spec.width - _marginX * 2, 2),
        ui.Paint()
          ..color = palette.muted.withValues(alpha: 0.35),
      );

      _draw(
        canvas,
        spec.statsLine,
        x: _marginX,
        bottom: _statsY,
        size: _statsSize,
        color: palette.muted,
        maxWidth: spec.width - _marginX * 2,
      );

      _draw(
        canvas,
        spec.footer,
        x: _marginX,
        bottom: _footerY,
        size: _footerSize,
        color: palette.muted,
        maxWidth: spec.width - _marginX * 2,
      );

      final picture = recorder.endRecording();
      final image = await picture.toImage(width, height);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      picture.dispose();
      image.dispose();

      if (data == null) {
        return const PosterRenderFailed('图片编码失败，请重试');
      }
      return PosterRendered(
        data.buffer.asUint8List(),
        width: width,
        height: height,
      );
    } catch (_) {
      // 内存不足、引擎异常都在这里收口。宁可如实说失败，也不要给一个半张图。
      return const PosterRenderFailed('生成图片时出了点问题，请重试');
    }
  }

  /// 画一行文字。[bottom] 是这一行的底边（比原型给的基线更好算，差几像素不影响版式）。
  static void _draw(
    ui.Canvas canvas,
    String text, {
    required double x,
    required double bottom,
    required double size,
    required ui.Color color,
    required double maxWidth,
    ui.FontWeight weight = ui.FontWeight.w400,
    ui.TextAlign align = ui.TextAlign.left,
  }) {
    if (text.isEmpty) return;
    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        fontSize: size,
        fontWeight: weight,
        textAlign: align,
        maxLines: 1,
      ),
    )..pushStyle(ui.TextStyle(color: color, fontSize: size, fontWeight: weight));
    builder.addText(text);
    final paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: maxWidth));
    canvas.drawParagraph(paragraph, ui.Offset(x, bottom - paragraph.height));
  }
}
