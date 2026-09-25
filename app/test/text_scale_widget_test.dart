import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/app/app.dart';
import 'package:younum/core/components/buttons.dart';
import 'package:younum/core/components/transaction_card_stack.dart';
import 'package:younum/core/designsystem/younum_dimens.dart';
import 'package:younum/core/preferences/app_state_store.dart';
import 'package:younum/core/preferences/theme_controller.dart';
import 'package:younum/core/preferences/theme_store.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';

/// 系统字号放大后的界面测试。
///
/// 为什么值得写：应用曾经把文字缩放**写死**在 1.6，理由是「堆叠卡片这类固定
/// 高度容器会溢出」。那是把容器的限制转嫁给了用户 —— 指南 6.3 要的是
/// 「不固定屏幕总高度，大字号时允许滚动」。
///
/// 现在卡片按内容自己撑高（设计高度只是下限），上限也去掉了。这两件事必须一起验：
///
/// * 卡片**真的**长高了，而不是「看着没崩」；
/// * 字号放到系统最大（Android 上就是 2.0）时，主要页面一处都不溢出。
///
/// 溢出在 Flutter 里是抛异常，而异常会让 widget 测试**直接失败** ——
/// 所以「走一遍不报错」本身就是断言。
void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late ThemeController themeController;
  late AppStateController appStateController;

  /// 堆叠卡片在树里的 key（见 `cards_screen.dart`）。
  const stackKey = ValueKey<String>('review-card-stack');

  /// 默认字号下的期望高度：设计高度 + 上下各一段摆动余量
  /// （见 `YounumDimens.stackSwingReserve`）。
  const designStackHeight =
      TransactionCardStack.minCardHeight + YounumDimens.stackSwingReserve * 2;

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
    // 示例账本：有几张卡片可整理，才量得到堆叠卡片。
    await appStateController.enterDemoLedger();
  });

  tearDown(() {
    themeController.dispose();
  });

  /// 把系统字号设成 [scale]，然后挂起真实的 [YounumApp]。
  Future<void> pumpAppAt(WidgetTester tester, double scale) async {
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
  }

  /// 点底部导航切到某个标签页。
  ///
  /// 卡片页的商户名在别的屏上也可能出现，所以先切页再断言，避免匹配到路由
  /// 下面还留在树里的页面。
  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  group('字号放大', () {    testWidgets('默认字号下卡片就是设计高度', (tester) async {
      await pumpAppAt(tester, 1.0);
      await openTab(tester, '整理');

      expect(
        tester.getSize(find.byKey(stackKey)).height,
        moreOrLessEquals(designStackHeight, epsilon: 0.5),
      );
    });

    testWidgets('字号 2.0 时卡片自己长高，而不是把文字挤出去', (tester) async {
      await pumpAppAt(tester, 2.0);
      await openTab(tester, '整理');

      // 曾经这里会停在放大 1.6 倍的高度：字号被应用悄悄压小了，用户看到的
      // 只是「大了一点」，而不是他要的那么大。
      expect(
        tester.getSize(find.byKey(stackKey)).height,
        greaterThan(designStackHeight + 40),
        reason: '字号翻倍，卡片必须跟着长，不能停在设计高度',
      );
    });

    testWidgets('字号 2.0 走一遍主要页面：一处都不该溢出', (tester) async {
      await pumpAppAt(tester, 2.0);

      // 每切一个标签就 pumpAndSettle：溢出会以异常的形式抛出来。
      await openTab(tester, '整理');
      await openTab(tester, '月报');
      await openTab(tester, '我的');
      await openTab(tester, '本月');

      expect(tester.takeException(), isNull);
    });

    testWidgets('字号调到系统下限附近：卡片不缩，不白白浪费一屏', (tester) async {
      await pumpAppAt(tester, 0.85);
      await openTab(tester, '整理');

      expect(
        tester.getSize(find.byKey(stackKey)).height,
        moreOrLessEquals(designStackHeight, epsilon: 0.5),
      );
    });

    testWidgets('窄屏 + 大字号：金额缩到装得下，而不是被截成「¥633…」', (tester) async {
      // 360dp 宽是常见的小屏（指南 6.3 要求至少验 360 与 412）。
      tester.view.physicalSize = const Size(720, 1600);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      await pumpAppAt(tester, 2.0);
      await openTab(tester, '整理');

      final error = tester.takeException();
      if (error is FlutterError) {
        // 报错里带着「谁溢出的」那条链。测试失败时把它打出来，
        // 免得下次还要回来加一遍调试代码。
        debugPrint(error.toString());
      }
      // 金额那一行溢出会抛异常，能走到这里就说明它装下了。
      expect(error, isNull);
      expect(find.textContaining('¥'), findsWidgets);
    });
  });

  group('首页头部', () {
    testWidgets('月份按钮与词标在同一行，并贴着右边', (tester) async {
      await pumpAppAt(tester, 1.0);

      // 曾经「9月」跑到第二行居中：`PlainTextButton` 用的是
      // `Container(alignment:)`，在有界宽度下会撑满，放进 `Wrap` 就占掉整行。
      final wordmark = tester.getCenter(find.text('有数.'));
      final month = tester.getCenter(find.text('9月'));
      expect(
        month.dy,
        moreOrLessEquals(wordmark.dy, epsilon: 4),
        reason: '月份应该和词标同一行',
      );

      // 右边对齐：与「追加导入 +」这类尾部入口的右边缘对齐。
      // 比的是**按钮**的右边缘，不是文字的：月份按钮后面还有个箭头图标。
      final monthRight = tester
          .getBottomRight(
            find.ancestor(
              of: find.text('9月'),
              matching: find.byType(PlainTextButton),
            ),
          )
          .dx;
      final trailingRight = tester
          .getBottomRight(
            find.ancestor(
              of: find.text('追加导入 +'),
              matching: find.byType(PlainTextButton),
            ),
          )
          .dx;
      expect(
        monthRight,
        moreOrLessEquals(trailingRight, epsilon: 1),
        reason: '月份要贴在内容区右边，而不是被挤到中间',
      );
    });

    testWidgets('字号 1.25（本机默认）下也在同一行', (tester) async {
      // 用户真机上就是 1.25，这个比例曾把内容撑到刚好换行 —— 单测默认的 1.0
      // 反而看不出来。
      await pumpAppAt(tester, 1.25);

      expect(
        tester.getCenter(find.text('9月')).dy,
        moreOrLessEquals(tester.getCenter(find.text('有数.')).dy, epsilon: 4),
      );
    });

    testWidgets('字号 2.0 时不溢出、不重叠（同排或换到下一排都可以）', (tester) async {
      await pumpAppAt(tester, 2.0);

      expect(tester.takeException(), isNull);
      // 这一档刚好还排得下，窄一点或字号再大就会换行 —— 指南 6.3 允许内容
      // 自然铺开，只要不跑到词标上面去。
      expect(
        tester.getCenter(find.text('9月')).dy,
        greaterThanOrEqualTo(tester.getCenter(find.text('有数.')).dy - 4),
      );
    });
  });

  group('引导页（三屏）', () {    setUp(() async {
      // 引导页只在**没看过**时出现，所以这里要把它改回去。
      appStateController = await AppStateController.restore(
        InMemoryAppStateStore(),
      );
    });

    testWidgets('字号 2.0 下三屏逐屏翻过去，不溢出', (tester) async {
      await pumpAppAt(tester, 2.0);
      expect(find.text('钱花在哪，\n心里有数。'), findsOneWidget);

      for (var page = 0; page < 2; page++) {
        await tester.tap(find.text('下一步'));
        await tester.pumpAndSettle();
      }

      expect(find.text('开启我的第一份月账单'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
