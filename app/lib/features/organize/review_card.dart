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

  /// 交易性质（消费 / 收入 / 转账 / 退款 / 排除统计 / 待判断）。
  ///
  /// 方向只能由它表达 —— 金额一律存非负绝对值（指南 3.1），
  /// 所以界面上任何「钱进 / 钱出」的判断都要走这里。
  TransactionNature get nature => transaction.nature;

  /// 形如 `09.23 · 14:26`。
  String get dateText => StatisticsTime.formatShort(transaction.occurredAtMs);

  /// 来源展示名，例如「微信支付」。
  String get source => LedgerSource.labelOf(transaction.sourceNamespace);

  /// 分类名称。未归类时为 null。
  String? get categoryName => category?.name;

  /// 分类图标键。未归类时用默认图标，保证卡片永远有一个可画的图标。
  String get categoryIconKey =>
      category?.iconKey ?? YounumIcons.defaultCategoryIconKey;

  /// 卡片上那枚徽标的词：这笔钱是**出**还是**进**。
  ///
  /// ⚠️ **必须看交易性质，不能写死「支出」。** 收入行也会进整理队列
  /// （导入时按账单的「收/支」列判定性质），而金额一律存**非负绝对值**、
  /// 方向只能由性质表达（指南 3.1）—— 写死之后，一张收入卡片会顶着
  /// 「支出」把 ¥5,000.00 摆在那儿，而同一笔在「全部明细」里写着
  /// 「收入 · +¥5,000.00」，两处自相矛盾。
  ///
  /// 词取自 [TransactionNature.label]（明细页与撤销日志用的是同一套词），
  /// **只有消费例外**：设计稿在卡片上写的是「支出」，不是「消费」。
  String get directionLabel =>
      nature == TransactionNature.expense ? '支出' : nature.label;

  /// 原始单号的显示文本：**只露后四位**（设计稿里那个 `•••• 0826` 就是这个意思）。
  ///
  /// ⚠️ 这里是**读数据**，不是常量。以前详情页写死 `•••• 0826`，
  /// 于是每一笔都显示同一个单号，而「交易类型」还一律写着「商户消费」——
  /// 一笔收入点进去看到的是「商户消费」。
  ///
  /// 拿不到单据号（手工补录、账单没这一列）就如实说「账单未提供」，
  /// 不摆一个样例值（指南 6.1：不撒谎）。
  String get sourceIdText {
    final id = transaction.sourceTransactionId;
    if (id == null || id.isEmpty) return '账单未提供';
    return '•••• ${id.length <= 4 ? id : id.substring(id.length - 4)}';
  }

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
