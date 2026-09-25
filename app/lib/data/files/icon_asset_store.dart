/// 分类图标的**文件**层：把缩略图写进应用私有目录、按哈希命名、按需清理。
///
/// 指南 14.4 的三条约束落在这里：
///
/// * 14.4.2：不能长期依赖选择器给的临时 URI —— 我们从字节写自己的文件，
///   原照片之后被移动或删除都不影响已经保存的图标。
/// * 14.4.3：先写临时文件、再做原子替换，最后才提交数据库引用；
///   文件与数据库**不可能**共处一个事务，所以这里只管文件，
///   谁先谁后由调用方（仓库层）按「先文件后数据库」的顺序决定。
/// * 14.4.4：只在确认「已经没人引用」之后才删文件；事务失败不能提前删。
library;

import 'dart:io';
import 'dart:typed_data';

import '../../domain/repositories/icon_asset_ports.dart';

/// 真机实现：应用私有目录下的一层子目录。
///
/// 目录**由外部提供**（真机走平台通道的 `filesDir`），这里不猜：
/// 猜错的后果是图片写到了一个不持久或者不对用户负责的地方，
/// 而那种错只在重启后才看得出来。
final class FileIconAssetStore implements IconAssetStore {
  FileIconAssetStore({required this.directoryOf});

  /// 子目录名。相对路径就是 `<子目录>/<哈希>.png`。
  static const String subDirectory = 'category_icons';

  /// 应用私有目录的解析器（真机是平台通道的 `filesDir`）。
  final Future<String> Function() directoryOf;

  String? _resolvedDirectory;

  Future<String> _directory() async =>
      _resolvedDirectory ??= '${await directoryOf()}/$subDirectory';

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<String> write({
    required String contentHash,
    required Uint8List bytes,
  }) async {
    final relative = '$subDirectory/$contentHash.png';
    final target = File(await _absolutePathOf(relative));
    await target.parent.create(recursive: true);

    if (await target.exists()) {
      // 同一张图已经在了：不重写，内容按定义是一样的。
      return relative;
    }

    // 先写临时文件再改名：中途失败不会留下一个「看起来有效」的半个文件。
    final temp = File('${target.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    try {
      await temp.rename(target.path);
    } catch (_) {
      // 改名失败（目标已存在、或跨文件系统）时退一步：直接写目标文件，
      // 但仍然保证不会留下 .tmp 残骸。
      await target.writeAsBytes(bytes, flush: true);
      if (await temp.exists()) await temp.delete();
    }
    return relative;
  }

  @override
  String absolutePath(String relativePath) {
    // 渲染路径是同步要的，而目录解析是异步的；拿到目录之前统一退回相对路径
    // （渲染层会因文件不存在而回退默认图标，不会崩）。**两种情况都要先净化**：
    // 未解析时原样返回，就等于把 `..` 直接交给了 File。
    final safe = _safe(relativePath);
    return _resolvedDirectory == null ? safe : '$_resolvedDirectory/$safe';
  }

  Future<String> _absolutePathOf(String relativePath) async =>
      '${await _directory()}/${_safe(relativePath)}';

  /// 相对路径是我们自己生成的，但拼接前仍要把路径穿越挡掉。
  static String _safe(String relativePath) =>
      relativePath.replaceAll('..', '').replaceAll(r'\', '/');

  @override
  Future<bool> exists(String relativePath) async =>
      File(await _absolutePathOf(relativePath)).exists();

  @override
  Future<void> delete(String relativePath) async {
    final file = File(await _absolutePathOf(relativePath));
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> clearAll() async {
    final directory = Directory(await _directory());
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

/// 落不了文件的平台（桌面、单元测试）。
///
/// 与选文件那边的 `UnsupportedFileSource` 一个道理：明确说「不支持」，
/// 让界面把入口显灰，而不是留一个点了没反应的按钮。
final class UnsupportedIconAssetStore implements IconAssetStore {
  const UnsupportedIconAssetStore();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<String> write({
    required String contentHash,
    required Uint8List bytes,
  }) async => throw StateError('这个平台上还不能保存图片资源');

  @override
  String absolutePath(String relativePath) => relativePath;

  @override
  Future<bool> exists(String relativePath) async => false;

  @override
  Future<void> delete(String relativePath) async {}

  @override
  Future<void> clearAll() async {}
}
