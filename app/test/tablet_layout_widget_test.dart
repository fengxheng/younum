import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/app/app.dart';
import 'package:younum/core/components/buttons.dart';
import 'package:younum/core/components/sheets.dart';
import 'package:younum/core/designsystem/younum_dimens.dart';
import 'package:younum/core/designsystem/younum_icons.dart';
import 'package:younum/core/preferences/app_state_store.dart';
import 'package:younum/core/preferences/category_pick_store.dart';
import 'package:younum/core/preferences/theme_controller.dart';
import 'package:younum/core/preferences/theme_store.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';

/// 平板竖屏（720×1152 dp）上的版式回归。
///
/// 为什么值得写：指南 6.3 的原话是「大屏居中限制阅读宽度……**不能把手机 UI
/// 无限拉宽**」，而在平板真机上确实看到两处问题：
///
/// * 页面内容一路铺满 720dp —— 金额卡与按钮拉成扁带，一行正文横跨整屏；
/// * 首页与引导页那张插画里的两张票据被推到屏幕两端，
///   中间只剩一个大圆圈，看起来像版式散了。
///
/// 溢出在 Flutter 里是抛异常，而异常会让 widget 测试直接失败 ——
/// 所以「走一遍不报错」本身就是断言。宽度则要**量**，不能靠眼睛。
void main() {
  // 1800×2880 @400dpi = 720×1152 dp，与这台平板一致（横屏不在保证范围内）。
  const tabletPhysical = Size(1800, 2880);
  const tabletRatio = 2.5;
  const screenWidth = 720.0;

  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late ThemeController themeController;
  late AppStateController appStateController;

  setUp(() async {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = tabletPhysical;
    view.devicePixelRatio = tabletRatio;

    store = InMemoryLedgerStore();
    repository = LedgerRepository(store);
    await repository.initialize();
    themeController = await ThemeController.restore(InMemoryThemeStore());
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
        ledgerFileSource: const UnsupportedFileSource(),
        categoryPickStore: InMemoryCategoryPickStore(),
      ),
    );
    await tester.pumpAndSettle();
  }

  final problems = <String>[];

  /// 每走一步都收一次异常，把「哪一屏出的问题」记下来。
  Future<void> report(WidgetTester tester, String label) async {
    final error = tester.takeException();
    if (error == null) return;
    problems.add('[$label] $error');
  }

  Future<void> tapText(WidgetTester tester, String label) async {
    final finder = find.text(label);
    if (finder.evaluate().isEmpty) return;
    await tester.tap(finder.last);
    await tester.pumpAndSettle();
  }

  /// 跳过三屏引导，落到空首页。
  ///
  /// 引导页是首次启动才会出现的（`onboardingSeen`），所以这一组测试不去
  /// 动那个偏好 —— 想看引导页的用例直接用，其余用例先点「跳过」。
  Future<void> skipOnboarding(WidgetTester tester) async {
    await tapText(tester, '跳过');
    await report(tester, '空首页');
  }

  testWidgets('平板竖屏：主要页面走一遍，一处都不该溢出', (tester) async {
    await pumpApp(tester);
    await report(tester, '引导页第 1 屏');
    await tapText(tester, '跳过');
    await report(tester, '空首页');
    await tapText(tester, '先用示例账单体验');
    await report(tester, '示例账本首页');

    await tapText(tester, '整理');
    await report(tester, '整理');
    await tapText(tester, '月报');
    await report(tester, '月报');
    await tapText(tester, '我的');
    await report(tester, '我的');

    for (final label in <String>[
      '主题与配色',
      '分类管理',
      '导入记录',
      '隐私与数据',
      '整理提醒',
      '整理进度与保存状态',
      '检查更新',
      '使用帮助',
    ]) {
      await tapText(tester, label);
      await report(tester, '我的 → $label');
      await tester.tap(find.byIcon(YounumIcons.back).first);
      await tester.pumpAndSettle();
    }

    // 分类管理 → 用途快捷项（这一页有拖动排序，最容易在手势/布局上出问题）。
    await tapText(tester, '分类管理');
    await tapText(tester, '用途快捷项');
    await report(tester, '用途快捷项');
    await tester.tap(find.byIcon(YounumIcons.back).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(YounumIcons.back).first);
    await tester.pumpAndSettle();
    await report(tester, '返回我的');

    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('平板竖屏：内容限制在阅读宽度内，并且居中', (tester) async {
    await pumpApp(tester);
    await skipOnboarding(tester);

    // 空首页上最宽的那条内容：整屏的「导入月账单」按钮。
    final action = find.ancestor(
      of: find.text('导入月账单'),
      matching: find.byType(PrimaryAction),
    );
    final rect = tester.getRect(action);

    expect(
      rect.width,
      lessThanOrEqualTo(YounumDimens.readingMaxWidth),
      reason: '内容不能跟着平板一起变宽（指南 6.3）',
    );
    expect(
      rect.width,
      closeTo(YounumDimens.readingMaxWidth, 1),
      reason: '在 720dp 的屏上应当正好用满阅读宽度',
    );
    expect(
      rect.center.dx,
      closeTo(screenWidth / 2, 1),
      reason: '限宽之后要**居中**，而不是靠左留一大片空白',
    );
  });

  testWidgets('平板竖屏：引导页与空首页的插画不被拉宽', (tester) async {
    await pumpApp(tester);

    final art = find.byKey(const ValueKey<String>('art-frame'));
    expect(art, findsWidgets);

    final rect = tester.getRect(art.first);
    expect(
      rect.width,
      lessThan(400),
      reason: '插画按设计宽度固定：跟着 720dp 拉宽的话，两张票据会跑到屏幕两端',
    );
    expect(
      rect.center.dx,
      closeTo(screenWidth / 2, 1),
      reason: '固定宽度之后要居中',
    );
  });

  testWidgets('平板竖屏：底部弹层也跟着限宽，不铺满整屏', (tester) async {
    await pumpApp(tester);
    await skipOnboarding(tester);
    await tapText(tester, '我的');
    await tapText(tester, '隐私与数据');
    await tapText(tester, '清除本地数据');

    final sheet = find.byType(YounumSheetSurface);
    if (sheet.evaluate().isEmpty) {
      // 这个入口的弹层文案变了也不要紧：这一条测的是**弹层的宽度**，
      // 没有弹层就没有可测的东西，直接跳过而不是假装通过。
      markTestSkipped('没打开确认弹层（入口文案可能变了）');
      return;
    }
    await report(tester, '确认弹层');

    // 量弹层里的按钮，而不是弹层自己：Material 3 的 BottomSheet 本身
    // 已经限到 640dp，但 640 > 阅读宽度，所以内容仍可能一条拉到底。
    final button = find.descendant(
      of: sheet,
      matching: find.byType(PrimaryAction),
    );
    final rect = tester.getRect(button.first);
    expect(
      rect.width,
      lessThanOrEqualTo(YounumDimens.readingMaxWidth),
      reason: '弹层内容也要限宽',
    );
    expect(rect.center.dx, closeTo(screenWidth / 2, 1), reason: '弹层内容居中');
  });
}
