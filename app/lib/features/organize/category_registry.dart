import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../core/designsystem/younum_icons.dart';
import '../../data/seed/demo_ledger_seed.dart';
import '../../domain/models/category.dart';
import '../../domain/models/category_icon_asset.dart';
import '../../domain/repositories/icon_asset_ports.dart';
import '../../domain/repositories/image_file_source.dart';
import '../../domain/repositories/ledger_repository.dart';

/// 分类与图标的**唯一**来源。
///
/// 指南 14.4.7：分类网格、分类管理、明细、分类统计、导出视图都从这里解析，
/// 避免「一页变了另一页还显示旧图」。
///
/// 它现在读写的是**数据库里的 `category` 表**。以前是内存里的两份表
/// （名字 → 图标、自定义名字列表），有两个真实缺陷：
///
/// 1. 用户新建的分类只存在内存里 —— 重启就没了，而且**整理时根本选不到**：
///    分配要的是真实的分类 ID，而那条分类在库里不存在。
/// 2. 图标按**名字**索引 —— 一旦改名，图标会跟着丢；指南 3.5.8 要求
///    「重命名保留稳定 ID」，名字本来就不该被当作键。
///
/// 图标只按分类 ID 存（`category.icon_key`），图片资源（`CategoryIconAsset`
/// 与私有文件生命周期）还没做，界面上如实说明。
class CategoryRegistry extends ChangeNotifier {
  CategoryRegistry({required this.repository, ImageFileSource? imageSource})
      : imageSource = imageSource ?? const UnsupportedImageSource();

  final LedgerRepository repository;

  /// 选图片的能力。桌面与测试环境是不支持实现，界面据此把入口显灰。
  final ImageFileSource imageSource;

  /// 出厂图标：内置分类在种子里定义的那一个。
  ///
  /// 「恢复默认图标」要回得到**出厂值**，而不是库里当前的值 ——
  /// 后者已经被用户改过了。用户新建的分类没有出厂图标，回退到默认叶片。
  static String defaultIconKeyOf(String? name) {
    if (name == null) return YounumIcons.defaultCategoryIconKey;
    for (final category in DemoLedgerSeed.categories()) {
      if (category.name == name) {
        return category.iconKey ?? YounumIcons.defaultCategoryIconKey;
      }
    }
    return YounumIcons.defaultCategoryIconKey;
  }

  List<Category> _categories = const <Category>[];
  List<CategoryIconAsset> _assets = const <CategoryIconAsset>[];
  String? _lastFailure;
  bool _loaded = false;

  /// 账本 ID。分类本身不按账本划分，这里只为调仓库时带上参数；
  /// 记住它，调用方（界面）就不用自己拼 `isDemo ? 1 : 2`。
  int _ledgerId = 0;

  List<Category> get categories => List<Category>.unmodifiable(_categories);

  bool get isLoaded => _loaded;

  /// 最近一次写失败的原因（成功时清空）。
  String? get lastFailure => _lastFailure;

  /// 一级分类（网格用），未归档。
  List<Category> get roots => <Category>[
        for (final category in _categories)
          if (category.isRoot && !category.archived) category,
      ];

  /// 某个一级分类下的细分用途。
  List<Category> childrenOf(int parentId) => <Category>[
        for (final category in _categories)
          if (category.parentId == parentId && !category.archived) category,
      ];

  Category? byId(int id) {
    for (final category in _categories) {
      if (category.id == id) return category;
    }
    return null;
  }

  /// 按名字找分类：明细、月报这些地方手上只有名字，只能这样查。
  Category? byName(String name) {
    for (final category in _categories) {
      if (category.name == name) return category;
    }
    return null;
  }

  /// 某个分类名对应的图标键。找不到返回 null，由调用方决定回退到什么。
  String? iconKeyOf(String name) => byName(name)?.iconKey;

  /// 从数据库读一遍。
  Future<void> load({required int ledgerId}) async {
    _ledgerId = ledgerId;
    _categories = await repository.categories(ledgerId: ledgerId);
    _assets = await repository.iconAssets();
    _loaded = true;
    notifyListeners();
  }

  /// 分类当前用的图片资源（内置图标时是 null）。
  CategoryIconAsset? assetOf(Category category) {
    if (category.iconType != CategoryIconType.image) return null;
    final id = int.tryParse(category.iconKey ?? '');
    if (id == null) return null;
    for (final asset in _assets) {
      if (asset.id == id) return asset;
    }
    return null;
  }

  /// 渲染用的**绝对**路径。
  ///
  /// 内置图标、或者资源记录已经不在了（图片被删、清过数据）时返回 null，
  /// 调用方回退到矢量图标 —— 指南 14.4.8：图片缺失不能影响分类与账目。
  String? imagePathOf(Category category) {
    final asset = assetOf(category);
    if (asset == null) return null;
    return repository.iconFiles.absolutePath(asset.relativePath);
  }

  /// 按分类名取渲染路径（明细、月报手上只有名字）。
  String? imagePathOfName(String name) {
    final category = byName(name);
    return category == null ? null : imagePathOf(category);
  }

  /// 把选中的图片做成缩略图（草稿用；此时还不落盘）。
  Future<IconThumbnailResult> prepareImage(Uint8List bytes) =>
      repository.prepareImage(bytes);

  /// 换成一个图片图标。返回 false 时 [lastFailure] 是可展示的原因。
  Future<bool> setImage({
    required int categoryId,
    required Uint8List bytes,
  }) async {
    final ok = _apply(
      await repository.setCategoryImage(
        ledgerId: _ledgerId,
        categoryId: categoryId,
        bytes: bytes,
      ),
    );
    if (ok) await _refreshAssets();
    return ok;
  }

  /// 恢复成内置图标（设计稿的「恢复默认图标」）。
  Future<bool> restoreBuiltinIcon({
    required int categoryId,
    required String name,
    required String iconKey,
  }) async {
    final ok = _apply(
      await repository.clearCategoryImage(
        ledgerId: _ledgerId,
        categoryId: categoryId,
        iconKey: iconKey,
      ),
    );
    if (ok) await _refreshAssets();
    return ok;
  }

  Future<void> _refreshAssets() async {
    _assets = await repository.iconAssets();
    notifyListeners();
  }

  /// 新建分类。失败时 [lastFailure] 里是给用户看的原因。
  Future<bool> create({required String name, required String iconKey}) async {
    return _apply(
      await repository.createCategory(
        ledgerId: _ledgerId,
        name: name,
        iconKey: iconKey,
      ),
    );
  }

  /// 改一个分类的图标。只改图标：名称、ID、分类关系与金额都不动（指南 14.3）。
  Future<bool> setIcon({
    required int categoryId,
    required String iconKey,
  }) async {
    return _apply(
      await repository.setCategoryIcon(
        ledgerId: _ledgerId,
        categoryId: categoryId,
        iconKey: iconKey,
      ),
    );
  }

  /// 把写库结果并进内存列表，再通知一次。
  ///
  /// 不重新查库：新分类带回了排序值（排在同级最后），就地替换/追加即可。
  bool _apply(CategoryWriteResult result) {
    switch (result) {
      case CategorySaved(:final category):
        _categories = <Category>[
          for (final item in _categories)
            if (item.id != category.id) item,
          category,
        ];
        _lastFailure = null;
        notifyListeners();
        return true;
      case CategoryRejected(:final message):
        _lastFailure = message;
        notifyListeners();
        return false;
    }
  }
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



