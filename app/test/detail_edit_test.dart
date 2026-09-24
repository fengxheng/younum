import 'package:flutter_test/flutter_test.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/ledger_transaction.dart';
import 'package:younum/domain/models/year_month.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/features/organize/review_session.dart';

/// 详情页的保存（备注 + 用途）。
///
/// 两件事必须一次写完：详情页只有一个「保存修改」，分成两次写会出现
/// 「撤销之后用途回来了、备注没回来」这种半截结果。
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

  Future<LedgerTransaction> reload(int id) async {
    final dataset = await repository.dataset(ledgerId: ledgerId);
    return dataset.transaction(id)!;
  }

  Future<List<int>> categoryIdsOf(int id) async {
    final dataset = await repository.dataset(ledgerId: ledgerId);
    return dataset
        .allocationsOf(id)
        .map((allocation) => allocation.categoryId)
        .toList();
  }

  test('只写备注：落库，但不算处理完成', () async {
    final card = session.current!;
    expect(card.transaction.note, isNull);

    final ok = await session.saveDetails(
      transactionId: card.id,
      note: '  午后和朋友喝咖啡  ',
    );

    expect(ok, isTrue);
    expect((await reload(card.id)).note, '午后和朋友喝咖啡', reason: '两端空格要去掉');
    expect(
      (await reload(card.id)).reviewStatus,
      ReviewStatus.pending,
      reason: '只写了个备注，不能把还没归类的消费算成处理完成',
    );
    expect(session.remainingCount, 6, reason: '队列不该动');
  });

  test('把备注改空会真的清掉，而不是留着上一版', () async {
    final card = session.current!;
    await session.saveDetails(transactionId: card.id, note: '先写点什么');
    expect((await reload(card.id)).note, '先写点什么');

    final ok = await session.saveDetails(transactionId: card.id, note: '   ');

    expect(ok, isTrue);
    expect(
      (await reload(card.id)).note,
      isNull,
      reason: '全是空格等于没写，库里应该存 null 而不是空白串',
    );
  });

  test('备注与用途一次写完', () async {
    final card = session.current!;

    final ok = await session.saveDetails(
      transactionId: card.id,
      note: '这杯是请客的',
      categoryId: SeedCategoryIds.diningCoffee,
    );

    expect(ok, isTrue);
    final updated = await reload(card.id);
    expect(updated.note, '这杯是请客的');
    expect(updated.reviewStatus, ReviewStatus.resolved);
    expect(await categoryIdsOf(card.id), <int>[SeedCategoryIds.diningCoffee]);
    expect(session.remainingCount, 5, reason: '定了用途就该离开待整理队列');
  });

  test('撤销：备注与用途都要回到原样', () async {
    final card = session.current!;
    // 先造一个「原来就有备注、也归过类」的状态。
    await session.saveDetails(
      transactionId: card.id,
      note: '原来的备注',
      categoryId: SeedCategoryIds.food,
    );
    await session.reload();

    final ok = await session.saveDetails(
      transactionId: card.id,
      note: '改过的备注',
      categoryId: SeedCategoryIds.shopping,
    );
    expect(ok, isTrue);
    expect(await categoryIdsOf(card.id), <int>[SeedCategoryIds.shopping]);

    expect(await session.undo(), isTrue);

    final restored = await reload(card.id);
    expect(
      restored.note,
      '原来的备注',
      reason: '撤销不能把用户手写的备注弄丢',
    );
    expect(await categoryIdsOf(card.id), <int>[SeedCategoryIds.food]);
  });

  test('撤销「清空备注」会把备注还回来', () async {
    final card = session.current!;
    await session.saveDetails(transactionId: card.id, note: '别忘了这句');

    await session.saveDetails(transactionId: card.id, note: '');
    expect((await reload(card.id)).note, isNull);

    expect(await session.undo(), isTrue);
    expect((await reload(card.id)).note, '别忘了这句');
  });

  test('记录不存在时给出说明而不是抛异常', () async {
    final outcome = await repository.saveDetails(
      ledgerId: ledgerId,
      month: month,
      transactionId: 999999,
      note: '随便写点',
    );

    expect(outcome, isA<ReviewRejected>());
    expect((outcome as ReviewRejected).message, contains('找不到'));
  });
}
