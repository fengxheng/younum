import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/app/app.dart';
import 'package:younum/core/components/category_grid.dart';
import 'package:younum/core/designsystem/younum_icons.dart';
import 'package:younum/core/preferences/app_state_store.dart';
import 'package:younum/core/preferences/category_pick_store.dart';
import 'package:younum/core/preferences/theme_controller.dart';
import 'package:younum/core/preferences/theme_store.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';

/// 用途快捷项的界面接线：整理卡片上的那几格，能不能按用户的意思来。
///
/// 为什么值得写：这个功能的价值全在「**我改的东西真的生效了**」这一件事上 ——
/// 而「设置存下来了但卡片没变」「拖完顺序没落盘」「移除最后一个之后卡片空了」
/// 这几类问题，纯逻辑单测与 flutter analyze 都看不见。
void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late ThemeController themeController;
  late AppStateController appStateController;
  late InMemoryCategoryPickStore pickStore;

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
    // 示例账本：有卡片可整理，也才有「选择用途」那一片网格。
    await appStateController.enterDemoLedger();
    pickStore = InMemoryCategoryPickStore();
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
        categoryPickStore: pickStore,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  /// 卡片网格上按顺序排列的用途名。
  List<String> gridNames(WidgetTester tester) => <String>[
    for (final item in tester.widget<CategoryGrid>(find.byType(CategoryGrid)).items)
      item.name,
  ];

  /// 我的 → 分类管理 → 用途快捷项。
  Future<void> openQuickPick(WidgetTester tester) async {
    await openTab(tester, '我的');
    await tester.tap(find.text('分类管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('用途快捷项'));
    await tester.pumpAndSettle();
  }

  testWidgets('卡片上的用途就是快捷项里配好的那几个，顺序一致', (tester) async {
    pickStore = InMemoryCategoryPickStore(<int>[
      SeedCategoryIds.health,
      SeedCategoryIds.food,
      SeedCategoryIds.other,
    ]);

    await pumpApp(tester);
    await openTab(tester, '整理');

    expect(gridNames(tester), <String>['健康', '餐饮', '其他']);
  });

  testWidgets('没配置过时还是内置那 8 个（老用户升级上来不会发现变了样）', (tester) async {
    await pumpApp(tester);
    await openTab(tester, '整理');

    expect(gridNames(tester), <String>[
      '餐饮',
      '购物',
      '交通',
      '居住',
      '娱乐',
      '健康',
      '人情',
      '其他',
    ]);
  });

  testWidgets('在管理页移除一个：卡片上立刻少一个，并且落了盘', (tester) async {
    await pumpApp(tester);
    await openQuickPick(tester);

    // 第一行的「移除」。
    await tester.tap(find.text('移除').first);
    await tester.pumpAndSettle();

    expect(
      await pickStore.loadQuickPickIds(),
      isNot(contains(SeedCategoryIds.food)),
      reason: '移除要真的存下来，否则下次进来又回来了',
    );

    // 回到整理页看卡片。
    //
    // 返回按钮用图标定位：它是 `Semantics(label:)` 而不是 `Tooltip`，
    // 所以 `find.byTooltip('返回')` 找不到它。
    await tester.tap(find.byIcon(YounumIcons.back).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(YounumIcons.back).first);
    await tester.pumpAndSettle();
    await openTab(tester, '整理');

    expect(gridNames(tester), isNot(contains('餐饮')));
    expect(gridNames(tester).first, '购物');
  });

  testWidgets('把第二个拖到第一个：顺序真的变了，而且落了盘', (tester) async {
    await pumpApp(tester);
    await openQuickPick(tester);

    // 拖动柄在每一行的最右边（只有它能拖，整行拖会和「移除」抢手势）。
    final handles = find.byIcon(YounumIcons.dragHandle);
    expect(handles, findsWidgets);

    final gesture = await tester.startGesture(tester.getCenter(handles.at(1)));
    await tester.pump();
    // 一行大约 60dp 高，往上多走一点才会跨过前一行。
    for (var step = 0; step < 8; step++) {
      await gesture.moveBy(const Offset(0, -12));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    final stored = await pickStore.loadQuickPickIds();
    expect(stored.first, SeedCategoryIds.shopping, reason: '购物被拖到了第一位');
    expect(stored[1], SeedCategoryIds.food, reason: '餐饮退到第二位');
  });

  testWidgets('只剩一个时不能再移除，并说明为什么', (tester) async {
    pickStore = InMemoryCategoryPickStore(<int>[SeedCategoryIds.food]);

    await pumpApp(tester);
    await openQuickPick(tester);

    // 只剩一个：不给「移除」这个坑（点了就一个都不剩，整理时反而更慢）。
    expect(find.text('移除'), findsOneWidget, reason: '按钮还在，但不可点');
    expect(find.textContaining('至少留一个'), findsOneWidget);

    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();

    expect(await pickStore.loadQuickPickIds(), <int>[SeedCategoryIds.food]);
  });

  testWidgets('加满 8 个之后，可选项被置灰并给出原因', (tester) async {
    await pumpApp(tester);
    await openQuickPick(tester);

    expect(find.textContaining('快捷项已经满了'), findsOneWidget);
    expect(find.text('已满'), findsWidgets);
    expect(
      find.text('添加'),
      findsNothing,
      reason: '满了之后不该还有能点的「添加」引诱用户',
    );
  });

  testWidgets('还有空位时可以添加，卡片上跟着出现', (tester) async {
    pickStore = InMemoryCategoryPickStore(<int>[SeedCategoryIds.food]);

    await pumpApp(tester);
    await openQuickPick(tester);

    // 「宠物」是自建分类，也能加进快捷项。
    await tester.tap(find.text('宠物'));
    await tester.pumpAndSettle();

    expect(await pickStore.loadQuickPickIds(), <int>[
      SeedCategoryIds.food,
      SeedCategoryIds.pets,
    ]);
  });
}
