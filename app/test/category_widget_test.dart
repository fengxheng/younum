import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/app/app.dart';
import 'package:younum/core/components/buttons.dart';
import 'package:younum/core/components/screen_scaffold.dart';
import 'package:younum/core/designsystem/younum_icons.dart';
import 'package:younum/core/preferences/app_state_store.dart';
import 'package:younum/core/preferences/theme_controller.dart';
import 'package:younum/core/preferences/theme_store.dart';
import 'package:younum/data/files/icon_asset_store.dart';
import 'package:younum/data/files/icon_image_processor.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/category.dart';
import 'package:younum/domain/repositories/icon_asset_ports.dart';
import 'package:younum/domain/repositories/image_file_source.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/features/organize/category_screens.dart';

/// 分类管理的界面接线（指南 3.5.8 / 14.3）。
///
/// 之前这一块只写内存注册表：新建的分类重启就没了，库里也查不到，
/// 于是整理时选它等于选了一个不存在的分类。这些用例断言的是
/// **库里真的有了那条分类**，而不只是页面上多了一行。
void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late ThemeController themeController;
  late AppStateController appStateController;
  late Directory iconDirectory;
  late FileIconAssetStore iconFiles;

  /// 测试可以换成假实现，避免在 widget 测试里真的跑引擎解码。
  IconThumbnailMaker? fakeThumbnails;

  const int ledgerId = DemoLedgerSeed.demoLedgerId;

  setUp(() async {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(1080, 2400);
    view.devicePixelRatio = 2.75;

    iconDirectory = await Directory.systemTemp.createTemp('younum_icons_ui_');
    iconFiles = FileIconAssetStore(directoryOf: () async => iconDirectory.path);
    store = InMemoryLedgerStore();
    repository = LedgerRepository(
      store,
      thumbnails: fakeThumbnails ?? const IconImageProcessor(),
      iconFiles: iconFiles,
    );
    await repository.initialize();
    themeController = await ThemeController.restore(InMemoryThemeStore());
    appStateController = await AppStateController.restore(
      InMemoryAppStateStore(),
    );
    await appStateController.completeOnboarding();
    await appStateController.enterDemoLedger();
  });

  tearDown(() async {
    themeController.dispose();
    if (await iconDirectory.exists()) {
      await iconDirectory.delete(recursive: true);
    }
  });

  Future<Category?> categoryNamed(String name) async {
    final categories = await repository.categories(ledgerId: ledgerId);
    for (final category in categories) {
      if (category.name == name) return category;
    }
    return null;
  }

  /// 我的 → 分类管理。
  Future<void> openManage(WidgetTester tester, {ImageFileSource? imageSource}) async {
    await tester.pumpWidget(
      YounumApp(
        themeController: themeController,
        appStateController: appStateController,
        ledgerRepository: repository,
        ledgerFileSource: const UnsupportedFileSource(),
        imageFileSource: imageSource ?? const UnsupportedImageSource(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byType(AppBottomBar),
        matching: find.text('我的'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('分类管理'));
    await tester.pumpAndSettle();
  }

  testWidgets('分类管理列出库里的分类（含自定义的「宠物」）', (WidgetTester tester) async {
    await openManage(tester);

    expect(find.byType(CategoryManageScreen), findsOneWidget);
    expect(find.text('餐饮'), findsWidgets);
    expect(
      find.text('宠物'),
      findsWidgets,
      reason: '自定义分类也要出现在管理页里',
    );
    expect(find.text('+ 新建'), findsOneWidget);
  });

  /// 点一个可能落在折叠线以下的控件。
  ///
  /// 图标库变大（几十个预设 + emoji 输入）之后，编辑器页面变长了 ——
  /// 而 `tester.tap` 对屏幕外的控件只是「点了个空」，不报错：
  /// 用例会以「什么都没发生」的形式失败。所以先滚到它。
  Future<void> tapBelowFold(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('新建分类真的写进分类表，不只是页面上多一行', (WidgetTester tester) async {
    expect(await categoryNamed('养花'), isNull, reason: '前提：还没有这个分类');

    await openManage(tester);
    await tester.tap(find.text('+ 新建'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '养花');
    await tester.pumpAndSettle();
    await tapBelowFold(tester, find.text('保存分类'));

    final saved = await categoryNamed('养花');
    expect(saved, isNotNull, reason: '关键：库里有它，整理时才能选到');
    expect(saved!.isBuiltin, isFalse);
    expect(saved.iconKey, isNotNull);
    expect(find.byType(CategoryManageScreen), findsOneWidget);
    expect(find.text('养花'), findsWidgets);
  });

  /// 整理页「已整理 n / N 笔」里的 n。
  int doneCount(WidgetTester tester) {
    final text = tester
        .widgetList<Text>(find.textContaining('已整理'))
        .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
        .firstWhere((value) => value.contains('已整理'));
    return int.parse(RegExp(r'已整理 (\d+)').firstMatch(text)!.group(1)!);
  }

  testWidgets('新建的分类，卡片上立刻就能选中并确认（不用重启应用）', (
    WidgetTester tester,
  ) async {
    // 真机上就是这么撞上的：在「分类管理」里新建了一个用途（收入），
    // 回到卡片里选中它、右滑 —— **卡片什么都不说地回弹**，像是手势坏了。
    //
    // 根因不在手势：会话手里的分类列表是**启动时读的那一份**，
    // 新建的分类不在里面，于是「名字 → 分类 ID」换不出来，
    // `confirmCurrent` 静默返回 false（见 DECISIONS.md 78 节）。
    // 杀掉应用重开之后就好了 —— 那是典型的「界面拿着旧快照」。
    await openManage(tester);
    await tester.tap(find.text('+ 新建'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '收入');
    await tester.pumpAndSettle();
    await tapBelowFold(tester, find.text('保存分类'));

    final created = await categoryNamed('收入');
    expect(created, isNotNull, reason: '前提：分类真的建好了');

    // 保存后会弹一条「分类已保存」提示条：先把它的 2 秒等过去再走。
    // 不等的话，路由动画期间两条提示条会撞成同一个 hero tag，
    // Flutter 自己会抛断言（与要验的东西无关）。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    // 回到卡片页：分类管理 → 我的 → 整理。
    await tester.tap(find.byIcon(YounumIcons.back).first);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AppBottomBar),
        matching: find.text('整理'),
      ),
    );
    await tester.pumpAndSettle();

    // 从「全部分类」里选刚建的那个，再用。
    await tester.tap(find.textContaining('全部分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收入').first);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('使用此分类'));
    await tester.pumpAndSettle();

    final before = doneCount(tester);
    await tester.drag(
      find.byKey(const ValueKey<String>('review-card-stack')),
      const Offset(200, 0),
    );
    await tester.pumpAndSettle();

    expect(
      doneCount(tester),
      before + 1,
      reason: '新建的分类必须能马上用来确认，不能等重启',
    );

    // 而且真的落库了：这笔的用途就是新建的那个分类。
    final dataset = await repository.dataset(ledgerId: ledgerId);
    expect(
      dataset
          .allocationsOf(DemoLedgerSeed.transactionIdAt(0))
          .map((allocation) => allocation.categoryId)
          .toList(),
      <int>[created!.id],
    );
  });

  testWidgets('同级重名被拒绝：显示原因、不落库、也不离开这一页', (WidgetTester tester) async {
    await openManage(tester);
    await tester.tap(find.text('+ 新建'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '餐饮');
    await tester.pumpAndSettle();
    await tapBelowFold(tester, find.text('保存分类'));

    expect(find.text('这个分类已经存在'), findsOneWidget);
    expect(
      find.byType(CategoryEditorScreen),
      findsOneWidget,
      reason: '保存失败不能返回上一页，否则用户以为存上了',
    );
    final categories = await repository.categories(ledgerId: ledgerId);
    expect(
      categories.where((category) => category.name == '餐饮'),
      hasLength(1),
      reason: '被拒之后库里不该多出一条同名分类',
    );
  });

  testWidgets('改图标落库，名字与 ID 都不动', (WidgetTester tester) async {
    final before = (await categoryNamed('宠物'))!;

    await openManage(tester);
    await tester.tap(find.text('宠物'));
    await tester.pumpAndSettle();

    // 选一个与原来不同的预设图标（宠物原来是 heart，这里选咖啡）。
    await tapBelowFold(tester, find.text('咖啡'));
    await tapBelowFold(tester, find.text('保存图标'));

    final after = (await categoryNamed('宠物'))!;
    expect(after.id, before.id, reason: 'ID 是稳定标识，不能跟着图标变');
    expect(after.name, before.name);
    expect(after.iconKey, 'coffee');
  });

  testWidgets('删除一个自建分类：真的归档，而且能在「已归档」里找回来', (
    WidgetTester tester,
  ) async {
    // 指南 3.5.8：分类删除默认归档，历史引用继续有效。
    await openManage(tester);
    expect(find.text('已归档'), findsNothing, reason: '前提：还没有归档过任何分类');

    await tester.tap(find.text('宠物'));
    await tester.pumpAndSettle();
    // 编辑页顶部有图标网格、图片入口、合并入口……「删除」在最底下，
    // 小屏上会落在可视区之外。先滚到它再点，别让 tap 打空气。
    await tester.ensureVisible(find.text('删除此分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除此分类'));
    await tester.pumpAndSettle();

    // 确认弹层要把「变的是什么、不变的是什么」说清楚。
    expect(find.textContaining('已经用它归好类的记录不受影响'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    final archived = await categoryNamed('宠物');
    expect(archived, isNotNull, reason: '归档不是删除数据：分类行还在');
    expect(archived!.archived, isTrue);
    expect(find.byType(CategoryManageScreen), findsOneWidget, reason: '删完回到管理页');
    expect(find.text('已归档'), findsOneWidget, reason: '管理页要给出回来的路');

    // 恢复。
    //
    // 两个「等」都不能省：
    // ① 上一步归档时会弹一条浮动提示条，它就浮在屏幕底部，正好压住「恢复」
    //    这一行；不等它自己收掉（2 秒），点到的是提示条。
    // ② 管理页在图标网格上面多了一行「用途快捷项」，整段「已归档」跟着下移，
    //    小屏上「恢复」会落到可视区外（直接 tap 只会打空气，用例假红）。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('恢复'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();

    final restored = await categoryNamed('宠物');
    expect(restored!.archived, isFalse);
    expect(find.text('已归档'), findsNothing, reason: '恢复之后这一段就不该再显示');
  });

  testWidgets('内置分类只给「归档」，不给「删除」', (WidgetTester tester) async {
    await openManage(tester);
    await tester.tap(find.text('餐饮').first);
    await tester.pumpAndSettle();

    expect(find.text('归档此分类'), findsOneWidget);
    expect(find.text('删除此分类'), findsNothing);
  });

  testWidgets('只剩一个一级分类时，归档按钮置灰并说明原因', (WidgetTester tester) async {
    // 用途列表空了，用户整理时无从下手 —— 这个按钮必须先把话说在前面。
    final all = await repository.categories(ledgerId: ledgerId);
    final roots = <Category>[
      for (final category in all)
        if (category.isRoot) category,
    ];
    for (final root in roots.skip(1)) {
      await repository.setCategoryArchived(
        ledgerId: ledgerId,
        categoryId: root.id,
        archived: true,
      );
    }

    await openManage(tester);
    await tester.tap(find.text(roots.first.name).first);
    await tester.pumpAndSettle();

    final button = tester.widget<PrimaryAction>(
      find
          .ancestor(
            of: find.text('归档此分类'),
            matching: find.byType(PrimaryAction),
          )
          .first,
    );
    expect(button.onPressed, isNull, reason: '最后一个分类不能归档');
    expect(find.textContaining('这是最后一个分类'), findsWidgets);
  });
}
