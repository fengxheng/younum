import 'dart:math' as math;
import 'dart:ui' show Color;

/// 颜色运算。
///
/// 全部以 `0xRRGGBB` 整数形式计算，刻意不依赖 [Color] 的 `r/g/b` 属性，
/// 这样既与原型 `theme.js` 的逐通道 sRGB 混色逐位对齐，也不受 Flutter
/// 颜色 API 版本变化影响。
///
/// 规则来源：实现指南 7.3「派生色与覆盖范围」。
abstract final class ColorMath {
  /// 与 `theme.js: mixTheme` 等价：`mix(a, b, t) = round(a × (1-t) + b × t)`。
  static int mix(int a, int b, double t) {
    final keep = 1.0 - t;
    int channel(int shift) {
      final ca = (a >> shift) & 0xFF;
      final cb = (b >> shift) & 0xFF;
      return (ca * keep + cb * t).round().clamp(0, 255);
    }

    return (channel(16) << 16) | (channel(8) << 8) | channel(0);
  }

  /// 线性化 sRGB 相对亮度。
  ///
  /// 必须线性化，不能直接平均 RGB 通道，否则对比度判断会失真（指南 7.3）。
  static double relativeLuminance(int rgb) {
    double linearize(int shift) {
      final v = ((rgb >> shift) & 0xFF) / 255.0;
      return v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * linearize(16) + 0.7152 * linearize(8) + 0.0722 * linearize(0);
  }

  /// 与白色的对比度。
  static double contrastWithWhite(int rgb) => 1.05 / (relativeLuminance(rgb) + 0.05);

  /// 与黑色的对比度。
  static double contrastWithBlack(int rgb) => (relativeLuminance(rgb) + 0.05) / 0.05;

  /// 两色对比度，供测试断言使用。
  static double contrast(int a, int b) {
    final la = relativeLuminance(a);
    final lb = relativeLuminance(b);
    final hi = math.max(la, lb);
    final lo = math.min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
  }

  /// 从原始色开始，每步向黑色混合 5%，直到与白色文字对比度 ≥ 4.5:1。
  ///
  /// 上限 60 步与原型一致；纯白 [0xFFFFFF] 需要约 55 步，留有余量。
  static int readableOnWhite(int rgb) {
    var result = rgb;
    for (var step = 0; step < 60 && contrastWithWhite(result) < 4.5; step++) {
      result = mix(result, 0x000000, 0.05);
    }
    return result;
  }

  /// 该主色是否经过自动加深。
  static bool wasReadableAdjustmentApplied(int raw) => readableOnWhite(raw) != raw;

  /// `#RRGGBB`（大写）。永不返回 `#AARRGGBB`，避免写回 DataStore 时改变语义。
  static String toHex(int rgb) =>
      '#${(rgb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  /// 解析用户输入的 HEX。只接受完整 `#RRGGBB`，允许省略 `#`，忽略两端空白。
  ///
  /// 返回 null 表示非法输入 —— 调用方必须保持上一次有效主题，不能回退到默认色
  /// （指南 7.2）。
  static int? tryParseHex(String? text) {
    if (text == null) return null;
    var value = text.trim();
    if (value.startsWith('#')) value = value.substring(1);
    if (value.length != 6) return null;
    if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(value)) return null;
    return int.parse(value, radix: 16);
  }

  /// 供 Compose 树使用的 [Color]。
  static Color toColor(int rgb) => Color(0xFF000000 | (rgb & 0xFFFFFF));
}
