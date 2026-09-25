import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/app/app.dart';
import 'package:younum/core/components/screen_scaffold.dart';
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

  testWidgets('新建分类真的写进分类表，不只是页面上多一行', (WidgetTester tester) async {
    expect(await categoryNamed('养花'), isNull, reason: '前提：还没有这个分类');

    await openManage(tester);
    await tester.tap(find.text('+ 新建'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '养花');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存分类'));
    await tester.pumpAndSettle();

    final saved = await categoryNamed('养花');
    expect(saved, isNotNull, reason: '关键：库里有它，整理时才能选到');
    expect(saved!.isBuiltin, isFalse);
    expect(saved.iconKey, isNotNull);
    expect(find.byType(CategoryManageScreen), findsOneWidget);
    expect(find.text('养花'), findsWidgets);
  });

  testWidgets('同级重名被拒绝：显示原因、不落库、也不离开这一页', (WidgetTester tester) async {
    await openManage(tester);
    await tester.tap(find.text('+ 新建'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '餐饮');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存分类'));
    await tester.pumpAndSettle();

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
    await tester.tap(find.text('咖啡'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存图标'));
    await tester.pumpAndSettle();

    final after = (await categoryNamed('宠物'))!;
    expect(after.id, before.id, reason: 'ID 是稳定标识，不能跟着图标变');
    expect(after.name, before.name);
    expect(after.iconKey, 'coffee');
  });

}
