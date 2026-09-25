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

    try {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.scale(scale);

      // 底色。
      canvas.drawRect(
        ui.Rect.fromLTWH(0, 0, spec.width, spec.height),
        ui.Paint()..color = spec.palette.background,
      );

      // 文字位置与大小全部来自 SharePosterLayout —— 界面预览读的也是它。
      final maxWidth = SharePosterLayout.maxWidthOf(spec);
      for (final placement in SharePosterLayout.placementsOf(spec)) {
        _draw(
          canvas,
          placement.text,
          x: placement.x,
          bottom: placement.bottom,
          size: placement.size,
          color: SharePosterLayout.colorOf(spec, placement.role),
          weight: placement.weight,
          align: placement.align,
          maxWidth: maxWidth,
        );
      }

      // 细分隔线：和原型一样，把金额和笔数分开。用次要色的半透明，不抢视线。
      canvas.drawRect(
        SharePosterLayout.dividerOf(spec),
        ui.Paint()..color = spec.palette.muted.withValues(alpha: 0.35),
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
    final builder =
        ui.ParagraphBuilder(
          ui.ParagraphStyle(
            fontSize: size,
            fontWeight: weight,
            textAlign: align,
            maxLines: 1,
          ),
        )..pushStyle(
          ui.TextStyle(color: color, fontSize: size, fontWeight: weight),
        );
    builder.addText(text);
    final paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: maxWidth));
    canvas.drawParagraph(paragraph, ui.Offset(x, bottom - paragraph.height));
  }
}
