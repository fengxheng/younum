import 'package:shared_preferences/shared_preferences.dart';

import 'theme_store.dart' show PreferenceKeys;

/// 「整理卡片上的用途快捷项」的持久化。
///
/// 存的是一个**有序的分类 ID 列表**：顺序就是卡片上的显示顺序。
///
/// 为什么放在偏好里而不是数据库：这是「界面上显示哪几个、按什么顺序」的显示
/// 偏好，不是账目数据 —— 与主题、提醒同一类。代价是可能留下已经归档或被合并掉的
/// ID，所以读取时一律交给 `CategoryRules.resolveQuickPick` 过滤一遍，
/// 界面不需要各自处理。
abstract interface class CategoryPickStore {
  /// 存下来的分类 ID（顺序即显示顺序）。**没配置过时返回空列表** ——
  /// 空列表表示「用默认」（内置一级分类），不是「一个都不要」。
  Future<List<int>> loadQuickPickIds();

  Future<void> saveQuickPickIds(List<int> ids);
}

/// 内存实现：测试与「偏好读不出来」的降级路径用。
class InMemoryCategoryPickStore implements CategoryPickStore {
  InMemoryCategoryPickStore([List<int>? initial]) : _ids = <int>[...?initial];

  List<int> _ids;

  @override
  Future<List<int>> loadQuickPickIds() async => List<int>.unmodifiable(_ids);

  @override
  Future<void> saveQuickPickIds(List<int> ids) async => _ids = <int>[...ids];
}

/// SharedPreferences 实现。
class SharedPreferencesCategoryPickStore implements CategoryPickStore {
  SharedPreferencesCategoryPickStore(this._preferences);

  final SharedPreferences _preferences;

  static Future<SharedPreferencesCategoryPickStore> open() async =>
      SharedPreferencesCategoryPickStore(await SharedPreferences.getInstance());

  @override
  Future<List<int>> loadQuickPickIds() async {
    final raw = _preferences.getStringList(PreferenceKeys.categoryQuickPick);
    if (raw == null) return const <int>[];
    // SharedPreferences 没有 int 列表，所以按字符串存。解析不了的条目跳过：
    // 一条坏值不该把整份配置丢掉（丢掉就等于用户白调了一遍）。
    return <int>[
      for (final item in raw)
        if (int.tryParse(item) != null) int.parse(item),
    ];
  }

  @override
  Future<void> saveQuickPickIds(List<int> ids) async {
    // 空列表要写回「没配置过」这个状态（而不是存一个空列表）——
    // 两者对读取方是同一个意思，但删掉键更干净。
    if (ids.isEmpty) {
      await _preferences.remove(PreferenceKeys.categoryQuickPick);
      return;
    }
    await _preferences.setStringList(
      PreferenceKeys.categoryQuickPick,
      <String>[for (final id in ids) '$id'],
    );
  }
}
