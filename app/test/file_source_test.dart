import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/data/files/system_file_source.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';

/// 原生侧错误码 → 用户看得懂的一句话。
///
/// 这些用例跑在纯 Dart 上：用 mock 通道替掉原生实现，
/// 因此**不需要设备**就能把每个失败分支走一遍。
/// 真机上那条通道是否真的在，由 `integration_test` 负责。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final channel = MethodChannel(SystemFileSource.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late SystemFileSource source;

  void respond(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(() {
    calls = <MethodCall>[];
    source = SystemFileSource();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('没有原生实现时', () {
    test('isAvailable 返回 false，而不是抛异常', () async {
      // 桌面 / Web 就是这种情况：通道根本不存在。
      expect(await source.isAvailable(), isFalse);
    });

    test('pick 给出可展示的说明，而不是抛异常', () async {
      final outcome = await source.pick();
      expect(outcome, isA<PickFailed>());
      expect((outcome as PickFailed).message, contains('不能选择'));
      expect(outcome.needsReselect, isFalse);
    });
  });

  group('能力探测', () {
    test('只有 supported 与 pickerAvailable 都为真才算可用', () async {
      respond(
        (call) async => <String, Object?>{
          'supported': true,
          'pickerAvailable': true,
        },
      );
      expect(await source.isAvailable(), isTrue);

      // 有通道但设备上没有能响应「打开文档」的界面 —— 不能算可用，
      // 否则界面会给出一个点了没反应的按钮。
      respond(
        (call) async => <String, Object?>{
          'supported': true,
          'pickerAvailable': false,
        },
      );
      expect(await source.isAvailable(), isFalse);
    });
  });

  group('选择文件', () {
    test('选到文件时带回名字、内容与 URI', () async {
      final bytes = Uint8List.fromList(<int>[
        0xE6,
        0x88,
        0x91,
        0xE7,
        0x9A,
        0x84,
      ]);
      respond(
        (call) async => <String, Object?>{
          'name': '微信支付账单.csv',
          'uri': 'content://downloads/42',
          'sizeBytes': bytes.length,
          'bytes': bytes,
        },
      );

      final outcome = await source.pick();
      expect(outcome, isA<DocumentPicked>());
      final document = (outcome as DocumentPicked).document;
      expect(document.name, '微信支付账单.csv');
      expect(document.bytes, bytes);
      expect(document.uri, 'content://downloads/42');
      expect(document.sizeBytes, 6);
      expect(calls.single.method, 'pickDocument');
    });

    test('用户取消不是错误，返回 PickCanceled', () async {
      respond((call) async => null);

      final outcome = await source.pick();
      expect(outcome, isA<PickCanceled>(), reason: '界面据此安静地回到原样，不弹提示');
    });

    test('内容为空时明确说不算选到了', () async {
      respond(
        (call) async => <String, Object?>{
          'name': 'empty.csv',
          'bytes': Uint8List(0),
        },
      );

      final outcome = await source.pick();
      expect(outcome, isA<PickFailed>());
    });

    test('原生给的名字缺失时也给出一个可用的名字', () async {
      respond(
        (call) async => <String, Object?>{
          'bytes': Uint8List.fromList(<int>[1, 2]),
        },
      );

      final outcome = await source.pick();
      expect((outcome as DocumentPicked).document.name, isNotEmpty);
    });
  });

  group('失败原因翻译', () {
    Future<PickFailed> failedWith(String code, [String? message]) async {
      respond(
        (call) async => throw PlatformException(code: code, message: message),
      );
      final outcome = await source.pick();
      expect(outcome, isA<PickFailed>(), reason: '错误码 $code');
      return outcome as PickFailed;
    }

    test('授权失效时要求用户重新选择', () async {
      final failure = await failedWith('forbidden');
      expect(failure.needsReselect, isTrue);
      expect(
        failure.message,
        contains('重新选择'),
        reason: '文件没坏，只是权限没了 —— 要说清怎么办',
      );
    });

    test('文件过大时用原生给的说明（里面有真实上限）', () async {
      final failure = await failedWith('too_large', '这个文件有 100 MB，超过上限 64 MB');
      expect(failure.message, contains('100 MB'));
      expect(failure.needsReselect, isFalse);
    });

    test('其余错误码都有可展示的说明', () async {
      for (final code in <String>[
        'empty',
        'unreadable',
        'unavailable',
        'busy',
        'detached',
        'something_new',
      ]) {
        final failure = await failedWith(code);
        expect(failure.message, isNotEmpty, reason: '错误码 $code 不能没有说明');
      }
    });

    test('原始 message 为空时不留空文案', () async {
      final failure = await failedWith('unreadable', '');
      expect(failure.message, isNotEmpty);
    });
  });

  group('重新读取之前选过的文件', () {
    test('把 URI 原样交给原生，不自己拼路径', () async {
      respond(
        (call) async => <String, Object?>{
          'name': 'again.csv',
          'uri': 'content://downloads/42',
          'bytes': Uint8List.fromList(<int>[1]),
        },
      );

      final outcome = await source.reread('content://downloads/42');
      expect(outcome, isA<DocumentPicked>());
      expect(calls.single.method, 'readDocument');
      expect(calls.single.arguments, <String, Object?>{
        'uri': 'content://downloads/42',
      });
    });

    test('URI 失效时按「需要重新选择」上报', () async {
      respond(
        (call) async =>
            throw PlatformException(code: 'forbidden', message: '没权限'),
      );

      final outcome = await source.reread('content://downloads/42');
      expect((outcome as PickFailed).needsReselect, isTrue);
    });
  });

  group('释放授权', () {
    test('把 URI 交给原生释放', () async {
      respond((call) async => null);
      await source.release('content://downloads/42');

      expect(calls.single.method, 'releaseDocument');
      expect(calls.single.arguments, <String, Object?>{
        'uri': 'content://downloads/42',
      });
    });

    test('释放失败不抛异常', () async {
      respond((call) async => throw PlatformException(code: 'whatever'));
      // 释放授权失败不影响用户手上的数据，不值得打断他。
      await expectLater(source.release('content://downloads/42'), completes);
    });

    test('没有原生实现时也不抛异常', () async {
      await expectLater(source.release('content://downloads/42'), completes);
    });
  });

  group('不支持该能力的平台', () {
    test('明确说不可用，并给出说明', () async {
      const source = UnsupportedFileSource();
      expect(await source.isAvailable(), isFalse);
      expect(await source.pick(), isA<PickFailed>());
      expect(await source.reread('content://x'), isA<PickFailed>());
      await expectLater(source.release('content://x'), completes);
    });
  });
}
