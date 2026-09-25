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

  /// 最终生效的选择：细分用途优先。
  String _effective(String selectedName) => _selectedSubcategory ?? selectedName;

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
            items: <YounumCategoryItem>[
              for (final category in roots)
                YounumCategoryItem(
                  name: category.name,
                  iconKey:
                      category.iconKey ?? YounumIcons.defaultCategoryIconKey,
                ),
            ],
            selectedName: selectedName,
            onSelected: (name) => setState(() {
              _selectedCategory = name;
              _selectedSubcategory = null;
            }),
          ),
          YounumSectionHeader(title: '$selectedName · 细分用途'),
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
                    onTap: () => setState(
                      () => _selectedSubcategory =
                          _selectedSubcategory == child.name ? null : child.name,
                    ),
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
                    onTap: () => setState(
                      () => _selectedSubcategory =
                          _selectedSubcategory == category.name
                              ? null
                              : category.name,
                    ),
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
                children: <Widget>[
                  for (final category in registry.roots)
                    SizedBox(
                      width: width,
                      child: _ManageCategoryCard(
                        entry: YounumCategoryItem(
                          name: category.name,
                          iconKey: category.iconKey ??
                              YounumIcons.defaultCategoryIconKey,
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
          const YounumDemoNote(
            '分类与图标存在本机数据库里，重启之后仍然在；改图标不会改动'
            '消费金额、分类关系与整理进度。图片图标还没做（只支持预设线条图标）。',
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
  String? _errorText;
  String _statusMessage = '';

  /// 正在写库。写完之前按钮要保持不可点（指南 14.3）。
  bool _saving = false;

  bool get _isEditing => widget.args.categoryId != null;

  @override
  void initState() {
    super.initState();
    // 读当前的已提交图标作为草稿起点；草稿只有按「保存」才会写库。
    final categoryId = widget.args.categoryId;
    _draftIconKey = categoryId == null
        ? YounumIcons.defaultCategoryIconKey
        : _registry.byId(categoryId)?.iconKey ??
              YounumIcons.defaultCategoryIconKey;
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
    final categoryId = widget.args.categoryId;
    if (categoryId == null) return false;
    final committed = _registry.byId(categoryId)?.iconKey;
    return committed != null && committed != _draftIconKey;
  }

  /// 名称校验走规则层：界面与仓库用同一份判断，
  /// 不会出现「界面放行、写库被拒」这种两套说法。
  bool _validateName(String name) {
    final error = CategoryRules.validateName(
      name: name,
      siblings: _registry.roots,
    );
    setState(() => _errorText = error?.message);
    return error == null;
  }

  Future<void> _save() async {
    if (_saving) return;
    final registry = _registry;
    final categoryId = widget.args.categoryId;
    if (categoryId == null && !_validateName(_nameController.text)) return;

    setState(() => _saving = true);
    final ok = categoryId == null
        ? await registry.create(
            name: _nameController.text.trim(),
            iconKey: _draftIconKey,
          )
        : await registry.setIcon(
            categoryId: categoryId,
            iconKey: _draftIconKey,
          );
    if (!mounted) return;
    setState(() => _saving = false);

    if (!ok) {
      // 失败要说清原因，而且**不能**返回上一页 —— 否则用户以为存上了。
      setState(
        () => _errorText = registry.lastFailure ?? '没有保存成功，可以重试',
      );
      return;
    }
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
                _draftIconKey = CategoryRegistry.defaultIconKeyOf(
                  widget.args.categoryName,
                );
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
              onPressed: _saving ? null : _save,
            ),
          ],
        ),
      ),
    );
  }
}
