/// 导出：文件名、内容生成与保存。
///
/// 这一层只做编排 —— 内容由 `ExportRules` / `SharePosterRules` 决定（纯函数，
/// 单测覆盖），落盘由 `DocumentSaver` 负责（原生走系统「创建文档」流程）。
/// 顺序很重要：[savePoster] 是**先渲染再保存**，所以「渲染失败」不会走到保存，
/// 也就不会出现「保存成功但内容不对」。
library;

import 'dart:typed_data';

import '../../domain/models/ledger_dataset.dart';
import '../../domain/models/year_month.dart';
import '../../domain/repositories/document_saver.dart';
import '../../domain/repositories/poster_ports.dart';
import '../../domain/rules/export_rules.dart';
import '../../domain/rules/share_poster_rules.dart';

/// `2026-09`。
String monthKey(YearMonth month) =>
    '${month.year}-${month.month.toString().padLeft(2, '0')}';

/// `有数_2026-09_明细.csv`。
///
/// 刻意**不带「备份」字样**：首版没有可恢复的备份格式，写成备份会让用户以为
/// 删了还能还原（指南 8.1）。
String detailCsvFileName(YearMonth month) => '有数_${monthKey(month)}_明细.csv';

/// `有数_2026-09_月度回顾.png`。
String posterFileName(YearMonth month) => '有数_${monthKey(month)}_月度回顾.png';

/// 某个月的明细 CSV 字节（真实查询结果 → 规则层，带 UTF-8 BOM）。
///
/// 只保留目标月份：导出内容必须与所选月份一致。
Uint8List detailCsvBytes({
  required LedgerDataset dataset,
  required YearMonth month,
}) => ExportRules.detailCsvBytes(
  ExportRules.detailRows(dataset: dataset, month: month),
);

/// 保存明细 CSV。
Future<SaveOutcome> saveDetailCsv({
  required DocumentSaver saver,
  required LedgerDataset dataset,
  required YearMonth month,
}) => saver.save(
  fileName: detailCsvFileName(month),
  mimeType: 'text/csv',
  bytes: detailCsvBytes(dataset: dataset, month: month),
);

/// 保存月报海报。
///
/// [spec] 决定了文件里有什么 —— 隐私开关必须已经体现在这份清单里
/// （见 `DECISIONS.md` 第 55 节）：渲染器拿不到交易，也就漏不出金额。
Future<SaveOutcome> savePoster({
  required DocumentSaver saver,
  required PosterMaker maker,
  required SharePosterSpec spec,
  required YearMonth month,
}) async {
  final rendered = await maker.render(spec);
  return switch (rendered) {
    PosterRendered(:final bytes) => saver.save(
      fileName: posterFileName(month),
      mimeType: 'image/png',
      bytes: bytes,
    ),
    PosterRenderFailed(:final message) => SaveFailed(message),
  };
}
