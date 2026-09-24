/// 导入相关的值对象。
///
/// 放在同一个文件里是因为它们是一组：批次 → 行 → 来源绑定，
/// 任何一个单独拿出来都没有意义。拆成三个文件只会让「改一处要开三处」。
///
/// 指南 4.3 的状态机：
///
/// ```text
/// SELECTED → READING → VALIDATING → REVIEW_REQUIRED → READY → COMMITTING → COMMITTED
///                ↘ FAILED / CANCELED
/// ```
///
/// 关键约束：**先落暂存区，用户确认后再用事务写入正式交易。未确认的数据
/// 不进入首页金额。** 所以 `import_row` 与 `txn` 是两张表，不是一张。
library;

/// 导入阶段。
enum ImportStage {
  /// 用户已经选好文件，还没开始读。
  selected,

  /// 正在读取与解码。
  reading,

  /// 正在校验与去重。
  validating,

  /// 需要用户核对（有疑似重复或异常行）。
  reviewRequired,

  /// 可以提交。
  ready,

  /// 正在写事务。
  committing,

  /// 已提交。
  committed,

  /// 失败。
  failed,

  /// 用户取消。
  canceled;

  static ImportStage parse(String value) => switch (value) {
    'SELECTED' => ImportStage.selected,
    'READING' => ImportStage.reading,
    'VALIDATING' => ImportStage.validating,
    'REVIEW_REQUIRED' => ImportStage.reviewRequired,
    'READY' => ImportStage.ready,
    'COMMITTING' => ImportStage.committing,
    'COMMITTED' => ImportStage.committed,
    'FAILED' => ImportStage.failed,
    'CANCELED' => ImportStage.canceled,
    _ => throw ArgumentError.value(value, 'value', '未知的导入阶段'),
  };

  String get storageValue => switch (this) {
    ImportStage.selected => 'SELECTED',
    ImportStage.reading => 'READING',
    ImportStage.validating => 'VALIDATING',
    ImportStage.reviewRequired => 'REVIEW_REQUIRED',
    ImportStage.ready => 'READY',
    ImportStage.committing => 'COMMITTING',
    ImportStage.committed => 'COMMITTED',
    ImportStage.failed => 'FAILED',
    ImportStage.canceled => 'CANCELED',
  };

  /// 是否已经落进正式交易表。
  bool get isCommitted => this == ImportStage.committed;

  /// 是否还会继续推进（用于判断重启后要不要恢复）。
  bool get isInFlight =>
      this == ImportStage.reading ||
      this == ImportStage.validating ||
      this == ImportStage.committing;
}

/// 导入批次。
final class ImportBatch {
  const ImportBatch({
    required this.id,
    required this.ledgerId,
    required this.sourceNamespace,
    required this.fileName,
    required this.fileHash,
    required this.fileSizeBytes,
    required this.encoding,
    required this.delimiter,
    required this.stage,
    required this.startedAtMs,
    this.rangeStartMs,
    this.rangeEndMs,
    this.totalRows = 0,
    this.newCount = 0,
    this.duplicateCount = 0,
    this.invalidCount = 0,
    this.amountCents = 0,
    this.committedAtMs,
    this.revertedAtMs,
  });

  static const int idUnassigned = 0;

  final int id;

  final int ledgerId;

  /// 来源命名空间（`wechat` / `alipay` / `manual`）。
  final String sourceNamespace;

  final String fileName;

  /// 文件内容哈希。用来识别「同一份文件」，**不代替逐笔去重**。
  final String fileHash;

  final int fileSizeBytes;

  /// 实际采用的编码名（`UTF-8` / `GBK`）。
  final String encoding;

  final String delimiter;

  final ImportStage stage;

  final int startedAtMs;

  /// 账单覆盖的时间范围（毫秒）。文件里没有可用日期时为 null。
  final int? rangeStartMs;
  final int? rangeEndMs;

  final int totalRows;

  /// 新增（会写入正式交易）的笔数。
  final int newCount;

  /// 判定为重复、被排除的笔数。
  final int duplicateCount;

  /// 校验失败、未纳入的笔数。
  final int invalidCount;

  /// 纳入交易的金额合计（分）。
  final int amountCents;

  final int? committedAtMs;

  /// 被撤回的时间。非 null 表示这个批次已经撤回过。
  final int? revertedAtMs;

  bool get isReverted => revertedAtMs != null;

  /// 能否撤回：已提交、且还没撤回过。
  bool get canRevert => stage.isCommitted && !isReverted;

  ImportBatch copyWith({
    int? id,
    ImportStage? stage,
    int? rangeStartMs,
    int? rangeEndMs,
    int? totalRows,
    int? newCount,
    int? duplicateCount,
    int? invalidCount,
    int? amountCents,
    int? committedAtMs,
    int? revertedAtMs,
  }) => ImportBatch(
    id: id ?? this.id,
    ledgerId: ledgerId,
    sourceNamespace: sourceNamespace,
    fileName: fileName,
    fileHash: fileHash,
    fileSizeBytes: fileSizeBytes,
    encoding: encoding,
    delimiter: delimiter,
    stage: stage ?? this.stage,
    startedAtMs: startedAtMs,
    rangeStartMs: rangeStartMs ?? this.rangeStartMs,
    rangeEndMs: rangeEndMs ?? this.rangeEndMs,
    totalRows: totalRows ?? this.totalRows,
    newCount: newCount ?? this.newCount,
    duplicateCount: duplicateCount ?? this.duplicateCount,
    invalidCount: invalidCount ?? this.invalidCount,
    amountCents: amountCents ?? this.amountCents,
    committedAtMs: committedAtMs ?? this.committedAtMs,
    revertedAtMs: revertedAtMs ?? this.revertedAtMs,
  );

  @override
  bool operator ==(Object other) => other is ImportBatch && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'ImportBatch($id, $fileName, ${stage.storageValue}, +$newCount)';
}

/// 一行的处理结果。
enum ImportRowStatus {
  /// 新增，会写入正式交易。
  newRow,

  /// 同源重复，默认不纳入。
  duplicate,

  /// 校验失败，未纳入。
  invalid,

  /// 用户主动跳过。
  skipped,

  /// 已经写入正式交易。
  imported;

  static ImportRowStatus parse(String value) => switch (value) {
    'NEW' => ImportRowStatus.newRow,
    'DUPLICATE' => ImportRowStatus.duplicate,
    'INVALID' => ImportRowStatus.invalid,
    'SKIPPED' => ImportRowStatus.skipped,
    'IMPORTED' => ImportRowStatus.imported,
    _ => throw ArgumentError.value(value, 'value', '未知的行状态'),
  };

  String get storageValue => switch (this) {
    ImportRowStatus.newRow => 'NEW',
    ImportRowStatus.duplicate => 'DUPLICATE',
    ImportRowStatus.invalid => 'INVALID',
    ImportRowStatus.skipped => 'SKIPPED',
    ImportRowStatus.imported => 'IMPORTED',
  };

  bool get isProblem =>
      this == ImportRowStatus.duplicate || this == ImportRowStatus.invalid;
}

/// 收支方向。**不是**交易性质 —— 性质要等用户确认。
enum ImportDirection {
  expense,
  income,
  transfer,

  /// 文件里读不出方向，交给用户判断。
  unknown;

  static ImportDirection parse(String value) => switch (value) {
    'EXPENSE' => ImportDirection.expense,
    'INCOME' => ImportDirection.income,
    'TRANSFER' => ImportDirection.transfer,
    _ => ImportDirection.unknown,
  };

  String get storageValue => switch (this) {
    ImportDirection.expense => 'EXPENSE',
    ImportDirection.income => 'INCOME',
    ImportDirection.transfer => 'TRANSFER',
    ImportDirection.unknown => 'UNKNOWN',
  };

  String get label => switch (this) {
    ImportDirection.expense => '支出',
    ImportDirection.income => '收入',
    ImportDirection.transfer => '转账',
    ImportDirection.unknown => '待判断',
  };
}

/// 暂存区里的一行。
final class ImportRow {
  const ImportRow({
    required this.id,
    required this.batchId,
    required this.rowNumber,
    required this.status,
    this.rawText,
    this.occurredAtMs,
    this.amountCents,
    this.direction,
    this.merchant,
    this.issue,
    this.dedupeKey,
    this.included = true,
    this.transactionId,
  });

  static const int idUnassigned = 0;

  final int id;

  final int batchId;

  /// 在文件里的第几行（1 起，含表头与说明行），便于用户回到原文件核对。
  final int rowNumber;

  final ImportRowStatus status;

  /// 原始行文本，保留以便追溯。
  final String? rawText;

  final int? occurredAtMs;

  /// 金额（分），非负。方向由 [direction] 表达。
  final int? amountCents;

  final ImportDirection? direction;

  final String? merchant;

  /// 校验问题说明。界面上按行展示原因（指南 4.3）。
  final String? issue;

  /// 同源去重键。没有稳定来源 ID 时为 null。
  final String? dedupeKey;

  /// 是否纳入交易。
  final bool included;

  /// 提交后指向写入的交易 ID。
  final int? transactionId;

  ImportRow copyWith({
    ImportRowStatus? status,
    bool? included,
    int? transactionId,
  }) => ImportRow(
    id: id,
    batchId: batchId,
    rowNumber: rowNumber,
    status: status ?? this.status,
    rawText: rawText,
    occurredAtMs: occurredAtMs,
    amountCents: amountCents,
    direction: direction,
    merchant: merchant,
    issue: issue,
    dedupeKey: dedupeKey,
    included: included ?? this.included,
    transactionId: transactionId ?? this.transactionId,
  );

  @override
  bool operator ==(Object other) => other is ImportRow && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'ImportRow($batchId#$rowNumber, ${status.storageValue}, ${merchant ?? '—'})';
}

/// 交易与来源批次的绑定。
///
/// 一笔交易可以有多条来源记录：同一把消费同时出现在微信与支付宝账单里是常事。
/// 所以撤回一个批次时，只有**没有任何其它来源**的交易才能被删掉（指南 4.4）。
final class TransactionOrigin {
  const TransactionOrigin({
    required this.id,
    required this.transactionId,
    required this.batchId,
    required this.rowNumber,
  });

  static const int idUnassigned = 0;

  final int id;

  final int transactionId;

  final int batchId;

  final int rowNumber;

  @override
  bool operator ==(Object other) =>
      other is TransactionOrigin && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'TransactionOrigin(tx=$transactionId, batch=$batchId)';
}
