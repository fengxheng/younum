/// 拆分与分配的校验规则。
///
/// 指南 3.5.1：**消费的 `Allocation` 合计必须精确等于原消费金额，每项大于 0。**
///
/// 这里只做校验，不碰数据库。仓库层在事务里先调用它、再写盘，
/// 保证「界面上允许提交的」和「数据库接受的」是同一套判断。
library;

import '../../core/money/money.dart';
import '../models/allocation.dart';

/// 分配校验失败的原因。
///
/// 用独立类型而不是一句字符串：界面要据此决定把错误标在哪一行
/// （例如 [AllocationItemNotPositive] 会高亮具体那一项）。
sealed class AllocationError {
  const AllocationError(this.message);

  final String message;
}

/// 原消费金额本身不合法。
final class AllocationSourceNotPositive extends AllocationError {
  const AllocationSourceNotPositive()
      : super('原消费金额必须大于 0，无法拆分');
}

/// 一项都没有。
final class AllocationItemsEmpty extends AllocationError {
  const AllocationItemsEmpty() : super('至少需要一项分类');
}

/// 第 [index] 项金额不合法。
final class AllocationItemNotPositive extends AllocationError {
  const AllocationItemNotPositive(this.index) : super('每一项金额都要大于 0');

  /// 从 0 开始的下标，界面用它定位到出错的那一行。
  final int index;
}

/// 同一分类出现了多次。
final class AllocationDuplicateCategory extends AllocationError {
  const AllocationDuplicateCategory(this.categoryId)
      : super('同一分类不能重复出现，请合并后再提交');

  final int categoryId;
}

/// 合计与原金额不一致。
final class AllocationSumMismatch extends AllocationError {
  const AllocationSumMismatch({required this.expected, required this.actual})
      : super('各项合计必须精确等于原金额');

  /// 原金额（分）。
  final int expected;

  /// 各项合计（分）。
  final int actual;

  /// 差额（分）。正数表示还差这么多，负数表示多出来。
  int get differenceCents => expected - actual;
}

/// 合计溢出，超出可安全表示的范围。
final class AllocationAmountOverflow extends AllocationError {
  const AllocationAmountOverflow() : super('合计金额超出可处理范围');
}

/// 分配规则。
abstract final class AllocationRules {
  /// 校验一组拆分项。
  ///
  /// 返回 null 表示可以提交。检查顺序是「先单项、后合计」：
  /// 用户必须先修好具体那一行，合计才有意义。
  static AllocationError? validate({
    required int originalCents,
    required List<AllocationDraft> items,
  }) {
    if (originalCents <= 0) return const AllocationSourceNotPositive();
    if (items.isEmpty) return const AllocationItemsEmpty();

    final seenCategories = <int>{};
    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      if (item.amountCents <= 0) return AllocationItemNotPositive(index);
      if (!seenCategories.add(item.categoryId)) {
        return AllocationDuplicateCategory(item.categoryId);
      }
    }

    final total = Money.addAll(items.map((item) => item.amountCents));
    if (total == null) return const AllocationAmountOverflow();
    if (total != originalCents) {
      return AllocationSumMismatch(expected: originalCents, actual: total);
    }
    return null;
  }

  /// 未拆分消费的隐式分配：整笔归一个分类。
  static List<AllocationDraft> singleCategory(int categoryId, int cents) =>
      <AllocationDraft>[AllocationDraft(categoryId: categoryId, amountCents: cents)];

  /// 只求和，不校验。界面用它显示实时「合计」。
  ///
  /// 返回 null 表示溢出。
  static int? totalOf(Iterable<AllocationDraft> items) =>
      Money.addAll(items.map((item) => item.amountCents));
}
