import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';

/// 可控的文件来源，给界面与流程测试用。
///
/// 为什么必须有它：真实实现要走系统文件选择器，单元测试里没人能替用户点。
/// 把「选到了什么 / 用户取消 / 失败了」做成可编程的，导入流程的每个分支
/// 才都能被测到。
final class FakeFileSource implements LedgerFileSource {
  FakeFileSource({
    this.available = true,
    this.bytes,
    this.name = '2026-09.csv',
    this.uri = 'content://test/bill.csv',
    this.failure,
    this.cancel = false,
  });

  /// 这台设备上有没有这个能力。
  bool available;

  /// 选文件时返回的内容。
  Uint8List? bytes;

  String name;

  String? uri;

  /// 让 pick / reread 失败。
  PickFailed? failure;

  /// 让 pick / reread 表现为用户取消。
  bool cancel;

  /// 系统分享进来的那一份。
  ///
  /// null 表示**没有**待处理的分享（不是失败）—— 真实实现也是这个语义，
  /// 所以测试里必须能表达「没有」。
  PickOutcome? shared;

  /// 记录调用，供断言。
  final List<String> releasedUris = <String>[];
  int pickCount = 0;
  int rereadCount = 0;

  /// 取走分享的次数。它必须是**一次性**的，否则每次回到前台都会重导一遍。
  int sharedTakeCount = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<PickOutcome> pick() async {
    pickCount++;
    return _outcome();
  }

  @override
  Future<PickOutcome> reread(String uri) async {
    rereadCount++;
    return _outcome();
  }

  @override
  Future<PickOutcome?> takeSharedFile() async {
    sharedTakeCount++;
    final pending = shared;
    // 取走即清：与原生侧一致，同一份分享不会被导第二次。
    shared = null;
    return pending;
  }

  @override
  Future<void> release(String uri) async {
    releasedUris.add(uri);
  }

  PickOutcome _outcome() {
    if (failure != null) return failure!;
    if (cancel) return const PickCanceled();
    final content = bytes;
    if (content == null) return const PickFailed('测试没有提供文件内容');
    return DocumentPicked(PickedDocument(name: name, bytes: content, uri: uri));
  }
}
