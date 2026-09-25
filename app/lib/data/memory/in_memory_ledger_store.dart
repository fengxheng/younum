/// 内存版账本存储。
///
/// 用途有两个，都很重要：
///
/// 1. **单元测试**。`flutter test` 跑在 Windows 的 Dart 虚拟机上，用 SQLite
///    需要一个本机并不存在的 `sqlite3.dll`。为了让业务编排（提交、撤销、稍后、
///    跨月退款）能在秒级测试里反复跑，这里提供一个行为等价的内存后端。
/// 2. **存储不可用时的兜底**。和主题偏好的处理保持一致：读不到存储不应该崩溃，
///    功能仍然可用，只是本次会话不落盘。
///
/// ⚠️ 它**不**模拟外键与唯一约束的实际强制行为（只在少数地方显式检查），
/// 所以「约束真的生效」必须由真机集成测试证明，不能靠这里的绿灯。
library;

import '../../data/seed/demo_ledger_seed.dart';
import '../../domain/models/allocation.dart';
import '../../domain/models/category.dart';
import '../../domain/models/import_records.dart';
import '../../domain/models/ledger.dart';
import '../../domain/models/ledger_dataset.dart';
import '../../domain/models/ledger_transaction.dart';
import '../../domain/models/review_session_record.dart';
import '../../domain/models/year_month.dart';
import '../../domain/repositories/ledger_store.dart';

/// 内存实现的存储。
final class InMemoryLedgerStore implements LedgerStore {
  InMemoryLedgerStore();

  final Map<int, Ledger> _ledgers = <int, Ledger>{};
  final Map<int, Category> _categories = <int, Category>{};
  final Map<int, LedgerTransaction> _transactions = <int, LedgerTransaction>{};
  final Map<int, List<Allocation>> _allocations = <int, List<Allocation>>{};
  final List<RefundLink> _refundLinks = <RefundLink>[];
  final List<RefundAllocation> _refundAllocations = <RefundAllocation>[];
  final Map<String, ReviewSessionRecord> _sessions =
      <String, ReviewSessionRecord>{};
  final Map<int, Set<YearMonth>> _coverage = <int, Set<YearMonth>>{};
  final List<UndoRecord> _actions = <UndoRecord>[];
  final Map<int, ImportBatch> _importBatches = <int, ImportBatch>{};
  final Map<int, List<ImportRow>> _importRows = <int, List<ImportRow>>{};
  final Map<int, TransactionOrigin> _origins = <int, TransactionOrigin>{};

  int _nextTransactionId = 1000;
  int _nextAllocationId = 1000;
  int _nextRefundLinkId = 1;
  int _nextActionId = 1;
  int _nextImportBatchId = 1;
  int _nextImportRowId = 1;
  int _nextOriginId = 1;

  /// 测试用：下一次写入是否应该失败，用来验证「保存失败时界面状态不变」。
  Object? failNextWrite;

  @override
  Future<void> initialize() async {
    // 幂等：重复调用不会产生重复账本或分类。
    _ledgers[DemoLedgerSeed.demoLedgerId] = DemoLedgerSeed.demoLedger();
    _ledgers[DemoLedgerSeed.realLedgerId] = DemoLedgerSeed.realLedger();
    for (final category in DemoLedgerSeed.categories()) {
      _categories[category.id] = category;
    }
    for (final transaction in DemoLedgerSeed.baselineTransactions()) {
      _transactions[transaction.id] = transaction;
    }
  }

  @override
  Future<void> clearAll() async {
    _transactions.clear();
    _allocations.clear();
    _refundLinks.clear();
    _refundAllocations.clear();
    _sessions.clear();
    _coverage.clear();
    _actions.clear();
    _importBatches.clear();
    _importRows.clear();
    _origins.clear();
    _categories.removeWhere((_, category) => !category.isBuiltin);
    await initialize();
  }

  @override
  Future<List<Ledger>> ledgers() async => _ledgers.values.toList();

  @override
  Future<List<Category>> categories({required int ledgerId}) async =>
      // 与 SQL 实现同一顺序：一级在前，然后按 sort_order、id。
      // 之前这里只按 sort_order 排，子分类会和一级分类交错，
      // 界面按这个顺序铺网格就会时对时错。
      _categories.values.toList()
        ..sort((a, b) {
          final byParent = (a.parentId ?? -1).compareTo(b.parentId ?? -1);
          if (byParent != 0) return byParent;
          final byOrder = a.sortOrder.compareTo(b.sortOrder);
          if (byOrder != 0) return byOrder;
          return a.id.compareTo(b.id);
        });

  @override
  Future<Category> saveCategory(Category category) async {
    _throwIfFailing();
    final saved = category.id == Category.idUnassigned
        ? category.copyWith(id: _nextCategoryId())
        : category;
    _categories[saved.id] = saved;
    return saved;
  }

  /// 分类没有账本维度，ID 只要在本进程内唯一即可。
  int _nextCategoryId() {
    var candidate = 1;
    for (final id in _categories.keys) {
      if (id >= candidate) candidate = id + 1;
    }
    return candidate;
  }

  @override
  Future<LedgerDataset> dataset({
    required int ledgerId,
    Set<YearMonth>? months,
  }) async {
    final selected = <LedgerTransaction>[
      for (final transaction in _transactions.values)
        if (transaction.ledgerId == ledgerId &&
            (months == null || months.contains(transaction.month)))
          transaction,
    ];

    // 只取给定月份时，还要带上「关联到这些月份消费的退款」——
    // 跨月退款要算对就必须这样取数。
    final baseIds = selected.map((transaction) => transaction.id).toSet();
    final links = months == null
        ? const <RefundLink>[]
        : <RefundLink>[
            for (final link in _refundLinks)
              if (baseIds.contains(link.originalTransactionId)) link,
          ];

    final extraTransactions = <LedgerTransaction>[
      for (final link in links)
        if (_transactions[link.refundTransactionId] case final refund?)
          if (!baseIds.contains(refund.id)) refund,
    ];

    final allTransactions = <LedgerTransaction>[
      ...selected,
      ...extraTransactions,
    ];
    final linkIds = links.map((link) => link.id).toSet();

    return LedgerDataset(
      transactions: allTransactions,
      allocations: <Allocation>[
        for (final transaction in allTransactions)
          ...?_allocations[transaction.id],
      ],
      refundLinks: links,
      refundAllocations: <RefundAllocation>[
        for (final refundAllocation in _refundAllocations)
          if (linkIds.contains(refundAllocation.refundLinkId)) refundAllocation,
      ],
      categories: _categories.values.toList(),
    );
  }

  /// 记录一条退款关联。
  ///
  /// 同一笔退款只能关联一次 —— 与数据库的唯一约束行为一致。
  @override
  Future<Map<String, int>> transactionIdsByDedupeKey({
    required int ledgerId,
    required List<String> dedupeKeys,
  }) async {
    final wanted = dedupeKeys.toSet();
    final found = <String, int>{};
    for (final transaction in _transactions.values) {
      if (transaction.ledgerId != ledgerId) continue;
      final key = transaction.dedupeKey;
      if (key == null || !wanted.contains(key)) continue;
      found[key] = transaction.id;
    }
    return found;
  }

  @override
  Future<int> insertRefundLink({
    required int refundTransactionId,
    required int originalTransactionId,
    required int amountCents,
    List<RefundAllocationDraft> allocations = const <RefundAllocationDraft>[],
  }) async {
    _throwIfFailing();
    for (final existing in _refundLinks) {
      if (existing.refundTransactionId == refundTransactionId) {
        throw StateError('这笔退款已经关联过一笔消费，不能重复关联');
      }
    }
    final link = RefundLink(
      id: _nextRefundLinkId++,
      refundTransactionId: refundTransactionId,
      originalTransactionId: originalTransactionId,
      amountCents: amountCents,
    );
    _refundLinks.add(link);
    for (final draft in allocations) {
      _refundAllocations.add(
        RefundAllocation(
          id: _refundAllocations.length + 1,
          refundLinkId: link.id,
          originalAllocationId: draft.originalAllocationId,
          amountCents: draft.amountCents,
        ),
      );
    }
    return link.id;
  }

  @override
  Future<LedgerTransaction?> transactionById(int transactionId) async =>
      _transactions[transactionId];

  @override
  Future<RefundLink?> refundLinkOf(int refundTransactionId) async =>
      _linkOf(refundTransactionId);

  @override
  Future<bool> unlinkRefund({
    required int refundTransactionId,
    required ReviewSessionRecord session,
  }) async {
    _throwIfFailing();
    if (!_unlinkRefundInPlace(refundTransactionId)) return false;
    _sessions[_sessionKey(session.ledgerId, session.month)] = session;
    return true;
  }

  RefundLink? _linkOf(int refundTransactionId) {
    for (final link in _refundLinks) {
      if (link.refundTransactionId == refundTransactionId) return link;
    }
    return null;
  }

  /// 解除关联，不管会话 —— 调用方决定要不要存会话。
  ///
  /// 撤回导入（指南 3.5.7）与用户主动解除走的就是同一段：
  /// 删连接、删挂在连接上的退款分配、退款回到「不知道这是什么」。
  bool _unlinkRefundInPlace(int refundTransactionId) {
    final link = _linkOf(refundTransactionId);
    if (link == null) return false;

    _refundLinks.removeWhere((item) => item.id == link.id);
    // 退款分配是挂在连接上的附属物，连接没了它就无所指。
    _refundAllocations.removeWhere((item) => item.refundLinkId == link.id);

    final current = _transactions[refundTransactionId];
    if (current != null) {
      // 回到「不知道这是什么」：性质是导入时猜的，链接是用户后来加的，
      // 两个都撒掉，剩下的交给下一次整理。
      _transactions[refundTransactionId] = current.copyWith(
        nature: TransactionNature.unknown,
        reviewStatus: ReviewStatus.pending,
        clearExcludeReason: true,
        version: current.version + 1,
      );
    }
    return true;
  }

  @override
  Future<int> insertTransaction(LedgerTransaction transaction) async {
    final key = transaction.dedupeKey;
    if (key != null) {
      for (final existing in _transactions.values) {
        if (existing.ledgerId == transaction.ledgerId &&
            existing.dedupeKey == key) {
          throw StateError('同一来源的同一笔交易已经存在，不能重复写入：$key');
        }
      }
    }
    final id = transaction.id != LedgerTransaction.idUnassigned
        ? transaction.id
        : _nextTransactionId++;
    _transactions[id] = transaction.copyWith(id: id);
    return id;
  }

  @override
  Future<bool> updateTransaction({
    required LedgerTransaction transaction,
    required int expectedVersion,
  }) async {
    _throwIfFailing();
    final current = _transactions[transaction.id];
    if (current == null || current.version != expectedVersion) return false;
    _transactions[transaction.id] = transaction.copyWith(
      version: expectedVersion + 1,
    );
    return true;
  }

  @override
  Future<ReviewSessionRecord?> loadReviewSession({
    required int ledgerId,
    required YearMonth month,
  }) async => _sessions[_sessionKey(ledgerId, month)];

  @override
  Future<void> saveReviewSession({required ReviewSessionRecord record}) async {
    _throwIfFailing();
    _sessions[_sessionKey(record.ledgerId, record.month)] = record;
  }

  @override
  Future<bool> coverageConfirmed({
    required int ledgerId,
    required YearMonth month,
  }) async => _coverage[ledgerId]?.contains(month) ?? false;

  @override
  Future<Set<YearMonth>> confirmedMonths({required int ledgerId}) async =>
      Set<YearMonth>.unmodifiable(_coverage[ledgerId] ?? const <YearMonth>{});

  @override
  Future<void> setCoverageConfirmed({
    required int ledgerId,
    required YearMonth month,
    required bool value,
  }) async {
    _throwIfFailing();
    final months = _coverage[ledgerId] ??= <YearMonth>{};
    if (value) {
      months.add(month);
    } else {
      months.remove(month);
    }
  }

  @override
  Future<bool> resolveTransaction({
    required LedgerTransaction before,
    required List<AllocationDraft> items,
    required ReviewSessionRecord session,
    required UndoRecord undo,
  }) async {
    _throwIfFailing();
    final current = _transactions[before.id];
    if (current == null || current.version != before.version) return false;

    _transactions[before.id] = current.copyWith(
      reviewStatus: ReviewStatus.resolved,
      version: current.version + 1,
    );
    _allocations[before.id] = <Allocation>[
      for (final item in items)
        Allocation(
          id: _nextAllocationId++,
          transactionId: before.id,
          categoryId: item.categoryId,
          amountCents: item.amountCents,
        ),
    ];
    _sessions[_sessionKey(session.ledgerId, session.month)] = session;
    _actions.add(undo.copyWith(id: _nextActionId++));
    return true;
  }

  @override
  Future<bool> deferTransaction({
    required LedgerTransaction before,
    required ReviewSessionRecord session,
    required UndoRecord undo,
  }) async {
    _throwIfFailing();
    final current = _transactions[before.id];
    if (current == null || current.version != before.version) return false;

    _transactions[before.id] = current.copyWith(
      reviewStatus: ReviewStatus.deferred,
      version: current.version + 1,
    );
    _sessions[_sessionKey(session.ledgerId, session.month)] = session;
    _actions.add(undo.copyWith(id: _nextActionId++));
    return true;
  }

  @override
  Future<bool> linkRefundAndResolve({
    required LedgerTransaction before,
    required int originalTransactionId,
    required int amountCents,
    required ReviewSessionRecord session,
  }) async {
    _throwIfFailing();
    final current = _transactions[before.id];
    if (current == null || current.version != before.version) return false;
    if (_transactions[originalTransactionId] == null) {
      throw StateError('找不到要关联的原消费');
    }
    for (final existing in _refundLinks) {
      if (existing.refundTransactionId == before.id) {
        throw StateError('这笔退款已经关联过一笔消费，不能重复关联');
      }
    }

    // 已经是退款了，旧的原因与分配都不该留着。
    _transactions[before.id] = current.copyWith(
      nature: TransactionNature.refund,
      reviewStatus: ReviewStatus.resolved,
      clearExcludeReason: true,
      version: current.version + 1,
    );
    _allocations.remove(before.id);
    _refundLinks.add(
      RefundLink(
        id: _nextRefundLinkId++,
        refundTransactionId: before.id,
        originalTransactionId: originalTransactionId,
        amountCents: amountCents,
      ),
    );
    _sessions[_sessionKey(session.ledgerId, session.month)] = session;
    return true;
  }

  @override
  Future<bool> saveDetails({
    required LedgerTransaction before,
    required String? note,
    required List<AllocationDraft>? items,
    required ReviewSessionRecord session,
    required UndoRecord undo,
  }) async {
    _throwIfFailing();
    final current = _transactions[before.id];
    if (current == null || current.version != before.version) return false;

    _transactions[before.id] = current.copyWith(
      note: note,
      // 备注被删空时要真的清掉，而不是留着上一版。
      clearNote: note == null,
      reviewStatus: items == null ? null : ReviewStatus.resolved,
      version: current.version + 1,
    );
    if (items != null) {
      _allocations[before.id] = <Allocation>[
        for (final item in items)
          Allocation(
            id: _nextAllocationId++,
            transactionId: before.id,
            categoryId: item.categoryId,
            amountCents: item.amountCents,
          ),
      ];
    }
    _sessions[_sessionKey(session.ledgerId, session.month)] = session;
    _actions.add(undo.copyWith(id: _nextActionId++));
    return true;
  }

  @override
  Future<bool> setTransactionNature({
    required LedgerTransaction before,
    required TransactionNature nature,
    required String? excludeReason,
    required ReviewSessionRecord session,
    required UndoRecord undo,
  }) async {
    _throwIfFailing();
    final current = _transactions[before.id];
    if (current == null || current.version != before.version) return false;

    _transactions[before.id] = current.copyWith(
      nature: nature,
      excludeReason: excludeReason,
      // 从「排除统计」改成别人时，旧原因必须真的清掉，而不是留着。
      clearExcludeReason: excludeReason == null,
      reviewStatus: ReviewStatus.resolved,
      version: current.version + 1,
    );
    if (!nature.isExpense) _allocations.remove(before.id);
    _sessions[_sessionKey(session.ledgerId, session.month)] = session;
    _actions.add(undo.copyWith(id: _nextActionId++));
    return true;
  }

  @override
  Future<void> saveSessionWithUndo({
    required ReviewSessionRecord session,
    required UndoRecord undo,
  }) async {
    _throwIfFailing();
    _sessions[_sessionKey(session.ledgerId, session.month)] = session;
    _actions.add(undo.copyWith(id: _nextActionId++));
  }

  @override
  Future<bool> reopenDeferred({
    required List<LedgerTransaction> transactions,
    required ReviewSessionRecord session,
    required UndoRecord undo,
  }) async {
    _throwIfFailing();
    for (final transaction in transactions) {
      final current = _transactions[transaction.id];
      if (current == null || current.version != transaction.version) {
        return false;
      }
      _transactions[transaction.id] = current.copyWith(
        reviewStatus: ReviewStatus.pending,
        version: current.version + 1,
      );
    }
    _sessions[_sessionKey(session.ledgerId, session.month)] = session;
    _actions.add(undo.copyWith(id: _nextActionId++));
    return true;
  }

  @override
  Future<UndoRecord?> latestAvailableAction({
    required int ledgerId,
    required YearMonth month,
  }) async {
    for (final action in _actions.reversed) {
      if (action.state != ReviewActionState.available) continue;
      if (action.ledgerId != ledgerId || action.month != month) continue;
      return action;
    }
    return null;
  }

  @override
  Future<bool> applyUndo({
    required UndoRecord action,
    required ReviewSessionRecord session,
  }) async {
    _throwIfFailing();

    // 先把所有目标校验完再写：任一版本对不上就整体不动，
    // 等价于 SQL 实现里事务回滚的效果。
    final restored = <int, LedgerTransaction>{};
    for (final target in action.targets) {
      final current = _transactions[target.transactionId];
      if (current == null) return false;
      // 操作之后又被改过 —— 不能覆盖新数据（指南 3.3）。
      if (current.version != target.afterVersion) return false;
      restored[target.transactionId] = current.copyWith(
        reviewStatus: target.beforeStatus,
        nature: target.beforeNature,
        // 原因与备注要跟着性质一起还原：只改性质会留下一条对不上的说明。
        excludeReason: target.beforeExcludeReason,
        clearExcludeReason: target.beforeExcludeReason == null,
        note: target.beforeNote,
        clearNote: target.beforeNote == null,
        version: target.beforeVersion + 1,
      );
    }

    for (final entry in restored.entries) {
      _transactions[entry.key] = entry.value;
      _allocations.remove(entry.key);
    }
    for (final target in action.targets) {
      if (target.beforeAllocations.isEmpty) continue;
      _allocations[target.transactionId] = <Allocation>[
        for (final draft in target.beforeAllocations)
          Allocation(
            id: _nextAllocationId++,
            transactionId: target.transactionId,
            categoryId: draft.categoryId,
            amountCents: draft.amountCents,
          ),
      ];
    }

    final index = _actions.indexWhere((candidate) => candidate.id == action.id);
    if (index >= 0) {
      _actions[index] = _actions[index].copyWith(state: ReviewActionState.used);
    }
    _sessions[_sessionKey(session.ledgerId, session.month)] = session;
    return true;
  }

  @override
  Future<void> invalidateAction(int actionId) async {
    final index = _actions.indexWhere((candidate) => candidate.id == actionId);
    if (index >= 0) {
      _actions[index] = _actions[index].copyWith(
        state: ReviewActionState.invalidated,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // 导入
  // ---------------------------------------------------------------------------

  @override
  Future<int> insertImportBatch({
    required ImportBatch batch,
    required List<ImportRow> rows,
  }) async {
    _throwIfFailing();
    final id = batch.id == ImportBatch.idUnassigned
        ? _nextImportBatchId++
        : batch.id;
    _importBatches[id] = batch.copyWith(id: id);
    _importRows[id] = <ImportRow>[
      for (var index = 0; index < rows.length; index++)
        _withRowId(rows[index], batchId: id, id: _nextImportRowId++),
    ];
    return id;
  }

  @override
  Future<void> updateImportBatch(ImportBatch batch) async {
    _throwIfFailing();
    _importBatches[batch.id] = batch;
  }

  @override
  Future<void> deleteImportBatch(int batchId) async {
    _throwIfFailing();
    final batch = _importBatches[batchId];
    if (batch != null && batch.stage.isCommitted && !batch.isReverted) {
      // 提交过的批次不能这样删掉：它背后的交易会失去来源记录，
      // 撤回时就再也判断不出「还有没有别处引用」了。
      // 但**已撤回**的批次名下已经没有交易，可以放心删。
      throw StateError('已提交的批次不能直接删除，请先撤回');
    }
    _importBatches.remove(batchId);
    _importRows.remove(batchId);
    _origins.removeWhere((_, origin) => origin.batchId == batchId);
  }

  @override
  Future<List<ImportBatch>> importBatches({required int ledgerId}) async {
    final batches =
        _importBatches.values
            .where((batch) => batch.ledgerId == ledgerId)
            .toList()
          ..sort((a, b) => b.id.compareTo(a.id));
    return batches;
  }

  @override
  Future<List<ImportRow>> importRows({required int batchId}) async {
    final rows = List<ImportRow>.of(_importRows[batchId] ?? const <ImportRow>[])
      ..sort((a, b) => a.rowNumber.compareTo(b.rowNumber));
    return rows;
  }

  @override
  Future<void> updateImportRows(List<ImportRow> rows) async {
    _throwIfFailing();
    for (final row in rows) {
      final list = _importRows[row.batchId];
      if (list == null) continue;
      final index = list.indexWhere((candidate) => candidate.id == row.id);
      if (index >= 0) list[index] = row;
    }
  }

  @override
  Future<List<int>> commitImport({
    required int batchId,
    required List<({ImportRow row, LedgerTransaction transaction})> entries,
    required int nowMs,
    required int totalRows,
    required int duplicateCount,
    required int invalidCount,
    required int amountCents,
  }) async {
    _throwIfFailing();
    final batch = _importBatches[batchId];
    if (batch == null) throw StateError('批次 $batchId 不存在');
    if (batch.stage.isCommitted && !batch.isReverted) {
      // 幂等：重复提交不能再写一遍交易，否则首页金额直接翻倍。
      // 但**已撤回**的批次可以再提交一次 —— 那是用户主动把导入退回去后
      // 又想装回来的情况，不该被当成重复提交。
      throw StateError('批次 $batchId 已经提交过');
    }

    final written = <int>[];
    // 内存实现里也先攒好再一次性落地，语义与真机的单事务保持一致。
    for (final entry in entries) {
      // 库里已经有这笔（同源键命中）时只新增来源绑定。
      final int id;
      if (entry.transaction.isPersisted) {
        id = entry.transaction.id;
      } else {
        id = _nextTransactionId++;
        _transactions[id] = entry.transaction.copyWith(
          id: id,
          importBatchId: batchId,
        );
      }
      _origins[_nextOriginId++] = TransactionOrigin(
        id: _nextOriginId - 1,
        transactionId: id,
        batchId: batchId,
        rowNumber: entry.row.rowNumber,
      );
      written.add(id);

      final staged = _importRows[batchId];
      if (staged != null) {
        final index = staged.indexWhere(
          (candidate) => candidate.id == entry.row.id,
        );
        if (index >= 0) {
          staged[index] = staged[index].copyWith(
            status: ImportRowStatus.imported,
            transactionId: id,
          );
        }
      }
    }

    _importBatches[batchId] = batch.copyWith(
      stage: ImportStage.committed,
      committedAtMs: nowMs,
      clearRevertedAt: true,
      totalRows: totalRows,
      newCount: written.length,
      duplicateCount: duplicateCount,
      invalidCount: invalidCount,
      amountCents: amountCents,
    );
    return written;
  }

  @override
  Future<ImportRevert> revertImport({
    required int batchId,
    required int nowMs,
    bool dryRun = false,
  }) async {
    _throwIfFailing();
    final batch = _importBatches[batchId];
    if (batch == null) throw StateError('批次 $batchId 不存在');

    final referenced = <int>{
      for (final origin in _origins.values)
        if (origin.batchId == batchId) origin.transactionId,
    };

    final deleted = <int>[];
    final shared = <int>[];
    final edited = <int>[];
    final unlinked = <int>[];
    for (final transactionId in referenced) {
      final others = _origins.values.where(
        (origin) =>
            origin.transactionId == transactionId && origin.batchId != batchId,
      );
      if (others.isNotEmpty) {
        shared.add(transactionId);
        continue;
      }
      final transaction = _transactions[transactionId];
      final touched =
          (_allocations[transactionId]?.isNotEmpty ?? false) ||
          (transaction != null &&
              (transaction.version > 1 ||
                  transaction.reviewStatus != ReviewStatus.pending));
      if (touched) {
        edited.add(transactionId);
        continue;
      }
      deleted.add(transactionId);

      // 指南 3.5.7：原消费要删掉，但不要连带删掉它的退款 ——
      // 退款可能是另一份账单导进来的，解除关联让它回到待核对就行。
      final linkedRefunds = <int>[
        for (final link in _refundLinks)
          if (link.originalTransactionId == transactionId)
            link.refundTransactionId,
      ];
      unlinked.addAll(linkedRefunds);
      if (dryRun) continue;

      for (final refundId in linkedRefunds) {
        _unlinkRefundInPlace(refundId);
      }
      _transactions.remove(transactionId);
      _allocations.remove(transactionId);
    }

    // dry run 到此为止：只回答「会发生什么」，不改任何东西。
    if (dryRun) {
      return ImportRevert(
        deletedTransactionIds: deleted,
        sharedTransactionIds: shared,
        editedTransactionIds: edited,
        unlinkedRefundIds: unlinked,
      );
    }

    _origins.removeWhere((_, origin) => origin.batchId == batchId);
    final staged = _importRows[batchId];
    if (staged != null) {
      for (var index = 0; index < staged.length; index++) {
        if (staged[index].status != ImportRowStatus.imported) continue;
        staged[index] = staged[index].copyWith(
          status: ImportRowStatus.newRow,
          clearTransactionId: true,
        );
      }
    }
    _importBatches[batchId] = batch.copyWith(revertedAtMs: nowMs);
    return ImportRevert(
      deletedTransactionIds: deleted,
      sharedTransactionIds: shared,
      editedTransactionIds: edited,
      unlinkedRefundIds: unlinked,
    );
  }

  ImportRow _withRowId(
    ImportRow row, {
    required int batchId,
    required int id,
  }) => ImportRow(
    id: id,
    batchId: batchId,
    rowNumber: row.rowNumber,
    status: row.status,
    rawText: row.rawText,
    occurredAtMs: row.occurredAtMs,
    amountCents: row.amountCents,
    direction: row.direction,
    merchant: row.merchant,
    issue: row.issue,
    dedupeKey: row.dedupeKey,
    included: row.included,
    transactionId: row.transactionId,
  );

  static String _sessionKey(int ledgerId, YearMonth month) =>
      '$ledgerId:${month.toIso()}';

  void _throwIfFailing() {
    final failure = failNextWrite;
    if (failure != null) {
      failNextWrite = null;
      throw failure;
    }
  }
}
