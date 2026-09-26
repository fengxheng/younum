import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/app/app.dart';
import 'package:younum/core/components/buttons.dart';
import 'package:younum/core/preferences/app_state_store.dart';
import 'package:younum/core/preferences/theme_controller.dart';
import 'package:younum/core/preferences/theme_store.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';

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

  group('确认之后的提示条', () {
    /// 选一个用途再点确认按钮，走的就是真机上出过问题的那条路。
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
