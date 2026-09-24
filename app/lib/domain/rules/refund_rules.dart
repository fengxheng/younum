/// 退款关联与抵扣的校验规则。
///
/// 指南 3.5 里与退款有关的硬规则：
///
/// 3. 多笔退款可关联同一消费，**累计抵扣不得超过原消费金额**；超额进入待核对，
///    不产生无解释的负消费。
/// 5. 单分类消费退款直接抵扣该类；**拆分消费退款要求明确退款分配**，
///    退款分配合计等于退款金额，单项累计不超过原分配金额。
/// 6. 原消费的拆分结构在有关联退款时不能直接破坏。
///
/// 这里全部实现为纯函数，仓库层在事务里调用；数据库另有外键与唯一约束兜底。
library;

import '../models/allocation.dart';
import '../models/ledger_dataset.dart';

/// 退款校验失败的原因。
sealed class RefundError {
  const RefundError(this.message);

  final String message;
}

/// 找不到指定的交易。
final class RefundTargetNotFound extends RefundError {
  const RefundTargetNotFound(this.transactionId) : super('找不到对应的交易记录');

  final int transactionId;
}

/// 退款关联到它自己。
final class RefundSelfReference extends RefundError {
  const RefundSelfReference()
      : super('退款不能关联到自己，请选择原消费记录');
}

/// 被关联的那笔不是消费。
final class RefundOriginalNotExpense extends RefundError {
  const RefundOriginalNotExpense()
      : super('退款只能关联到一笔消费，不能关联收入、转账或另一笔退款');
}

/// 关联金额不是正数。
final class RefundAmountNotPositive extends RefundError {
  const RefundAmountNotPositive() : super('关联金额必须大于 0');
}

/// 关联金额超过退款本身的金额。
final class RefundExceedsRefundAmount extends RefundError {
  const RefundExceedsRefundAmount(this.refundAmountCents)
      : super('关联金额不能超过退款金额本身');

  final int refundAmountCents;
}

/// 这笔退款已经关联过了。
final class RefundAlreadyLinked extends RefundError {
  const RefundAlreadyLinked(this.existingOriginalTransactionId)
      : super('这笔退款已经关联过一笔消费，不能重复关联');

  final int existingOriginalTransactionId;
}

/// 累计抵扣超过原消费金额。
///
/// 这是指南 3.5.3 的核心规则：超额**必须明确失败**，
/// 不允许产生一笔没有解释的负消费。
final class RefundExceedsOriginal extends RefundError {
  const RefundExceedsOriginal({required this.remainingCents})
      : super('累计退款超过原消费金额，本笔最多还能抵扣这个额度');

  /// 还能抵扣多少（分）。
  final int remainingCents;
}

/// 拆分消费的退款没有给出明确分配。
final class RefundAllocationRequired extends RefundError {
  const RefundAllocationRequired()
      : super('这笔消费拆成了多个分类，请说明退款分别抵扣哪几项');
}

/// 退款分配一项都没有。
final class RefundAllocationItemsEmpty extends RefundError {
  const RefundAllocationItemsEmpty() : super('至少需要一项退款分配');
}

/// 某一项退款分配金额不合法。
final class RefundAllocationItemNotPositive extends RefundError {
  const RefundAllocationItemNotPositive(this.originalAllocationId)
      : super('每一项退款金额都要大于 0');

  final int originalAllocationId;
}

/// 退款分配指向了不属于这笔消费的拆分项。
final class RefundAllocationUnknownItem extends RefundError {
  const RefundAllocationUnknownItem(this.originalAllocationId)
      : super('退款分配指向了不属于这笔消费的拆分项');

  final int originalAllocationId;
}

/// 退款分配合计不等于退款金额。
final class RefundAllocationSumMismatch extends RefundError {
  const RefundAllocationSumMismatch({required this.expected, required this.actual})
      : super('退款分配合计必须精确等于退款金额');

  final int expected;
  final int actual;

  int get differenceCents => expected - actual;
}

/// 某个拆分项被退款抵扣的累计额超过了它自己的金额。
final class RefundAllocationExceedsOriginalItem extends RefundError {
  const RefundAllocationExceedsOriginalItem({
    required this.originalAllocationId,
    required this.remainingCents,
  }) : super('这一项被抵扣的金额超过了它原本的金额');

  final int originalAllocationId;

  /// 还能抵扣多少（分）。
  final int remainingCents;
}

/// 有关联退款时，原拆分项不能被删除、也不能缩减到低于已抵扣金额。
final class RefundSplitBreaksLinkedRefunds extends RefundError {
  const RefundSplitBreaksLinkedRefunds({
    required this.originalAllocationId,
    required this.refundedCents,
  }) : super('这一项已经被退款抵扣过，不能删除或改小到低于已抵扣金额');

  final int originalAllocationId;

  /// 已经被抵扣的金额（分）。
  final int refundedCents;
}

/// 退款规则。
abstract final class RefundRules {
  /// 校验「把一笔退款关联到一笔原消费」。
  ///
  /// [excludingLinkId] 用于修改已有连接时排除它自己重算额度。
  ///
  /// 注意这里**不**校验退款交易的性质：调用方是在同一个事务里
  /// 把性质改成 `REFUND` 并建立连接的，要求分两步会凭空制造中间状态。
  static RefundError? validateLink({
    required LedgerDataset dataset,
    required int refundTransactionId,
    required int originalTransactionId,
    required int amountCents,
    int? excludingLinkId,
  }) {
    if (amountCents <= 0) return const RefundAmountNotPositive();
    if (refundTransactionId == originalTransactionId) {
      return const RefundSelfReference();
    }

    final refund = dataset.transaction(refundTransactionId);
    if (refund == null) return RefundTargetNotFound(refundTransactionId);
    final original = dataset.transaction(originalTransactionId);
    if (original == null) return RefundTargetNotFound(originalTransactionId);

    if (!original.nature.isExpense) return const RefundOriginalNotExpense();

    // 首版一笔退款只能关联一笔原消费，所以「已经关联过」是硬错误。
    final existing = dataset.linkForRefund(refundTransactionId);
    if (existing != null && existing.id != excludingLinkId) {
      return RefundAlreadyLinked(existing.originalTransactionId);
    }

    if (amountCents > refund.amountCents) {
      return RefundExceedsRefundAmount(refund.amountCents);
    }

    final alreadyLinked = dataset.linkedRefundTotalOf(
      originalTransactionId,
      excludingLinkId: excludingLinkId,
    );
    final remaining = original.amountCents - alreadyLinked;
    if (amountCents > remaining) return RefundExceedsOriginal(remainingCents: remaining);

    return null;
  }

  /// 校验拆分消费的退款分配。
  ///
  /// 单分类消费不需要调用它 —— 那种情况直接抵扣那唯一一条分配。
  static RefundError? validateRefundAllocations({
    required LedgerDataset dataset,
    required int refundTransactionId,
    required int originalTransactionId,
    required int refundAmountCents,
    required List<RefundAllocationDraft> drafts,
    int? excludingLinkId,
  }) {
    final linkError = validateLink(
      dataset: dataset,
      refundTransactionId: refundTransactionId,
      originalTransactionId: originalTransactionId,
      amountCents: refundAmountCents,
      excludingLinkId: excludingLinkId,
    );
    if (linkError != null) return linkError;

    final originalAllocations = dataset.allocationsOf(originalTransactionId);
    if (drafts.isEmpty) {
      // 只有一项分配时无需明确指定，抵扣它就行。
      return originalAllocations.length == 1
          ? null
          : const RefundAllocationRequired();
    }

    final seen = <int>{};
    for (final draft in drafts) {
      if (draft.amountCents <= 0) {
        return RefundAllocationItemNotPositive(draft.originalAllocationId);
      }
      if (!seen.add(draft.originalAllocationId)) {
        return RefundAllocationUnknownItem(draft.originalAllocationId);
      }
    }

    var total = 0;
    for (final draft in drafts) {
      final target = dataset.allocation(draft.originalAllocationId);
      if (target == null || target.transactionId != originalTransactionId) {
        return RefundAllocationUnknownItem(draft.originalAllocationId);
      }
      final alreadyRefunded = dataset.refundedAgainstAllocation(
        draft.originalAllocationId,
        excludingLinkId: excludingLinkId,
      );
      final remaining = target.amountCents - alreadyRefunded;
      if (draft.amountCents > remaining) {
        return RefundAllocationExceedsOriginalItem(
          originalAllocationId: draft.originalAllocationId,
          remainingCents: remaining,
        );
      }
      total += draft.amountCents;
    }

    if (total != refundAmountCents) {
      return RefundAllocationSumMismatch(
        expected: refundAmountCents,
        actual: total,
      );
    }
    return null;
  }

  /// 校验「修改原消费的拆分结构」是否破坏已有退款关联（指南 3.5.6）。
  ///
  /// [retainedAmountsByAllocationId] 是修改后仍然保留的拆分项及其新金额；
  /// 被删掉、或改小的项不在这里（或者金额变小）就会被拦下。
  ///
  /// 阶段 2 只实现规则本身；界面上的拆分编辑流程在阶段 4 接入。
  static RefundError? validateSplitChange({
    required LedgerDataset dataset,
    required int originalTransactionId,
    required Map<int, int> retainedAmountsByAllocationId,
  }) {
    for (final allocation in dataset.allocationsOf(originalTransactionId)) {
      final refunded = dataset.refundedAgainstAllocation(allocation.id);
      if (refunded == 0) continue;
      final retained = retainedAmountsByAllocationId[allocation.id];
      if (retained == null || retained < refunded) {
        return RefundSplitBreaksLinkedRefunds(
          originalAllocationId: allocation.id,
          refundedCents: refunded,
        );
      }
    }
    return null;
  }
}
