import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:younum/domain/models/allocation.dart';
import 'package:younum/domain/models/category.dart';
import 'package:younum/domain/models/ledger_dataset.dart';
import 'package:younum/domain/models/ledger_transaction.dart';
import 'package:younum/domain/models/year_month.dart';
import 'package:younum/domain/repositories/document_saver.dart';
import 'package:younum/domain/repositories/poster_ports.dart';
import 'package:younum/domain/rules/export_rules.dart';
import 'package:younum/domain/rules/month_overview.dart';
import 'package:younum/domain/rules/share_poster_rules.dart';
import 'package:younum/features/export/export_files.dart';

/// 导出编排：文件名、内容生成、渲染失败时不落盘。
/// 记录调用的假保存器。
final class FakeSaver implements DocumentSaver {
  FakeSaver({this.outcome = const DocumentSaved(name: 'x.csv')});

  SaveOutcome outcome;
  bool available = true;
  final List<({String fileName, String mimeType, Uint8List bytes})> calls =
      <({String fileName, String mimeType, Uint8List bytes})>[];

  @override
  Future<bool> isAvailable() async => available;

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

/// 记录它被要求画过什么的假渲染器。
final class FakeMaker implements PosterMaker {
  FakeMaker({this.result});

  PosterRenderResult? result;
  final List<SharePosterSpec> specs = <SharePosterSpec>[];

  @override
  Future<PosterRenderResult> render(
    SharePosterSpec spec, {
    double scale = posterExportScale,
  }) async {
    specs.add(spec);
    return result ??
        PosterRendered(Uint8List.fromList(<int>[1, 2, 3]), width: 4, height: 5);
  }
}

void main() {
  const ledgerId = 1;
  final september = YearMonth(2026, 9);

  LedgerDataset dataset() => LedgerDataset(
    transactions: <LedgerTransaction>[
      LedgerTransaction(
        id: 1,
        ledgerId: ledgerId,
        occurredAtMs: DateTime.utc(2026, 9, 23, 4, 9).millisecondsSinceEpoch,
        amountCents: 2800,
        merchant: 'MANNER COFFEE',
        nature: TransactionNature.expense,
        reviewStatus: ReviewStatus.resolved,
        timeZone: 'Asia/Shanghai',
      ),
      // 另一个月：不能出现在 9 月的导出里。
      LedgerTransaction(
        id: 2,
        ledgerId: ledgerId,
        occurredAtMs: DateTime.utc(2026, 8, 20, 4, 0).millisecondsSinceEpoch,
        amountCents: 9900,
        merchant: '上个月的店',
        nature: TransactionNature.expense,
        reviewStatus: ReviewStatus.resolved,
        timeZone: 'Asia/Shanghai',
      ),
    ],
    categories: <Category>[
      Category(
        id: 1,
        name: '餐饮',
        iconType: CategoryIconType.builtin,
        iconKey: 'food',
        sortOrder: 1,
        isBuiltin: true,
      ),
    ],
    allocations: <Allocation>[
      Allocation(id: 1, transactionId: 1, categoryId: 1, amountCents: 2800),
    ],
  );

  SharePosterSpec spec({bool showAmount = false}) => SharePosterRules.build(
    overview: MonthOverview.compute(
      month: september,
      dataset: dataset(),
      coverageConfirmed: true,
      isDemoLedger: true,
    ),
    privacy: ExportPrivacy(showAmount: showAmount),
    palette: const PosterPalette(
      background: Color(0xFFE8EFE4),
      foreground: Color(0xFF22331D),
      muted: Color(0xFF6B7A63),
    ),
  );

  test('文件名带月份，且不出现「备份」字样', () {
    expect(detailCsvFileName(september), '有数_2026-09_明细.csv');
    expect(posterFileName(september), '有数_2026-09_月度回顾.png');
    expect(detailCsvFileName(september), isNot(contains('备份')));
  });

  test('CSV 只含目标月份，带 BOM 与防注入处理', () {
    final bytes = detailCsvBytes(dataset: dataset(), month: september);
    expect(bytes.sublist(0, 3), <int>[0xEF, 0xBB, 0xBF]);

    final text = utf8.decode(bytes);
    expect(text, contains('MANNER COFFEE'));
    expect(text, contains('-28.00'));
    expect(text, contains('餐饮'));
    expect(text, isNot(contains('上个月的店')), reason: '不能把别的月份带出去');
  });

  test('保存 CSV：交给系统的是文本类型与带月份的文件名', () async {
    final saver = FakeSaver(outcome: const DocumentSaved(name: '存好的.csv'));
    final outcome = await saveDetailCsv(
      saver: saver,
      dataset: dataset(),
      month: september,
    );

    expect(outcome, isA<DocumentSaved>());
    expect(saver.calls, hasLength(1));
    expect(saver.calls.single.mimeType, 'text/csv');
    expect(saver.calls.single.fileName, '有数_2026-09_明细.csv');
  });

  test('保存海报：先渲染再保存，用的是传进来的那份清单', () async {
    final saver = FakeSaver(
      outcome: const DocumentSaved(name: '有数_2026-09_月度回顾.png'),
    );
    final maker = FakeMaker();

    final outcome = await savePoster(
      saver: saver,
      maker: maker,
      spec: spec(),
      month: september,
    );

    expect(outcome, isA<DocumentSaved>());
    expect(maker.specs, hasLength(1));
    expect(maker.specs.single.showsAmount, isFalse);
    expect(saver.calls.single.mimeType, 'image/png');
    expect(saver.calls.single.fileName, '有数_2026-09_月度回顾.png');
    expect(saver.calls.single.bytes, <int>[1, 2, 3]);
  });

  test('渲染失败时不落盘，并且把原因原样带出来', () async {
    final saver = FakeSaver();
    final maker = FakeMaker(result: const PosterRenderFailed('生成图片时出了点问题，请重试'));

    final outcome = await savePoster(
      saver: saver,
      maker: maker,
      spec: spec(),
      month: september,
    );

    expect(outcome, isA<SaveFailed>());
    expect((outcome as SaveFailed).message, contains('出了点问题'));
    expect(saver.calls, isEmpty, reason: '画不出来就不该产生文件');
  });

  test('取消与失败原样传回去，不会被改写成成功', () async {
    for (final outcome in <SaveOutcome>[
      const SaveCanceled(),
      const SaveFailed('磁盘满了'),
    ]) {
      final saver = FakeSaver(outcome: outcome);
      final result = await saveDetailCsv(
        saver: saver,
        dataset: dataset(),
        month: september,
      );
      expect(result.runtimeType, outcome.runtimeType);
    }
  });
}

