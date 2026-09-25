import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/core/components/buttons.dart';
import 'package:younum/core/components/list_row.dart';
import 'package:younum/core/components/screen_scaffold.dart';
import 'package:younum/core/preferences/app_state_store.dart';
import 'package:younum/core/preferences/theme_controller.dart';
import 'package:younum/core/preferences/theme_store.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/category.dart';
import 'package:younum/domain/models/year_month.dart';
import 'package:younum/domain/repositories/image_file_source.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/app/app.dart';
import 'package:younum/features/organize/category_screens.dart';
import 'package:younum/features/organize/category_registry.dart';

/// 分类合并的界面接线（指南 3.5.8：「分类合并需显式迁移分配关系」）。
///
/// 断言的重点不是「页面上多了一个按钮」，而是**走完这条路之后库里真的变了**：
/// 账目换了分类、源分类被归档。合并是少数几个会改动真实账目的操作之一，
/// 界面说成功而库里没动（或者反过来）都是不能接受的。
void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late ThemeController themeController;
  late AppStateController appStateController;

  const int ledgerId = DemoLedgerSeed.demoLedgerId;
  final YearMonth september = DemoLedgerSeed.month;

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

  tearDown(() => themeController.dispose());

  Future<Category?> categoryNamed(String name) async {
    final categories = await repository.categories(ledgerId: ledgerId);
    for (final category in categories) {
      if (category.name == name) return category;
    }
    return null;
  }

  /// 我的 → 分类管理 → 点某个分类进编辑页。
  Future<void> openEditor(WidgetTester tester, String name) async {
    await tester.pumpWidget(
      YounumApp(
        themeController: themeController,
        appStateController: appStateController,
        ledgerRepository: repository,
        ledgerFileSource: const UnsupportedFileSource(),
        imageFileSource: const UnsupportedImageSource(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(of: find.byType(AppBottomBar), matching: find.text('我的')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('分类管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(name).first);
    await tester.pumpAndSettle();
    expect(find.byType(CategoryEditorScreen), findsOneWidget);
  }

  Future<void> tapMerge(WidgetTester tester) async {
    // 合并入口在编辑页靠下，小屏上要滚一下才点得到。
    await tester.ensureVisible(find.text('合并到其他分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合并到其他分类'));
    await tester.pumpAndSettle();
  }

  Future<void> tapMergeTarget(WidgetTester tester, String name) async {
    final row = find.descendant(
      of: find.byType(YounumListRow),
      matching: find.text(name),
    );
    expect(row, findsOneWidget, reason: '目标列表里应该有且只有一个「$name」');
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  testWidgets('合并到别的分类：账目真的换了用途，源分类变成已归档', (WidgetTester tester) async {
    // 先造一个「有账目」的自建分类：合并最容易出错的正是这一步。
    final created = await repository.createCategory(
      ledgerId: ledgerId,
      name: '养花',
      iconKey: 'leaf',
    );
    final source = (created as CategorySaved).category;

    final snapshot = await repository.loadSnapshot(
      ledgerId: ledgerId,
      month: september,
    );
    final card = snapshot.current!;
    final confirmed = await repository.confirm(
      ledgerId: ledgerId,
      month: september,
      transactionId: card.id,
      categoryId: source.id,
    );
    expect(confirmed, isA<ReviewSucceeded>(), reason: '$confirmed');

    await openEditor(tester, '养花');
    await tapMerge(tester);
    // 目标列表是懒加载的，选一个靠前的分类（一级分类有十个，
    // 靠后的几行在弹层高度外，测试里拿不到）。
    await tapMergeTarget(tester, '购物');

    // 确认弹层必须把真实影响说清楚，尤其是「不能撤销」。
    expect(find.textContaining('账目会改成「购物」'), findsOneWidget);
    expect(find.textContaining('这一步不能撤销'), findsOneWidget);

    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();

    // 如实报回搬了几笔，而不是只说「成功」。
    expect(find.textContaining('1 笔账已归到「购物」'), findsOneWidget);

    final dataset = await repository.dataset(
      ledgerId: ledgerId,
      months: <YearMonth>{september},
    );
    final target = (await categoryNamed('购物'))!;
    expect(
      dataset.allocationsOf(card.id).single.categoryId,
      target.id,
      reason: '关键：账目真的换了分类',
    );

    final after = await categoryNamed('养花');
    expect(after, isNotNull, reason: '归档不是删除数据');
    expect(after!.archived, isTrue);

    // 合并完回到管理页，并且在「已归档」里能看到它。
    expect(find.byType(CategoryManageScreen), findsOneWidget);
    expect(find.text('已归档'), findsOneWidget);
  });

  testWidgets('目标列表只给同层级的分类：细分用途不该出现在一级的候选里', (WidgetTester tester) async {
    await repository.createCategory(
      ledgerId: ledgerId,
      name: '养花',
      iconKey: 'leaf',
    );

    await openEditor(tester, '养花');
    await tapMerge(tester);

    expect(find.text('合并到哪个分类？'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(YounumListRow),
        matching: find.text('购物'),
      ),
      findsOneWidget,
      reason: '一级分类之间可以合',
    );
    expect(
      find.descendant(
        of: find.byType(YounumListRow),
        matching: find.text('咖啡茶饮'),
      ),
      findsNothing,
      reason: '「咖啡茶饮」是餐饮下面的细分，跨层级不给合',
    );
    expect(
      find.descendant(
        of: find.byType(YounumListRow),
        matching: find.text('养花'),
      ),
      findsNothing,
      reason: '自己不在候选里',
    );
  });

  testWidgets('源下面还有细分用途时：入口置灰，并把原因写在旁边', (WidgetTester tester) async {
    await openEditor(tester, '餐饮');

    final button = tester.widget<PrimaryAction>(
      find.widgetWithText(PrimaryAction, '合并到其他分类'),
    );
    expect(button.onPressed, isNull, reason: '不能给一个点下去会被拒的入口');
    expect(
      find.textContaining('先把它们合并或归档'),
      findsOneWidget,
      reason: '置灰必须给出原因，否则用户以为功能坏了',
    );

    final registry = CategoryRegistryScope.read(
      tester.element(find.byType(CategoryEditorScreen)),
    );
    final food = registry.byName('餐饮')!;
    expect(registry.mergeTargetsFor(food), isEmpty);
  });
}
