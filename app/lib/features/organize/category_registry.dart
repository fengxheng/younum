import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../core/designsystem/younum_icons.dart';
import '../../core/preferences/category_pick_store.dart';
import '../../data/seed/demo_ledger_seed.dart';
import '../../domain/models/category.dart';
import '../../domain/models/category_icon_asset.dart';
import '../../domain/repositories/icon_asset_ports.dart';
import '../../domain/repositories/image_file_source.dart';
import '../../domain/repositories/ledger_repository.dart';
import '../../domain/rules/category_rules.dart';

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
/// 图标只按分类 ID 存（`category.icon_key`）；图片图标存成一个资源行加一份
/// 应用私有目录里的文件（见 `DECISIONS.md` 第 51、52 节）。
class CategoryRegistry extends ChangeNotifier {
  CategoryRegistry({
    required this.repository,
    ImageFileSource? imageSource,
    CategoryPickStore? pickStore,
  })  : imageSource = imageSource ?? const UnsupportedImageSource(),
        pickStore = pickStore ?? InMemoryCategoryPickStore();

  final LedgerRepository repository;

  /// 用途快捷项的持久化（卡片上显示哪几个、按什么顺序）。
  final CategoryPickStore pickStore;

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

  /// 用户配置过的快捷项 ID（顺序即显示顺序）。空 = 没配置过，用默认。
  List<int> _quickPickIds = const <int>[];

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

  /// 某个一级分类下**已归档**的细分用途。
  ///
  /// 与 [archivedRoots] 同一个道理：归档不等于删数据，用户得能找到回来的路。
  /// 父级归档时子级会被连带归档（见仓库层），那时它们不在这个列表里 ——
  /// 从「已归档」里恢复父级时会一起回来。
  List<Category> archivedChildrenOf(int parentId) => <Category>[
        for (final category in _categories)
          if (category.parentId == parentId && category.archived) category,
      ];

  /// 已经归档的一级分类（分类管理页底部的「已归档」区）。
  ///
  /// 归档的分类不参与用途选择，但历史记录仍然引用它，所以它不能消失 ——
  /// 这一份列表就是「让它还能被找回来」的那条路。
  List<Category> get archivedRoots => <Category>[
        for (final category in _categories)
          if (category.isRoot && category.archived) category,
      ];

  /// 能不能归档这个分类；不能时返回给用户看的原因。
  ///
  /// 界面用它**先把按钮置灰并说明**，而不是让用户点下去才被拒 ——
  /// 与名称校验同一条原则。
  String? archiveBlockedReason(Category category) =>
      CategoryRules.validateArchive(category: category, all: _categories)
          ?.message;

  /// 归档一个分类。用户看到的词是「删除」，指南 3.5.8 的语义是归档。
  Future<bool> archive(int categoryId) =>
      _setArchived(categoryId, archived: true);

  /// 从「已归档」里找回来。
  Future<bool> restore(int categoryId) =>
      _setArchived(categoryId, archived: false);

  /// 归档会**连带**改动细分用途（见仓库层说明），所以这里整表重读，
  /// 不像图标那样只就地替换一条。
  Future<bool> _setArchived(int categoryId, {required bool archived}) async {
    final result = await repository.setCategoryArchived(
      ledgerId: _ledgerId,
      categoryId: categoryId,
      archived: archived,
    );
    switch (result) {
      case CategorySaved():
        await load(ledgerId: _ledgerId);
        _lastFailure = null;
        notifyListeners();
        return true;
      case CategoryRejected(:final message):
        _lastFailure = message;
        notifyListeners();
        return false;
    }
  }

  /// 这个分类能不能当合并的源；不能时返回给用户看的原因。
  ///
  /// 界面拿它**先把入口置灰并说明**，而不是让用户走完选目标再被拒 ——
  /// 与名称校验、归档同一条原则。
  String? mergeBlockedReason(Category category) =>
      CategoryRules.mergeSourceBlocked(source: category, all: _categories)
          ?.message;

  /// 能合并到的其他分类。空列表的意思是「没有可合并的目标」——
  /// 与 [mergeBlockedReason] 是两句不同的话，界面分开说。
  List<Category> mergeTargetsFor(Category category) =>
      CategoryRules.mergeTargets(source: category, all: _categories);

  /// 把 [sourceId] 合并到 [targetId]（指南 3.5.8）。
  ///
  /// 成功后**整表重读**：合并不只改了源分类（归档），还改了真实账目的用途，
  /// 内存里那些按分类 ID 缓存的引用不能只靠就地替换。
  Future<CategoryMergeResult> merge({
    required int sourceId,
    required int targetId,
  }) async {
    final result = await repository.mergeCategories(
      ledgerId: _ledgerId,
      sourceId: sourceId,
      targetId: targetId,
    );
    switch (result) {
      case CategoryMerged():
        await load(ledgerId: _ledgerId);
        _lastFailure = null;
      case CategoryMergeRejected(:final message):
        _lastFailure = message;
    }
    notifyListeners();
    return result;
  }

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
    // 偏好读不出来不影响分类本身：退回「没配置过」，卡片显示内置那 8 个。
    try {
      _quickPickIds = await pickStore.loadQuickPickIds();
    } on Object catch (error) {
      _quickPickIds = const <int>[];
      _lastFailure = '用途快捷项的设置没读出来：$error';
    }
    _loaded = true;
    notifyListeners();
  }

  /// 卡片上的用途快捷项（有序、已过滤、最多 [CategoryRules.quickPickLimit] 个）。
  ///
  /// 未配置过时就是内置一级分类 —— 也就是这个功能之前的行为，
  /// 所以老用户升级上来看到的东西一模一样。
  List<Category> get quickPick => CategoryRules.resolveQuickPick(
        storedIds: _quickPickIds,
        all: _categories,
      );

  /// 当前的快捷项 ID（顺序即卡片上的顺序）。管理页用它判断「哪几个已选」。
  List<int> get quickPickIds => <int>[
        for (final category in quickPick) category.id,
      ];

  /// 保存快捷项。返回 false 表示**没存下来**（此时界面上的列表也不变）。
  ///
  /// 存失败不能装作成功：用户调完顺序、下次进来又变回原样，比一次明确的
  /// 失败提示糟糕得多。
  Future<bool> setQuickPick(List<int> ids) async {
    final stored = ids.take(CategoryRules.quickPickLimit).toList(growable: false);
    try {
      await pickStore.saveQuickPickIds(stored);
    } on Object catch (error) {
      _lastFailure = '用途快捷项没保存下来：$error';
      notifyListeners();
      return false;
    }
    _quickPickIds = stored.isEmpty ? const <int>[] : stored;
    _lastFailure = null;
    notifyListeners();
    return true;
  }

  /// 这个分类能不能加进快捷项；不能时返回给用户看的原因。
  ///
  /// 界面拿它**先把入口置灰并说明**，而不是等用户点下去才被拒 ——
  /// 与名称校验、归档、合并同一条原则。
  String? quickPickBlockedReason(int categoryId) {
    final picked = quickPick;
    if (picked.any((category) => category.id == categoryId)) return null;
    if (picked.length >= CategoryRules.quickPickLimit) {
      return '快捷项最多 ${CategoryRules.quickPickLimit} 个：'
          '再多就会把确认按钮挤到屏幕外';
    }
    return null;
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

  /// 新建分类。成功返回新建的那个分类，失败返回 null（原因在 [lastFailure]）。
  ///
  /// [parentId] 非空时建的是**细分用途**（需求：细分用途也要能自己建）。
  ///
  /// 返回整个分类而不是 bool：调用方要拿它的 **ID** 接着写图标，
  /// 而按名字回查在「一级和细分同名」时会拿错那一个。
  Future<Category?> create({
    required String name,
    required String iconKey,
    int? parentId,
  }) async {
    final result = await repository.createCategory(
      ledgerId: _ledgerId,
      name: name,
      iconKey: iconKey,
      parentId: parentId,
    );
    _apply(result);
    return switch (result) {
      CategorySaved(:final category) => category,
      CategoryRejected() => null,
    };
  }

  /// 给一个分类改名（指南 3.5.8：重命名保留稳定 ID）。
  ///
  /// 内置分类会被仓库拒绝并给出原因，界面拿 [lastFailure] 显示。
  Future<bool> rename({required int categoryId, required String name}) async {
    return _apply(
      await repository.renameCategory(
        ledgerId: _ledgerId,
        categoryId: categoryId,
        name: name,
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



