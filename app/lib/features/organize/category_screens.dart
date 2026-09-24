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
import '../../data/sample/sample_data.dart';
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
  late String _selectedCategory =
      _isBuiltin(widget.args.currentCategory) ? widget.args.currentCategory! : '餐饮';
  String? _selectedSubcategory;

  static bool _isBuiltin(String? name) =>
      name != null && SampleData.categories.any((c) => c.name == name);

  /// 最终生效的选择：细分用途优先。
  String get _effective => _selectedSubcategory ?? _selectedCategory;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final registry = CategoryRegistryScope.of(context);

    return YounumScreen(
      title: '选择用途',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('生活，不止一种分类', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText('先选大类，也可以进一步记录细分用途。'),
          const SizedBox(height: YounumDimens.gapLg),
          CategoryGrid(
            items: SampleData.categories
                .map(
                  (category) => YounumCategoryItem(
                    name: category.name,
                    iconKey: registry
                        .iconFor(category.name, fallbackIconKey: category.iconKey)
                        .iconKey,
                    imagePath: registry.iconFor(category.name).imagePath,
                  ),
                )
                .toList(growable: false),
            selectedName: _selectedCategory,
            onSelected: (name) => setState(() {
              _selectedCategory = name;
              _selectedSubcategory = null;
            }),
          ),
          YounumSectionHeader(title: '$_selectedCategory · 细分用途'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: SampleData.diningSubcategories
                .map(
                  (name) => YounumChip(
                    label: name,
                    selected: _selectedSubcategory == name,
                    onTap: () => setState(
                      () => _selectedSubcategory = _selectedSubcategory == name ? null : name,
                    ),
                  ),
                )
                .toList(growable: false),
          ),
          const YounumDivider(),
          YounumSectionHeader(
            title: '我的分类',
            trailing: YounumPressable(
              onTap: () => context.open(AppRoutes.categoryManage),
              semanticLabel: '管理分类图标',
              borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                child: Text(
                  '管理图标 ›',
                  style: text.label.copyWith(color: YounumColors.of(context).primaryColor),
                ),
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: registry.customNames
                .map(
                  (name) => YounumChip(
                    label: name,
                    selected: _selectedSubcategory == name,
                    leadingIconKey: registry.iconFor(name).iconKey,
                    leadingImagePath: registry.iconFor(name).imagePath,
                    onTap: () => setState(
                      () => _selectedSubcategory = _selectedSubcategory == name ? null : name,
                    ),
                  ),
                )
                .toList(growable: false),
          ),
          const SizedBox(height: YounumDimens.gapXl),
          PrimaryAction(
            label: '使用此分类 · $_effective',
            onPressed: () {
              switch (widget.args.purpose) {
                case CategoryPickPurpose.card:
                  ReviewSessionScope.of(context).select(_effective);
                  Navigator.of(context).pop();
                case CategoryPickPurpose.detail:
                case CategoryPickPurpose.splitItem:
                  // 返回选中值给调用方，而不是替它决定后续跳转。
                  Navigator.of(context).pop(_effective);
              }
            },
          ),
        ],
      ),
    );
  }
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

    final entries = <YounumCategoryItem>[
      ...SampleData.categories.map(
        (category) => YounumCategoryItem(
          name: category.name,
          iconKey: registry.iconFor(category.name, fallbackIconKey: category.iconKey).iconKey,
          imagePath: registry.iconFor(category.name).imagePath,
        ),
      ),
      ...registry.customNames.map(
        (name) => YounumCategoryItem(
          name: name,
          iconKey: registry.iconFor(name).iconKey,
          imagePath: registry.iconFor(name).imagePath,
        ),
      ),
    ];

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
          LayoutBuilder(
            builder: (context, constraints) {
              const spacing = 10.0;
              final width = (constraints.maxWidth - spacing) / 2;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: entries
                    .map(
                      (entry) => SizedBox(
                        width: width,
                        child: _ManageCategoryCard(
                          entry: entry,
                          onTap: () => context.open(
                            AppRoutes.categoryEditor,
                            arguments: CategoryEditorArgs(categoryName: entry.name),
                          ),
                        ),
                      ),
                    )
                    .toList(growable: false),
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
          const YounumDemoNote(
            '设计走查：图标修改会立即在分类网格与本页生效。'
            '阶段 4 接入系统 Photo Picker 与私有文件写入后，重启也会保留。',
          ),
        ],
      ),
    );
  }
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
  String? _draftImagePath;
  String? _errorText;
  String _statusMessage = '';

  /// 图片处理中必须禁用保存（指南 14.3）。
  ///
  /// 首版只支持预设图标，因此恒为 false；阶段 4 接入 Photo Picker 后
  /// 由异步解码过程控制。
  final bool _processing = false;

  bool get _isEditing => widget.args.categoryName != null;

  @override
  void initState() {
    super.initState();
    final registry = _registry;
    final config = _isEditing
        ? registry.iconFor(
            widget.args.categoryName!,
            fallbackIconKey: SampleData.iconKeyFor(widget.args.categoryName!),
          )
        : const CategoryIconConfig.builtin(YounumIcons.defaultCategoryIconKey);
    _draftIconKey = config.iconKey;
    _draftImagePath = config.imagePath;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// 读取注册表。
  ///
  /// 编辑器里改动的都是本地草稿，因此这里不需要订阅注册表的变化，
  /// 用非订阅式读取即可（`initState` 也不允许订阅）。
  CategoryRegistry get _registry => CategoryRegistryScope.read(context);

  /// 是否存在未保存的草稿。
  bool get _isDirty {
    if (!_isEditing) return false;
    final committed = _registry.iconFor(
      widget.args.categoryName!,
      fallbackIconKey: SampleData.iconKeyFor(widget.args.categoryName!),
    );
    return committed.iconKey != _draftIconKey ||
        committed.imagePath != _draftImagePath;
  }

  bool _validateName(String name) {
    if (name.isEmpty) {
      setState(() => _errorText = '请先填写分类名称');
      return false;
    }
    // 名称限 1–12 个文字、数字、空格或短横线，与原型校验一致。
    final pattern = RegExp(r'^[\p{L}\p{N} _-]{1,12}$', unicode: true);
    if (!pattern.hasMatch(name)) {
      setState(() => _errorText = '名称限 1–12 个文字、数字、空格或短横线');
      return false;
    }
    final builtinNames = SampleData.categories.map((c) => c.name);
    if (!_isEditing && _registry.exists(name, builtinNames)) {
      setState(() => _errorText = '这个分类已经存在');
      return false;
    }
    setState(() => _errorText = null);
    return true;
  }

  Future<void> _save() async {
    if (_processing) return;
    final name = _isEditing ? widget.args.categoryName! : _nameController.text.trim();
    if (!_validateName(name)) return;

    final config = CategoryIconConfig.builtin(_draftIconKey);
    if (_isEditing) {
      _registry.saveIcon(name, config);
    } else {
      _registry.createCategory(name, config);
    }
    if (!mounted) return;
    showYounumToast(context, _isEditing ? '分类图标已保存' : '分类已保存');
    Navigator.of(context).pop();
  }

  Future<bool> _confirmDiscard() async {
    if (!_isDirty) return true;
    return showConfirmSheet(
      context: context,
      title: '放弃未保存的修改？',
      description: '你选择的图标还没有保存，离开后这次修改会丢失。已提交的图标不受影响。',
      confirmLabel: '放弃修改',
      cancelLabel: '继续编辑',
    );
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
        title: _isEditing ? '编辑分类图标' : '新建分类',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              _isEditing ? '给分类换个新模样' : '让分类，更像你',
              style: text.screenTitle,
            ),
            const SizedBox(height: YounumDimens.gapSm),
            YounumMutedText('选择一个图标，或用自己的图片。'),
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
                child: CategoryIconView(
                  iconKey: _draftIconKey,
                  imagePath: _draftImagePath,
                  size: 42,
                  color: colors.primaryColor,
                ),
              ),
            ),
            const SizedBox(height: YounumDimens.gapLg),

            const YounumFieldLabel('分类名称'),
            YounumTextField(
              controller: _nameController,
              hintText: '例如：宠物、学习成长',
              maxLength: 12,
              readOnly: _isEditing,
              errorText: _errorText,
              onChanged: (value) {
                if (_errorText != null) setState(() => _errorText = null);
              },
            ),
            if (_isEditing)
              const YounumPillNote('编辑已有分类时只改图标：名称、ID、分类关系与金额都不会变化。'),

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
              selectedName: YounumIcons.categoryIconLabel(_draftIconKey),
              onSelected: (label) {
                final key = YounumIcons.builtinCategoryKeys.firstWhere(
                  (candidate) => YounumIcons.categoryIconLabel(candidate) == label,
                );
                setState(() {
                  _draftIconKey = key;
                  _draftImagePath = null;
                  _statusMessage = '图标已预览，保存后生效';
                });
              },
            ),
            const SizedBox(height: YounumDimens.gapLg),

            PrimaryAction(
              label: '从图片选择',
              icon: YounumIcons.upload,
              style: YounumActionStyle.secondary,
              onPressed: () => showYounumToast(
                context,
                '阶段 4 接入系统 Photo Picker 后可用；当前只支持预设图标',
              ),
            ),
            const YounumPillNote(
              'PNG / JPG / WebP · 最大 2 MB\n图片居中裁成方形，保留原色，仅存于此设备',
            ),
            PrimaryAction(
              label: '恢复默认图标',
              style: YounumActionStyle.plain,
              onPressed: () => setState(() {
                _draftIconKey = _isEditing
                    ? SampleData.iconKeyFor(widget.args.categoryName!)
                    : YounumIcons.defaultCategoryIconKey;
                _draftImagePath = null;
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
              label: _isEditing ? '保存图标' : '保存分类',
              onPressed: _processing ? null : _save,
            ),
          ],
        ),
      ),
    );
  }
}
