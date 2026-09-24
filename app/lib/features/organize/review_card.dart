/// 整理卡片：给界面用的展示模型。
///
/// 界面不该直接依赖交易记录的存储字段（毫秒时间戳、来源命名空间、分类 ID）。
/// 把它们集中翻译成「显示成什么」之后：
///
/// * 换存储、改文案都不需要动十几个页面；
/// * 金额仍然以「分」传递，格式化只发生在 `AmountText` 里，不会中途变成浮点。
library;

import '../../core/designsystem/younum_icons.dart';
import '../../core/time/statistics_time.dart';
import '../../domain/models/allocation.dart';
import '../../domain/models/category.dart';
import '../../domain/models/ledger_source.dart';
import '../../domain/models/ledger_transaction.dart';

/// 一张卡片。
final class ReviewCard {
  const ReviewCard({
    required this.transaction,
    this.category,
    this.allocations = const <Allocation>[],
  });

  final LedgerTransaction transaction;

  /// 已归类的分类。未归类时为 null。
  final Category? category;

  /// 该笔的**全部**分配。拆分后有多条，也是拆分页回填的依据。
  final List<Allocation> allocations;

  /// 第一条分配。单分类消费就是它，拆分时只是其中一条。
  Allocation? get allocation =>
      allocations.isEmpty ? null : allocations.first;

  int get id => transaction.id;

  String get merchant => transaction.merchant;

  int get amountCents => transaction.amountCents;

  /// 形如 `09.23 · 14:26`。
  String get dateText => StatisticsTime.formatShort(transaction.occurredAtMs);

  /// 来源展示名，例如「微信支付」。
  String get source => LedgerSource.labelOf(transaction.sourceNamespace);

  /// 分类名称。未归类时为 null。
  String? get categoryName => category?.name;

  /// 分类图标键。未归类时用默认图标，保证卡片永远有一个可画的图标。
  String get categoryIconKey =>
      category?.iconKey ?? YounumIcons.defaultCategoryIconKey;

  bool get isResolved => transaction.reviewStatus == ReviewStatus.resolved;

  bool get isDeferred => transaction.reviewStatus == ReviewStatus.deferred;

  @override
  String toString() => 'ReviewCard($id, $merchant, $amountCents)';
}

/// 一条已经完成整理的记录。
final class ReviewDoneEntry {
  const ReviewDoneEntry({required this.card, required this.category});

  final ReviewCard card;

  /// 确认后所属的分类名称。
  final String category;

  LedgerTransaction get transaction => card.transaction;

  @override
  String toString() => 'ReviewDoneEntry(${card.id}, $category)';
}
