/// 分类图片图标的校验规则（指南 14.4 / 设计稿「我的 → 分类管理」）。
///
/// 全部是纯函数：不碰文件、不解码、不依赖 Flutter。解码那一步在
/// `lib/data/files/icon_image_processor.dart` 里，它把「字节数 / 尺寸 / 格式」
/// 交给这里的判断，这样这些边界能被单元测试穷举，
/// 而不是只能靠在真机上拿大图试。
library;

import 'dart:typed_data';

/// 支持的图片格式。
enum IconAssetFormat { png, jpeg, webp }

/// 图片校验失败的原因。
sealed class IconAssetError {
  const IconAssetError(this.message);

  /// 直接给用户看的原因。
  final String message;
}

/// 文件太大。
final class IconFileTooLarge extends IconAssetError {
  const IconFileTooLarge() : super('这张图超过 2 MB，先压缩一下再试');
}

/// 格式不支持。
final class IconFormatUnsupported extends IconAssetError {
  const IconFormatUnsupported() : super('只支持 PNG / JPG / WebP 图片');
}

/// 解不开（损坏、或者根本不是图片）。
final class IconBrokenImage extends IconAssetError {
  const IconBrokenImage() : super('这张图打不开，换一张试试');
}

/// 像素太多。
final class IconTooManyPixels extends IconAssetError {
  const IconTooManyPixels() : super('这张图太大（超过 1600 万像素），先缩小再试');
}

/// 图片规则。
abstract final class IconAssetRules {
  /// 单张图上限：2 MiB（设计稿写明的数值）。
  static const int maxBytes = 2 * 1024 * 1024;

  /// 像素上限：1600 万（设计稿写明的数值）。
  static const int maxPixels = 1600 * 10000;

  /// 缩略图边长：指南 14.3 要求后台生成 256×256 的私有缩略图。
  ///
  /// 顺便去掉 EXIF 等无关元数据 —— 重新编码出来的 PNG 里不会有原始照片
  /// 的位置信息（14.3）。
  static const int thumbnailSize = 256;

  /// 按**文件头**判断格式。
  ///
  /// 不看后缀也不信 MIME：两者都可以对不上内容（指南 4.2.3 是同一条道理）。
  static IconAssetFormat? formatOf(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return IconAssetFormat.png;
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return IconAssetFormat.jpeg;
    }
    // WebP：`RIFF` + 4 字节长度 + `WEBP`。
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return IconAssetFormat.webp;
    }
    return null;
  }

  /// 解码**之前**能做的判断：非空、不超限、格式认识。
  static IconAssetError? validateBytes(Uint8List bytes) {
    if (bytes.isEmpty) return const IconBrokenImage();
    if (bytes.length > maxBytes) return const IconFileTooLarge();
    if (formatOf(bytes) == null) return const IconFormatUnsupported();
    return null;
  }

  /// 解码**之后**能做的判断。
  static IconAssetError? validateDimensions({
    required int width,
    required int height,
  }) {
    if (width <= 0 || height <= 0) return const IconBrokenImage();
    if (width * height > maxPixels) return const IconTooManyPixels();
    return null;
  }

  /// 居中方形裁切的源矩形：`(left, top, side)`。
  ///
  /// 设计稿要的是「居中方形裁切」：取短边作边长，长边两侧各裁掉一半。
  static (int left, int top, int side) squareCrop({
    required int width,
    required int height,
  }) {
    final side = width < height ? width : height;
    return ((width - side) ~/ 2, (height - side) ~/ 2, side);
  }
}
