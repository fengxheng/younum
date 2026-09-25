import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/import_records.dart';
import 'package:younum/domain/repositories/import_workflow.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';

/// 进程被杀之后的导入恢复。
///
/// 指南 10.2 要求「提交时进程结束后恢复不出现半批数据或重复记录」。
/// 提交走的是一个事务，所以崩溃只会留下两种局面，两种都必须按**实际结果**收尾：
/// 库里没有这批交易就放回待提交，有就补记为已提交（否则再提交一次会入两份）。

const String _bill = '''
交易时间,交易对方,收/支,金额(元),交易单号
2026-09-23 14:26:00,老王牛肉面,支出,28.00,4200001
2026-09-24 09:02:11,地铁公司,支出,5.00,4200002
''';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;

  const ledgerId = DemoLedgerSeed.realLedgerId;

  setUp(() async {
    store = InMemoryLedgerStore();
    repository = LedgerRepository(store);
    await repository.initialize();
  });

  Future<ImportStaged> stage() async {
    final result = await repository.stageImport(
      ledgerId: ledgerId,
      fileName: '2026-09.csv',
      bytes: _bytes(_bill),
      sourceNamespace: 'wechat',
      sourceAccount: '零钱',
    );
    expect(result, isA<ImportStaged>(), reason: '$result');
    return result as ImportStaged;
  }

  Future<void> setStage(int batchId, ImportStage stage) async {
    final batches = await store.importBatches(ledgerId: ledgerId);
    final batch = batches.firstWhere((item) => item.id == batchId);
    await store.updateImportBatch(batch.copyWith(stage: stage));
  }

  Future<ImportStage> stageOf(int batchId) async {
    final batches = await store.importBatches(ledgerId: ledgerId);
    return batches.firstWhere((item) => item.id == batchId).stage;
  }

  test('什么都没写进去：放回待提交，可以再提交一次', () async {
    final staged = await stage();
    // 模拟「提交事务还没开始就被杀」：状态停在 COMMITTING。
    await setStage(staged.preview.batchId, ImportStage.committing);

    final recovery = await repository.recoverInterruptedImports();

    expect(recovery.reopened, 1);
    expect(recovery.closed, 0);
    expect(await stageOf(staged.preview.batchId), ImportStage.ready);

    // 再提交一次：应当正常入账，而且只入这一批。
    await repository.commitImport(
      ledgerId: ledgerId,
      batchId: staged.preview.batchId,
    );
    final dataset = await repository.dataset(ledgerId: ledgerId);
    expect(dataset.transactions, hasLength(2));
  });

  test('已经写进去了但状态没改：补记为已提交，不会重复入账', () async {
    final staged = await stage();
    await repository.commitImport(
      ledgerId: ledgerId,
      batchId: staged.preview.batchId,
    );
    final afterCommit = await repository.dataset(ledgerId: ledgerId);
    expect(afterCommit.transactions, hasLength(2));

    // 模拟「事务提交成功了，但改状态之前进程被杀」。
    await setStage(staged.preview.batchId, ImportStage.committing);

    final recovery = await repository.recoverInterruptedImports();

    expect(recovery.closed, 1);
    expect(recovery.reopened, 0);
    expect(await stageOf(staged.preview.batchId), ImportStage.committed);

    // 关键：一笔都不多。
    final afterRecovery = await repository.dataset(ledgerId: ledgerId);
    expect(afterRecovery.transactions, hasLength(2));
  });

  test('已经收尾过的批次不动它', () async {
    final staged = await stage();
    await repository.commitImport(
      ledgerId: ledgerId,
      batchId: staged.preview.batchId,
    );

    final recovery = await repository.recoverInterruptedImports();

    expect(recovery.reopened, 0);
    expect(recovery.closed, 0);
    expect(await stageOf(staged.preview.batchId), ImportStage.committed);
  });

  test('撤销过的批次也不动它', () async {
    final staged = await stage();
    await repository.commitImport(
      ledgerId: ledgerId,
      batchId: staged.preview.batchId,
    );
    await repository.revertImport(
      batchId: staged.preview.batchId,
    );

    final recovery = await repository.recoverInterruptedImports();

    expect(recovery.reopened, 0);
    expect(recovery.closed, 0);
    final dataset = await repository.dataset(ledgerId: ledgerId);
    expect(dataset.transactions, isEmpty);
  });

  test('没有在途批次时什么也不做', () async {
    await stage();

    final recovery = await repository.recoverInterruptedImports();

    expect(recovery.reopened, 0);
    expect(recovery.closed, 0);
  });
}
