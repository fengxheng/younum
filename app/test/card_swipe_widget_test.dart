import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/app/app.dart';
import 'package:younum/core/components/buttons.dart';
import 'package:younum/core/components/primitives.dart';
import 'package:younum/core/preferences/app_state_store.dart';
import 'package:younum/core/preferences/theme_controller.dart';
import 'package:younum/core/preferences/theme_store.dart';
import 'package:younum/core/time/statistics_time.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/ledger_transaction.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/features/organize/cards_screen.dart';
import 'package:younum/features/organize/review_session.dart';

/// 堆叠卡片的滑动手势回归测试。
///
/// 为什么值得写：卡片高度的实现方式变过一次（固定高度 → 由内容撑高，
/// 设计高度当下限），整个 `Stack` 的层级也跟着改了 —— 后层卡片从
/// `Positioned(height:)` 变成 `Positioned.fill`，前层卡片从「被放进固定高度的
/// `SizedBox`」变成「自己决定这一层多高」。
///
/// 这类改动最容易悄悄弄坏的正是手势：命中的区域变了、阈值算的还是旧宽度、
/// 或者卡片根本没接到拖动。而**没接到拖动**在界面上表现为「滑了没反应」，
/// 不会报错，只会让用户以为应用坏了。
///
/// 阈值只按距离判定（指南 14.2 明确不单独用瞬时速度），所以这里用
/// `tester.drag` 就是真实路径。
void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late ThemeController themeController;
  late AppStateController appStateController;

  const stackKey = ValueKey<String>('review-card-stack');

  /// 示例账本的 6 笔，顺序就是整理顺序（见 `DemoLedgerSeed.baseline`）。
  const merchants = <String>[
    'MANNER COFFEE',
    '优衣库 UNIQLO',
    '滴滴出行',
    '盒马鲜生',
    '周末电影',
    '社区药房',
  ];

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

  Future<void> pumpApp(WidgetTester tester, {double scale = 1.0}) async {
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      YounumApp(
        themeController: themeController,
        appStateController: appStateController,
        ledgerRepository: repository,
        ledgerFileSource: const UnsupportedFileSource(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('整理').last);
    await tester.pumpAndSettle();
  }

  /// 在卡片上横向拖 [dx]（起点是卡片中心，避开边缘返回的避让区）。
  Future<void> swipe(WidgetTester tester, double dx) async {
    await tester.drag(find.byKey(stackKey), Offset(dx, 0));
    await tester.pumpAndSettle();
  }

  /// 「已整理 n / 6 笔」里的 n。
  int doneCount(WidgetTester tester) {
    final text = tester
        .widgetList<Text>(find.textContaining('已整理'))
        .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
        .firstWhere((value) => value.contains('已整理'));
    final match = RegExp(r'已整理 (\d+)').firstMatch(text);
    return int.parse(match!.group(1)!);
  }

  /// 当前卡片上写的是哪一笔。
  ///
  /// 「卡片换了」是手势真的被处理的**唯一**硬证据：左滑是稍后处理，
  /// 完成数不会变，只看数字分不出「滑了没反应」和「滑了但状态正确」。
  String cardMerchant(WidgetTester tester) {
    for (final merchant in merchants) {
      final finder = find.descendant(
        of: find.byKey(stackKey),
        matching: find.text(merchant),
      );
      if (finder.evaluate().isNotEmpty) return merchant;
    }
    return '';
  }

  group('滑卡手势', () {
    testWidgets('左滑超过阈值 = 稍后处理，卡片换下一张', (tester) async {
      await pumpApp(tester);
      expect(cardMerchant(tester), merchants.first);

      await swipe(tester, -150);

      // 稍后处理**不算**完成（指南 2.3.6）：它进待处理清单，不增加完成数。
      expect(
        doneCount(tester),
        0,
        reason: '左滑是「稍后处理」，不该增加已整理数',
      );
      // 但卡片确实换了一张 —— 这才说明手势真的被处理了。
      expect(cardMerchant(tester), merchants[1]);
    });

    testWidgets('未选分类时右滑：回弹，还是同一张', (tester) async {
      await pumpApp(tester);

      await swipe(tester, 150);

      expect(doneCount(tester), 0);
      expect(cardMerchant(tester), merchants.first, reason: '没选分类就不能提交');
    });

    testWidgets('滑动距离不够：回弹，还是同一张', (tester) async {
      await pumpApp(tester);

      // 阈值是卡片宽度的 28%（约 97dp），40dp 远不够。
      await swipe(tester, -40);

      expect(doneCount(tester), 0);
      expect(cardMerchant(tester), merchants.first);
    });

    testWidgets('字号 2.0（卡片更高）时手势仍然有效', (tester) async {
      await pumpApp(tester, scale: 2.0);

      // 卡片高度改了，宽度与阈值判定不该受影响。
      await swipe(tester, -150);

      expect(cardMerchant(tester), merchants[1]);
      expect(tester.takeException(), isNull);
    });
  });

  group('卡片上的收支方向', () {
    /// 往演示账本里塞一笔**收入**。
    ///
    /// 收入行确实会进整理队列 —— 导入时按账单的「收/支」列判定性质
    /// （`import_workflow.dart` 的 `_natureOf`），微信/支付宝账单里的收入行
    /// 就是这样进来的。队列按时间倒序，所以这笔排在最前面。
    Future<void> seedIncome() async {
      await store.insertTransaction(
        LedgerTransaction(
          id: LedgerTransaction.idUnassigned,
          ledgerId: DemoLedgerSeed.demoLedgerId,
          occurredAtMs: StatisticsTime.epochMsFor(2026, 9, 26, 10),
          amountCents: 500000,
          merchant: '刘旭龙',
          nature: TransactionNature.income,
          reviewStatus: ReviewStatus.pending,
          timeZone: StatisticsTime.timeZone,
        ),
      );
    }

    /// 某个商户那张卡片上的徽标文字。
    ///
    /// 堆叠卡片会同时挂着后面几张，所以要**按商户名定位当前那张**，
    /// 否则会读到别的卡片上的徽标。
    String badgeOf(WidgetTester tester, String merchant) => tester
        .widget<YounumBadge>(
          find.descendant(
            of: find
                .ancestor(
                  of: find.text(merchant),
                  matching: find.byType(TransactionCardView),
                )
                .first,
            matching: find.byType(YounumBadge),
          ),
        )
        .label;

    testWidgets('收入那一笔写「收入」，不能写死「支出」', (tester) async {
      // 真机上就是这么看到的：卡片顶着「支出」+ ¥5,000.00，
      // 而同一笔在「全部明细」里是「收入 · +¥5,000.00」。
      await seedIncome();
      await pumpApp(tester);

      // 找不到这张卡片时 finder 会直接报错，不会静默跳过。
      expect(
        badgeOf(tester, '刘旭龙'),
        '收入',
        reason: '金额一律存绝对值，方向只能由交易性质表达（指南 3.1）',
      );
    });

    testWidgets('消费那一笔仍然是「支出」（设计稿的用词，不要改成「消费」）', (
      tester,
    ) async {
      await pumpApp(tester);

      expect(cardMerchant(tester), merchants.first);
      expect(badgeOf(tester, merchants.first), '支出');
    });

    testWidgets('朗读文本也报「收入」，不能让读屏用户听到反的', (tester) async {
      await seedIncome();
      await pumpApp(tester);

      expect(find.bySemanticsLabel(RegExp('刘旭龙.*收入')), findsWidgets);
      expect(
        find.bySemanticsLabel(RegExp('刘旭龙.*支出')),
        findsNothing,
        reason: '徽标说一套、朗读说另一套，等于没修',
      );
    });
  });

  group('手势这条路也要说实话', () {
    testWidgets('选中的用途换不成分类时：不能静默回弹，要说清原因', (tester) async {
      await pumpApp(tester);

      // 直接塞一个库里没有的用途名 —— 等价于「刚新建的分类还没同步进会话」，
      // 真机上就是这么撞上「右滑没法确认」的（见 DECISIONS.md 78 节）。
      final session = ReviewSessionScope.of(
        tester.element(find.byType(CardsScreen)),
      );
      session.select('库里没有的用途');
      await tester.pumpAndSettle();

      await swipe(tester, 200);

      expect(
        find.textContaining('找不到对应的分类'),
        findsOneWidget,
        reason: '回弹是「什么都没发生」的样子，而用户确实做了一次操作',
      );
      expect(doneCount(tester), 0, reason: '没提交成功就不能算整理完成');
    });

    testWidgets('一个用途都没选就右滑：也要说一句，不能只是回弹', (tester) async {
      // 文档里写的就是「未选分类时右滑 → 回弹**并提示**」（见
      // `transaction_card_stack.dart` 开头的手势语义）。
      await pumpApp(tester);

      await swipe(tester, 200);

      expect(find.textContaining('先选一个用途'), findsOneWidget);
      expect(doneCount(tester), 0);
      expect(cardMerchant(tester), merchants.first, reason: '记录不变，还是同一张');
    });
  });

  group('确认之后的提示条', () {    /// 选一个用途再点确认按钮，走的就是真机上出过问题的那条路。
    testWidgets('提示条里写的是商户名，不是对象的 toString', (tester) async {
      await pumpApp(tester);

      await tester.tap(find.text('餐饮'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(PrimaryAction),
          matching: find.textContaining('确认 ·'),
        ),
      );
      await tester.pumpAndSettle();

      // 这里曾经是「已确认 · ReviewCard(6, 社区药房, 6500).merchant → 餐饮」：
      // `'… $transaction.merchant …'` 只会插值 `$transaction`，
      // 再把 `.merchant` 当字面量拼上去（见 DECISIONS.md 76 节）。
      // 这条断言就是为它写的 —— 写成 `$x.y` 立刻会红。
      expect(
        find.textContaining('已确认 · ${merchants.first} → 餐饮'),
        findsOneWidget,
      );
      expect(
        find.textContaining('ReviewCard'),
        findsNothing,
        reason: '给用户看的字符串里出现对象字面量，说明插值写成了 \$x.y',
      );

      // 等提示条自己的 2 秒过去，别给测试留下待处理的定时器。
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });
  });
}
