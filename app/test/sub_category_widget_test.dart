import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/app/app.dart';
import 'package:younum/core/components/screen_scaffold.dart';
import 'package:younum/core/designsystem/younum_icons.dart';
import 'package:younum/core/preferences/app_state_store.dart';
import 'package:younum/core/preferences/theme_controller.dart';
import 'package:younum/core/preferences/theme_store.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/category.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/features/organize/category_screens.dart';

/// 细分用途与 emoji 图标的界面接线（需求）。
///
/// 需求原文：「细分用途中允许用户创建和修改自己的细分用途，在编辑分类图标页面
/// 也要有相应的细分配置功能」「定义图标允许用户直接输入 emoji 作为图标」。
///
/// 以前细分用途是种子里写死的（餐饮下面的咖啡茶饮之类）：能选不能加，
/// 名字也改不了；图标只能在预设与图片之间二选一。
void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late ThemeController themeController;
  late AppStateController appStateController;

  const int ledgerId = DemoLedgerSeed.demoLedgerId;

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
    await appStateController.enterDemoLedger();
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
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byType(AppBottomBar),
        matching: find.text(label),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 整理 →「全部分类」。
  Future<void> openPicker(WidgetTester tester) async {
    await pumpApp(tester);
    await openTab(tester, '整理');
    await tester.tap(find.textContaining('全部分类'));
    await tester.pumpAndSettle();
  }

  Future<Category?> categoryNamed(String name) async {
    final all = await repository.categories(ledgerId: ledgerId);
    for (final category in all) {
      if (category.name == name) return category;
    }
    return null;
  }

  /// 点一个可能落在折叠线以下的控件（编辑器页面很长）。
  Future<void> tapBelowFold(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// 选择用途 →「餐饮 · 细分用途」的「新建 / 编辑 ›」。
  Future<void> openSubCategories(WidgetTester tester) async {
    await openPicker(tester);
    await tester.tap(find.text('餐饮').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建 / 编辑 ›'));
    await tester.pumpAndSettle();
  }

  testWidgets('在细分用途页里新建一个，回到选择用途就能选到它', (tester) async {
    await openSubCategories(tester);
    expect(find.byType(SubCategoryScreen), findsOneWidget);

    await tester.tap(find.text('新建细分用途'));
    await tester.pumpAndSettle();
    expect(find.byType(CategoryEditorScreen), findsOneWidget);
    expect(find.text('新建细分用途'), findsWidgets);

    await tester.enterText(find.byType(TextField).first, '外卖');
    await tester.pumpAndSettle();
    await tapBelowFold(tester, find.text('保存细分用途'));

    // 保存后会弹「细分用途已保存」：先把它的 2 秒等过去再导航，
    // 否则路由动画期间两条提示条会撞成同一个 hero tag（与要验的东西无关）。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    // 库里有它，而且挂在「餐饮」下面。
    final created = await categoryNamed('外卖');
    expect(created, isNotNull, reason: '关键：库里真的有这条细分用途');
    final parent = await categoryNamed('餐饮');
    expect(created!.parentId, parent!.id);

    // 回到细分用途页，列表里就有它了。
    expect(find.byType(SubCategoryScreen), findsOneWidget);
    expect(find.text('外卖'), findsWidgets);

    // 回选择用途页：它出现在「餐饮 · 细分用途」下面，而且能直接选中并确认。
    await tester.tap(find.byIcon(YounumIcons.back).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('外卖'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(YounumIcons.back).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('确认 · 外卖'), findsOneWidget);
  });

  testWidgets('改细分用途的名字：ID 不动，名字变了', (tester) async {
    final created = await repository.createCategory(
      ledgerId: ledgerId,
      name: '外卖',
      iconKey: 'fastfood',
      parentId: (await categoryNamed('餐饮'))!.id,
    );
    final id = (created as CategorySaved).category.id;

    await openSubCategories(tester);
    await tester.tap(find.text('外卖'));
    await tester.pumpAndSettle();

    // 自建分类的名字可以改（内置的不行，见仓库用例）。
    await tester.enterText(find.byType(TextField).first, '点外卖');
    await tester.pumpAndSettle();
    await tapBelowFold(tester, find.text('保存图标'));

    final renamed = (await repository.categories(ledgerId: ledgerId))
        .firstWhere((category) => category.id == id);
    expect(renamed.name, '点外卖');
    expect(renamed.parentId, isNotNull, reason: '改名字不该动父子关系');
  });

  testWidgets('编辑一级分类时也有细分用途入口（需求：两个地方都能到）', (tester) async {
    await pumpApp(tester);
    await openTab(tester, '我的');
    await tester.tap(find.text('分类管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('餐饮').first);
    await tester.pumpAndSettle();

    expect(
      find.text('细分用途'),
      findsOneWidget,
      reason: '编辑分类图标页也要有细分配置入口',
    );

    await tapBelowFold(tester, find.text('细分用途'));
    expect(find.byType(SubCategoryScreen), findsOneWidget);
    expect(find.text('买菜'), findsWidgets, reason: '种子里「餐饮」下面本来就有细分用途');
  });

  testWidgets('直接输入 emoji 当图标：真的存下来，而且画成 emoji', (tester) async {
    await pumpApp(tester);
    await openTab(tester, '我的');
    await tester.tap(find.text('分类管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('+ 新建'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '拉面');
    await tester.pumpAndSettle();
    // emoji 是第二个输入框（第一个是分类名称）。
    await tester.enterText(find.byType(TextField).at(1), '🍜');
    await tester.pumpAndSettle();
    await tapBelowFold(tester, find.text('保存分类'));

    final created = await categoryNamed('拉面');
    expect(created, isNotNull);
    expect(created!.iconKey, '🍜', reason: 'emoji 直接存在 iconKey 里');
    expect(created.iconType, CategoryIconType.builtin);

    // 管理页上画出来的是这个 emoji（不是回退的默认图标）。
    expect(find.text('🍜'), findsWidgets);
  });

  testWidgets('emoji 框里填了文字：当场说清楚，不会静默存成图标', (tester) async {
    await pumpApp(tester);
    await openTab(tester, '我的');
    await tester.tap(find.text('分类管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('+ 新建'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '拉面');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), '拉面');
    await tester.pumpAndSettle();

    expect(find.textContaining('只能填 emoji'), findsOneWidget);
  });
}
