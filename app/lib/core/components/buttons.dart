import 'package:flutter/material.dart';

import '../designsystem/younum_colors.dart';
import '../designsystem/younum_dimens.dart';
import '../designsystem/younum_text.dart';

/// 按钮样式族。对应原型的 `.primary` / `.secondary` / `.danger` / `.plain`。
enum YounumActionStyle {
  /// 主操作：主题主色实底。
  primary,

  /// 次操作：主题淡色底 + 主色文字。
  secondary,

  /// 破坏性操作：固定危险色，**不随主题变化**（指南 7.3）。
  danger,

  /// 轻量文字按钮。
  plain,
}

/// 统一的可点击容器。
///
/// 所有按钮与列表行都经过这里，从而一次性满足：
/// * 最小触控目标 48×48dp（指南 6.2）；
/// * 明确的 TalkBack 角色与标签（指南 6.3）；
/// * 禁用态不响应点击，也不会被误报为可操作。
class YounumPressable extends StatelessWidget {
  const YounumPressable({
    super.key,
    required this.onTap,
    required this.child,
    this.borderRadius,
    this.semanticLabel,
    this.semanticButton = true,
    this.enabled = true,
  });

  /// 为 null 或 [enabled] 为 false 时不可点击。
  final VoidCallback? onTap;
  final Widget child;
  final BorderRadius? borderRadius;
  final String? semanticLabel;
  final bool semanticButton;
  final bool enabled;

  bool get _active => enabled && onTap != null;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final radius = borderRadius ?? BorderRadius.circular(YounumDimens.radiusControl);
    return Semantics(
      button: semanticButton,
      label: semanticLabel,
      enabled: _active,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _active ? onTap : null,
          borderRadius: radius,
          overlayColor: WidgetStatePropertyAll<Color>(
            colors.pressedColor.withValues(alpha: 0.10),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 主要操作按钮。
class PrimaryAction extends StatelessWidget {
  const PrimaryAction({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.trailingArrow = false,
    this.style = YounumActionStyle.primary,
    this.semanticLabel,
  });

  final String label;
  final VoidCallback? onPressed;

  /// 前置图标。
  final IconData? icon;

  /// 是否显示尾部箭头（原型多处使用「继续整理 →」）。
  final bool trailingArrow;

  final YounumActionStyle style;

  /// 覆盖朗读文本。图标按钮必须提供明确名称（指南 6.3）。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final text = YounumText.of(context);
    final enabled = onPressed != null;

    final (Color background, Color foreground) = switch (style) {
      YounumActionStyle.primary => (colors.primaryColor, colors.onPrimaryColor),
      YounumActionStyle.secondary => (colors.softColor, colors.primaryColor),
      YounumActionStyle.danger => (
          const Color(YounumColors.dangerContainer),
          const Color(YounumColors.danger),
        ),
      YounumActionStyle.plain => (Colors.transparent, colors.primaryColor),
    };

    final content = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          ExcludeSemantics(child: Icon(icon, size: YounumDimens.iconMd)),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Text(
            label,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: text.button.copyWith(color: foreground),
          ),
        ),
        if (trailingArrow) ...<Widget>[
          const SizedBox(width: 8),
          ExcludeSemantics(
            child: Icon(Icons.arrow_forward, size: YounumDimens.iconSm, color: foreground),
          ),
        ],
      ],
    );

    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: YounumPressable(
        onTap: onPressed,
        enabled: enabled,
        semanticLabel: semanticLabel ?? label,
        borderRadius: BorderRadius.circular(YounumDimens.radiusControl),
        child: Container(
          constraints: const BoxConstraints(
            minHeight: YounumDimens.primaryButtonHeight,
            minWidth: YounumDimens.minTouchTarget,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(YounumDimens.radiusControl),
          ),
          child: content,
        ),
      ),
    );
  }
}

/// 无底色的轻量文字按钮。
///
/// 用于「月份 ⌄」「详情 ›」这类行内入口。原先首页与月报各有一份几乎相同的实现，
/// 已在需要给月份入口加矢量图标时合并到这里，避免两边行为不一致。
class PlainTextButton extends StatelessWidget {
  const PlainTextButton({
    super.key,
    required this.label,
    required this.onTap,
    this.trailingIcon,
    this.iconSize = YounumDimens.iconMd,
    this.semanticLabel,
  });

  final String label;
  final VoidCallback onTap;

  /// 尾部图标。
  ///
  /// 必须用矢量图标而不是 Unicode 字符（例如 `⌄`）：生僻字形会落到系统回退字体，
  /// 尺寸、基线与左右边距都不受控，看起来会又小又偏。
  final IconData? trailingIcon;

  final double iconSize;

  /// 覆盖朗读文本。带图标的入口应把图标的含义说清楚，例如「切换月份」。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    return YounumPressable(
      onTap: onTap,
      semanticLabel: semanticLabel ?? label,
      borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
      child: ConstrainedBox(
        // 最小高度 44 保证触控目标（指南 6.3），但**宽度必须贴着内容**。
        //
        // 这里原来是 `Container(alignment: Alignment.center)` —— 带 `alignment`
        // 的 Container 在**有界**宽度下会撑满父级，于是把它放进 `Wrap` 时会占掉
        // 整行，同一行的其它内容被挤到下一行居中（首页右上角的「9月」就这么
        // 跑到第二行去了）。放在 `Row` 里时本来就不给宽度上限，所以看不出来。
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            // 图标与文字对齐到同一条水平中线，避免出现偏上 / 偏下的观感。
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Text(
                label,
                style: YounumText.of(context).label.copyWith(color: colors.primaryColor),
              ),
              if (trailingIcon != null) ...<Widget>[
                const SizedBox(width: 4),
                ExcludeSemantics(
                  child: Icon(trailingIcon, size: iconSize, color: colors.primaryColor),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 圆形图标按钮。
///
/// 视觉直径 40dp，但外层撑到 48dp 以满足最小触控目标（指南 6.2）。
class YounumIconButton extends StatelessWidget {
  const YounumIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.semanticLabel,
    this.background,
    this.foreground,
  });

  final IconData icon;
  final VoidCallback? onPressed;

  /// 必填：图标按钮没有可见文字，必须给出可读名称。
  final String semanticLabel;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    return YounumPressable(
      onTap: onPressed,
      semanticLabel: semanticLabel,
      borderRadius: BorderRadius.circular(YounumDimens.minTouchTarget / 2),
      child: SizedBox(
        width: YounumDimens.minTouchTarget,
        height: YounumDimens.minTouchTarget,
        child: Center(
          child: Container(
            width: YounumDimens.iconButtonVisual,
            height: YounumDimens.iconButtonVisual,
            decoration: BoxDecoration(
              color: background ?? const Color(YounumColors.iconButton),
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              size: YounumDimens.iconMd,
              color: foreground ?? colors.inkColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// 一行里并排的轻量操作（撤销 / 稍后处理 / 更多操作）。
class YounumActionRow extends StatelessWidget {
  const YounumActionRow({super.key, required this.actions});

  final List<YounumActionRowItem> actions;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        for (final item in actions)
          Expanded(
            child: YounumPressable(
              onTap: item.onPressed,
              semanticLabel: item.label,
              borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
              child: Container(
                constraints: const BoxConstraints(minHeight: YounumDimens.minTouchTarget),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    if (item.icon != null) ...<Widget>[
                      ExcludeSemantics(
                        child: Icon(
                          item.icon,
                          size: YounumDimens.iconSm,
                          color: YounumText.of(context).label.color,
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Text(
                        item.label,
                        overflow: TextOverflow.ellipsis,
                        style: YounumText.of(context).label,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// [YounumActionRow] 的一项。
class YounumActionRowItem {
  const YounumActionRowItem({
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
}
