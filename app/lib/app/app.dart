import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/preferences/app_state_store.dart';
import '../core/preferences/reminder_controller.dart';
import '../core/preferences/reminder_store.dart';
import '../core/preferences/theme_controller.dart';
import '../domain/repositories/image_file_source.dart';
import '../domain/repositories/document_saver.dart';
import '../domain/repositories/ledger_file_source.dart';
import '../domain/repositories/ledger_repository.dart';
import '../domain/repositories/poster_ports.dart';
import '../domain/repositories/reminder_scheduler.dart';
import '../features/export/export_scope.dart';
import '../features/import_flow/import_screens.dart';
import '../features/import_flow/import_session.dart';
import '../features/import_flow/parse_screens.dart';
import '../features/organize/cards_screen.dart';
import '../features/organize/category_registry.dart';
import '../features/organize/category_screens.dart';
import '../features/organize/review_screens.dart';
import '../features/organize/review_session.dart';
import '../features/profile/profile_screens.dart';
import '../features/profile/theme_screen.dart';
import '../features/report/report_screens.dart';
import '../features/review/design_review_screen.dart';
import '../features/start/start_screens.dart';
import 'app_routes.dart';
import 'route_args.dart';

/// 应用根。
///
/// 这里集中装配四件事，全部**位于 MaterialApp 之上**，因此弹出的路由也能取到：
/// * [ThemeScope] —— 全局主题，任何页面改色立即全树生效；
/// * [AppStateScope] —— 引导状态与真实 / 演示账本隔离；
/// * [TabScope] —— 四个一级标签的选中态；
/// * [ReviewSessionScope] —— 整理会话，切标签后进度不丢；
/// * [ImportSessionScope] —— 导入会话，跨「选文件 → 解析 → 映射 → 核对」几页；
/// * [CategoryRegistryScope] —— 分类图标的唯一来源。
class YounumApp extends StatefulWidget {
  const YounumApp({
    super.key,
    required this.themeController,
    required this.appStateController,
    required this.ledgerRepository,
    required this.ledgerFileSource,
    this.imageFileSource = const UnsupportedImageSource(),
    this.posterMaker = const UnsupportedPosterMaker(),
    this.documentSaver = const UnsupportedDocumentSaver(),
    this.reminderStore,
    this.reminderScheduler = const UnsupportedReminderScheduler(),
  });

  final ThemeController themeController;
  final AppStateController appStateController;

  /// 账本数据仓库。真实 / 演示账本的隔离由它保证。
  final LedgerRepository ledgerRepository;

  /// 选账单文件的能力。
  ///
  /// 桌面与测试环境传 [UnsupportedFileSource]：界面据此把入口显灰，
  /// 而不是留一个点了没反应的按钮。
  final LedgerFileSource ledgerFileSource;

  /// 选分类图片的能力。桌面与测试环境是不支持实现，入口会显灰。
  final ImageFileSource imageFileSource;

  /// 生成月报海报的能力。桌面与测试环境是不支持实现，导出会如实报错。
  final PosterMaker posterMaker;

  /// 保存文件的能力。桌面与测试环境是不支持实现，导出会如实报错。
  final DocumentSaver documentSaver;

  /// 提醒设置的持久化。不传就用内存实现（测试与降级路径）。
  final ReminderStore? reminderStore;

  /// 提醒调度能力。桌面与测试环境是不支持实现，开关会显灰。
  final ReminderScheduler reminderScheduler;

  @override
  State<YounumApp> createState() => _YounumAppState();
}

class _YounumAppState extends State<YounumApp> with WidgetsBindingObserver {
  final TabSelection _tabs = TabSelection();

  /// 通知点进来时要跳页，必须能拿到 Navigator。
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late final ReviewSession _review = ReviewSession(
    repository: widget.ledgerRepository,
  );
  late final ImportSession _import = ImportSession(
    repository: widget.ledgerRepository,
    fileSource: widget.ledgerFileSource,
    ledgerId: _ledgerIdFor(widget.appStateController.isDemoLedger),
  );
  late final CategoryRegistry _registry = CategoryRegistry(
    repository: widget.ledgerRepository,
    imageSource: widget.imageFileSource,
  );
  late final ReminderController _reminder = ReminderController(
    store: widget.reminderStore ?? InMemoryReminderStore(),
    scheduler: widget.reminderScheduler,
  );

  @override
  void initState() {
    super.initState();
    // 账本模式存在偏好里，启动时按它把会话接到对应账本。
    widget.appStateController.addListener(_syncLedgerMode);
    _review.useLedger(isDemo: widget.appStateController.isDemoLedger);
    // 分类是界面上到处都要用的（网格、明细、月报），启动就读一次。
    _registry.load(
      ledgerId: _ledgerIdFor(widget.appStateController.isDemoLedger),
    );
    // 提醒设置与平台状态也启动就读：设置页必须显示**实际**状态。
    _reminder.load();
    // 点通知进来时要落到整理页（指南 8.2：通知跳转到需要整理的月份）。
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openPendingRoute());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 应用已经在后台时点通知，走的是 onNewIntent + 回到前台，两条路都要接。
    if (state != AppLifecycleState.resumed) return;
    _openPendingRoute();
    // onNewIntent 有时比 resume 晚到一步（真机上碰到过），再问一次就不会漏。
    // 路由取走即清，所以重复问不会多跳一页。
    Timer(const Duration(milliseconds: 500), _openPendingRoute);
  }

  /// 取走通知带的路由并跳页。
  ///
  /// ⚠️ 只认白名单里的路由：平台通道给什么就跳什么太危险，
  /// 而且路由名本来就是应用内部约定，不该让外部决定。
  Future<void> _openPendingRoute() async {
    final String? route;
    try {
      route = await widget.reminderScheduler.consumeLaunchRoute();
    } catch (_) {
      return;
    }
    if (route == null || !mounted) return;

    final target = switch (route) {
      '/organize/cards' => AppRoutes.cards,
      _ => null,
    };
    if (target == null) return;

    // 整理本来就是一级标签页：**切标签**比再压一层路由对 ——
    // 压路由会多出一份同样的页面，而且底部导航的高亮会停在原来的标签上。
    // 先回到根，避免用户还停在某个详情页里时切了标签却看不见。
    _navigatorKey.currentState?.popUntil((route) => route.isFirst);
    _tabs.syncFromRoute(target);
  }

  /// 进入 / 退出演示账本时整体重载会话。
  ///
  /// 两个账本的数据互不可见，不能把上一本的队列留在界面上（指南 1.3）。
  /// 导入会话同样要换账本 —— 否则在演示账本里选的账单会被暂存到真实账本里。
  void _syncLedgerMode() {
    final isDemo = widget.appStateController.isDemoLedger;
    _review.useLedger(isDemo: isDemo);
    // 换账本意味着这次导入的上下文整个变了，直接回到起点。
    _import.reset();
    _import.useLedger(_ledgerIdFor(isDemo));
  }

  /// 演示账本与真实账本的 ID。
  ///
  /// 与 `DemoLedgerSeed` 保持一致；这里不直接导入那个文件是为了不让
  /// 应用根部依赖种子数据。
  static int _ledgerIdFor(bool isDemo) => isDemo ? 1 : 2;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.appStateController.removeListener(_syncLedgerMode);
    _tabs.dispose();
    _review.dispose();
    _import.dispose();
    _registry.dispose();
    _reminder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        widget.themeController,
        widget.appStateController,
      ]),
      builder: (context, _) {
        return ThemeScope(
          controller: widget.themeController,
          child: AppStateScope(
            controller: widget.appStateController,
            child: TabScope(
              selection: _tabs,
              child: ReviewSessionScope(
                session: _review,
                child: ImportSessionScope(
                  session: _import,
                  child: CategoryRegistryScope(
                    registry: _registry,
                    child: ExportScope(
                      posterMaker: widget.posterMaker,
                      documentSaver: widget.documentSaver,
                      child: MaterialApp(
                        navigatorKey: _navigatorKey,
                        navigatorObservers: <NavigatorObserver>[
                          _TabHighlightObserver(_tabs),
                        ],
                        title: '有数',
                        debugShowCheckedModeBanner: false,
                        // 只提供浅色主题：系统深色模式不应把浅色设计自动反色（指南 7.2）。
                        theme: widget.themeController.themeData,
                        themeMode: ThemeMode.light,
                        locale: const Locale('zh', 'CN'),
                        supportedLocales: const <Locale>[Locale('zh', 'CN')],
                        localizationsDelegates:
                            const <LocalizationsDelegate<Object>>[
                              GlobalMaterialLocalizations.delegate,
                              GlobalWidgetsLocalizations.delegate,
                              GlobalCupertinoLocalizations.delegate,
                            ],
                        initialRoute: widget.appStateController.onboardingSeen
                            ? AppRoutes.root
                            : AppRoutes.welcome,
                        onGenerateRoute: _onGenerateRoute,
                        builder: (context, child) {
                          // 限制文字缩放上限，避免堆叠卡片这类固定高度容器在大字体下溢出。
                          // 下限不压低，用户调大字号的能力不被剥夺（指南 6.3）。
                          return MediaQuery.withClampedTextScaling(
                            minScaleFactor: 0.85,
                            maxScaleFactor: 1.6,
                            child: child ?? const SizedBox.shrink(),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Route<dynamic>? _onGenerateRoute(RouteSettings settings) {
    final builder = _builderFor(settings);
    if (builder == null) {
      // 未知路由：给出解释而不是白屏。
      return MaterialPageRoute<dynamic>(
        settings: settings,
        builder: (context) => YounumUnknownRouteScreen(route: settings.name),
      );
    }
    // 用 dynamic 而不是 void：分类选择页会 pop 出 String 结果给调用方，
    // 若这里是 Route<void>，`pushNamed<String?>` 的类型转换会在运行期失败。
    return MaterialPageRoute<dynamic>(settings: settings, builder: builder);
  }

  WidgetBuilder? _builderFor(RouteSettings settings) {
    switch (settings.name) {
      case AppRoutes.root:
        return (context) => const RootTabsScreen();
      case AppRoutes.welcome:
        return (context) => const WelcomeScreen();
      case AppRoutes.emptyHome:
        return (context) => const EmptyHomeScreen();
      case AppRoutes.home:
        return (context) => const HomeScreen();

      case AppRoutes.billImport:
        return (context) => const ImportSourceScreen();
      case AppRoutes.exportGuide:
        return (context) => const ExportGuideScreen();
      case AppRoutes.upload:
        return (context) => UploadScreen(
          args: settings.arguments is ImportSourceArgs
              ? settings.arguments! as ImportSourceArgs
              : null,
        );
      case AppRoutes.parsing:
        return (context) => const ParsingScreen();
      case AppRoutes.mapping:
        return (context) => const MappingScreen();
      case AppRoutes.checkImport:
        return (context) => const CheckImportScreen();
      case AppRoutes.duplicates:
        return (context) => const DuplicatesScreen();
      case AppRoutes.importError:
        return (context) => const ImportErrorScreen();

      case AppRoutes.cards:
        return (context) => const CardsScreen();
      case AppRoutes.allCategories:
        final args = settings.arguments;
        return (context) => AllCategoriesScreen(
          args: args is CategoryPickArgs
              ? args
              : const CategoryPickArgs(purpose: CategoryPickPurpose.card),
        );
      case AppRoutes.categoryManage:
        return (context) => const CategoryManageScreen();
      case AppRoutes.categoryEditor:
        final args = settings.arguments;
        return (context) => CategoryEditorScreen(
          args: args is CategoryEditorArgs
              ? args
              : const CategoryEditorArgs(categoryName: null),
        );
      case AppRoutes.transactionDetail:
        final args = settings.arguments;
        return (context) => TransactionDetailScreen(
          args: args is TransactionDetailArgs
              ? args
              : const TransactionDetailArgs(),
        );
      case AppRoutes.splitTransaction:
        final splitArgs = settings.arguments;
        return (context) => SplitScreen(
          // 没有参数时给一个不存在的 ID，页面会如实说「这笔记录已经不在了」，
          // 而不是随手拆了别的记录。
          transactionId: splitArgs is SplitArgs ? splitArgs.transactionId : 0,
        );
      case AppRoutes.transactionNature:
        final natureArgs = settings.arguments;
        return (context) => TransactionNatureScreen(
          transactionId: natureArgs is NatureArgs
              ? natureArgs.transactionId
              : 0,
        );
      case AppRoutes.pendingQueue:
        return (context) => const PendingQueueScreen();
      case AppRoutes.reviewComplete:
        return (context) => const ReviewCompleteScreen();

      case AppRoutes.report:
        return (context) => const ReportScreen();
      case AppRoutes.breakdown:
        final args = settings.arguments;
        return (context) => BreakdownScreen(
          args: args is BreakdownArgs ? args : const BreakdownArgs(),
        );
      case AppRoutes.trends:
        return (context) => const TrendsScreen();
      case AppRoutes.transactions:
        final args = settings.arguments;
        return (context) => TransactionsScreen(
          args: args is TransactionsArgs ? args : const TransactionsArgs(),
        );
      case AppRoutes.share:
        return (context) => const ShareScreen();
      case AppRoutes.months:
        return (context) => const MonthsScreen();

      case AppRoutes.profile:
        return (context) => const ProfileScreen();
      case AppRoutes.theme:
        return (context) => const ThemeScreen();
      case AppRoutes.importHistory:
        return (context) => const ImportHistoryScreen();
      case AppRoutes.privacy:
        return (context) => const PrivacyScreen();
      case AppRoutes.reminder:
        return (context) => ReminderScreen(controller: _reminder);
      case AppRoutes.deleteConfirm:
        return (context) => DeleteConfirmScreen(reminder: _reminder);
      case AppRoutes.offlineStatus:
        return (context) => const OfflineStatusScreen();

      case AppRoutes.designReview:
        // 只在调试构建注册。Release 里这个分支永远拿不到。
        if (!AppRoutes.isDesignReviewEnabled) return null;
        return (context) => const DesignReviewScreen();

      default:
        return null;
    }
  }
}

/// 四个一级标签的宿主。
///
/// 用 [IndexedStack] 保留各标签的滚动位置与局部状态，切换标签**不会**
/// 反复压入相同页面（指南 5.1）。
class RootTabsScreen extends StatelessWidget {
  const RootTabsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final selection = TabScope.of(context);
    // 每个标签各包一层 RepaintBoundary：未激活的标签不参与绘制，
    // 激活的那个会缓存成独立图层。
    // 这样从二级页返回（包括预见式返回动画）时，底层的根页面只需重新合成
    // 已有图层，不必逐帧整页重新栅格化。
    return IndexedStack(
      index: selection.index,
      children: const <Widget>[
        RepaintBoundary(child: HomeTabScreen()),
        RepaintBoundary(child: CardsScreen()),
        RepaintBoundary(child: ReportScreen()),
        RepaintBoundary(child: ProfileScreen()),
      ],
    );
  }
}

/// 未知路由的兜底页面。
class YounumUnknownRouteScreen extends StatelessWidget {
  const YounumUnknownRouteScreen({super.key, this.route});

  final String? route;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '这个页面不存在或已收起：${route ?? '（未命名）'}\n'
              '按返回键回到上一页。',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}

/// 让底部导航的高亮跟着当前路由走。
///
/// 没这个之前，只有用户自己点底部导航才会换高亮；从别处**跳**到某个一级
/// 标签页（通知点进来、首页的「继续整理」）时，就会出现
/// 「人在整理页、高亮停在首页」这种自相矛盾的界面 —— 真机上碰到过。
///
/// [TabSelection.syncFromRoute] 只认四个一级标签，其余路由不动高亮，
/// 所以详情页、导入流程这些压栈不会误改高亮。
class _TabHighlightObserver extends NavigatorObserver {
  _TabHighlightObserver(this.tabs);

  final TabSelection tabs;

  /// 压入一级标签页之前的高亮。根路由（底部导航外壳）的高亮才是
  /// 「用户原本在哪儿」；压栈只是临时盖在上面的一层，退回来要还原。
  int? _before;

  static int _indexOf(Route<dynamic>? route) =>
      AppRoutes.tabs.indexOf(route?.settings.name ?? '');

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    final index = _indexOf(route);
    if (index < 0) return;
    _before = tabs.index;
    tabs.select(index);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    if (_indexOf(route) < 0) return;
    tabs.select(_before ?? tabs.index);
    _before = null;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    final index = _indexOf(newRoute);
    if (index >= 0) tabs.select(index);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    if (_indexOf(route) < 0) return;
    tabs.select(_before ?? tabs.index);
    _before = null;
  }
}
