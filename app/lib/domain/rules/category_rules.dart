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

/// 只剩这一个分类了，不能再归档。
///
/// 用途选择列表不能空：空了用户整理时无从下手，而且那不是用户想要的 ——
/// 他只是想删掉一个分类。
final class CategoryLastRoot extends CategoryError {
  const CategoryLastRoot() : super('这是最后一个分类，删掉就没有用途可选了');
}

/// 合并时选了自己。
final class CategoryMergeSelf extends CategoryError {
  const CategoryMergeSelf() : super('不能合并到自己');
}

/// 合并的目标不存在（刚被别处删掉 / 恢复）。
final class CategoryMergeTargetMissing extends CategoryError {
  const CategoryMergeTargetMissing() : super('找不到要合并到的分类');
}

/// 合并的目标已经归档。
///
/// 归档的分类不在用途列表里，把账目迁过去等于让它们「从此选不到」——
/// 用户要的是把两个分类合成一个，不是把账藏起来。
final class CategoryMergeTargetArchived extends CategoryError {
  const CategoryMergeTargetArchived()
      : super('不能合并到已归档的分类，先把它恢复出来');
}

/// 跨层级 / 跨父级合并。
///
/// 一级只能并进一级，细分只能并进**同一个父级下**的细分：
/// 「把一级分类并进别人的细分用途」在语义上说不通 ——
/// 迁移之后那笔账会挂在别人的子节点下，用户根本找不到它。
final class CategoryMergeLevelMismatch extends CategoryError {
  const CategoryMergeLevelMismatch() : super('只能合并到同一层级的分类');
}

/// 源分类下面还有细分用途。
///
/// 合并只迁移**直接挂在源分类上**的分配，不会动它的细分用途 ——
/// 那些账会留在一个已经归档的父级下，变成用户看不见也点不到的角落。
/// 与其默默把账藏起来，不如让用户先把子级处理掉（归档或合并都可以）。
final class CategoryMergeHasChildren extends CategoryError {
  const CategoryMergeHasChildren()
      : super('这个分类下面还有细分用途，先把它们合并或归档再合并这个分类');
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

  /// 能不能归档 / 恢复这个分类（指南 3.5.8）。
  ///
  /// 只有一条限制：**不能把最后一个还在用的一级分类归档掉** ——
  /// 那样「选择用途」就空了，用户整理时无从下手。细分用途不受限：
  /// 它们的父级还在，只是少一个选项。
  ///
  /// 恢复永远允许：归档的分类本来就不参与这条判断。
  static CategoryError? validateArchive({
    required Category category,
    required List<Category> all,
  }) {
    if (category.archived) return null;
    if (!category.isRoot) return null;

    final remaining = <Category>[
      for (final item in all)
        if (item.isRoot && !item.archived && item.id != category.id) item,
    ];
    if (remaining.isEmpty) return const CategoryLastRoot();
    return null;
  }

  /// 卡片上的用途快捷项最多几个。
  ///
  /// 8 个 = 两行（每行四个）。这个数**不是随便定的**：确认按钮与
  /// 「撤销 / 稍后 / 更多操作」那一行必须在不滚动的情况下可见
  /// （指南 6.2「核心确认区尽量稳定可达」），排到第三行就会把它们推到
  /// 折叠线以下。所以用户可以自定义**是哪 8 个、按什么顺序**，但不能无限加。
  static const int quickPickLimit = 8;

  /// 把存下来的快捷项 ID 解析成真实分类（**有序**）。
  ///
  /// 为什么需要这一步：偏好里存的是 ID，而分类会被改名、归档、合并掉 ——
  /// 那时剩下的 ID 指向一个不该再出现在选择列表里的分类。在这里统一过滤，
  /// 卡片页与管理页看到的就是同一份。
  ///
  /// * [storedIds] 为空 = 用户**没配置过** → 用默认（内置一级分类，即原来的行为）；
  /// * 过滤掉：已归档、不存在、不是一级分类、以及重复的 ID；
  /// * 过滤后个数不足时**不自动补**别的分类 —— 用户没选过的东西不该自己冒出来。
  static List<Category> resolveQuickPick({
    required List<int> storedIds,
    required List<Category> all,
    int limit = quickPickLimit,
  }) {
    if (storedIds.isEmpty) {
      return <Category>[
        for (final category in all)
          if (category.isRoot && !category.archived && category.isBuiltin) category,
      ].take(limit).toList(growable: false);
    }

    final byId = <int, Category>{
      for (final category in all)
        if (category.isRoot && !category.archived) category.id: category,
    };
    final picked = <Category>[];
    for (final id in storedIds) {
      final category = byId[id];
      if (category == null) continue;
      if (picked.any((item) => item.id == id)) continue;
      picked.add(category);
      if (picked.length >= limit) break;
    }
    return List<Category>.unmodifiable(picked);
  }

  /// 能不能把 [source] 合并到 [targetId]（指南 3.5.8）。
  ///
  /// 同名/同层级的重名检查不在这里：合并本来就是为了把两个不同的名字合成一个，
  /// 而重名在同一个父级下根本建不出来（`idx_category_parent_name` 唯一索引）。
  ///
  /// 源分类**可以是已归档的**：归档列表里那些清理不掉的分类，
  /// 合并掉它们正是用户想要的。
  ///
  /// 检查顺序是「先源后目标」：源自己就有问题（下面还有细分用途）时，
  /// 报那一句更有用 —— 它才是用户真正要先去处理的东西。
  static CategoryError? validateMerge({
    required Category source,
    required List<Category> all,
    required int? targetId,
  }) {
    final sourceError = mergeSourceBlocked(source: source, all: all);
    if (sourceError != null) return sourceError;

    if (targetId == null) return const CategoryMergeTargetMissing();
    if (targetId == source.id) return const CategoryMergeSelf();

    Category? target;
    for (final category in all) {
      if (category.id == targetId) target = category;
    }
    if (target == null) return const CategoryMergeTargetMissing();
    if (target.archived) return const CategoryMergeTargetArchived();
    // 同一父级才叫同一层级：两个一级分类的 parentId 都是 null。
    if (target.parentId != source.parentId) {
      return const CategoryMergeLevelMismatch();
    }
    return null;
  }

  /// 只检查**源分类自己**能不能当合并的源。
  ///
  /// 拆出来是因为界面要分两句问：「这个分类能不能合并」（本函数）
  /// 与「能并到哪里」（[mergeTargets]）。合成一句的话，
  /// 源分类自己没问题、只是没别的分类可并时，界面只能报出一句错的话。
  static CategoryError? mergeSourceBlocked({
    required Category source,
    required List<Category> all,
  }) {
    for (final category in all) {
      // 已归档的子级不挡路：它本来就不在用途列表里，
      // 归档父级时它们已经跟着归档过了。
      if (category.parentId == source.id && !category.archived) {
        return const CategoryMergeHasChildren();
      }
    }
    return null;
  }

  /// 可以合并到的候选目标（界面用它出选择列表）。
  ///
  /// 规则只有一份：这里逐个调用 [validateMerge]，界面因此不可能给出一个
  /// 「点下去会被拒」的选项。
  static List<Category> mergeTargets({
    required Category source,
    required List<Category> all,
  }) => <Category>[
    for (final category in all)
      if (category.isRoot == source.isRoot &&
          category.parentId == source.parentId &&
          validateMerge(source: source, all: all, targetId: category.id) ==
              null)
        category,
  ];
}
