import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/app/app.dart';
import 'package:younum/core/components/buttons.dart';
import 'package:younum/core/components/screen_scaffold.dart';
import 'package:younum/core/preferences/app_state_store.dart';
import 'package:younum/core/preferences/theme_controller.dart';
import 'package:younum/core/preferences/theme_store.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/domain/repositories/document_saver.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';

import 'support/fake_file_source.dart';

/// 导入流程的界面测试。
///
/// 为什么值得写：接线这一步最容易出的问题不是逻辑错，而是**页面根本没接上** ——
/// 按钮点了没反应、跳转去错地方、数字还是样例数据。这类问题 `flutter analyze`
/// 看不出来，纯逻辑的单元测试也看不出来。
///
/// 这里把真正的 [YounumApp] 挂起来走一遍：选文件 → 解析页 → 核对页 → 提交。
/// 文件来源用假实现（真实现要打开系统选择器，测试里没人能替用户点）。
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
共 4 笔,合计,-42.50,,,,
''';

  /// 表头认不出来的一份。
  const unknownHeaderBill = '''
日期戳,摘要,数额
2026-09-23 14:26:00,老王牛肉面,28.00
''';

  /// 上一个月（8 月）的账单：用来验「导入的不是正在看的那一个月」。
  const augustBill = '''
微信支付账单明细
微信昵称：[有数测试]
起始时间：[2026-08-01 00:00:00] 终止时间：[2026-08-31 23:59:59]
导出时间：[2026-09-01 09:12:03]
----------------------微信支付账单明细列表--------------------
交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号,商户单号,备注
2026-08-05 19:12:00,商户消费,楼下小馆,晚饭,支出,¥36.00,零钱,支付成功,4300001,M2001,/
2026-08-19 08:30:00,商户消费,便利店,牛奶,支出,¥12.00,零钱,支付成功,4300002,M2002,/
共 2 笔,合计,-48.00,,,,,
''';

  Uint8List bytesOf(String text) => Uint8List.fromList(utf8.encode(text));

  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late FakeFileSource fileSource;
  late ThemeController themeController;
  late AppStateController appStateController;

  setUp(() async {
    // 手机尺寸的界面：默认 800x600 会让为 1080x2400 设计的布局溢出，
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
    fileSource = FakeFileSource(bytes: bytesOf(bill));
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

  Future<void> pumpApp(WidgetTester tester, {DocumentSaver? saver}) async {
    await tester.pumpWidget(
      YounumApp(
        themeController: themeController,
        appStateController: appStateController,
        ledgerRepository: repository,
        ledgerFileSource: fileSource,
        documentSaver: saver ?? const UnsupportedDocumentSaver(),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 从首页走到「选择账单文件」页。
  ///
  /// 空账本的首页给的是「导入月账单」，来源页选微信 —— 来源会影响去重键，
  /// 所以要按真实路径走。
  Future<void> openUploadScreen(WidgetTester tester) async {
    await tester.tap(find.text('导入月账单').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('微信支付'));
    await tester.pumpAndSettle();
  }

  /// 取某个按钮组件，用来断言它是不是可点。
  ///
  /// 「按钮不可点」是导入流程里最容易出错的地方之一，值得单独断言：
  /// 一个可点但什么都不做的按钮会骗用户。
  PrimaryAction actionFor(WidgetTester tester, String label) =>
      tester.widget<PrimaryAction>(
        find
            .ancestor(
              of: find.text(label),
              matching: find.byType(PrimaryAction),
            )
            .first,
      );

  /// 点按钮。
  ///
  /// 不能用 `find.text(label)` 直接点：页面标题与按钮文案常常一样
  /// （左上角写着「选择账单文件」，下面那个按钮也叫这个名字）。
  Future<void> tapAction(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byType(PrimaryAction),
        matching: find.text(label),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 点一个可能在折叠线以下的按钮。
  ///
  /// 异常页要列几十行，按钮被挤到屏幕外。`tester.tap` 对屏幕外的控件只是
  /// 「点了个空」，不会报错 —— 测试会以「什么都没发生」的形式失败。
  Future<void> tapActionBelowFold(WidgetTester tester, String label) async {
    final finder = find.descendant(
      of: find.byType(PrimaryAction),
      matching: find.text(label),
    );
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  group('选文件', () {
    testWidgets('设备不支持选择文件时，点下去要说清原因', (tester) async {
      fileSource.available = false;
      await pumpApp(tester);
      await openUploadScreen(tester);

      await tapAction(tester, '选择账单文件');

      // 按钮仍然可点是对的：点下去会给出真实原因，不是无声无息。
      expect(find.textContaining('不能选择文件'), findsWidgets);
      expect(find.text('导入你的月账单'), findsOneWidget);
    });

    testWidgets('选到文件后自动走到核对页，并显示真实笔数', (tester) async {
      await pumpApp(tester);
      await openUploadScreen(tester);

      await tapAction(tester, '选择账单文件');

      // 解析页应该已经自动前进到核对页。
      expect(find.text('确认导入'), findsWidgets);
      expect(
        find.textContaining('本次新增支出 · 3 笔'),
        findsOneWidget,
        reason: '数字要来自真实的暂存区，不是样例数据',
      );
      // 金额组件把「¥」与数字拆成两个 Text（为的是 TalkBack 读得更整），
      // 所以只断言数字那一半。
      expect(find.textContaining('42.00'), findsWidgets);
      expect(
        find.textContaining('可导入 3 笔'),
        findsOneWidget,
        reason: '识别行数与可导入笔数都要是真的',
      );
    });

    testWidgets('用户取消选择时安静地回到原样', (tester) async {
      fileSource.cancel = true;
      await pumpApp(tester);
      await openUploadScreen(tester);

      await tapAction(tester, '选择账单文件');

      expect(find.text('导入你的月账单'), findsOneWidget);
      expect(find.textContaining('没读进来'), findsNothing);
    });

    testWidgets('读不了文件时说明原因，并留下重试的余地', (tester) async {
      fileSource.failure = const PickFailed('没有读取这个文件的权限，请重新选择一次');
      await pumpApp(tester);
      await openUploadScreen(tester);

      await tapAction(tester, '选择账单文件');

      expect(find.textContaining('请重新选择一次'), findsWidgets);
      expect(find.text('导入你的月账单'), findsOneWidget);
      // 还能再点一次。
      expect(actionFor(tester, '选择账单文件').onPressed, isNotNull);
    });
  });

  group('核对与提交', () {
    testWidgets('点确认导入之后真的写进账本，并给出下一步', (tester) async {
      await pumpApp(tester);
      await openUploadScreen(tester);
      await tapAction(tester, '选择账单文件');

      await tapAction(tester, '确认导入 3 笔');

      expect(find.text('账单已经进来了'), findsOneWidget);
      expect(find.text('开始整理'), findsOneWidget);
      expect(find.text('查看导入记录'), findsOneWidget);

      // 账本里真的有 3 笔。
      final dataset = await repository.dataset(ledgerId: 2);
      expect(dataset.transactions, hasLength(3));
    });

    testWidgets('提交之后首页与整理页立刻就能看到这批账单（不需要重启）', (tester) async {
      // 真机上报过：三批账单在「导入记录」里写着「已导入」，
      // 整理页却还是「这个月还没有账单」—— 杀掉应用重开数据又都在。
      // 根因是首页/整理/月报各自持有一份已加载的快照，
      // 而导入只改了数据库，没人让它们重读。
      await pumpApp(tester);
      expect(
        find.text('导入月账单'),
        findsWidgets,
        reason: '前提：空账本，首页给的是导入入口',
      );

      await openUploadScreen(tester);
      await tapAction(tester, '选择账单文件');
      await tapAction(tester, '确认导入 3 笔');
      await tapAction(tester, '开始整理');

      // 整理页：不再是空状态，而是真的列出了那几笔。
      expect(
        find.textContaining('这个月还没有账单'),
        findsNothing,
        reason: '提交之后快照必须已经重读，不能等重启',
      );
      expect(find.textContaining('0 / 3 笔'), findsWidgets);
      expect(find.text('还剩 3 笔'), findsWidgets);
      // 队列里当前是哪一笔由整理顺序决定，不写死 —— 只要求它是刚导入的三笔之一。
      final shownImported = <String>['老王牛肉面', '地铁公司', '早餐铺'].any(
        (merchant) => find.text(merchant).evaluate().isNotEmpty,
      );
      expect(shownImported, isTrue, reason: '整理页要真的列出刚导入的账单');

      // 首页：金额也要立刻出来。
      await tester.tap(
        find.descendant(
          of: find.byType(AppBottomBar),
          matching: find.text('本月'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('42.00'),
        findsWidgets,
        reason: '首页金额与整理页用的是同一份数据',
      );
      expect(find.textContaining('3 笔消费'), findsWidgets);
    });

    testWidgets('导入的是另一个月的账单时，界面跟着走到那个月', (tester) async {
      // 重读数据还不够：用户导入的可能是**上个月**的账单，
      // 界面停在原地同样什么都看不到。口径是
      // 「导入之后看到的 = 重启之后看到的」。
      fileSource.bytes = bytesOf(augustBill);
      await pumpApp(tester);
      await openUploadScreen(tester);
      await tapAction(tester, '选择账单文件');
      await tapAction(tester, '确认导入 2 笔');
      await tapAction(tester, '开始整理');

      expect(
        find.textContaining('AUGUST, 2026'),
        findsWidgets,
        reason: '8 月才是这批账单所在的月份',
      );
      expect(find.textContaining('这个月还没有账单'), findsNothing);
      expect(find.textContaining('0 / 2 笔'), findsWidgets);
    });

    testWidgets('退款那笔不会被计入', (tester) async {      await pumpApp(tester);
      await openUploadScreen(tester);
      await tapAction(tester, '选择账单文件');

      // 「需要检查的记录」入口带着真实行数。
      expect(find.textContaining('1 行没读进来'), findsOneWidget);
      await tester.tap(find.text('需要检查的记录'));
      await tester.pumpAndSettle();

      expect(find.text('有 1 行需要检查'), findsOneWidget);
      expect(find.textContaining('不是已完成的消费'), findsWidgets);
    });
  });

  group('字段映射', () {
    testWidgets('表头认不出来时进映射页，并给出文件前几行', (tester) async {
      fileSource.bytes = bytesOf(unknownHeaderBill);
      await pumpApp(tester);
      await openUploadScreen(tester);

      await tapAction(tester, '选择账单文件');

      expect(find.text('匹配表格字段'), findsWidgets);
      expect(find.textContaining('日期戳'), findsWidgets);
      // 必填项没齐，按钮不能点。
      expect(actionFor(tester, '确认字段，预览账单').onPressed, isNull);
    });
  });

  group('导入记录', () {
    testWidgets('没有导入过时给出空状态与入口', (tester) async {
      await pumpApp(tester);

      // 从「我的」进导入记录。
      await tester.tap(find.text('我的').last);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('导入记录'));
      await tester.pumpAndSettle();

      expect(find.text('还没有导入过账单'), findsOneWidget);
    });

    testWidgets('数据管理页的「导入批次」是真实数量，不是占位符', (tester) async {
      await pumpApp(tester);
      await openUploadScreen(tester);
      await tapAction(tester, '选择账单文件');
      await tapAction(tester, '确认导入 3 笔');

      // 完成页没有底部导航，先回到有标签的那几页。
      await tapAction(tester, '开始整理');

      // 我的 → 隐私与数据 → 清除本地数据（这一页就是数据管理）。
      await tester.tap(find.text('我的').last);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('隐私与数据'));
      await tester.pumpAndSettle();
      await tapActionBelowFold(tester, '清除本地数据');

      // 这一行曾经写死成「—」，而批次其实早就有数据了。
      expect(find.text('导入批次'), findsOneWidget);
      expect(find.text('1 批'), findsOneWidget);
      expect(find.text('—'), findsNothing);
    });
  });

  group('导入异常明细的导出', () {
    /// 55 行坏行 + 2 行好行。55 是有意的：异常页面上只列前 50 行。
    String billWithProblems(int badRows) {
      final buffer = StringBuffer()
        ..writeln('微信支付账单明细')
        ..writeln('交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号,商户单号,备注')
        ..writeln('2026-09-23 14:26:00,商户消费,老王牛肉面,牛肉面,支出,¥28.00,零钱,支付成功,4200001,M1001,/')
        ..writeln('2026-09-24 09:02:11,商户消费,地铁公司,地铁,支出,¥5.00,零钱,支付成功,4200002,M1002,/');
      for (var i = 0; i < badRows; i++) {
        // 时间写得看不懂 —— 这是真实的「行级异常」之一。
        buffer.writeln('9/3,商户消费,某店,某物,支出,¥1.00,零钱,支付成功,9$i,M9$i,/');
      }
      return buffer.toString();
    }

    testWidgets('界面上只列前 50 行，导出的是完整清单', (tester) async {
      const badRows = 55;
      fileSource
        ..bytes = bytesOf(billWithProblems(badRows))
        ..name = '2026-09.csv';
      final saver = _RecordingSaver();

      await pumpApp(tester, saver: saver);
      await openUploadScreen(tester);
      await tapAction(tester, '选择账单文件');

      // 核对页上从「需要检查的记录」进异常页。
      await tester.tap(find.text('需要检查的记录'));
      await tester.pumpAndSettle();
      expect(find.text('有 $badRows 行需要检查'), findsOneWidget);
      expect(find.textContaining('还有 5 行没有列出来'), findsOneWidget);

      await tapActionBelowFold(tester, '导出异常明细');

      expect(saver.requests, hasLength(1), reason: '导出只该走一次系统保存');
      final request = saver.requests.single;
      expect(request.fileName, endsWith('_导入异常明细.csv'));
      expect(request.mimeType, 'text/csv');

      // 真正要守的那条：界面上列不下，导出的必须一行不少。
      final text = utf8.decode(request.bytes);
      final lines = text.trim().split('\r\n');
      expect(lines.first, '行号,状态,原因,原始内容');
      expect(lines, hasLength(badRows + 1), reason: '表头 + 全部异常行');
      expect(
        lines.where((line) => line.contains('无效')).length,
        badRows,
        reason: '界面上列不下的那 5 行，文件里必须有',
      );
    });
  });
}

/// 记录「存了什么」，供断言。
///
/// 真实的实现要走系统「创建文档」界面，测试里没人能替用户点 —— 这也是把
/// 保存做成端口的原因之一。
final class _RecordingSaver implements DocumentSaver {
  final List<_SaveRequest> requests = <_SaveRequest>[];

  /// 让保存返回什么。
  SaveOutcome outcome = const DocumentSaved(name: '有数_导入异常明细.csv');

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<SaveOutcome> save({
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    requests.add(
      _SaveRequest(fileName: fileName, mimeType: mimeType, bytes: bytes),
    );
    return outcome;
  }

  @override
  Future<SaveOutcome> saveImageToGallery({
    required String fileName,
    required Uint8List bytes,
  }) async => const SaveFailed('这份测试不涉及相册');
}

final class _SaveRequest {
  _SaveRequest({
    required this.fileName,
    required this.mimeType,
    required this.bytes,
  });

  final String fileName;
  final String mimeType;
  final Uint8List bytes;
}
