import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/app/app.dart';
import 'package:younum/core/components/screen_scaffold.dart';
import 'package:younum/core/preferences/app_state_store.dart';
import 'package:younum/core/preferences/theme_controller.dart';
import 'package:younum/core/preferences/theme_store.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/year_month.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';

/// 月度概况页「部分账单」提示与确认入口的界面测试。
///
/// 为什么值得写：指南 3.4 要求 `coverageConfirmed` 只能由用户**显式**给出，
/// 而原先只有整理完成页有这个开关 —— 只想看账、不走完整理流程的用户
/// 会一直看到「部分账单」却找不到确认的地方（这是记录在
/// `IMPLEMENTATION_STATUS.md` 里最明显的一个用户视角缺口）。
///
/// 「部分账单」有两种完全不同的原因，测试要分别守住：
/// 还有记录没整理完（该去整理）与整理完但没确认范围（该点确认）。
void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late ThemeController themeController;
  late AppStateController appStateController;

  final YearMonth month = DemoLedgerSeed.month;

  setUp(() async {
    // 手机尺寸：默认 800x600 会让为 1080x2400 设计的布局溢出，
    // 而溢出在测试里会直接报错，掩盖真正要验的东西。
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
    // 演示账本自带 6 笔基准记录，用它来构造「整理到一半 / 整理完」两种状态。
    await appStateController.enterDemoLedger();
  });

  tearDown(() {
    themeController.dispose();
  });

  /// 把演示账本的前 [count] 笔归类。
  ///
  /// 归类会让该交易有「有效分配」，概况页据此计算消费总额与占比；
  /// 没归类的那部分则计入整理进度里的待整理数。
  Future<void> classify(int count) async {
    final dataset = await repository.dataset(ledgerId: DemoLedgerSeed.demoLedgerId);
    for (final transaction in dataset.transactions.take(count)) {
      await repository.confirm(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: month,
        transactionId: transaction.id,
        categoryId: SeedCategoryIds.food,
      );
    }
  }

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

  /// 打开底部导航的「月报」。
  Future<void> openReport(WidgetTester tester) async {
    await pumpApp(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(AppBottomBar),
        matching: find.text('月报'),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('整理完但没确认范围时，概况页给出确认入口，点了真的落盘', (WidgetTester tester) async {
    await classify(6);
    await openReport(tester);

    // 入口在页面上，而不是只有一句「你还没有确认」。
    expect(find.textContaining('你还没有确认 9 月账单范围完整'), findsOneWidget);
    final Finder confirm = find.text('我确认9月账单范围完整');
    expect(confirm, findsOneWidget);
    // 这个状态不该出现「继续整理」——记录已经整理完了。
    expect(find.text('继续整理'), findsNothing);
    expect(find.text('部分账单'), findsOneWidget);

    // 点确认：先问一句，再落盘。
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(find.text('确认9月账单范围完整？'), findsOneWidget);

    await tester.tap(find.text('确认范围完整'));
    await tester.pumpAndSettle();

    expect(
      await store.coverageConfirmed(ledgerId: DemoLedgerSeed.demoLedgerId, month: month),
      isTrue,
      reason: '点确认必须真的写进库，而不是只改了界面',
    );
    // 提示与「部分账单」标记都要跟着消失。
    expect(find.textContaining('你还没有确认'), findsNothing);
    expect(find.text('部分账单'), findsNothing);
    expect(find.text('我确认9月账单范围完整'), findsNothing);
  });

  testWidgets('在弹层上选「再看看」不会改动范围确认状态', (WidgetTester tester) async {
    await classify(6);
    await openReport(tester);

    await tester.tap(find.text('我确认9月账单范围完整'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('再看看'));
    await tester.pumpAndSettle();

    expect(
      await store.coverageConfirmed(ledgerId: DemoLedgerSeed.demoLedgerId, month: month),
      isFalse,
    );
    expect(find.text('我确认9月账单范围完整'), findsOneWidget, reason: '入口应当还在');
  });

  testWidgets('还有记录没整理完时，给的是「继续整理」而不是确认范围', (WidgetTester tester) async {
    await classify(2);
    await openReport(tester);

    expect(find.textContaining('没有整理完'), findsOneWidget);
    expect(find.text('继续整理'), findsOneWidget);
    expect(
      find.text('我确认9月账单范围完整'),
      findsNothing,
      reason: '记录都没整理完，此时问「范围完整吗」是问错问题',
    );
  });
}
