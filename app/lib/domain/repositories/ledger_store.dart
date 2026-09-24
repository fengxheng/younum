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
  /// [months] 为 null 表示取全部；给定月份时，额外带上**关联到这些月份消费的
  /// 退款**（即使退款本身发生在别的月份）—— 跨月退款要算对就必须这样取数。
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

  /// 确认归类：在**一个事务**里写入分配、置为已处理、递增版本、
  /// 保存会话顺序、写下可撤销的操作日志。
  ///
  /// 返回 false 表示版本冲突（交易已被别处修改），此时什么都不写。
  Future<bool> resolveTransaction({
    required LedgerTransaction before,
    required int categoryId,
    required ReviewSessionRecord session,
    required UndoRecord undo,
  });

  /// 稍后处理：一个事务里改状态、保存会话、写操作日志。
  Future<bool> deferTransaction({
    required LedgerTransaction before,
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
}
