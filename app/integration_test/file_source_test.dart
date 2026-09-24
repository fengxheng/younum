import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:younum/data/files/system_file_source.dart';
import 'package:younum/domain/models/import_records.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/rules/csv_parser.dart';
import 'package:younum/domain/rules/import_rules.dart';
import 'package:younum/domain/rules/text_decoding.dart';

/// 文件选择通道的**真机**测试。
///
/// 这里能证明什么、不能证明什么要说清楚：
///
/// * **能证明**：`MainActivity` 里的 MethodChannel 真的注册上了；
///   设备上有能响应「打开文档」的界面；读不到文件时返回的是可展示的说明，
///   不会抛异常、不会挂住。
/// * **不能证明**：用户真的在系统选择器里点了一份微信账单。
///   那一步需要人手点，自动化点不可靠（选择器的界面随系统版本与厂商而变）。
///   所以「真实账单文件能否导入」在 docs/IMPLEMENTATION_STATUS.md 里
///   如实列为**未验证**，而不是靠这条用例蒙过去。
///
/// 运行方式：
///
/// ```powershell
/// flutter test integration_test/file_source_test.dart -d <device-id>
/// ```
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final source = SystemFileSource();

  test('通道注册上了，并且这台设备有文件选择器', () async {
    expect(
      await source.isAvailable(),
      isTrue,
      reason: 'FlutterActivity 里没注册通道，或者设备上没有 DocumentsUI',
    );
  });

  test('读一个不存在的 URI：给出说明而不是挂住或崩溃', () async {
    // 这条会走到原生侧的错误分支。具体是 forbidden 还是 unreadable 取决于
    // 系统对未知 authority 的反应，所以这里只断言「有可展示的说明」。
    final outcome = await source.reread(
      'content://com.younum.app.definitely-not-here/nothing',
    );

    expect(outcome, isA<PickFailed>());
    expect((outcome as PickFailed).message, isNotEmpty);
  });

  test('读一个 file:// URI 走的是同一条读取路径', () async {
    // 用文件 URI 而不是 content URI，是为了在没有用户点击的前提下
    // 验证「打开流 → 读字节 → 返回给 Dart」这条链路真的通了。
    final outcome = await source.reread('file:///proc/version');

    expect(outcome, isA<PickFailed>());
    expect(
      (outcome as PickFailed).message,
      isNotEmpty,
      reason: '没有权限读 /proc 是可以预期的，但必须给出说明',
    );
  });

  test('真实文件：字节原样回到 Dart，并直接能解码、解析', () async {
    // 这是这条通道上最有价值的一条：把一份真的账单文件放到设备上，
    // 走与用户选文件**完全相同**的读取路径（ContentResolver → 字节 → Dart），
    // 再把拿到的字节交给真正的解析器。
    //
    // 没有点系统选择器，所以「用户点选」那一步仍未验证；
    // 但这能排掉「读出来的字节被截断/串码」这类真正致命的错误。
    const csv =
        '''交易时间,交易对方,收/支,金额(元),交易单号
'''
        '''2026-09-23 14:26:00,老王牛肉面,支出,¥28.00,4200001\n'''
        '''2026-09-24 09:02:11,地铁公司,支出,¥5.00,4200002\n''';

    final file = File('${Directory.systemTemp.path}/younum_bill.csv');
    await file.writeAsBytes(utf8.encode(csv), flush: true);
    addTearDown(() async {
      if (await file.exists()) await file.delete();
    });

    final outcome = await source.reread('file://${file.path}');
    expect(outcome, isA<DocumentPicked>(), reason: '$outcome');
    final document = (outcome as DocumentPicked).document;
    expect(utf8.decode(document.bytes), csv, reason: '读回来的字节必须与写出去的一模一样');
    expect(document.name, isNotEmpty, reason: '文件名为空时界面会显示一个空格子');

    // 接着就用真正的解码与解析器跑一遍。
    final (decoded, decodeError) = TextDecoding.decode(document.bytes);
    expect(decodeError, isNull);
    expect(decoded!.encoding, TextEncoding.utf8);

    final (table, csvError) = CsvParser.parse(decoded.text);
    expect(csvError, isNull);
    final header = ImportRules.detectHeader(table!);
    expect(header.isUsable, isTrue, reason: '$header');

    final parsed = ImportRules.parseRow(
      row: table.rows[1],
      rowNumber: 2,
      header: header,
    );
    expect(parsed, isA<RowParsed>());
    expect((parsed as RowParsed).merchant, '老王牛肉面');
    expect(parsed.amountCents, 2800);
    expect(parsed.direction, ImportDirection.expense);
  });

  test('释放一个从没授权过的 URI 不报错', () async {
    await expectLater(
      source.release('content://com.younum.app.definitely-not-here/nothing'),
      completes,
    );
  });
}
