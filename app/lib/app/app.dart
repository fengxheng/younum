import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/components/primitives.dart';
import '../core/components/sheets.dart';
import '../core/preferences/app_state_store.dart';
import '../core/preferences/category_pick_store.dart';
import '../core/preferences/reminder_controller.dart';
import '../core/preferences/reminder_store.dart';
import '../core/preferences/theme_controller.dart';
import '../domain/repositories/image_file_source.dart';
import '../domain/repositories/document_saver.dart';
import '../domain/repositories/ledger_file_source.dart';
import '../domain/repositories/ledger_repository.dart';
import '../domain/repositories/poster_ports.dart';
import '../core/preferences/update_store.dart';
import '../domain/repositories/reminder_scheduler.dart';
import '../domain/repositories/update_ports.dart';
import '../domain/rules/update_rules.dart';
import '../features/export/export_scope.dart';
import '../features/import_flow/import_screens.dart';
import '../features/import_flow/import_session.dart';
import '../features/import_flow/parse_screens.dart';
import '../features/organize/cards_screen.dart';
import '../features/organize/category_registry.dart';
import '../features/organize/category_screens.dart';
import '../features/organize/quick_pick_screen.dart';
import '../features/organize/review_screens.dart';
import '../features/organize/review_session.dart';
import '../features/profile/profile_screens.dart';
import '../features/profile/theme_screen.dart';
import '../features/profile/update_controller.dart';
import '../features/profile/update_screen.dart';
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
    this.updateSource = const UnsupportedUpdateSource(),
    this.updateInstaller = const UnsupportedUpdateInstaller(),
    this.updateStore,
    this.categoryPickStore,
    this.appVersion,
    this.databaseEncrypted = false,
    this.databaseEncryptionNote,
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

  /// 去哪里查最新版本。桌面与测试环境是不支持实现，界面会如实说明。
  final UpdateSource updateSource;

  /// 下载并交给系统安装器的能力。
  final UpdateInstaller updateInstaller;

  /// 「忽略这个版本」的持久化。不传就用内存实现（测试与降级路径）。
  final UpdateStore? updateStore;

  /// 用途快捷项（卡片上显示哪几个分类、按什么顺序）的持久化。
  /// 不传就用内存实现（测试与降级路径）。
  final CategoryPickStore? categoryPickStore;

  /// 当前安装的版本。读不到时为 null —— 那就**不做升级提示**，
  /// 而不是拿一个猜出来的版本号去比较。
  final AppVersion? appVersion;

  /// 数据库是不是加密存储。
  ///
  /// 界面要**如实显示**：加密没成功时用户有权知道，而不是以为已经加密了。
  final bool databaseEncrypted;

  /// 加密没成功时的原因（成功时为 null）。
  final String? databaseEncryptionNote;

  @override
  State<YounumApp> createState() => _YounumAppState();
}

class _YounumAppState extends State<YounumApp> with WidgetsBindingObserver {
  final TabSelection _tabs = TabSelection();

  /// 通知点进来时要跳页，必须能拿到 Navigator。
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// 正在处理一份分享进来的文件。
  ///
  /// 回到前台时会问两次（resume + 500ms 补问），而原生侧是「取走即清」：
  /// 没有这道闸，两次问会撞在一起，或者在解析大文件时又插进来一次。
  bool _sharedBusy = false;

  /// 启动时的升级提示已经弹过了（同一次启动只弹一次）。
  bool _promptedUpdate = false;
  late final ReviewSession _review = ReviewSession(
    repository: widget.ledgerRepository,
  );
  late final ImportSession _import = ImportSession(
    repository: widget.ledgerRepository,
    fileSource: widget.ledgerFileSource,
    ledgerId: _ledgerIdFor(widget.appStateController.isDemoLedger),
    onLedgerChanged: _reloadLedgerViews,
  );
  late final CategoryRegistry _registry = CategoryRegistry(
    repository: widget.ledgerRepository,
    imageSource: widget.imageFileSource,
    pickStore: widget.categoryPickStore ?? InMemoryCategoryPickStore(),
  );
  late final ReminderController _reminder = ReminderController(
    store: widget.reminderStore ?? InMemoryReminderStore(),
    scheduler: widget.reminderScheduler,
  );
  late final UpdateController _update = UpdateController(
    source: widget.updateSource,
    installer: widget.updateInstaller,
    store: widget.updateStore ?? InMemoryUpdateStore(),
    currentVersionCode: widget.appVersion?.versionCode ?? 0,
    currentVersionName: widget.appVersion?.versionName ?? '',
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
    // 升级检查：**静默**查一次（不阻塞启动、失败不留痕）。
    // 用户主动进「检查更新」时才会看到失败原因。
    // 版本号读不到（桌面、测试）就不查：没有基准没法比新旧。
    if (widget.appVersion != null) {
      _update.pruneSkipped();
      _update.check();
    }
    // 查完真的有新版本要**告诉**用户 —— 只提示一次，且忽略过的版本不提示。
    _update.addListener(_promptUpdateIfAvailable);
    // 点通知进来时要落到整理页（指南 8.2：通知跳转到需要整理的月份）。
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _openPendingRoute();
      // 分享进来的文件：冷启动时 intent 里就带着它。
      await _consumeSharedFile();
      // 静默检查可能在首帧之前就查完了，那时还没有 context 可以弹层。
      _promptUpdateIfAvailable();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 应用已经在后台时点通知，走的是 onNewIntent + 回到前台，两条路都要接。
    if (state != AppLifecycleState.resumed) return;
    _openPendingRoute();
    // 分享也是这样：应用在后台时被分享，回来时要从新 intent 里取。
    _consumeSharedFile();
    // onNewIntent 有时比 resume 晚到一步（真机上碰到过），再问一次就不会漏。
    // 路由取走即清、分享取走即清，所以重复问不会多跳一页、多导一份。
    Timer(const Duration(milliseconds: 500), () {
      _openPendingRoute();
      _consumeSharedFile();
    });
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

  /// 有没有一份从系统「分享」进来的文件，有就走导入流程。
  ///
  /// 冷启动与每次回到前台都会问一次：原生侧「取走即清」，所以问多少次都
  /// 只是问一遍；没有待处理的分享时它回 null，**不是**失败。
  Future<void> _consumeSharedFile() async {
    if (_sharedBusy) return;
    _sharedBusy = true;
    try {
      await _adoptSharedFile();
    } finally {
      _sharedBusy = false;
    }
  }

  Future<void> _adoptSharedFile() async {
    if (_navigatorKey.currentState == null) return;

    final PickOutcome? outcome;
    try {
      outcome = await widget.ledgerFileSource.takeSharedFile();
    } on Object catch (error) {
      // 读不到就当没有这一步：分享进来的东西不该把应用弄崩，
      // 也不该拦住用户本来要做的事。
      debugPrint('取分享进来的文件时出错：$error');
      return;
    }
    if (!mounted) return;

    switch (outcome) {
      // 绝大多数时候是这里：没有待处理的分享。
      case null:
      case PickCanceled():
        return;
      case PickFailed(:final message):
        await _showShareProblem(title: '这份文件没能读进来', description: message);
      case DocumentPicked(:final document):
        await _importSharedDocument(document);
    }
  }

  /// 把一份分享进来的文件走完导入的前半段。
  ///
  /// 顺序与「选文件」那条路一致：**先挂解析页、再开始解析**。反过来的话，
  /// 解析可能在页面挂上之前就结束，用户看到的是一个停住不动的转圈。
  Future<void> _importSharedDocument(PickedDocument document) async {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;

    if (_import.isBusy) {
      // 半截状态里插一份新文件，会让还在跑的那次解析拿到别人的字节。
      // 宁可说清楚，也不默默丢掉用户刚分享的东西。
      await _showShareProblem(
        title: '这次没能导入这份文件',
        description: '上一次导入还没走完（正在解析或提交）。等它结束之后再分享一次就好。',
        tone: YounumCircleTone.primary,
      );
      return;
    }

    // 分享进来时用户可能停在任意一页：先把页面栈收回到根，
    // 否则导入流程会盖在一堆旧页面上，返回时一层层弹很莫名其妙。
    navigator.popUntil((route) => route.isFirst);
    // 不 await：这个 Future 要等解析页被替换掉（成功）或弹回去（失败）才完成，
    // 而解析现在就该开始了。
    final flow = navigator.pushNamed(AppRoutes.parsing);
    await _import.stageSharedDocument(document);
    await flow;
    if (!mounted) return;

    // 失败时解析页会自己弹回来（它不负责解释原因）。用户是被分享唤起过来
    // 的，主页上不会有人告诉他发生了什么，所以要在这里把话说清楚。
    if (_import.phase == ImportPhase.failed) {
      await _showShareProblem(
        title: '这份文件没能导入',
        description: _import.errorMessage ?? '没能读懂这份文件',
      );
    }
  }

  Future<void> _showShareProblem({
    required String title,
    required String description,
    YounumCircleTone tone = YounumCircleTone.error,
  }) async {
    final context = _navigatorKey.currentState?.overlay?.context;
    if (context == null) return;
    await showNoticeSheet(
      context: context,
      title: title,
      description: description,
      tone: tone,
    );
  }

  /// 启动时查到新版本就提示一次。
  ///
  /// 三条约束：
  ///
  /// * 同一次启动**只提示一次**（不然每次回到前台都会弹）；
  /// * 用户自己点的「检查更新」不弹 —— 他已经在那一页上看着结果了；
  /// * 点过「忽略这个版本」的不弹，由 `UpdateRules.shouldPrompt` 挡住
  ///   （此时阶段是 [UpdatePhase.skipped]），出现更高的版本时才会再提。
  void _promptUpdateIfAvailable() {
    if (_promptedUpdate) return;
    if (_update.userAsked) return;
    if (_update.phase != UpdatePhase.available) return;
    final info = _update.available;
    if (info == null) return;
    // 首帧之前没有可以弹层的 context；首帧之后那次调用会补上。
    final context = _navigatorKey.currentState?.overlay?.context;
    if (context == null) return;

    _promptedUpdate = true;
    unawaited(_askAboutUpdate(context, info));
  }

  Future<void> _askAboutUpdate(BuildContext context, UpdateInfo info) async {
    final choice = await showUpdatePromptSheet(context: context, info: info);
    if (!mounted) return;
    switch (choice) {
      case UpdatePromptChoice.update:
        await _navigatorKey.currentState?.pushNamed(AppRoutes.update);
      case UpdatePromptChoice.skip:
        // 写进偏好：同一个版本不再打扰，出现更高版本再说。
        await _update.skipCurrent();
      case UpdatePromptChoice.later || null:
        // 「以后再说」**什么都不记**：下次启动还会提醒。
        break;
    }
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

  /// 导入提交 / 撤回之后，把「读账本」的会话重读一遍。
  ///
  /// 首页、整理、月报、明细读的都是 [ReviewSession] 里那一份已加载的快照，
  /// 而导入改的是数据库本身 —— 两者之间没有自动联系。不重读，用户提交完
  /// 回到首页会看到「这个月还没有账单」，以为白导了。
  ///
  /// 真机上就是这么报的：三批账单都写着「已导入」，整理页却还是空的，
  /// 杀掉应用重开数据又都在。所以「界面拿着旧快照」这件事只能在这里补。
  ///
  /// `followPreferredMonth` 是另一半：导入的账单可能不是用户正在看的那一个月，
  /// 那种情况下光重读还是看不到东西。跟着月份走的口径是
  /// 「导入之后看到的 = 重启之后看到的」。
  Future<void> _reloadLedgerViews() =>
      _review.reload(followPreferredMonth: true);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.appStateController.removeListener(_syncLedgerMode);
    _update.removeListener(_promptUpdateIfAvailable);
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
                    child: UpdateScope(
                      controller: _update,
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
                            // 下限不压低用户调小字号的意愿，也保住按默认字号设计的版式。
                            //
                            // ⚠️ 上限已经**去掉**了：曾经写死 1.6，理由是「堆叠卡片这类
                            // 固定高度容器会溢出」。那是把容器的限制转嫁给了用户 ——
                            // 指南 6.3 要的是「不固定屏幕总高度，大字号时允许滚动」。
                            // 现在卡片高度跟着字号一起长（见 `cardHeightFor`），
                            // 页面本身可滚动，字号想调多大就调多大。
                            return MediaQuery.withClampedTextScaling(
                              minScaleFactor: 0.85,
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
      case AppRoutes.categoryQuickPick:
        return (context) => const QuickPickScreen();
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
        return (context) => PrivacyScreen(
          encrypted: widget.databaseEncrypted,
          encryptionNote: widget.databaseEncryptionNote,
        );
      case AppRoutes.reminder:
        return (context) => ReminderScreen(controller: _reminder);
      case AppRoutes.deleteConfirm:
        return (context) => DeleteConfirmScreen(reminder: _reminder);
      case AppRoutes.offlineStatus:
        return (context) => const OfflineStatusScreen();
      case AppRoutes.update:
        return (context) => const UpdateScreen();

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
