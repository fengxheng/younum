import 'package:flutter_test/flutter_test.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/ledger_transaction.dart';
import 'package:younum/domain/models/year_month.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/features/organize/review_session.dart';

/// 交易性质调整。
///
/// 指南 3.3：收入 / 转账 / 排除统计在确认性质后即处理完成，不需要消费分类；
/// 排除统计必须写明原因；退款必须关联到原消费；消费必须有分配。
/// 指南 3.5.4：跨月退款归回原消费月份。
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

  Future<LedgerTransaction> reload(int transactionId) async {
    final dataset = await repository.dataset(ledgerId: ledgerId);
    return dataset.transaction(transactionId)!;
  }

  test('标成转账：性质变了、离开待整理队列、旧的分配被清掉', () async {
    final card = session.current!;
    // 先当消费归类，这样才有「旧分配」可清。
    session.select('餐饮');
    expect(await session.confirmCurrent(), isTrue);
    expect(
      (await repository.dataset(ledgerId: ledgerId)).allocationsOf(card.id),
      hasLength(1),
    );

    final ok = await session.setNature(
      transactionId: card.id,
      nature: TransactionNature.transfer,
    );

    expect(ok, isTrue);
    final updated = await reload(card.id);
    expect(updated.nature, TransactionNature.transfer);
    expect(updated.reviewStatus, ReviewStatus.resolved);
    expect(
      (await repository.dataset(ledgerId: ledgerId)).allocationsOf(card.id),
      isEmpty,
      reason: '已经不是消费了，留着用途只会让以后回看时看不懂',
    );
    expect(session.remainingCount, 5);
  });

  test('排除统计必须写明原因', () async {
    final card = session.current!;

    final missing = await repository.setNature(
      ledgerId: ledgerId,
      month: month,
      transactionId: card.id,
      nature: TransactionNature.excluded,
    );
    expect(missing, isA<ReviewRejected>());
    expect((await reload(card.id)).nature, isNot(TransactionNature.excluded));

    final blank = await repository.setNature(
      ledgerId: ledgerId,
      month: month,
      transactionId: card.id,
      nature: TransactionNature.excluded,
      excludeReason: '   ',
    );
    expect(blank, isA<ReviewRejected>(), reason: '全是空格不算写了原因');

    final ok = await repository.setNature(
      ledgerId: ledgerId,
      month: month,
      transactionId: card.id,
      nature: TransactionNature.excluded,
      excludeReason: '朋友还我的钱',
    );
    expect(ok, isA<ReviewSucceeded>());

    final updated = await reload(card.id);
    expect(updated.nature, TransactionNature.excluded);
    expect(updated.excludeReason, '朋友还我的钱');
  });

  test('从「排除统计」改回转账时，旧原因会被清掉', () async {
    final card = session.current!;
    await repository.setNature(
      ledgerId: ledgerId,
      month: month,
      transactionId: card.id,
      nature: TransactionNature.excluded,
      excludeReason: '朋友还我的钱',
    );

    await session.setNature(
      transactionId: card.id,
      nature: TransactionNature.transfer,
    );

    final updated = await reload(card.id);
    expect(updated.nature, TransactionNature.transfer);
    expect(
      updated.excludeReason,
      isNull,
      reason: '原因要跟着性质一起清掉，否则会留下一条对不上的说明',
    );
  });

  test('改回消费但没有用途时被拒', () async {
    final card = session.current!;
    await session.setNature(
      transactionId: card.id,
      nature: TransactionNature.transfer,
    );

    final outcome = await repository.setNature(
      ledgerId: ledgerId,
      month: month,
      transactionId: card.id,
      nature: TransactionNature.expense,
    );

    expect(outcome, isA<ReviewRejected>());
    expect((await reload(card.id)).nature, TransactionNature.transfer);
  });

  test('标成退款但还没关联原消费时被拒（指南 3.3）', () async {
    final card = session.current!;

    final outcome = await repository.setNature(
      ledgerId: ledgerId,
      month: month,
      transactionId: card.id,
      nature: TransactionNature.refund,
    );

    expect(outcome, isA<ReviewRejected>());
    expect((await reload(card.id)).nature, isNot(TransactionNature.refund));
  });

  test('撤销「改性质」后回到原来的消费与用途', () async {
    final card = session.current!;
    session.select('餐饮');
    expect(await session.confirmCurrent(), isTrue);

    expect(
      await session.setNature(
        transactionId: card.id,
        nature: TransactionNature.income,
      ),
      isTrue,
    );
    expect((await reload(card.id)).nature, TransactionNature.income);

    expect(await session.undo(), isTrue);

    final restored = await reload(card.id);
    expect(restored.nature, TransactionNature.expense);
    expect(restored.reviewStatus, ReviewStatus.resolved);
    expect(
      (await repository.dataset(ledgerId: ledgerId)).allocationsOf(card.id),
      hasLength(1),
      reason: '撤销要把被清掉的分配一起还回来',
    );
  });

  test('记录不存在时给出说明而不是抛异常', () async {
    final outcome = await repository.setNature(
      ledgerId: ledgerId,
      month: month,
      transactionId: 999999,
      nature: TransactionNature.transfer,
    );

    expect(outcome, isA<ReviewRejected>());
    expect((outcome as ReviewRejected).message, contains('找不到'));
  });
}
