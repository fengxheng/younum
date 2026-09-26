import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/app_routes.dart';
import '../../app/route_args.dart';
import '../../core/components/buttons.dart';
import '../../core/components/category_grid.dart';
import '../../core/components/fields.dart';
import '../../core/components/list_row.dart';
import '../../core/components/primitives.dart';
import '../../core/components/screen_scaffold.dart';
import '../../core/components/sheets.dart';
import '../../core/designsystem/younum_colors.dart';
import '../../core/designsystem/younum_dimens.dart';
import '../../core/designsystem/younum_icons.dart';
import '../../core/designsystem/younum_text.dart';
import '../../domain/models/category.dart';
import '../../domain/repositories/icon_asset_ports.dart';
import '../../domain/repositories/ledger_file_source.dart';
import '../../domain/repositories/ledger_repository.dart';
import '../../domain/rules/category_rules.dart';
import 'category_registry.dart';
import 'review_session.dart';

// -----------------------------------------------------------------------------
// allcats —— 完整分类选择
// -----------------------------------------------------------------------------

/// 完整分类选择。
///
/// 带调用目的进入：为卡片选择、编辑详情、编辑拆分项。返回时回到正确调用方，
/// 不能全部跳回卡片页（指南 5.1）。
class AllCategoriesScreen extends StatefulWidget {
  const AllCategoriesScreen({super.key, this.args = const CategoryPickArgs(purpose: CategoryPickPurpose.card)});

  final CategoryPickArgs args;

  @override
  State<AllCategoriesScreen> createState() => _AllCategoriesScreenState();
}

class _AllCategoriesScreenState extends State<AllCategoriesScreen> {
  /// 选中的一级分类名。null 表示还没点过，按「当前分类或第一个」算。
  String? _selectedCategory;

  /// 选中的细分用途。
  String? _selectedSubcategory;

  /// 用户在这一页**点过**东西吗。
  ///
  /// 返回时要带出选择，但页面一进来就有一个「当前分类或第一个」的默认高亮 ——
  /// 用户什么都没点就返回，不能把这个默认值当成他的选择（那等于替用户改了用途）。
  bool _touched = false;

  /// 最终生效的选择：细分用途优先。
  String _effective(String selectedName) => _selectedSubcategory ?? selectedName;

  /// 选中就**立刻生效**，不必再点一次「使用此分类」。
  ///
  /// 需求方提的就是这个：卡片上找不到想要的用途 → 进「全部分类」选一个 →
  /// **直接返回**也算选定。所以每次点选都当场写进会话（卡片的用途选择存在
  /// [ReviewSession] 里），返回时调用方拿到的已经是最新那个。
  ///
  /// 详情页 / 拆分页要的是**返回值**（它们走 `Navigator.pop(result)`），
  /// 所以这边只记「点过」，由返回时的 `PopScope` 带出去。
  void _apply(String name) {
    _touched = true;
    if (widget.args.purpose == CategoryPickPurpose.card) {
      ReviewSessionScope.of(context).select(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final registry = CategoryRegistryScope.of(context);
    final roots = registry.roots;

    if (roots.isEmpty) {
      // 分类还没读出来（或者真的一个都没有）：给出解释，而不是一片空白。
      return YounumScreen(
        title: '选择用途',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('生活，不止一种分类', style: text.screenTitle),
            const SizedBox(height: YounumDimens.gapLg),
            YounumMutedText(
              registry.isLoaded ? '这个账本还没有可用的分类。' : '正在读取分类…',
            ),
          ],
        ),
      );
    }

    // 当前分类在列表里就用它，否则从第一个开始 ——
    // 以前这里写死「餐饮」，分类一旦改名就选不中了。
    final current = widget.args.currentCategory;
    final selectedName = _selectedCategory ??
        (current != null && registry.byName(current) != null
            ? current
            : roots.first.name);
    final children = registry.childrenOf(
      registry.byName(selectedName)?.id ?? 0,
    );
    final customRoots = <Category>[
      for (final category in roots)
        if (!category.isBuiltin) category,
    ];

    return PopScope(
      // 返回也要把当前选择交回给调用方：需求是「选好之后不必再点一次，
      // 直接返回也默认锁定新选的那个」。
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.of(context).pop(
          // 没点过就不带值：页面一进来就有一个默认高亮，
          // 那不能当成用户的选择（否则等于静默改了他的用途）。
          !_touched || widget.args.purpose == CategoryPickPurpose.card
              ? null
              : _effective(selectedName),
        );
      },
      child: YounumScreen(
        title: '选择用途',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('生活，不止一种分类', style: text.screenTitle),
            const SizedBox(height: YounumDimens.gapSm),
            YounumMutedText('先选大类，也可以进一步记录细分用途。'),
            const SizedBox(height: YounumDimens.gapLg),
            CategoryGrid(
              items: <YounumCategoryItem>[
                for (final category in roots)
                  YounumCategoryItem(
                    name: category.name,
                    iconKey:
                        category.iconKey ?? YounumIcons.defaultCategoryIconKey,
                    imagePath: registry.imagePathOf(category),
                  ),
              ],
              selectedName: selectedName,
              onSelected: (name) {
                setState(() {
                  _selectedCategory = name;
                  _selectedSubcategory = null;
                });
                _apply(name);
              },
            ),
            YounumSectionHeader(
              title: '$selectedName · 细分用途',
              // 细分用途要能自己建、自己改（需求）：入口在这里，配置在
              // 「细分用途」那一页 —— 与「用途快捷项」同一种做法，
              // 免得「选择用途」页既要选又要增删改。
              trailing: YounumPressable(
                onTap: () => context.open(
                  AppRoutes.subCategories,
                  arguments: SubCategoryArgs(
                    parentId: registry.byName(selectedName)?.id ?? 0,
                    parentName: selectedName,
                  ),
                ),
                semanticLabel: '管理「$selectedName」的细分用途',
                borderRadius:
                    BorderRadius.circular(YounumDimens.radiusControlSmall),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                  child: Text(
                    '新建 / 编辑 ›',
                    style: text.label
                        .copyWith(color: YounumColors.of(context).primaryColor),
                  ),
                ),
              ),
            ),
            if (children.isEmpty)
              const YounumPillNote('这个分类还没有细分用途，直接用它就好。')
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final child in children)
                    YounumChip(
                      label: child.name,
                      selected: _selectedSubcategory == child.name,
                      leadingIconKey: child.iconKey,
                      onTap: () {
                        setState(
                          () => _selectedSubcategory =
                              _selectedSubcategory == child.name
                                  ? null
                                  : child.name,
                        );
                        _apply(
                          _selectedSubcategory == null
                              ? selectedName
                              : child.name,
                        );
                      },
                    ),
                ],
              ),
          if (customRoots.isNotEmpty) ...<Widget>[
            const YounumDivider(),
            YounumSectionHeader(
              title: '我的分类',
              trailing: YounumPressable(
                onTap: () => context.open(AppRoutes.categoryManage),
                semanticLabel: '管理分类图标',
                borderRadius:
                    BorderRadius.circular(YounumDimens.radiusControlSmall),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                  child: Text(
                    '管理图标 ›',
                    style: text.label
                        .copyWith(color: YounumColors.of(context).primaryColor),
                  ),
                ),
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final category in customRoots)
                  YounumChip(
                    label: category.name,
                    selected: _selectedSubcategory == category.name,
                    leadingIconKey: category.iconKey,
                    onTap: () {
                      setState(
                        () => _selectedSubcategory =
                            _selectedSubcategory == category.name
                                ? null
                                : category.name,
                      );
                      _apply(
                        _selectedSubcategory == null
                            ? selectedName
                            : category.name,
                      );
                    },
                  ),
              ],
            ),
          ],
          const SizedBox(height: YounumDimens.gapXl),
          PrimaryAction(
            label: '使用此分类 · ${_effective(selectedName)}',
            onPressed: () {
              switch (widget.args.purpose) {
                case CategoryPickPurpose.card:
                  ReviewSessionScope.of(context).select(_effective(selectedName));
                  Navigator.of(context).pop();
                case CategoryPickPurpose.detail:
                case CategoryPickPurpose.splitItem:
                  // 返回选中值给调用方，而不是替它决定后续跳转。
                  Navigator.of(context).pop(_effective(selectedName));
              }
            },
          ),
        ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// subcats —— 细分用途
// -----------------------------------------------------------------------------

/// 一个一级分类下面的细分用途。
///
/// 需求：细分用途也要能**自己建、自己改**，而且「编辑分类图标」页里也要有
/// 相应的入口。以前细分用途是种子里写死的（餐饮下面的咖啡茶饮之类），
/// 用户能选不能加，名字也改不了。
///
/// 与「用途快捷项」同一种做法：管理页独立成页，两个入口都指向它，
/// 不用两处各写一套增删改。
class SubCategoryScreen extends StatelessWidget {
  const SubCategoryScreen({super.key, required this.args});

  final SubCategoryArgs args;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final registry = CategoryRegistryScope.of(context);
    final parent = registry.byId(args.parentId);
    // 父级被删/归档之后不该再停在「细分用途」上：给出原因与退路。
    if (parent == null || parent.archived) {
      return YounumScreen(
        title: '细分用途',
        child: const YounumEmptyState(
          icon: YounumIcons.search,
          title: '这个分类已经不在了',
          description: '它可能已经被归档。归档的分类不再出现在选择列表里，'
              '可以在「分类管理」最底部恢复它，它的细分用途会一起回来。',
        ),
      );
    }

    final label = args.parentName ?? parent.name;
    final children = registry.childrenOf(parent.id);
    final archived = registry.archivedChildrenOf(parent.id);

    return YounumScreen(
      title: '细分用途',
      // 底部留出手势条/导航栏的高度：列表长了也不会被系统条盖住最后一行。
      padding: EdgeInsets.fromLTRB(
        YounumDimens.pageHorizontal,
        YounumDimens.pageTop,
        YounumDimens.pageHorizontal,
        YounumDimens.pageBottom + MediaQuery.paddingOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('「$label」下面还能再分细一点。', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText(
            '细分用途只在整理时多一次选择：选中「$label」之后可以再指定它。'
            '不建也行，直接用大类就够了。',
          ),
          const SizedBox(height: YounumDimens.gapLg),

          YounumSettingRow(
            title: '新建细分用途',
            subtitle: '挂在「$label」下面',
            icon: YounumIcons.add,
            onTap: () => context.open(
              AppRoutes.categoryEditor,
              arguments: CategoryEditorArgs(
                categoryName: null,
                parentId: parent.id,
                parentName: label,
              ),
            ),
          ),
          const SizedBox(height: YounumDimens.gapSm),

          if (children.isEmpty)
            const YounumPillNote('还没有细分用途。先新建一个，整理时才选得到。')
          else
            for (final child in children)
              YounumListRow(
                title: child.name,
                // 内置的那几个名字是设计稿定的基线词汇，不能改（编辑页会说明），
                // 所以这里的承诺要分开写 —— 不能说“能改名”却进去了改不动。
                subtitle: child.isBuiltin ? '内置名称，只能换图标' : '点击改名或换图标',
                iconKey: child.iconKey,
                imagePath: registry.imagePathOf(child),
                onTap: () => context.open(
                  AppRoutes.categoryEditor,
                  arguments: CategoryEditorArgs(
                    categoryId: child.id,
                    categoryName: child.name,
                  ),
                ),
              ),

          if (archived.isNotEmpty) ...<Widget>[
            const SizedBox(height: YounumDimens.gapLg),
            const YounumDivider(),
            const YounumSectionHeader(title: '已归档'),
            YounumMutedText(
              '这 ${archived.length} 个细分用途不再出现在选择列表里，'
              '用它们归过类的记录照旧显示。想继续用就点「恢复」。',
            ),
            const SizedBox(height: YounumDimens.gapSm),
            for (final child in archived)
              YounumListRow(
                title: child.name,
                subtitle: '已归档，不影响已有记录',
                iconKey: child.iconKey,
                imagePath: registry.imagePathOf(child),
                trailingText: '恢复',
                onTap: () => _restoreSubCategory(context, registry, child),
              ),
          ],

          const SizedBox(height: YounumDimens.gapLg),
          const YounumPanel(
            tone: YounumPanelTone.soft,
            child: YounumMutedText(
              '改名字不会动 ID：已经用这个细分用途归好类的账目照旧属于它。',
            ),
          ),
        ],
      ),
    );
  }
}

/// 恢复一个已归档的细分用途。
Future<void> _restoreSubCategory(
  BuildContext context,
  CategoryRegistry registry,
  Category category,
) async {
  final ok = await registry.restore(category.id);
  if (!context.mounted) return;
  showYounumToast(
    context,
    ok ? '已恢复「${category.name}」' : (registry.lastFailure ?? '没有恢复成功'),
  );
}

// -----------------------------------------------------------------------------
// categorymanage —— 分类管理 · 图标设置
// -----------------------------------------------------------------------------

/// 分类管理。
///
/// 内置与自定义分类都可进入图标编辑；**改名、改 ID、改分类关系、改金额**
/// 都不属于本页范围（指南 14.3）。
class CategoryManageScreen extends StatelessWidget {
  const CategoryManageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final registry = CategoryRegistryScope.of(context);

    return YounumScreen(
      title: '分类管理',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text('小图标，你来定义。', style: text.screenTitle)),
              YounumPressable(
                onTap: () => context.open(
                  AppRoutes.categoryEditor,
                  arguments: const CategoryEditorArgs(categoryName: null),
                ),
                semanticLabel: '新建分类',
                borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                  child: Text(
                    '+ 新建',
                    style: text.label.copyWith(color: YounumColors.of(context).primaryColor),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText('点击一个分类，选择它的专属图标。'),
          const SizedBox(height: YounumDimens.gapLg),
          // 用途快捷项：卡片上显示哪几个、按什么顺序。
          // 放在图标网格**上面**是有意的：它管的是「整理时先看到什么」，
          // 比换图标更常被用到，埋在网格下面会很难找。
          YounumSettingRow(
            title: '用途快捷项',
            subtitle:
                '卡片上显示${registry.quickPick.length}个：'
                '${registry.quickPick.map((category) => category.name).join('、')}',
            icon: YounumIcons.navCards,
            onTap: () => context.open(AppRoutes.categoryQuickPick),
          ),
          const SizedBox(height: YounumDimens.gapSm),
          LayoutBuilder(
            builder: (context, constraints) {
              const spacing = 10.0;
              final width = (constraints.maxWidth - spacing) / 2;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: <Widget>[
                  for (final category in registry.roots)
                    SizedBox(
                      width: width,
                      child: _ManageCategoryCard(
                        entry: YounumCategoryItem(
                          name: category.name,
                          iconKey: category.iconKey ??
                              YounumIcons.defaultCategoryIconKey,
                          imagePath: registry.imagePathOf(category),
                        ),
                        onTap: () => context.open(
                          AppRoutes.categoryEditor,
                          arguments: CategoryEditorArgs(
                            categoryId: category.id,
                            categoryName: category.name,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: YounumDimens.gapLg),
          const YounumPanel(
            tone: YounumPanelTone.soft,
            child: YounumMutedText(
              '预设线条图标跟随主题色，上传的图片保持原色。'
              '更换图标不会改动消费金额、分类关系与整理进度。',
            ),
          ),

          // 已归档（指南 3.5.8）。
          //
          // 「删除」的真相是归档：分类不再出现在用途选择里，但历史记录仍然
          // 引用它。既然删除不是不可逆的，就必须让用户**找得到回来的路** ——
          // 否则那个按钮就是个陷阱。
          if (registry.archivedRoots.isNotEmpty) ...<Widget>[
            const SizedBox(height: YounumDimens.gapLg),
            const YounumDivider(),
            const YounumSectionHeader(title: '已归档'),
            YounumMutedText(
              '这 ${registry.archivedRoots.length} 个分类不再出现在选择列表里，'
              '用它们归过类的记录照旧显示。想继续用就点「恢复」。',
            ),
            const SizedBox(height: YounumDimens.gapSm),
            for (final category in registry.archivedRoots)
              YounumListRow(
                title: category.name,
                subtitle: '已归档，不影响已有记录',
                iconKey: category.iconKey,
                imagePath: registry.imagePathOf(category),
                trailingText: '恢复',
                onTap: () => _restoreArchived(context, registry, category),
              ),
          ],
        ],
      ),
    );
  }
}

/// 把一个已归档的分类恢复回来。
Future<void> _restoreArchived(
  BuildContext context,
  CategoryRegistry registry,
  Category category,
) async {
  final ok = await registry.restore(category.id);
  if (!context.mounted) return;
  showYounumToast(
    context,
    ok ? '已恢复「${category.name}」' : (registry.lastFailure ?? '没有恢复成功'),
  );
}

class _ManageCategoryCard extends StatelessWidget {
  const _ManageCategoryCard({required this.entry, required this.onTap});

  final YounumCategoryItem entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final colors = YounumColors.of(context);
    return Semantics(
      button: true,
      // 可交互控件必须有明确名称（指南 14.4.9）。
      label: '编辑${entry.name}图标',
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(YounumDimens.radiusControl),
          overlayColor: WidgetStatePropertyAll<Color>(
            colors.pressedColor.withValues(alpha: 0.10),
          ),
          child: Container(
            constraints: const BoxConstraints(minHeight: 68),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(YounumColors.surface),
              border: Border.all(color: colors.softColor),
              borderRadius: BorderRadius.circular(YounumDimens.radiusControl),
            ),
            child: Row(
              children: <Widget>[
                YounumTileIcon(
                  iconKey: entry.iconKey,
                  imagePath: entry.imagePath,
                  size: 34,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    entry.name,
                    overflow: TextOverflow.ellipsis,
                    style: text.listPrimary,
                  ),
                ),
                ExcludeSemantics(
                  child: Icon(
                    YounumIcons.edit,
                    size: YounumDimens.iconSm,
                    color: colors.mutedColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// newcat —— 新建分类 / 编辑已有分类的图标
// -----------------------------------------------------------------------------

/// 分类图标编辑器。
///
/// 一个页面同时承载两种用途（指南 14.3）：
/// * 新建分类 —— 可填名称；
/// * 编辑已有分类 —— **只改图标**，名称只读。
///
/// 未保存的草稿在返回时会询问放弃 / 继续编辑。
class CategoryEditorScreen extends StatefulWidget {
  const CategoryEditorScreen({super.key, this.args = const CategoryEditorArgs(categoryName: null)});

  final CategoryEditorArgs args;

  @override
  State<CategoryEditorScreen> createState() => _CategoryEditorScreenState();
}

class _CategoryEditorScreenState extends State<CategoryEditorScreen> {
  late final TextEditingController _nameController =
      TextEditingController(text: widget.args.categoryName ?? '');

  late String _draftIconKey;

  /// 进页时的草稿图标，用来判断「改过没有」。
  late final String _initialDraftIconKey;

  /// 草稿里的 emoji 输入框（需求：允许直接填 emoji 当图标）。
  late final TextEditingController _emojiController;

  /// emoji 输入框的错误提示。
  String? _emojiError;

  /// 草稿里的图片缩略图（设计稿：选中图片只改草稿，按保存才提交）。
  Uint8List? _draftImageBytes;

  String? _errorText;
  String _statusMessage = '';

  /// 正在写库。写完之前按钮要保持不可点（指南 14.3）。
  bool _saving = false;

  /// 正在处理图片。处理未完成时也要禁用保存（指南 14.3）。
  bool _processing = false;

  /// 这台设备能不能选图片。未知时按钮显灰，而不是点了才发现不行。
  bool _canPickImage = false;

  /// 选图令牌：连续选图只保留最后一次（指南 14.3）。
  int _pickToken = 0;

  bool get _isEditing => widget.args.categoryId != null;

  @override
  void initState() {
    super.initState();
    // 草稿起点就是这个分类**当前**的图标；只有按「保存」才会写库。
    //
    // 以前这里用的是「按名字查种子图标」（`defaultIconKeyOf(committed.name)`）：
    // 对内置分类没错，但用户自建的分类（自己挑过图标的那种）一律拿回默认
    // 叶片 —— 预览是错的、一进页就算「改过」，保存一下就把用户的图标
    // 默默换成了叶子。
    //
    // 图片图标例外：草稿只能是一个矢量键（用户在草稿里要么重选图片、
    // 要么挑一个矢量 / emoji），所以它从该分类的默认矢量起。
    final committed = _editingCategory;
    _initialDraftIconKey = switch (committed) {
      null => YounumIcons.defaultCategoryIconKey,
      Category(iconType: CategoryIconType.image) =>
        CategoryRegistry.defaultIconKeyOf(committed.name),
      Category(:final iconKey) =>
        iconKey ?? YounumIcons.defaultCategoryIconKey,
    };
    _draftIconKey = _initialDraftIconKey;
    _emojiController = TextEditingController(
      text: YounumIcons.isBuiltinCategoryKey(_initialDraftIconKey)
          ? ''
          : _initialDraftIconKey,
    );
    // 名字也是草稿的一部分：它决定「保存」能不能按（编辑已有分类时
    // 什么都没改就灰着）以及「返回时要不要先问一句」。少了这个监听，
    // 用户改完名字发现保存按钮还是灰的 —— 界面上看不出为什么。
    _nameController.addListener(_onNameChanged);
    _loadPickAvailability();
  }

  void _onNameChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _loadPickAvailability() async {
    final available = await _registry.imageSource.isAvailable();
    if (!mounted) return;
    setState(() => _canPickImage = available);
  }

  @override
  void dispose() {
    _nameController.removeListener(_onNameChanged);
    _nameController.dispose();
    _emojiController.dispose();
    super.dispose();
  }

  /// 读取注册表。
  ///
  /// 编辑器里改动的都是本地草稿，因此这里不需要订阅注册表的变化，
  /// 用非订阅式读取即可（`initState` 也不允许订阅）。
  CategoryRegistry get _registry => CategoryRegistryScope.read(context);

  /// 图标标签 → 内置键。
  ///
  /// 网格是按**名字**回调的（`CategoryGrid` 的接口），所以这里建一份映射
  /// 反向查；以前是在列表里 `firstWhere` 找标签，图标一多，重名就成了
  /// 静默选错格子的隐患（`icon_asset_rules_test.dart` 有用例守着标签唯一）。
  Map<String, String> get _iconKeyByLabel => <String, String>{
    for (final key in YounumIcons.builtinCategoryKeys)
      YounumIcons.categoryIconLabel(key): key,
  };

  /// 用户直接在输入框里填 emoji。
  ///
  /// 只在合法时才把它当成草稿图标：填到一半（或填了文字）时不该把预览
  /// 改成一句错误信息，但要说清哪里不对。
  void _onEmojiChanged(String raw) {
    final value = raw.trim();
    if (value.isEmpty) {
      setState(() {
        _emojiError = null;
        if (!YounumIcons.isBuiltinCategoryKey(_draftIconKey)) {
          // 清空就回到默认图标，不让草稿停在一个已经看不到的 emoji 上。
          _draftIconKey = YounumIcons.defaultCategoryIconKey;
          _statusMessage = '';
        }
      });
      return;
    }
    final error = CategoryRules.validateEmojiIconKey(raw: value);
    setState(() {
      _emojiError = error?.message;
      if (error == null) {
        _draftIconKey = value;
        _draftImageBytes = null;
        _statusMessage = '图标已预览，保存后生效';
      }
    });
  }

  /// 名字改过没有。
  ///
  /// 新建时「填过东西」就算改过（返回时先问一句再丢）；编辑自己建的分类时
  /// 与原名比；内置分类的名字不给改，所以永远算没改过。
  bool get _nameChanged {
    final typed = _nameController.text.trim();
    final existing = _editingCategory;
    if (existing == null) return typed.isNotEmpty;
    if (!_nameEditable) return false;
    return existing.name != typed;
  }

  /// 是否存在未保存的草稿。
  bool get _isDirty {
    if (_draftImageBytes != null) return true;
    if (_draftIconKey != _initialDraftIconKey) return true;
    return _nameChanged;
  }

  /// 能不能按保存。
  ///
  /// 编辑已有分类时，什么都没改就不给按：那种「保存」只能干坏事
  /// （例如把一个图片图标默默换成矢量）—— 与详情页「没改动时保存是灰的」同一条原则。
  bool get _canSave =>
      !_saving && !_processing && (!_isEditing || _isDirty);

  /// 选一张图片，做成缩略图放进草稿。
  ///
  /// 取消什么也不改；失败给出可读原因并且**保留旧草稿**（指南 14.3）。
  /// 连续选图用令牌只留最后一次：旧图处理得慢，回来时不能覆盖新选择。
  Future<void> _pickImage() async {
    if (_processing) return;
    final registry = _registry;
    final token = ++_pickToken;

    setState(() => _processing = true);
    final outcome = await registry.imageSource.pickImage();
    switch (outcome) {
      case PickCanceled():
        break;
      case PickFailed(:final message):
        if (mounted) showYounumToast(context, message);
      case DocumentPicked(:final document):
        final result = await registry.prepareImage(document.bytes);
        // 有更新的选择在路上了：这次的结果直接丢掉，也不写任何状态。
        if (token != _pickToken || !mounted) return;
        switch (result) {
          case IconThumbnailFailed(:final error):
            showYounumToast(context, error.message);
          case IconThumbnailReady(:final bytes):
            setState(() {
              _draftImageBytes = bytes;
              _statusMessage = '图片已预览，保存后生效';
            });
        }
    }
    if (mounted) setState(() => _processing = false);
  }

  /// 名称校验走规则层：界面与仓库用同一份判断，
  /// 不会出现「界面放行、写库被拒」这种两套说法。
  ///
  /// 同级是谁取决于层级：一级分类看别的**一级分类**，细分用途看**同一个
  /// 父级下面的**那些 —— 否则「餐饮」下面和一级里各有一个「咖啡」都不算重名，
  /// 那个唯一索引也不会拦（它按 parent_id + name 判）。
  bool _validateName(String name) {
    final parentId = _parentId;
    final error = CategoryRules.validateName(
      name: name,
      siblings: parentId == null
          ? _registry.roots
          : _registry.childrenOf(parentId),
      excludingId: widget.args.categoryId,
    );
    setState(() => _errorText = error?.message);
    return error == null;
  }

  Future<void> _save() async {
    if (!_canSave) return;
    final registry = _registry;
    final existing = _editingCategory;
    final name = _nameController.text.trim();
    final nameChanged = existing != null && existing.name != name;
    if (existing == null && !_validateName(name)) return;

    setState(() => _saving = true);

    // 先确保分类存在且名字写对：新建时先建（用草稿里的矢量图标），再改图标。
    // 分开写是有意的：图片落盘与数据库不可能共处一个事务（指南 14.4.3），
    // 所以万一图片那一步失败，分类本身仍然建成了（带默认图标），
    // 而不是让用户以为什么都没发生。
    var targetId = existing?.id;
    var ok = true;
    if (existing == null) {
      final created = await registry.create(
        name: name,
        iconKey: _draftIconKey,
        parentId: widget.args.parentId,
      );
      ok = created != null;
      targetId = created?.id;
    } else {
      // 改名（指南 3.5.8：重命名保留稳定 ID）。内置分类会被仓库拒绝，
      // 而且界面本来就不给改 —— 这里只是把那条规则也走一遍。
      if (nameChanged) {
        ok = await registry.rename(categoryId: existing.id, name: name);
      }
      if (ok && _draftIconKey != _initialDraftIconKey) {
        ok = await registry.setIcon(
          categoryId: existing.id,
          iconKey: _draftIconKey,
        );
      }
    }

    final imageBytes = _draftImageBytes;
    if (ok && targetId != null) {
      final committed = registry.byId(targetId);
      final savedName = committed?.name ?? name;
      if (imageBytes != null) {
        ok = await registry.setImage(
          categoryId: targetId,
          bytes: imageBytes,
        );
      } else if (committed?.iconType == CategoryIconType.image &&
          _draftIconKey != _initialDraftIconKey) {
        // 草稿是矢量图标、库里本来挂着图片，而且矢量确实换过：这就是「恢复默认图标」。
        ok = await registry.restoreBuiltinIcon(
          categoryId: targetId,
          name: savedName,
          iconKey: _draftIconKey,
        );
      }
    }

    if (!mounted) return;
    setState(() => _saving = false);

    if (!ok) {
      // 失败要说清原因，而且**不能**返回上一页 —— 否则用户以为存上了。
      setState(
        () => _errorText = registry.lastFailure ?? '没有保存成功，可以重试',
      );
      return;
    }
    showYounumToast(
      context,
      existing == null
          ? (widget.args.parentId == null ? '分类已保存' : '细分用途已保存')
          : '已保存',
    );
    Navigator.of(context).pop();
  }

  Future<bool> _confirmDiscard() async {
    if (!_isDirty) return true;
    return showConfirmSheet(
      context: context,
      title: '放弃未保存的修改？',
      description: '你的修改还没有保存，离开后这次修改会丢失。已提交的内容不受影响。',
      confirmLabel: '放弃修改',
      cancelLabel: '继续编辑',
    );
  }

  /// 正在编辑的那个分类（新建时为 null）。
  Category? get _editingCategory {
    final id = widget.args.categoryId;
    return id == null ? null : _registry.byId(id);
  }

  /// 这个分类挂在谁下面：编辑已有分类时看它自己，新建时看参数。
  int? get _parentId => _editingCategory?.parentId ?? widget.args.parentId;

  /// 页面标题。
  String get _title {
    final editing = _editingCategory;
    if (editing != null) {
      return editing.isRoot ? '编辑分类图标' : '编辑细分用途';
    }
    return _parentId == null ? '新建分类' : '新建细分用途';
  }

  /// 名字能不能改。
  ///
  /// 新建时当然能填；编辑时**自建分类**能改（指南 3.5.8 要求「重命名保留
  /// 稳定 ID」，ID 不动，历史账目照旧属于它），内置分类不给改 ——
  /// 它们是设计稿定的基线词汇，想换说法就新建一个自己的。
  bool get _nameEditable => !_isEditing || !(_editingCategory?.isBuiltin ?? true);

  /// 「细分用途」那一行的副标题：有就说清是哪几个，没有就直说没有。
  String get _subCategoriesSubtitle {
    final id = _editingCategory?.id;
    if (id == null) return '还没建过';
    final children = _registry.childrenOf(id);
    if (children.isEmpty) return '还没有：可以在这里自己建';
    final names = children.map((category) => category.name).join('、');
    return '${children.length} 个：$names';
  }

  /// 不能归档时给用户看的原因（例如「这是最后一个分类」）。
  String? get _archiveBlockedReason {
    final category = _editingCategory;
    return category == null ? null : _registry.archiveBlockedReason(category);
  }

  /// 不能合并时给用户看的原因（例如「下面还有细分用途」）。
  String? get _mergeBlockedReason {
    final category = _editingCategory;
    return category == null ? null : _registry.mergeBlockedReason(category);
  }

  /// 合并到另一个分类（指南 3.5.8：分类合并需显式迁移分配关系）。
  ///
  /// 两步都要先问：**并到哪里**（选列表），以及**确认**。
  /// 确认里把真实影响说清楚 —— 「账目会改成目标分类」「源分类会被归档」
  /// 「不能撤销」—— 用户才敢按下去，与归档确认同一条原则。
  Future<void> _merge() async {
    final category = _editingCategory;
    if (category == null || _saving || _processing) return;
    final registry = _registry;

    final targets = registry.mergeTargetsFor(category);
    if (targets.isEmpty) {
      showYounumToast(context, '没有可以合并到的分类：需要同层级的另一个分类才行');
      return;
    }

    final target = await _pickMergeTarget(category, targets);
    if (target == null || !mounted) return;

    final confirmed = await showConfirmSheet(
      context: context,
      title: '把「${category.name}」并到「${target.name}」？',
      description:
          '已经用「${category.name}」归好类的账目会改成「${target.name}」：'
          '金额、时间、备注都不变，月度统计会跟着重新汇总。\n\n'
          '「${category.name}」会变成一个空分类并归档 —— 不再出现在选择列表里。'
          '想找回来时可以在「分类管理」最底部恢复（那时它里面已经没有账目了）。\n\n'
          '这一步不能撤销。',
      confirmLabel: '合并',
      cancelLabel: '再想想',
    );
    if (!confirmed || !mounted) return;

    setState(() => _saving = true);
    final result = await registry.merge(
      sourceId: category.id,
      targetId: target.id,
    );
    if (!mounted) return;
    setState(() => _saving = false);

    switch (result) {
      case CategoryMergeRejected(:final message):
        // 失败要说清原因，而且**不能**返回上一页 —— 否则用户以为并好了。
        setState(() => _errorText = message);
      case CategoryMerged(:final movedTransactions, :final targetName):
        showYounumToast(
          context,
          movedTransactions == 0
              ? '「${category.name}」并到了「$targetName」，它下面本来没有账目'
              : '$movedTransactions 笔账已归到「$targetName」',
        );
        Navigator.of(context).pop();
    }
  }

  /// 选合并目标。取消返回 null，不产生副作用。
  ///
  /// 不用通用的文字选项弹层：分类在这套界面里一直是**带图标**出现的
  /// （分类网格、管理页、明细），到这里突然只剩一行行名字会让用户
  /// 要靠文字回想自己那几个自定义分类长得什么样。
  Future<Category?> _pickMergeTarget(
    Category source,
    List<Category> targets,
  ) {
    final registry = _registry;
    final text = YounumText.of(context);
    final colors = YounumColors.of(context);
    return showModalBottomSheet<Category>(
      context: context,
      backgroundColor: colors.washColor,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  YounumDimens.pageHorizontal,
                  0,
                  YounumDimens.pageHorizontal,
                  8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text('合并到哪个分类？', style: text.sheetTitle),
                    const SizedBox(height: 4),
                    YounumMutedText(
                      '只有同一层级的分类能合并。「${source.name}」上的账目会全部归到选中的那个。',
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: targets.length,
                  itemBuilder: (context, index) {
                    final option = targets[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: YounumDimens.pageHorizontal,
                      ),
                      child: YounumListRow(
                        title: option.name,
                        iconKey: option.iconKey ??
                            YounumIcons.defaultCategoryIconKey,
                        imagePath: registry.imagePathOf(option),
                        showDivider: index != targets.length - 1,
                        semanticLabel: '合并到${option.name}',
                        onTap: () => Navigator.of(sheetContext).pop(option),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 删除 / 归档这个分类（指南 3.5.8：**分类删除默认归档**）。
  ///
  /// 说清楚「变的是什么、不变的是什么」：用户以为删掉分类会连账一起没，
  /// 那句「记录不受影响」是他敢按下去的前提。
  Future<void> _archive() async {
    final category = _editingCategory;
    if (category == null || _saving || _processing) return;
    final isBuiltin = category.isBuiltin;

    final confirmed = await showConfirmSheet(
      context: context,
      title: isBuiltin ? '归档「${category.name}」？' : '删除「${category.name}」？',
      description:
          '已经用它归好类的记录不受影响：用途、金额与月度统计都照旧。\n\n'
          '变的只有一处：它不再出现在「选择用途」的列表里。'
          '${isBuiltin ? '内置分类不能删除，只能归档。' : ''}\n\n'
          '想找回来时，在「分类管理」最底部可以恢复。',
      confirmLabel: isBuiltin ? '归档' : '删除',
      cancelLabel: '再想想',
    );
    if (!confirmed || !mounted) return;

    setState(() => _saving = true);
    final ok = await _registry.archive(category.id);
    if (!mounted) return;
    setState(() => _saving = false);

    if (!ok) {
      setState(
        () => _errorText = _registry.lastFailure ?? '没有保存成功，可以重试',
      );
      return;
    }
    showYounumToast(
      context,
      isBuiltin ? '已归档，可在分类管理底部恢复' : '已删除，可在分类管理底部恢复',
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final colors = YounumColors.of(context);

    return PopScope(
      canPop: !_isDirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final leave = await _confirmDiscard();
        if (leave && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: YounumScreen(
        title: _title,
        // 这一页很长（预设图标 + emoji + 图片 + 保存），滚到底时最后的按钮
        // 会被系统手势条盖住一截：真机上「保存」按不到（实测）。底部补上
        // 系统占用的那一块，滚到底就是完整可见的按钮。
        padding: EdgeInsets.fromLTRB(
          YounumDimens.pageHorizontal,
          YounumDimens.pageTop,
          YounumDimens.pageHorizontal,
          YounumDimens.pageBottom + MediaQuery.paddingOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              _isEditing ? '给分类换个新模样' : '让分类，更像你',
              style: text.screenTitle,
            ),
            const SizedBox(height: YounumDimens.gapSm),
            YounumMutedText(
              widget.args.parentName == null
                  ? '选择一个图标，或用自己的图片。'
                  : '挂到「${widget.args.parentName}」下面的细分用途。',
            ),
            const SizedBox(height: YounumDimens.gapLg),

            // 当前图标预览
            Center(
              child: Container(
                width: 74,
                height: 74,
                decoration: BoxDecoration(
                  color: colors.softColor,
                  border: Border.all(color: colors.borderColor),
                  borderRadius: BorderRadius.circular(20),
                ),
                alignment: Alignment.center,
                child: _draftImageBytes != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(
                          _draftImageBytes!,
                          width: 52,
                          height: 52,
                          fit: BoxFit.cover,
                        ),
                      )
                    : CategoryIconView(
                        iconKey: _draftIconKey,
                        size: 42,
                        color: colors.primaryColor,
                      ),
              ),
            ),
            const SizedBox(height: YounumDimens.gapLg),

            const YounumFieldLabel('分类名称'),
            YounumTextField(
              controller: _nameController,
              hintText: _parentId == null ? '例如：宠物、学习成长' : '例如：咖啡茶饮',
              maxLength: 12,
              readOnly: !_nameEditable,
              errorText: _errorText,
              onChanged: (value) {
                if (_errorText != null) setState(() => _errorText = null);
              },
            ),
            if (_isEditing && !_nameEditable)
              const YounumPillNote('内置分类只改图标：名称、ID、分类关系与金额都不会变化。')
            else if (_isEditing)
              const YounumPillNote(
                '可以改名和换图标：ID 不变，已经归好类的账目照旧属于它。',
              ),

            // 细分用途：一级分类下面可以自己建（需求）。
            // 入口放在这里，与「我的 → 分类管理」形成两条路都能到的局面；
            // 真正的增删改在那一页上做，免得两处各写一套。
            if (_isEditing && (_editingCategory?.isRoot ?? false)) ...<Widget>[
              const SizedBox(height: YounumDimens.gapSm),
              YounumSettingRow(
                title: '细分用途',
                subtitle: _subCategoriesSubtitle,
                icon: YounumIcons.split,
                onTap: () => context.open(
                  AppRoutes.subCategories,
                  arguments: SubCategoryArgs(
                    parentId: _editingCategory!.id,
                    parentName: _editingCategory!.name,
                  ),
                ),
              ),
            ],

            YounumSectionHeader(
              title: '预设图标',
              trailing: YounumCaptionText('跟随主题色'),
            ),
            CategoryGrid(
              columns: 6,
              semanticPrefix: '选择图标',
              items: YounumIcons.builtinCategoryKeys
                  .map(
                    (key) => YounumCategoryItem(
                      name: YounumIcons.categoryIconLabel(key),
                      iconKey: key,
                    ),
                  )
                  .toList(growable: false),
              // 草稿是 emoji（或别的非内置键）时，网格里一个都不选中 ——
              // `categoryIconLabel` 不认识它会原样返回，恰好不会误标成别的格子。
              selectedName: YounumIcons.isBuiltinCategoryKey(_draftIconKey)
                  ? YounumIcons.categoryIconLabel(_draftIconKey)
                  : null,
              onSelected: (label) {
                final key = _iconKeyByLabel[label];
                if (key == null) return;
                setState(() {
                  _draftIconKey = key;
                  _draftImageBytes = null;
                  _emojiController.clear();
                  _emojiError = null;
                  _statusMessage = '图标已预览，保存后生效';
                });
              },
            ),
            const SizedBox(height: YounumDimens.gapLg),

            // 需求：允许用户直接输入 emoji 当图标。
            // 存在 `iconKey` 里（类型仍是「内置」）—— 不改表结构，
            // 旧版本读到它只是回退成默认图标，不会崩。
            YounumSectionHeader(title: '或者自己填一个 emoji'),
            YounumTextField(
              controller: _emojiController,
              hintText: '例如 🍜 🐱 ✈️',
              maxLength: CategoryRules.maxEmojiIconLength,
              errorText: _emojiError,
              onChanged: _onEmojiChanged,
            ),
            const YounumPillNote(
              'emoji 不跟随主题色，会以本来的样子显示在各处。',
            ),
            const SizedBox(height: YounumDimens.gapLg),

            PrimaryAction(
              label: _processing ? '正在处理图片…' : '从图片选择',
              icon: YounumIcons.upload,
              style: YounumActionStyle.secondary,
              onPressed: (_processing || !_canPickImage) ? null : _pickImage,
            ),
            if (_canPickImage)
              const YounumPillNote(
                'PNG / JPG / WebP · 最大 2 MB\n图片居中裁成方形，保留原色，仅存于此设备',
              )
            else
              const YounumPillNote(
                '这个平台上还不能选择图片（桌面与测试环境）；手机上可以。',
              ),
            PrimaryAction(
              label: '恢复默认图标',
              style: YounumActionStyle.plain,
              onPressed: () => setState(() {
                _draftIconKey = CategoryRegistry.defaultIconKeyOf(
                  _editingCategory?.name ?? widget.args.categoryName,
                );
                _draftImageBytes = null;
                _emojiController.clear();
                _emojiError = null;
                _statusMessage = '已恢复默认图标，保存后生效';
              }),
            ),
            if (_statusMessage.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _statusMessage,
                  textAlign: TextAlign.center,
                  style: text.caption.copyWith(color: colors.primaryColor),
                ),
              ),
            PrimaryAction(
              label: _saving
                  ? '正在保存…'
                  : (_processing
                        ? '图片处理中…'
                        : (_isEditing
                              ? '保存图标'
                              : (_parentId == null ? '保存分类' : '保存细分用途'))),
              onPressed: _canSave ? _save : null,
            ),

            // 合并（指南 3.5.8）。放在删除 / 归档之前：
            // 比起「删掉一个分类」，用户更常想要的其实是「这两个其实是一回事」。
            if (_isEditing && _editingCategory != null) ...<Widget>[
              const SizedBox(height: YounumDimens.gapLg),
              PrimaryAction(
                label: _saving ? '正在合并…' : '合并到其他分类',
                style: YounumActionStyle.plain,
                onPressed: (_saving || _processing || _mergeBlockedReason != null)
                    ? null
                    : _merge,
              ),
              YounumPillNote(
                _mergeBlockedReason ??
                    '把「${_editingCategory!.name}」上的账目全部归到另一个同层级的分类，'
                        '然后把空掉的它归档。不能撤销。',
              ),
            ],

            // 删除 / 归档（指南 3.5.8）。只对已有分类显示 ——
            // 还在新建的东西没什么可删的。
            if (_isEditing && _editingCategory != null) ...<Widget>[
              const SizedBox(height: YounumDimens.gapLg),
              PrimaryAction(
                label: _editingCategory!.isBuiltin ? '归档此分类' : '删除此分类',
                style: YounumActionStyle.danger,
                onPressed: (_saving || _processing || _archiveBlockedReason != null)
                    ? null
                    : _archive,
              ),
              YounumPillNote(
                _archiveBlockedReason ??
                    '删除等于归档：分类不再出现在选择列表里，'
                        '但已经归好类的记录照旧显示它，也能在分类管理底部恢复。',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

