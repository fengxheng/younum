import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

/// 全部路由名。
///
/// 覆盖实现指南第 5 节的 33 个设计状态。命名按「领域_页面」组织，
/// 便于阶段 2-6 把假数据替换为真实仓库时不用改动机跳转。
abstract final class AppRoutes {
  /// 根路由：承载四个一级标签与底部导航。
  static const String root = '/';

  // --- 开始与本月 ---
  static const String welcome = '/welcome';
  static const String emptyHome = '/empty';
  static const String home = '/home';

  // --- 账单导入 ---
  static const String billImport = '/import';
  static const String exportGuide = '/import/guide';
  static const String upload = '/import/upload';
  static const String parsing = '/import/parsing';
  static const String mapping = '/import/mapping';
  static const String checkImport = '/import/check';
  static const String duplicates = '/import/duplicates';
  static const String importError = '/import/errors';

  // --- 卡片整理 ---
  static const String cards = '/organize/cards';
  static const String allCategories = '/organize/categories';
  static const String categoryManage = '/organize/category-manage';

  /// 用途快捷项：整理卡片上显示哪几个分类、按什么顺序。
  static const String categoryQuickPick = '/organize/category-quick-pick';
  static const String categoryEditor = '/organize/category-editor';
  static const String transactionDetail = '/organize/detail';
  static const String splitTransaction = '/organize/split';
  static const String transactionNature = '/organize/nature';
  static const String pendingQueue = '/organize/pending';
  static const String reviewComplete = '/organize/complete';

  // --- 月度回顾 ---
  static const String report = '/report';
  static const String breakdown = '/report/breakdown';
  static const String trends = '/report/trends';
  static const String transactions = '/report/transactions';
  static const String share = '/report/share';
  static const String months = '/report/months';

  // --- 我的与状态 ---
  static const String profile = '/profile';
  static const String theme = '/profile/theme';
  static const String importHistory = '/profile/imports';
  static const String privacy = '/profile/privacy';
  static const String reminder = '/profile/reminder';
  static const String deleteConfirm = '/profile/delete';
  static const String offlineStatus = '/profile/offline';

  /// 在线升级：查新版本、下载并交给系统安装器。
  static const String update = '/profile/update';

  /// 调试构建下的设计走查入口（Release 不注册）。
  static const String designReview = '/design-review';

  /// 设计走查是否可用。
  ///
  /// 只在调试构建开放：它替代原型里的设计画廊，方便逐个核对 33 个状态。
  /// Release 构建不注册该路由，也不会显示入口，符合指南 1.3
  /// 「不把设计画廊复制到正式 App」的要求。
  static bool get isDesignReviewEnabled => kDebugMode;

  /// 四个一级标签对应的路由，用于底部导航。
  static const List<String> tabs = <String>[home, cards, report, profile];
}

/// 四个一级标签的文案与图标。
class YounumTab {
  const YounumTab({required this.route, required this.label, required this.icon});

  final String route;
  final String label;
  final IconData icon;
}

/// 一级标签选择器。
///
/// 四个一级标签共用一个根路由，底部导航只切换索引，**不会无限压入相同页面**
/// （实现指南 5.1）。
class TabSelection extends ChangeNotifier {
  int _index = 0;

  int get index => _index;

  void select(int next) {
    if (next == _index) return;
    _index = next;
    notifyListeners();
  }

  /// 依据当前路由名同步高亮项。
  void syncFromRoute(String? route) {
    final found = AppRoutes.tabs.indexOf(route ?? '');
    if (found >= 0) select(found);
  }
}

/// 把 [TabSelection] 提供给子树。
class TabScope extends InheritedNotifier<TabSelection> {
  const TabScope({super.key, required TabSelection selection, required super.child})
      : super(notifier: selection);

  static TabSelection of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<TabScope>();
    assert(scope != null, 'TabScope 未挂载：请检查 app.dart 的根部装配。');
    return scope!.notifier!;
  }

  static TabSelection read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<TabScope>();
    assert(scope != null, 'TabScope 未挂载：请检查 app.dart 的根部装配。');
    return scope!.notifier!;
  }
}

/// 统一的跳转写法。
extension YounumNavigator on BuildContext {
  /// 压入新页面。
  ///
  /// [arguments] 只允许携带小参数（交易 ID、分类名、调用目的…），
  /// 不传完整账单对象或文件字节（指南 2.3.2）。
  void open(String route, {Object? arguments}) {
    Navigator.of(this).pushNamed(route, arguments: arguments);
  }

  /// 用新页面替换当前页（用于导入流程里「取消后回到某页」这类不回头的前进）。
  void replaceWith(String route) {
    Navigator.of(this).pushReplacementNamed(route);
  }

  /// 清空整栈并进入该页。
  ///
  /// 用于从引导页（它是唯一的初始路由）进入主界面 —— 此时必须真的清空，
  /// 否则返回键会回到引导页。
  void openAsRoot(String route) {
    Navigator.of(this).pushNamedAndRemoveUntil(route, (route) => false);
  }

  /// 切换一级标签。
  void selectTab(int index) {
    TabScope.read(this).select(index);
    Navigator.of(this).popUntil((route) => route.isFirst);
  }
}
