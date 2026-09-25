import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/app/app.dart';
import 'package:younum/core/components/buttons.dart';
import 'package:younum/core/components/screen_scaffold.dart';
import 'package:younum/core/components/sheets.dart';
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

  /// 真实的 Release 正文就是这个长度：小节、列表、注意事项都有。
  ///
  /// 弹层里的更新说明是**原文照搬**的，所以不能按「一句话」去设计。
  const longNotes = '''
修复：导入之后界面不刷新

导入完成、回到首页却什么都没有 —— 「导入记录」里明明每一批都写着「已导入」，
把应用杀掉重开，数据又都在。根因是首页、整理、月报各自拿着一份已经加载好的
账单快照，而导入改的是数据库，提交完没有人通知它们重新读一遍。

· 提交与撤回之后，首页 / 整理 / 月报 / 明细会立刻重新读账本，不需要重启；
· 导入的账单不是当前月份的时，界面会自己走到那个月；
· 刷新失败不会被说成导入失败 —— 账已经写进去了就照实报成功。

说明

· 直接覆盖安装即可：账单、分类、整理进度都会保留。
· 这一版只改了上面这一处，没有别的行为变化。

已知限制

· 真机上的系统文件选择器、相册写入、六套主题逐页对比度、系统字号调到最大、
  TalkBack、横屏旋转，仍未逐项走查完毕；清单在 docs/MANUAL_CHECKS.md 里，
  标着「未验证」的没有当成已验证。
· 没有账号、没有云同步，换机不会自动恢复数据。
''';

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

  /// 关掉启动时的新版本提示层。
  ///
  /// 除了专门测这个弹层的用例，其他用例都得先把它点掉 —— 它盖在整棵树上，
  /// 不点掉的话后面的点击都是「点在弹层上」。
  Future<void> dismissStartupPrompt(WidgetTester tester) async {
    final later = find.text('以后再说');
    if (later.evaluate().isEmpty) return;
    await tester.tap(later);
    await tester.pumpAndSettle();
  }

  Future<void> pumpApp(WidgetTester tester, {bool dismissPrompt = true}) async {
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
    if (dismissPrompt) await dismissStartupPrompt(tester);
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

  testWidgets('按钮之间不许贴在一起（真机上看着像叠在一起）', (tester) async {
    // 这条是从真机截图来的：两个同色实底按钮首尾相接时，圆角处会出现一条
    // 「蝴蝶结」接缝，看上去就是两块叠在一起。间距不是装饰，是把两个可点区域
    // 在视觉上分开 —— 所以这里量的是**矩形之间有没有留空隙**。
    source.result = UpdateFound(info(2));
    installer.canInstallAllowed = false;
    await pumpApp(tester);
    await openUpdate(tester);

    final rects = <Rect>[
      for (var i = 0; i < tester.widgetList<PrimaryAction>(find.byType(PrimaryAction)).length; i++)
        tester.getRect(find.byType(PrimaryAction).at(i)),
    ];
    expect(rects.length, greaterThanOrEqualTo(3), reason: '这一页应有多个操作按钮');

    for (var i = 0; i < rects.length; i++) {
      for (var j = i + 1; j < rects.length; j++) {
        final a = rects[i];
        final b = rects[j];
        // 纵向相邻的两个按钮：下面那个的顶边必须在上面那个的底边之下，且留出空隙。
        final gap = b.top - a.bottom;
        expect(
          gap,
          greaterThan(0),
          reason: '第 ${i + 1} 个与第 ${j + 1} 个按钮重叠了（gap=$gap）',
        );
      }
    }
  });

  group('启动时的新版本提示', () {
    // 为什么要有这一组：启动时查到了新版本却**什么都不说**，等于没查；
    // 而每次启动都拿同一个版本反复烦用户，同样是错的。
    // 两条边界都在下面守着：「忽略过的版本不再提」与「以后再说 ≠ 忽略」。

    testWidgets('查到新版本就弹一次，把版本号和三条路都说清', (tester) async {
      source.result = UpdateFound(info(2));
      await pumpApp(tester, dismissPrompt: false);

      expect(find.text('有新版本 1.1.0'), findsOneWidget);
      expect(find.text('这版修了几个小问题。'), findsWidgets, reason: '更新说明要给出来');
      expect(find.text('去更新'), findsOneWidget);
      expect(find.text('忽略这个版本'), findsOneWidget);
      expect(find.text('以后再说'), findsOneWidget);
    });

    testWidgets('查不到时什么都不弹：断网不该在每次启动时报错', (tester) async {
      source.result = const UpdateUnreadable('连不上网络，稍后再试');
      await pumpApp(tester, dismissPrompt: false);

      expect(find.text('以后再说'), findsNothing);
      expect(find.text('连不上网络，稍后再试'), findsNothing, reason: '用户没问，就别告诉他');
    });

    testWidgets('已经是最新的版本不弹', (tester) async {
      // 当前版本是 1，远端也是 1：没有可装的东西。
      source.result = UpdateFound(info(1));
      await pumpApp(tester, dismissPrompt: false);

      expect(find.text('以后再说'), findsNothing);
    });

    testWidgets('点「去更新」进到检查更新页', (tester) async {
      source.result = UpdateFound(info(2));
      await pumpApp(tester, dismissPrompt: false);

      await tester.tap(find.text('去更新'));
      await tester.pumpAndSettle();

      expect(find.text('当前版本'), findsOneWidget);
      expect(find.text('下载并安装'), findsOneWidget);
    });

    testWidgets('点「忽略这个版本」：写进偏好，下次启动不再弹', (tester) async {
      source.result = UpdateFound(info(2));
      await pumpApp(tester, dismissPrompt: false);

      await tester.tap(find.text('忽略这个版本'));
      await tester.pumpAndSettle();

      expect(await updateStore.loadSkippedVersionCode(), 2);

      // 重新启动一次（销毁整棵树再挂一遍），这次不该再打扰用户。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await pumpApp(tester, dismissPrompt: false);

      expect(find.text('以后再说'), findsNothing, reason: '忽略过的版本不再提');
      expect(find.text('忽略这个版本'), findsNothing);
    });

    testWidgets('出现更高的版本时还会再提一次', (tester) async {
      // 忽略的语义是「这一版我先不装」，不是「以后别告诉我」。
      await updateStore.saveSkippedVersionCode(2);
      source.result = UpdateFound(info(3, '1.2.0'));
      await pumpApp(tester, dismissPrompt: false);

      expect(find.text('有新版本 1.2.0'), findsOneWidget);
    });

    testWidgets('点「以后再说」什么都不记：下次启动还会提', (tester) async {
      source.result = UpdateFound(info(2));
      await pumpApp(tester, dismissPrompt: false);

      await tester.tap(find.text('以后再说'));
      await tester.pumpAndSettle();

      expect(
        await updateStore.loadSkippedVersionCode(),
        isNull,
        reason: '把「以后再说」也记成忽略，用户就再也等不到提醒了',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await pumpApp(tester, dismissPrompt: false);

      expect(find.text('以后再说'), findsOneWidget);
    });

    testWidgets('用户自己点「检查更新」查到的结果不弹层', (tester) async {
      // 启动那次查不到（断网），用户进页之后手动查到了：
      // 他已经在看着结果了，再弹一个层只会盖住他自己要的东西。
      source.result = const UpdateUnreadable('连不上网络，稍后再试');
      await pumpApp(tester, dismissPrompt: false);
      await openUpdate(tester);

      source.result = UpdateFound(info(2));
      await tapAction(tester, '检查更新');

      expect(find.text('有新版本 1.1.0'), findsOneWidget, reason: '结果在页面上');
      expect(find.text('以后再说'), findsNothing, reason: '不该再弹一层');
    });

    testWidgets('三个按钮都在弹层里，而且不贴在一起', (tester) async {
      // 「两个同色实底按钮首尾相接、圆角处看着像叠在一起」是这个工程真栽过的坑，
      // 所以这里量的是矩形之间的实际间隙，不是「大概看了一眼」。
      source.result = UpdateFound(info(2));
      await pumpApp(tester, dismissPrompt: false);

      final sheet = find.byType(YounumSheetSurface);
      final actions = find.descendant(
        of: sheet,
        matching: find.byType(PrimaryAction),
      );
      expect(actions, findsNWidgets(3), reason: '去更新 / 忽略这个版本 / 以后再说');

      final sheetRect = tester.getRect(sheet);
      final rects = <Rect>[
        for (var i = 0; i < 3; i++) tester.getRect(actions.at(i)),
      ];
      for (var i = 0; i < rects.length; i++) {
        expect(
          sheetRect.contains(rects[i].topLeft) &&
              sheetRect.contains(rects[i].bottomRight),
          isTrue,
          reason: '第 ${i + 1} 个按钮跑到弹层外面去了',
        );
      }
      for (var i = 0; i + 1 < rects.length; i++) {
        expect(
          rects[i + 1].top - rects[i].bottom,
          greaterThan(0),
          reason: '第 ${i + 1} 与 ${i + 2} 个按钮贴在一起了（展开看起来像叠成一块）',
        );
      }
    });

    testWidgets('更新说明很长时也放得下（Release 正文可能很长）', (tester) async {
      // 说明是**原文照搬** GitHub Release 正文的，写多长由发布的人决定，
      // 所以不能按「一句话」去设计这个弹层。
      source.result = UpdateFound(
        UpdateInfo(
          versionCode: 2,
          versionName: '1.1.0',
          apkUrl: 'https://example.com/younum-2.apk',
          releaseUrl: 'https://example.com/releases/2',
          notes: longNotes,
        ),
      );
      await pumpApp(tester, dismissPrompt: false);

      expect(tester.takeException(), isNull, reason: '说明再长也不能溢出');
      expect(find.text('以后再说'), findsOneWidget, reason: '出路不能被挤出屏幕');
    });

    testWidgets('系统字号调到 2.0，弹层依然能看全、不溢出', (tester) async {
      // 字放大之后弹层变高，如果内容不可滚动就会直接溢出（渲染期抛异常）。
      // 这一条是把它钉住：文字想调多大就多大，容器去适应它。
      //
      // ⚠️ 这里进演示账本，而不是留在空首页：空首页那张装饰插画在字号 2.0 下
      // 会自己溢出（`start_screens.dart` 的 `_MiniReceipt`，与本次改动无关，
      // 已记在 docs/MANUAL_CHECKS.md），留着它会把这一条淹掉。
      await appStateController.enterDemoLedger();
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      source.result = UpdateFound(info(2));
      await pumpApp(tester, dismissPrompt: false);

      expect(tester.takeException(), isNull, reason: '溢出会在渲染期抛异常');
      expect(find.text('去更新'), findsOneWidget);
      expect(find.text('以后再说'), findsOneWidget);
    });
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
