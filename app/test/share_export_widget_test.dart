import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/app/app.dart';
import 'package:younum/app/app_routes.dart';
import 'package:younum/core/preferences/app_state_store.dart';
import 'package:younum/core/preferences/theme_controller.dart';
import 'package:younum/core/preferences/theme_store.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/domain/repositories/document_saver.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/domain/repositories/poster_ports.dart';
import 'package:younum/domain/rules/share_poster_rules.dart';
import 'package:younum/features/export/poster_preview.dart';

/// 分享与导出的界面接线。
///
/// 指南 8.1 要求「隐私开关必须影响最终文件，不是屏幕上的遮罩」，10.4 要求
/// 「隐藏金额后检查生成的 PNG」。这里的验法是：假渲染器把它**被要求画的那份
/// 清单**记下来，于是可以断言文件内容里根本没有金额 —— 而不是只检查屏幕。

/// 记录被要求渲染的清单。
final class _RecordingMaker implements PosterMaker {
  final List<SharePosterSpec> specs = <SharePosterSpec>[];
  Uint8List bytes = Uint8List.fromList(<int>[9, 8, 7]);

  @override
  Future<PosterRenderResult> render(
    SharePosterSpec spec, {
    double scale = posterExportScale,
  }) async {
    specs.add(spec);
    return PosterRendered(bytes, width: 1500, height: 2000);
  }
}

/// 记录被保存的文件。
final class _RecordingSaver implements DocumentSaver {
  SaveOutcome outcome = const DocumentSaved(name: '有数_2026-09_明细.csv');
  final List<({String fileName, String mimeType, Uint8List bytes})> calls =
      <({String fileName, String mimeType, Uint8List bytes})>[];

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<SaveOutcome> save({
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    calls.add((fileName: fileName, mimeType: mimeType, bytes: bytes));
    return outcome;
  }
}

/// 看起来像金额的数字（例如 633.30）。用来断言「文件里没有金额」。
final RegExp _money = RegExp(r'\d+[.,]\d\d');

void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late ThemeController themeController;
  late AppStateController appStateController;

  late _RecordingMaker maker;
  late _RecordingSaver saver;

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

    maker = _RecordingMaker();
    saver = _RecordingSaver();
  });

  tearDown(() {
    themeController.dispose();
  });

  /// 挂应用并打开分享页（入口在月报页，这里不需要走那一串点击）。
  Future<void> openShare(WidgetTester tester) async {
    await tester.pumpWidget(
      YounumApp(
        themeController: themeController,
        appStateController: appStateController,
        ledgerRepository: repository,
        ledgerFileSource: const UnsupportedFileSource(),
        posterMaker: maker,
        documentSaver: saver,
      ),
    );
    await tester.pumpAndSettle();

    final navigator = Navigator.of(tester.element(find.byType(Navigator).first));
    unawaited(navigator.pushNamed(AppRoutes.share));
    await tester.pumpAndSettle();
  }

  SharePosterSpec previewSpec(WidgetTester tester) =>
      tester.widget<PosterPreview>(find.byType(PosterPreview)).spec;

  Future<void> tapAction(WidgetTester tester, String label) async {
    final target = find.text(label);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> toggleAmount(WidgetTester tester) async {
    final target = find.byType(Switch);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets('默认隐藏金额：预览清单里没有任何金额数字', (tester) async {
    await openShare(tester);

    final spec = previewSpec(tester);
    expect(spec.showsAmount, isFalse);
    expect(spec.amountText, SharePosterRules.hiddenAmountText);
    for (final text in spec.allText) {
      expect(_money.hasMatch(text), isFalse, reason: '不该出现金额：$text');
    }
  });

  testWidgets('导出月度回顾：交给渲染器的清单里没有金额，存的是渲染出来的字节', (tester) async {
    await openShare(tester);
    await tapAction(tester, '导出月度回顾');

    expect(maker.specs, hasLength(1));
    final rendered = maker.specs.single;
    expect(rendered.showsAmount, isFalse);
    expect(rendered.amountText, SharePosterRules.hiddenAmountText);
    for (final text in rendered.allText) {
      expect(_money.hasMatch(text), isFalse, reason: '导出的文件里不该有金额：$text');
    }

    expect(saver.calls, hasLength(1));
    expect(saver.calls.single.mimeType, 'image/png');
    expect(saver.calls.single.fileName, endsWith('_月度回顾.png'));
    expect(saver.calls.single.bytes, <int>[9, 8, 7], reason: '存的就是渲染出来的字节');
    expect(find.textContaining('已保存'), findsOneWidget);
  });

  testWidgets('打开金额开关后导出：清单里出现金额', (tester) async {
    await openShare(tester);
    await toggleAmount(tester);

    expect(previewSpec(tester).showsAmount, isTrue);

    await tapAction(tester, '导出月度回顾');
    final rendered = maker.specs.single;
    expect(rendered.showsAmount, isTrue);
    expect(rendered.amountText, isNot(SharePosterRules.hiddenAmountText));
    expect(_money.hasMatch(rendered.amountText), isTrue);
  });

  testWidgets('用户取消保存：不显示成功，也不报错', (tester) async {
    saver.outcome = const SaveCanceled();
    await openShare(tester);
    await tapAction(tester, '导出月度回顾');

    expect(saver.calls, hasLength(1));
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('保存失败：如实说明原因', (tester) async {
    saver.outcome = const SaveFailed('这个位置写不进去，请换一个位置');
    await openShare(tester);
    await tapAction(tester, '导出月度回顾');

    expect(find.text('这个位置写不进去，请换一个位置'), findsOneWidget);
  });

  testWidgets('导出明细 CSV：字节带 BOM，且只含本月', (tester) async {
    await openShare(tester);
    final period = previewSpec(tester).periodLabel; // 2026 / 09
    await tapAction(tester, '导出明细 CSV');

    expect(saver.calls, hasLength(1));
    final call = saver.calls.single;
    expect(call.mimeType, 'text/csv');
    expect(call.fileName, endsWith('_明细.csv'));
    expect(call.bytes.sublist(0, 3), <int>[0xEF, 0xBB, 0xBF], reason: 'UTF-8 BOM');

    final text = utf8.decode(call.bytes);
    expect(text, startsWith('时间,商户,金额,收支,用途,备注'));

    final key = period.replaceAll(' / ', '-');
    final lines = text.trim().split('\r\n').skip(1).toList();
    expect(lines, isNotEmpty);
    for (final line in lines) {
      expect(line.startsWith(key), isTrue, reason: '不该混进别的月份：$line');
    }
  });

  testWidgets('再次进入分享，金额又回到隐藏', (tester) async {
    await openShare(tester);
    await toggleAmount(tester);
    expect(previewSpec(tester).showsAmount, isTrue);

    // 退回月报再进来一次：开关必须回到默认，不沿用上一次公开出去的设置。
    Navigator.of(tester.element(find.byType(PosterPreview))).pop();
    await tester.pumpAndSettle();

    final navigator = Navigator.of(tester.element(find.byType(Navigator).first));
    unawaited(navigator.pushNamed(AppRoutes.share));
    await tester.pumpAndSettle();

    expect(previewSpec(tester).showsAmount, isFalse);
  });
}
