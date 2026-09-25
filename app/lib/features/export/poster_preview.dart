/// 海报预览。
///
/// ⚠️ 预览与导出的文件读的是**同一份版式**（[SharePosterLayout]），所以屏幕上
/// 看到的排布就是文件里的排布，不存在「预览一个样、导出另一个样」。
///
/// 预览用的是 `TextPainter` 直接画（不经过 PNG 编解码），因为 widget 测试里
/// 真实解码必须 `runAsync`，会和 `pumpAndSettle` 互相等待（分类图标那块踩过）。
/// 文件本身由 `SharePosterRenderer` 生成，另有引擎测试覆盖。
library;

import 'package:flutter/material.dart';

import '../../domain/rules/share_poster_rules.dart';

/// 一段文字排版时该用的最小宽度。
///
/// 右对齐必须让段落**撑满**可用宽度，否则段落会缩到文字自身的宽度，
/// 对齐无从谈起（真机上表现为「有数」和月份叠在一起）。
/// 左对齐则给 0 就行。
double textBoxMinWidth(PosterTextPlacement placement, double maxWidth) =>
    placement.align == TextAlign.right ? maxWidth : 0;

/// 按设计尺寸等比缩放显示海报。
class PosterPreview extends StatelessWidget {
  const PosterPreview({super.key, required this.spec, this.semanticLabel});

  final SharePosterSpec spec;

  /// 读屏用的说明。整张图对读屏就是一个对象，不逐行念。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      image: true,
      child: AspectRatio(
        aspectRatio: spec.width / spec.height,
        child: CustomPaint(
          painter: _PosterPainter(spec),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _PosterPainter extends CustomPainter {
  const _PosterPainter(this.spec);

  final SharePosterSpec spec;

  @override
  void paint(Canvas canvas, Size size) {
    // 高度由 AspectRatio 保证是同一比例，用宽度算缩放比即可。
    final scale = size.width / spec.width;
    canvas.save();
    canvas.scale(scale);

    canvas.drawRect(
      Rect.fromLTWH(0, 0, spec.width, spec.height),
      Paint()..color = spec.palette.background,
    );

    final maxWidth = SharePosterLayout.maxWidthOf(spec);
    for (final placement in SharePosterLayout.placementsOf(spec)) {
      if (placement.text.isEmpty) continue;
      final painter =
          TextPainter(
            text: TextSpan(
              text: placement.text,
              style: TextStyle(
                color: SharePosterLayout.colorOf(spec, placement.role),
                fontSize: placement.size,
                fontWeight: placement.weight,
              ),
            ),
            textAlign: placement.align,
            textDirection: TextDirection.ltr,
            maxLines: 1,
          )..layout(
            // ⚠️ minWidth 必须跟着给：只给 maxWidth 的话，段落宽度会缩到**文字自身**
            // 的宽度，TextAlign.right 就没有可对齐的空间了 —— 右对齐失效，
            // 月份与品牌字样会叠在一起（这条真在真机上出现过）。
            minWidth: textBoxMinWidth(placement, maxWidth),
            maxWidth: maxWidth,
          );
      painter.paint(
        canvas,
        Offset(placement.x, placement.bottom - painter.height),
      );
    }

    canvas.drawRect(
      SharePosterLayout.dividerOf(spec),
      Paint()..color = spec.palette.muted.withValues(alpha: 0.35),
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_PosterPainter oldDelegate) =>
      !identical(oldDelegate.spec, spec);
}
