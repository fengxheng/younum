/// 账本仓库：业务编排的唯一入口。
///
/// 分层与实现指南 2.2 一致：界面 → 仓库 → 存储。
/// 仓库负责**事务边界与业务规则**，存储只负责读写行；规则函数在
/// `lib/domain/rules/` 里，界面与仓库共用同一份实现，因此
/// 「单元测试里验证的公式」和「界面上跑出来的数字」不会分叉。
library;

import 'dart:typed_data';

import '../models/allocation.dart';
import '../models/import_records.dart';
import '../models/category.dart';
import '../models/category_icon_asset.dart';
import '../models/ledger.dart';
import '../models/ledger_dataset.dart';
import '../models/ledger_transaction.dart';
import '../models/review_session_record.dart';
import '../models/year_month.dart';
import '../rules/allocation_rules.dart';
import '../rules/category_rules.dart';
import '../rules/icon_asset_rules.dart';
import '../rules/month_insights.dart';
import '../rules/month_overview.dart';
import '../rules/refund_rules.dart';
import 'icon_asset_ports.dart';
import 'ledger_store.dart';

/// 一次整理会话的完整快照：队列 + 本月概况。
///
/// 界面只需要这一个对象就能画出整理页与首页，不必分别去查三次。
final class ReviewSnapshot {
  const ReviewSnapshot({
    required this.record,
    required this.dataset,
    required this.isDemoLedger,
    required this.coverageConfirmed,
    required this.lastActionLabel,
  });

  final ReviewSessionRecord record;

  /// 本月数据集（含跨月引用到本月的退款）。
  final LedgerDataset dataset;

  final bool isDemoLedger;

  final bool coverageConfirmed;

  /// 最近一次可撤销操作的描述，用于按钮朗读。
  final String? lastActionLabel;

  /// 主队列，按持久化的稳定顺序。
  List<LedgerTransaction> get mainQueue => _resolve(record.mainQueue);

  /// 稍后队列。
  List<LedgerTransaction> get deferred => _resolve(record.deferredQueue);

  LedgerTransaction? get current {
    final queue = mainQueue;
    return queue.isEmpty ? null : queue.first;
  }

  bool get canUndo => lastActionLabel != null;

  /// 已完成整理的笔数（指南 3.3：跳过不计完成数）。
  int get resolvedCount => dataset.transactions
      .where(
        (transaction) =>
            transaction.month == record.month &&
            transaction.reviewStatus == ReviewStatus.resolved,
      )
      .length;

  int get totalCount => resolvedCount + mainQueue.length + deferred.length;

  double get progress => totalCount == 0 ? 0 : resolvedCount / totalCount;

  /// 本月金额与分类概况。
  MonthOverview get overview => MonthOverview.compute(
    month: record.month,
    dataset: dataset,
    coverageConfirmed: coverageConfirmed,
    isDemoLedger: isDemoLedger,
  );

  /// 把队列里的 ID 还原成交易对象。
  ///
  /// 找不到的记录直接跳过：宁可少一张卡片，也不能整页崩掉。
  List<LedgerTransaction> _resolve(List<int> ids) => <LedgerTransaction>[
    for (final id in ids) ?dataset.transaction(id),
  ];

  @override
  String toString() =>
      'ReviewSnapshot(${record.month}, $resolvedCount/$totalCount)';
}

/// 整理操作的结果。
sealed class ReviewOutcome {
  const ReviewOutcome();
}

/// 成功。
final class ReviewSucceeded extends ReviewOutcome {
  const ReviewSucceeded(this.snapshot);

  final ReviewSnapshot snapshot;
}

/// 被业务规则拒绝（例如未选分类）。
final class ReviewRejected extends ReviewOutcome {
  const ReviewRejected(this.message);

  final String message;
}

/// 版本冲突：目标记录在操作之后又被改过，不能覆盖新数据。
final class ReviewConflict extends ReviewOutcome {
  const ReviewConflict(this.message);

  final String message;
}

/// 存储失败。用户输入必须保留，界面不能假装成功。
final class ReviewFailed extends ReviewOutcome {
  const ReviewFailed(this.error);

  final Object error;
}

/// 分类写操作的结果。
///
/// 不复用 [ReviewOutcome]：那一套带的是「整理会话快照」，而分类改动
/// 与队列、月报都无关，硬塞进去只会让两边都别扭。
sealed class CategoryWriteResult {
  const CategoryWriteResult();
}

/// 保存成功，带回落库后的分类。
final class CategorySaved extends CategoryWriteResult {
  const CategorySaved(this.category);

  final Category category;
}

/// 被规则拒绝或保存失败，[message] 直接给用户看。
final class CategoryRejected extends CategoryWriteResult {
  const CategoryRejected(this.message);

  final String message;
}

/// 分类合并的结果。
///
/// 不复用 [CategoryWriteResult]：合并不只是「保存了一下」——
/// 它**改了真实账目的用途**，还把源分类归档了。只说一句「保存成功」
/// 会让用户不知道到底动了什么，所以把「多少笔」单独报回来。
sealed class CategoryMergeResult {
  const CategoryMergeResult();
}

/// 合并成功。
final class CategoryMerged extends CategoryMergeResult {
  const CategoryMerged({
    required this.movedTransactions,
    required this.sourceName,
    required this.targetName,
  });

  /// 有多少笔账换了用途。
  final int movedTransactions;

  /// 源分类名（已经归档）。
  final String sourceName;

  /// 目标分类名。
  final String targetName;
}

/// 被规则拒绝或中途失败，[message] 直接给用户看。
final class CategoryMergeRejected extends CategoryMergeResult {
  const CategoryMergeRejected(this.message);

  final String message;
}

/// 账本仓库。
final class LedgerRepository {
  LedgerRepository(
    this._store, {
    DateTime Function()? clock,
    IconThumbnailMaker? thumbnails,
    IconAssetStore? iconFiles,
  }) : _clock = clock ?? DateTime.now,
       _thumbnails = thumbnails ?? const UnsupportedThumbnailMaker(),
       _iconFiles = iconFiles ?? const UnsupportedIconAssetStore();

  final LedgerStore _store;
  final DateTime Function() _clock;

  /// 图片处理与文件夹。桌面/单测环境给的是「不支持」的实现，
  /// 仓库层会先问能不能用，再决定要不要接这个能力。
  final IconThumbnailMaker _thumbnails;
  final IconAssetStore _iconFiles;

  /// 图片文件夹（界面渲染需要把相对路径换成绝对路径）。
  IconAssetStore get iconFiles => _iconFiles;

  /// 全部图片资源。
  Future<List<CategoryIconAsset>> iconAssets() => _store.iconAssets();

  /// 把一张图做成缩略图，**不落盘**。
  ///
  /// 给编辑器的草稿预览用（指南 14.3：选中图片只改草稿，按保存才提交）：
  /// 失败时什么都不改，用户手上的旧草稿也不受影响。
  Future<IconThumbnailResult> prepareImage(Uint8List bytes) =>
      _thumbnails.thumbnail(bytes);

  LedgerStore get store => _store;

  /// 建表并写入初始账本与分类。幂等。
  Future<void> initialize() => _store.initialize();

  /// 按「真实 / 演示」取账本。
  Future<Ledger> ledgerFor({required bool isDemo}) async {
    final ledgers = await _store.ledgers();
    for (final ledger in ledgers) {
      if (ledger.isDemo == isDemo) return ledger;
    }
    throw StateError('账本未初始化：isDemo=$isDemo');
  }

  Future<List<Category>> categories({required int ledgerId}) =>
      _store.categories(ledgerId: ledgerId);

  /// 打开应用时应该先看哪个月。
  ///
  /// 规则：**有记录就取最新记录所在的月份**，没有记录就用当前自然月。
  ///
  /// 为什么不是「永远用当前月」：演示账本里的样例账单固定在 2026 年 9 月，
  /// 如果按设备当前月份去查，下个月打开演示账本就会变成一片空白，
  /// 看起来像数据丢了。按数据本身选月份对两种情况都成立。
  Future<YearMonth> preferredMonth({required int ledgerId}) async =>
      (await preferredMonthState(ledgerId: ledgerId)).month;

  /// 同 [preferredMonth]，并告知这本账本里**到底有没有记录**。
  ///
  /// 首页要在「没有账单」与「有账单」两种形态之间切换，这个判断不能靠
  /// 「是不是演示账本」近似 —— 真实账本导入之前确实一笔都没有。
  Future<({YearMonth month, bool hasRecords})> preferredMonthState({
    required int ledgerId,
  }) async {
    final dataset = await _store.dataset(ledgerId: ledgerId);
    YearMonth? newest;
    for (final transaction in dataset.transactions) {
      final month = transaction.month;
      if (newest == null || month > newest) newest = month;
    }
    return (
      month: newest ?? YearMonth.fromDateTime(_clock()),
      hasRecords: dataset.transactions.isNotEmpty,
    );
  }

  /// 清空账本数据（「清除本地数据」用），并重新写入初始的演示账单。
  ///
  /// 保留主题偏好与引导状态（指南 8.3）。
  Future<void> clearAllData() async {
    await _store.clearAll();
    // 分类图片是**文件**，不在数据库里：只清表会留下孤儿文件，
    // 而「清除本地数据」的承诺是把它们一起清掉（指南 8.3）。
    // 文件都放在应用私有目录下的 category_icons，清空即可，不需要逐个删。
    await _iconFiles.clearAll();
  }

  /// 启动时扫描「上次提交没写完」的导入批次，按**实际结果**收尾。
  ///
  /// 提交是一个事务（`commitImport`），所以进程被杀只可能留下两种局面：
  ///
  /// * **什么都没写进去** —— 批次仍停在 `COMMITTING`。放回 `READY`，
  ///   用户可以照原样再提交一次；
  /// * **已经写进去了、状态没来得及改** —— 库里已经有属于这个批次的交易。
  ///   这时必须补记为 `COMMITTED`：否则用户再提交一次就会入两份，
  ///   而指南明确要求「提交时进程结束后恢复不出现半批数据或重复记录」。
  ///
  /// 判断依据是交易上的 `importBatchId` —— 那个字段就是为这件事存在的。
  /// 返回放回待提交与补记已提交的批次数，供日志与测试核对。
  Future<({int reopened, int closed})> recoverInterruptedImports() async {
    var reopened = 0;
    var closed = 0;

    for (final ledger in await _store.ledgers()) {
      final batches = await _store.importBatches(ledgerId: ledger.id);
      final inFlight = <ImportBatch>[
        for (final batch in batches)
          if (batch.stage == ImportStage.committing) batch,
      ];
      if (inFlight.isEmpty) continue;

      final dataset = await _store.dataset(ledgerId: ledger.id);
      for (final batch in inFlight) {
        final written = dataset.transactions.any(
          (transaction) => transaction.importBatchId == batch.id,
        );
        if (written) {
          await _store.updateImportBatch(
            batch.copyWith(
              stage: ImportStage.committed,
              committedAtMs: batch.committedAtMs ?? _nowMs(),
            ),
          );
          closed++;
        } else {
          await _store.updateImportBatch(
            batch.copyWith(stage: ImportStage.ready),
          );
          reopened++;
        }
      }
    }

    return (reopened: reopened, closed: closed);
  }

  /// 月度报告：概况 + 洞察 + 趋势 + 有记录的月份 + 完整数据集。
  ///
  /// 一次把页面需要的东西全算好。取的是**整本账本**的数据集，
  /// 因为跨月退款、趋势、分类变化都需要目标月份之外的记录。
  ///
  /// 首页、月报、趋势、明细、分享、月份页都从这一个对象取数，
  /// 于是「同一笔交易在所有页面金额一致」是从源头成立的，
  /// 而不是靠每个页面各自小心。
  Future<MonthReport> monthReport({
    required int ledgerId,
    required YearMonth month,
    int trendMonths = MonthReports.defaultTrendMonths,
  }) async {
    final ledger = await _ledgerById(ledgerId);
    final dataset = await _store.dataset(ledgerId: ledgerId);
    final confirmed = await _store.confirmedMonths(ledgerId: ledgerId);
    return MonthReports.build(
      month: month,
      dataset: dataset,
      isDemoLedger: ledger.isDemo,
      coverageConfirmed: confirmed,
      trendMonths: trendMonths,
    );
  }

  Future<LedgerDataset> dataset({
    required int ledgerId,
    Set<YearMonth>? months,
  }) => _store.dataset(ledgerId: ledgerId, months: months);

  /// 某月的金额与分类概况。
  Future<MonthOverview> monthOverview({
    required int ledgerId,
    required YearMonth month,
  }) async {
    final ledger = await _ledgerById(ledgerId);
    final dataset = await _store.dataset(ledgerId: ledgerId, months: {month});
    final confirmed = await _store.coverageConfirmed(
      ledgerId: ledgerId,
      month: month,
    );
    return MonthOverview.compute(
      month: month,
      dataset: dataset,
      coverageConfirmed: confirmed,
      isDemoLedger: ledger.isDemo,
    );
  }

  /// 多个月份的概况（趋势图用）。一次取数，逐月计算。
  Future<List<MonthOverview>> monthOverviews({
    required int ledgerId,
    required Iterable<YearMonth> months,
  }) async {
    final ledger = await _ledgerById(ledgerId);
    final wanted = months.toList();
    final dataset = await _store.dataset(
      ledgerId: ledgerId,
      months: wanted.toSet(),
    );
    final result = <MonthOverview>[];
    for (final month in wanted) {
      result.add(
        MonthOverview.compute(
          month: month,
          dataset: dataset,
          coverageConfirmed: await _store.coverageConfirmed(
            ledgerId: ledgerId,
            month: month,
          ),
          isDemoLedger: ledger.isDemo,
        ),
      );
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // 整理会话
  // ---------------------------------------------------------------------------

  /// 加载（必要时创建）整理会话。
  ///
  /// 会把会话与数据库**对齐**：已经被别处处理掉的记录从队列移除，
  /// 期间新出现的待整理记录追加进来。这样「导入后继续整理」不需要额外流程。
  Future<ReviewSnapshot> loadSnapshot({
    required int ledgerId,
    required YearMonth month,
  }) async {
    final ledger = await _ledgerById(ledgerId);
    final dataset = await _store.dataset(ledgerId: ledgerId, months: {month});
    final stored = await _store.loadReviewSession(
      ledgerId: ledgerId,
      month: month,
    );

    final reconciled = _reconcile(
      ledgerId: ledgerId,
      month: month,
      dataset: dataset,
      stored: stored,
    );

    if (reconciled.changed) {
      await _store.saveReviewSession(record: reconciled.record);
    }

    final action = await _store.latestAvailableAction(
      ledgerId: ledgerId,
      month: month,
    );
    final confirmed = await _store.coverageConfirmed(
      ledgerId: ledgerId,
      month: month,
    );

    return ReviewSnapshot(
      record: reconciled.record,
      dataset: dataset,
      isDemoLedger: ledger.isDemo,
      coverageConfirmed: confirmed,
      lastActionLabel: action?.label,
    );
  }

  /// 确认当前记录的归类。
  Future<ReviewOutcome> confirm({
    required int ledgerId,
    required YearMonth month,
    required int transactionId,
    required int categoryId,
  }) async {
    final snapshot = await loadSnapshot(ledgerId: ledgerId, month: month);
    final transaction = snapshot.dataset.transaction(transactionId);
    if (transaction == null) {
      return ReviewRejected('找不到这条记录，可能已被删除');
    }

    // 消费必须完成「有效分配」才算处理完成（指南 3.3）。
    // 这里只给一项分配，等于「重新归类成本类全额」；拆分走 [split]。
    final items = AllocationRules.singleCategory(
      categoryId,
      transaction.amountCents,
    );
    final ruleError = AllocationRules.validate(
      originalCents: transaction.amountCents,
      items: items,
    );
    if (ruleError != null) return ReviewRejected(ruleError.message);

    final nextRecord = _withoutEntry(snapshot.record, transactionId);
    final undo = UndoRecord(
      type: ReviewActionType.resolve,
      label: '确认 ${transaction.merchant}',
      ledgerId: ledgerId,
      month: month,
      targets: <UndoTarget>[
        UndoTarget(
          transactionId: transactionId,
          beforeVersion: transaction.version,
          beforeStatus: transaction.reviewStatus,
          beforeNature: transaction.nature,
          beforeExcludeReason: transaction.excludeReason,
          beforeAllocations: _draftsOf(snapshot.dataset, transactionId),
        ),
      ],
      beforeEntries: snapshot.record.entries,
      createdAtMs: _nowMs(),
    );

    return _run(
      () => _store.resolveTransaction(
        before: transaction,
        items: items,
        session: nextRecord,
        undo: undo,
      ),
      ledgerId: ledgerId,
      month: month,
    );
  }

  /// 拆分一笔消费：把一笔金额拆到多个用途。
  ///
  /// 指南 3.5：不复制原交易（账单笔数不变），每项大于 0，
  /// 且合计**精确等于**原始金额；同一分类不能重复出现。
  ///
  /// 指南 3.5.6：已经有退款关联的消费不能直接改变拆分结构 ——
  /// 那需要同时调整退款分配并在同一事务里校验。本轮先**明确拒绝**，
  /// 而不是默默把退款分配留成对不上号的旧值。
  Future<ReviewOutcome> split({
    required int ledgerId,
    required YearMonth month,
    required int transactionId,
    required List<AllocationDraft> items,
  }) async {
    final snapshot = await loadSnapshot(ledgerId: ledgerId, month: month);
    final transaction = snapshot.dataset.transaction(transactionId);
    if (transaction == null) {
      return ReviewRejected('找不到这条记录，可能已被删除');
    }

    final ruleError = AllocationRules.validate(
      originalCents: transaction.amountCents,
      items: items,
    );
    if (ruleError != null) return ReviewRejected(ruleError.message);

    final hasRefund = snapshot.dataset.refundLinks.any(
      (link) => link.originalTransactionId == transactionId,
    );
    if (hasRefund) {
      return ReviewRejected('这笔消费已经有退款关联，先解除关联再拆分');
    }

    final nextRecord = _withoutEntry(snapshot.record, transactionId);
    final undo = UndoRecord(
      type: ReviewActionType.resolve,
      label: '拆分 ${transaction.merchant}',
      ledgerId: ledgerId,
      month: month,
      targets: <UndoTarget>[
        UndoTarget(
          transactionId: transactionId,
          beforeVersion: transaction.version,
          beforeStatus: transaction.reviewStatus,
          beforeNature: transaction.nature,
          beforeExcludeReason: transaction.excludeReason,
          beforeAllocations: _draftsOf(snapshot.dataset, transactionId),
        ),
      ],
      beforeEntries: snapshot.record.entries,
      createdAtMs: _nowMs(),
    );

    return _run(
      () => _store.resolveTransaction(
        before: transaction,
        items: items,
        session: nextRecord,
        undo: undo,
      ),
      ledgerId: ledgerId,
      month: month,
    );
  }

  /// 稍后处理。不增加完成数。
  Future<ReviewOutcome> defer({
    required int ledgerId,
    required YearMonth month,
    required int transactionId,
  }) async {
    final snapshot = await loadSnapshot(ledgerId: ledgerId, month: month);
    final transaction = snapshot.dataset.transaction(transactionId);
    if (transaction == null) {
      return ReviewRejected('找不到这条记录，可能已被删除');
    }

    final nextRecord = _withBucket(
      _withoutEntry(snapshot.record, transactionId),
      transactionId,
      ReviewBucket.deferred,
    );
    final undo = UndoRecord(
      type: ReviewActionType.defer,
      label: '稍后处理 ${transaction.merchant}',
      ledgerId: ledgerId,
      month: month,
      targets: <UndoTarget>[
        UndoTarget(
          transactionId: transactionId,
          beforeVersion: transaction.version,
          beforeStatus: transaction.reviewStatus,
          beforeNature: transaction.nature,
          beforeExcludeReason: transaction.excludeReason,
          beforeAllocations: _draftsOf(snapshot.dataset, transactionId),
        ),
      ],
      beforeEntries: snapshot.record.entries,
      createdAtMs: _nowMs(),
    );

    return _run(
      () => _store.deferTransaction(
        before: transaction,
        session: nextRecord,
        undo: undo,
      ),
      ledgerId: ledgerId,
      month: month,
    );
  }

  /// 把稍后队列放回主队列。
  Future<ReviewOutcome> reopenDeferred({
    required int ledgerId,
    required YearMonth month,
  }) async {
    final snapshot = await loadSnapshot(ledgerId: ledgerId, month: month);
    final deferred = snapshot.deferred;
    if (deferred.isEmpty) return const ReviewRejected('稍后队列里没有记录');

    final entries = <ReviewQueueEntry>[
      ...snapshot.record.entries.where(
        (entry) => entry.bucket == ReviewBucket.main,
      ),
      for (final transaction in deferred)
        ReviewQueueEntry(
          transactionId: transaction.id,
          bucket: ReviewBucket.main,
        ),
    ];
    final nextRecord = snapshot.record.copyWith(
      entries: entries,
      updatedAtMs: _nowMs(),
      currentTransactionId: entries.isEmpty
          ? null
          : entries.first.transactionId,
      clearCurrent: entries.isEmpty,
    );

    final undo = UndoRecord(
      type: ReviewActionType.reopenDeferred,
      label: '重新整理稍后记录',
      ledgerId: ledgerId,
      month: month,
      targets: <UndoTarget>[
        for (final transaction in deferred)
          UndoTarget(
            transactionId: transaction.id,
            beforeVersion: transaction.version,
            beforeStatus: transaction.reviewStatus,
            beforeNature: transaction.nature,
          beforeExcludeReason: transaction.excludeReason,
          ),
      ],
      beforeEntries: snapshot.record.entries,
      createdAtMs: _nowMs(),
    );

    try {
      final ok = await _store.reopenDeferred(
        transactions: deferred,
        session: nextRecord,
        undo: undo,
      );
      if (!ok) {
        return const ReviewConflict('稍后记录刚刚被改过，请重试');
      }
    } catch (error) {
      return ReviewFailed(error);
    }
    return ReviewSucceeded(
      await loadSnapshot(ledgerId: ledgerId, month: month),
    );
  }

  /// 撤销最近一次可撤销操作。
  Future<ReviewOutcome> undo({
    required int ledgerId,
    required YearMonth month,
  }) async {
    final action = await _store.latestAvailableAction(
      ledgerId: ledgerId,
      month: month,
    );
    if (action == null) {
      return const ReviewRejected('没有可以撤销的操作了');
    }

    // 有关联退款时不能直接撤销原消费（指南 3.5.6 / 3.5.7）。
    //
    // 否则会出现一个静默的错误：原消费被撤销、不再计入月度统计，但退款关联
    // 仍然指着它 —— 于是那笔退款会去抵扣一笔已经不存在的消费，
    // 月度净额凭空变小，而且没有任何地方提示。
    //
    // 正确做法是先解除退款关联（退款恢复待核对），再撤销原消费。
    final dataset = await _store.dataset(ledgerId: ledgerId, months: {month});
    for (final target in action.targets) {
      if (dataset.refundsOf(target.transactionId).isEmpty) continue;
      return const ReviewRejected('这笔记录还有关联的退款，请先解除退款关联再撤销');
    }

    final restored = ReviewSessionRecord(
      ledgerId: ledgerId,
      month: month,
      entries: action.beforeEntries,
      updatedAtMs: _nowMs(),
      currentTransactionId: action.beforeEntries.isEmpty
          ? null
          : action.beforeEntries.first.transactionId,
    );

    try {
      final ok = await _store.applyUndo(action: action, session: restored);
      if (!ok) {
        // 目标记录在操作之后又被改过：标记失效，说明原因，不覆盖新数据。
        await _store.invalidateAction(action.id!);
        return ReviewConflict('「${action.label}」之后这条记录又被修改过，撤销会覆盖更新的数据，已停止');
      }
    } catch (error) {
      return ReviewFailed(error);
    }
    return ReviewSucceeded(
      await loadSnapshot(ledgerId: ledgerId, month: month),
    );
  }

  /// 记录用户对当月账单范围完整性的确认。
  ///
  /// 这个值**只能**由用户显式确认，不能因为数据里恰好有月初和月底的记录就
  /// 自动判定完整（指南 3.4）。
  Future<void> setCoverageConfirmed({
    required int ledgerId,
    required YearMonth month,
    required bool value,
  }) => _store.setCoverageConfirmed(
    ledgerId: ledgerId,
    month: month,
    value: value,
  );

  /// 改一笔记录的交易性质（指南 3.5）。
  ///
  /// 规则：
  ///
  /// * **收入 / 转账 / 排除统计**确认后即处理完成，不需要消费分类
  ///   （[TransactionNature.resolvesWithoutAllocation]，指南 3.3）；
  /// * **排除统计**必须写明原因 —— 否则以后回看时没人知道为什么不算；
  /// * **退款**必须已经关联到原消费，否则就变成一笔「没有原消费的退款」，
  ///   它去抵扣谁都不对；
  /// * **改回消费**则必须已经有分配：没有用途的消费不算处理完成。
  Future<ReviewOutcome> setNature({
    required int ledgerId,
    required YearMonth month,
    required int transactionId,
    required TransactionNature nature,
    String? excludeReason,
  }) async {
    final snapshot = await loadSnapshot(ledgerId: ledgerId, month: month);
    final transaction = snapshot.dataset.transaction(transactionId);
    if (transaction == null) {
      return ReviewRejected('找不到这条记录，可能已被删除');
    }

    final reason = excludeReason?.trim();
    switch (nature) {
      case TransactionNature.excluded:
        if (reason == null || reason.isEmpty) {
          return const ReviewRejected('排除统计需要写明原因，否则以后回看时不知道为什么不算');
        }
      case TransactionNature.refund:
        final linked = snapshot.dataset.refundLinks.any(
          (link) => link.refundTransactionId == transactionId,
        );
        if (!linked) {
          return const ReviewRejected(
            '退款需要先关联到原消费才能算处理完成；找不到原消费时，请改为「暂不计入统计」并写明原因',
          );
        }
      case TransactionNature.expense:
        if (snapshot.dataset.allocationsOf(transactionId).isEmpty) {
          return const ReviewRejected(
            '作为消费统计就需要一个用途，请先用「修改用途」或「拆分」把它定下来',
          );
        }
      case TransactionNature.income:
      case TransactionNature.transfer:
        break;
      case TransactionNature.unknown:
        return const ReviewRejected('还没有选择交易性质');
    }

    final nextRecord = _withoutEntry(snapshot.record, transactionId);
    final undo = UndoRecord(
      type: ReviewActionType.resolve,
      label: '${transaction.merchant} 改为「${nature.label}」',
      ledgerId: ledgerId,
      month: month,
      targets: <UndoTarget>[
        UndoTarget(
          transactionId: transactionId,
          beforeVersion: transaction.version,
          beforeStatus: transaction.reviewStatus,
          beforeNature: transaction.nature,
          beforeExcludeReason: transaction.excludeReason,
          beforeAllocations: _draftsOf(snapshot.dataset, transactionId),
        ),
      ],
      beforeEntries: snapshot.record.entries,
      createdAtMs: _nowMs(),
    );

    return _run(
      () => _store.setTransactionNature(
        before: transaction,
        nature: nature,
        excludeReason: nature == TransactionNature.excluded ? reason : null,
        session: nextRecord,
        undo: undo,
      ),
      ledgerId: ledgerId,
      month: month,
    );
  }

  /// 保存详情页的修改：备注，以及（可选的）用途变更。
  ///
  /// 两件事一次写完，是因为详情页只有一个「保存修改」：分成两次写会出现
  /// 「撤销之后用途回来了、备注没回来」这种半截结果。
  ///
  /// [categoryId] 为 null 表示不改用途 —— 那就不动记录的处理状态，
  /// 免得「只写了个备注」把一笔还没归类的消费算成处理完成。
  Future<ReviewOutcome> saveDetails({
    required int ledgerId,
    required YearMonth month,
    required int transactionId,
    required String? note,
    int? categoryId,
  }) async {
    final snapshot = await loadSnapshot(ledgerId: ledgerId, month: month);
    final transaction = snapshot.dataset.transaction(transactionId);
    if (transaction == null) {
      return ReviewRejected('找不到这条记录，可能已被删除');
    }

    // 空字符串当作「没有备注」：否则库里会存一堆空白备注。
    final trimmed = note?.trim();
    final nextNote = (trimmed == null || trimmed.isEmpty) ? null : trimmed;

    List<AllocationDraft>? items;
    if (categoryId != null) {
      items = AllocationRules.singleCategory(categoryId, transaction.amountCents);
      final ruleError = AllocationRules.validate(
        originalCents: transaction.amountCents,
        items: items,
      );
      if (ruleError != null) return ReviewRejected(ruleError.message);
    }

    // 改了用途就是「处理完成」，要从待整理队列里出去；只改备注则队列不动。
    final nextRecord = items == null
        ? snapshot.record
        : _withoutEntry(snapshot.record, transactionId);

    final undo = UndoRecord(
      type: ReviewActionType.resolve,
      label: '修改 ${transaction.merchant}',
      ledgerId: ledgerId,
      month: month,
      targets: <UndoTarget>[
        UndoTarget(
          transactionId: transactionId,
          beforeVersion: transaction.version,
          beforeStatus: transaction.reviewStatus,
          beforeNature: transaction.nature,
          beforeExcludeReason: transaction.excludeReason,
          beforeNote: transaction.note,
          beforeAllocations: _draftsOf(snapshot.dataset, transactionId),
        ),
      ],
      beforeEntries: snapshot.record.entries,
      createdAtMs: _nowMs(),
    );

    return _run(
      () => _store.saveDetails(
        before: transaction,
        note: nextNote,
        items: items,
        session: nextRecord,
        undo: undo,
      ),
      ledgerId: ledgerId,
      month: month,
    );
  }

  // ---------------------------------------------------------------------------
  // 退款关联
  // ---------------------------------------------------------------------------

  /// 建立退款与原消费的关联，并**同时**把它标成退款、置为处理完成。
  ///
  /// 与 [linkRefund] 的区别：那个只建连接（阶段 2 的能力，用户从原消费那边
  /// 手动挂退款时用），这个走的是用户真实会遇到的路径 —— 一导入进来就有一笔
  /// 「退款」，用户要把它指回原来那笔消费。这种情形下性质和连接必须一次写完，
  /// 见 `RefundRules.validateLink` 的注释。
  ///
  /// 校验全在 [RefundRules] 里，与单元测试共用同一份实现。
  Future<ReviewOutcome> linkRefundAndResolve({
    required int ledgerId,
    required YearMonth month,
    required int refundTransactionId,
    required int originalTransactionId,
    List<RefundAllocationDraft> allocations = const <RefundAllocationDraft>[],
  }) async {
    final refund = await _store.transactionById(refundTransactionId);
    if (refund == null) return const ReviewRejected('找不到这笔退款记录');
    final original = await _store.transactionById(originalTransactionId);
    if (original == null) return const ReviewRejected('找不到要关联的原消费记录');

    // 跨月退款时退款月与原消费月不同，数据集要同时覆盖两个月（指南 3.5.4）。
    final dataset = await _store.dataset(
      ledgerId: ledgerId,
      months: <YearMonth>{refund.month, original.month},
    );

    // 原消费还没有用途时，退款没有可抵扣的东西。与其建一条抵扣不到任何用途的
    // 连接（那会让拆分后的分摊金额悄悄算错），不如让用户先把用途定下来。
    if (dataset.allocationsOf(originalTransactionId).isEmpty) {
      return const ReviewRejected(
        '这笔消费还没有用途，先去详情页给它定一个用途，退款才知道抵扣什么',
      );
    }

    // 指南 3.5.5：单分类消费直接抵扣那一项（[allocations] 留空）；拆分消费
    // 必须明确退款分配 —— 合计等于退款金额，单项累计不超过该拆分项。
    // 连接本身的校验也在里面（`validateRefundAllocations` 会先调 `validateLink`）。
    final error = RefundRules.validateRefundAllocations(
      dataset: dataset,
      refundTransactionId: refundTransactionId,
      originalTransactionId: originalTransactionId,
      refundAmountCents: refund.amountCents,
      drafts: allocations,
    );
    if (error != null) return ReviewRejected(error.message);

    final snapshot = await loadSnapshot(ledgerId: ledgerId, month: month);
    final nextRecord = _withoutEntry(snapshot.record, refundTransactionId);

    return _run(
      () => _store.linkRefundAndResolve(
        before: refund,
        originalTransactionId: originalTransactionId,
        amountCents: refund.amountCents,
        session: nextRecord,
        allocations: allocations,
      ),
      ledgerId: ledgerId,
      month: month,
    );
  }

  /// 解除一笔退款的关联（指南 3.5.7），退款回到待核对。
  ///
  /// 与 [linkRefundAndResolve] 对称：也是一次写入 —— 删连接、把退款改回
  /// `unknown` + 待整理、保存会话。**没有连接时明确拒绝**，而不是默默成功：
  /// 用户点的那句「取消关联」如果什么都没取消，ta 应当知道。
  ///
  /// 退款不会出现在返回值里靠手写队列项 —— 它变回待整理之后，
  /// [loadSnapshot] 的 reconcile 会把它算回队列，与「新导入一笔待整理」同理。
  Future<ReviewOutcome> unlinkRefund({
    required int ledgerId,
    required int refundTransactionId,
  }) async {
    final refund = await _store.transactionById(refundTransactionId);
    if (refund == null) return const ReviewRejected('找不到这笔退款记录');

    final link = await _store.refundLinkOf(refundTransactionId);
    if (link == null) {
      return const ReviewRejected('这笔退款没有关联原消费，不需要解除');
    }

    final month = refund.month;
    final snapshot = await loadSnapshot(ledgerId: ledgerId, month: month);

    return _run(
      () => _store.unlinkRefund(
        refundTransactionId: refundTransactionId,
        session: snapshot.record,
      ),
      ledgerId: ledgerId,
      month: month,
    );
  }

  /// 一笔退款当前的关联（没有则是 null）。
  ///
  /// 给「详情页要显示这笔退款抵扣到了哪一笔」用。直查而不是从数据集里找：
  /// 数据集里的连接是跟着**原消费所在月份**来的，跨月退款在原消费不在本月
  /// 时就找不到，而这里问的正是「这笔退款」。
  Future<RefundLink?> refundLinkOf(int refundTransactionId) =>
      _store.refundLinkOf(refundTransactionId);

  /// 按 ID 取一笔记录。只读场景用（比如把原消费的商户名显示出来）。
  Future<LedgerTransaction?> transactionById(int transactionId) =>
      _store.transactionById(transactionId);

  /// 新建一个分类。
  ///
  /// 名字校验与同级重名走 [CategoryRules]；重名这里会**明确拒绝**，
  /// 而不是让数据库的唯一索引抛出来 —— 那句话是给用户看的。
  Future<CategoryWriteResult> createCategory({
    required int ledgerId,
    required String name,
    required String iconKey,
    int? parentId,
  }) async {
    try {
      final all = await _store.categories(ledgerId: ledgerId);
      final siblings = <Category>[
        for (final category in all)
          if (category.parentId == parentId) category,
      ];

      final error = CategoryRules.validateName(name: name, siblings: siblings);
      if (error != null) return CategoryRejected(error.message);

      // 排到同级最后，而不是插在最前面 —— 用户新建的分类多半是补充性质的。
      var sortOrder = 0;
      for (final sibling in siblings) {
        if (sibling.sortOrder >= sortOrder) sortOrder = sibling.sortOrder + 1;
      }

      final created = await _store.saveCategory(
        Category(
          id: Category.idUnassigned,
          parentId: parentId,
          name: name.trim(),
          iconType: CategoryIconType.builtin,
          iconKey: iconKey,
          sortOrder: sortOrder,
          isBuiltin: false,
        ),
      );
      return CategorySaved(created);
    } catch (error) {
      return CategoryRejected('分类没有保存成功：$error');
    }
  }

  /// 归档 / 恢复一个分类（指南 3.5.8：**分类删除默认归档**，历史引用继续有效）。
  ///
  /// 归档**不动任何已经发生的分配**：记录里存的还是那个分类 ID，
  /// 明细、月报、导出照旧显示它的名字与图标。变的只有一件事 ——
  /// 它不再出现在「选择用途」的列表里。
  ///
  /// 一级分类归档时**连带**归档它的细分用途：细分用途只能从父级进入，
  /// 父级归档后它们就成了「选不到、但还挂在全部分类页上」的幽灵条目
  /// （那一页读的是扁平列表）。恢复父级时一起恢复。
  ///
  /// 唯一被拒绝的情况是 [CategoryRules.validateArchive] 里的
  /// 「最后一个还在用的一级分类」—— 用途列表不能空。
  Future<CategoryWriteResult> setCategoryArchived({
    required int ledgerId,
    required int categoryId,
    required bool archived,
  }) async {
    try {
      final all = await _store.categories(ledgerId: ledgerId);
      Category? target;
      for (final category in all) {
        if (category.id == categoryId) target = category;
      }
      if (target == null) {
        return const CategoryRejected('找不到这个分类，可能已经被删掉了');
      }

      final error = CategoryRules.validateArchive(category: target, all: all);
      if (error != null) return CategoryRejected(error.message);

      final affected = <Category>[
        target,
        if (target.isRoot)
          for (final category in all)
            if (category.parentId == target.id) category,
      ];

      Category? saved;
      for (final category in affected) {
        final result = await _store.saveCategory(
          category.copyWith(archived: archived),
        );
        if (category.id == categoryId) saved = result;
      }
      return CategorySaved(saved ?? target);
    } catch (error) {
      return CategoryRejected('分类没有保存成功：$error');
    }
  }

  /// 把一个分类合并到另一个分类（指南 3.5.8：
  /// 「分类删除默认归档，历史引用继续有效。重命名保留稳定 ID；
  /// **分类合并需显式迁移分配关系**」）。
  ///
  /// 三件事，顺序有意如此：
  ///
  /// 1. 校验：只能并到同层级的分类，目标不能已归档，源下面不能还有细分用途
  ///    （见 [CategoryRules.validateMerge]）；
  /// 2. **显式迁移分配**：把直接挂在源分类上的账目改成目标分类 ——
  ///    这就是指南要求的那句「显式」，不是把源藏起来让统计自己撞；
  /// 3. 源分类按 3.5.8 的默认语义**归档**，不删。它已经没有账目了，
  ///    但用户可能在「已归档」里找它，也可能只是想先把账并过去、
  ///    过两天再决定这个空壳要不要恢复。
  ///
  /// 迁移在前、归档在后：万一归档失败，用户看到的是「账已经并过去了，
  /// 那个空分类还在」—— 比反过来（分类没了、账没动）好解释得多。
  ///
  /// 合并**不提供撤销**：迁移会改掉分配的行结构（撞车时要先把两行合一），
  /// 撤不回去。所以界面必须在确认弹窗里先把这件事说清楚。
  Future<CategoryMergeResult> mergeCategories({
    required int ledgerId,
    required int sourceId,
    required int targetId,
  }) async {
    try {
      final all = await _store.categories(ledgerId: ledgerId);
      Category? source;
      Category? target;
      for (final category in all) {
        if (category.id == sourceId) source = category;
        if (category.id == targetId) target = category;
      }
      if (source == null) {
        return const CategoryMergeRejected('找不到这个分类，可能已经被删掉了');
      }

      final error = CategoryRules.validateMerge(
        source: source,
        all: all,
        targetId: targetId,
      );
      if (error != null) return CategoryMergeRejected(error.message);
      // 上面的校验已经保证目标存在；这里只是让类型收窄。
      final targetName = target?.name ?? '';

      final moved = await _store.migrateAllocations(
        sourceCategoryId: sourceId,
        targetCategoryId: targetId,
      );

      final archived = await setCategoryArchived(
        ledgerId: ledgerId,
        categoryId: sourceId,
        archived: true,
      );
      if (archived is CategoryRejected) {
        // 账已经并过去了，不能假装什么都没发生。
        return CategoryMergeRejected(
          '账目已经归到「$targetName」，但「${source.name}」没能归档：'
          '${archived.message}。它现在是个空分类，可以再删一次。',
        );
      }

      return CategoryMerged(
        movedTransactions: moved,
        sourceName: source.name,
        targetName: targetName,
      );
    } catch (error) {
      return CategoryMergeRejected('合并没有完成：$error');
    }
  }

  /// 改一个分类的图标。
  ///
  /// 只改图标（指南 14.3）：名称、ID、分类关系与金额都不动。
  /// 图标按**分类 ID** 存，所以以后改名也不会把图标弄丢。
  Future<CategoryWriteResult> setCategoryIcon({
    required int ledgerId,
    required int categoryId,
    required String iconKey,
  }) async {
    try {
      final all = await _store.categories(ledgerId: ledgerId);
      for (final category in all) {
        if (category.id != categoryId) continue;
        final saved = await _store.saveCategory(
          category.copyWith(
            iconType: CategoryIconType.builtin,
            iconKey: iconKey,
          ),
        );
        // 从图片换回内置图标：旧图片资源如果已经没人引用，顺手清掉。
        await _clearUnreferencedIcon(
          category.iconKey,
          ledgerId: ledgerId,
          keepAssetId: null,
        );
        return CategorySaved(saved);
      }
      return const CategoryRejected('找不到这个分类，可能已经被删掉了');
    } catch (error) {
      return CategoryRejected('图标没有保存成功：$error');
    }
  }

  /// 把分类图标换成一张图片（指南 14.3 / 14.4）。
  ///
  /// 顺序是「处理 → 写文件 → 提交数据库引用」：文件与数据库不可能共处一个
  /// 事务（14.4.3），所以任何一步失败都保持**旧图标不动**，
  /// 而且处理期间不删旧文件。只有替换成功之后，才去看旧资源还有没有人引用。
  Future<CategoryWriteResult> setCategoryImage({
    required int ledgerId,
    required int categoryId,
    required Uint8List bytes,
  }) async {
    if (!await _iconFiles.isAvailable()) {
      return const CategoryRejected('这个平台上还不能保存图片图标');
    }

    try {
      final all = await _store.categories(ledgerId: ledgerId);
      Category? target;
      for (final category in all) {
        if (category.id == categoryId) target = category;
      }
      if (target == null) {
        return const CategoryRejected('找不到这个分类，可能已经被删掉了');
      }

      final processed = await _thumbnails.thumbnail(bytes);
      switch (processed) {
        case IconThumbnailFailed(:final error):
          return CategoryRejected(error.message);
        case IconThumbnailReady(
          :final bytes,
          :final width,
          :final height,
        ):
          final hash = IconAssetRules.contentHash(bytes);
          final relativePath = await _iconFiles.write(
            contentHash: hash,
            bytes: bytes,
          );
          final saved = await _store.saveCategoryWithIconAsset(
            category: target,
            asset: CategoryIconAsset(
              id: CategoryIconAsset.idUnassigned,
              relativePath: relativePath,
              contentHash: hash,
              width: width,
              height: height,
              byteSize: bytes.length,
              createdAtMs: _nowMs(),
            ),
          );
          await _clearUnreferencedIcon(
            target.iconKey,
            ledgerId: ledgerId,
            keepAssetId: int.tryParse(saved.iconKey ?? ''),
          );
          return CategorySaved(saved);
      }
    } catch (error) {
      return CategoryRejected('这张图没有保存成功：$error');
    }
  }

  /// 把分类图标恢复成内置图标（设计稿的「恢复默认图标」）。
  ///
  /// [iconKey] 由调用方给出出厂图标键 —— 「默认」是种子数据里的定义，
  /// 而不是库里当前的值（那个值已经被用户改过了）。
  Future<CategoryWriteResult> clearCategoryImage({
    required int ledgerId,
    required int categoryId,
    required String iconKey,
  }) async {
    final result = await setCategoryIcon(
      ledgerId: ledgerId,
      categoryId: categoryId,
      iconKey: iconKey,
    );
    return result;
  }

  /// 清理一个不再被引用的图片资源（指南 14.4.4）。
  ///
  /// [keepAssetId] 是刚刚写进去、**肯定还在用**的那个资源：
  /// 保存同一个分类时，旧资源与新资源可能是同一条（同一张图），
  /// 那种情况下不能把它删掉。
  Future<void> _clearUnreferencedIcon(
    String? oldIconKey, {
    required int ledgerId,
    required int? keepAssetId,
  }) async {
    final assetId = int.tryParse(oldIconKey ?? '');
    if (assetId == null || assetId == keepAssetId) return;

    final assets = await _store.iconAssets();
    CategoryIconAsset? asset;
    for (final item in assets) {
      if (item.id == assetId) asset = item;
    }
    if (asset == null) return;

    // 还有别的分类指向它就不动 —— 先删记录再删文件：
    // 反过来的话，中途失败会留下一条指向不存在文件的记录。
    for (final category in await _store.categories(ledgerId: ledgerId)) {
      if (category.iconKey == '$assetId') return;
    }
    await _store.deleteIconAsset(assetId);
    await _iconFiles.delete(asset.relativePath);
  }

  /// 建立退款与原消费的关联。
  ///
  /// 规则全部来自 [RefundRules]，与单元测试共用同一份实现。
  /// 阶段 2 先把能力与约束做实；界面在阶段 4 接入。
  Future<ReviewOutcome> linkRefund({
    required int ledgerId,
    required YearMonth month,
    required int refundTransactionId,
    required int originalTransactionId,
    required int amountCents,
    List<RefundAllocationDraft> allocations = const <RefundAllocationDraft>[],
  }) async {
    final original = await _store.transactionById(originalTransactionId);
    if (original == null) {
      return const ReviewRejected('找不到要关联的原消费记录');
    }
    final refund = await _store.transactionById(refundTransactionId);
    if (refund == null) {
      return const ReviewRejected('找不到这笔退款记录');
    }

    // 校验用的数据集要同时覆盖**退款所在的月份**和**原消费所在的月份**：
    // 跨月退款时这两者不同，只取一个会找不到另一笔。
    final dataset = await _store.dataset(
      ledgerId: ledgerId,
      months: {original.month, refund.month},
    );

    final error = allocations.isEmpty
        ? RefundRules.validateLink(
            dataset: dataset,
            refundTransactionId: refundTransactionId,
            originalTransactionId: originalTransactionId,
            amountCents: amountCents,
          )
        : RefundRules.validateRefundAllocations(
            dataset: dataset,
            refundTransactionId: refundTransactionId,
            originalTransactionId: originalTransactionId,
            refundAmountCents: amountCents,
            drafts: allocations,
          );
    if (error != null) return ReviewRejected(error.message);

    try {
      await _store.insertRefundLink(
        refundTransactionId: refundTransactionId,
        originalTransactionId: originalTransactionId,
        amountCents: amountCents,
        allocations: allocations,
      );
    } catch (error) {
      // 唯一约束（同一退款只能关联一次）在这里被挡下。
      return ReviewFailed(error);
    }
    return ReviewSucceeded(
      await loadSnapshot(ledgerId: ledgerId, month: month),
    );
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  Future<ReviewOutcome> _run(
    Future<bool> Function() write, {
    required int ledgerId,
    required YearMonth month,
  }) async {
    try {
      final ok = await write();
      if (!ok) {
        return const ReviewConflict('这条记录刚刚被改过，请重试');
      }
    } catch (error) {
      return ReviewFailed(error);
    }
    return ReviewSucceeded(
      await loadSnapshot(ledgerId: ledgerId, month: month),
    );
  }

  Future<Ledger> _ledgerById(int ledgerId) async {
    final ledgers = await _store.ledgers();
    for (final ledger in ledgers) {
      if (ledger.id == ledgerId) return ledger;
    }
    throw StateError('找不到账本：$ledgerId');
  }

  int _nowMs() => _clock().millisecondsSinceEpoch;

  /// 当前时间（毫秒）。
  ///
  /// 公开出来是给 `ImportWorkflow` 用的：导入批次的时间戳必须走同一个
  /// 可注入的时钟，否则测试里就没法得到确定的时间。
  int nowMs() => _nowMs();

  List<AllocationDraft> _draftsOf(LedgerDataset dataset, int transactionId) =>
      <AllocationDraft>[
        for (final allocation in dataset.allocationsOf(transactionId))
          AllocationDraft(
            categoryId: allocation.categoryId,
            amountCents: allocation.amountCents,
          ),
      ];

  ReviewSessionRecord _withoutEntry(
    ReviewSessionRecord record,
    int transactionId,
  ) => record.copyWith(
    entries: <ReviewQueueEntry>[
      for (final entry in record.entries)
        if (entry.transactionId != transactionId) entry,
    ],
  );

  /// 把某笔挪到指定队列的末尾。
  ReviewSessionRecord _withBucket(
    ReviewSessionRecord record,
    int transactionId,
    ReviewBucket bucket,
  ) => record.copyWith(
    entries: <ReviewQueueEntry>[
      ...record.entries,
      ReviewQueueEntry(transactionId: transactionId, bucket: bucket),
    ],
    currentTransactionId: _firstMainId(record.entries, transactionId),
  );

  int? _firstMainId(List<ReviewQueueEntry> entries, int removedId) {
    for (final entry in entries) {
      if (entry.transactionId == removedId) continue;
      if (entry.bucket == ReviewBucket.main) return entry.transactionId;
    }
    return null;
  }

  /// 把会话与数据库对齐。
  _ReconcileResult _reconcile({
    required int ledgerId,
    required YearMonth month,
    required LedgerDataset dataset,
    required ReviewSessionRecord? stored,
  }) {
    final pending = <LedgerTransaction>[];
    final deferred = <LedgerTransaction>[];
    for (final transaction in dataset.transactions) {
      if (transaction.month != month) continue;
      switch (transaction.reviewStatus) {
        case ReviewStatus.pending:
          pending.add(transaction);
        case ReviewStatus.deferred:
          deferred.add(transaction);
        case ReviewStatus.resolved:
          break;
      }
    }
    // 稳定顺序：时间倒序，同一时刻按 ID，避免顺序随查询计划漂移。
    int byTimeThenId(LedgerTransaction a, LedgerTransaction b) {
      final byTime = b.occurredAtMs.compareTo(a.occurredAtMs);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    }

    pending.sort(byTimeThenId);
    deferred.sort(byTimeThenId);

    final wanted = <ReviewQueueEntry>[
      for (final transaction in pending)
        ReviewQueueEntry(
          transactionId: transaction.id,
          bucket: ReviewBucket.main,
        ),
      for (final transaction in deferred)
        ReviewQueueEntry(
          transactionId: transaction.id,
          bucket: ReviewBucket.deferred,
        ),
    ];

    if (stored == null) {
      return _ReconcileResult(
        record: ReviewSessionRecord(
          ledgerId: ledgerId,
          month: month,
          entries: wanted,
          updatedAtMs: _nowMs(),
          currentTransactionId: wanted.isEmpty
              ? null
              : wanted.first.transactionId,
        ),
        changed: true,
      );
    }

    // 保留用户已经调整过的顺序：先按存储的顺序取仍然有效的项，
    // 再把新出现的记录按稳定顺序补到对应队列末尾。
    final allowed = <int, ReviewBucket>{
      for (final entry in wanted) entry.transactionId: entry.bucket,
    };
    final kept = <ReviewQueueEntry>[];
    final seen = <int>{};
    for (final entry in stored.entries) {
      final bucket = allowed[entry.transactionId];
      if (bucket == null) continue;
      if (!seen.add(entry.transactionId)) continue;
      kept.add(
        ReviewQueueEntry(transactionId: entry.transactionId, bucket: bucket),
      );
    }
    final additions = <ReviewQueueEntry>[
      for (final entry in wanted)
        if (!seen.contains(entry.transactionId)) entry,
    ];
    final merged = <ReviewQueueEntry>[...kept, ...additions];

    final changed =
        merged.length != stored.entries.length ||
        !_sameOrder(merged, stored.entries);

    return _ReconcileResult(
      record: changed
          ? stored.copyWith(
              entries: merged,
              updatedAtMs: _nowMs(),
              currentTransactionId: merged.isEmpty
                  ? null
                  : merged.first.transactionId,
              clearCurrent: merged.isEmpty,
            )
          : stored,
      changed: changed,
    );
  }

  bool _sameOrder(List<ReviewQueueEntry> a, List<ReviewQueueEntry> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index].transactionId != b[index].transactionId) return false;
      if (a[index].bucket != b[index].bucket) return false;
    }
    return true;
  }
}

final class _ReconcileResult {
  const _ReconcileResult({required this.record, required this.changed});

  final ReviewSessionRecord record;
  final bool changed;
}
