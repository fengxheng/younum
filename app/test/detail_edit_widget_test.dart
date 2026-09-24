import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/app/app.dart';
import 'package:younum/core/components/screen_scaffold.dart';
import 'package:younum/core/preferences/app_state_store.dart';
import 'package:younum/core/preferences/theme_controller.dart';
import 'package:younum/core/preferences/theme_store.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/ledger_transaction.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/features/organize/review_screens.dart';

/// 详情页保存的界面接线测试。
///
/// 原先这一页的「保存修改」只弹一句提示，不写库；已有备注也不会回填 ——
/// 用户改一个错字会把整条备注弄丢。这两类问题 analyze 与仓库层单测都看不见。
void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late ThemeController themeController;
  late AppStateController appStateController;

  const int ledgerId = DemoLedgerSeed.demoLedgerId;
  final int firstCardId = DemoLedgerSeed.transactionIdAt(0);

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

  /// 路由下面的页面仍留在树里，断言要限定在详情页内。
  Finder inDetail(Finder matching) => find.descendant(
    of: find.byType(TransactionDetailScreen),
    matching: matching,
  );

  Future<LedgerTransaction> reload() async {
    final dataset = await repository.dataset(ledgerId: ledgerId);
    return dataset.transaction(firstCardId)!;
  }

  /// 整理 → 更多操作 → 账单详情。
  Future<void> openDetail(WidgetTester tester) async {
    await tester.pumpWidget(
      YounumApp(
        themeController: themeController,
        appStateController: appStateController,
        ledgerRepository: repository,
        ledgerFileSource: const UnsupportedFileSource(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byType(AppBottomBar),
        matching: find.text('整理'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('更多操作'));
    await tester.pumpAndSettle();
  }

  testWidgets('展示那一笔；没改动时「保存修改」是灰的', (WidgetTester tester) async {
    await openDetail(tester);

    expect(inDetail(find.text('MANNER COFFEE')), findsOneWidget);
    expect(inDetail(find.text('待确认用途')), findsOneWidget);

    // 一个字都没改，按钮不该能点 —— 免得凭空写出一条撤销记录。
    await tester.tap(inDetail(find.text('保存修改')));
    await tester.pumpAndSettle();
    expect((await reload()).note, isNull);
  });

  testWidgets('已有的备注会回填，改了之后保存真的落库', (WidgetTester tester) async {
    // 先造一条已有备注的记录。
    await repository.saveDetails(
      ledgerId: ledgerId,
      month: DemoLedgerSeed.month,
      transactionId: firstCardId,
      note: '原来的备注',
    );

    await openDetail(tester);

    expect(
      inDetail(find.text('原来的备注')),
      findsOneWidget,
      reason: '不回填的话，用户改一个错字会把整条备注弄丢',
    );

    await tester.enterText(inDetail(find.byType(TextField)).first, '改过的备注');
    await tester.pumpAndSettle();
    await tester.tap(inDetail(find.text('保存修改')));
    await tester.pumpAndSettle();

    expect((await reload()).note, '改过的备注');
    // 只改备注不该把记录算成处理完成。
    expect((await reload()).reviewStatus, ReviewStatus.pending);
  });

  testWidgets('修改用途后保存：分配落库，记录算处理完成', (WidgetTester tester) async {
    await openDetail(tester);

    await tester.tap(inDetail(find.text('修改用途')));
    await tester.pumpAndSettle();
    // 分类选择页是两步：先点大类，再点底部「使用此分类」返回给调用方。
    await tester.tap(find.text('餐饮').first);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('使用此分类'));
    await tester.pumpAndSettle();

    expect(inDetail(find.text('已归类 · 餐饮')), findsOneWidget);

    await tester.tap(inDetail(find.text('保存修改')));
    await tester.pumpAndSettle();

    final dataset = await repository.dataset(ledgerId: ledgerId);
    expect(
      dataset.allocationsOf(firstCardId).map((a) => a.categoryId).toList(),
      <int>[SeedCategoryIds.food],
    );
    expect((await reload()).reviewStatus, ReviewStatus.resolved);
  });

  testWidgets('保存后按钮重新变灰（当前值成了新基准）', (WidgetTester tester) async {
    await openDetail(tester);

    await tester.enterText(inDetail(find.byType(TextField)).first, '写点东西');
    await tester.pumpAndSettle();
    await tester.tap(inDetail(find.text('保存修改')));
    await tester.pumpAndSettle();

    expect((await reload()).note, '写点东西');
    // 再点一次不该再写出第二条撤销记录。
    await tester.tap(inDetail(find.text('保存修改')));
    await tester.pumpAndSettle();
    expect((await reload()).version, 2, reason: '没改动就不该再写一次');
  });
}
