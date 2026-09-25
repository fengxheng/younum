import 'package:shared_preferences/shared_preferences.dart';

import 'theme_store.dart' show PreferenceKeys;

/// 「忽略这个版本」的存储。
///
/// 只存一个 build number，别的一概不存 —— 甚至连「上次检查时间」都不存：
/// 那是给自己找麻烦（要处理时区、要处理跨年），而每次启动查一次
/// 一个几十字节的公开 JSON 没有成本。
abstract interface class UpdateStore {
  /// 被用户忽略的版本序号；没忽略过返回 null。
  Future<int?> loadSkippedVersionCode();

  Future<void> saveSkippedVersionCode(int? versionCode);
}

/// 内存实现：测试与「偏好读不出来」的降级路径用。
class InMemoryUpdateStore implements UpdateStore {
  InMemoryUpdateStore([this._skipped]);

  int? _skipped;

  @override
  Future<int?> loadSkippedVersionCode() async => _skipped;

  @override
  Future<void> saveSkippedVersionCode(int? versionCode) async =>
      _skipped = versionCode;
}

/// SharedPreferences 实现。
class SharedPreferencesUpdateStore implements UpdateStore {
  SharedPreferencesUpdateStore(this._preferences);

  final SharedPreferences _preferences;

  static Future<SharedPreferencesUpdateStore> open() async =>
      SharedPreferencesUpdateStore(await SharedPreferences.getInstance());

  @override
  Future<int?> loadSkippedVersionCode() async =>
      _preferences.getInt(PreferenceKeys.updateSkippedVersionCode);

  @override
  Future<void> saveSkippedVersionCode(int? versionCode) async {
    if (versionCode == null) {
      await _preferences.remove(PreferenceKeys.updateSkippedVersionCode);
      return;
    }
    await _preferences.setInt(PreferenceKeys.updateSkippedVersionCode, versionCode);
  }
}
