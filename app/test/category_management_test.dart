import 'package:flutter_test/flutter_test.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/category.dart';
import 'package:younum/domain/models/year_month.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/domain/rules/category_rules.dart';

/// 分类管理（指南 3.5.8 / 14.3）。
///
/// 这一块之前是内存实现，有两个真实缺陷：新建的分类重启就没了，
/// 而且**整理时根本选不到它** —— 分配要的是真实的分类 ID，而那条分类
/// 在库里不存在。这些用例锁住「真的落库、真的能用来归类」。
void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;

  const int ledgerId = DemoLedgerSeed.demoLedgerId;

  setUp(() async {
    store = InMemoryLedgerStore();
    repository = LedgerRepository(store);
    await repository.initialize();
  });

  Future<List<Category>> categories() =>
      repository.categories(ledgerId: ledgerId);

  group('名称规则', () {
    const roots = <Category>[
      Category(
        id: 1,
        name: '餐饮',
        iconType: CategoryIconType.builtin,
        iconKey: 'food',
        sortOrder: 1,
        isBuiltin: true,
      ),
    ];

    test('空名字、太长、不支持的字符都被拒', () {
      expect(
        CategoryRules.validateName(name: '   ', siblings: roots),
        isA<CategoryNameEmpty>(),
      );
      expect(
        CategoryRules.validateName(
          name: '一二三四五六七八九十十一十二三',
          siblings: roots,
        ),
        isA<CategoryNameTooLong>(),
      );
      expect(
        CategoryRules.validateName(name: 'a/b', siblings: roots),
        isA<CategoryNameInvalid>(),
      );
    });

    test('同级重名被拒，但自己不算重名（改自己的名字时要用排除）', () {
      expect(
        CategoryRules.validateName(name: '餐饮', siblings: roots),
        isA<CategoryNameDuplicated>(),
      );
      expect(
        CategoryRules.validateName(name: '餐饮', siblings: roots, excludingId: 1),
        isNull,
      );
    });

    test('不同层级可以重名', () {
      expect(CategoryRules.validateName(name: '咖啡茶饮', siblings: roots), isNull);
    });
  });

  group('落库', () {
    test('新建分类真的进分类表，并排在同级最后', () async {
      final before = await categories();

      final result = await repository.createCategory(
        ledgerId: ledgerId,
        name: '养花',
        iconKey: 'leaf',
      );

      expect(result, isA<CategorySaved>(), reason: '$result');
      final saved = (result as CategorySaved).category;
      expect(saved.id, isNot(Category.idUnassigned), reason: '要有稳定的 ID');
      expect(saved.isBuiltin, isFalse, reason: '用户建的分类不是内置的');

      final after = await categories();
      expect(after, hasLength(before.length + 1));
      final roots = <Category>[
        for (final category in after)
          if (category.isRoot) category,
      ];
      expect(roots.last.name, '养花', reason: '新建的分类排在一级分类的最后');
      expect(
        roots.last.sortOrder,
        greaterThan(roots[roots.length - 2].sortOrder),
      );
    });

    test('同级重名被明确拒绝，而且什么都没写', () async {
      final before = await categories();

      final result = await repository.createCategory(
        ledgerId: ledgerId,
        name: '餐饮',
        iconKey: 'leaf',
      );

      expect(result, isA<CategoryRejected>());
      expect(
        (result as CategoryRejected).message,
        contains('已经存在'),
        reason: '这句话要给用户看，不能是数据库错误',
      );
      expect(await categories(), hasLength(before.length));
    });

    test('改图标只改图标：名字、ID、排序都不动', () async {
      final target = (await categories()).firstWhere((c) => c.name == '餐饮');

      final result = await repository.setCategoryIcon(
        ledgerId: ledgerId,
        categoryId: target.id,
        iconKey: 'coffee',
      );

      expect(result, isA<CategorySaved>(), reason: '$result');
      final saved = (result as CategorySaved).category;
      expect(saved.iconKey, 'coffee');
      expect(saved.name, target.name);
      expect(saved.id, target.id);
      expect(saved.sortOrder, target.sortOrder);
      expect(saved.isBuiltin, isTrue);
    });

    test('找不到分类时明确拒绝', () async {
      final result = await repository.setCategoryIcon(
        ledgerId: ledgerId,
        categoryId: 99999,
        iconKey: 'leaf',
      );

      expect(result, isA<CategoryRejected>());
      expect((result as CategoryRejected).message, contains('找不到'));
    });

    test('新建的分类可以真的用来归类（之前选不到它的原因）', () async {
      final created = await repository.createCategory(
        ledgerId: ledgerId,
        name: '养花',
        iconKey: 'leaf',
      );
      expect(created, isA<CategorySaved>());
      final categoryId = (created as CategorySaved).category.id;

      final snapshot = await repository.loadSnapshot(
        ledgerId: ledgerId,
        month: DemoLedgerSeed.month,
      );
      final card = snapshot.current!;

      final outcome = await repository.confirm(
        ledgerId: ledgerId,
        month: DemoLedgerSeed.month,
        transactionId: card.id,
        categoryId: categoryId,
      );
      expect(outcome, isA<ReviewSucceeded>(), reason: '$outcome');

      final dataset = await repository.dataset(
        ledgerId: ledgerId,
        months: <YearMonth>{DemoLedgerSeed.month},
      );
      expect(dataset.allocationsOf(card.id).single.categoryId, categoryId);
    });
  });

  group('归档（指南 3.5.8：删除默认归档）', () {
    test('规则：最后一个还在用的一级分类不能归档，细分用途不受限', () {
      const onlyRoot = <Category>[
        Category(
          id: 1,
          name: '餐饮',
          iconType: CategoryIconType.builtin,
          iconKey: 'food',
          sortOrder: 1,
          isBuiltin: true,
        ),
        Category(
          id: 2,
          parentId: 1,
          name: '咖啡茶饮',
          iconType: CategoryIconType.builtin,
          iconKey: 'coffee',
          sortOrder: 1,
          isBuiltin: true,
        ),
      ];
      expect(
        CategoryRules.validateArchive(category: onlyRoot[0], all: onlyRoot),
        isA<CategoryLastRoot>(),
        reason: '只剩一个一级分类时归档它，用途列表就空了',
      );
      expect(
        CategoryRules.validateArchive(category: onlyRoot[1], all: onlyRoot),
        isNull,
        reason: '细分用途可以归档，父级还在',
      );

      const twoRoots = <Category>[
        Category(
          id: 1,
          name: '餐饮',
          iconType: CategoryIconType.builtin,
          iconKey: 'food',
          sortOrder: 1,
          isBuiltin: true,
        ),
        Category(
          id: 3,
          name: '养花',
          iconType: CategoryIconType.builtin,
          iconKey: 'leaf',
          sortOrder: 2,
          isBuiltin: false,
        ),
      ];
      expect(
        CategoryRules.validateArchive(category: twoRoots[0], all: twoRoots),
        isNull,
      );
      // 已经归档的再归档一次不算错（恢复那条路也走这个判断）。
      expect(
        CategoryRules.validateArchive(
          category: twoRoots[0].copyWith(archived: true),
          all: twoRoots,
        ),
        isNull,
      );
    });

    test('归档真的落库，而且归档后不再出现在用途列表里', () async {
      final created = await repository.createCategory(
        ledgerId: ledgerId,
        name: '养花',
        iconKey: 'leaf',
      );
      final categoryId = (created as CategorySaved).category.id;

      final result = await repository.setCategoryArchived(
        ledgerId: ledgerId,
        categoryId: categoryId,
        archived: true,
      );
      expect(result, isA<CategorySaved>(), reason: '$result');
      expect((result as CategorySaved).category.archived, isTrue);

      final after = await categories();
      final archived = after.firstWhere((item) => item.id == categoryId);
      expect(archived.archived, isTrue, reason: '重启后仍要记得它被归档了');

      // 用途选择读的是「未归档」的那一份。
      final pickable = <Category>[
        for (final category in after)
          if (category.isRoot && !category.archived) category,
      ];
      expect(
        pickable.map((category) => category.id),
        isNot(contains(categoryId)),
      );
    });

    test('归档不动已有记录：用途、金额与统计都照旧', () async {
      // 这是这条需求的核心：**历史引用继续有效**。
      final snapshot = await repository.loadSnapshot(
        ledgerId: ledgerId,
        month: DemoLedgerSeed.month,
      );
      final card = snapshot.current!;
      final all = await categories();
      final categoryId = all.firstWhere((item) => item.isRoot).id;

      final confirmed = await repository.confirm(
        ledgerId: ledgerId,
        month: DemoLedgerSeed.month,
        transactionId: card.id,
        categoryId: categoryId,
      );
      expect(confirmed, isA<ReviewSucceeded>(), reason: '$confirmed');

      final archived = await repository.setCategoryArchived(
        ledgerId: ledgerId,
        categoryId: categoryId,
        archived: true,
      );
      expect(archived, isA<CategorySaved>(), reason: '$archived');

      final dataset = await repository.dataset(
        ledgerId: ledgerId,
        months: <YearMonth>{DemoLedgerSeed.month},
      );
      expect(
        dataset.allocationsOf(card.id).single.categoryId,
        categoryId,
        reason: '归档不能让已有的分配消失',
      );
      expect(
        dataset.categories.map((category) => category.id),
        contains(categoryId),
        reason: '分类本身还在，只是不再可选',
      );
    });

    test('归档一级分类会连带归档它的细分用途，恢复时一起回来', () async {
      // 细分用途只能从父级进入：父级归档后它们就成了「选不到但还挂在
      // 全部分类页上」的幽灵条目（那一页读的是扁平列表）。
      final before = await categories();
      final root = before.firstWhere(
        (category) => category.isRoot && category.isBuiltin,
      );
      final children = <Category>[
        for (final category in before)
          if (category.parentId == root.id) category,
      ];
      expect(children, isNotEmpty, reason: '内置分类应该有细分用途，否则这条测不到东西');

      final result = await repository.setCategoryArchived(
        ledgerId: ledgerId,
        categoryId: root.id,
        archived: true,
      );
      expect(result, isA<CategorySaved>(), reason: '$result');

      final after = await categories();
      for (final child in children) {
        final now = after.firstWhere((item) => item.id == child.id);
        expect(now.archived, isTrue, reason: '${child.name} 应跟着父级一起归档');
      }

      final restored = await repository.setCategoryArchived(
        ledgerId: ledgerId,
        categoryId: root.id,
        archived: false,
      );
      expect(restored, isA<CategorySaved>(), reason: '$restored');

      final back = await categories();
      for (final child in children) {
        final now = back.firstWhere((item) => item.id == child.id);
        expect(now.archived, isFalse, reason: '恢复父级时 ${child.name} 也回来');
      }
    });

    test('最后一个一级分类被明确拒绝，而且什么都没写', () async {
      final all = await categories();
      final roots = <Category>[
        for (final category in all)
          if (category.isRoot) category,
      ];
      // 把除第一个之外的一级分类都归档掉（可能连带细分用途）。
      for (final root in roots.skip(1)) {
        await repository.setCategoryArchived(
          ledgerId: ledgerId,
          categoryId: root.id,
          archived: true,
        );
      }

      final result = await repository.setCategoryArchived(
        ledgerId: ledgerId,
        categoryId: roots.first.id,
        archived: true,
      );
      expect(result, isA<CategoryRejected>());
      expect((result as CategoryRejected).message, contains('最后一个分类'));

      final after = await categories();
      expect(
        after.firstWhere((item) => item.id == roots.first.id).archived,
        isFalse,
        reason: '被拒之后库里的状态不能变',
      );
    });
  });
}

