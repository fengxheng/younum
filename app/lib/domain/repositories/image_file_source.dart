/// 「让用户选一张图片」这个平台能力（分类图标用，指南 14.4）。
///
/// 与账单那边的 [LedgerFileSource] 分开是有意的：
///
/// * 过滤器不同 —— 图片要的是 `image/*`，账单要的是任意类型（微信账单
///   有时是 `.xlsx` 有时是 `.csv`，还得允许用户自己选到）；
/// * 失败的说法不同 —— 选账单失败要说「重新选一份账单」，
///   选图失败要说「换一张图」，把两者混在一起只会让文案变得含糊；
/// * 生命周期不同 —— 账单文件读完就丢，图片要复制成应用自己的资源
///   （14.4.2），后续的落盘与清理完全是另一套（见 `icon_asset_store.dart`）。
///
/// 返回值复用 [PickOutcome]：取消不是错误、失败要能直接给用户看，
/// 这两条与选文件是同一套规矩。
library;

import 'ledger_file_source.dart';

/// 选图片的来源端口。
abstract interface class ImageFileSource {
  /// 这台设备上能不能选图片。
  Future<bool> isAvailable();

  /// 打开系统图片选择器。
  Future<PickOutcome> pickImage();
}

/// 平台上没有这个能力时的实现（桌面、某些测试环境）。
final class UnsupportedImageSource implements ImageFileSource {
  const UnsupportedImageSource();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<PickOutcome> pickImage() async =>
      const PickFailed('这个平台上还不能选择图片');
}
