import 'package:flutter/material.dart';

import '../designsystem/younum_colors.dart';
import '../designsystem/younum_dimens.dart';
import '../designsystem/younum_text.dart';
import 'list_row.dart';

/// 一个可选的分类。
class YounumCategoryItem {
  const YounumCategoryItem({required this.name, required this.iconKey, this.imagePath});

  final String name;
  final String iconKey;

  /// 阶段 4 接入的自定义图片资源路径。
  final String? imagePath;
}

/// 分类选择网格。
///
/// 满足指南 6.1：
/// * 图标 + 文本，**不能仅用颜色区分**；
/// * 选中态同时有边框、勾选标记与语义状态，TalkBack 能读出「已选中」。
class CategoryGrid extends StatelessWidget {
  const CategoryGrid({
    super.key,
    required this.items,
    this.selectedName,
    this.onSelected,
    this.columns = 4,
    this.semanticPrefix = '选择用途',
  });

  final List<YounumCategoryItem> items;
  final String? selectedName;
  final ValueChanged<String>? onSelected;
  final int columns;
  final String semanticPrefix;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = YounumDimens.categoryGridGap;
        final itemWidth = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: items
              .map(
                (item) => SizedBox(
                  width: itemWidth,
                  child: _CategoryCell(
                    item: item,
                    selected: item.name == selectedName,
                    onTap: onSelected == null ? null : () => onSelected!(item.name),
                    semanticPrefix: semanticPrefix,
                  ),
                ),
              )
              .toList(growable: false),
        );
      },
    );
  }
}

class _CategoryCell extends StatelessWidget {
  const _CategoryCell({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.semanticPrefix,
  });

  final YounumCategoryItem item;
  final bool selected;
  final VoidCallback? onTap;
  final String semanticPrefix;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final text = YounumText.of(context);

    return Semantics(
      selected: selected,
      button: onTap != null,
      label: '$semanticPrefix ${item.name}',
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
          overlayColor: WidgetStatePropertyAll<Color>(
            colors.pressedColor.withValues(alpha: 0.10),
          ),
          child: Container(
            constraints: const BoxConstraints(
              minHeight: YounumDimens.categoryCellMinHeight,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 10),
            decoration: BoxDecoration(
              color: selected ? colors.softColor : const Color(YounumColors.surface),
              border: Border.all(
                color: selected ? colors.primaryColor : const Color(YounumColors.line),
                width: selected ? 1.4 : 1,
              ),
              borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    CategoryIconView(
                      iconKey: item.iconKey,
                      imagePath: item.imagePath,
                      size: YounumDimens.categoryIconSize,
                      color: selected ? colors.primaryColor : colors.inkColor,
                    ),
                    if (selected)
                      Positioned(
                        right: -10,
                        top: -6,
                        child: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            color: colors.primaryColor,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.check,
                            size: 10,
                            color: colors.onPrimaryColor,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.caption.copyWith(
                    color: selected ? colors.primaryColor : colors.inkColor,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
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

/// 细分用途标签。
class YounumChip extends StatelessWidget {
  const YounumChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.leadingIconKey,
    this.leadingImagePath,
    this.semanticPrefix = '选择用途',
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final String? leadingIconKey;
  final String? leadingImagePath;
  final String semanticPrefix;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final text = YounumText.of(context);
    return Semantics(
      selected: selected,
      button: onTap != null,
      label: '$semanticPrefix $label',
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall + 2),
          overlayColor: WidgetStatePropertyAll<Color>(
            colors.pressedColor.withValues(alpha: 0.10),
          ),
          child: Container(
            constraints: const BoxConstraints(minHeight: 40, minWidth: 44),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: selected ? colors.primaryColor : colors.softColor,
              borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall + 2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (leadingIconKey != null) ...<Widget>[
                  CategoryIconView(
                    iconKey: leadingIconKey!,
                    imagePath: leadingImagePath,
                    size: 16,
                    color: selected ? colors.onPrimaryColor : colors.primaryColor,
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  style: text.caption.copyWith(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? colors.onPrimaryColor : colors.primaryColor,
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

/// 分段切换（导出指引里的「微信支付 / 支付宝」）。
class YounumToggleGroup extends StatelessWidget {
  const YounumToggleGroup({
    super.key,
    required this.options,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<String> options;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final text = YounumText.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.softColor,
        borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
      ),
      child: Row(
        children: <Widget>[
          for (var index = 0; index < options.length; index++)
            Expanded(
              child: Semantics(
                selected: index == selectedIndex,
                button: true,
                label: options[index],
                excludeSemantics: true,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => onSelected(index),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 44),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: index == selectedIndex
                            ? const Color(YounumColors.surface)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        options[index],
                        style: text.label.copyWith(
                          color: index == selectedIndex
                              ? colors.primaryColor
                              : colors.mutedColor,
                          fontWeight: index == selectedIndex
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
