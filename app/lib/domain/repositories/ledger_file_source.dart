/// 「让用户选一份账单文件」这个平台能力。
///
/// 单独抽成端口的原因：它**必然**跟平台绑定（Android 是系统文件选择器 +
/// `content://`，桌面测试环境什么都没有），而导入流程本身是纯逻辑。
/// 抽出来之后，整理/导入的编排与界面都能用假实现跑测试。
///
/// 实现指南 4.2 的三条要求体现在这个接口上：
///
/// * 只认 [PickedDocument.uri] 这个系统授权，**不去猜真实磁盘路径**；
/// * 允许[重新读][LedgerFileSource.reread]一份之前选过的文件 —— URI 可能
///   在系统回收授权之后失效，所以要能明确报错让用户重选，而不是默默失败；
/// * 用户丢弃批次时[释放授权][LedgerFileSource.release]，不长期占着权限。
library;

import 'dart:typed_data';

/// 用户选中的文件。
final class PickedDocument {
  const PickedDocument({required this.name, required this.bytes, this.uri});

  /// 展示给用户看的文件名（来自 provider，不是我们自己猜的）。
  final String name;

  /// 已经读进内存的内容。
  ///
  /// 一次性读进内存而不是留个流：账单文件是 MB 级以下的小文件，
  /// 而解析需要完整内容才能判编码（先读一段再判会读错）。
  final Uint8List bytes;

  /// 系统给的 `content://` URI。测试环境的假实现可以是 null。
  final String? uri;

  int get sizeBytes => bytes.length;

  @override
  String toString() => 'PickedDocument($name, $sizeBytes 字节)';
}

/// 选择文件的结果。
sealed class PickOutcome {
  const PickOutcome();
}

/// 选到了。
final class DocumentPicked extends PickOutcome {
  const DocumentPicked(this.document);

  final PickedDocument document;
}

/// 用户取消了。**不是错误**：界面应该安静地回到原样，不弹提示。
final class PickCanceled extends PickOutcome {
  const PickCanceled();
}

/// 选不了，需要告诉用户为什么。
final class PickFailed extends PickOutcome {
  const PickFailed(this.message, {this.needsReselect = false});

  /// 直接给用户看的原因。
  final String message;

  /// true 表示「文件还在，但读取授权没了」—— 界面应该给一个
  /// 「重新选择」的入口，而不是让用户以为这份账单坏了。
  final bool needsReselect;

  @override
  String toString() => 'PickFailed($message, 需重选=$needsReselect)';
}

/// 文件来源端口。
abstract interface class LedgerFileSource {
  /// 这台设备上能不能选文件。
  ///
  /// 用来决定「选择文件」按钮是可用还是显灰，而不是点了才发现不行。
  Future<bool> isAvailable();

  /// 打开系统文件选择器。
  Future<PickOutcome> pick();

  /// 重新读一份之前选过的文件（导入历史里「重新解析」用）。
  ///
  /// URI 失效时返回 [PickFailed] 且 `needsReselect` 为真。
  Future<PickOutcome> reread(String uri);

  /// 系统「分享」进来、还没被处理掉的那份文件。
  ///
  /// 返回 **null 表示没有这件事**，而不是失败：启动时与每次回到前台都会问
  /// 一次，绝大多数时候答案就是「没有」。真的读不出来（太大、权限失效、文件被
  /// 删了）才回 [PickFailed]，让界面能如实说清。
  ///
  /// 这是「一次性」的：取走之后同一份分享不会再被取到第二次，
  /// 否则用户每次切回应用都会重新导一遍同一份文件。
  Future<PickOutcome?> takeSharedFile();

  /// 释放读取授权。丢弃批次时调用。
  ///
  /// 实现必须是**幂等**的：重复释放、从未授权过都不算失败。
  Future<void> release(String uri);
}

/// 平台上没有这个能力时的实现（桌面、单元测试）。
///
/// 明确返回「不支持」，而不是抛异常 —— 界面据此把入口显灰，
/// 不会留下一个点了没反应的按钮（指南 9.10）。
final class UnsupportedFileSource implements LedgerFileSource {
  const UnsupportedFileSource();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<PickOutcome> pick() async => const PickFailed('这个平台上还不能选择本地文件');

  @override
  Future<PickOutcome> reread(String uri) async =>
      const PickFailed('这个平台上还不能选择本地文件');

  /// 这个平台不会被分享唤起，所以永远没有待处理的分享。
  ///
  /// 注意是 **null**（没有）而不是 [PickFailed]（失败）：桌面与测试环境
  /// 每次都回「失败」的话，界面上会莫名其妙地反复报错。
  @override
  Future<PickOutcome?> takeSharedFile() async => null;

  @override
  Future<void> release(String uri) async {}
}
