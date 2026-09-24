import 'package:flutter_test/flutter_test.dart';
import 'package:younum/domain/rules/csv_parser.dart';

/// CSV 解析。
///
/// 指南 4.2.4 点名要求支持：引号、字段内逗号、字段内换行、BOM、CRLF。
/// BOM 由 [TextDecoding] 在解码阶段去掉，这里只测结构。
void main() {
  group('基本结构', () {
    test('普通两行两列', () {
      final (table, error) = CsvParser.parse('a,b\nc,d');

      expect(error, isNull);
      expect(table!.rows, <List<String>>[
        <String>['a', 'b'],
        <String>['c', 'd'],
      ]);
      expect(table.delimiter, ',');
    });

    test('末尾多一个换行不算多一行数据', () {
      final (table, _) = CsvParser.parse('a,b\nc,d\n');
      expect(table!.rows, hasLength(2));
      expect(table.hasTrailingNewline, isTrue);
    });

    test('末尾连续多个空行也会被丢掉', () {
      final (table, _) = CsvParser.parse('a,b\n\n\n');
      expect(table!.rows, <List<String>>[
        <String>['a', 'b'],
      ]);
    });

    test('行内字段数不一致时如实保留，不补齐也不报错', () {
      // 真实账单里表头、说明行、合计行的列数经常不一样。
      final (table, error) = CsvParser.parse('h1,h2,h3\n说明行\n1,2,3');

      expect(error, isNull);
      expect(table!.maxColumns, 3);
      expect(table.columnCountOf(1), 1);
      expect(table.rows[1], <String>['说明行']);
    });

    test('空内容与纯空白都明确失败', () {
      expect(CsvParser.parse('').$2, isA<CsvEmpty>());
      expect(CsvParser.parse('   \n  \n').$2, isA<CsvEmpty>());
    });
  });

  group('引号', () {
    test('引号里的逗号不算分隔符', () {
      final (table, _) = CsvParser.parse('"肯德基, 中关村店",¥35.00');
      expect(table!.rows.single, <String>['肯德基, 中关村店', '¥35.00']);
    });

    test('引号里的换行属于同一个字段', () {
      final (table, _) = CsvParser.parse('"第一行\n第二行",x');
      expect(table!.rows, hasLength(1));
      expect(table.rows.single, <String>['第一行\n第二行', 'x']);
    });

    test('两个双引号表示一个双引号', () {
      final (table, _) = CsvParser.parse('"他说 ""好"" 的",x');
      expect(table!.rows.single, <String>['他说 "好" 的', 'x']);
    });

    test('空引号字段是空字符串，不是 null', () {
      final (table, _) = CsvParser.parse('"",b');
      expect(table!.rows.single, <String>['', 'b']);
    });

    test('多个字段都带引号', () {
      final (table, _) = CsvParser.parse('"a","b,c","d""e"');
      expect(table!.rows.single, <String>['a', 'b,c', 'd"e']);
    });

    test('引号没有闭合时明确失败，并指出行号与字段序号', () {
      final (table, error) = CsvParser.parse('a,b\n"没闭合,c');

      expect(table, isNull);
      expect(error, isA<CsvUnterminatedQuote>());
      final unterminated = error! as CsvUnterminatedQuote;
      expect(unterminated.line, 2);
      expect(unterminated.column, 1);
    });

    test('引号出现在字段中间时按普通字符处理，不吞后面的内容', () {
      final (table, _) = CsvParser.parse('ab"cd,e');
      expect(table!.rows.single, <String>['ab"cd', 'e']);
    });
  });

  group('换行', () {
    test('CRLF', () {
      final (table, _) = CsvParser.parse('a,b\r\nc,d');
      expect(table!.rows, <List<String>>[
        <String>['a', 'b'],
        <String>['c', 'd'],
      ]);
    });

    test('只有 CR', () {
      final (table, _) = CsvParser.parse('a,b\rc,d');
      expect(table!.rows, hasLength(2));
      expect(table.rows[1], <String>['c', 'd']);
    });

    test('同一个文件里混用 CRLF 与 LF', () {
      final (table, _) = CsvParser.parse('a,b\r\nc,d\ne,f');
      expect(table!.rows, hasLength(3));
      expect(table.rows.last, <String>['e', 'f']);
    });

    test('引号内的 CRLF 不产生新行', () {
      final (table, _) = CsvParser.parse('"a\r\nb",c');
      expect(table!.rows, hasLength(1));
      expect(table.rows.single.first, 'a\r\nb');
    });
  });

  group('分隔符探测', () {
    test('逗号', () {
      expect(CsvParser.detectDelimiter('a,b,c\n1,2,3'), ',');
    });

    test('制表符', () {
      expect(CsvParser.detectDelimiter('a\tb\tc\n1\t2\t3'), '\t');
    });

    test('分号', () {
      expect(CsvParser.detectDelimiter('a;b;c\n1;2;3'), ';');
    });

    test('备注里的逗号不会被误判成主分隔符', () {
      // 制表符切出来列数一致；逗号切出来每行列数都不一样。
      const text = 'a\tb\n'
          '1\t备注里有,逗号,好几处\n'
          '2\t再来,一个';
      expect(CsvParser.detectDelimiter(text), '\t');
    });

    test('单列文件不会硬找一个分隔符出来', () {
      // 只有一列时 modeCount < 2，所有候选都不合格，回落到默认的逗号。
      expect(CsvParser.detectDelimiter('只有一列\n第二行'), ',');
    });
  });

  group('贴近真实账单的用例', () {
    test('带说明行、引号商户、字段内换行与合计行的微信风格 CSV', () {
      const text = '微信支付账单明细\r\n'
          '导出时间：2026-09-24 10:32\r\n'
          '交易时间,交易类型,商户,金额(元),收/支,交易状态\r\n'
          '2026-09-23 14:26:00,商户消费,"MANNER COFFEE, 国贸店",-28.00,支出,支付成功\r\n'
          '2026-09-22 18:09:00,商户消费,"优衣库\nUNIQLO",-299.00,支出,支付成功\r\n'
          '共 2 笔,合计,-327.00\r\n';

      final (table, error) = CsvParser.parse(text);
      expect(error, isNull);
      expect(table!.delimiter, ',');
      expect(table.rows, hasLength(6));

      // 商户里的逗号与换行都没有破坏结构。
      expect(table.rows[3][2], 'MANNER COFFEE, 国贸店');
      expect(table.rows[4][2], '优衣库\nUNIQLO');
      // 合计行自然是缺列的，如实保留。
      expect(table.columnCountOf(5), 3);
    });
  });
}
