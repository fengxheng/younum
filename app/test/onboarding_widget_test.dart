import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/app/app.dart';
import 'package:younum/core/preferences/app_state_store.dart';
import 'package:younum/core/preferences/theme_controller.dart';
import 'package:younum/core/preferences/theme_store.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';

/// 首次使用·产品引导（三屏）的界面测试。
///
/// 为什么值得写：设计一开始只给了第一屏，第 2、3 屏是后补的，靠人眼很容易
/// 漏掉一屏 —— 那样用户第一次打开只会看到一句话，不知道「导入」和「月报」
/// 是什么。另外交互补充规范对「首尾不循环」「不足 50dp 不翻页」有明确约定，
/// 这类手感问题只能靠测试守着，`flutter analyze` 完全看不出来。
void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late ThemeController themeController;
  late AppStateController appStateController;

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
    // 故意**不**标记引导已完成：要让应用落在欢迎页。
    appStateController = await AppStateController.restore(
      InMemoryAppStateStore(),
    );
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
        // 引导页不碰文件，给一个「平台不支持」的实现就够，
        // 无需装一个假的系统选择器。
        ledgerFileSource: const UnsupportedFileSource(),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 慢速拖动。
  ///
  /// 不用 `tester.drag`：它是「一帧内瞬移」，速度极大，全被当成轻扫，
  /// 小位移也会翻页 —— 那样测的就不是规范里说的那件事了。
  ///
  /// 距离也有讲究：[PageView] 的 [PageScrollPhysics] 除了位移还会把
  /// 一定速度当成「甩一页」的补偿。拖**一页宽**（348dp）会变成翻两页，
  /// 所以翻页用例统一用 200dp：算上补偿也只到 1 页，不带补偿也是 1 页。
  Future<void> slowDrag(WidgetTester tester, Offset offset) async {
    await tester.timedDrag(
      find.byType(PageView),
      offset,
      const Duration(milliseconds: 800),
    );
    await tester.pumpAndSettle();
  }

  const title1 = '钱花在哪，\n心里有数。';
  const title2 = '导入一个月，\n一笔一张整理。';
  const title3 = '看见花费，\n也看见生活。';

  /// 断言这一屏里旋转后的卡片完全落在页面宽度内。
  ///
  /// 为什么值得单写一条：旋转会把包围盒撑宽（152×172 转 -14° 后宽 189dp，
  /// 超出量平均落在两侧），超出插画容器的部分会被硬裁 ——
  /// 看起来就是**圆角被切掉一块**。真机上第 1、2 屏都出现过这个问题，
  /// 而截图比对全靠人眼，容易漏。
  ///
  /// 等价说法：卡片连旋转在内的四个角，不能跑到页面外面去。
  void expectArtInsidePage(WidgetTester tester, String where) {
    final Rect page = tester.getRect(find.byType(PageView));
    // 只取**真的转过**的：页面里还有两个框架内部的单位矩阵 `Transform`
    // （包住整屏），不过滤的话它们会被当成卡片重复检查。
    final Finder cards = find.descendant(
      of: find.byType(PageView),
      matching: find.byWidgetPredicate(
        (Widget widget) =>
            widget is Transform && !widget.transform.isIdentity(),
      ),
    );
    final int count = cards.evaluate().length;
    expect(count, greaterThan(0), reason: '$where：这一屏应当有旋转的卡片');

    for (var i = 0; i < count; i++) {
      final Finder card = find
          .descendant(of: cards.at(i), matching: find.byType(Container))
          .first;
      final RenderBox box = tester.renderObject<RenderBox>(card);
      final Size size = box.size;
      final List<Offset> corners = <Offset>[
        Offset.zero,
        Offset(size.width, 0),
        Offset(0, size.height),
        Offset(size.width, size.height),
      ].map(box.localToGlobal).toList();

      for (final Offset corner in corners) {
        expect(
          corner.dx,
          greaterThanOrEqualTo(page.left - 0.01),
          reason: '$where：第 ${i + 1} 张卡左边越出页面，圆角会被裁',
        );
        expect(
          corner.dx,
          lessThanOrEqualTo(page.right + 0.01),
          reason: '$where：第 ${i + 1} 张卡右边越出页面，圆角会被裁',
        );
      }
    }
  }

  testWidgets('三屏插画里的旋转卡片都不越出页面（圆角不会被裁）', (WidgetTester tester) async {
    await pumpApp(tester);
    expectArtInsidePage(tester, '第 1 屏');

    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expectArtInsidePage(tester, '第 2 屏');

    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expectArtInsidePage(tester, '第 3 屏');
  });

  testWidgets('三屏都在，不是只有第一屏', (WidgetTester tester) async {
    await pumpApp(tester);

    // 第一屏。
    expect(find.text(title1), findsOneWidget);
    expect(find.text(title2), findsNothing);

    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text(title2), findsOneWidget);
    expect(find.text(title1), findsNothing);
    expect(
      find.text('导入微信、支付宝或银行卡账单。\n选择用途，让每一笔花费各就各位。'),
      findsOneWidget,
    );

    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text(title3), findsOneWidget);
    expect(
      find.text('从消费结构到月度回顾，\n看懂钱的去向，找到自己的生活节奏。'),
      findsOneWidget,
    );
    // 最后一屏主按钮换文案，且不再出现「下一步」。
    expect(find.text('开启我的第一份月账单'), findsOneWidget);
    expect(find.text('下一步'), findsNothing);
  });

  testWidgets('每一屏都显示页脚说明，且不显示「左右滑动了解」提示', (WidgetTester tester) async {
    await pumpApp(tester);

    for (var i = 0; i < 3; i++) {
      expect(find.text('无需注册，先体验整理'), findsOneWidget);
      // 用户明确要求不显示这条提示。
      expect(find.textContaining('左右滑动了解'), findsNothing);
      if (i < 2) {
        await tester.tap(find.text('下一步'));
        await tester.pumpAndSettle();
      }
    }
  });

  testWidgets('左滑前进、右滑返回', (WidgetTester tester) async {
    await pumpApp(tester);

    await slowDrag(tester, const Offset(-200, 0));
    expect(find.text(title2), findsOneWidget);

    await slowDrag(tester, const Offset(200, 0));
    expect(find.text(title1), findsOneWidget);
  });

  testWidgets('首尾不循环：第一屏右滑、最后一屏左滑都不动', (WidgetTester tester) async {
    await pumpApp(tester);

    await slowDrag(tester, const Offset(200, 0));
    expect(find.text(title1), findsOneWidget, reason: '第一屏再往右滑应该停住');

    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text(title3), findsOneWidget);

    await slowDrag(tester, const Offset(-200, 0));
    expect(find.text(title3), findsOneWidget, reason: '最后一屏再往左滑应该停住');
  });

  testWidgets('不足 50dp 的横向位移不翻页', (WidgetTester tester) async {
    await pumpApp(tester);

    await slowDrag(tester, const Offset(-40, 0));
    expect(find.text(title1), findsOneWidget);
  });

  testWidgets('竖向滑动不翻页', (WidgetTester tester) async {
    await pumpApp(tester);

    await slowDrag(tester, const Offset(0, -300));
    expect(find.text(title1), findsOneWidget);
  });

  testWidgets('分页圆点可以直接跳页', (WidgetTester tester) async {
    await pumpApp(tester);

    await tester.tap(find.bySemanticsLabel('第 3 页，共 3 页'));
    await tester.pumpAndSettle();
    expect(find.text(title3), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('第 1 页，共 3 页'));
    await tester.pumpAndSettle();
    expect(find.text(title1), findsOneWidget);
  });

  testWidgets('最后一屏主按钮进入首页，并落盘完成状态', (WidgetTester tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开启我的第一份月账单'));
    await tester.pumpAndSettle();

    expect(appStateController.onboardingSeen, isTrue);
    expect(find.text(title3), findsNothing, reason: '应该已经离开引导页');
  });

  for (var page = 0; page < 3; page++) {
    testWidgets('「跳过」在第 ${page + 1} 屏可用，且不会再次出现引导', (WidgetTester tester) async {
      await pumpApp(tester);

      for (var i = 0; i < page; i++) {
        await tester.tap(find.text('下一步'));
        await tester.pumpAndSettle();
      }

      await tester.tap(find.text('跳过'));
      await tester.pumpAndSettle();

      expect(appStateController.onboardingSeen, isTrue);
      // 「跳过」只在引导页上，它消失就说明已经离开。
      expect(find.text('跳过'), findsNothing);
    });
  }
}
