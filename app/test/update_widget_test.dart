import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/app/app.dart';
import 'package:younum/core/components/buttons.dart';
import 'package:younum/core/components/screen_scaffold.dart';
import 'package:younum/core/preferences/app_state_store.dart';
import 'package:younum/core/preferences/theme_controller.dart';
import 'package:younum/core/preferences/theme_store.dart';
import 'package:younum/core/preferences/update_store.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/domain/repositories/update_ports.dart';
import 'package:younum/domain/rules/update_rules.dart';

/// 「我的 → 检查更新」的界面接线。
///
/// 这一页最怕的两件事：**偷偷什么都没做**，以及**把没查到说成已是最新**。
/// 两条都在下面有用例。
void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late ThemeController themeController;
  late AppStateController appStateController;
  late _FakeSource source;
  late _FakeInstaller installer;
  late InMemoryUpdateStore updateStore;

  UpdateInfo info(int code, [String name = '1.1.0']) => UpdateInfo(
    versionCode: code,
    versionName: name,
    apkUrl: 'https://example.com/younum-$code.apk',
    releaseUrl: 'https://example.com/releases/$code',
    notes: '这版修了几个小问题。',
  );

  setUp(() async {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(1080, 2400);
    view.devicePixelRatio = 2.75;

    store = InMemoryLedgerStore();
    repository = LedgerRepository(store);
    await repository.initialize();
    themeController = await ThemeController.restore(InMemoryThemeStore());
    appStateController = await AppStateController.restore(
      InMemoryAppStateStore(),
    );
    await appStateController.completeOnboarding();
    source = _FakeSource();
    installer = _FakeInstaller();
    updateStore = InMemoryUpdateStore();
  });

  tearDown(() {
    themeController.dispose();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      YounumApp(
        themeController: themeController,
        appStateController: appStateController,
        ledgerRepository: repository,
        ledgerFileSource: const UnsupportedFileSource(),
        updateSource: source,
        updateInstaller: installer,
        updateStore: updateStore,
        appVersion: const AppVersion(versionName: '1.0.0', versionCode: 1),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 切到「我的」标签页。
  Future<void> openProfile(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byType(AppBottomBar),
        matching: find.text('我的'),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 点页面里的按钮。
  ///
  /// 不能直接用 `find.text`：「检查更新」既是「我的」页那一行的标题，
  /// 也是详情页里按钮的文案，两处都会匹配到。
  Future<void> tapAction(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byType(PrimaryAction),
        matching: find.text(label),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 我的 → 检查更新。
  Future<void> openUpdate(WidgetTester tester) async {
    await openProfile(tester);
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
  }

  testWidgets('启动时就静默查过一次，入口上直接显示结果', (tester) async {
    source.result = UpdateFound(info(2));
    await pumpApp(tester);
    await openProfile(tester);

    // 用户不必点进去才知道有没有新版。
    expect(source.calls, 1, reason: '启动时查一次');
    expect(find.textContaining('有新版本 1.1.0'), findsOneWidget);
  });

  testWidgets('有新版本：说清版本号，能下载，也能忽略', (tester) async {
    source.result = UpdateFound(info(2));
    await pumpApp(tester);
    await openUpdate(tester);

    expect(find.text('有新版本 1.1.0'), findsOneWidget);
    expect(find.text('这版修了几个小问题。'), findsOneWidget, reason: '更新说明要显示');

    await tester.tap(find.text('下载并安装'));
    await tester.pumpAndSettle();

    expect(installer.installedUrls, <String>['https://example.com/younum-2.apk']);
    expect(find.textContaining('系统'), findsWidgets);
  });
  testWidgets('忽略之后不再提示，但页面仍留着手动安装的入口', (tester) async {
    source.result = UpdateFound(info(2));
    await pumpApp(tester);
    await openUpdate(tester);

    await tester.tap(find.text('忽略这个版本'));
    await tester.pumpAndSettle();

    expect(await updateStore.loadSkippedVersionCode(), 2);
    expect(find.textContaining('忽略过'), findsOneWidget);
    expect(find.text('下载并安装'), findsOneWidget, reason: '忽略不是隐藏');
  });

  testWidgets('查不到时如实说查不到，绝不能写成「已是最新」', (tester) async {
    source.result = const UpdateUnreadable('连不上网络，稍后再试');
    await pumpApp(tester);
    await openUpdate(tester);

    await tapAction(tester, '检查更新');

    expect(find.text('连不上网络，稍后再试'), findsOneWidget);
    expect(find.text('已经是最新版本。'), findsNothing);
    expect(find.text('下载并安装'), findsNothing);
  });

  testWidgets('系统没允许安装应用时：先把话说清，并给出过去打开的路', (tester) async {
    source.result = UpdateFound(info(2));
    installer.canInstallAllowed = false;
    await pumpApp(tester);
    await openUpdate(tester);

    expect(find.textContaining('还没允许'), findsOneWidget);
    await tapAction(tester, '去允许安装');

    expect(installer.openedSettings, isTrue);
  });
}

final class _FakeSource implements UpdateSource {
  UpdateReadResult result = const UpdateUnreadable('测试没准备结果');
  int calls = 0;

  @override
  Future<UpdateReadResult> fetchLatest() async {
    calls++;
    return result;
  }
}

final class _FakeInstaller implements UpdateInstaller {
  InstallOutcome outcome = const InstallHandedOff();
  bool canInstallAllowed = true;
  bool openedSettings = false;
  final List<String> installedUrls = <String>[];

  @override
  ValueListenable<int?> get progress => _progress;
  final ValueNotifier<int?> _progress = ValueNotifier<int?>(null);

  @override
  Future<bool> canInstall() async => canInstallAllowed;

  @override
  Future<void> openInstallSettings() async => openedSettings = true;

  @override
  Future<InstallOutcome> downloadAndInstall(UpdateInfo info) async {
    installedUrls.add(info.apkUrl);
    return outcome;
  }
}
