/// 分类。
///
/// 指南 3.2 / 14.4.1：图标类型用 `BUILTIN` / `IMAGE` 区分表达，
/// 数据库里**不**保存位图或 Base64 大对象。
///
/// 阶段 2 只落地 `BUILTIN`（内置图标键）。图片资源需要
/// `CategoryIconAsset` 表与私有文件生命周期，属于阶段 4 的范围，
/// 那时用一次真实的 v1 → v2 迁移补上（见 `docs/DECISIONS.md`）。
library;

/// 分类图标的来源。
enum CategoryIconType {
  /// 内置矢量图标，[Category.iconKey] 是 `YounumIcons` 里的键。
  builtin,

  /// 用户选择的图片。阶段 4 接入后 [Category.iconKey] 为 null。
  image;

  static CategoryIconType parse(String value) => switch (value) {
        'BUILTIN' => CategoryIconType.builtin,
        'IMAGE' => CategoryIconType.image,
        _ => throw ArgumentError.value(value, 'value', '未知的图标类型'),
      };

  /// 数据库里的字面值。显式映射，不依赖 `Enum.name` 的大小写，
  /// 避免以后重命名枚举成员就悄悄改了存盘格式。
  String get storageValue => switch (this) {
        CategoryIconType.builtin => 'BUILTIN',
        CategoryIconType.image => 'IMAGE',
      };
}

/// 一个分类。不可变。
final class Category {
  const Category({
    required this.id,
    required this.name,
    required this.iconType,
    required this.iconKey,
    required this.sortOrder,
    required this.isBuiltin,
    this.parentId,
    this.archived = false,
  }) : assert(
          iconType != CategoryIconType.builtin || iconKey != null,
          '内置图标类型必须带图标键',
        );

  /// 还没写进数据库时的占位 ID。
  static const int idUnassigned = 0;

  final int id;

  /// 父分类 ID。首版只用一层细分（如「餐饮 → 咖啡茶饮」）。
  final int? parentId;

  final String name;

  final CategoryIconType iconType;

  /// 内置图标键。图片类型时为 null。
  final String? iconKey;

  /// 排序权重，越小越靠前。
  final int sortOrder;

  /// 内置分类不允许删除，只能归档（指南 3.5.8）。
  final bool isBuiltin;

  /// 归档的分类从选择列表里消失，但历史引用继续有效。
  final bool archived;

  bool get isRoot => parentId == null;

  Category copyWith({
    int? id,
    int? parentId,
    bool clearParent = false,
    String? name,
    CategoryIconType? iconType,
    String? iconKey,
    int? sortOrder,
    bool? isBuiltin,
    bool? archived,
  }) =>
      Category(
        id: id ?? this.id,
        parentId: clearParent ? null : (parentId ?? this.parentId),
        name: name ?? this.name,
        iconType: iconType ?? this.iconType,
        iconKey: iconKey ?? this.iconKey,
        sortOrder: sortOrder ?? this.sortOrder,
        isBuiltin: isBuiltin ?? this.isBuiltin,
        archived: archived ?? this.archived,
      );

  @override
  bool operator ==(Object other) =>
      other is Category &&
      other.id == id &&
      other.parentId == parentId &&
      other.name == name &&
      other.iconType == iconType &&
      other.iconKey == iconKey &&
      other.sortOrder == sortOrder &&
      other.isBuiltin == isBuiltin &&
      other.archived == archived;

  @override
  int get hashCode => Object.hash(
        id,
        parentId,
        name,
        iconType,
        iconKey,
        sortOrder,
        isBuiltin,
        archived,
      );

  @override
  String toString() => 'Category($id, $name)';
}
