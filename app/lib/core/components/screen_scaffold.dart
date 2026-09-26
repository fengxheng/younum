import 'package:flutter/material.dart';

import '../../app/app_routes.dart';
import '../designsystem/younum_colors.dart';
import '../designsystem/younum_dimens.dart';
import '../designsystem/younum_icons.dart';
import '../designsystem/younum_text.dart';
import 'buttons.dart';

/// 页面骨架。
///
/// 统一处理：系统 Insets、IME Insets、横向留白、顶部导航、可选底部导航，
/// 保证金额、确认按钮与底部导航不被手势区域或键盘遮挡（实现指南 6.2）。
class YounumScreen extends StatelessWidget {
  const YounumScreen({
    super.key,
    required this.child,
    this.title,
    this.onBack,
    this.showBack = true,
    this.trailing,
    this.bottomBar,
    this.scrollable = true,
    this.padding,
    this.background,
    this.fillViewport = false,
  });

  final Widget child;

  /// 为 null 时不显示顶部导航栏。
  final String? title;

  final VoidCallback? onBack;
  final bool showBack;
  final Widget? trailing;
  final Widget? bottomBar;

  /// 页面是否自行滚动。列表页一般传 false 并自己用 `ListView`。
  final bool scrollable;

  final EdgeInsetsGeometry? padding;
  final Color? background;

  /// 内容不足时是否撑满视口剩余高度。
  ///
  /// 开启后子级可以用 `Spacer` / `MainAxisAlignment.spaceBetween` 把内容分布到
  /// 整个屏幕（欢迎页、完成页这类短页面需要）。内容超出时仍然可以滚动，
  /// 因此小屏与大字号不会被截断（指南 6.3）。
  final bool fillViewport;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final resolvedPadding = padding ??
        const EdgeInsets.fromLTRB(
          YounumDimens.pageHorizontal,
          YounumDimens.pageTop,
          YounumDimens.pageHorizontal,
          YounumDimens.pageBottom,
        );

    Widget content;
    if (!scrollable) {
      content = _withinReadingWidth(
        Padding(padding: padding ?? EdgeInsets.zero, child: child),
      );
    } else {
      content = LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          // 键盘弹出时保证输入框可见。
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: resolvedPadding,
          child: _withinReadingWidth(
            fillViewport
                ? ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight:
                          (constraints.maxHeight - resolvedPadding.vertical)
                              .clamp(0.0, double.infinity),
                    ),
                    // IntrinsicHeight 让 Column 拿到确定高度，
                    // 这样 spaceBetween / Spacer 在「未超出视口」时才有意义。
                    child: IntrinsicHeight(child: child),
                  )
                : child,
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: background ?? colors.washColor,
      body: SafeArea(
        bottom: bottomBar != null,
        child: Column(
          children: <Widget>[
            if (title != null)
              YounumTopNav(
                title: title!,
                showBack: showBack,
                onBack: onBack,
                trailing: trailing,
              ),
            Expanded(child: content),
          ],
        ),
      ),
      bottomNavigationBar: bottomBar,
    );
  }
}

/// 把内容限制在阅读宽度内并居中（手机上等于原样）。
///
/// 指南 6.3：「大屏居中限制阅读宽度……不能把手机 UI 无限拉宽」。
/// 页面正文、顶部导航、底部弹层都用它，这样三者左右边缘能对齐 ——
/// 只限制正文的话，标题会贴在平板最左边、内容却在中间，看起来是错位的。
Widget _withinReadingWidth(Widget child) => Center(
  child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: YounumDimens.readingMaxWidth),
    child: child,
  ),
);

/// 顶部导航栏：圆形返回按钮 + 居中标题 + 可选右侧操作。
class YounumTopNav extends StatelessWidget {
  const YounumTopNav({
    super.key,
    required this.title,
    this.showBack = true,
    this.onBack,
    this.trailing,
  });

  final String title;
  final bool showBack;
  final VoidCallback? onBack;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final text = YounumText.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        YounumDimens.pageHorizontal - 8,
        4,
        YounumDimens.pageHorizontal - 8,
        4,
      ),
      child: SizedBox(
        height: YounumDimens.minTouchTarget,
        child: _withinReadingWidth(
          Row(
            children: <Widget>[
              if (showBack)
                YounumIconButton(
                  icon: YounumIcons.back,
                  semanticLabel: '返回',
                  onPressed: onBack ?? () => Navigator.of(context).maybePop(),
                )
              else
                const SizedBox(width: YounumDimens.minTouchTarget),
              Expanded(
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: text.listPrimary.copyWith(color: colors.inkColor),
                ),
              ),
              SizedBox(
                width: YounumDimens.minTouchTarget,
                child: trailing == null
                    ? null
                    : Align(alignment: Alignment.centerRight, child: trailing),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 底部一级导航：本月 / 整理 / 月报 / 我的。
class AppBottomBar extends StatelessWidget {
  const AppBottomBar({super.key});

  static const List<YounumTab> tabs = <YounumTab>[
    YounumTab(route: AppRoutes.home, label: '本月', icon: YounumIcons.navHome),
    YounumTab(route: AppRoutes.cards, label: '整理', icon: YounumIcons.navCards),
    YounumTab(route: AppRoutes.report, label: '月报', icon: YounumIcons.navReport),
    YounumTab(route: AppRoutes.profile, label: '我的', icon: YounumIcons.navProfile),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final text = YounumText.of(context);
    final selection = TabScope.of(context);

    return Container(
      decoration: BoxDecoration(
        color: colors.washColor,
        border: const Border(top: BorderSide(color: Color(YounumColors.line))),
      ),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          // 用最小高度而不是固定高度：大字体下允许自然撑开，不出现 overflow
          // （指南 6.3：页面内容可以随文本扩展）。
          constraints: const BoxConstraints(minHeight: YounumDimens.bottomNavHeight),
          child: Row(
            children: <Widget>[
              for (var index = 0; index < tabs.length; index++)
                Expanded(
                  child: Semantics(
                    selected: selection.index == index,
                    button: true,
                    label: tabs[index].label,
                    excludeSemantics: true,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => context.selectTab(index),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                tabs[index].icon,
                                size: YounumDimens.iconLg,
                                color: selection.index == index
                                    ? colors.primaryColor
                                    : colors.mutedColor,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                tabs[index].label,
                                style: text.micro.copyWith(
                                  color: selection.index == index
                                      ? colors.primaryColor
                                      : colors.mutedColor,
                                  fontWeight: selection.index == index
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
