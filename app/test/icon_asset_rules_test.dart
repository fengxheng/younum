import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:younum/core/designsystem/younum_icons.dart';
import 'package:younum/domain/rules/category_rules.dart';
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

  group('预设图标库', () {
    // 这些键按分类存进了数据库（`category.icon_key`），改名或删除等于把
    // 用户已经选好的图标弄丢。所以它们必须一直在。
    const legendary = <String, String>{
      'food': '餐饮',
      'coffee': '咖啡',
      'bag': '购物',
      'car': '交通',
      'home': '居住',
      'play': '娱乐',
      'heart': '健康',
      'gift': '人情',
      'file': '文件',
      'wallet': '钱包',
      'user': '个人',
      'leaf': '叶片',
    };

    test('指南 14.3 要求的 12 类一个都不能少、不能改名', () {
      for (final entry in legendary.entries) {
        expect(
          YounumIcons.isBuiltinCategoryKey(entry.key),
          isTrue,
          reason: '${entry.key} 已经存进过数据库，不能删',
        );
        expect(YounumIcons.categoryIconLabel(entry.key), entry.value);
      }
    });

    test('图标变多了（用户反馈预设太少）', () {
      expect(
        YounumIcons.builtinCategoryKeys.length,
        greaterThanOrEqualTo(40),
        reason: '只给十来个预设时，用户几乎只能在「默认叶子」和「自己的照片」之间选',
      );
    });

    test('每个键都有图标与名字，名字两两不同', () {
      // 名字在编辑器里**同时是选项名**（`CategoryGrid` 按名字选中）：
      // 重名会让选中态落到错误的那一格 —— 而且是静默的。
      final labels = <String>{};
      for (final key in YounumIcons.builtinCategoryKeys) {
        expect(key.trim(), isNotEmpty);
        expect(
          YounumIcons.categoryIconLabels.containsKey(key),
          isTrue,
          reason: '$key 少了中文名，TalkBack 会读不出它是什么',
        );
        expect(
          YounumIcons.categoryIconLabels[key],
          isNot(equals(YounumIcons.defaultCategoryIconKey)),
        );
        expect(
          labels.add(YounumIcons.categoryIconLabels[key]!),
          isTrue,
          reason: '${YounumIcons.categoryIconLabels[key]} 这个名字重复了',
        );
      }
    });

    test('未知的键原样返回（emoji 就这样被读出来）', () {
      expect(YounumIcons.categoryIconLabel('🍜'), '🍜');
      expect(YounumIcons.isBuiltinCategoryKey('🍜'), isFalse);
    });
  });

  group('emoji 当图标（用户直接填）', () {
    test('常见的 emoji 放行', () {
      for (final emoji in <String>['🍜', '🐱', '✈️', '🏠', '👨‍👩‍👧']) {
        expect(
          CategoryRules.validateEmojiIconKey(raw: emoji),
          isNull,
          reason: '$emoji 应该可以用',
        );
      }
    });

    test('首尾空白不算内容', () {
      expect(
        CategoryRules.validateEmojiIconKey(raw: '  🍜  '),
        isNull,
      );
    });

    test('空的要说清「填一个 emoji 或者从预设里挑」', () {
      final error = CategoryRules.validateEmojiIconKey(raw: '   ');
      expect(error, isA<CategoryIconEmojiEmpty>());
      expect(error!.message, contains('emoji'));
    });

    test('文字 / 数字 / 空格都不行（图标不是第二个名字）', () {
      for (final text in <String>['拉面', 'ab', '12', '吃 饭']) {
        expect(
          CategoryRules.validateEmojiIconKey(raw: text),
          isA<CategoryIconEmojiNotEmoji>(),
          reason: '$text 不是 emoji',
        );
      }
    });

    test('太长的不行', () {
      expect(
        CategoryRules.validateEmojiIconKey(raw: '🍜🍜🍜🍜🍜'),
        isA<CategoryIconEmojiTooLong>(),
      );
      expect(CategoryRules.maxEmojiIconLength, 8);
    });
  });
}
