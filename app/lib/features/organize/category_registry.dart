import 'package:flutter/widgets.dart';

import '../../core/designsystem/younum_icons.dart';

/// 一个分类的图标配置。
///
/// `iconType` 的区分方式与指南 14.4.1 一致：内置键与图片资源 ID 分开表达，
/// 数据库里**不**保存 Bitmap / Base64 大对象。
class CategoryIconConfig {
  const CategoryIconConfig.builtin(this.iconKey)
      : imagePath = null,
        isImage = false;

  const CategoryIconConfig.image(this.imagePath)
      : iconKey = YounumIcons.defaultCategoryIconKey,
        isImage = true;

  final String iconKey;

  /// 应用私有文件目录下的相对路径。阶段 4 写入真实资源后填充。
  final String? imagePath;

  final bool isImage;

  @override
  bool operator ==(Object other) =>
      other is CategoryIconConfig &&
      other.iconKey == iconKey &&
      other.imagePath == imagePath &&
      other.isImage == isImage;

  @override
  int get hashCode => Object.hash(iconKey, imagePath, isImage);
}

/// 分类与图标的**唯一**来源。
///
/// 指南 14.4.7：分类网格、分类管理、明细、分类统计、导出视图都从这里解析，
/// 避免「一页变了另一页还显示旧图」。
///
/// 阶段 1 是内存实现（走查用）。阶段 2 增加图标资源模型与迁移，
/// 阶段 4 接入系统 Photo Picker 与私有文件写入后，把 [_save] 换成事务写入即可，
/// 调用方无需改动。
class CategoryRegistry extends ChangeNotifier {
  CategoryRegistry({Map<String, CategoryIconConfig>? initial, List<String>? customNames})
      : _icons = <String, CategoryIconConfig>{...?initial},
        _customNames = <String>[...?customNames];

  final Map<String, CategoryIconConfig> _icons;
  final List<String> _customNames;

  /// 用户创建的分类名。
  List<String> get customNames => List<String>.unmodifiable(_customNames);

  /// 解析某个分类的图标。未配置过则使用 [fallbackIconKey]。
  CategoryIconConfig iconFor(String categoryName, {String? fallbackIconKey}) {
    final configured = _icons[categoryName];
    if (configured != null) return configured;
    return CategoryIconConfig.builtin(
      fallbackIconKey ?? YounumIcons.defaultCategoryIconKey,
    );
  }

  /// 分类是否存在（内置或自定义）。
  bool exists(String name, Iterable<String> builtinNames) =>
      builtinNames.contains(name) || _customNames.contains(name);

  /// 保存图标草稿。
  ///
  /// 只有调用到这里，草稿才变成已提交配置 —— 选中新图标和恢复默认都只改草稿
  /// （指南 14.3）。
  void saveIcon(String categoryName, CategoryIconConfig config) {
    _icons[categoryName] = config;
    notifyListeners();
  }

  /// 新建分类并同时设置图标。
  void createCategory(String name, CategoryIconConfig config) {
    if (!_customNames.contains(name)) _customNames.add(name);
    _icons[name] = config;
    notifyListeners();
  }

  /// 恢复默认图标（内置叶片）。
  void resetIcon(String categoryName) {
    _icons.remove(categoryName);
    notifyListeners();
  }

  /// 该分类是否使用过自定义配置。
  bool hasCustomIcon(String categoryName) => _icons.containsKey(categoryName);
}

/// 把 [CategoryRegistry] 提供给子树。
class CategoryRegistryScope extends InheritedNotifier<CategoryRegistry> {
  const CategoryRegistryScope({
    super.key,
    required CategoryRegistry registry,
    required super.child,
  }) : super(notifier: registry);

  static CategoryRegistry of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<CategoryRegistryScope>();
    assert(scope != null, 'CategoryRegistryScope 未挂载：请检查 app.dart 的根部装配。');
    return scope!.notifier!;
  }

  /// 不需要订阅变化时使用，例如在 `initState` 里读取初始草稿。
  ///
  /// `initState` 阶段不允许 `dependOnInheritedWidgetOfExactType`。
  static CategoryRegistry read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<CategoryRegistryScope>();
    assert(scope != null, 'CategoryRegistryScope 未挂载：请检查 app.dart 的根部装配。');
    return scope!.notifier!;
  }
}
