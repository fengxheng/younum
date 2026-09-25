import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/app/app.dart';
import 'package:younum/core/preferences/app_state_store.dart';
import 'package:younum/core/preferences/theme_controller.dart';
import 'package:younum/core/preferences/theme_store.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';

import 'support/fake_file_source.dart';

/// 「把一份账单分享到有数」这条入口的界面接线。
///
/// 为什么值得写：分享与「选文件」是**两条入口**，但它们下面共用同一套解析。
/// 接线这一步最容易出的问题 `flutter analyze` 与纯逻辑单测都看不见 ——
/// 页面根本没挂上、失败时没人说话、同一份文件导两遍。这里把真正的
/// [YounumApp] 挂起来，用假的文件来源把「系统分享进来了一份」这件事喂进去：
///
/// * 解析成功 → 直接落到「确认导入」页（用户要的就是少点几下）；
/// * 表头认不出来 → 去字段映射页，而不是按固定列下标猜；
/// * 读不了（例如老式 `.xls`）→ **必须有人说清为什么**，不能静默；
/// * 同一份分享只导一次（回到前台不会又导一遍）。
void main() {
  /// 一份仿微信导出：6 行说明 + 表头 + 3 笔消费 + 1 笔退款 + 合计行。
  const bill = '''
微信支付账单明细
微信昵称：[有数测试]
起始时间：[2026-09-01 00:00:00] 终止时间：[2026-09-30 23:59:59]
导出类型：[全部]
导出时间：[2026-10-01 09:12:03]
----------------------微信支付账单明细列表--------------------
交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号,商户单号,备注
2026-09-23 14:26:00,商户消费,老王牛肉面,牛肉面,支出,¥28.00,零钱,支付成功,4200001,M1001,/
2026-09-24 09:02:11,商户消费,地铁公司,地铁,支出,¥5.00,零钱,支付成功,4200002,M1002,/
2026-09-27 08:00:00,商户消费,早餐铺,包子,支出,¥9.00,零钱,支付成功,4200005,M1005,/
2026-09-26 11:05:00,商户消费,某网店,杯子,支出,¥32.50,零钱,已全额退款,4200004,M1004,退款
共 4 笔,合计,-42.50,,,,,
''';

  /// 表头认不出来的一份（用户把列名改了，或者它根本不是账单）。
  const unknownHeader = '''
日期戳,摘要,数额
2026-09-23 14:26:00,老王牛肉面,28.00
''';

  Uint8List bytesOf(String text) => Uint8List.fromList(utf8.encode(text));

  /// 老式 `.xls` 的字节：OLE2 复合文档的头。工程不实现 BIFF 解析。
  Uint8List legacyXlsBytes() => Uint8List.fromList(<int>[
    0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1,
    0x00, 0x00, 0x00, 0x00,
  ]);

  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late FakeFileSource fileSource;
  late ThemeController themeController;
  late AppStateController appStateController;

  setUp(() async {
    // 手机尺寸：默认 800x600 会让按 1080x2400 设计的布局溢出，
    // 而溢出在测试里直接抛异常，会把真正要验的东西盖掉。
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.physicalSize = const Size(1080, 2400);
    view.devicePixelRatio = 2.75;

    store = InMemoryLedgerStore();
    repository = LedgerRepository(store);
    await repository.initialize();
    fileSource = FakeFileSource();
    themeController = await ThemeController.restore(InMemoryThemeStore());
    appStateController = await AppStateController.restore(
      InMemoryAppStateStore(),
    );
    // 直接进主界面，跳过引导页。
    await appStateController.completeOnboarding();
  });

  tearDown(() {
    themeController.dispose();
  });

  /// 准备一份「系统分享进来」的文件。
  void share(String name, Uint8List bytes) {
    fileSource.shared = DocumentPicked(
      PickedDocument(name: name, bytes: bytes, uri: 'content://share/$name'),
    );
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      YounumApp(
        themeController: themeController,
        appStateController: appStateController,
        ledgerRepository: repository,
        ledgerFileSource: fileSource,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('分享进来的账单直接落到确认导入页', (tester) async {
    share('微信支付账单.csv', bytesOf(bill));
    await pumpApp(tester);

    expect(find.text('确认导入'), findsWidgets);
    expect(
      find.textContaining('本次新增支出 · 3 笔'),
      findsOneWidget,
      reason: '数字要来自真实解析，而不是停在首页或样例数据',
    );
  });

  testWidgets('分享进来的文件认不出表头时去字段映射页，不硬猜列', (tester) async {
    share('流水.csv', bytesOf(unknownHeader));
    await pumpApp(tester);

    expect(find.text('匹配表格字段'), findsWidgets);
  });

  testWidgets('分享进来的是老式 .xls：说清读不了，并给出下一步', (tester) async {
    // 真机上这条路的失败方式是「分享过来没反应」或者「对着一页乱码指列」，
    // 两种都会让用户以为文件坏了。这里要求必须有人说清为什么。
    share('平安银行交易明细.xls', legacyXlsBytes());
    await pumpApp(tester);

    expect(find.text('这份文件没能导入'), findsOneWidget);
    expect(
      find.textContaining('另存为'),
      findsOneWidget,
      reason: '只说「读不了」不够，要说清用户做得到的那一步',
    );
  });

  testWidgets('读不到分享的文件时也要说清，不能静默', (tester) async {
    fileSource.shared = const PickFailed('这个文件太大了，暂时读不了');
    await pumpApp(tester);

    expect(find.text('这份文件没能读进来'), findsOneWidget);
    expect(find.textContaining('太大了'), findsOneWidget);
  });

  testWidgets('同一份分享只导一次：回到前台不会重导', (tester) async {
    share('微信支付账单.csv', bytesOf(bill));
    await pumpApp(tester);
    expect(find.textContaining('本次新增支出 · 3 笔'), findsOneWidget);

    // 真机上「分享过来」就是一次回到前台，所以这里照这条路走一遍。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    // 500ms 后的那次补问也要放过去，否则测试结束时会挂着定时器。
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(
      fileSource.sharedTakeCount,
      greaterThanOrEqualTo(2),
      reason: '每次回到前台都会问一次',
    );
    expect(
      find.textContaining('本次新增支出 · 3 笔'),
      findsOneWidget,
      reason: '重导一次会变成 6 笔 —— 那正是用户最怕的事',
    );
  });

  testWidgets('提示层里的原因再长、字号再大也要看得全', (tester) async {
    // 失败原因是**文件与系统给的**，长度完全不受我们控制：下面这句就是真机上
    // 实际收到过的原文（英文报错 + 一长串路径）。
    fileSource.shared = const PickFailed(
      '读不了这个文件：/sdcard/Android/data/com.younum.app/files/share-test.csv: '
      'open failed: EACCES (Permission denied)',
    );
    // 空首页那张装饰插画在字号 2.0 下会自己溢出（与本次改动无关，
    // 已记在 MANUAL_CHECKS），所以这里进演示账本，别把它算到提示层头上。
    await appStateController.enterDemoLedger();
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await pumpApp(tester);

    expect(tester.takeException(), isNull, reason: '溢出会在渲染期抛异常');
    expect(find.text('知道了'), findsOneWidget, reason: '出路不能被挤出屏幕');
  });
}
