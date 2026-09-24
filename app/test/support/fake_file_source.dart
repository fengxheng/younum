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

  /// 记录调用，供断言。
  final List<String> releasedUris = <String>[];
  int pickCount = 0;
  int rereadCount = 0;

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
