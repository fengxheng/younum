import 'package:flutter/material.dart';

import '../designsystem/color_math.dart';
import '../designsystem/theme_presets.dart';
import '../designsystem/younum_theme.dart';
import '../preferences/theme_store.dart';

/// 一次主题提交的结果。
enum ThemeSaveOutcome {
  /// 已生效并写入设备。
  saved,

  /// 已即时生效，但写入失败 —— 必须明确告知用户，不能假装保存成功（指南 7.2）。
  previewOnlySaveFailed,
}

/// 全局主题控制器。
///
/// 主题**不是**单页局部变量：任何页面读取的都是同一份状态（指南 7.2）。
/// 使用 [ChangeNotifier] + 根部监听，避免引入额外的状态管理依赖。
class ThemeController extends ChangeNotifier {
  ThemeController(this._store, this._preferences);

  final ThemeStore _store;
  ThemePreferences _preferences;

  bool _saveFailed = false;
  ThemePreferences? _lastPersisted;

  /// 冷启动时先加载偏好再渲染首帧，避免「先闪默认绿再切色」（指南 7.2）。
  static Future<ThemeController> restore(ThemeStore store) async {
    final preferences = await store.load();
    final controller = ThemeController(store, preferences);
    controller._lastPersisted = preferences;
    return controller;
  }

  /// 当前生效的原始色值。
  int get rawColor => _preferences.color;

  String get hex => _preferences.hex;

  /// 名称：预设名或「自定义配色」。
  String get displayName => ThemePresets.byId(_preferences.presetId)?.name ?? '自定义配色';

  ThemePreset? get preset => ThemePresets.byId(_preferences.presetId);

  bool get isCustom => _preferences.presetId == ThemePresets.customId;

  bool get isDefault => _preferences.presetId == ThemePresets.defaultId;

  /// 当前主色是否因对比度不足被自动加深。用于给出说明文案。
  bool get primaryAdjusted => ColorMath.wasReadableAdjustmentApplied(_preferences.color);

  /// 最近一次提交是否只预览、未落盘。
  bool get hasUnsavedPreview => _saveFailed;

  /// 是否存在尚未提交的拖拽预览。
  bool get isDirty => _lastPersisted != null && _lastPersisted != _preferences;

  /// 当前 [ThemeData]。
  ThemeData get themeData => YounumTheme.build(_preferences.color);

  /// 只改变内存中的颜色，**不写磁盘**。
  ///
  /// 取色器拖动过程中调用，避免每帧写入（指南 7.2）。
  void preview(int color) {
    final next = ThemePreferences(
      color: color & 0xFFFFFF,
      presetId: ThemePresets.idForColor(color),
    );
    if (next == _preferences) return;
    _preferences = next;
    notifyListeners();
  }

  /// 生效并写入设备。
  ///
  /// 即使写入失败，界面仍保持已预览的颜色（用户看得见效果），但 [hasUnsavedPreview]
  /// 会变为 true，页面必须据此显示「已预览但保存失败」并提供重试。
  Future<ThemeSaveOutcome> apply(int color) async {
    preview(color);
    return _persist();
  }

  /// 重试写入当前颜色。
  Future<ThemeSaveOutcome> retrySave() => _persist();

  /// 放弃预览，回到最后一次成功写入的主题。
  void revertPreview() {
    final restored = _lastPersisted;
    if (restored == null || restored == _preferences) return;
    _preferences = restored;
    _saveFailed = false;
    notifyListeners();
  }

  /// 恢复默认（森林绿）。
  ///
  /// 只影响主题，不清除账单、分类与提醒（指南 7.2）。
  Future<ThemeSaveOutcome> restoreDefault() =>
      apply(ThemePresets.defaultPreset.color);

  Future<ThemeSaveOutcome> _persist() async {
    try {
      await _store.save(_preferences);
      _lastPersisted = _preferences;
      if (_saveFailed) {
        _saveFailed = false;
        notifyListeners();
      }
      return ThemeSaveOutcome.saved;
    } catch (_) {
      _saveFailed = true;
      notifyListeners();
      return ThemeSaveOutcome.previewOnlySaveFailed;
    }
  }
}

/// 让任意子页面以 `ThemeScope.of(context)` 取到控制器。
class ThemeScope extends InheritedNotifier<ThemeController> {
  const ThemeScope({super.key, required ThemeController controller, required super.child})
      : super(notifier: controller);

  static ThemeController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThemeScope>();
    assert(scope != null, 'ThemeScope 未挂载：请检查 main.dart 的根部装配。');
    return scope!.notifier!;
  }

  /// 不需要在主题变化时重建时使用，例如在回调里读取。
  static ThemeController read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<ThemeScope>();
    assert(scope != null, 'ThemeScope 未挂载：请检查 main.dart 的根部装配。');
    return scope!.notifier!;
  }
}
