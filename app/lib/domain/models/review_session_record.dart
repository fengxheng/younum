/// 整理会话的持久化记录。
///
/// 指南 3.2 要求 `ReviewSession` 保存「账本 / 月、稳定队列顺序、当前交易 ID、
/// 排序方式、最近保存时间」，`ReviewAction` 保存「操作前快照、操作后版本、
/// 撤销状态」。
///
/// 这里把它们建模成不依赖数据库的值对象，这样同一套编排逻辑可以跑在
/// 内存存储（单元测试）和 SQLite（真机）两套后端上。
library;

import '../models/allocation.dart';
import '../models/ledger_transaction.dart';
import '../models/year_month.dart';

/// 记录在哪个队列里。
enum ReviewBucket {
  /// 主队列，等待整理。
  main,

  /// 稍后队列。
  deferred;

  static ReviewBucket parse(String value) => switch (value) {
        'MAIN' => ReviewBucket.main,
        'DEFERRED' => ReviewBucket.deferred,
        _ => throw ArgumentError.value(value, 'value', '未知的队列'),
      };

  String get storageValue => switch (this) {
        ReviewBucket.main => 'MAIN',
        ReviewBucket.deferred => 'DEFERRED',
      };
}

/// 队列里的一项。
final class ReviewQueueEntry {
  const ReviewQueueEntry({required this.transactionId, required this.bucket});

  final int transactionId;
  final ReviewBucket bucket;

  @override
  bool operator ==(Object other) =>
      other is ReviewQueueEntry &&
      other.transactionId == transactionId &&
      other.bucket == bucket;

  @override
  int get hashCode => Object.hash(transactionId, bucket);

  @override
  String toString() =>
      'ReviewQueueEntry(${bucket.storageValue}:$transactionId)';
}

/// 整理会话的持久化状态。
final class ReviewSessionRecord {
  const ReviewSessionRecord({
    required this.ledgerId,
    required this.month,
    required this.entries,
    required this.updatedAtMs,
    this.currentTransactionId,
    this.sortMode = sortByTimeDescending,
    this.id,
  });

  /// 默认排序：按交易时间倒序。
  ///
  /// 这是**初始**顺序。用户稍后处理过的记录会排到主队列末尾，
  /// 那个顺序由 [entries] 显式保存，不再依赖排序方式重算。
  static const String sortByTimeDescending = 'TIME_DESC';

  /// 数据库主键。新会话为 null。
  final int? id;

  final int ledgerId;

  final YearMonth month;

  /// 队列顺序。[entries] 的下标即位置。
  final List<ReviewQueueEntry> entries;

  final int updatedAtMs;

  final int? currentTransactionId;

  final String sortMode;

  List<int> get mainQueue => <int>[
        for (final entry in entries)
          if (entry.bucket == ReviewBucket.main) entry.transactionId,
      ];

  List<int> get deferredQueue => <int>[
        for (final entry in entries)
          if (entry.bucket == ReviewBucket.deferred) entry.transactionId,
      ];

  ReviewSessionRecord copyWith({
    int? id,
    List<ReviewQueueEntry>? entries,
    int? updatedAtMs,
    int? currentTransactionId,
    bool clearCurrent = false,
    String? sortMode,
  }) =>
      ReviewSessionRecord(
        id: id ?? this.id,
        ledgerId: ledgerId,
        month: month,
        entries: entries ?? this.entries,
        updatedAtMs: updatedAtMs ?? this.updatedAtMs,
        currentTransactionId:
            clearCurrent ? null : (currentTransactionId ?? this.currentTransactionId),
        sortMode: sortMode ?? this.sortMode,
      );

  @override
  String toString() =>
      'ReviewSessionRecord($ledgerId, $month, ${entries.length} 项)';
}

/// 操作类型。
enum ReviewActionType {
  /// 确认归类。
  resolve,

  /// 稍后处理。
  defer,

  /// 把稍后队列放回主队列。
  reopenDeferred;

  static ReviewActionType parse(String value) => switch (value) {
        'RESOLVE' => ReviewActionType.resolve,
        'DEFER' => ReviewActionType.defer,
        'REOPEN_DEFERRED' => ReviewActionType.reopenDeferred,
        _ => throw ArgumentError.value(value, 'value', '未知的操作类型'),
      };

  String get storageValue => switch (this) {
        ReviewActionType.resolve => 'RESOLVE',
        ReviewActionType.defer => 'DEFER',
        ReviewActionType.reopenDeferred => 'REOPEN_DEFERRED',
      };
}

/// 撤销状态。
enum ReviewActionState {
  /// 可以撤销。
  available,

  /// 已经撤销过。
  used,

  /// 因为交易被后续修改而失效。
  invalidated;

  static ReviewActionState parse(String value) => switch (value) {
        'AVAILABLE' => ReviewActionState.available,
        'USED' => ReviewActionState.used,
        'INVALIDATED' => ReviewActionState.invalidated,
        _ => throw ArgumentError.value(value, 'value', '未知的撤销状态'),
      };

  String get storageValue => switch (this) {
        ReviewActionState.available => 'AVAILABLE',
        ReviewActionState.used => 'USED',
        ReviewActionState.invalidated => 'INVALIDATED',
      };
}

/// 一次操作**前**的单笔状态。
///
/// 撤销要能恢复，就必须把「操作前长什么样」记下来。大多数操作只影响一笔
/// （确认、稍后），但「重新整理稍后队列」会同时把若干笔从 `DEFERRED` 改回
/// `PENDING`，所以这里是列表。
final class UndoTarget {
  const UndoTarget({
    required this.transactionId,
    required this.beforeVersion,
    required this.beforeStatus,
    required this.beforeNature,
    this.beforeExcludeReason,
    this.beforeNote,
    this.beforeAllocations = const <AllocationDraft>[],
  });

  final int transactionId;

  /// 操作前的版本号。
  final int beforeVersion;

  final ReviewStatus beforeStatus;

  final TransactionNature beforeNature;

  /// 操作前的「排除统计原因」。
  ///
  /// 必须存下来：撤销时如果只还原性质不还原原因，库里就会留下一条
  /// 「性质是转账、却写着一句为什么不计入统计」的记录 ——
  /// 以后回看时没人知道那句话还算不算数。（真机测试拓到的。）
  final String? beforeExcludeReason;

  /// 操作前的备注。
  ///
  /// 同理：备注是用户手写的，撤销必须把它还原回去，
  /// 不能让「撤销」把备注抹掉。
  final String? beforeNote;

  /// 操作前的分配。首次归类时为空。
  final List<AllocationDraft> beforeAllocations;

  /// 操作后的版本号。
  ///
  /// 约定：**每次操作把受影响交易的版本号加一**。撤销时用
  /// 「当前版本 == 操作后版本」做乐观校验，版本对不上说明这笔在操作之后
  /// 又被别处改过，不能覆盖（指南 3.3）。
  int get afterVersion => beforeVersion + 1;

  @override
  String toString() => 'UndoTarget($transactionId, v$beforeVersion)';
}

/// 一次操作的「操作前快照」，用于撤销。
final class UndoRecord {
  const UndoRecord({
    required this.type,
    required this.label,
    required this.ledgerId,
    required this.month,
    required this.targets,
    required this.beforeEntries,
    required this.createdAtMs,
    this.id,
    this.state = ReviewActionState.available,
  });

  final int? id;

  final ReviewActionType type;

  /// 给用户看的描述，例如「确认 MANNER COFFEE」。
  final String label;

  /// 所属账本。撤销只在同一会话内进行。
  final int ledgerId;

  /// 所属月份。
  final YearMonth month;

  /// 本次操作影响到的交易。
  final List<UndoTarget> targets;

  /// 操作前的会话顺序。
  final List<ReviewQueueEntry> beforeEntries;

  final int createdAtMs;

  final ReviewActionState state;

  UndoRecord copyWith({int? id, ReviewActionState? state}) => UndoRecord(
        id: id ?? this.id,
        type: type,
        label: label,
        ledgerId: ledgerId,
        month: month,
        targets: targets,
        beforeEntries: beforeEntries,
        createdAtMs: createdAtMs,
        state: state ?? this.state,
      );

  @override
  String toString() => 'UndoRecord($label, ${state.storageValue})';
}
