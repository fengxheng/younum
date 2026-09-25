/// 分类图标的**图片资源**（指南 3.2 / 14.4）。
///
/// 数据库里只存元数据与稳定资源 ID，图片本体放在应用私有文件目录里，
/// 靠 [relativePath] 查找 —— **不**保存 Bitmap / Base64 大对象（14.4.1）。
///
/// 「引用状态」刻意不存成字段：它等于「有没有哪个分类的 `icon_key` 指向我」，
/// 存一份就会漂移。要判断时现算（`LedgerDataset` / 仓库层都能算）。
library;

/// 一条图片资源。
final class CategoryIconAsset {
  const CategoryIconAsset({
    required this.id,
    required this.relativePath,
    required this.contentHash,
    required this.width,
    required this.height,
    required this.byteSize,
    required this.createdAtMs,
  });

  /// 还没写进数据库时的占位 ID。
  static const int idUnassigned = 0;

  final int id;

  /// 应用私有文件目录下的**相对**路径。
  ///
  /// 存相对路径而不是绝对路径：应用私有目录的绝对路径在升级、换设备、
  /// 备份恢复之后都可能变，存绝对路径等于存了一个迟早会失效的东西。
  final String relativePath;

  /// 缩略图内容哈希。同一张图重复选择只落一份，也用来判断「还有没有别处引用」。
  final String contentHash;

  /// 缩略图尺寸（像素）。
  final int width;
  final int height;

  /// 落盘的字节数。
  final int byteSize;

  final int createdAtMs;

  CategoryIconAsset copyWith({int? id}) => CategoryIconAsset(
    id: id ?? this.id,
    relativePath: relativePath,
    contentHash: contentHash,
    width: width,
    height: height,
    byteSize: byteSize,
    createdAtMs: createdAtMs,
  );

  @override
  String toString() =>
      'CategoryIconAsset($id, $relativePath, ${width}x$height, $byteSize 字节)';
}
