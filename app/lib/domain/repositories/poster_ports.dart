/// 月报海报的渲染端口。
///
/// 渲染要用引擎能力，没法纯函数化，所以接口留在领域层、实现放在数据层
/// （和分类图标那套 `IconThumbnailMaker` 一样的分工）：
/// 领域层只描述「要画什么」（`SharePosterSpec`），数据层负责真画出来。
///
/// 这样界面在测试里可以换成假实现 —— 真实编解码必须在引擎里跑，
/// 放进 widget 测试会和 `pumpAndSettle` 互相等待（图标那块踩过这个坑）。
library;

import 'dart:typed_data';

import '../rules/share_poster_rules.dart';

/// 把海报内容渲染成 PNG 字节。
abstract interface class PosterMaker {
  /// [scale] 是相对设计尺寸（750×1000）的放大倍数，导出用 2 倍。
  Future<PosterRenderResult> render(
    SharePosterSpec spec, {
    double scale = posterExportScale,
  });
}

/// 导出用的放大倍数：750×1000 的设计尺寸变成 1500×2000 的 PNG。
const double posterExportScale = 2;

/// 渲染结果。
sealed class PosterRenderResult {
  const PosterRenderResult();
}

/// 渲染成功。
final class PosterRendered extends PosterRenderResult {
  const PosterRendered(this.bytes, {required this.width, required this.height});

  final Uint8List bytes;

  /// PNG 的像素尺寸（不是设计尺寸）。
  final int width;
  final int height;
}

/// 渲染失败。[message] 是可以直接给用户看的中文。
final class PosterRenderFailed extends PosterRenderResult {
  const PosterRenderFailed(this.message);

  final String message;

  @override
  String toString() => 'PosterRenderFailed($message)';
}

/// 当前环境不支持渲染（例如纯逻辑测试里）。
final class UnsupportedPosterMaker implements PosterMaker {
  const UnsupportedPosterMaker();

  @override
  Future<PosterRenderResult> render(
    SharePosterSpec spec, {
    double scale = posterExportScale,
  }) async => const PosterRenderFailed('当前环境不支持生成图片');
}
