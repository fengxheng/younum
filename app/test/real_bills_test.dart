import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/import_records.dart';
import 'package:younum/domain/repositories/import_workflow.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';

/// 用**真实账单**跑端到端。
///
/// 这些文件是私人的，被 `.gitignore` 排除，不会进仓库；样本不存在时
/// [markTestSkipped] 记成跳过，**不**当作通过。
///
/// 覆盖的是三份账单一起过时才会出现的情形：微信、支付宝的扣款都走同一张银行卡，
/// 同一笔消费在两份账单里各记一条，而银行卡那份的交易对方写的是
/// 「支付宝（中国）网络技术有限公司」—— 商户名、时间都对不上，
/// 只有跨来源那一级判定能发现它（见 `DECISIONS.md` 53 节）。

const String _directory = 'test/账单';

/// 按文件名找账单。找不到就返回 null（测试会记成跳过）。
File? _bill(bool Function(String name) matches) {
  final folder = Directory(_directory);
  if (!folder.existsSync()) return null;
  final files = folder
      .listSync()
      .whereType<File>()
      .where((file) => matches(file.uri.pathSegments.last))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return files.isEmpty ? null : files.first;
}

Uint8List _bytes(File file) => file.readAsBytesSync();

void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;

  const ledgerId = DemoLedgerSeed.realLedgerId;

  setUp(() async {
    store = InMemoryLedgerStore();
    repository = LedgerRepository(store);
    await repository.initialize();
  });

  Future<ImportStaged> stage(File file, String namespace) async {
    final result = await repository.stageImport(
      ledgerId: ledgerId,
      fileName: file.uri.pathSegments.last,
      bytes: _bytes(file),
      sourceNamespace: namespace,
      sourceAccount: '默认',
    );
    expect(result, isA<ImportStaged>(), reason: '${file.path} 应该能直接暂存：$result');
    return result as ImportStaged;
  }

  test('微信账单：笔数与合计都和文件对得上', () async {
    final file = _bill((name) => name.contains('微信'));
    if (file == null) {
      markTestSkipped('没有真实账单样本（$_directory 下没有微信账单）');
      return;
    }

    final staged = await stage(file, 'wechat');
    expect(staged.preview.invalidCount, 0);
    expect(staged.preview.freshCount, 6);
  });

  test('支付宝账单（GBK 编码、带说明块）：全部解析，方向不误判', () async {
    final file = _bill((name) => name.contains('支付宝'));
    if (file == null) {
      markTestSkipped('没有真实账单样本（$_directory 下没有支付宝账单）');
      return;
    }

    final staged = await stage(file, 'alipay');
    expect(staged.preview.invalidCount, 0, reason: '说明块不能被当成数据行');
    expect(staged.preview.freshCount, 5);

    final rows = await repository.importRows(batchId: staged.preview.batchId);
    // 「不计收支」那一笔必须是转账，不能当成消费 —— 判错就会多算一笔消费。
    final transfer = rows.where((row) => row.direction == ImportDirection.transfer);
    expect(transfer, hasLength(1));
  });

  test('银行卡账单（后缀 .xls 其实是 XLSX）：不用人工映射，76 行全部解析', () async {
    final file = _bill((name) => name.contains('平安') || name.contains('银行'));
    if (file == null) {
      markTestSkipped('没有真实账单样本（$_directory 下没有银行卡账单）');
      return;
    }

    final staged = await stage(file, 'pab');
    expect(staged.preview.invalidCount, 0, reason: '交易对方要按方向取，不能整列判空');
    expect(staged.preview.freshCount, 76);
    expect(staged.preview.skippedCount, 2, reason: '账号说明行与表头各占一行');
  });

  test('三份账单一起过：银行账单里和支付宝撞上的那笔要被标成疑似', () async {
    final wechat = _bill((name) => name.contains('微信'));
    final alipay = _bill((name) => name.contains('支付宝'));
    final bank = _bill((name) => name.contains('平安') || name.contains('银行'));
    if (wechat == null || alipay == null || bank == null) {
      markTestSkipped('真实账单样本不齐（$_directory），跳过跨来源核对');
      return;
    }

    for (final entry in <(File, String)>[(wechat, 'wechat'), (alipay, 'alipay')]) {
      final staged = await stage(entry.$1, entry.$2);
      await repository.commitImport(
        ledgerId: ledgerId,
        batchId: staged.preview.batchId,
      );
    }

    // 单独导银行卡这份时没有任何可疑之处（库里还没有能撞上的记录）。
    final bankOnly = await repository.stageImport(
      ledgerId: ledgerId,
      fileName: bank.uri.pathSegments.last,
      bytes: _bytes(bank),
      sourceNamespace: 'pab',
      sourceAccount: '默认',
    );
    final bankStaged = bankOnly as ImportStaged;

    expect(
      bankStaged.preview.suspectedCount,
      greaterThanOrEqualTo(1),
      reason: '微信/支付宝的扣款都来自这张卡，必然有同一笔出现在两份账单里',
    );

    // 不写死「哪一笔」：两份账单覆盖的日期范围只是部分重叠，重叠到哪里由数据决定。
    // 所以改成从数据推导 —— 被标疑似的那几笔，金额必须真的在已有的账单里出现过。
    final previous = await repository.dataset(ledgerId: ledgerId);
    final knownAmounts = <int, Set<String>>{};
    for (final transaction in previous.transactions) {
      (knownAmounts[transaction.amountCents] ??= <String>{}).add(
        transaction.sourceNamespace ?? '',
      );
    }

    final rows = await repository.importRows(batchId: bankStaged.preview.batchId);
    final flagged = rows.where((row) => row.issue != null).toList();
    expect(flagged, hasLength(bankStaged.preview.suspectedCount));

    for (final row in flagged) {
      expect(row.status, ImportRowStatus.newRow);
      expect(row.included, isTrue, reason: '疑似不等于丢弃');
      expect(row.issue, startsWith(suspectedDuplicateIssuePrefix));

      final sources = knownAmounts[row.amountCents] ?? const <String>{};
      expect(
        sources,
        isNotEmpty,
        reason: '被标疑似的金额必须真的在已有账单里出现过，不能凭空怀疑',
      );
      // 提示里点名的来源必须真的是库里那一笔的来源，不能瞎指。
      final named = sources.firstWhere(
        (namespace) => row.issue!.contains(namespace),
        orElse: () => '<没有点名任何已有来源>',
      );
      expect(named, isNot('<没有点名任何已有来源>'), reason: row.issue);
    }

    // 疑似行照样能提交 —— 用户可以选择「保留两笔」。
    await repository.commitImport(
      ledgerId: ledgerId,
      batchId: bankStaged.preview.batchId,
    );
    final dataset = await repository.dataset(ledgerId: ledgerId);
    expect(
      dataset.transactions.length,
      previous.transactions.length + bankStaged.preview.freshCount,
    );
  });
}
