import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/import_records.dart';
import 'package:younum/domain/models/ledger_transaction.dart';
import 'package:younum/domain/repositories/import_workflow.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/domain/rules/csv_parser.dart';
import 'package:younum/domain/rules/import_rules.dart';

/// 银行卡账单的平台适配器。
///
/// 样例的**列结构**照着真实文件写（说明行、11 列、转出/转入的写法一致），
/// 姓名、卡号、公司名都是编的 —— 真实账单不进仓库。
///
/// 这里要守住的是一条反例：平台自己的列名（银行的方向列叫「交易类型」）
/// **不能**进公共别名表 —— 微信账单里也有一列叫「交易类型」，
/// 一旦共用，微信的方向列就会被它抢走。

const String _bank = '''账号：6230****0000  开始日期：2026-09-01  结束日期：2026-09-25  币种：RMB
交易时间,付款方姓名,付款方账号,收款方姓名,收款方账号,交易类型,交易金额,账户余额,摘要,备注,交易流水号
2026-09-25 11:09:10,张三,6230****0000,支付宝（中国）网络技术有限公司,215500690,转出,50.00,23385.14,快捷支付,支付宝,4064162609250001
2026-09-23 18:09:25,张三,6230****0000,天际美食荟,2088131795640121,转出,20.00,23544.96,快捷支付,支付宝-消费天际美食荟,3352582609230002
2026-09-20 09:00:00,某公司,1234567890,张三,6230****0000,转入,8000.00,31544.96,代发工资,工资,8888882609200003
''';

/// 仿微信账单表头：**也有一列叫「交易类型」，而且排在「收/支」前面**。
const String _wechat = '''微信支付账单明细
交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号
2026-09-23 14:26:00,商户消费,老王牛肉面,牛肉面,支出,¥28.00,零钱,支付成功,4200001
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

  RowParsed parseAt(
    HeaderGuess header,
    List<List<String>> rows,
    int dataIndex,
  ) {
    final result = ImportRules.parseRow(
      row: rows[dataIndex],
      rowNumber: dataIndex + 1,
      header: header,
    );
    expect(result, isA<RowParsed>(), reason: '第 $dataIndex 行应能解析：$result');
    return result as RowParsed;
  }

  test('整套表头认出来了：平台名正确、必填项齐全、不用人工映射', () {
    final table = CsvParser.parse(_bank).$1!;
    final guess = ImportRules.detectHeader(table);

    expect(guess.headerRowIndex, 1);
    expect(guess.platformName, '银行账单');
    expect(guess.isUsable, isTrue);
    expect(guess.missingRequired, isEmpty);
    expect(guess.columns[ImportField.direction], 5);
    expect(guess.columns[ImportField.orderId], 10);
    expect(guess.columns[ImportField.payer], 1);
    expect(guess.columns[ImportField.payee], 3);
  });

  test('平台名不会被数据行里的「支付宝」带偏', () {
    final table = CsvParser.parse(_bank).$1!;
    final guess = ImportRules.detectHeader(table);
    // 这份账单里有好几行收款方写着「支付宝（中国）网络技术有限公司」，
    // 但它是银行卡的账单 —— 平台名只能看表头之前那几行。
    expect(guess.platformName, isNot('支付宝'));
    expect(guess.platformName, '银行账单');
  });

  test('交易对方按方向取：转出取收款方，转入取付款方', () {
    final table = CsvParser.parse(_bank).$1!;
    final guess = ImportRules.detectHeader(table);

    final expense = parseAt(guess, table.rows, 2); // 转出 50.00
    final income = parseAt(guess, table.rows, 4); // 转入 8000.00

    expect(expense.direction, ImportDirection.expense);
    expect(expense.merchant, '支付宝（中国）网络技术有限公司');

    expect(income.direction, ImportDirection.income);
    expect(income.merchant, '某公司', reason: '转入时对方是付款方，不能是用户自己');
  });

  test('微信账单不会误用银行适配器：方向列仍是「收/支」', () {
    final table = CsvParser.parse(_wechat).$1!;
    final guess = ImportRules.detectHeader(table);

    expect(guess.columns[ImportField.direction], 4, reason: '方向必须取「收/支」那一列');
    expect(guess.platformName, '微信支付');

    final row = parseAt(guess, table.rows, 2);
    expect(row.direction, ImportDirection.expense);
    expect(row.merchant, '老王牛肉面');
  });

  test('银行账单直接就能暂存、能提交，金额与方向都对', () async {
    final result = await repository.stageImport(
      ledgerId: ledgerId,
      fileName: '2026-09-银行卡.csv',
      bytes: _bytes(_bank),
      sourceNamespace: 'pab',
      sourceAccount: '默认',
    );

    expect(result, isA<ImportStaged>(), reason: '不该再要求人工映射：$result');
    final staged = result as ImportStaged;
    expect(staged.preview.freshCount, 3);
    expect(staged.preview.invalidCount, 0);
    expect(staged.preview.skippedCount, 2, reason: '说明行与表头各占一行');

    await repository.commitImport(
      ledgerId: ledgerId,
      batchId: staged.preview.batchId,
    );

    final dataset = await repository.dataset(ledgerId: ledgerId);
    expect(dataset.transactions.length, 3);

    final income = dataset.transactions.firstWhere(
      (transaction) => transaction.amountCents == 800000,
    );
    expect(income.nature, TransactionNature.income);
    expect(income.merchant, '某公司');
  });
}
