/// 系统「创建文档」流程的接入实现（Android）。
///
/// 和文件选择一样走 `com.younum.app/files` 这条自写的平台通道 ——
/// 原生侧代码在 `android/app/src/main/kotlin/com/younum/app/MainActivity.kt`。
///
/// 这一层只做一件事：把原生返回的 map 与错误码翻译成 [SaveOutcome]，
/// 让界面拿到的是可以**直接展示**的中文说明，而不是 `PlatformException`。
library;

import 'package:flutter/services.dart';

import '../../domain/repositories/document_saver.dart';

/// 系统文件保存。
final class SystemDocumentSaver implements DocumentSaver {
  SystemDocumentSaver({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  /// 与 MainActivity 里注册的名字必须一致。
  static const String channelName = 'com.younum.app/files';

  final MethodChannel _channel;

  @override
  Future<bool> isAvailable() async {
    try {
      final described = await _channel.invokeMapMethod<String, Object?>(
        'describe',
      );
      return described?['supported'] == true &&
          described?['saverAvailable'] == true;
    } on MissingPluginException {
      // 桌面或 Web：通道不存在，不是故障，就是没这个能力。
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<SaveOutcome> save({
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    if (bytes.isEmpty) return const SaveFailed('没有可保存的内容');
    try {
      // 原生侧返回 null 表示用户取消。
      final saved = await _channel.invokeMapMethod<String, Object?>(
        'saveDocument',
        <String, Object?>{
          'fileName': fileName,
          'mimeType': mimeType,
          'bytes': bytes,
        },
      );
      if (saved == null) return const SaveCanceled();
      return DocumentSaved(
        name: (saved['name'] as String?) ?? fileName,
        uri: saved['uri'] as String?,
      );
    } on MissingPluginException {
      return const SaveFailed('这个平台上还不能保存文件');
    } on PlatformException catch (error) {
      return _failureOf(error);
    }
  }

  /// 把原生错误码翻译成用户能看懂的一句话。
  SaveFailed _failureOf(PlatformException error) {
    final detail = error.message ?? '';
    return switch (error.code) {
      'unwritable' => SaveFailed(detail.isEmpty ? '写不进去这个位置，请换一个位置' : detail),
      'too_large' => SaveFailed(detail.isEmpty ? '导出文件太大了，暂时保存不了' : detail),
      'unavailable' => SaveFailed(detail.isEmpty ? '这台设备上没有可用的文件保存界面' : detail),
      'busy' => const SaveFailed('正在保存上一个文件，请稍候'),
      'detached' => const SaveFailed('界面已经被关掉了，请重新保存一次'),
      'bad_arguments' => SaveFailed(detail.isEmpty ? '没有可保存的内容' : detail),
      _ => SaveFailed(detail.isEmpty ? '保存文件时出错了' : detail),
    };
  }
}
