import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:younum/data/files/icon_asset_store.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/category.dart';
import 'package:younum/domain/repositories/icon_asset_ports.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/domain/rules/icon_asset_rules.dart';

/// 换图片图标这条**编排**（指南 14.3 / 14.4）。
///
/// 真实的处理链路由 `icon_asset_store_test.dart` 验（真的解码与裁切），
/// 界面上「选图 → 预览 → 保存」那条路径在 widget 测试里会卡在图片解码上
/// （必须 `runAsync` 才推进），所以它留作人工检查项（见 `MANUAL_CHECKS.md`）。
/// 这里验的是中间那层：顺序、失败不动旧图标、旧资源清理。
void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late Directory directory;
  late FileIconAssetStore files;

  const int ledgerId = DemoLedgerSeed.demoLedgerId;

  /// 假的缩略图实现：只做「已经处理好」的那一步。
  final thumbnailBytes = Uint8List.fromList(
    List<int>.generate(64, (index) => index),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('younum_icon_');
    files = FileIconAssetStore(directoryOf: () async => directory.path);
    store = InMemoryLedgerStore();
    repository = LedgerRepository(
      store,
      thumbnails: _FakeThumbnails(thumbnailBytes),
      iconFiles: files,
    );
    await repository.initialize();
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<Category> categoryNamed(String name) async {
    final categories = await repository.categories(ledgerId: ledgerId);
    return categories.firstWhere((category) => category.name == name);
  }

  test('挂上图片：分类指向资源，文件真的落盘', () async {
    final target = await categoryNamed('餐饮');

    final result = await repository.setCategoryImage(
      ledgerId: ledgerId,
      categoryId: target.id,
      bytes: thumbnailBytes,
    );

    expect(result, isA<CategorySaved>(), reason: '$result');
    final saved = (result as CategorySaved).category;
    expect(saved.iconType, CategoryIconType.image);
    expect(saved.name, target.name, reason: '只换图标，名字与 ID 不动');
    expect(saved.id, target.id);

    final assets = await repository.iconAssets();
    expect(assets, hasLength(1));
    expect(saved.iconKey, '${assets.single.id}');
    expect(await files.exists(assets.single.relativePath), isTrue);
    expect(assets.single.byteSize, thumbnailBytes.length);
  });

  test('换成另一张图：旧资源与旧文件一起清掉', () async {
    final target = await categoryNamed('餐饮');
    await repository.setCategoryImage(
      ledgerId: ledgerId,
      categoryId: target.id,
      bytes: thumbnailBytes,
    );
    final first = (await repository.iconAssets()).single;

    final other = Uint8List.fromList(
      List<int>.generate(64, (index) => index + 1),
    );
    final result = await repository.setCategoryImage(
      ledgerId: ledgerId,
      categoryId: target.id,
      bytes: other,
    );

    expect(result, isA<CategorySaved>(), reason: '$result');
    final assets = await repository.iconAssets();
    expect(assets, hasLength(1), reason: '旧资源已经没人引用');
    expect(assets.single.id, isNot(first.id));
    expect(
      await files.exists(first.relativePath),
      isFalse,
      reason: '旧文件也要删掉，否则私有目录会一直涨',
    );
  });

  test('同一张图再选一次：不新增资源，也不删文件', () async {
    final target = await categoryNamed('餐饮');
    await repository.setCategoryImage(
      ledgerId: ledgerId,
      categoryId: target.id,
      bytes: thumbnailBytes,
    );
    final first = (await repository.iconAssets()).single;

    await repository.setCategoryImage(
      ledgerId: ledgerId,
      categoryId: target.id,
      bytes: thumbnailBytes,
    );

    final assets = await repository.iconAssets();
    expect(assets, hasLength(1));
    expect(assets.single.id, first.id);
    expect(
      await files.exists(first.relativePath),
      isTrue,
      reason: '正在用的资源不能被当成旧资源删掉',
    );
  });

  test('恢复默认图标：回到出厂值，资源与文件都清掉', () async {
    final target = await categoryNamed('餐饮');
    await repository.setCategoryImage(
      ledgerId: ledgerId,
      categoryId: target.id,
      bytes: thumbnailBytes,
    );
    final asset = (await repository.iconAssets()).single;

    final result = await repository.clearCategoryImage(
      ledgerId: ledgerId,
      categoryId: target.id,
      iconKey: 'food',
    );

    expect(result, isA<CategorySaved>(), reason: '$result');
    final restored = (result as CategorySaved).category;
    expect(restored.iconType, CategoryIconType.builtin);
    expect(restored.iconKey, 'food');
    expect(await repository.iconAssets(), isEmpty);
    expect(await files.exists(asset.relativePath), isFalse);
  });

  test('两个分类用同一张图：一个人换掉时不能删到另一个人的文件', () async {
    final food = await categoryNamed('餐饮');
    final shopping = await categoryNamed('购物');
    await repository.setCategoryImage(
      ledgerId: ledgerId,
      categoryId: food.id,
      bytes: thumbnailBytes,
    );
    await repository.setCategoryImage(
      ledgerId: ledgerId,
      categoryId: shopping.id,
      bytes: thumbnailBytes,
    );
    final shared = (await repository.iconAssets()).single;

    // 餐饮换成别的图：购物还指着同一份资源，不能删。
    final other = Uint8List.fromList(
      List<int>.generate(64, (index) => index + 7),
    );
    await repository.setCategoryImage(
      ledgerId: ledgerId,
      categoryId: food.id,
      bytes: other,
    );

    expect(
      await files.exists(shared.relativePath),
      isTrue,
      reason: '还有别的分类在用它 —— 指南 14.4.4：只清理已无引用的资源',
    );
    expect((await categoryNamed('购物')).iconKey, '${shared.id}');
  });

  test('平台上不能存文件时：明确拒绝，且旧图标不动', () async {
    final offline = LedgerRepository(
      store,
      thumbnails: _FakeThumbnails(thumbnailBytes),
      // 默认就是「不支持」的实现。
    );
    final target = await categoryNamed('餐饮');

    final result = await offline.setCategoryImage(
      ledgerId: ledgerId,
      categoryId: target.id,
      bytes: thumbnailBytes,
    );

    expect(result, isA<CategoryRejected>());
    expect((result as CategoryRejected).message, contains('还不能保存图片'));
    expect((await categoryNamed('餐饮')).iconType, CategoryIconType.builtin);
  });
}

/// 假的缩略图实现：把输入原样当输出，避免测试里真的解码。
///
/// **透传**而不是固定返回一份字节：测试要区分「同一张图」与「另一张图」，
/// 固定返回会让两次保存变成同一份内容，哈希一样、资源复用，
/// 于是「旧资源被清理」这条根本验不到。
final class _FakeThumbnails implements IconThumbnailMaker {
  const _FakeThumbnails(this.unused);

  /// 保留这个参数只是为了在用例里显式说明「原始图片是什么」。
  final Uint8List unused;

  @override
  Future<IconThumbnailResult> thumbnail(
    Uint8List source, {
    int size = IconAssetRules.thumbnailSize,
  }) async => IconThumbnailReady(source, width: size, height: size);
}
