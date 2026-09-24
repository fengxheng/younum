import 'package:flutter_test/flutter_test.dart';
import 'package:younum/core/designsystem/color_math.dart';
import 'package:younum/core/designsystem/theme_presets.dart';
import 'package:younum/core/designsystem/younum_colors.dart';

/// 颜色派生与对比度测试。
///
/// 对应实现指南 7.3 与 10.4：逐通道混色、线性化相对亮度、
/// 主按钮与白色文字对比度 ≥ 4.5:1。
void main() {
  group('混色', () {
    test('t = 0 与 t = 1 是端点', () {
      expect(ColorMath.mix(0x315F4F, 0xFFFFFF, 0), 0x315F4F);
      expect(ColorMath.mix(0x315F4F, 0xFFFFFF, 1), 0xFFFFFF);
    });

    test('与 theme.js 的 round(a*(1-t)+b*t) 一致', () {
      // 0x31 = 49 → 49 * 0.10 + 255 * 0.90 = 234.4 → 234 = 0xEA
      final soft = ColorMath.mix(0x315F4F, 0xFFFFFF, 0.90);
      expect((soft >> 16) & 0xFF, 234);
      // 0x5F = 95 → 9.5 + 229.5 = 239
      expect((soft >> 8) & 0xFF, 239);
      // 0x4F = 79 → 7.9 + 229.5 = 237.4 → 237
      expect(soft & 0xFF, 237);
    });
  });

  group('相对亮度与对比度', () {
    test('黑白对比度为 21:1', () {
      expect(ColorMath.contrastWithWhite(0x000000), closeTo(21, 0.01));
      expect(ColorMath.contrastWithWhite(0xFFFFFF), closeTo(1, 0.01));
    });

    test('线性化后不能直接平均通道', () {
      // 中灰 #808080 的线性亮度低于 0.5，直接平均会得到 0.5。
      expect(ColorMath.relativeLuminance(0x808080), lessThan(0.25));
    });
  });

  group('可读性加深', () {
    test('六套预设的主色与白色对比度均 ≥ 4.5:1', () {
      for (final preset in ThemePresets.all) {
        final primary = ColorMath.readableOnWhite(preset.color);
        expect(
          ColorMath.contrastWithWhite(primary),
          greaterThanOrEqualTo(4.5),
          reason: '${preset.name} (${preset.hex}) 的主色对比度不足',
        );
      }
    });

    test('纯白与纯黄输入会被自动加深', () {
      expect(ColorMath.wasReadableAdjustmentApplied(0xFFFFFF), isTrue);
      expect(ColorMath.wasReadableAdjustmentApplied(0xFFFF00), isTrue);
      final yellow = ColorMath.readableOnWhite(0xFFFF00);
      expect(ColorMath.contrastWithWhite(yellow), greaterThanOrEqualTo(4.5));
    });

    test('深色不会被无谓改动', () {
      const dark = 0x101010;
      expect(ColorMath.readableOnWhite(dark), dark);
      expect(ColorMath.wasReadableAdjustmentApplied(dark), isFalse);
    });
  });

  group('HEX 解析', () {
    test('接受完整 #RRGGBB，忽略大小写与两端空白', () {
      expect(ColorMath.tryParseHex('#be4084'), 0xBE4084);
      expect(ColorMath.tryParseHex('  #BE4084 '), 0xBE4084);
      expect(ColorMath.tryParseHex('BE4084'), 0xBE4084);
    });

    test('拒绝不完整或非法输入', () {
      expect(ColorMath.tryParseHex(null), isNull);
      expect(ColorMath.tryParseHex(''), isNull);
      expect(ColorMath.tryParseHex('#FFF'), isNull);
      expect(ColorMath.tryParseHex('#FFFF00FF'), isNull);
      expect(ColorMath.tryParseHex('#GGGGGG'), isNull);
      expect(ColorMath.tryParseHex('红色'), isNull);
    });

    test('格式化统一为大写六位', () {
      expect(ColorMath.toHex(0xBE4084), '#BE4084');
      expect(ColorMath.toHex(0x000000), '#000000');
    });
  });

  group('语义令牌', () {
    test('预设能被识别，自定义色不会误判为预设', () {
      final forest = YounumColors.fromRaw(ThemePresets.defaultPreset.color);
      expect(forest.presetId, 'forest');
      expect(forest.primaryAdjusted, isFalse);

      final custom = YounumColors.fromRaw(0xBE4084);
      expect(custom.presetId, ThemePresets.customId);
    });

    test('派生色不改变原始色', () {
      final colors = YounumColors.fromRaw(0xFFFFFF);
      expect(colors.raw, 0xFFFFFF);
      expect(colors.primaryAdjusted, isTrue);
      // primary 已被加深，但 raw 仍是用户输入的白。
      expect(colors.primary, isNot(0xFFFFFF));
    });

    test('主题不影响固定语义色', () {
      // 危险色与分类系列色是静态常量，任何主题下都相同。
      expect(YounumColors.danger, 0xFFA7664D);
      expect(YounumColors.categorySeries.first, 0xFF416B54);
    });

    test('固定语义色必须是不透明的 8 位 ARGB', () {
      // 防回归：`Color(int)` 按 0xAARRGGBB 解释。
      // 如果常量漏写 alpha（例如写成 0xF5EBE0），元素会完全透明地消失，
      // 而且不会报错 —— 曾导致示例账本徽标、分隔线、面板描边全部不可见。
      for (final value in YounumColors.allFixedColorValues) {
        expect(
          (value >> 24) & 0xFF,
          0xFF,
          reason: '固定色 0x${value.toRadixString(16).toUpperCase()} 的 alpha 不是 FF',
        );
      }
    });

    test('ColorMath.toColor 对已带 alpha 的值是幂等的', () {
      final expected = ColorMath.toColor(0xFFA7664D);
      expect(expected.a, 1.0);
      expect(expected, ColorMath.toColor(YounumColors.danger));
    });
  });
}
