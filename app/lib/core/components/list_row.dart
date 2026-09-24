import 'dart:io';

import 'package:flutter/material.dart';

import '../designsystem/younum_colors.dart';
import '../designsystem/younum_dimens.dart';
import '../designsystem/younum_icons.dart';
import '../designsystem/younum_text.dart';
import 'buttons.dart';

/// 图标底色。
enum YounumTileTone { primary, neutral, blue, purple }

/// 分类图标。
///
/// 阶段 1 只渲染内置矢量图标；阶段 4 接入自定义图片时，把 [imagePath] 填上即可，
/// 无需改动任何调用点 —— 这满足了指南 14.4.7「所有页面从同一个分类仓库解析资源」。
///
/// 图片缺失或损坏时**必须**回退到内置图标，不能抛出异常（指南 14.4.8）。
class CategoryIconView extends StatelessWidget {
  const CategoryIconView({
    super.key,
    required this.iconKey,
    this.imagePath,
    this.size = YounumDimens.categoryIconSize,
    this.color,
  });

  /// 内置图标键。未知键会回退到默认叶片图标。
  final String iconKey;

  /// 应用私有目录下的图片资源相对路径。为 null 表示使用内置图标。
  final String? imagePath;

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved = iconKey.isEmpty ? YounumIcons.defaultCategoryIconKey : iconKey;
    final path = imagePath;
    if (path != null && path.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Image.file(
          File(path),
          width: size,
          height: size,
          fit: BoxFit.cover,
          // 图片被删除或损坏时回退，保留分类名称与全部账目数据。
          errorBuilder: (context, error, stackTrace) =>
              Icon(YounumIcons.categoryIcon(resolved), size: size, color: color),
        ),
      );
    }
    return Icon(YounumIcons.categoryIcon(resolved), size: size, color: color);
  }
}

/// 圆角方形图标底。
class YounumTileIcon extends StatelessWidget {
  const YounumTileIcon({
    super.key,
    required this.iconKey,
    this.imagePath,
    this.tone = YounumTileTone.primary,
    this.size = YounumDimens.tileIconSize,
    this.icon,
  });

  final String? iconKey;
  final String? imagePath;
  final YounumTileTone tone;
  final double size;

  /// 覆盖图标（用于「我的」页引用的功能图标，而非分类图标）。
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final (Color background, Color foreground) = switch (tone) {
      YounumTileTone.primary => (colors.softColor, colors.primaryColor),
      YounumTileTone.neutral => (
          const Color(YounumColors.neutralTile),
          const Color(YounumColors.neutralOnTile),
        ),
      YounumTileTone.blue => (
          const Color(YounumColors.blueTile),
          const Color(YounumColors.blueOnTile),
        ),
      YounumTileTone.purple => (
          const Color(YounumColors.purpleTile),
          const Color(YounumColors.purpleOnTile),
        ),
    };

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(YounumDimens.radiusTile),
      ),
      alignment: Alignment.center,
      child: icon != null
          ? Icon(icon, size: size * 0.5, color: foreground)
          : CategoryIconView(
              iconKey: iconKey ?? YounumIcons.defaultCategoryIconKey,
              imagePath: imagePath,
              size: size * 0.5,
              color: foreground,
            ),
    );
  }
}

/// 通用列表行。
///
/// 整行可点，点击区域高度 ≥ 56dp，满足最小触控目标。
class YounumListRow extends StatelessWidget {
  const YounumListRow({
    super.key,
    required this.title,
    this.iconKey,
    this.icon,
    this.imagePath,
    this.iconTone = YounumTileTone.primary,
    this.subtitle,
    this.subtitleWidget,
    this.trailingText,
    this.trailingWidget,
    this.onTap,
    this.showDivider = true,
    this.leading,
    this.semanticLabel,
  });

  final String title;
  final String? iconKey;
  final IconData? icon;
  final String? imagePath;
  final YounumTileTone iconTone;
  final String? subtitle;
  final Widget? subtitleWidget;
  final String? trailingText;
  final Widget? trailingWidget;
  final VoidCallback? onTap;
  final bool showDivider;

  /// 完全自定义的前置内容（例如排名数字）。
  final Widget? leading;

  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final colors = YounumColors.of(context);

    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      child: Row(
        children: <Widget>[
          if (leading != null) ...<Widget>[
            leading!,
            const SizedBox(width: 8),
          ] else ...<Widget>[
            YounumTileIcon(
              iconKey: iconKey,
              imagePath: imagePath,
              tone: iconTone,
              icon: icon,
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: text.listPrimary),
                if (subtitleWidget != null) ...<Widget>[
                  const SizedBox(height: 4),
                  subtitleWidget!,
                ] else if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: text.listSecondary,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (trailingWidget != null)
            trailingWidget!
          else if (trailingText != null)
            Text(
              trailingText!,
              style: text.body.copyWith(color: colors.mutedColor),
            ),
        ],
      ),
    );

    final content = showDivider
        ? Column(
            children: <Widget>[
              row,
              Container(height: 1, color: const Color(YounumColors.rowLine)),
            ],
          )
        : row;

    if (onTap == null) return content;

    return YounumPressable(
      onTap: onTap,
      semanticLabel: semanticLabel ??
          <String?>[title, subtitle, trailingText].whereType<String>().join('，'),
      borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
      child: content,
    );
  }
}

/// 「我的」页里的设置入口行：图标 + 标题 + 说明 + 右侧箭头。
class YounumSettingRow extends StatelessWidget {
  const YounumSettingRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    return YounumListRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      onTap: onTap,
      trailingWidget: ExcludeSemantics(
        child: Icon(
          YounumIcons.chevronRight,
          size: YounumDimens.iconMd,
          color: colors.mutedColor,
        ),
      ),
      semanticLabel: '$title，$subtitle',
    );
  }
}
