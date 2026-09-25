/// 分类的校验规则（指南 3.5.8 / 14.3）。
///
/// 与退款规则一样：纯函数、不依赖 Flutter，仓库层在写库前调用，
/// 界面用它先把话说清楚（而不是等写库失败再报错）。
///
/// 同级的唯一性数据库上还有 `idx_category_parent_name` 唯一索引兜底，
/// 这里检查是为了给出人能看懂的原因。
library;

import '../models/category.dart';

/// 分类校验失败的原因。
sealed class CategoryError {
  const CategoryError(this.message);

  final String message;
}

/// 名称为空。
final class CategoryNameEmpty extends CategoryError {
  const CategoryNameEmpty() : super('请先填写分类名称');
}

/// 名称太长。
final class CategoryNameTooLong extends CategoryError {
  const CategoryNameTooLong()
      : super('名称限 1–12 个文字、数字、空格或短横线');
}

/// 名称里有不支持的字符。
final class CategoryNameInvalid extends CategoryError {
  const CategoryNameInvalid()
      : super('名称限 1–12 个文字、数字、空格或短横线');
}

/// 同级已经有了同名分类。
final class CategoryNameDuplicated extends CategoryError {
  const CategoryNameDuplicated() : super('这个分类已经存在');
}

/// 分类规则。
abstract final class CategoryRules {
  /// 名称长度上限（与原型校验一致）。
  static const int maxNameLength = 12;

  /// 允许的字符：文字、数字、空格、短横线。
  static final RegExp _allowed =
      RegExp(r'^[\p{L}\p{N} _-]{1,12}$', unicode: true);

  /// 校验一个分类名。
  ///
  /// [siblings] 是**同一层级**的分类：[excludingId] 用来在改自己的名字时
  /// 把自己排除掉，否则「改成原名」会被自己挡住。
  static CategoryError? validateName({
    required String name,
    required List<Category> siblings,
    int? excludingId,
  }) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return const CategoryNameEmpty();
    if (trimmed.runes.length > maxNameLength) return const CategoryNameTooLong();
    if (!_allowed.hasMatch(trimmed)) return const CategoryNameInvalid();

    for (final sibling in siblings) {
      if (excludingId != null && sibling.id == excludingId) continue;
      if (sibling.name == trimmed) return const CategoryNameDuplicated();
    }
    return null;
  }
}
