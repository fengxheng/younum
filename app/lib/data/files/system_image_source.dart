/// 系统图片选择器的接入实现（Android）。
///
/// 复用账单那条通道（`com.younum.app/files`）：选择器的生命周期、
/// 「同时只能有一个请求」、取消与错误码翻译都已经在那里处理过一遍了，
/// 再写一条通道只会多一份要维护的重复逻辑。不同之处只有一个 ——
/// 请求时带上图片类型的过滤。
library;

import 'package:flutter/services.dart';

import '../../domain/repositories/image_file_source.dart';
import '../../domain/repositories/ledger_file_source.dart';
import 'system_file_source.dart';

/// 系统图片选择器。
final class SystemImageSource implements ImageFileSource {
  SystemImageSource({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(SystemFileSource.channelName);

  final MethodChannel _channel;

  @override
  Future<bool> isAvailable() async {
    try {
      final described = await _channel.invokeMapMethod<String, Object?>(
        'describe',
      );
      return described?['supported'] == true &&
          described?['pickerAvailable'] == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<PickOutcome> pickImage() async {
    try {
      final picked = await _channel.invokeMapMethod<String, Object?>(
        'pickDocument',
        <String, Object?>{'mimeType': 'image/*'},
      );
      if (picked == null) return const PickCanceled();

      final raw = picked['bytes'];
      if (raw is! Uint8List || raw.isEmpty) {
        return const PickFailed('没读到这张图的内容，请重新选择一次');
      }
      return DocumentPicked(
        PickedDocument(
          name: (picked['name'] as String?) ?? '未命名图片',
          bytes: raw,
          uri: picked['uri'] as String?,
        ),
      );
    } on MissingPluginException {
      return const PickFailed('这个平台上还不能选择图片');
    } on PlatformException catch (error) {
      return PickFailed(error.message ?? '选择图片时出错了，请再试一次');
    }
  }
}
