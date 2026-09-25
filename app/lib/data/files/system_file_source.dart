/// 系统文件选择器的接入实现（Android）。
///
/// 走 `com.younum.app/files` 这条自写的平台通道 —— 原生侧代码在
/// `android/app/src/main/kotlin/com/younum/app/MainActivity.kt`，
/// 那里写清了为什么不用第三方插件。
///
/// 这一层只做一件事：把原生返回的 map 与错误码翻译成
/// [PickOutcome]，好让界面拿到的是可以**直接展示给用户**的说明，
/// 而不是一串 `PlatformException`。
library;

import 'package:flutter/services.dart';

import '../../domain/repositories/ledger_file_source.dart';

/// 系统文件选择器。
final class SystemFileSource implements LedgerFileSource {
  SystemFileSource({MethodChannel? channel})
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
          described?['pickerAvailable'] == true;
    } on MissingPluginException {
      // 桌面或 Web：通道不存在，不是故障，就是没这个能力。
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<PickOutcome> pick() async {
    try {
      // 原生侧返回 null 表示用户取消。
      final picked = await _channel.invokeMapMethod<String, Object?>(
        'pickDocument',
      );
      if (picked == null) return const PickCanceled();
      return _outcomeOf(picked);
    } on MissingPluginException {
      return const PickFailed('这个平台上还不能选择本地文件');
    } on PlatformException catch (error) {
      return _failureOf(error);
    }
  }

  @override
  Future<PickOutcome> reread(String uri) async {
    try {
      final picked = await _channel.invokeMapMethod<String, Object?>(
        'readDocument',
        <String, Object?>{'uri': uri},
      );
      if (picked == null) return const PickCanceled();
      return _outcomeOf(picked);
    } on MissingPluginException {
      return const PickFailed('这个平台上还不能选择本地文件');
    } on PlatformException catch (error) {
      return _failureOf(error);
    }
  }

  @override
  Future<PickOutcome?> takeSharedFile() async {
    try {
      // 原生侧返回 null 表示「没有待处理的分享」，不是失败。
      final shared = await _channel.invokeMapMethod<String, Object?>(
        'consumeSharedFile',
      );
      if (shared == null) return null;
      return _outcomeOf(shared);
    } on MissingPluginException {
      // 桌面或 Web：没有这条通道，也就是没有分享进来的文件。
      return null;
    } on PlatformException catch (error) {
      return _failureOf(error);
    }
  }

  @override
  Future<void> release(String uri) async {
    try {
      await _channel.invokeMethod<void>('releaseDocument', <String, Object?>{
        'uri': uri,
      });
    } on MissingPluginException {
      // 没有这个能力就没什么可释放的。
    } on PlatformException {
      // 释放授权失败不影响用户手上的数据，不值得打断他。
    }
  }

  PickOutcome _outcomeOf(Map<String, Object?> picked) {
    final raw = picked['bytes'];
    if (raw is! Uint8List || raw.isEmpty) {
      return const PickFailed('没读到文件内容，请重新选择一次');
    }
    return DocumentPicked(
      PickedDocument(
        name: (picked['name'] as String?) ?? 'bill.csv',
        bytes: raw,
        uri: picked['uri'] as String?,
      ),
    );
  }

  /// 把原生错误码翻译成用户能看懂的一句话。
  PickFailure _failureOf(PlatformException error) {
    final detail = error.message ?? '';
    return switch (error.code) {
      'forbidden' => const PickFailed(
        '这个文件的读取权限已经失效，请重新选择一次',
        needsReselect: true,
      ),
      'too_large' => PickFailed(detail.isEmpty ? '这个文件太大了，暂时读不了' : detail),
      'empty' => const PickFailed('这个文件是空的'),
      'unreadable' => PickFailed(detail.isEmpty ? '读不了这个文件' : detail),
      'unavailable' => PickFailed(detail.isEmpty ? '这台设备上没有可用的文件选择器' : detail),
      'busy' => const PickFailed('正在选择文件，请稍候'),
      'detached' => const PickFailed('界面已经被关掉了，请重新选择一次'),
      _ => PickFailed(detail.isEmpty ? '选择文件时出错了' : detail),
    };
  }
}

/// [PickFailed] 的别名，只是为了让 [_failureOf] 的返回类型读起来更直白。
typedef PickFailure = PickFailed;
