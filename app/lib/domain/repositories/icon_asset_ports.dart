/// 分类图片图标用到的两个平台端口（指南 14.4）。
///
/// 放在这一层是为了让仓库层只依赖**接口**：处理图片要用引擎、落文件要用
/// 磁盘，两者都是平台相关的能力，而「保存分类图标」这件事的编排顺序
/// （先处理 → 写文件 → 再提交数据库引用）属于业务规则。
library;

import 'dart:typed_data';

import '../rules/icon_asset_rules.dart';

/// 分类图标的文件柜。
abstract interface class IconAssetStore {
  /// 这台设备上能不能落文件（桌面测试环境给的是假实现）。
  Future<bool> isAvailable();

  /// 写一张缩略图，返回应用私有目录下的**相对**路径。
  ///
  /// 文件名由 `contentHash` 决定：同一张图重复保存只会有一份文件。
  /// 实现必须是「先写临时文件再改名」，这样中途失败不会留下半个文件
  /// 冒充有效资源。
  Future<String> write({
    required String contentHash,
    required Uint8List bytes,
  });

  /// 相对路径对应的绝对路径（渲染时用）。
  String absolutePath(String relativePath);

  /// 文件在不在（渲染前用它决定要不要回退默认图标）。
  Future<bool> exists(String relativePath);

  /// 删掉一份文件。已经被删掉的、从来没写过的都不算失败。
  Future<void> delete(String relativePath);

  /// 清空整个目录（「清除本地数据」用，指南 14.4.5）。
  Future<void> clearAll();
}

/// 把用户选的图片做成缩略图的能力。
abstract interface class IconThumbnailMaker {
  /// 解码、居中方形裁切、缩放，再编码成 PNG。
  Future<IconThumbnailResult> thumbnail(
    Uint8List bytes, {
    int size = IconAssetRules.thumbnailSize,
  });
}

/// 缩略图结果。
sealed class IconThumbnailResult {
  const IconThumbnailResult();
}

final class IconThumbnailReady extends IconThumbnailResult {
  const IconThumbnailReady(
    this.bytes, {
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;
}

final class IconThumbnailFailed extends IconThumbnailResult {
  const IconThumbnailFailed(this.error);

  final IconAssetError error;
}

/// 落不了文件的实现（桌面、单元测试）。
final class UnsupportedIconAssetStore implements IconAssetStore {
  const UnsupportedIconAssetStore();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<String> write({
    required String contentHash,
    required Uint8List bytes,
  }) async => throw StateError('这个平台上还不能保存图片资源');

  @override
  String absolutePath(String relativePath) => relativePath;

  @override
  Future<bool> exists(String relativePath) async => false;

  @override
  Future<void> delete(String relativePath) async {}

  @override
  Future<void> clearAll() async {}
}

/// 做不了缩略图的实现。
///
/// 正常路径走不到它：仓库层先看 `IconAssetStore.isAvailable()`，
/// 不可用时直接给用户一句「这个平台上还不能保存图片图标」。
final class UnsupportedThumbnailMaker implements IconThumbnailMaker {
  const UnsupportedThumbnailMaker();

  @override
  Future<IconThumbnailResult> thumbnail(
    Uint8List bytes, {
    int size = IconAssetRules.thumbnailSize,
  }) async => const IconThumbnailFailed(IconBrokenImage());
}
