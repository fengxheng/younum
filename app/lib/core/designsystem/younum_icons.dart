import 'package:flutter/material.dart';

/// 图标库。
///
/// 原型的 34 个线性图标是手写 SVG `path`。首版刻意**不**自建 SVG 解析器，
/// 而是用 Material 线性（`_outlined`）图标族替代，理由见 `docs/DECISIONS.md`：
/// 保持「一致的图标库」而不是混用 emoji 或零散位图（指南 6.2）。
///
/// 所有图标在此集中登记，替换成自绘矢量时只需改这一个文件。
abstract final class YounumIcons {
  // ---------------------------------------------------------------------------
  // 界面功能性图标
  // ---------------------------------------------------------------------------

  static const IconData back = Icons.chevron_left;
  static const IconData forward = Icons.arrow_forward;
  static const IconData chevronRight = Icons.chevron_right;
  static const IconData expandMore = Icons.expand_more;
  static const IconData close = Icons.close;
  static const IconData check = Icons.check;
  static const IconData add = Icons.add;
  static const IconData more = Icons.more_horiz;

  static const IconData upload = Icons.file_upload_outlined;
  static const IconData download = Icons.file_download_outlined;
  static const IconData search = Icons.search;
  static const IconData edit = Icons.edit_outlined;
  static const IconData undo = Icons.undo;
  static const IconData split = Icons.call_split;
  static const IconData link = Icons.link;
  static const IconData alert = Icons.warning_amber_rounded;

  static const IconData clock = Icons.schedule_outlined;
  static const IconData calendar = Icons.calendar_today_outlined;
  static const IconData shield = Icons.shield_outlined;
  static const IconData lock = Icons.lock_outline;
  static const IconData settings = Icons.tune;
  static const IconData palette = Icons.palette_outlined;
  static const IconData bell = Icons.notifications_none;
  static const IconData image = Icons.image_outlined;
  static const IconData refresh = Icons.refresh;

  /// 账单文件 / 导入记录。
  static const IconData cards = Icons.style_outlined;
  static const IconData file = Icons.description_outlined;

  /// 使用帮助。
  static const IconData description = Icons.menu_book_outlined;

  static const IconData home = Icons.home_outlined;
  static const IconData chart = Icons.insert_chart_outlined;

  // 底部一级导航
  static const IconData navHome = Icons.home_outlined;
  static const IconData navCards = Icons.style_outlined;
  static const IconData navReport = Icons.insert_chart_outlined;
  static const IconData navProfile = Icons.person_outline;

  /// 账单来源用的钱包图标。
  static const IconData wallet = Icons.account_balance_wallet_outlined;

  // ---------------------------------------------------------------------------
  // 分类内置图标库（指南 14.3 要求至少覆盖这 12 类）
  // ---------------------------------------------------------------------------

  static const String defaultCategoryIconKey = 'leaf';

  static const Map<String, IconData> _categoryIcons = <String, IconData>{
    'food': Icons.restaurant_outlined, // 餐饮
    'coffee': Icons.local_cafe_outlined, // 咖啡
    'bag': Icons.shopping_bag_outlined, // 购物
    'car': Icons.directions_car_outlined, // 交通
    'home': Icons.home_outlined, // 居住
    'play': Icons.movie_outlined, // 娱乐
    'heart': Icons.favorite_outline, // 健康
    'gift': Icons.card_giftcard_outlined, // 人情
    'file': Icons.description_outlined, // 文件
    'wallet': Icons.account_balance_wallet_outlined, // 钱包
    'user': Icons.person_outline, // 个人
    'leaf': Icons.eco_outlined, // 叶片（默认）
  };

  /// 内置分类图标的可选键，顺序即图标编辑器的展示顺序。
  static List<String> get builtinCategoryKeys => _categoryIcons.keys.toList(growable: false);

  /// 图标编辑器的中文可访问名称，供 TalkBack 朗读（指南 14.3 / 14.4.9）。
  static const Map<String, String> categoryIconLabels = <String, String>{
    'food': '餐饮',
    'coffee': '咖啡',
    'bag': '购物',
    'car': '交通',
    'home': '居住',
    'play': '娱乐',
    'heart': '健康',
    'gift': '人情',
    'file': '文件',
    'wallet': '钱包',
    'user': '个人',
    'leaf': '叶片',
  };

  /// 解析内置分类图标键；未知键回退到 [defaultCategoryIconKey]。
  ///
  /// 回退必须永远可用：分类图标资源缺失或损坏时不能让账单页面崩溃（指南 14.4.8）。
  static IconData categoryIcon(String? key) =>
      _categoryIcons[key] ?? _categoryIcons[defaultCategoryIconKey]!;

  /// 该键是否为合法的内置键。
  static bool isBuiltinCategoryKey(String key) => _categoryIcons.containsKey(key);

  /// 中文可访问名称。
  static String categoryIconLabel(String key) =>
      categoryIconLabels[key] ?? categoryIconLabels[defaultCategoryIconKey]!;
}
