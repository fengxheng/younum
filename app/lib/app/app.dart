import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/preferences/app_state_store.dart';
import '../core/preferences/theme_controller.dart';
import '../domain/repositories/ledger_file_source.dart';
import '../domain/repositories/ledger_repository.dart';
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

  @override
  State<YounumApp> createState() => _YounumAppState();
}

class _YounumAppState extends State<YounumApp> {
  final TabSelection _tabs = TabSelection();
  late final ReviewSession _review = ReviewSession(
    repository: widget.ledgerRepository,
  );
  late final ImportSession _import = ImportSession(
    repository: widget.ledgerRepository,
    fileSource: widget.ledgerFileSource,
    ledgerId: _ledgerIdFor(widget.appStateController.isDemoLedger),
  );
  late final CategoryRegistry _registry = CategoryRegistry(
    initial: <String, CategoryIconConfig>{
      // 演示账本预置两个自定义分类，让「我的分类」有内容可看。
      '宠物': const CategoryIconConfig.builtin('heart'),
      '学习成长': const CategoryIconConfig.builtin('file'),
    },
    customNames: <String>['宠物', '学习成长'],
  );

  @override
  void initState() {
    super.initState();
    // 账本模式存在偏好里，启动时按它把会话接到对应账本。
    widget.appStateController.addListener(_syncLedgerMode);
    _review.useLedger(isDemo: widget.appStateController.isDemoLedger);
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
    widget.appStateController.removeListener(_syncLedgerMode);
    _tabs.dispose();
    _review.dispose();
    _import.dispose();
    _registry.dispose();
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
                    child: MaterialApp(
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
        return (context) => const SplitScreen();
      case AppRoutes.transactionNature:
        return (context) => const TransactionNatureScreen();
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
        return (context) => const ReminderScreen();
      case AppRoutes.deleteConfirm:
        return (context) => const DeleteConfirmScreen();
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
