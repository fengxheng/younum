import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/data/files/system_document_saver.dart';
import 'package:younum/domain/repositories/document_saver.dart';

/// 保存通道：原生错误码 → 用户看得懂的一句话。
///
/// 跑在纯 Dart 上（用 mock 通道替掉原生实现），所以**不需要设备**就能把
/// 每个分支走一遍：取消、写失败、权限失效、太忙、通道不存在。
/// 真机上那条通道是否真的在，由 `integration_test` 与人工核对负责。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final channel = MethodChannel(SystemDocumentSaver.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late SystemDocumentSaver saver;

  final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);

  void respond(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(() {
    calls = <MethodCall>[];
    saver = SystemDocumentSaver();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('没有原生实现时', () {
    test('isAvailable 返回 false，而不是抛异常', () async {
      expect(await saver.isAvailable(), isFalse);
    });

    test('save 给出可展示的说明', () async {
      final outcome = await saver.save(
        fileName: 'a.csv',
        mimeType: 'text/csv',
        bytes: bytes,
      );
      expect(outcome, isA<SaveFailed>());
      expect((outcome as SaveFailed).message, contains('不能保存'));
    });
  });

  group('能力探测', () {
    test('supported 与 saverAvailable 都为真才算可用', () async {
      respond(
        (call) async => <String, Object?>{
          'supported': true,
          'saverAvailable': true,
        },
      );
      expect(await saver.isAvailable(), isTrue);

      respond(
        (call) async => <String, Object?>{
          'supported': true,
          'saverAvailable': false,
        },
      );
      expect(await saver.isAvailable(), isFalse);
    });
  });

  group('保存', () {
    test('成功时带上文件名，并且真的把字节递过去了', () async {
      respond(
        (call) async => <String, Object?>{
          'uri': 'content://downloads/1',
          'name': '有数_2026-09.csv',
          'sizeBytes': 4,
        },
      );

      final outcome = await saver.save(
        fileName: '有数_2026-09.csv',
        mimeType: 'text/csv',
        bytes: bytes,
      );

      expect(outcome, isA<DocumentSaved>());
      final saved = outcome as DocumentSaved;
      expect(saved.name, '有数_2026-09.csv');
      expect(saved.uri, 'content://downloads/1');

      expect(calls, hasLength(1));
      expect(calls.single.method, 'saveDocument');
      expect(calls.single.arguments['fileName'], '有数_2026-09.csv');
      expect(calls.single.arguments['mimeType'], 'text/csv');
      expect(calls.single.arguments['bytes'], bytes);
    });

    test('用户取消是「取消」，不是失败', () async {
      respond((call) async => null);

      final outcome = await saver.save(
        fileName: 'a.csv',
        mimeType: 'text/csv',
        bytes: bytes,
      );
      expect(outcome, isA<SaveCanceled>());
    });

    test('写不进去时如实说明，不说「已保存」', () async {
      respond(
        (call) async => throw PlatformException(
          code: 'unwritable',
          message: '这个位置写不进去，请换一个位置',
        ),
      );

      final outcome = await saver.save(
        fileName: 'a.csv',
        mimeType: 'text/csv',
        bytes: bytes,
      );
      expect(outcome, isA<SaveFailed>());
      expect((outcome as SaveFailed).message, contains('写不进去'));
    });

    test('每个原生错误码都有对应说法，不会漏成英文异常', () async {
      for (final code in <String>[
        'unwritable',
        'too_large',
        'unavailable',
        'busy',
        'detached',
        'bad_arguments',
        'unknown_code',
      ]) {
        respond((call) async => throw PlatformException(code: code));
        final outcome = await saver.save(
          fileName: 'a.csv',
          mimeType: 'text/csv',
          bytes: bytes,
        );
        expect(outcome, isA<SaveFailed>(), reason: code);
        expect((outcome as SaveFailed).message, isNotEmpty, reason: code);
        expect(outcome.message, isNot(contains('Exception')), reason: code);
      }
    });

    test('空内容不发给原生', () async {
      final outcome = await saver.save(
        fileName: 'a.csv',
        mimeType: 'text/csv',
        bytes: Uint8List(0),
      );
      expect(outcome, isA<SaveFailed>());
      expect(calls, isEmpty, reason: '没必要为空的导出物弹系统界面');
    });
  });

  group('不支持的实现', () {
    test('给出可读的中文提示', () async {
      const fallback = UnsupportedDocumentSaver();
      expect(await fallback.isAvailable(), isFalse);
      final outcome = await fallback.save(
        fileName: 'a.csv',
        mimeType: 'text/csv',
        bytes: bytes,
      );
      expect(outcome, isA<SaveFailed>());
      expect((outcome as SaveFailed).message, contains('不能保存'));
    });
  });
}
