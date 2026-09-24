/// 导入编排：把「解析 → 暂存 → 提交 → 撤回」串起来。
///
/// 单独一个文件是因为这条链路比整理会话长得多，混在
/// `LedgerRepository` 里会让那个文件难以通读；但它仍然属于同一层
/// （同样的 store 端口、同样的规则函数），所以用扩展方法接上去，
/// 调用方拿到的还是同一个 `LedgerRepository`。
///
/// 关键约定（指南 4.3 / 4.4）：
///
/// * **先落暂存区，用户确认后再写入正式账。** `stage()` 只写
///   `import_batch` / `import_row`，首页金额不受影响。
/// * **提交是一个事务。** 要么整批进去，要么全不进去。
/// * **撤回按引用计数。** 只删「没有别的批次引用、且用户还没动过」的交易。
library;

import 'dart:typed_data';

import '../../core/time/statistics_time.dart';
import '../models/import_records.dart';
import '../models/ledger_transaction.dart';
import '../rules/csv_parser.dart';
import '../rules/import_rules.dart';
import '../rules/text_decoding.dart';
import 'ledger_repository.dart';
import 'ledger_store.dart';

/// 暂存阶段的结果。
sealed class ImportStageResult {
  const ImportStageResult();
}

/// 已经暂存好，可以进入核对页。
final class ImportStaged extends ImportStageResult {
  const ImportStaged(this.preview);

  final ImportPreview preview;
}

/// 文件读得出来，但**表头认不出来或缺必填列**，需要用户手工做字段映射。
///
/// 这里刻意**不落库**：还不知道怎么映射，就没有「这一行是什么」可言，
/// 存一堆看不懂的行只会让用户以为导入已经进行了一半。
final class ImportMappingRequired extends ImportStageResult {
  const ImportMappingRequired({
    required this.headers,
    required this.missingFields,
    required this.sampleRows,
    required this.totalRows,
  });

  final List<String> headers;

  /// 缺的必填列。
  final Set<ImportField> missingFields;

  /// 前几行原文，给映射界面做预览。指南要求至少 3 行。
  final List<List<String>> sampleRows;

  final int totalRows;
}

/// 连文件都没读进来。
final class ImportStageRejected extends ImportStageResult {
  const ImportStageRejected(this.message);

  /// 直接给用户看的原因。
  final String message;
}

/// 暂存结果里给界面看的统计。
final class ImportPreview {
  const ImportPreview({
    required this.batchId,
    required this.fileName,
    required this.encoding,
    required this.totalRows,
    required this.freshCount,
    required this.duplicateCount,
    required this.suspectedCount,
    required this.invalidCount,
    required this.skippedCount,
    required this.freshCents,
    required this.rangeStartMs,
    required this.rangeEndMs,
    required this.issues,
  });

  final int batchId;
  final String fileName;

  /// 实际采用的编码名，显示在核对页上让用户有机会发现乱码。
  final String encoding;

  /// 文件里的总行数（含说明行与表头）。
  final int totalRows;

  /// 会写入正式账的笔数。
  final int freshCount;

  /// 同源重复、默认不纳入的笔数。
  final int duplicateCount;

  /// 疑似重复的笔数。**默认仍然纳入**，只是要用户确认。
  final int suspectedCount;

  /// 校验失败的笔数。
  final int invalidCount;

  /// 跳过的行数（说明行、空行、合计行）。
  final int skippedCount;

  /// 将写入的金额合计（分）。
  final int freshCents;

  final int? rangeStartMs;
  final int? rangeEndMs;

  /// 前几条校验失败的原因，便于界面上直接列出来。
  final List<String> issues;

  bool get isEmpty => freshCount == 0;

  /// 有疑似重复时必须先让用户确认分组，不能直接提示「完成」。
  bool get needsReview => suspectedCount > 0;
}

/// 提交结果。
final class ImportCommitResult {
  const ImportCommitResult({
    required this.transactionIds,
    required this.amountCents,
    required this.batch,
  });

  final List<int> transactionIds;
  final int amountCents;
  final ImportBatch batch;

  int get count => transactionIds.length;
}

/// 导入编排。
extension ImportWorkflow on LedgerRepository {
  /// 解析并暂存一份账单文件。**不写入正式账。**
  ///
  /// [sourceNamespace] 例如 `wechat` / `alipay`；[sourceAccount] 是账户名
  /// （零钱 / 银行卡），它参与同源去重键，所以两份不同账户的账单里
  /// 出现同一个单号不会被误判成同一笔。
  Future<ImportStageResult> stageImport({
    required int ledgerId,
    required String fileName,
    required Uint8List bytes,
    required String sourceNamespace,
    String? sourceAccount,
    TextEncoding? encoding,
  }) async {
    if (bytes.isEmpty) {
      return const ImportStageRejected('文件是空的');
    }

    // 传了 encoding 就按它解（用户在核对页上手工指定的）；
    // 不传就探测。
    final (decoded, decodeError) = TextDecoding.decode(bytes, force: encoding);
    if (decodeError != null || decoded == null) {
      return ImportStageRejected(_decodeMessage(decodeError!));
    }

    final (table, csvError) = CsvParser.parse(decoded.text);
    if (csvError != null) {
      return ImportStageRejected(_csvMessage(csvError));
    }
    if (table == null || table.isEmpty) {
      return ImportStageRejected('这份文件里没有读到任何一行');
    }

    final header = ImportRules.detectHeader(table);
    if (header.needsManualMapping) {
      return ImportMappingRequired(
        headers: header.headers,
        missingFields: header.missingRequired,
        sampleRows: _sampleRows(table, header),
        totalRows: table.rows.length,
      );
    }

    // 已入库的同源键与弱键，用来判断「这份文件里有没有库里已经有的记录」。
    final existing = await dataset(ledgerId: ledgerId);
    final knownStable = <String>{};
    final knownWeak = <String>{};
    for (final transaction in existing.transactions) {
      final key = transaction.dedupeKey;
      if (key != null) knownStable.add(key);
      knownWeak.add(
        ImportRules.weakKeyOf(
          merchant: transaction.merchant,
          occurredAtMs: transaction.occurredAtMs,
          amountCents: transaction.amountCents,
        ),
      );
    }

    final parsed = <RowParsed>[];
    final rows = <ImportRow>[];
    var skipped = 0;
    var invalid = 0;
    var duplicates = 0;
    var suspected = 0;
    var freshCents = 0;
    int? rangeStart;
    int? rangeEnd;
    final issues = <String>[];

    for (var index = 0; index < table.rows.length; index++) {
      final rowNumber = index + 1;
      final result = ImportRules.parseRow(
        row: table.rows[index],
        rowNumber: rowNumber,
        header: header,
      );

      switch (result) {
        case RowSkipped():
          skipped++;
        case RowInvalid():
          invalid++;
          if (issues.length < 8) {
            issues.add('第 $rowNumber 行：${result.issue}');
          }
          rows.add(
            ImportRow(
              id: ImportRow.idUnassigned,
              batchId: ImportBatch.idUnassigned,
              rowNumber: rowNumber,
              status: ImportRowStatus.invalid,
              rawText: result.rawText,
              issue: result.issue,
              included: false,
            ),
          );
        case RowParsed():
          final stableKey = ImportRules.stableKeyOf(
            sourceNamespace: sourceNamespace,
            sourceAccount: sourceAccount,
            orderId: result.orderId,
          );
          final weakKey = ImportRules.weakKeyOf(
            merchant: result.merchant,
            occurredAtMs: result.occurredAtMs,
            amountCents: result.amountCents,
          );
          final verdict = ImportRules.classify(
            stableKey: stableKey,
            weakKey: weakKey,
            knownStableKeys: knownStable,
            knownWeakKeys: knownWeak,
          );

          var status = ImportRowStatus.newRow;
          var included = true;
          String? issue;
          switch (verdict) {
            case DuplicateVerdict.sameOrigin:
              status = ImportRowStatus.duplicate;
              included = false;
              duplicates++;
              issue = '这份账单里已经导入过';
            case DuplicateVerdict.suspected:
              suspected++;
              issue = '疑似重复：商户、时间、金额与别处一致，请确认是否同一笔';
            case DuplicateVerdict.fresh:
              break;
          }

          if (stableKey != null) knownStable.add(stableKey);
          // 同一文件里后面出现的行也要能和前面比，所以无论什么判定都记进去。
          knownWeak.add(weakKey);

          if (included) {
            parsed.add(result);
            freshCents += result.amountCents;
            rangeStart = rangeStart == null
                ? result.occurredAtMs
                : (result.occurredAtMs < rangeStart
                      ? result.occurredAtMs
                      : rangeStart);
            rangeEnd = rangeEnd == null
                ? result.occurredAtMs
                : (result.occurredAtMs > rangeEnd
                      ? result.occurredAtMs
                      : rangeEnd);
          }

          rows.add(
            ImportRow(
              id: ImportRow.idUnassigned,
              batchId: ImportBatch.idUnassigned,
              rowNumber: rowNumber,
              status: status,
              rawText: result.rawText,
              occurredAtMs: result.occurredAtMs,
              amountCents: result.amountCents,
              direction: result.direction,
              merchant: result.merchant,
              issue: issue,
              dedupeKey: stableKey,
              included: included,
            ),
          );
      }
    }

    final batch = ImportBatch(
      id: ImportBatch.idUnassigned,
      ledgerId: ledgerId,
      sourceNamespace: sourceNamespace,
      fileName: fileName,
      fileHash: _hashOf(bytes),
      fileSizeBytes: bytes.length,
      encoding: decoded.encoding.label,
      delimiter: CsvParser.detectDelimiter(decoded.text),
      stage: ImportStage.reviewRequired,
      startedAtMs: nowMs(),
      rangeStartMs: rangeStart,
      rangeEndMs: rangeEnd,
      totalRows: table.rows.length,
      newCount: parsed.length,
      duplicateCount: duplicates,
      invalidCount: invalid,
    );

    final batchId = await store.insertImportBatch(batch: batch, rows: rows);

    return ImportStaged(
      ImportPreview(
        batchId: batchId,
        fileName: fileName,
        encoding: decoded.encoding.label,
        totalRows: table.rows.length,
        freshCount: parsed.length,
        duplicateCount: duplicates,
        suspectedCount: suspected,
        invalidCount: invalid,
        skippedCount: skipped,
        freshCents: freshCents,
        rangeStartMs: rangeStart,
        rangeEndMs: rangeEnd,
        issues: issues,
      ),
    );
  }

  /// 提交一个已暂存的批次。**一个事务**写入正式账。
  ///
  /// 只提交 `included` 且状态是「新增」的行；用户可以在核对页上改这些取值。
  Future<ImportCommitResult> commitImport({
    required int ledgerId,
    required int batchId,
  }) async {
    final rows = await store.importRows(batchId: batchId);
    final included = <ImportRow>[
      for (final row in rows)
        if (row.included && row.status == ImportRowStatus.newRow) row,
    ];

    // 同源键已经在库里的行：这不是「新的一笔」，而是**同一笔被另一份账单
    // 又发现了一次**。只能新增来源绑定，不能再插一条交易 ——
    // 否则真机上会撞 (ledger_id, dedupe_key) 唯一索引，整批提交失败；
    // 而且撤回时就判断不出「这笔还被别的批次引用着」，会把用户的钱删掉。
    final keys = <String>[
      for (final row in included)
        if (row.dedupeKey != null) row.dedupeKey!,
    ];
    final existingIds = keys.isEmpty
        ? const <String, int>{}
        : await store.transactionIdsByDedupeKey(
            ledgerId: ledgerId,
            dedupeKeys: keys,
          );

    // 只有知道稳定单号时才拆得出命名空间与账户。
    // 拆不出来就一律留 null——不能把一份普通 CSV 编造成「有来源」的数据。
    String? namespaceOf(ImportRow row) =>
        row.dedupeKey == null ? null : row.dedupeKey!.split('\u0000')[0];
    String? accountOf(ImportRow row) =>
        row.dedupeKey == null ? null : row.dedupeKey!.split('\u0000')[1];
    String? sourceIdOf(ImportRow row) =>
        row.dedupeKey == null ? null : row.dedupeKey!.split('\u0000')[2];

    final entries = <({ImportRow row, LedgerTransaction transaction})>[];
    for (final row in included) {
      final reusing = row.dedupeKey == null
          ? null
          : existingIds[row.dedupeKey!];
      if (reusing != null) {
        final original = await store.transactionById(reusing);
        if (original != null) {
          entries.add((row: row, transaction: original));
          continue;
        }
      }
      entries.add((
        row: row,
        transaction: LedgerTransaction(
          id: LedgerTransaction.idUnassigned,
          ledgerId: ledgerId,
          occurredAtMs: row.occurredAtMs!,
          amountCents: row.amountCents!,
          merchant: row.merchant ?? '',
          nature: _natureOf(row.direction),
          // 导入的行一律先当「待整理」：导入与分类是两件事，
          // 替用户猜分类比让他多滑几张卡片危险得多。
          reviewStatus: ReviewStatus.pending,
          timeZone: StatisticsTime.timeZone,
          sourceNamespace: namespaceOf(row),
          sourceAccount: accountOf(row),
          sourceTransactionId: sourceIdOf(row),
          importBatchId: batchId,
        ),
      ));
    }

    var totalCents = 0;
    for (final entry in entries) {
      totalCents += entry.transaction.amountCents;
    }

    var invalidCount = 0;
    var duplicateCount = 0;
    for (final row in rows) {
      if (row.status == ImportRowStatus.invalid) invalidCount++;
      if (row.status == ImportRowStatus.duplicate) duplicateCount++;
    }

    final written = await store.commitImport(
      batchId: batchId,
      entries: entries,
      nowMs: nowMs(),
      totalRows: rows.length,
      duplicateCount: duplicateCount,
      invalidCount: invalidCount,
      amountCents: totalCents,
    );

    final batches = await store.importBatches(ledgerId: ledgerId);
    final batch = batches.firstWhere(
      (candidate) => candidate.id == batchId,
      orElse: () => batches.first,
    );

    return ImportCommitResult(
      transactionIds: written,
      amountCents: totalCents,
      batch: batch,
    );
  }

  /// 撤回一个已提交的批次。
  Future<ImportRevert> revertImport({required int batchId}) =>
      store.revertImport(batchId: batchId, nowMs: nowMs());

  /// 某账本的导入历史。
  Future<List<ImportBatch>> importBatches({required int ledgerId}) =>
      store.importBatches(ledgerId: ledgerId);

  /// 一个批次里的暂存行。
  Future<List<ImportRow>> importRows({required int batchId}) =>
      store.importRows(batchId: batchId);

  /// 改暂存行的取舍。
  Future<void> updateImportRows(List<ImportRow> rows) =>
      store.updateImportRows(rows);

  /// 丢弃一个还在暂存区的批次。
  Future<void> discardImport(int batchId) => store.deleteImportBatch(batchId);

  /// 取一个批次的当前状态。
  Future<ImportBatch?> importBatch({
    required int ledgerId,
    required int batchId,
  }) async {
    final batches = await store.importBatches(ledgerId: ledgerId);
    for (final batch in batches) {
      if (batch.id == batchId) return batch;
    }
    return null;
  }

  TransactionNature _natureOf(ImportDirection? direction) =>
      switch (direction) {
        ImportDirection.expense => TransactionNature.expense,
        ImportDirection.income => TransactionNature.income,
        ImportDirection.transfer => TransactionNature.transfer,
        ImportDirection.unknown || null => TransactionNature.unknown,
      };

  List<List<String>> _sampleRows(CsvTable table, HeaderGuess header) {
    final start = header.headerRowIndex < 0 ? 0 : header.headerRowIndex + 1;
    final samples = <List<String>>[];
    for (var index = start; index < table.rows.length; index++) {
      if (samples.length >= 3) break;
      final row = table.rows[index];
      if (row.every((cell) => cell.trim().isEmpty)) continue;
      samples.add(row);
    }
    return samples;
  }

  String _decodeMessage(DecodeError error) => switch (error) {
    DecodeEmptyFile() => '这个文件是空的',
    DecodeUnsupportedEncoding(:final encodingName) =>
      '这份文件用的是 $encodingName 编码，暂时读不了。'
          '请在导出时选择「UTF-8」或「GBK」，或者用表格软件另存为 CSV。',
    DecodeAmbiguous() => '分不清这份文件是 UTF-8 还是 GBK，请手工指定一次编码。',
  };

  String _csvMessage(CsvError error) => switch (error) {
    CsvEmpty() => '这份文件里没有读到任何数据',
    CsvUnterminatedQuote(:final line, :final column) =>
      '第 $line 行第 $column 列的引号没有闭合，文件可能被截断了',
  };
}

/// 文件内容哈希（FNV-1a 64 位）。
///
/// 只用来识别「同一份文件又选了一次」。它**不代替**逐笔去重：
/// 用户重新导出了一份内容略有不同的账单时，哈希会变，但里面大多数
/// 记录是同源的，那件事只能靠 `dedupe_key` 判断。
String _hashOf(List<int> bytes) {
  var hash = 0xcbf29ce484222325;
  for (final byte in bytes) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
