import 'package:flutter/material.dart';

import 'color_math.dart';
import 'theme_presets.dart';
import 'younum_colors.dart';
import 'younum_dimens.dart';
import 'younum_text.dart';

/// 主题装配。
///
/// 只用**浅色**方案：指南 7.2 明确要求「系统深色模式不应把浅色设计自动反色」，
/// 也不启用系统壁纸动态色，避免覆盖用户的选择。
abstract final class YounumTheme {
  /// 由用户选择的原始主色构建完整 [ThemeData]。
  static ThemeData build(int rawColor) {
    final colors = YounumColors.fromRaw(rawColor);
    final text = YounumText(colors);
    final colorScheme = ColorScheme.fromSeed(
      seedColor: colors.primaryColor,
      brightness: Brightness.light,
    ).copyWith(
      primary: colors.primaryColor,
      onPrimary: colors.onPrimaryColor,
      primaryContainer: colors.softColor,
      onPrimaryContainer: colors.primaryColor,
      secondary: colors.primaryColor,
      onSecondary: colors.onPrimaryColor,
      secondaryContainer: colors.tintColor,
      onSecondaryContainer: colors.inkColor,
      surface: ColorMath.toColor(YounumColors.surface),
      onSurface: colors.inkColor,
      surfaceContainerLowest: colors.washColor,
      surfaceContainerLow: colors.washColor,
      surfaceContainer: colors.softColor,
      outline: colors.borderColor,
      outlineVariant: ColorMath.toColor(YounumColors.line),
      error: ColorMath.toColor(YounumColors.danger),
      onError: const Color(0xFFFFFFFF),
      errorContainer: ColorMath.toColor(YounumColors.dangerContainer),
      onErrorContainer: ColorMath.toColor(YounumColors.danger),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colors.washColor,
      canvasColor: colors.washColor,
      textTheme: text.toTextTheme(),
      extensions: <ThemeExtension<dynamic>>[colors],
      // 原型没有 Material 涟漪，用按下态变色代替，视觉更接近设计稿。
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      dividerTheme: DividerThemeData(
        color: ColorMath.toColor(YounumColors.line),
        thickness: 1,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: EdgeInsets.zero,
        minVerticalPadding: YounumDimens.gap,
      ),
      // 底部弹层：圆角 24dp（指南 6.2）。
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.washColor,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(YounumDimens.radiusSheet),
          ),
        ),
      ),
      // 顶部栏去阴影，避免出现设计稿里没有的分层感。
      appBarTheme: AppBarTheme(
        backgroundColor: colors.washColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: colors.inkColor,
        ),
        iconTheme: IconThemeData(color: colors.inkColor, size: YounumDimens.iconLg),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.primaryColor,
        contentTextStyle: const TextStyle(fontSize: 14, color: Color(0xFFFFFFFF)),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(YounumDimens.radiusControl),
        ),
      ),
      dialogTheme: DialogThemeData(backgroundColor: colors.washColor),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colors.primaryColor,
        linearTrackColor: colors.softColor,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll<Color>(Color(0xFFFFFFFF)),
        trackColor: WidgetStateProperty.resolveWith<Color>((states) {
          if (states.contains(WidgetState.selected)) return colors.primaryColor;
          return ColorMath.toColor(YounumColors.switchTrack);
        }),
        trackOutlineColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: colors.primaryColor,
        selectionColor: colors.tintColor,
        selectionHandleColor: colors.primaryColor,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: ColorMath.toColor(YounumColors.surface),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        hintStyle: TextStyle(fontSize: 14, color: colors.mutedColor),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
          borderSide: const BorderSide(color: Color(YounumColors.inputBorder)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
          borderSide: const BorderSide(color: Color(YounumColors.inputBorder)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
          borderSide: BorderSide(color: colors.primaryColor, width: 1.4),
        ),
      ),
    );
  }

  /// 默认主题（森林绿）。用于需要脱离 context 的场景与测试。
  static ThemeData get fallback => build(ThemePresets.defaultPreset.color);

  /// 当前语义色。
  static YounumColors colorsOf(BuildContext context) => YounumColors.of(context);

  /// 当前字体层级。
  static YounumText textOf(BuildContext context) => YounumText.of(context);
}
