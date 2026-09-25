import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/repositories/import_workflow.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';

/// 大文件导入（阶段 7：加载大文件、长时间不卡死）。
///
/// 这一组不是为了测性能数字，而是为了接住**复杂度写错**这类问题：
/// 去重、跨来源比对、逐行标准化都必须是线性的，行数翻倍不能变成平方级。
/// 所以断言的是「能跑完 + 统计正确 + 时间长到离谱就算失败」，上限给得很宽。

/// 造一份很大但结构正常的微信账单。
Uint8List _bigBill(int rows) {
  final buffer = StringBuffer(
    '交易时间,交易对方,收/支,金额(元),交易单号\n',
  );
  for (var index = 0; index < rows; index++) {
    final day = 1 + (index % 28);
    // 金额刻意大量重复（真实账单里同金额很常见），
    // 这样跨来源比对那一层的分桶是否有效就能体现出来。
    final amount = ((index % 37) + 1) * 3;
    buffer
      ..write('2026-09-')
      ..write(day.toString().padLeft(2, '0'))
      ..write(' 12:')
      ..write((index % 60).toString().padLeft(2, '0'))
      ..write(':00,商户')
      ..write(index)
      ..write(',支出,')
      ..write(amount)
      ..write('.00,42')
      ..write(index)
      ..write('\n');
  }
  return Uint8List.fromList(utf8.encode(buffer.toString()));
}

void main() {
  const ledgerId = DemoLedgerSeed.realLedgerId;

  Future<ImportStaged> stageBig(int rows, {bool commit = false}) async {
    final store = InMemoryLedgerStore();
    final repository = LedgerRepository(store);
    await repository.initialize();

    final bytes = _bigBill(rows);
    final stopwatch = Stopwatch()..start();
    final result = await repository.stageImport(
      ledgerId: ledgerId,
      fileName: 'big-$rows.csv',
      bytes: bytes,
      sourceNamespace: 'wechat',
      sourceAccount: '零钱',
    );
    expect(result, isA<ImportStaged>(), reason: '$result');
    final staged = result as ImportStaged;

    if (commit) {
      await repository.commitImport(
        ledgerId: ledgerId,
        batchId: staged.preview.batchId,
      );
    }
    stopwatch.stop();

    // 宽松上限：只是接住「不小心写成 O(n²)」。真机上几十万行本来就要几秒。
    expect(
      stopwatch.elapsed.inSeconds,
      lessThan(90),
      reason: '$rows 行用了 ${stopwatch.elapsedMilliseconds} ms，疑似复杂度写错',
    );
    return staged;
  }

  test('6 万行：全部解析、统计正确、能提交', () async {
    const rows = 60000;
    final staged = await stageBig(rows, commit: true);

    expect(staged.preview.totalRows, rows + 1, reason: '表头一行');
    expect(staged.preview.freshCount, rows);
    expect(staged.preview.invalidCount, 0);
    expect(staged.preview.skippedCount, 1);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('行数翻倍，耗时不该变成四倍（线性）', () async {
    final small = Stopwatch()..start();
    await stageBig(20000);
    small.stop();

    final big = Stopwatch()..start();
    await stageBig(40000);
    big.stop();

    // 允许很宽的余量：只为抓「平方级」这种量级差异。
    final ratio = big.elapsedMicroseconds / small.elapsedMicroseconds;
    expect(
      ratio,
      lessThan(6),
      reason: '2 万行 ${small.elapsedMilliseconds} ms → 4 万行 '
          '${big.elapsedMilliseconds} ms，比值 $ratio 不像线性',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('同一份大文件再导一次：全部判成重复，不重复入账', () async {
    final store = InMemoryLedgerStore();
    final repository = LedgerRepository(store);
    await repository.initialize();

    const rows = 20000;
    final bytes = _bigBill(rows);
    Future<ImportStaged> stage(String name) async {
      final result = await repository.stageImport(
        ledgerId: ledgerId,
        fileName: name,
        bytes: bytes,
        sourceNamespace: 'wechat',
        sourceAccount: '零钱',
      );
      return result as ImportStaged;
    }

    final first = await stage('first.csv');
    await repository.commitImport(
      ledgerId: ledgerId,
      batchId: first.preview.batchId,
    );

    final second = await stage('second.csv');
    expect(second.preview.freshCount, 0);
    expect(second.preview.duplicateCount, rows, reason: '同源单号全部命中');
    expect(second.preview.suspectedCount, 0, reason: '同源重复不该报成跨来源疑似');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
