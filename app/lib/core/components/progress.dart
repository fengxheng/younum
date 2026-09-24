import 'package:flutter/material.dart';

import '../designsystem/younum_colors.dart';
import '../designsystem/younum_dimens.dart';
import '../designsystem/younum_text.dart';
import 'buttons.dart';

/// 进度条。
///
/// [value] 为 0–1。传 null 表示不定进度 —— 实现指南 4.2.9 要求真实进度，
/// 未知总量时必须用不定进度，不能伪造百分比。
class YounumProgressTrack extends StatelessWidget {
  const YounumProgressTrack({
    super.key,
    this.value,
    this.height = YounumDimens.progressTrackHeight,
    this.semanticLabel,
    this.margin,
  });

  final double? value;
  final double height;
  final String? semanticLabel;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final clamped = value?.clamp(0.0, 1.0);
    final percent = clamped == null ? null : (clamped * 100).round();

    return Padding(
      padding: margin ?? const EdgeInsets.symmetric(vertical: 8),
      child: Semantics(
        label: semanticLabel ?? '完成进度',
        value: percent == null ? '计算中' : '$percent%',
        child: ClipRRect(
          borderRadius: BorderRadius.circular(height),
          child: SizedBox(
            height: height,
            child: clamped == null
                // 不定进度：用系统指示器，避免出现假的固定百分比。
                ? LinearProgressIndicator(
                    backgroundColor: colors.softColor,
                    color: colors.primaryColor,
                    minHeight: height,
                  )
                : Stack(
                    children: <Widget>[
                      Container(color: colors.softColor),
                      FractionallySizedBox(
                        widthFactor: clamped,
                        child: Container(color: colors.primaryColor),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// 环形消费分布图。
///
/// 用 [CustomPainter] 绘制而不是截图，并提供文字版图例与朗读摘要（指南 6.2）。
class YounumDonutChart extends StatelessWidget {
  const YounumDonutChart({
    super.key,
    required this.slices,
    required this.centerLabel,
    required this.centerValue,
    this.size = YounumDimens.donutSize,
    this.thickness = 21,
  });

  /// 切片。必须已按展示顺序排好，颜色由调用方给出以保证与图例一致。
  final List<YounumDonutSlice> slices;

  final String centerLabel;
  final String centerValue;
  final double size;
  final double thickness;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final total = slices.fold<double>(0, (sum, slice) => sum + slice.value);
    final summary = slices.isEmpty || total <= 0
        ? '暂无消费数据'
        : slices
            .map((s) => '${s.label} ${(s.value / total * 100).toStringAsFixed(1)}%')
            .join('，');

    return Center(
      child: Semantics(
        label: '消费分布',
        value: summary,
        child: ExcludeSemantics(
          child: SizedBox(
            width: size,
            height: size,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                CustomPaint(
                  size: Size.square(size),
                  painter: _DonutPainter(slices: slices, thickness: thickness),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(centerLabel, style: text.caption),
                    Text(centerValue, style: text.statNumber),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 环形图的一片。
class YounumDonutSlice {
  const YounumDonutSlice({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final double value;
  final Color color;
}

class _DonutPainter extends CustomPainter {
  const _DonutPainter({required this.slices, required this.thickness});

  final List<YounumDonutSlice> slices;
  final double thickness;

  @override
  void paint(Canvas canvas, Size size) {
    final total = slices.fold<double>(0, (sum, slice) => sum + slice.value);
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - thickness) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.butt;

    if (total <= 0) {
      // 没有消费时用中性底环，而不是除以零或画出空心的错误图形（指南 3.4）。
      paint.color = const Color(YounumColors.categorySeriesRest);
      canvas.drawCircle(center, radius, paint);
      return;
    }

    var start = -1.5707963267948966; // -90°，从 12 点方向开始
    for (final slice in slices) {
      if (slice.value <= 0) continue;
      final sweep = slice.value / total * 6.283185307179586;
      paint.color = slice.color;
      canvas.drawArc(rect, start, sweep, false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter oldDelegate) =>
      oldDelegate.thickness != thickness ||
      oldDelegate.slices.length != slices.length ||
      !_sameSlices(oldDelegate.slices, slices);

  static bool _sameSlices(List<YounumDonutSlice> a, List<YounumDonutSlice> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i].value != b[i].value || a[i].color != b[i].color) return false;
    }
    return true;
  }
}

/// 图例。
class YounumLegend extends StatelessWidget {
  const YounumLegend({super.key, required this.entries, this.columns = 2});

  final List<YounumLegendEntry> entries;
  final int columns;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 12.0;
        final itemWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: 12,
          children: entries
              .map(
                (entry) => SizedBox(
                  width: itemWidth,
                  child: Row(
                    children: <Widget>[
                      ExcludeSemantics(
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: entry.color,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          entry.label,
                          overflow: TextOverflow.ellipsis,
                          style: YounumText.of(context).caption,
                        ),
                      ),
                      Text(
                        entry.value,
                        style: YounumText.of(context)
                            .caption
                            .copyWith(fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
              )
              .toList(growable: false),
        );
      },
    );
  }
}

/// 图例项。
class YounumLegendEntry {
  const YounumLegendEntry({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;
}

/// 横向条状比例行（月报的分类占比）。
class YounumBarRow extends StatelessWidget {
  const YounumBarRow({
    super.key,
    required this.label,
    required this.amountText,
    required this.percent,
    this.onTap,
  });

  final String label;
  final String amountText;

  /// 0–1。
  final double percent;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final percentText = '${(percent * 100).toStringAsFixed(1)}%';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: YounumPressable(
        onTap: onTap,
        semanticLabel: '$label $amountText，占比 $percentText',
        borderRadius: BorderRadius.circular(8),
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(child: Text(label, style: text.body)),
                Text('$amountText · $percentText', style: text.body),
              ],
            ),
            YounumProgressTrack(value: percent, height: 8, semanticLabel: '$label 占比'),
          ],
        ),
      ),
    );
  }
}
