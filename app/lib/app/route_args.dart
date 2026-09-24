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

/// 分类详情（下钻）参数。
class BreakdownArgs {
  const BreakdownArgs({this.categoryName});

  final String? categoryName;
}
