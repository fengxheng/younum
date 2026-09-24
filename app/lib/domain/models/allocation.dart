/// 分配与退款关联。
///
/// 指南 3.2 / 3.5 的关系模型：
///
/// ```text
/// 消费交易 ──┬─ Allocation(categoryId, amountCents)   普通分类也是一条分配记录
///            │
///            └─ RefundLink(refundTransactionId, amountCents)
///                   └─ RefundAllocation(originalAllocationId, amountCents)
/// ```
///
/// 三个约束必须由数据库**和**业务函数同时拦住：
/// * 一笔消费的分配合计精确等于原金额；
/// * 多笔退款可关联同一消费，**累计抵扣不得超过原消费金额**；
/// * 拆分消费的退款必须明确分配，单项累计不超过原分配金额。
library;

/// 一条分配记录：某笔消费中属于某个分类的金额。
///
/// 未拆分的单分类消费也有一条 [Allocation]，这样统计代码只有一条路径，
/// 不必到处写「如果没有拆分则……」的分支。
final class Allocation {
  const Allocation({
    required this.id,
    required this.transactionId,
    required this.categoryId,
    required this.amountCents,
  })  : assert(id >= idUnassigned, '分配 ID 不能为负'),
        assert(amountCents > 0, '拆分项金额必须大于 0（指南 3.5.1）');

  /// 尚未落库的占位 ID。
  static const int idUnassigned = 0;

  final int id;

  /// 原消费交易 ID。
  final int transactionId;

  final int categoryId;

  /// 该分类分到的金额（分），恒大于 0。
  final int amountCents;

  @override
  bool operator ==(Object other) =>
      other is Allocation &&
      other.id == id &&
      other.transactionId == transactionId &&
      other.categoryId == categoryId &&
      other.amountCents == amountCents;

  @override
  int get hashCode => Object.hash(id, transactionId, categoryId, amountCents);

  @override
  String toString() =>
      'Allocation($id, tx=$transactionId, cat=$categoryId, $amountCents)';
}

/// 退款与原消费的关联。
///
/// 首版一笔退款对应**一笔**原消费（指南 3.2），因此 `refundTransactionId` 唯一。
/// 反过来说，同一笔原消费可以有多笔退款 —— 这正是
/// 「累计抵扣不得超过原消费金额」需要业务校验的原因。
final class RefundLink {
  const RefundLink({
    required this.id,
    required this.refundTransactionId,
    required this.originalTransactionId,
    required this.amountCents,
  })  : assert(id >= idUnassigned, '退款关联 ID 不能为负'),
        assert(amountCents > 0, '关联金额必须大于 0');

  /// 尚未落库的占位 ID。
  static const int idUnassigned = 0;

  final int id;

  /// 退款交易 ID。
  final int refundTransactionId;

  /// 被退的原消费交易 ID。
  final int originalTransactionId;

  /// 本次关联的抵扣金额（分）。允许小于退款金额 ——
  /// 差额部分属于「未关联」，不能拿来做抵扣。
  final int amountCents;

  @override
  bool operator ==(Object other) => other is RefundLink && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'RefundLink($id, refund=$refundTransactionId → original=$originalTransactionId, $amountCents)';
}

/// 退款分配到**原消费的某个拆分项**上。
///
/// 只有拆分消费的退款才需要它；单分类消费的退款直接抵扣那唯一一条分配。
final class RefundAllocation {
  const RefundAllocation({
    required this.id,
    required this.refundLinkId,
    required this.originalAllocationId,
    required this.amountCents,
  })  : assert(id >= idUnassigned, '退款分配 ID 不能为负'),
        assert(amountCents > 0, '退款分项金额必须大于 0');

  /// 尚未落库的占位 ID。
  static const int idUnassigned = 0;

  final int id;

  final int refundLinkId;

  /// 被抵扣的原分配项 ID。
  final int originalAllocationId;

  final int amountCents;

  @override
  bool operator ==(Object other) => other is RefundAllocation && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'RefundAllocation($id, link=$refundLinkId, alloc=$originalAllocationId, $amountCents)';
}

/// 尚未落库的拆分草稿。
///
/// 界面上的一行拆分项。校验通过后由仓库在一个事务里转成 [Allocation]，
/// 因此草稿本身没有 ID。
final class AllocationDraft {
  const AllocationDraft({required this.categoryId, required this.amountCents});

  final int categoryId;

  /// 用户输入的金额（分）。可能是 0 或负数，校验负责拦住。
  final int amountCents;

  AllocationDraft copyWith({int? categoryId, int? amountCents}) => AllocationDraft(
        categoryId: categoryId ?? this.categoryId,
        amountCents: amountCents ?? this.amountCents,
      );

  @override
  bool operator ==(Object other) =>
      other is AllocationDraft &&
      other.categoryId == categoryId &&
      other.amountCents == amountCents;

  @override
  int get hashCode => Object.hash(categoryId, amountCents);

  @override
  String toString() => 'AllocationDraft(cat=$categoryId, $amountCents)';
}

/// 尚未落库的退款分配草稿：本次要抵扣哪个原拆分项、抵扣多少。
final class RefundAllocationDraft {
  const RefundAllocationDraft({
    required this.originalAllocationId,
    required this.amountCents,
  });

  final int originalAllocationId;

  final int amountCents;

  @override
  bool operator ==(Object other) =>
      other is RefundAllocationDraft &&
      other.originalAllocationId == originalAllocationId &&
      other.amountCents == amountCents;

  @override
  int get hashCode => Object.hash(originalAllocationId, amountCents);

  @override
  String toString() =>
      'RefundAllocationDraft(alloc=$originalAllocationId, $amountCents)';
}
