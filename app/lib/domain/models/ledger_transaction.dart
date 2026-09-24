/// 交易记录。
///
/// 命名用 `LedgerTransaction` 而不是 `Transaction`：sqflite 导出同名类型，
/// 仓库层两个都会用到，重名会逼出一堆 `as` 前缀。
///
/// 指南 3.3 要求**交易性质与整理状态分开建模**，所以这里有两个独立枚举，
/// 不是一个「状态」字段兼表达两件事。
library;

import 'year_month.dart';

/// 交易性质。决定这笔记录在统计里算不算消费。
enum TransactionNature {
  /// 消费。只有完成有效分配才可 `RESOLVED`。
  expense,

  /// 收入。不计入消费。
  income,

  /// 转账。不计入消费。
  transfer,

  /// 退款。必须完成关联、或明确排除统计并保留原因，才算处理完成。
  refund,

  /// 排除统计。必须保留原因。
  excluded,

  /// 尚未判断。
  unknown;

  static TransactionNature parse(String value) => switch (value) {
        'EXPENSE' => TransactionNature.expense,
        'INCOME' => TransactionNature.income,
        'TRANSFER' => TransactionNature.transfer,
        'REFUND' => TransactionNature.refund,
        'EXCLUDED' => TransactionNature.excluded,
        'UNKNOWN' => TransactionNature.unknown,
        _ => throw ArgumentError.value(value, 'value', '未知的交易性质'),
      };

  /// 数据库里的字面值。显式映射，不依赖 `Enum.name`。
  String get storageValue => switch (this) {
        TransactionNature.expense => 'EXPENSE',
        TransactionNature.income => 'INCOME',
        TransactionNature.transfer => 'TRANSFER',
        TransactionNature.refund => 'REFUND',
        TransactionNature.excluded => 'EXCLUDED',
        TransactionNature.unknown => 'UNKNOWN',
      };

  /// 是否为「消费」。注意退款**不是**消费：它单独作为抵扣项参与月度统计。
  bool get isExpense => this == TransactionNature.expense;

  /// 这类记录在用户确认性质后即可处理完成，不需要强加消费分类（指南 3.3）。
  bool get resolvesWithoutAllocation =>
      this == TransactionNature.income ||
      this == TransactionNature.transfer ||
      this == TransactionNature.excluded;
}

/// 整理状态。
enum ReviewStatus {
  /// 待整理。
  pending,

  /// 已稍后处理。不增加已完成数。
  deferred,

  /// 已处理完成。
  resolved;

  static ReviewStatus parse(String value) => switch (value) {
        'PENDING' => ReviewStatus.pending,
        'DEFERRED' => ReviewStatus.deferred,
        'RESOLVED' => ReviewStatus.resolved,
        _ => throw ArgumentError.value(value, 'value', '未知的整理状态'),
      };

  String get storageValue => switch (this) {
        ReviewStatus.pending => 'PENDING',
        ReviewStatus.deferred => 'DEFERRED',
        ReviewStatus.resolved => 'RESOLVED',
      };
}

/// 一条交易记录。不可变 —— 修改一律产生新实例并递增 [version]。
///
/// 金额保存为**非负绝对值**，方向由 [nature] 表达（指南 3.1）。
final class LedgerTransaction {
  const LedgerTransaction({
    required this.id,
    required this.ledgerId,
    required this.occurredAtMs,
    required this.amountCents,
    required this.merchant,
    required this.nature,
    required this.reviewStatus,
    required this.timeZone,
    this.sourceNamespace,
    this.sourceAccount,
    this.sourceTransactionId,
    this.rawTimeText,
    this.note,
    this.excludeReason,
    this.importBatchId,
    this.version = 1,
    this.currency = 'CNY',
  })  : assert(id >= idUnassigned, '交易 ID 不能为负'),
        assert(amountCents >= 0, '金额保存为非负绝对值，方向由 nature 表达'),
        assert(
          nature != TransactionNature.excluded || excludeReason != null,
          '排除统计必须保留原因（指南 3.5 / 3.3）',
        );

  /// 尚未落库的占位 ID。写入由存储层分配真实 ID。
  static const int idUnassigned = 0;

  final int id;

  final int ledgerId;

  /// 标准化交易时间（毫秒时间戳，UTC 基准）。
  final int occurredAtMs;

  /// 金额（分），非负。
  final int amountCents;

  final String merchant;

  final TransactionNature nature;

  final ReviewStatus reviewStatus;

  /// 解释 [occurredAtMs] 时采用的时区。记录选择而不是依赖设备当前时区。
  final String timeZone;

  /// 来源命名空间，例如 `wechat` / `alipay`。用于同源去重（指南 4.3）。
  final String? sourceNamespace;

  /// 来源账户标识。
  final String? sourceAccount;

  /// 来源账单里的稳定交易 ID。与 [sourceNamespace] 一起构成去重键。
  final String? sourceTransactionId;

  /// 原始时间文本，保留以便核对。
  final String? rawTimeText;

  final String? note;

  /// [TransactionNature.excluded] 时必须存在。
  final String? excludeReason;

  final int? importBatchId;

  /// 修订号。撤销与编辑时做版本校验，避免覆盖更新的数据（指南 3.3）。
  final int version;

  final String currency;

  /// 是否已经落库。
  bool get isPersisted => id != idUnassigned;

  /// 这笔记录所属的月份。由标准化时间 + 显式时区算出，不读设备当前时区。
  YearMonth get month => YearMonth.fromEpochMs(occurredAtMs, timeZone: timeZone);

  /// 数据库去重键。没有稳定来源 ID 时返回 null —— 这种情况只能算「疑似重复」，
  /// 不能凭商户/时间/金额相同就删掉一笔真实的重复消费（指南 4.3）。
  String? get dedupeKey {
    final namespace = sourceNamespace;
    final sourceId = sourceTransactionId;
    if (namespace == null || sourceId == null) return null;
    return '$namespace\u0000${sourceAccount ?? ''}\u0000$sourceId';
  }

  LedgerTransaction copyWith({
    int? id,
    int? ledgerId,
    int? occurredAtMs,
    int? amountCents,
    String? merchant,
    TransactionNature? nature,
    ReviewStatus? reviewStatus,
    String? timeZone,
    String? sourceNamespace,
    String? sourceAccount,
    String? sourceTransactionId,
    String? rawTimeText,
    String? note,
    bool clearNote = false,
    String? excludeReason,
    bool clearExcludeReason = false,
    int? importBatchId,
    int? version,
    String? currency,
  }) =>
      LedgerTransaction(
        id: id ?? this.id,
        ledgerId: ledgerId ?? this.ledgerId,
        occurredAtMs: occurredAtMs ?? this.occurredAtMs,
        amountCents: amountCents ?? this.amountCents,
        merchant: merchant ?? this.merchant,
        nature: nature ?? this.nature,
        reviewStatus: reviewStatus ?? this.reviewStatus,
        timeZone: timeZone ?? this.timeZone,
        sourceNamespace: sourceNamespace ?? this.sourceNamespace,
        sourceAccount: sourceAccount ?? this.sourceAccount,
        sourceTransactionId: sourceTransactionId ?? this.sourceTransactionId,
        rawTimeText: rawTimeText ?? this.rawTimeText,
        note: clearNote ? null : (note ?? this.note),
        excludeReason:
            clearExcludeReason ? null : (excludeReason ?? this.excludeReason),
        importBatchId: importBatchId ?? this.importBatchId,
        version: version ?? this.version,
        currency: currency ?? this.currency,
      );

  @override
  bool operator ==(Object other) =>
      other is LedgerTransaction && other.id == id && other.version == version;

  @override
  int get hashCode => Object.hash(id, version);

  @override
  String toString() =>
      'LedgerTransaction($id, $merchant, $amountCents, ${nature.name}, '
      '${reviewStatus.name}, v$version)';
}
