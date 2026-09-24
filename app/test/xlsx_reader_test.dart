import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:younum/core/time/statistics_time.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/import_records.dart';
import 'package:younum/domain/models/ledger_transaction.dart';
import 'package:younum/domain/repositories/import_workflow.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/domain/rules/csv_parser.dart';
import 'package:younum/domain/rules/import_rules.dart';
import 'package:younum/domain/rules/xlsx_reader.dart';

/// XLSX 读取器的测试。
///
/// 分两层：
///
/// * 用**自己造的** xlsx 验格式处理（自闭合标签、跳列、跳行、日期样式、
///   实体转义…）—— 这些用例在任何机器上都能跑；
/// * 用**真实的**微信账单验端到端 —— 那份文件是私人的、被 .gitignore 排除，
///   所以在别的机器上会自动跳过，而不是假装通过。
void main() {
  group('Excel 数字格式', () {
    test('日期序列号换算（用真实账单里的值核对过）', () {
      // 真实文件里 B19 那一格就是 46281.61962962963。
      expect(XlsxReader.excelSerialToText(46281.61962962963), '2026-09-16 14:52:16');
      // 整点日期的序列号。
      expect(XlsxReader.excelSerialToText(46290), '2026-09-25 00:00:00');
      expect(XlsxReader.excelSerialToText(46281), '2026-09-16 00:00:00');
    });

    test('秒数四舍五入，不会把 :15.999 说成 :15', () {
      // 直接截断会把 14:52:15.999 说成 14:52:15，而 Excel 里显示的是 :16，
      // 账单时间对不上就查不出问题在哪。
      const noonish = 53535.0 / 86400; // 14:52:15
      expect(XlsxReader.excelSerialToText(46281 + noonish + 0.499 / 86400),
          '2026-09-16 14:52:15');
      expect(XlsxReader.excelSerialToText(46281 + noonish + 0.999 / 86400),
          '2026-09-16 14:52:16');
      // 当天最后一刻进位到次日。
      expect(XlsxReader.excelSerialToText(46281.99999999), '2026-09-17 00:00:00');
    });

    test('1900 年那条历史边界：序列号 61 是 1900-03-01，1 是 1900-01-01', () {
      // Excel 把 1900 当闰年，凭空多出一个 1900-02-29（序列号 60）。
      // 用 1899-12-30 作零点刚好把这段抵消掉；但这只对序列号 ≥ 61 成立，
      // 再往前的日期要补回一天，否则会少一天（1 会变成 1899-12-31）。
      expect(XlsxReader.excelSerialToText(61), '1900-03-01 00:00:00');
      expect(XlsxReader.excelSerialToText(59), '1900-02-28 00:00:00');
      expect(XlsxReader.excelSerialToText(1), '1900-01-01 00:00:00');
    });

    test('数值整形：去掉浮点尾巴，不留多余的零', () {
      expect(XlsxReader.numberToText(37.4), '37.4');
      expect(XlsxReader.numberToText(2605), '2605');
      expect(XlsxReader.numberToText(0.88), '0.88');
      // 浮点运算留下的尾巴必须收掉，否则金额解析会失败或算出离谱的数。
      expect(XlsxReader.numberToText(37.400000000000006), '37.4');
      expect(XlsxReader.numberToText(0.1 + 0.2), '0.3');
      // 去掉末尾的零只在有小数点时生效：100 绝不能变成 1。
      expect(XlsxReader.numberToText(100), '100');
      expect(XlsxReader.numberToText(100.0), '100');
      expect(XlsxReader.numberToText(1230.00), '1230');
      // 大到超过两位小数的精度就不再谈了：分以下的差异 Excel 里也看不见。
      expect(XlsxReader.numberToText(350.006), '350.01');
      expect(XlsxReader.numberToText(350.004), '350');
      // 离谱的大数原样给出，让下游当成「看不懂的数字」报错，而不是变成一串 0。
      expect(XlsxReader.numberToText(1e16), '10000000000000000.0');
      expect(XlsxReader.numberToText(1e21), contains('e+'));
    });
  });

  group('文件类型判断', () {
    test('按内容判断，而不是看后缀名', () {
      expect(XlsxReader.looksLikeXlsx(_zip(<String, String>{
        'x': 'y',
      })), isTrue, reason: 'zip 魔数 PK\\x03\\x04');
      expect(XlsxReader.looksLikeXlsx(utf8.encode('交易时间,金额')), isFalse);
      expect(XlsxReader.looksLikeXlsx(<int>[]), isFalse);
      expect(XlsxReader.looksLikeXlsx(<int>[0x50, 0x4B]), isFalse);
    });

    test('不是 xlsx 时给出明确原因', () {
      final (table, error) = XlsxReader.read(utf8.encode('a,b\n1,2'));

      expect(table, isNull);
      expect(error, isA<XlsxNotZip>());
      expect(error!.message, contains('xlsx'));
    });
  });

  group('表结构', () {
    test('跳过缺失的行号，行位置与文件一致', () {
      // 微信的导出里就是跳行的（第 6、16 行不存在）。不补齐的话，
      // 后面所有行的行号都会比文件里小，用户按行号回去核对会找错行。
      final xlsx = _buildXlsx(
        sheet: '<row r="1"><c r="A1" t="s"><v>0</v></c></row>'
            '<row r="3"><c r="A3" t="s"><v>1</v></c></row>',
        shared: <String>['第一行', '第三行'],
      );

      final (table, error) = XlsxReader.read(xlsx);
      expect(error, isNull);
      expect(table!.rows, hasLength(3));
      expect(table.rows[0], <String>['第一行']);
      expect(table.rows[1], isEmpty, reason: '第 2 行在文件里就不存在');
      expect(table.rows[2], <String>['第三行']);
    });

    test('跳过缺失的列，列位置与文件一致', () {
      // 一行里没有 E 列就不会有 <c r="E..">。按出现顺序摆放会让后面整体串位。
      final xlsx = _buildXlsx(
        sheet: '<row r="1">'
            '<c r="A1" t="s"><v>0</v></c>'
            '<c r="C1" t="s"><v>1</v></c>'
            '</row>',
        shared: <String>['甲', '丙'],
      );

      final (table, error) = XlsxReader.read(xlsx);
      expect(error, isNull);
      expect(table!.rows.first, <String>['甲', '', '丙']);
    });

    test('自闭合标签（没有值的单元格）不会让整行读不出来', () {
      // 样式表里的 <xf .../> 与空单元格的 <c .../> 都是自闭合的。
      final xlsx = _buildXlsx(
        sheet: '<row r="1"><c r="A1"/><c r="B1" t="s"><v>0</v></c></row>',
        shared: <String>['有值'],
      );

      final (table, error) = XlsxReader.read(xlsx);
      expect(error, isNull);
      expect(table!.rows.first, <String>['', '有值']);
    });

    test('XML 实体被还原', () {
      final xlsx = _buildXlsx(
        sheet: '<row r="1"><c r="A1" t="s"><v>0</v></c></row>',
        shared: <String>['A&amp;B &lt;C&gt; &#37; &#x4E2D;'],
      );

      final (table, _) = XlsxReader.read(xlsx);
      expect(table!.rows.first.first, 'A&B <C> % 中');
    });

    test('富文本片段会被接起来', () {
      final xlsx = _buildXlsx(
        sheet: '<row r="1"><c r="A1" t="s"><v>0</v></c></row>',
        sharedRaw: '<sst><si><r><t>砂糖橘</t></r><r><t>寄养费</t></r></si></sst>',
      );

      final (table, _) = XlsxReader.read(xlsx);
      expect(
        table!.rows.first.first,
        '砂糖橘寄养费',
        reason: '只取第一段的话，带强调的文字会剩一半',
      );
    });

    test('内联字符串也能读', () {
      final xlsx = _buildXlsx(
        sheet: '<row r="1"><c r="A1" t="inlineStr">'
            '<is><t>内联文本</t></is></c></row>',
      );

      final (table, _) = XlsxReader.read(xlsx);
      expect(table!.rows.first.first, '内联文本');
    });

    test('公式只取缓存值，不重算', () {
      // 指南 4.2.5：不得执行单元格公式。
      final xlsx = _buildXlsx(
        sheet: '<row r="1"><c r="A1" t="str"><f>SUM(B1:B2)</f><v>42</v></c></row>',
      );

      final (table, _) = XlsxReader.read(xlsx);
      expect(table!.rows.first.first, '42');
    });

    test('日期样式决定数字变成时间还是金额', () {
      // 同一个数字，靠样式区分。判错的后果是日期变成一串看不懂的数字，
      // 而用户会以为账单坏了。
      final xlsx = _buildXlsx(
        sheet: '<row r="1">'
            '<c r="A1" s="1"><v>46281.61962962963</v></c>'
            '<c r="B1" s="2"><v>37.4</v></c>'
            '</row>',
      );

      final (table, _) = XlsxReader.read(xlsx);
      expect(table!.rows.first, <String>['2026-09-16 14:52:16', '37.4']);
    });

    test('错误值当作空，让这一格按「缺内容」上报', () {
      final xlsx = _buildXlsx(
        sheet: '<row r="1"><c r="A1" t="e"><v>#N/A</v></c>'
            '<c r="B1" t="s"><v>0</v></c></row>',
        shared: <String>['有值'],
      );

      final (table, _) = XlsxReader.read(xlsx);
      expect(table!.rows.first, <String>['', '有值']);
    });

    test('空工作表明确报错', () {
      final xlsx = _buildXlsx(sheet: '');
      final (table, error) = XlsxReader.read(xlsx);

      expect(table, isNull);
      expect(error, isA<XlsxEmpty>());
    });
  });

  group('真实微信账单', () {
    // 这份文件是私人的，已被 .gitignore 排除。
    final directory = Directory('test/账单');
    final files = directory.existsSync()
        ? directory
              .listSync()
              .whereType<File>()
              .where((file) => file.path.toLowerCase().endsWith('.xlsx'))
              .toList()
        : <File>[];

    test('能读到真实文件（没有样本时跳过）', () {
      if (files.isEmpty) {
        markTestSkipped('没有真实账单样本（test/账单 下没有 .xlsx），跳过');
        return;
      }

      final bytes = files.first.readAsBytesSync();
      final (table, error) = XlsxReader.read(bytes);

      expect(error, isNull, reason: '$error');
      expect(table!.rows.length, greaterThan(20));
      expect(table.maxColumns, 11, reason: '微信导出是 A–K 共 11 列');
    });

    test('识别出表头，并把 6 笔全部解析出来（没有样本时跳过）', () {
      if (files.isEmpty) {
        markTestSkipped('没有真实账单样本，跳过');
        return;
      }

      final (xlsxTable, error) = XlsxReader.read(files.first.readAsBytesSync());
      expect(error, isNull);

      final table = CsvTable(
        rows: xlsxTable!.rows,
        delimiter: '',
        hasTrailingNewline: false,
      );
      final header = ImportRules.detectHeader(table);
      expect(header.isUsable, isTrue, reason: '$header');
      // 表头在第 18 行（下标 17）。
      expect(header.headerRowIndex, 17);
      expect(header.platformName, '微信支付');
      expect(header.columns[ImportField.occurredAt], 0);
      expect(header.columns[ImportField.amount], 5);

      final parsed = <RowParsed>[];
      for (var index = 0; index < table.rows.length; index++) {
        final result = ImportRules.parseRow(
          row: table.rows[index],
          rowNumber: index + 1,
          header: header,
        );
        if (result is RowParsed) parsed.add(result);
      }

      expect(parsed, hasLength(6), reason: '文件自己也写着「共6笔记录」');

      // 文件里自带汇总：「收入：2笔 1.76元」「支出：4笔 3022.40元」。
      // 这是最硬的断言 —— 它不由我们自己的代码生成。
      var expenseCents = 0;
      var incomeCents = 0;
      for (final row in parsed) {
        switch (row.direction) {
          case ImportDirection.expense:
            expenseCents += row.amountCents;
          case ImportDirection.income:
            incomeCents += row.amountCents;
          default:
            break;
        }
      }
      expect(expenseCents, 302240, reason: '要与文件里的「支出 3022.40 元」一致');
      expect(incomeCents, 176, reason: '要与文件里的「收入 1.76 元」一致');

      // 时间也要对：这份账单覆盖 2026-09-01 到 2026-09-25。
      for (final row in parsed) {
        final at = StatisticsTime.toLocal(row.occurredAtMs);
        expect(at.year, 2026);
        expect(at.month, 9);
        expect(at.day, inInclusiveRange(1, 25));
      }
    });

    test('整条链路：真实 xlsx 能暂存、提交，金额与文件汇总一致（没有样本时跳过）', () async {
      if (files.isEmpty) {
        markTestSkipped('没有真实账单样本，跳过');
        return;
      }

      final store = InMemoryLedgerStore();
      final repository = LedgerRepository(store);
      await repository.initialize();
      const real = DemoLedgerSeed.realLedgerId;

      final result = await repository.stageImport(
        ledgerId: real,
        fileName: files.first.uri.pathSegments.last,
        bytes: files.first.readAsBytesSync(),
        sourceNamespace: 'wechat',
      );

      expect(result, isA<ImportStaged>(), reason: '$result');
      final staged = result as ImportStaged;
      expect(staged.preview.format, 'XLSX');
      expect(staged.preview.freshCount, 6);

      // 暂存不碰正式账。
      expect((await repository.dataset(ledgerId: real)).transactions, isEmpty);

      final committed = await repository.commitImport(
        ledgerId: real,
        batchId: staged.preview.batchId,
      );
      expect(committed.count, 6);

      final dataset = await repository.dataset(ledgerId: real);
      var expenseCents = 0;
      var incomeCount = 0;
      for (final transaction in dataset.transactions) {
        if (transaction.nature == TransactionNature.expense) {
          expenseCents += transaction.amountCents;
        }
        if (transaction.nature == TransactionNature.income) {
          incomeCount += 1;
        }
      }
      expect(expenseCents, 302240, reason: '文件里的「支出 3022.40 元」');
      expect(incomeCount, 2, reason: '文件里的「收入 2 笔」');
    });
  });
}

// -----------------------------------------------------------------------------
// 造一个最小但合法的 xlsx
// -----------------------------------------------------------------------------

/// 缺省样式表：两个 xf，索引 1 是日期格式。
const String _defaultStyles =
    '<styleSheet><numFmts count="1">'
    '<numFmt numFmtId="164" formatCode="yyyy-mm-dd hh:mm:ss"/>'
    '</numFmts><cellXfs count="2">'
    '<xf numFmtId="0"/><xf numFmtId="164" applyNumberFormat="1"/>'
    '</cellXfs></styleSheet>';

/// 组装一份 xlsx（zip）字节。
Uint8List _buildXlsx({
  required String sheet,
  List<String>? shared,
  String? sharedRaw,
}) {
  final strings = sharedRaw ??
      '<sst count="${shared?.length ?? 0}">'
          '${(shared ?? const <String>[]).map((s) => '<si><t>$s</t></si>').join()}'
          '</sst>';

  return _zip(<String, String>{
    'xl/workbook.xml':
        '<workbook><sheets><sheet name="账单明细" sheetId="1" r:id="rId1"/></sheets></workbook>',
    'xl/_rels/workbook.xml.rels':
        '<Relationships><Relationship Id="rId1" '
        'Target="worksheets/sheet1.xml"/></Relationships>',
    'xl/styles.xml': _defaultStyles,
    'xl/sharedStrings.xml': strings,
    'xl/worksheets/sheet1.xml':
        '<worksheet><sheetData>$sheet</sheetData></worksheet>',
  });
}

/// 把一批文件打成 zip（**真正压缩**，走 DEFLATE）。
///
/// 用 DEFLATE 而不是 STORED：微信导出的文件是真压缩的，
/// 只测不压缩的分支等于没测解压。
Uint8List _zip(Map<String, String> files) => _zipRaw(<String, List<int>>{
  for (final entry in files.entries) entry.key: utf8.encode(entry.value),
});

Uint8List _zipRaw(Map<String, List<int>> files) {
  final local = BytesBuilder();
  final central = BytesBuilder();
  final offsets = <String, int>{};

  for (final entry in files.entries) {
    final name = utf8.encode(entry.key);
    final payload = Uint8List.fromList(entry.value);
    final compressed = Uint8List.fromList(
      ZLibEncoder(raw: true).convert(payload),
    );
    offsets[entry.key] = local.length;

    local.add(_u32(0x04034B50));
    local.add(_u16(20)); // version needed
    local.add(_u16(0)); // flags
    local.add(_u16(8)); // method = deflate
    local.add(_u16(0)); // time
    local.add(_u16(0)); // date
    local.add(_u32(0)); // crc（读取时不校验，置 0 省掉实现）
    local.add(_u32(compressed.length));
    local.add(_u32(payload.length));
    local.add(_u16(name.length));
    local.add(_u16(0)); // extra
    local.add(name);
    local.add(compressed);
  }

  for (final entry in files.entries) {
    final name = utf8.encode(entry.key);
    final payload = Uint8List.fromList(entry.value);
    final compressed = Uint8List.fromList(
      ZLibEncoder(raw: true).convert(payload),
    );

    central.add(_u32(0x02014B50));
    central.add(_u16(20)); // version made by
    central.add(_u16(20)); // version needed
    central.add(_u16(0)); // flags
    central.add(_u16(8)); // method
    central.add(_u16(0)); // time
    central.add(_u16(0)); // date
    central.add(_u32(0)); // crc
    central.add(_u32(compressed.length));
    central.add(_u32(payload.length));
    central.add(_u16(name.length));
    central.add(_u16(0)); // extra
    central.add(_u16(0)); // comment
    central.add(_u16(0)); // disk
    central.add(_u16(0)); // internal attrs
    central.add(_u32(0)); // external attrs
    central.add(_u32(offsets[entry.key]!));
    central.add(name);
  }

  final centralBytes = central.toBytes();
  final builder = BytesBuilder()
    ..add(local.toBytes())
    ..add(centralBytes);

  builder.add(_u32(0x06054B50));
  builder.add(_u16(0)); // disk
  builder.add(_u16(0)); // central disk
  builder.add(_u16(files.length));
  builder.add(_u16(files.length));
  builder.add(_u32(centralBytes.length));
  builder.add(_u32(local.length));
  builder.add(_u16(0)); // comment length

  return builder.toBytes();
}

List<int> _u16(int value) => <int>[value & 0xFF, (value >> 8) & 0xFF];

List<int> _u32(int value) => <int>[
  value & 0xFF,
  (value >> 8) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 24) & 0xFF,
];
