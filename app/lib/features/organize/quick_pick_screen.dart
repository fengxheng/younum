import 'package:flutter/material.dart';

import '../../core/components/buttons.dart';
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

/// 用途快捷项：整理卡片上显示**哪几个**分类、按**什么顺序**。
///
/// 为什么需要它：卡片上那 8 个原来是写死的（只放内置一级分类），用户既不能
/// 换掉其中一个，也不能把最常用的挪到第一格。而「第几个」是有实际差别的 ——
/// 每次整理都要扫一遍这一格子。
///
/// 上限仍是 [CategoryRules.quickPickLimit] 个（8 个 = 两行），这不是可以商量的
/// 数字：确认按钮与「撤销 / 稍后 / 更多操作」必须留在屏幕上（指南 6.2）。
/// 所以这里给的是「哪 8 个 + 什么顺序」的自由，而不是「想加多少加多少」。
class QuickPickScreen extends StatelessWidget {
  const QuickPickScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final registry = CategoryRegistryScope.of(context);
    final picked = registry.quickPick;
    final pickedIds = <int>{for (final category in picked) category.id};
    // 能加进来的：未归档的一级分类里，还没被选中的那些。
    final candidates = <Category>[
      for (final category in registry.roots)
        if (!pickedIds.contains(category.id)) category,
    ];
    final full = picked.length >= CategoryRules.quickPickLimit;
    // 至少留一个：空了之后整理一笔要先进「全部分类」，多一步。
    final canRemove = picked.length > 1;

    Future<void> save(List<int> ids) async {
      final ok = await registry.setQuickPick(ids);
      if (!context.mounted) return;
      if (ok) return;
      // 存不下来就说清楚：用户调完顺序、下次进来又变回原样，
      // 比一次明确的失败提示糟糕得多。
      showYounumToast(context, registry.lastFailure ?? '这次没保存下来，请再试一次');
    }

    Future<void> reorder(int oldIndex, int newIndex) async {
      final ids = <int>[for (final category in picked) category.id];
      // 用 `onReorderItem`（不是已弃用的 `onReorder`）：
      // 框架已经替我们扣掉了「取出后索引前移」那一位，这里直接插就行。
      final moved = ids.removeAt(oldIndex);
      ids.insert(newIndex, moved);
      await save(ids);
    }

    return YounumScreen(
      title: '用途快捷项',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('挑几个顺手的用途。', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText(
            '整理一笔时，卡片上只显示这里的几个。按住右侧的手柄可以拖动排序，'
            '最常用的放前面。',
          ),
          const SizedBox(height: YounumDimens.gapLg),

          YounumSectionHeader(
            title:
                '显示在卡片上（${picked.length}/${CategoryRules.quickPickLimit}）',
          ),
          ReorderableListView(
            // 页面本身是可滚动的（YounumScreen），所以这里不再自己滚：
            // 两个滚动容器套在一起，拖动时会互相抢手势。
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            onReorderItem: reorder,
            // 整行都能拖会和行内按钮抢手势，所以只认手柄。
            buildDefaultDragHandles: false,
            children: <Widget>[
              for (var index = 0; index < picked.length; index++)
                _PickedRow(
                  key: ValueKey<int>(picked[index].id),
                  index: index,
                  category: picked[index],
                  imagePath: registry.imagePathOf(picked[index]),
                  onRemove: canRemove
                      ? () => save(<int>[
                          for (final category in picked)
                            if (category.id != picked[index].id) category.id,
                        ])
                      : null,
                ),
            ],
          ),
          if (!canRemove)
            const YounumPillNote('至少留一个：全空的话，整理一笔要先点进「全部分类」'),

          if (candidates.isNotEmpty) ...<Widget>[
            const SizedBox(height: YounumDimens.gapLg),
            const YounumSectionHeader(title: '还可以加进来'),
            if (full)
              const YounumPillNote(
                '快捷项已经满了：先移除一个，再加新的',
              ),
            for (final category in candidates)
              YounumListRow(
                title: category.name,
                subtitle: full ? '位置满了' : '加进卡片',
                iconKey: category.iconKey,
                imagePath: registry.imagePathOf(category),
                trailingText: full ? '已满' : '添加',
                // 满了就把这一行置灰并说明，而不是让用户点下去才被拒
                // （与名称校验、归档同一条原则）。
                onTap: full ? null : () => save(<int>[...pickedIds, category.id]),
              ),
          ],

          const SizedBox(height: YounumDimens.gapLg),
          const YounumPanel(
            tone: YounumPanelTone.soft,
            child: YounumMutedText(
              '细分用途不在这里：它们从「全部分类」里选。'
              '改这份列表不会影响任何已有账目。',
            ),
          ),
        ],
      ),
    );
  }
}

/// 已选中的一行：图标 + 名字 + 移除 + 拖动柄。
class _PickedRow extends StatelessWidget {
  const _PickedRow({
    super.key,
    required this.index,
    required this.category,
    required this.imagePath,
    required this.onRemove,
  });

  final int index;
  final Category category;
  final String? imagePath;

  /// 为 null 表示不能移除（只剩一个了）。
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final text = YounumText.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: YounumDimens.gapSm),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: colors.softColor,
        borderRadius: BorderRadius.circular(YounumDimens.radiusControl),
      ),
      child: Row(
        children: <Widget>[
          YounumTileIcon(
            iconKey: category.iconKey,
            imagePath: imagePath,
            size: 34,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              category.name,
              style: text.listPrimary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          YounumPressable(
            onTap: onRemove,
            semanticLabel: '把「${category.name}」移出快捷项',
            borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Text(
                '移除',
                style: text.label.copyWith(
                  color: onRemove == null
                      ? colors.mutedColor
                      : colors.primaryColor,
                ),
              ),
            ),
          ),
          ReorderableDragStartListener(
            index: index,
            child: ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Icon(
                  YounumIcons.dragHandle,
                  size: YounumDimens.iconMd,
                  color: colors.mutedColor,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
