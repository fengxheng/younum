import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/import_records.dart';
import 'package:younum/domain/repositories/import_workflow.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/domain/rules/import_rules.dart';

/// 跨来源疑似重复。
///
/// 场景来自真实账单：微信、支付宝的扣款全部走银行卡，于是同一笔消费会同时出现在
/// 两份账单里 —— 而两份账单里的**商户名完全不同**（银行卡那份写的是
/// 「支付宝（中国）网络技术有限公司」），时间也差着几秒。
/// 靠「商户 + 时间 + 金额完全相同」那条弱键根本发现不了，结果就是同一笔算两次。
///
/// 这里的样例是照着真实文件的列结构手写的（表头、列顺序、「转出/转入」写法一致），
/// 卡号之类的信息全是编的。

/// 仿支付宝导出：09-23 18:09 在天际美食荟花 20.00。
const String _alipayBill = '''
交易时间,交易对方,商品说明,收/支,金额(元),交易状态,交易号
2026-09-23 18:09:20,天际美食荟,餐费,支出,20.00,交易成功,2026092322001
''';

/// 仿银行卡导出。第 1 行与支付宝那笔是同一笔消费（金额相同、差 5 秒），
/// 第 2 行金额不同，第 3 行金额相同但差了 4 天。
const String _bankBill = '''
账号：6230****0000  开始日期：2026-09-01  结束日期：2026-09-25  币种：RMB
交易时间,付款方姓名,付款方账号,收款方姓名,收款方账号,交易类型,交易金额,账户余额,摘要,备注,交易流水号
2026-09-23 18:09:25,张三,6230****0000,宁波天际美食荟,2088131795640121,转出,20.00,23544.96,快捷支付,支付宝-消费天际美食荟,3352582609230001
2026-09-24 08:01:00,张三,6230****0000,某早餐店,2088131795640000,转出,5.00,23539.96,快捷支付,支付宝,3352582609240002
2026-09-19 18:09:20,张三,6230****0000,天际美食荟,2088131795640121,转出,20.00,23600.00,快捷支付,支付宝-消费天际美食荟,3352582609190003
''';

/// 银行卡那份认不出表头（指南 4.2.7 要求进映射页），所以这里照映射页的产物手写一份。
const ImportFieldMapping _bankMapping = ImportFieldMapping(
  headerRowIndex: 1,
  columns: <ImportField, int>{
    ImportField.occurredAt: 0,
    ImportField.merchant: 3,
    ImportField.amount: 6,
    ImportField.direction: 5,
    ImportField.orderId: 10,
    ImportField.note: 9,
  },
);

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

  Future<ImportStaged> stage(
    String text, {
    required String namespace,
    ImportFieldMapping? mapping,
    String fileName = '2026-09.csv',
  }) async {
    final result = await repository.stageImport(
      ledgerId: ledgerId,
      fileName: fileName,
      bytes: _bytes(text),
      sourceNamespace: namespace,
      sourceAccount: '默认',
      mapping: mapping,
    );
    expect(result, isA<ImportStaged>(), reason: '应该能暂存：$result');
    return result as ImportStaged;
  }

  Future<void> commit(ImportStaged staged) async {
    await repository.commitImport(
      ledgerId: ledgerId,
      batchId: staged.preview.batchId,
    );
  }

  test('同一笔消费在两份账单里各记一次：跨来源那行是疑似，但仍然计入', () async {
    // 先导入支付宝那份 —— 库里的天际美食荟是 alipay 来源。
    final alipay = await stage(_alipayBill, namespace: 'alipay');
    expect(alipay.preview.suspectedCount, 0);
    await commit(alipay);

    final bank = await stage(
      _bankBill,
      namespace: 'pab',
      mapping: _bankMapping,
      fileName: '2026-09-银行.csv',
    );

    // 三行里只有第 1 行该被怀疑：第 2 行金额不同，第 3 行时间差 4 天。
    expect(bank.preview.suspectedCount, 1);
    expect(bank.preview.freshCount, 3, reason: '疑似不等于丢弃，三行都要能提交');

    final rows = await repository.importRows(batchId: bank.preview.batchId);
    final sameDay = rows.firstWhere((row) => row.amountCents == 2000);
    final otherDay = rows.last;

    expect(sameDay.status, ImportRowStatus.newRow);
    expect(sameDay.included, isTrue, reason: '疑似重复必须留给用户决定，不能自动剔除');
    expect(sameDay.issue, isNotNull);
    expect(sameDay.issue, startsWith(suspectedDuplicateIssuePrefix));
    expect(sameDay.issue, contains('alipay'), reason: '要说清是和哪份账单撞上的');

    expect(otherDay.amountCents, 2000);
    expect(otherDay.issue, isNull, reason: '差 4 天不算疑似');
  });

  test('同一份账单再导一遍仍然是同源重复，不会降级成疑似', () async {
    final first = await stage(_alipayBill, namespace: 'alipay');
    await commit(first);

    final again = await stage(_alipayBill, namespace: 'alipay', fileName: 'again.csv');
    expect(again.preview.duplicateCount, 1);
    expect(again.preview.suspectedCount, 0);
  });

  test('crossSourceDuplicate：来源不同 + 时间接近 + 金额相同才命中', () {
    final known = <ImportSourceStamp>[
      ImportRules.stampOf(occurredAtMs: 1000000, sourceNamespace: 'pab'),
    ];

    // 来源不同、差 5 秒 → 命中，并说清差了多久。
    final hit = ImportRules.crossSourceDuplicate(
      occurredAtMs: 1005000,
      sourceNamespace: 'alipay',
      sameAmount: known,
    );
    expect(hit, isNotNull);
    expect(hit!.gapMs, 5000);
    expect(hit.otherNamespace, 'pab');

    // 同一份来源：交给同源键处理，不在这里判。
    expect(
      ImportRules.crossSourceDuplicate(
        occurredAtMs: 1005000,
        sourceNamespace: 'pab',
        sameAmount: known,
      ),
      isNull,
    );

    // 刚好在窗口边界上算命中，超出一天就不算。
    expect(
      ImportRules.crossSourceDuplicate(
        occurredAtMs: 1000000 + ImportRules.crossSourceWindowMs,
        sourceNamespace: 'alipay',
        sameAmount: known,
      ),
      isNotNull,
    );
    expect(
      ImportRules.crossSourceDuplicate(
        occurredAtMs: 1000000 + ImportRules.crossSourceWindowMs + 1,
        sourceNamespace: 'alipay',
        sameAmount: known,
      ),
      isNull,
    );
  });

  test('crossSourceDuplicate：多个候选时取时间最接近的那个', () {
    final hit = ImportRules.crossSourceDuplicate(
      occurredAtMs: 1000000,
      sourceNamespace: 'alipay',
      sameAmount: <ImportSourceStamp>[
        ImportRules.stampOf(occurredAtMs: 1000000 + 3600000, sourceNamespace: 'pab'),
        ImportRules.stampOf(occurredAtMs: 1000000 + 60000, sourceNamespace: 'wechat'),
      ],
    );
    expect(hit, isNotNull);
    expect(hit!.otherNamespace, 'wechat');
    expect(hit.gapMs, 60000);
  });

  test('时间差说成人话', () {
    expect(ImportRules.sourceGapText(30000), '不到 1 分钟');
    expect(ImportRules.sourceGapText(5 * 60 * 1000), '5 分钟');
    expect(ImportRules.sourceGapText(3 * 60 * 60 * 1000), '3.0 小时');
    expect(ImportRules.sourceGapText(3 * 24 * 60 * 60 * 1000), '3 天');
  });

  test('银行卡的「转出 / 转入」能判出方向，且不影响「转账」', () {
    expect(ImportRules.directionOf('转出', 1), ImportDirection.expense);
    expect(ImportRules.directionOf('转入', 1), ImportDirection.income);
    expect(ImportRules.directionOf('转账', 1), ImportDirection.transfer);
    expect(ImportRules.directionOf('支出', 1), ImportDirection.expense);
    expect(ImportRules.directionOf('收入', 1), ImportDirection.income);
  });
}
