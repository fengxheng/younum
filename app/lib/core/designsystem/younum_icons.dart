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

  /// 拖动排序用的手柄（用途快捷项里用它，避免整行都能拖而和行内按钮抢手势）。
  static const IconData dragHandle = Icons.drag_handle;
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
  //
  // ⚠️ **已有的键不要改名、不要删**：它们按分类存进了数据库
  // （`category.icon_key`），改名等于把用户已经选好的图标弄丢。只允许追加。
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

    // 底下是补充的生活类别：预设太少时，用户只能靠在图片与默认图标之间二选一。
    'pets': Icons.pets, // 宠物
    'study': Icons.school_outlined, // 学习
    'sport': Icons.fitness_center, // 运动
    'medicine': Icons.medication_outlined, // 药品
    'phone': Icons.smartphone, // 数码
    'clothes': Icons.checkroom, // 服饰
    'baby': Icons.child_friendly_outlined, // 母婴
    'travel': Icons.flight_takeoff, // 旅行
    'game': Icons.sports_esports_outlined, // 游戏
    'music': Icons.music_note_outlined, // 音乐
    'book': Icons.auto_stories_outlined, // 读书
    'flower': Icons.local_florist_outlined, // 绿植
    'electric': Icons.bolt_outlined, // 水电
    'daily': Icons.water_drop_outlined, // 日用
    'apartment': Icons.apartment_outlined, // 房租
    'insurance': Icons.health_and_safety_outlined, // 保险
    'tax': Icons.account_balance_outlined, // 税费
    'charity': Icons.volunteer_activism_outlined, // 公益
    'repair': Icons.build_outlined, // 维修
    'beauty': Icons.spa_outlined, // 美容
    'snack': Icons.icecream_outlined, // 零食
    'tea': Icons.emoji_food_beverage_outlined, // 茶饮
    'fastfood': Icons.fastfood_outlined, // 快餐
    'drink': Icons.local_bar_outlined, // 酒水
    'taxi': Icons.local_taxi_outlined, // 打车
    'bus': Icons.directions_bus_outlined, // 公交
    'train': Icons.train_outlined, // 火车
    'bike': Icons.pedal_bike_outlined, // 骑行
    'work': Icons.work_outline, // 工作
    'savings': Icons.savings_outlined, // 储蓄
    'creditcard': Icons.credit_card_outlined, // 信用卡
    'subscription': Icons.subscriptions_outlined, // 订阅
    'laundry': Icons.local_laundry_service_outlined, // 洗衣
    'party': Icons.celebration_outlined, // 聚会
    'toys': Icons.toys_outlined, // 玩具
    'furniture': Icons.chair_outlined, // 家居
    'kitchen': Icons.kitchen_outlined, // 厨具
    'camera': Icons.photo_camera_outlined, // 摄影
    'computer': Icons.desktop_windows_outlined, // 电脑
    'outdoor': Icons.wb_sunny_outlined, // 户外
  };

  /// 内置分类图标的可选键，顺序即图标编辑器的展示顺序。
  static List<String> get builtinCategoryKeys => _categoryIcons.keys.toList(growable: false);

  /// 图标编辑器的中文可访问名称，供 TalkBack 朗读（指南 14.3 / 14.4.9）。
  ///
  /// ⚠️ 这些名字在编辑器里同时充当**选项名**（`CategoryGrid` 是按名字选中的），
  /// 所以它们必须两两不同 —— `icon_asset_rules_test.dart` 里有一条用例守着。
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
    'pets': '宠物',
    'study': '学习',
    'sport': '运动',
    'medicine': '药品',
    'phone': '数码',
    'clothes': '服饰',
    'baby': '母婴',
    'travel': '旅行',
    'game': '游戏',
    'music': '音乐',
    'book': '读书',
    'flower': '绿植',
    'electric': '水电',
    'daily': '日用',
    'apartment': '房租',
    'insurance': '保险',
    'tax': '税费',
    'charity': '公益',
    'repair': '维修',
    'beauty': '美容',
    'snack': '零食',
    'tea': '茶饮',
    'fastfood': '快餐',
    'drink': '酒水',
    'taxi': '打车',
    'bus': '公交',
    'train': '火车',
    'bike': '骑行',
    'work': '工作',
    'savings': '储蓄',
    'creditcard': '信用卡',
    'subscription': '订阅',
    'laundry': '洗衣',
    'party': '聚会',
    'toys': '玩具',
    'furniture': '家居',
    'kitchen': '厨具',
    'camera': '摄影',
    'computer': '电脑',
    'outdoor': '户外',
  };

  /// 解析内置分类图标键；未知键回退到 [defaultCategoryIconKey]。
  ///
  /// 回退必须永远可用：分类图标资源缺失或损坏时不能让账单页面崩溃（指南 14.4.8）。
  static IconData categoryIcon(String? key) =>
      _categoryIcons[key] ?? _categoryIcons[defaultCategoryIconKey]!;

  /// 该键是否为合法的内置键。
  static bool isBuiltinCategoryKey(String key) => _categoryIcons.containsKey(key);

  /// 中文可访问名称。
  ///
  /// 不认识这个键时**返回键本身**：那多半是用户自己填的 emoji
  /// （见 `CategoryRules.validateEmojiIconKey`），让 TalkBack 直接读它
  /// —— 读成「叶片」是错的，而且会让图标编辑器把 emoji 误标成叶子那一格。
  static String categoryIconLabel(String key) => categoryIconLabels[key] ?? key;
}
