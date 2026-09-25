import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:younum/domain/models/allocation.dart';
import 'package:younum/domain/models/category.dart';
import 'package:younum/domain/models/import_records.dart';
import 'package:younum/domain/models/ledger_dataset.dart';
import 'package:younum/domain/models/ledger_transaction.dart';
import 'package:younum/domain/models/year_month.dart';
import 'package:younum/domain/rules/csv_parser.dart';
import 'package:younum/domain/rules/export_rules.dart';

/// 导出规则：CSV 结构、公式注入防护、隐私开关。
///
/// 指南 8.1 与 10.4 的验收点是「CSV 文本含 `= + - @` 开头、引号与换行时，
/// 防公式执行且格式可解析」，以及「隐藏金额后检查生成的 PNG，而非只检查屏幕遮罩」。

const int _ledger = 1;
final YearMonth _september = YearMonth(2026, 9);

/// 2026-09-23 18:09:20（统计时区）。
int _at(int day, int hour, int minute) =>
    DateTime.utc(2026, 9, day, hour - 8, minute).millisecondsSinceEpoch;

LedgerTransaction _tx({
  required int id,
  required int occurredAtMs,
  required int amountCents,
  String merchant = '老王牛肉面',
  TransactionNature nature = TransactionNature.expense,
  String? note,
}) => LedgerTransaction(
  id: id,
  ledgerId: _ledger,
  occurredAtMs: occurredAtMs,
  amountCents: amountCents,
  merchant: merchant,
  nature: nature,
  reviewStatus: ReviewStatus.resolved,
  timeZone: 'Asia/Shanghai',
  note: note,
);

Category _category(int id, String name) => Category(
  id: id,
  name: name,
  iconType: CategoryIconType.builtin,
  iconKey: 'food',
  sortOrder: id,
  isBuiltin: true,
);

void main() {
  group('公式注入防护', () {
    test('危险开头的文本列会被加上单引号', () {
      expect(ExportRules.guardFormula('=1+1'), "'=1+1");
      expect(ExportRules.guardFormula('+1'), "'+1");
      expect(ExportRules.guardFormula('-1'), "'-1");
      expect(ExportRules.guardFormula('@SUM(A1)'), "'@SUM(A1)");
      expect(ExportRules.guardFormula('\t=x'), "'\t=x");
      expect(ExportRules.guardFormula('\r=x'), "'\r=x");
    });

    test('前导空格后面跟公式起始符也挡掉', () {
      expect(ExportRules.guardFormula(' =1+1'), "' =1+1");
      expect(ExportRules.guardFormula('   @x'), "'   @x");
    });

    test('正常文本与空文本不动它', () {
      expect(ExportRules.guardFormula('老王牛肉面'), '老王牛肉面');
      expect(ExportRules.guardFormula(''), '');
      expect(ExportRules.guardFormula('   '), '   ');
      expect(ExportRules.guardFormula('28.00'), '28.00');
    });

    test('金额列保持数字语义：负号不会被当成公式前缀', () {
      expect(ExportRules.amountCell(2800), '28.00');
      expect(ExportRules.amountCell(2800, sign: -1), '-28.00');
      // 关键：负数**不能**走 guardFormula，否则就成了文本 '‑28.00。
      expect(ExportRules.amountCell(2800, sign: -1).startsWith("'"), isFalse);
    });
  });

  group('CSV 单元格', () {
    test('逗号、引号、换行该加引号的加引号', () {
      expect(ExportRules.csvCell('a,b'), '"a,b"');
      expect(ExportRules.csvCell('a"b'), '"a""b"');
      expect(ExportRules.csvCell('a\nb'), '"a\nb"');
      expect(ExportRules.csvCell('a\rb'), '"a\rb"');
      expect(ExportRules.csvCell('普通文本'), '普通文本');
    });

    test('时间列用与平台账单一致的写法：横杠加秒', () {
      // 界面上的 2026.09.23 18:09 拿去对账、再导回来都不方便，
      // 导出固定用 2026-09-23 18:09:20。
      expect(ExportRules.timeCell(_at(23, 18, 9)), '2026-09-23 18:09:00');
      expect(ExportRules.timeCell(_at(1, 0, 0)), '2026-09-01 00:00:00');
    });
  });

  group('明细行', () {
    test('只取目标月份，金额带方向，用途来自真实分配', () {
      final dataset = LedgerDataset(
        transactions: <LedgerTransaction>[
          _tx(id: 1, occurredAtMs: _at(23, 18, 9), amountCents: 2800),
          // 另一笔：上个月，不该出现在 9 月的导出里。
          _tx(
            id: 2,
            occurredAtMs: _at(23, 18, 9) - 30 * 24 * 3600 * 1000,
            amountCents: 9900,
          ),
          _tx(
            id: 3,
            occurredAtMs: _at(24, 9, 2),
            amountCents: 500,
            nature: TransactionNature.transfer,
            merchant: '零钱通',
          ),
        ],
        categories: <Category>[_category(1, '餐饮'), _category(2, '购物')],
        allocations: <Allocation>[
          Allocation(id: 1, transactionId: 1, categoryId: 1, amountCents: 2000),
          Allocation(id: 2, transactionId: 1, categoryId: 2, amountCents: 800),
        ],
      );

      final rows = ExportRules.detailRows(dataset: dataset, month: _september);
      expect(rows, hasLength(2));
      expect(rows.first.occurredAtMs, lessThan(rows.last.occurredAtMs));

      final meal = rows.first;
      expect(meal.merchant, '老王牛肉面');
      expect(meal.amountCents, 2800);
      expect(meal.amountSign, -1);
      expect(meal.natureLabel, '消费');
      expect(meal.categoryNames, <String>['餐饮', '购物']);

      // 转账没有方向：按绝对值写，不去猜它是进还是出。
      final transfer = rows.last;
      expect(transfer.natureLabel, '转账');
      expect(transfer.amountSign, isNull);
      expect(
        ExportRules.amountCell(transfer.amountCents, sign: transfer.amountSign),
        '5.00',
      );
    });
  });

  group('明细 CSV 文件', () {
    List<ExportRow> rowsOf(LedgerDataset dataset) =>
        ExportRules.detailRows(dataset: dataset, month: _september);

    test('BOM + CRLF + 固定表头', () {
      final text = ExportRules.detailCsv(<ExportRow>[]);
      expect(text.startsWith(ExportRules.bom), isTrue);
      expect(text, contains('时间,商户,金额,收支,用途,备注${ExportRules.lineEnding}'));

      final bytes = ExportRules.detailCsvBytes(<ExportRow>[]);
      expect(bytes.sublist(0, 3), <int>[0xEF, 0xBB, 0xBF], reason: 'UTF-8 BOM');
      // ⚠️ Dart 的 utf8.decode 会把开头 BOM 吃掉，所以这里比的是「去掉 BOM 的文本」。
      expect(utf8.decode(bytes), text.substring(ExportRules.bom.length));
    });

    test('危险文本在文件里被中和，且能被自己的解析器原样读回来', () {
      final dataset = LedgerDataset(
        transactions: <LedgerTransaction>[
          _tx(
            id: 1,
            occurredAtMs: _at(23, 12, 0),
            amountCents: 100,
            merchant: '=cmd|calc',
            note: '备注里有,逗号和"引号"\n还有换行',
          ),
        ],
        categories: <Category>[],
        allocations: <Allocation>[],
      );

      final text = ExportRules.detailCsv(rowsOf(dataset));
      // 商户列不能以裸的 = 开头。
      expect(text, contains("'=cmd|calc"));

      final parsed = CsvParser.parse(text.substring(ExportRules.bom.length));
      expect(parsed.$2, isNull, reason: '自己生成的 CSV 必须能被自己的解析器读懂');
      final table = parsed.$1!;
      expect(table.rows, hasLength(2));
      expect(table.rows[1][0], '2026-09-23 12:00:00', reason: '时间列固定写法');
      expect(table.rows[1][1], "'=cmd|calc");
      expect(table.rows[1][5], '备注里有,逗号和"引号"\n还有换行', reason: '引号与换行原样往返');
      expect(table.rows[1][2], '-1.00');
    });

    test('没有任何一行会以裸公式开头', () {
      final dataset = LedgerDataset(
        transactions: <LedgerTransaction>[
          _tx(
            id: 1,
            occurredAtMs: _at(23, 12, 0),
            amountCents: 100,
            merchant: '+1',
          ),
          _tx(
            id: 2,
            occurredAtMs: _at(24, 12, 0),
            amountCents: 200,
            merchant: '@x',
          ),
        ],
      );
      for (final line in ExportRules.detailCsv(
        rowsOf(dataset),
      ).split(ExportRules.lineEnding)) {
        for (final cell in line.split(',')) {
          expect(
            cell.startsWith('=') ||
                cell.startsWith('+') ||
                cell.startsWith('@'),
            isFalse,
            reason: '这一格没有被中和：$cell',
          );
        }
      }
    });
  });

  group('导入异常明细', () {
    ImportRow row(
      int number, {
      ImportRowStatus status = ImportRowStatus.invalid,
      String? issue,
      String? raw,
    }) => ImportRow(
      id: ImportRow.idUnassigned,
      batchId: ImportBatch.idUnassigned,
      rowNumber: number,
      status: status,
      issue: issue,
      rawText: raw,
      included: false,
    );

    test('表头固定、按行号排序、状态说人话', () {
      final text = ExportRules.problemCsv(<ImportRow>[
        row(20, issue: '缺少交易金额', raw: '2026-09-03,某店,,'),
        row(7, issue: '看不懂的时间格式：9/3'),
        row(
          15,
          status: ImportRowStatus.newRow,
          issue: '$suspectedDuplicateIssuePrefix：与「pab」那份账单里的一笔金额相同',
        ),
      ]);

      expect(text.startsWith(ExportRules.bom), isTrue, reason: 'Excel 打开要不乱码');
      final lines = text
          .substring(ExportRules.bom.length)
          .trim()
          .split(ExportRules.lineEnding);
      expect(lines.first, '行号,状态,原因,原始内容');
      expect(lines[1], startsWith('7,无效,'));
      expect(
        lines[2],
        startsWith('15,疑似重复,'),
        reason: '疑似重复的行在库里仍是「新增」，导出时要按用户能读懂的说法写',
      );
      expect(lines[3], startsWith('20,无效,'));
    });

    test('原始内容里的危险开头同样会被中和', () {
      // 原始内容是用户文件里的**任意**文本，防注入不能跳过这一列。
      final text = ExportRules.problemCsv(<ImportRow>[
        row(3, issue: '缺少交易金额', raw: '=1+1,某店,12.00'),
      ]);

      expect(text, contains("'=1+1,某店,12.00"));
    });

    test('没有异常行时只留表头', () {
      expect(
        ExportRules.problemCsv(const <ImportRow>[]),
        '${ExportRules.bom}行号,状态,原因,原始内容${ExportRules.lineEnding}',
      );
    });
  });

  group('隐私开关', () {
    test('默认隐藏金额，而且每次都是默认值', () {
      expect(ExportPrivacy.defaults.showAmount, isFalse);
      expect(const ExportPrivacy().showAmount, isFalse);
      expect(
        ExportPrivacy.defaults.copyWith(showAmount: true).showAmount,
        isTrue,
      );
    });

    test('开关是不可变值：改了不会污染默认值', () {
      final on = ExportPrivacy.defaults.copyWith(showAmount: true);
      expect(on.showAmount, isTrue);
      expect(ExportPrivacy.defaults.showAmount, isFalse);
      expect(on, isNot(ExportPrivacy.defaults));
      expect(on.copyWith(showAmount: false), ExportPrivacy.defaults);
    });
  });
}
