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
}

