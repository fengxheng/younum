import 'package:flutter_test/flutter_test.dart';
import 'package:younum/core/preferences/category_pick_store.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/category.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/domain/rules/category_rules.dart';
import 'package:younum/features/organize/category_registry.dart';

/// 用途快捷项：整理卡片上显示**哪几个**分类、按**什么顺序**。
///
/// 为什么值得写：这份列表决定「整理一笔要点哪里」。做成可配置之后，
/// 三条边界必须钉住 ——
///
/// * **默认不变**：没配置过的人看到的还是原来那 8 个内置分类（老用户升级
///   上来不该发现整理页悄悄变了样）；
/// * **存量数据不能被配置弄坏**：归档、合并、删掉的分类留下来的 ID 必须被
///   过滤掉，而不是在卡片上留一格点不动的名字；
/// * **存不下来不能说存好了**：用户调完顺序、下次进来又变回原样，
///   比一次明确的失败提示糟糕得多。
void main() {
  List<Category> allCategories() => DemoLedgerSeed.categories();

  List<String> namesOf(List<Category> categories) => <String>[
    for (final category in categories) category.name,
  ];

  group('规则：把存下来的 ID 解析成真实分类', () {
    test('没配置过时用默认：内置一级分类，顺序就是原来的顺序', () {
      final picked = CategoryRules.resolveQuickPick(
        storedIds: const <int>[],
        all: allCategories(),
      );

      expect(namesOf(picked), <String>[
        '餐饮',
        '购物',
        '交通',
        '居住',
        '娱乐',
        '健康',
        '人情',
        '其他',
      ]);
    });

    test('配置过的顺序与子集照原样生效', () {
      final picked = CategoryRules.resolveQuickPick(
        storedIds: const <int>[
          SeedCategoryIds.transport,
          SeedCategoryIds.food,
          SeedCategoryIds.other,
        ],
        all: allCategories(),
      );

      expect(namesOf(picked), <String>['交通', '餐饮', '其他']);
    });

    test('自建分类能进快捷项；细分用途不能（它从「全部分类」里选）', () {
      final picked = CategoryRules.resolveQuickPick(
        storedIds: const <int>[
          SeedCategoryIds.pets,
          SeedCategoryIds.diningCoffee,
          SeedCategoryIds.study,
        ],
        all: allCategories(),
      );

      expect(namesOf(picked), <String>['宠物', '学习成长']);
    });

    test('归档掉的分类不会留在快捷项里，而且不自动补别的', () {
      final categories = <Category>[
        for (final category in allCategories())
          if (category.id == SeedCategoryIds.food)
            category.copyWith(archived: true)
          else
            category,
      ];

      final picked = CategoryRules.resolveQuickPick(
        storedIds: const <int>[SeedCategoryIds.food, SeedCategoryIds.shopping],
        all: categories,
      );

      expect(namesOf(picked), <String>['购物']);
      expect(
        picked,
        hasLength(1),
        reason: '过滤之后不补位：用户没选过的分类不该自己冒出来',
      );
    });

    test('超过上限只取前 8 个', () {
      // 10 个一级分类（内置 8 个 + 宠物 + 学习成长）全选。
      final picked = CategoryRules.resolveQuickPick(
        storedIds: const <int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
        all: allCategories(),
      );

      expect(picked, hasLength(CategoryRules.quickPickLimit));
      expect(namesOf(picked).first, '餐饮');
      expect(namesOf(picked), isNot(contains('宠物')));
    });

    test('坏掉的配置（重复 ID）不会让同一格出现两次', () {
      final picked = CategoryRules.resolveQuickPick(
        storedIds: const <int>[
          SeedCategoryIds.food,
          SeedCategoryIds.food,
          SeedCategoryIds.shopping,
        ],
        all: allCategories(),
      );

      expect(namesOf(picked), <String>['餐饮', '购物']);
    });
  });

  group('注册表：读取、保存、拒绝的原因', () {
    late LedgerRepository repository;
    late InMemoryCategoryPickStore store;
    late CategoryRegistry registry;

    setUp(() async {
      repository = LedgerRepository(InMemoryLedgerStore());
      await repository.initialize();
      store = InMemoryCategoryPickStore();
      registry = CategoryRegistry(repository: repository, pickStore: store);
      await registry.load(ledgerId: DemoLedgerSeed.demoLedgerId);
    });

    test('默认（没配置过）就是内置那 8 个', () async {
      expect(registry.quickPick, hasLength(CategoryRules.quickPickLimit));
      expect(registry.quickPick.first.name, '餐饮');
    });

    test('保存顺序之后卡片上的顺序跟着变，并且写进了偏好', () async {
      final ok = await registry.setQuickPick(const <int>[
        SeedCategoryIds.health,
        SeedCategoryIds.food,
      ]);

      expect(ok, isTrue);
      expect(namesOf(registry.quickPick), <String>['健康', '餐饮']);
      expect(await store.loadQuickPickIds(), <int>[SeedCategoryIds.health, SeedCategoryIds.food]);
    });

    test('重新加载之后配置还在（模拟重启应用）', () async {
      await registry.setQuickPick(const <int>[SeedCategoryIds.transport]);

      final reopened = CategoryRegistry(repository: repository, pickStore: store);
      await reopened.load(ledgerId: DemoLedgerSeed.demoLedgerId);

      expect(namesOf(reopened.quickPick), <String>['交通']);
    });

    test('存不下来时返回 false，界面上的列表不变', () async {
      final broken = CategoryRegistry(
        repository: repository,
        pickStore: _ThrowingPickStore(),
      );
      await broken.load(ledgerId: DemoLedgerSeed.demoLedgerId);

      final ok = await broken.setQuickPick(const <int>[SeedCategoryIds.health]);

      expect(ok, isFalse, reason: '存不下来就不能说存好了');
      expect(broken.lastFailure, isNotNull, reason: '要有一句能给用户看的原因');
      expect(namesOf(broken.quickPick).first, '餐饮', reason: '列表保持原样');
    });

    test('加满之后，再加人会被拒并给出原因', () async {
      // 默认就是满的（8 个）。
      expect(
        registry.quickPickBlockedReason(SeedCategoryIds.pets),
        contains('最多 8 个'),
      );
      // 移掉一个之后就能加了。
      await registry.setQuickPick(const <int>[SeedCategoryIds.food]);
      expect(registry.quickPickBlockedReason(SeedCategoryIds.pets), isNull);
    });

    test('偏好读不出来时不崩，退回默认列表', () async {
      final broken = CategoryRegistry(
        repository: repository,
        pickStore: _ThrowingReadStore(),
      );

      await broken.load(ledgerId: DemoLedgerSeed.demoLedgerId);

      expect(broken.quickPick, hasLength(CategoryRules.quickPickLimit));
      expect(broken.isLoaded, isTrue);
    });
  });
}

/// 保存永远失败（磁盘满 / 偏好写不进去）。
final class _ThrowingPickStore implements CategoryPickStore {
  @override
  Future<List<int>> loadQuickPickIds() async => const <int>[];

  @override
  Future<void> saveQuickPickIds(List<int> ids) async =>
      throw StateError('偏好写不进去');
}

/// 读取永远失败。
final class _ThrowingReadStore implements CategoryPickStore {
  @override
  Future<List<int>> loadQuickPickIds() async => throw StateError('偏好读不出来');

  @override
  Future<void> saveQuickPickIds(List<int> ids) async {}
}
