/// 把生成好的文件交给系统保存的端口（指南 8.1）。
///
/// 指南要求「保存文件使用系统创建文档流程」，并且**不向系统暴露应用私有的
/// 绝对路径** —— 所以这里的接口收的是**字节**，不是路径：
/// 原生侧走 `ACTION_CREATE_DOCUMENT`，由用户在系统界面里挑位置。
///
/// 结果分三态，因为「用户取消」和「写失败」对界面是两件完全不同的事：
/// 取消要安静地回到原样，失败必须说清楚为什么。
library;

import 'dart:typed_data';

/// 系统「创建文档」流程。
abstract interface class DocumentSaver {
  /// 这个平台有没有可用的保存界面。没有就如实把按钮置灰，不做假成功。
  Future<bool> isAvailable();

  /// 保存一份文件。[fileName] 只是建议名，用户可以改。
  Future<SaveOutcome> save({
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
  });
}

/// 保存结果。
sealed class SaveOutcome {
  const SaveOutcome();
}

/// 保存成功。
final class DocumentSaved extends SaveOutcome {
  const DocumentSaved({required this.name, this.uri});

  /// 用户最终用的文件名（可能被改过）。
  final String name;

  /// 系统给的 `content://` URI，仅用于记录，不展示给用户。
  final String? uri;

  @override
  String toString() => 'DocumentSaved($name)';
}

/// 用户取消。不是错误。
final class SaveCanceled extends SaveOutcome {
  const SaveCanceled();
}

/// 保存失败。[message] 可以直接给用户看。
final class SaveFailed extends SaveOutcome {
  const SaveFailed(this.message);

  final String message;

  @override
  String toString() => 'SaveFailed($message)';
}

/// 当前环境不支持保存（桌面、Web、纯逻辑测试）。
final class UnsupportedDocumentSaver implements DocumentSaver {
  const UnsupportedDocumentSaver();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<SaveOutcome> save({
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
  }) async => const SaveFailed('这个平台上还不能保存文件');
}
