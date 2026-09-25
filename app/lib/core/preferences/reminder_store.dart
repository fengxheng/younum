import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'theme_store.dart' show PreferenceKeys;

/// 每月整理提醒的设置（指南 8.2：保存每月日期、当地时间、时区策略与开关）。
class ReminderSettings {
  const ReminderSettings({
    required this.enabled,
    required this.day,
    required this.hour,
    required this.minute,
  });

  /// 开关。**默认关闭** —— 用户主动开了才会有通知（指南 8.2）。
  final bool enabled;

  /// 每月第几天（1–31）。29/30/31 在短月顺延到月末。
  final int day;

  final int hour;
  final int minute;

  ReminderSettings copyWith({
    bool? enabled,
    int? day,
    int? hour,
    int? minute,
  }) => ReminderSettings(
    enabled: enabled ?? this.enabled,
    day: day ?? this.day,
    hour: hour ?? this.hour,
    minute: minute ?? this.minute,
  );

  /// 时区口径固定为账目那一套，随设置一起存下来，迁移时不至于口径不明。
  String get timeZone => 'Asia/Shanghai';

  /// 存盘用。带版本号，将来加字段能识别旧数据。
  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'enabled': enabled,
    'day': day,
    'hour': hour,
    'minute': minute,
    'timeZone': timeZone,
  };

  @override
  bool operator ==(Object other) =>
      other is ReminderSettings &&
      other.enabled == enabled &&
      other.day == day &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode => Object.hash(enabled, day, hour, minute);

  @override
  String toString() =>
      'ReminderSettings(enabled: $enabled, $day 日 $hour:${minute.toString().padLeft(2, '0')})';
}

/// 提醒设置存储。实现可替换为内存版以便测试（指南 2.1）。
abstract interface class ReminderStore {
  Future<ReminderSettings?> load();

  Future<void> save(ReminderSettings settings);
}

/// 内存实现：测试与「数据库打不开」的降级路径用。
class InMemoryReminderStore implements ReminderStore {
  InMemoryReminderStore([this._settings]);

  ReminderSettings? _settings;

  @override
  Future<ReminderSettings?> load() async => _settings;

  @override
  Future<void> save(ReminderSettings settings) async => _settings = settings;
}

/// SharedPreferences 实现。
///
/// 只存这一小组设置，不存账单（与主题偏好同一原则）。
class SharedPreferencesReminderStore implements ReminderStore {
  SharedPreferencesReminderStore(this._preferences);

  final SharedPreferences _preferences;

  static Future<SharedPreferencesReminderStore> open() async =>
      SharedPreferencesReminderStore(await SharedPreferences.getInstance());

  @override
  Future<ReminderSettings?> load() async {
    final raw = _preferences.getString(PreferenceKeys.reminder);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      final enabled = decoded['enabled'];
      final day = decoded['day'];
      final hour = decoded['hour'];
      final minute = decoded['minute'];
      if (enabled is! bool ||
          day is! int ||
          hour is! int ||
          minute is! int) {
        // 数据损坏：当作没设置过，让用户重新设一次，不猜测。
        return null;
      }
      return ReminderSettings(
        enabled: enabled,
        day: day,
        hour: hour,
        minute: minute,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> save(ReminderSettings settings) async {
    await _preferences.setString(
      PreferenceKeys.reminder,
      jsonEncode(settings.toJson()),
    );
  }
}
