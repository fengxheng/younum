/// 路由参数。
///
/// 只为小参数建模：交易 ID、分类名、调用目的等。**不**传完整账单对象或文件字节
/// （实现指南 2.3.2）。
library;

/// 进入分类选择页的调用目的。
///
/// 指南 5.1：分类选择需带调用目的，返回时必须回到正确的调用方，
/// 不能全部跳回卡片页。
enum CategoryPickPurpose {
  /// 为当前卡片选择用途。
  card,

  /// 编辑交易详情里的用途。
  detail,

  /// 编辑拆分项。
  splitItem,
}

/// 分类选择参数。
class CategoryPickArgs {
  const CategoryPickArgs({
    required this.purpose,
    this.currentCategory,
    this.transactionId,
  });

  final CategoryPickPurpose purpose;
  final String? currentCategory;
  final String? transactionId;
}

/// 进入「选择账单文件」时带上的来源。
///
/// 来源会进入**同源去重键**（命名空间 + 账户 + 稳定源交易 ID），
/// 所以不能三条入口都用同一个值 —— 否则同一单号的微信与支付宝记录
/// 会被当成同一笔，而不同来源的同一单号本来就不是一回事。
class ImportSourceArgs {
  const ImportSourceArgs({required this.sourceNamespace, this.title});

  /// 写进 `import_batch.source_namespace` 的值。
  final String sourceNamespace;

  /// 页面标题用的名字，例如「微信支付」。
  final String? title;
}

/// 分类图标编辑器参数。
class CategoryEditorArgs {
  const CategoryEditorArgs({required this.categoryName, this.returnRoute});

  /// 为 null 表示新建分类；非 null 表示只编辑该分类的图标。
  final String? categoryName;

  /// 保存后返回的路由，用于「管理图标」与「分类管理」两个入口。
  final String? returnRoute;
}

/// 交易详情参数。
class TransactionDetailArgs {
  const TransactionDetailArgs({this.transactionId});

  final String? transactionId;
}

/// 拆分参数。
///
/// 必须带交易 ID：拆分页要展示并修改**具体那一笔**，
/// 而「当前卡片」在从明细 / 详情页进来时并不是它。
class SplitArgs {
  const SplitArgs({required this.transactionId});

  final int transactionId;
}

/// 明细检索参数。
///
/// 指南 10.3 要求「按分类下钻只显示对应明细」，所以从分类详情进入明细时
/// 必须带上分类名，而不是打开一个没有筛选的全部明细。
class TransactionsArgs {
  const TransactionsArgs({this.categoryName});

  /// 进入时预先应用的分类筛选。
  final String? categoryName;
}

/// 分类详情（下钻）参数。
class BreakdownArgs {
  const BreakdownArgs({this.categoryName});

  final String? categoryName;
}
