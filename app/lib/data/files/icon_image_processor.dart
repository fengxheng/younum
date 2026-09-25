/// 把用户选的图片变成分类图标缩略图（指南 14.3 / 14.4）。
///
/// 只用 `dart:ui`，**不引任何图片处理插件**：需要的只有「解码 → 居中方形
/// 裁切 → 缩放到 256×256 → 重新编码成 PNG」这四步 —— Flutter 引擎本来就
/// 带得动。重新编码还有一个附带好处：原始照片里的 EXIF（拍摄位置等）
/// 不会跟着进到我们自己的资源里（14.3 要求去掉无关元数据）。
///
/// 放在数据层而不是规则层：它要用到引擎能力，没法纯函数化。
/// 边界判断在 `IconAssetRules` 里，那部分能穷举测试。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../domain/repositories/icon_asset_ports.dart';
import '../../domain/rules/icon_asset_rules.dart';

/// 图片处理。用引擎能力实现 [IconThumbnailMaker]。
final class IconImageProcessor implements IconThumbnailMaker {
  const IconImageProcessor();

  @override
  Future<IconThumbnailResult> thumbnail(
    Uint8List bytes, {
    int size = IconAssetRules.thumbnailSize,
  }) async {
    final bytesError = IconAssetRules.validateBytes(bytes);
    if (bytesError != null) return IconThumbnailFailed(bytesError);

    ui.Codec codec;
    try {
      codec = await ui.instantiateImageCodec(bytes);
    } catch (_) {
      // 文件头对、里面是坏的（截断、伪造）：到这里才看得出来。
      return const IconThumbnailFailed(IconBrokenImage());
    }

    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final dimensionsError = IconAssetRules.validateDimensions(
        width: image.width,
        height: image.height,
      );
      if (dimensionsError != null) {
        image.dispose();
        return IconThumbnailFailed(dimensionsError);
      }

      final (left, top, side) = IconAssetRules.squareCrop(
        width: image.width,
        height: image.height,
      );

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        image,
        ui.Rect.fromLTWH(
          left.toDouble(),
          top.toDouble(),
          side.toDouble(),
          side.toDouble(),
        ),
        ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      final picture = recorder.endRecording();
      final scaled = await picture.toImage(size, size);
      final data = await scaled.toByteData(format: ui.ImageByteFormat.png);

      picture.dispose();
      scaled.dispose();
      image.dispose();

      if (data == null) return const IconThumbnailFailed(IconBrokenImage());
      return IconThumbnailReady(
        data.buffer.asUint8List(),
        width: size,
        height: size,
      );
    } catch (_) {
      return const IconThumbnailFailed(IconBrokenImage());
    } finally {
      codec.dispose();
    }
  }
}
