/// 账本的持久化端口。
///
/// 分两层是为了让**业务逻辑只写一遍**：
///
/// * 本文件只声明「取行 / 写行 / 事务」这类存储动作，不含任何业务判断；
/// * `LedgerRepository` 在上面做编排，调用领域规则函数；
/// * 两个实现 —— `InMemoryLedgerStore`（`flutter test` 用）与
///   `SqfliteLedgerStore`（真机用）—— 只负责各自后端的读写。
///
/// 这样「拆分合计必须精确等于原金额」之类的规则不会因为换后端而走样；
/// 而外键、唯一约束这类**数据库才能保证**的事情，
/// 交给真机集成测试去验证（见 `integration_test/`）。
library;

import '../models/allocation.dart';
import '../models/category.dart';
import '../models/import_records.dart';
import '../models/ledger.dart';
import '../models/ledger_dataset.dart';
import '../models/ledger_transaction.dart';
import '../models/review_session_record.dart';
import '../models/year_month.dart';

/// 撤销的结果。
enum UndoStatus {
  /// 撤销成功。
  undone,

  /// 没有可撤销的操作。
  nothingToUndo,

  /// 目标交易在操作之后又被改过，不能覆盖新数据（指南 3.3）。
  versionConflict,
}

/// 撤销的结果与撤销后的会话状态。
final class UndoOutcome {
  const UndoOutcome({required this.status, this.session, this.conflictMessage});

  const UndoOutcome.nothing() : this(status: UndoStatus.nothingToUndo);

  final UndoStatus status;

  /// 撤销后的会话状态（成功时非空）。
  final ReviewSessionRecord? session;

  /// 版本冲突时给用户看的说明。
  final String? conflictMessage;
}

/// 账本存储端口。
abstract interface class LedgerStore {
  /// 建表（或建内存结构）并写入账本与分类，**幂等**。
  ///
  /// 重复调用不能产生重复账本或重复分类。
  Future<void> initialize();

  /// 清空全部账本数据并恢复初始的演示账单。
  ///
  /// 「清除本地数据」用：真实与演示账本的交易、分配、退款关联、整理会话、
  /// 操作日志、用户自建分类全部移除；账本与内置分类保留。
  Future<void> clearAll();

  /// 全部账本。演示账本与真实账本都在里面，靠 [Ledger.isDemo] 区分。
  Future<List<Ledger>> ledgers();

  /// 账本的分类（含归类的）。
  Future<List<Category>> categories({required int ledgerId});

  /// 取账本的数据集。
  ///
  /// [months] 为 null 表示取全部交易；给定月份时，额外带上**关联到这些月份
  /// 消费的退款**（即使退款本身发生在别的月份）—— 跨月退款要算对就必须
  /// 这样取数。
  ///
  /// ⚠️ **退款连接只在给了月份时返回。** `months == null` 拿到的是
  /// 「所有交易」，`refundLinks` 与 `refundAllocations` 都是空的。
  /// 要判断某笔退款有没有关联过，得按月取（判据在 [LedgerDataset.linkForRefund]，
  /// 但那个数据集得先带上连接）。这是两个实现一致的行为，不是某一端的偏差。
  Future<LedgerDataset> dataset({
    required int ledgerId,
    Set<YearMonth>? months,
  });

  /// 按 ID 取一笔交易。
  Future<LedgerTransaction?> transactionById(int transactionId);

  /// 新建一笔交易（导入流程用，阶段 3 接入）。返回新 ID。
  Future<int> insertTransaction(LedgerTransaction transaction);

  /// 修改一笔交易，带乐观校验：当前版本不等于 [expectedVersion] 就失败，什么都不写。
  ///
  /// 阶段 2 用它来证明「撤销遇到版本冲突会停下来」；阶段 4 的交易详情编辑
  /// 会走同一个入口。
  Future<bool> updateTransaction({
    required LedgerTransaction transaction,
    required int expectedVersion,
  });

  Future<ReviewSessionRecord?> loadReviewSession({
    required int ledgerId,
    required YearMonth month,
  });

  /// 只保存会话本身，不改动任何交易状态。
  ///
  /// 用于首次创建会话、以及把会话与数据库对齐（新出现的待整理记录追加进来）。
  /// 这类动作不是用户操作，因此不写撤销日志。
  Future<void> saveReviewSession({required ReviewSessionRecord record});

  Future<bool> coverageConfirmed({
    required int ledgerId,
    required YearMonth month,
  });

  Future<void> setCoverageConfirmed({
    required int ledgerId,
    required YearMonth month,
    required bool value,
  });

  /// 已确认范围完整的月份。
  ///
  /// 趋势与环比需要知道**上个月是不是也完整**，只查当前月份不够。
  Future<Set<YearMonth>> confirmedMonths({required int ledgerId});

  /// 确认归类：在**一个事务**里写入分配、置为已处理、递增版本、
  /// 保存会话顺序、写下可撤销的操作日志。
  ///
  /// [items] 是这笔交易的全部分配（拆分就是多于一项）。用一组而不是
  /// 「一个分类」是因为拆分与重新归类本质上是同一件事：
  /// **把旧的分配整体换成新的**。版本校验、会话与撤销日志只写一次。
  ///
  /// 返回 false 表示版本冲突（交易已被别处修改），此时什么都不写。
  Future<bool> resolveTransaction({
    required LedgerTransaction before,
    required List<AllocationDraft> items,
    required ReviewSessionRecord session,
    required UndoRecord undo,
  });

  /// 稍后处理：一个事务里改状态、保存会话、写操作日志。
  Future<bool> deferTransaction({
    required LedgerTransaction before,
    required ReviewSessionRecord session,
    required UndoRecord undo,
  });

  /// 把一笔退款关联到原消费，**并在同一个事务里**把它标成退款、置为已处理。
  ///
  /// 为什么不拆成两次写：`RefundRules.validateLink` 的注释说得很清楚 ——
  /// 分两步会凭空制造中间状态（「已关联但还不是退款」或「是退款却没关联」），
  /// 而中间状态会被统计与外部读取看到。
  ///
  /// 与 [insertRefundLink] 一样**不写撤销日志**：解除关联是一个独立操作
  /// （指南 3.5.7：退款恢复待核对），不是「撤销上一次」能摄过去的。
  ///
  /// 返回 false 表示版本冲突（记录已被别处修改），此时什么都不写。
  Future<bool> linkRefundAndResolve({
    required LedgerTransaction before,
    required int originalTransactionId,
    required int amountCents,
    required ReviewSessionRecord session,
  });

  /// 取一笔退款当前的关联（没有则是 null）。
  ///
  /// 为什么需要单独的查询：`dataset()` 里的 `refundLinks` 是**跟着原消费
  /// 所属月份**带出来的，所以「我想知道**这笔退款**关联到了谁」这种反方向
  /// 的问问不到（跨月时更问不到：连原消费在哪个月都不知道，就没法组月份集）。
  /// `refund_link.refund_transaction_id` 上有唯一索引，这里是个直查。
  Future<RefundLink?> refundLinkOf(int refundTransactionId);

  /// 解除退款关联（指南 3.5.7），退款**回到待核对**。
  ///
  /// 与 [linkRefundAndResolve] 对称，也是**一个事务**里做完：
  /// 删掉连接（及其退款分配）、把退款改回 `unknown` + `PENDING`、保存会话。
  ///
  /// 性质为什么改回 `unknown` 而不是留着 `refund`：原始账单里那笔钱的
  /// 性质本来就不是我们定的（导入时多为 `income`），解除关联意味着
  /// 「这一笔到底是什么，需要重新看」，猜一个不如不猜 —— 而且留着 `refund`
  /// 会让它在整理页里显得像一笔已经处理好的退款。
  ///
  /// 返回 false 表示本来就没有连接（或版本冲突），此时什么都不写。
  Future<bool> unlinkRefund({
    required int refundTransactionId,
    required ReviewSessionRecord session,
  });

  /// 保存详情页的修改：备注，以及（可选的）用途变更。
  ///
  /// 两件事必须在**一个事务**里完成，否则撤销只能还原一半 ——
  /// 用户会看到「撤销之后用途回来了、备注没回来」这种半截结果。
  ///
  /// [items] 为 null 表示不改用途（记录状态也不动）；给了分配就同时置为已处理。
  ///
  /// 返回 false 表示版本冲突（记录已被别处修改），此时什么都不写。
  Future<bool> saveDetails({
    required LedgerTransaction before,
    required String? note,
    required List<AllocationDraft>? items,
    required ReviewSessionRecord session,
    required UndoRecord undo,
  });

  /// 把一笔记录标成非消费（转账 / 收入 / 退款 / 排除统计），或改回消费。
  ///
  /// 这些性质不需要消费分类（`TransactionNature.resolvesWithoutAllocation`），
  /// 所以不走 [resolveTransaction]；但一样要在**一个事务**里改状态、
  /// 保存会话顺序、写下可撤销的日志。
  ///
  /// 改离「消费」时会把旧的分配删掉：它已经不再是消费，留着只会让以后回看
  /// 时看不懂。撤销日志里存着原分配，可以原样还原。
  ///
  /// 返回 false 表示版本冲突（记录已被别处修改），此时什么都不写。
  Future<bool> setTransactionNature({
    required LedgerTransaction before,
    required TransactionNature nature,
    required String? excludeReason,
    required ReviewSessionRecord session,
    required UndoRecord undo,
  });

  /// 只更新会话（把稍后队列放回主队列）。
  Future<void> saveSessionWithUndo({
    required ReviewSessionRecord session,
    required UndoRecord undo,
  });

  /// 把稍后队列重新放回主队列：一个事务里把这几笔改回待整理并保存会话。
  ///
  /// 返回 false 表示版本冲突（其中某一笔已被别处修改）。
  Future<bool> reopenDeferred({
    required List<LedgerTransaction> transactions,
    required ReviewSessionRecord session,
    required UndoRecord undo,
  });

  /// 按同源去重键批量找已有交易，返回「去重键 → 交易 ID」。
  ///
  /// 提交导入时用它判断某一笔到底是**新交易**还是**库里已经有的同一笔**。
  /// 后者只能新增一条来源绑定，不能再插一条交易 —— 否则真机上会直接撞
  /// `(ledger_id, dedupe_key)` 的唯一索引，整批提交失败；
  /// 而且撤回时就判断不出「这笔还被别的批次引用着」。
  Future<Map<String, int>> transactionIdsByDedupeKey({
    required int ledgerId,
    required List<String> dedupeKeys,
  });

  /// 写入一条退款关联（含可选的退款分配）。返回关联 ID。
  ///
  /// 同一笔退款只能有一条关联 —— 由数据库的唯一约束最终保证。
  Future<int> insertRefundLink({
    required int refundTransactionId,
    required int originalTransactionId,
    required int amountCents,
    List<RefundAllocationDraft> allocations,
  });

  /// 最近一条仍可撤销的操作。
  Future<UndoRecord?> latestAvailableAction({
    required int ledgerId,
    required YearMonth month,
  });

  /// 执行撤销：恢复目标交易与会的状态，并把该条日志标记为已使用。
  ///
  /// 返回 false 表示版本冲突，此时不写入任何东西。
  Future<bool> applyUndo({
    required UndoRecord action,
    required ReviewSessionRecord session,
  });

  /// 把一条日志标记为失效（目标交易被别处改过）。
  Future<void> invalidateAction(int actionId);

  // ---------------------------------------------------------------------------
  // 导入
  //
  // 这一组动作存在的原因：**未确认的数据不进入首页金额**。
  // 解析结果先写进暂存区（`import_batch` + `import_row`），
  // 用户确认后才由 [commitImport] 在一个事务里写进正式账。
  // ---------------------------------------------------------------------------

  /// 写入一个导入批次连同它的全部暂存行，返回批次 ID。
  ///
  /// 批次与行必须**一起**落库。只写了行没有批次，或反过来，
  /// 都会留下一份用户看不见、也删不掉的残骸。
  Future<int> insertImportBatch({
    required ImportBatch batch,
    required List<ImportRow> rows,
  });

  /// 更新批次的状态与统计。
  Future<void> updateImportBatch(ImportBatch batch);

  /// 删除一个批次及其暂存行与来源绑定。
  ///
  /// 只用于还在暂存区、从未提交过的批次；已提交的批次要走 [revertImport]。
  Future<void> deleteImportBatch(int batchId);

  /// 某账本的导入批次，最新的在前。
  Future<List<ImportBatch>> importBatches({required int ledgerId});

  /// 一个批次里的全部暂存行，按文件行号升序。
  Future<List<ImportRow>> importRows({required int batchId});

  /// 改写暂存行的取舍（用户在核对页上取消勾选某些行）。
  Future<void> updateImportRows(List<ImportRow> rows);

  /// 把暂存行写进正式账，**一个事务**完成。
  ///
  /// [entries] 每一项是「暂存行 + 要写入的交易」。
  ///
  /// 如果 `transaction.isPersisted` 为真，说明这笔在库里已经有了
  /// （同源键命中），此时**只新增来源绑定**，不再插一条交易。
  /// 返回该批涉及的交易 ID，顺序与 [entries] 一致。
  ///
  /// 事务语义很关键：要么整批进去、要么全不进去。写了一半的批次会让
  /// 首页金额出现一个用户无法解释的中间值，而且重试时会变成重复入账。
  Future<List<int>> commitImport({
    required int batchId,
    required List<({ImportRow row, LedgerTransaction transaction})> entries,
    required int nowMs,
    required int totalRows,
    required int duplicateCount,
    required int invalidCount,
    required int amountCents,
  });

  /// 撤回一个已提交的导入批次。
  ///
  /// 只删除**同时满足**下面三个条件的交易：
  ///
  /// * 只有这一个批次引用它（同一笔消费被两份账单同时导入时，撤回其中一份
  ///   不能连带删掉另一份的成果）；
  /// * 用户没给它分过类（没有 allocation）；
  /// * 用户没改过它（version == 1，整理状态还是 PENDING）。
  ///
  /// 后两条同样重要：撤回的是「这次导入」，不是用户在导入之后做的工作。
  ///
  /// [dryRun] 为真时**只算不做**，返回「如果现在撤回会发生什么」。
  /// 指南 4.4 要求撤回前展示真实影响，而这份影响必须与真正执行时的结果
  /// 一致 —— 所以预览与执行走的是同一段判定代码，不是两份。
  Future<ImportRevert> revertImport({
    required int batchId,
    required int nowMs,
    bool dryRun = false,
  });
}

/// 撤回结果。
///
/// 三种去向分开列，是因为它们对应三句不同的用户可见说明：
/// 「已删除 N 笔」「M 笔别的账单也导入过，已保留」「K 笔你已经整理过，已保留」。
/// 合成一个数字的话，界面就只能含糊地说「部分交易被保留」。
final class ImportRevert {
  const ImportRevert({
    required this.deletedTransactionIds,
    required this.sharedTransactionIds,
    required this.editedTransactionIds,
    this.unlinkedRefundIds = const <int>[],
  });

  /// 被删掉的交易：只有这一个批次引用，并且用户还没动过。
  final List<int> deletedTransactionIds;

  /// 保留下来的交易：还被其它批次引用（同一笔消费出现在两份账单里）。
  final List<int> sharedTransactionIds;

  /// 保留下来的交易：用户已经分过类或改过，不能再悄悄抹掉。
  final List<int> editedTransactionIds;

  /// 因为原消费被删掉而解除关联、回到待核对的退款（指南 3.5.7）。
  ///
  /// 它们**不会被删**：退款可能是另一份账单导进来的，撤回消费的那份账单
  /// 不能连带把别人的钱也抹掉。
  final List<int> unlinkedRefundIds;

  int get deletedCount => deletedTransactionIds.length;

  int get keptCount =>
      sharedTransactionIds.length + editedTransactionIds.length;

  int get unlinkedRefundCount => unlinkedRefundIds.length;

  @override
  String toString() =>
      'ImportRevert(删除 $deletedCount, 共享保留 ${sharedTransactionIds.length}, '
      '已整理保留 ${editedTransactionIds.length}, '
      '解除退款关联 ${unlinkedRefundIds.length})';
}
