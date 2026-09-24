import 'package:flutter_test/flutter_test.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/allocation.dart';
import 'package:younum/domain/models/year_month.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/features/organize/review_session.dart';

import 'support/ledger_fixtures.dart';

/// 拆分一笔消费。
///
/// 指南 3.5：不复制原交易（账单笔数不变）、每项大于 0、合计**精确等于**
/// 原始金额；指南 3.5.6：已经有退款关联的消费不能直接改变拆分结构。
///
/// 这里走的是真仓库（后端换成内存存储），所以同时也是「界面经过的那条路径」
/// 的断言 —— 拆分与「重新归类」共用同一条写路径（版本校验 + 撤销日志）。
void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late ReviewSession session;

  final YearMonth month = DemoLedgerSeed.month;
  const int ledgerId = DemoLedgerSeed.demoLedgerId;

  setUp(() async {
    store = InMemoryLedgerStore();
    repository = LedgerRepository(store);
    await repository.initialize();
    session = ReviewSession(repository: repository);
    await session.useLedger(isDemo: true);
  });

  tearDown(() {
    session.dispose();
  });

  Future<List<Allocation>> allocationsOf(int transactionId) async {
    final dataset = await repository.dataset(ledgerId: ledgerId);
    return dataset.allocationsOf(transactionId);
  }

  test('拆分把一笔写成多条分配，账单笔数不变', () async {
    final card = session.current!;
    expect(card.merchant, 'MANNER COFFEE');
    expect(card.amountCents, 2800);

    final ok = await session.splitTransaction(
      transactionId: card.id,
      items: <AllocationDraft>[
        const AllocationDraft(categoryId: SeedCategoryIds.diningCoffee, amountCents: 1800),
        const AllocationDraft(categoryId: SeedCategoryIds.food, amountCents: 1000),
      ],
    );

    expect(ok, isTrue);
    final dataset = await repository.dataset(ledgerId: ledgerId);
    expect(dataset.transactions, hasLength(6), reason: '拆分不复制原交易');

    final allocations = dataset.allocationsOf(card.id);
    expect(
      allocations.map((allocation) => allocation.amountCents).toList()..sort(),
      <int>[1000, 1800],
    );
    // 拆分后这笔算处理完了：它不再留在待整理队列里。
    expect(session.doneCount, 1);
  });

  test('合计不等于原始金额时被拒，且一条分配都不写', () async {
    final card = session.current!;

    final outcome = await repository.split(
      ledgerId: ledgerId,
      month: month,
      transactionId: card.id,
      items: <AllocationDraft>[
        const AllocationDraft(categoryId: SeedCategoryIds.food, amountCents: 1800),
      ],
    );

    expect(outcome, isA<ReviewRejected>());
    expect(await allocationsOf(card.id), isEmpty);
  });

  test('有 0 元项时被拒', () async {
    final card = session.current!;

    final outcome = await repository.split(
      ledgerId: ledgerId,
      month: month,
      transactionId: card.id,
      items: <AllocationDraft>[
        const AllocationDraft(categoryId: SeedCategoryIds.food, amountCents: 2800),
        const AllocationDraft(categoryId: SeedCategoryIds.shopping, amountCents: 0),
      ],
    );

    expect(outcome, isA<ReviewRejected>());
    expect(await allocationsOf(card.id), isEmpty);
  });

  test('同一分类重复出现时被拒', () async {
    final card = session.current!;

    final outcome = await repository.split(
      ledgerId: ledgerId,
      month: month,
      transactionId: card.id,
      items: <AllocationDraft>[
        const AllocationDraft(categoryId: SeedCategoryIds.food, amountCents: 1400),
        const AllocationDraft(categoryId: SeedCategoryIds.food, amountCents: 1400),
      ],
    );

    expect(outcome, isA<ReviewRejected>());
    expect(await allocationsOf(card.id), isEmpty);
  });

  test('已经有退款关联的消费不能改拆分结构（指南 3.5.6）', () async {
    final card = session.current!;

    // 先归类，再挂一笔退款关联。
    session.select('餐饮');
    expect(await session.confirmCurrent(), isTrue);

    const refundId = 9001;
    await store.insertTransaction(
      refundTransaction(
        id: refundId,
        amountCents: 500,
        year: 2026,
        month: 9,
        day: 25,
      ),
    );
    final linked = await repository.linkRefund(
      ledgerId: ledgerId,
      month: month,
      refundTransactionId: refundId,
      originalTransactionId: card.id,
      amountCents: 500,
    );
    expect(linked, isA<ReviewSucceeded>(), reason: '$linked');

    final outcome = await repository.split(
      ledgerId: ledgerId,
      month: month,
      transactionId: card.id,
      items: <AllocationDraft>[
        const AllocationDraft(categoryId: SeedCategoryIds.food, amountCents: 1400),
        const AllocationDraft(categoryId: SeedCategoryIds.shopping, amountCents: 1400),
      ],
    );

    expect(outcome, isA<ReviewRejected>());
    expect(
      (await allocationsOf(card.id)).single.amountCents,
      2800,
      reason: '被拒时不能留下半个拆分结果',
    );
  });

  test('撤销拆分后回到拆分前的单个分配', () async {
    final card = session.current!;

    session.select('餐饮');
    expect(await session.confirmCurrent(), isTrue);
    expect((await allocationsOf(card.id)).single.categoryId, SeedCategoryIds.food);

    expect(
      await session.splitTransaction(
        transactionId: card.id,
        items: <AllocationDraft>[
          const AllocationDraft(categoryId: SeedCategoryIds.diningCoffee, amountCents: 1800),
          const AllocationDraft(categoryId: SeedCategoryIds.food, amountCents: 1000),
        ],
      ),
      isTrue,
    );
    expect(await allocationsOf(card.id), hasLength(2));
    expect(session.canUndo, isTrue);

    expect(await session.undo(), isTrue);

    final restored = await allocationsOf(card.id);
    expect(restored, hasLength(1), reason: '撤销要恢复到拆分前的那一条分配');
    expect(restored.single.categoryId, SeedCategoryIds.food);
    expect(restored.single.amountCents, 2800);
  });

  test('拆分不存在的记录时给出说明而不是抛异常', () async {
    final outcome = await repository.split(
      ledgerId: ledgerId,
      month: month,
      transactionId: 999999,
      items: <AllocationDraft>[
        const AllocationDraft(categoryId: SeedCategoryIds.food, amountCents: 100),
      ],
    );

    expect(outcome, isA<ReviewRejected>());
    expect((outcome as ReviewRejected).message, contains('找不到'));
  });
}
