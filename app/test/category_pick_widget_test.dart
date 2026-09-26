import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/app/app.dart';
import 'package:younum/core/components/category_grid.dart';
import 'package:younum/core/components/screen_scaffold.dart';
import 'package:younum/core/designsystem/younum_icons.dart';
import 'package:younum/core/preferences/app_state_store.dart';
import 'package:younum/core/preferences/theme_controller.dart';
import 'package:younum/core/preferences/theme_store.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/features/organize/category_screens.dart';

/// 「选择用途」页的界面接线。
///
/// 需求：卡片上找不到想要的用途 → 点「全部分类」选好 → **直接返回**就算选定，
/// 不必再点一次「使用此分类」。以前这一页只在按钮那条路写回选择，
/// 直接返回等于白选（用户会以为应用没记住）。
void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late ThemeController themeController;
  late AppStateController appStateController;

  const stackKey = ValueKey<String>('review-card-stack');

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

  /// 整理页「已整理 n / N 笔」里的 n。
  int doneCount(WidgetTester tester) {
    final text = tester
        .widgetList<Text>(find.textContaining('已整理'))
        .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
        .firstWhere((value) => value.contains('已整理'));
    return int.parse(RegExp(r'已整理 (\d+)').firstMatch(text)!.group(1)!);
  }

  testWidgets('点一个用途就生效：直接返回也能确认（不必再点「使用此分类」）', (
    tester,
  ) async {
    await openPicker(tester);
    expect(find.byType(AllCategoriesScreen), findsOneWidget);

    await tester.tap(find.text('宠物').first);
    await tester.pumpAndSettle();

    // 关键：**不点**「使用此分类」，直接返回。
    await tester.tap(find.byIcon(YounumIcons.back).first);
    await tester.pumpAndSettle();

    expect(find.byType(AllCategoriesScreen), findsNothing);
    expect(
      find.textContaining('确认 · 宠物'),
      findsOneWidget,
      reason: '返回之后卡片上应该已经锁定刚选的那个用途',
    );

    // 而且真的能提交 —— 只改标签不改行为等于没修。
    final before = doneCount(tester);
    await tester.drag(find.byKey(stackKey), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(doneCount(tester), before + 1);
  });

  testWidgets('细分用途同理：点中细分之后直接返回也算选定', (tester) async {
    await openPicker(tester);

    // 先点大类「餐饮」，再从它的细分用途里点一个。
    await tester.tap(find.text('餐饮').first);
    await tester.pumpAndSettle();
    final firstChild = tester
        .widgetList<YounumChip>(find.byType(YounumChip))
        .map((chip) => chip.label)
        .firstWhere((label) => label != '餐饮');
    await tester.tap(find.text(firstChild));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(YounumIcons.back).first);
    await tester.pumpAndSettle();

    expect(find.textContaining('确认 · $firstChild'), findsOneWidget);
  });

  testWidgets('详情页改用途：选完直接返回也带回去', (tester) async {
    await pumpApp(tester);
    await openTab(tester, '整理');
    await tester.tap(find.textContaining('更多操作'));
    await tester.pumpAndSettle();

    // 详情页 → 修改用途 → 选一个 → 直接返回。
    await tester.tap(find.text('修改用途'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('购物').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(YounumIcons.back).first);
    await tester.pumpAndSettle();

    expect(
      find.text('已归类 · 购物'),
      findsOneWidget,
      reason: '返回也要把用户选的那个带回来，不能当没选过',
    );
  });
}
