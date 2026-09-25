import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/data/files/icon_asset_store.dart';
import 'package:younum/data/files/icon_image_processor.dart';
import 'package:younum/domain/repositories/icon_asset_ports.dart';
import 'package:younum/domain/rules/icon_asset_rules.dart';

/// 分类图片图标的处理与落盘（指南 14.3 / 14.4）。
///
/// 这里用**真的**图片字节（引擎现场生成一张 PNG），而不是手搓文件头：
/// 「居中裁成方形」「缩放到 256×256」这类事只有走一遍解码才验得到。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 生成一张指定尺寸的纯色 PNG。
  Future<Uint8List> makePng({
    required int width,
    required int height,
    Color color = const Color(0xFF3366CC),
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = color,
    );
    final image = await recorder.endRecording().toImage(width, height);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  group('缩略图处理', () {
    test('横图裁成 256×256 的 PNG', () async {
      final source = await makePng(width: 400, height: 100);

      final result = await const IconImageProcessor().thumbnail(source);

      expect(result, isA<IconThumbnailReady>(), reason: '$result');
      final ready = result as IconThumbnailReady;
      expect(ready.width, IconAssetRules.thumbnailSize);
      expect(ready.height, IconAssetRules.thumbnailSize);

      // 裁切是真的发生了：输出是正方形，而且能重新解码。
      final codec = await ui.instantiateImageCodec(ready.bytes);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, ready.width);
      expect(frame.image.height, ready.height);
      frame.image.dispose();
      codec.dispose();
    });

    test('超过 2 MB 的图在解码之前就被拒（省得白白解码）', () async {
      final tooBig = Uint8List(IconAssetRules.maxBytes + 1);
      tooBig[0] = 0x89;
      tooBig[1] = 0x50;
      tooBig[2] = 0x4E;
      tooBig[3] = 0x47;

      final result = await const IconImageProcessor().thumbnail(tooBig);

      expect(result, isA<IconThumbnailFailed>());
      expect(
        (result as IconThumbnailFailed).error,
        isA<IconFileTooLarge>(),
      );
    });

    test('文件头对但内容是坏的：说打不开，而不是崩', () async {
      final broken = Uint8List.fromList(<int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG 头
        0x00, 0x01, 0x02, 0x03, // 后面是垃圾
      ]);

      final result = await const IconImageProcessor().thumbnail(broken);

      expect(result, isA<IconThumbnailFailed>());
      expect((result as IconThumbnailFailed).error, isA<IconBrokenImage>());
    });
  });

  group('文件柜', () {
    late Directory temp;
    late FileIconAssetStore store;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('younum_icons_');
      store = FileIconAssetStore(directoryOf: () async => temp.path);
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('写进去能读到，相对路径带哈希与子目录', () async {
      final bytes = await makePng(width: 64, height: 64);
      final hash = IconAssetRules.contentHash(bytes);

      final relative = await store.write(contentHash: hash, bytes: bytes);

      expect(relative, '${FileIconAssetStore.subDirectory}/$hash.png');
      expect(await store.exists(relative), isTrue);
      expect(
        await File(store.absolutePath(relative)).length(),
        bytes.length,
        reason: '落盘的应当就是那一段字节',
      );
    });

    test('同一哈希写两次不会覆盖，也不会报错', () async {
      final bytes = await makePng(width: 32, height: 32);
      final hash = IconAssetRules.contentHash(bytes);

      final first = await store.write(contentHash: hash, bytes: bytes);
      final second = await store.write(contentHash: hash, bytes: bytes);

      expect(second, first);
      expect(await store.exists(first), isTrue);
    });

    test('删除与清空都不留残骸', () async {
      final bytes = await makePng(width: 16, height: 16);
      final relative = await store.write(
        contentHash: IconAssetRules.contentHash(bytes),
        bytes: bytes,
      );

      await store.delete(relative);
      expect(await store.exists(relative), isFalse);
      // 重复删除不算失败。
      await store.delete(relative);

      await store.write(
        contentHash: IconAssetRules.contentHash(bytes),
        bytes: bytes,
      );
      await store.clearAll();
      expect(await store.exists(relative), isFalse);
    });

    test('清空之后还能继续写（目录会重建）', () async {
      final bytes = await makePng(width: 16, height: 16);
      final hash = IconAssetRules.contentHash(bytes);

      await store.clearAll();
      final relative = await store.write(contentHash: hash, bytes: bytes);

      expect(await store.exists(relative), isTrue);
    });

    test('路径穿越被挡掉', () {
      final path = store.absolutePath('../../etc/passwd');
      expect(path.contains('..'), isFalse);
    });
  });
}
