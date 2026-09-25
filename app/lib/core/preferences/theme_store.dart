import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../designsystem/color_math.dart';
import '../designsystem/theme_presets.dart';

/// 需要持久化的主题偏好。
///
/// 只保存**原始色值**与预设 ID。派生色（primary / soft / ink…）是渲染结果，
/// 绝不回写（指南 7.2）。
class ThemePreferences {
  const ThemePreferences({required this.color, required this.presetId});

  factory ThemePreferences.defaults() => ThemePreferences(
        color: ThemePresets.defaultPreset.color,
        presetId: ThemePresets.defaultId,
      );

  final int color;
  final String presetId;

  /// `#RRGGBB`，大写。
  String get hex => ColorMath.toHex(color);

  Map<String, Object?> toJson() => <String, Object?>{
        'version': 1,
        'presetId': presetId,
        'color': hex,
      };

  @override
  bool operator ==(Object other) =>
      other is ThemePreferences && other.color == color && other.presetId == presetId;

  @override
  int get hashCode => Object.hash(color, presetId);
}

/// 主题偏好存储接口。实现可替换为内存版以便测试（指南 2.1：业务接口可替换）。
abstract interface class ThemeStore {
  Future<ThemePreferences> load();

  Future<void> save(ThemePreferences preferences);
}

/// 偏好键名。集中在一处，避免多个功能各写一套。
abstract final class PreferenceKeys {
  static const String theme = 'younum.theme';

  /// 每月整理提醒的设置。
  static const String reminder = 'younum.reminder';
}

/// SharedPreferences 实现。
///
/// 只用于这类少量偏好，不存账单集合（指南 7.2）。账单未来落在 Room 等价的
/// 本地数据库里，不走这里。
class SharedPreferencesThemeStore implements ThemeStore {
  SharedPreferencesThemeStore(this._preferences);

  final SharedPreferences _preferences;

  static Future<SharedPreferencesThemeStore> open() async =>
      SharedPreferencesThemeStore(await SharedPreferences.getInstance());

  @override
  Future<ThemePreferences> load() async {
    final raw = _preferences.getString(PreferenceKeys.theme);
    if (raw == null || raw.isEmpty) return ThemePreferences.defaults();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return ThemePreferences.defaults();
      final color = ColorMath.tryParseHex(decoded['color'] as String?);
      // 非法或损坏的偏好回退到默认，但不写回磁盘，便于用户改回来。
      if (color == null) return ThemePreferences.defaults();
      return ThemePreferences(
        color: color,
        // 预设 ID 与色值不一致时以色值为准，避免出现「显示森林绿、实际是紫色」。
        presetId: ThemePresets.idForColor(color),
      );
    } on FormatException {
      return ThemePreferences.defaults();
    }
  }

  @override
  Future<void> save(ThemePreferences preferences) async {
    final ok = await _preferences.setString(
      PreferenceKeys.theme,
      jsonEncode(preferences.toJson()),
    );
    if (!ok) {
      throw StateError('preferences write returned false');
    }
  }
}

/// 内存实现，供单元测试与 Preview 使用。
class InMemoryThemeStore implements ThemeStore {
  /// 传入的初始值会被复制，因此可以安全地传 `const {}`
  /// 或直接喂一段「损坏的 JSON」来测试回退路径。
  InMemoryThemeStore([Map<String, String>? initial])
      : _stored = <String, String>{...?initial};

  final Map<String, String> _stored;

  /// 设为 true 可模拟「磁盘写入失败」路径（指南 7.2 / 10.4）。
  bool failOnSave = false;

  @override
  Future<ThemePreferences> load() async {
    final raw = _stored[PreferenceKeys.theme];
    if (raw == null) return ThemePreferences.defaults();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return ThemePreferences.defaults();
      final color = ColorMath.tryParseHex(decoded['color'] as String?);
      if (color == null) return ThemePreferences.defaults();
      return ThemePreferences(color: color, presetId: ThemePresets.idForColor(color));
    } on FormatException {
      return ThemePreferences.defaults();
    }
  }

  @override
  Future<void> save(ThemePreferences preferences) async {
    if (failOnSave) throw StateError('in-memory store configured to fail');
    _stored[PreferenceKeys.theme] = jsonEncode(preferences.toJson());
  }
}
