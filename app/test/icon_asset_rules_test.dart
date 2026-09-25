import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:younum/domain/rules/icon_asset_rules.dart';

/// 分类图片图标的校验规则（指南 14.4 / 设计稿「分类管理」）。
///
/// 这些判断写成纯函数，是为了让「大文件、大尺寸、损坏图、错误格式」这些
/// 边界能在单元测试里穷举 —— 否则只能靠真机上拿一张大图去试，
/// 而那种验法既慢又容易漏。
void main() {
  /// 造一段以 [magic] 开头、总长 [size] 的假图片字节。
  Uint8List bytes(List<int> magic, {int size = 64}) {
    final data = Uint8List(size);
    for (var index = 0; index < magic.length && index < size; index++) {
      data[index] = magic[index];
    }
    return data;
  }

  final png = bytes(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final jpeg = bytes(<int>[0xFF, 0xD8, 0xFF, 0xE0]);
  final webp = bytes(<int>[
    0x52, 0x49, 0x46, 0x46, // RIFF
    0x10, 0x00, 0x00, 0x00, // 长度
    0x57, 0x45, 0x42, 0x50, // WEBP
  ]);
  final gif = bytes(<int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);

  group('格式识别（看文件头，不看后缀）', () {
    test('认识 PNG / JPEG / WebP', () {
      expect(IconAssetRules.formatOf(png), IconAssetFormat.png);
      expect(IconAssetRules.formatOf(jpeg), IconAssetFormat.jpeg);
      expect(IconAssetRules.formatOf(webp), IconAssetFormat.webp);
    });

    test('GIF 与别的格式不认识（设计稿只要求三种）', () {
      expect(IconAssetRules.formatOf(gif), isNull);
      expect(IconAssetRules.formatOf(Uint8List(0)), isNull);
    });
  });

  group('字节校验', () {
    test('空内容当成损坏图', () {
      expect(IconAssetRules.validateBytes(Uint8List(0)), isA<IconBrokenImage>());
    });

    test('超过 2 MB 被拒，刚好 2 MB 放行', () {
      final tooBig = bytes(
        <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
        size: IconAssetRules.maxBytes + 1,
      );
      expect(IconAssetRules.validateBytes(tooBig), isA<IconFileTooLarge>());
      expect(
        IconAssetRules.validateBytes(
          bytes(
            <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
            size: IconAssetRules.maxBytes,
          ),
        ),
        isNull,
        reason: '边界值本身要放行',
      );
    });

    test('格式不对时给出可读原因', () {
      final error = IconAssetRules.validateBytes(gif);
      expect(error, isA<IconFormatUnsupported>());
      expect(error!.message, contains('PNG'));
    });
  });

  group('尺寸校验', () {
    test('1600 万像素放行，再多一点就被拒', () {
      expect(
        IconAssetRules.validateDimensions(width: 4000, height: 4000),
        isNull,
      );
      expect(
        IconAssetRules.validateDimensions(width: 4001, height: 4000),
        isA<IconTooManyPixels>(),
      );
    });

    test('宽高为 0 当成损坏图', () {
      expect(
        IconAssetRules.validateDimensions(width: 0, height: 100),
        isA<IconBrokenImage>(),
      );
    });
  });

  group('居中方形裁切', () {
    test('横图裁左右', () {
      expect(
        IconAssetRules.squareCrop(width: 100, height: 50),
        (25, 0, 50),
      );
    });

    test('竖图裁上下', () {
      expect(
        IconAssetRules.squareCrop(width: 50, height: 100),
        (0, 25, 50),
      );
    });

    test('正方形不动', () {
      expect(IconAssetRules.squareCrop(width: 100, height: 100), (0, 0, 100));
    });

    test('差值是奇数时取整，不越界', () {
      final (left, top, side) = IconAssetRules.squareCrop(
        width: 101,
        height: 50,
      );
      expect(side, 50);
      expect(left, 25);
      expect(top, 0);
      expect(left + side, lessThanOrEqualTo(101));
    });
  });
}
