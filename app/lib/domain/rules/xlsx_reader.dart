/// XLSX 读取：把工作表读成与 CSV 一样的「行 × 列」文本。
///
/// ## 为什么要自己写，而不是引一个电子表格库
///
/// 实现指南 4.2.5 明确要求：「XLSX 解析器须先做 Android 真机兼容性与内存验证，
/// 再锁定依赖。**不能未经验证就引入依赖桌面 Java API 的整个电子表格库**。」
///
/// 微信/支付宝导出的 `.xlsx` 其实非常规整：一个 zip，里面有
/// `sharedStrings.xml`（字符串表）与 `xl/worksheets/sheet1.xml`（单元格）。
/// 需要的能力只有三样：
///
/// * 从 zip 里取出几个条目 —— 用 `dart:io` 的 `ZLibDecoder(raw: true)` 解 DEFLATE，
///   不需要任何依赖；
/// * 认几个固定标签 —— 一个够用的 XML 扫描器就够，不必上完整 XML 库；
/// * 把「Excel 日期序列号」还原成时间 —— 十几行算术。
///
/// 相比之下，引一个完整表格库要背下它的公式引擎、图表、样式模型和
/// 原生依赖，而其中 99% 在这个场景里用不上，还要跟着 Flutter/AGP 升级维护。
///
/// ## 输出为什么是文本
///
/// 读出来统一变成「与 CSV 一样的文本」，于是**下游完全不需要知道文件是
/// CSV 还是 XLSX**：`ImportRules` 的表头识别、字段映射、逐行标准化、
/// 去重判断全部照旧。日期被格式化成 `yyyy-MM-dd HH:mm:ss` ——
/// 正是 `ImportRules.parseOccurredAt` 已经认识的写法。
///
/// ## 明确不做的事
///
/// * **不执行公式**（指南 4.2.5）。单元格有 `<f>` 时只取它缓存的 `<v>`，
///   也就是「打开文件时看到的值」，而不是重算一遍。
/// * 不追外部链接、不读宏、不处理图表。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 读取失败的原因。
sealed class XlsxError {
  const XlsxError(this.message);

  final String message;
}

/// 不是 xlsx（连 zip 都不是）。
final class XlsxNotZip extends XlsxError {
  const XlsxNotZip()
    : super('这个文件不是 xlsx（它连压缩包都不是）。');
}

/// 压缩包结构坏了。
final class XlsxCorrupt extends XlsxError {
  const XlsxCorrupt(super.message);
}

/// 压缩包里没有工作表。
final class XlsxNoSheet extends XlsxError {
  const XlsxNoSheet() : super('这个 xlsx 里没有找到工作表。');
}

/// 用到了本实现不支持的特性（例如超过 4GB 的 ZIP64）。
///
/// 明确报错而不是硬读：硬读出来的东西会是错的，而错的数据看起来
/// 和「导入成功」一模一样。
final class XlsxUnsupported extends XlsxError {
  const XlsxUnsupported(super.message);
}

/// 工作表是空的。
final class XlsxEmpty extends XlsxError {
  const XlsxEmpty() : super('这个 xlsx 里没有读到任何一行。');
}

/// 读出来的表格。
///
/// 与 `CsvTable` 一样是**参差不齐**的行：某一行的尾部空格由
/// [maxColumns] 补齐，而不是每行都塞满空字符串。
final class XlsxTable {
  const XlsxTable({required this.rows, required this.sheetName});

  final List<List<String>> rows;

  /// 工作表名，展示给用户看，便于他确认选对了 sheet。
  final String sheetName;

  bool get isEmpty => rows.isEmpty;

  int get maxColumns {
    var max = 0;
    for (final row in rows) {
      if (row.length > max) max = row.length;
    }
    return max;
  }

  @override
  String toString() => 'XlsxTable($sheetName, ${rows.length} 行, $maxColumns 列)';
}

/// XLSX 读取器。
abstract final class XlsxReader {
  /// ZIP 的魔数（`PK\x03\x04`）。
  ///
  /// 用它判断文件类型，而不是看后缀名 —— 指南 4.2.3 要求
  /// 「文件名后缀、MIME 和文件内容联合判断，不能仅依据后缀就信任内容」。
  static const List<int> zipMagic = <int>[0x50, 0x4B, 0x03, 0x04];

  /// 这个字节串看起来是不是 xlsx（实际判断的是「是不是 zip」）。
  static bool looksLikeXlsx(List<int> bytes) {
    if (bytes.length < zipMagic.length) return false;
    for (var index = 0; index < zipMagic.length; index++) {
      if (bytes[index] != zipMagic[index]) return false;
    }
    return true;
  }

  /// 读一份 xlsx。
  static (XlsxTable?, XlsxError?) read(List<int> bytes) {
    if (!looksLikeXlsx(bytes)) return (null, const XlsxNotZip());

    final (entries, zipError) = _unzip(bytes);
    if (zipError != null) return (null, zipError);
    final files = entries!;

    // 字符串表。缺失是合法的（纯数字表就是没有）。
    final sharedStrings = files['xl/sharedstrings.xml'] == null
        ? const <String>[]
        : _readSharedStrings(_decodeXml(files['xl/sharedstrings.xml']!));

    final sheetPath = _firstSheetPath(files) ?? 'xl/worksheets/sheet1.xml';
    final sheetBytes = files[sheetPath];
    if (sheetBytes == null) return (null, const XlsxNoSheet());

    final styles = files['xl/styles.xml'] == null
        ? const <_CellStyle>[]
        : _readStyles(_decodeXml(files['xl/styles.xml']!));

    final rows = _readSheet(
      _decodeXml(sheetBytes),
      sharedStrings: sharedStrings,
      styles: styles,
    );
    if (rows.isEmpty) return (null, const XlsxEmpty());

    return (
      XlsxTable(rows: rows, sheetName: _sheetName(files) ?? '工作表 1'),
      null,
    );
  }

  // ---------------------------------------------------------------------------
  // Excel 数字格式
  // ---------------------------------------------------------------------------

  /// Excel 的日期纪元。序列号 1 是 1900-01-01。
  ///
  /// 用 1899-12-30 作零点，是为了把 Excel 那个著名的 bug 一并抵消掉：
  /// 它把 1900 年当成闰年，于是存在一个不存在的序列号 60（1900-02-29）。
  /// 对序列号 ≥ 61（即 1900-03-01 之后）来说，这样算出来的日期是对的 ——
  /// 而账单里的日期永远是现代的，所以这是实际生效的那条分支。
  /// 序列号 1–59（1900-03-01 之前）要补回一天，见 [excelSerialToText]。
  static final DateTime _excelEpoch = DateTime.utc(1899, 12, 30);

  /// 日期序列号 → `yyyy-MM-dd HH:mm:ss`。
  ///
  /// 秒数四舍五入：序列号是浮点数，直接截断会让 14:52:15.999 变成 14:52:15，
  /// 而 Excel 里显示的其实是 14:52:16。账单的时间要能对上。
  static String excelSerialToText(double serial) {
    if (!serial.isFinite) return serial.toString();
    var days = serial.floor();
    // 1900-03-01 之前要补一天：那个区间里 Excel 并没有凭空多出 1900-02-29，
    // 所以「1899-12-30 + n」会比真实日期少一天。序列号 60 往上才需要这个偏移。
    if (days < 61) days += 1;
    var seconds = ((serial - serial.floor()) * 86400).round();
    if (seconds >= 86400) {
      // 0.999999 秒进位到第二天。
      days += 1;
      seconds -= 86400;
    }
    final date = _excelEpoch.add(Duration(days: days, seconds: seconds));
    return _formatDateTime(date);
  }

  /// 数值单元格 → 文本。
  ///
  /// 为什么要整形：Excel 把 37.4 存成 `37.4` 没问题，但浮点运算过的值
  /// 可能是 `37.400000000000006`，直接当金额解析会失败或算出巨大误差。
  /// 金额的有效精度就是「分」，所以保留两位小数再去掉多余的零。
  static String numberToText(double value) {
    if (!value.isFinite) return value.toString();
    // 极大的数（例如把日期当数值存错列）不整形，原样给出去，
    // 让下游按「看不懂的数字」报错，而不是变成一串 0。
    if (value.abs() >= 1e15) return value.toString();
    final fixed = value.toStringAsFixed(2);
    if (!fixed.contains('.')) return fixed;
    var trimmed = fixed.replaceFirst(RegExp(r'0+$'), '');
    if (trimmed.endsWith('.')) trimmed = trimmed.substring(0, trimmed.length - 1);
    return trimmed;
  }

  static String _formatDateTime(DateTime date) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
  }

  // ---------------------------------------------------------------------------
  // zip
  // ---------------------------------------------------------------------------

  /// 解出压缩包里的所有条目，键是**小写**的文件路径。
  static (Map<String, Uint8List>?, XlsxError?) _unzip(List<int> bytes) {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final view = ByteData.sublistView(data);

    final eocd = _findEndOfCentralDirectory(data, view);
    if (eocd < 0) {
      return (null, const XlsxCorrupt('这个 xlsx 的压缩包结构不完整（找不到中央目录）。'));
    }

    final entryCount = view.getUint16(eocd + 10, Endian.little);
    var offset = view.getUint32(eocd + 16, Endian.little);

    final files = <String, Uint8List>{};
    for (var index = 0; index < entryCount; index++) {
      if (offset + 46 > data.length) {
        return (null, const XlsxCorrupt('压缩包的中央目录被截断了。'));
      }
      if (view.getUint32(offset, Endian.little) != 0x02014B50) {
        return (null, const XlsxCorrupt('压缩包的中央目录格式不对。'));
      }

      final method = view.getUint16(offset + 10, Endian.little);
      final compressedSize = view.getUint32(offset + 20, Endian.little);
      final uncompressedSize = view.getUint32(offset + 24, Endian.little);
      final nameLength = view.getUint16(offset + 28, Endian.little);
      final extraLength = view.getUint16(offset + 30, Endian.little);
      final commentLength = view.getUint16(offset + 32, Endian.little);
      final localOffset = view.getUint32(offset + 42, Endian.little);

      final nameBytes = data.sublist(
        offset + 46,
        offset + 46 + nameLength,
      );
      final name = utf8.decode(nameBytes, allowMalformed: true).toLowerCase();

      if (compressedSize == 0xFFFFFFFF ||
          uncompressedSize == 0xFFFFFFFF ||
          localOffset == 0xFFFFFFFF) {
        return (
          null,
          const XlsxUnsupported('这个 xlsx 是 ZIP64 格式（超过 4GB），暂时读不了。'),
        );
      }

      final Uint8List? content;
      try {
        content = _readEntry(
          data,
          view,
          localOffset: localOffset,
          method: method,
          compressedSize: compressedSize,
        );
      } on _UnsupportedCompression catch (error) {
        return (
          null,
          XlsxUnsupported('这个 xlsx 用了不支持的压缩方式（${error.method}），暂时读不了。'),
        );
      }
      if (content == null) {
        return (null, XlsxCorrupt('压缩包里的 $name 读不出来。'));
      }
      files[name] = content;

      offset += 46 + nameLength + extraLength + commentLength;
    }

    return (files, null);
  }

  /// 从结尾往前找「中央目录结束记录」。
  ///
  /// 它后面最多还有 65535 字节的注释，所以只需要往回扫这么多。
  static int _findEndOfCentralDirectory(Uint8List data, ByteData view) {
    if (data.length < 22) return -1;
    final lowest = data.length - 22 - 65535;
    for (var offset = data.length - 22; offset >= (lowest < 0 ? 0 : lowest); offset--) {
      if (view.getUint32(offset, Endian.little) == 0x06054B50) return offset;
    }
    return -1;
  }

  static Uint8List? _readEntry(
    Uint8List data,
    ByteData view, {
    required int localOffset,
    required int method,
    required int compressedSize,
  }) {
    if (localOffset + 30 > data.length) return null;
    if (view.getUint32(localOffset, Endian.little) != 0x04034B50) return null;

    final nameLength = view.getUint16(localOffset + 26, Endian.little);
    final extraLength = view.getUint16(localOffset + 28, Endian.little);
    final start = localOffset + 30 + nameLength + extraLength;
    if (start + compressedSize > data.length) return null;
    final payload = Uint8List.sublistView(data, start, start + compressedSize);

    switch (method) {
      case 0: // 不压缩
        return payload;
      case 8: // DEFLATE。raw: true 表示没有 zlib 头，正是 zip 里的写法。
        try {
          final decoded = ZLibDecoder(raw: true).convert(payload);
          return decoded is Uint8List ? decoded : Uint8List.fromList(decoded);
        } on FormatException {
          return null;
        }
      default:
        // 压缩方式不认识：让调用方报一个明确的错，
        // 而不是把一堆压缩后的字节当成 XML 去读。
        throw _UnsupportedCompression(method);
    }
  }

  static String _decodeXml(Uint8List bytes) {
    // xlsx 内部固定是 UTF-8（XML 声明里也是）。
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    return text;
  }

  // ---------------------------------------------------------------------------
  // 工作表与样式
  // ---------------------------------------------------------------------------

  /// 第一个工作表的路径（优先用 workbook 的关系表解析）。
  static String? _firstSheetPath(Map<String, Uint8List> files) {
    final workbook = files['xl/workbook.xml'];
    final rels = files['xl/_rels/workbook.xml.rels'];
    if (workbook == null || rels == null) return null;

    final sheets = _elements(_decodeXml(workbook), 'sheet');
    if (sheets.isEmpty) return null;
    final relId = sheets.first.attributes['r:id'] ?? sheets.first.attributes['id'];
    if (relId == null) return null;

    for (final relationship in _elements(_decodeXml(rels), 'Relationship')) {
      if (relationship.attributes['Id'] != relId) continue;
      final target = relationship.attributes['Target'];
      if (target == null) continue;
      // 关系里的路径是相对 xl/ 的，可能是 "worksheets/sheet1.xml"。
      final normalized = target.startsWith('/')
          ? target.substring(1).toLowerCase()
          : 'xl/${target.replaceFirst(RegExp(r'^\./'), '')}'.toLowerCase();
      if (files.containsKey(normalized)) return normalized;
    }
    return null;
  }

  static String? _sheetName(Map<String, Uint8List> files) {
    final workbook = files['xl/workbook.xml'];
    if (workbook == null) return null;
    final sheets = _elements(_decodeXml(workbook), 'sheet');
    return sheets.isEmpty ? null : sheets.first.attributes['name'];
  }

  /// 读样式表里的「单元格格式」，用来判断一个数字到底是日期还是金额。
  ///
  /// 这一步不能省：`46281.61962962963` 既可能是日期也可能是金额，
  /// 只有样式能区分。判错的后果是日期变成一串看不懂的数字，
  /// 而用户会以为账单坏了。
  static List<_CellStyle> _readStyles(String xml) {
    final formats = <int, String>{};
    for (final numFmt in _elements(xml, 'numFmt')) {
      final id = int.tryParse(numFmt.attributes['numFmtId'] ?? '');
      final code = numFmt.attributes['formatCode'];
      if (id != null && code != null) formats[id] = code;
    }

    final styles = <_CellStyle>[];
    final cellXfs = _elements(xml, 'cellXfs');
    if (cellXfs.isEmpty) return styles;

    for (final xf in _elements(cellXfs.first.inner, 'xf')) {
      final id = int.tryParse(xf.attributes['numFmtId'] ?? '') ?? 0;
      final code = formats[id];
      styles.add(
        _CellStyle(
          numFmtId: id,
          formatCode: code,
          isDate: code != null ? _looksLikeDateFormat(code) : _isBuiltinDateFormat(id),
        ),
      );
    }
    return styles;
  }

  /// 内置的日期格式 id（ECMA-376 里的 14–22、45–47）。
  static bool _isBuiltinDateFormat(int numFmtId) =>
      (numFmtId >= 14 && numFmtId <= 22) ||
      (numFmtId >= 45 && numFmtId <= 47) ||
      numFmtId == 27 ||
      (numFmtId >= 30 && numFmtId <= 36) ||
      (numFmtId >= 50 && numFmtId <= 58);

  /// 自定义格式串里有没有日期/时间的占位符。
  ///
  /// 只看 `y m d h s` 这几个字母：`¥#,##0.00` 里一个都没有，
  /// 而 `yyyy-mm-dd hh:mm:ss` 全是。方括号里的颜色/条件段先去掉，
  /// 免得 `[Red]` 里的 r 被误判。
  static bool _looksLikeDateFormat(String code) {
    final cleaned = code.replaceAll(RegExp(r'\[[^\]]*\]'), '');
    return RegExp(r'[ymdhs]', caseSensitive: false).hasMatch(cleaned);
  }

  /// 读取单元格。
  ///
  /// `r="A18"` 里的列字母很重要：单元格可以跳列（这一行没有 E 列就不会
  /// 有 `<c r="E..">`），如果按出现顺序摆放，后面的列会整体串位。
  static List<List<String>> _readSheet(
    String xml, {
    required List<String> sharedStrings,
    required List<_CellStyle> styles,
  }) {
    final sheetData = _elements(xml, 'sheetData');
    if (sheetData.isEmpty) return const <List<String>>[];

    final rows = <List<String>>[];
    for (final row in _elements(sheetData.first.inner, 'row')) {
      final rowNumber = int.tryParse(row.attributes['r'] ?? '') ?? rows.length + 1;
      // 行号可以跳（微信的导出里第 6、16 行就不存在），补齐空行，
      // 否则下面所有行的行号都会对不上文件，用户按行号回去核对时会找错。
      while (rows.length < rowNumber - 1) {
        rows.add(<String>[]);
      }

      final cells = <String>[];
      for (final cell in _elements(row.inner, 'c')) {
        final reference = cell.attributes['r'];
        final column = reference == null ? cells.length : _columnIndex(reference);
        while (cells.length < column) {
          cells.add('');
        }
        cells.add(_cellText(cell, sharedStrings, styles));
      }
      while (cells.isNotEmpty && cells.last.isEmpty) {
        cells.removeLast();
      }
      rows.add(cells);
    }

    // 末尾的空行去掉：它们只是行号补齐的副产物。
    while (rows.isNotEmpty && rows.last.isEmpty) {
      rows.removeLast();
    }
    return rows;
  }

  static String _cellText(
    _XmlElement cell,
    List<String> sharedStrings,
    List<_CellStyle> styles,
  ) {
    final type = cell.attributes['t'] ?? 'n';

    // 内联字符串：内容直接在 <is> 里，不经过字符串表。
    if (type == 'inlineStr') {
      final inline = _elements(cell.inner, 'is');
      if (inline.isEmpty) return '';
      return _allText(inline.first.inner);
    }

    final values = _elements(cell.inner, 'v');
    if (values.isEmpty) return '';
    final raw = _decodeEntities(values.first.inner);

    switch (type) {
      case 's':
        final index = int.tryParse(raw.trim());
        if (index == null || index < 0 || index >= sharedStrings.length) return '';
        return sharedStrings[index];
      case 'str':
        // 公式的字符串结果。只取缓存值，不重算（指南 4.2.5）。
        return raw;
      case 'b':
        return raw.trim() == '1' ? 'TRUE' : 'FALSE';
      case 'e':
        // 错误值（#N/A 之类）当作空，让这一格按「缺内容」上报。
        return '';
      default:
        break;
    }

    final number = double.tryParse(raw.trim());
    if (number == null) return raw;

    final styleIndex = int.tryParse(cell.attributes['s'] ?? '');
    if (styleIndex != null &&
        styleIndex >= 0 &&
        styleIndex < styles.length &&
        styles[styleIndex].isDate) {
      return excelSerialToText(number);
    }
    return numberToText(number);
  }

  /// `A18` → 0，`K18` → 10，`AA1` → 26。
  static int _columnIndex(String reference) {
    var value = 0;
    for (var index = 0; index < reference.length; index++) {
      final code = reference.codeUnitAt(index);
      if (code >= 0x41 && code <= 0x5A) {
        value = value * 26 + (code - 0x41 + 1);
      } else if (code >= 0x61 && code <= 0x7A) {
        value = value * 26 + (code - 0x61 + 1);
      } else {
        break;
      }
    }
    return value <= 0 ? 0 : value - 1;
  }

  /// 读字符串表。
  ///
  /// 一个 `<si>` 可能是富文本（多个 `<r><t>` 片段），要把它们接起来 ——
  /// 否则「砂糖橘寄养费」这种带强调的文字会只剩下第一段。
  static List<String> _readSharedStrings(String xml) {
    final sst = _elements(xml, 'sst');
    if (sst.isEmpty) return const <String>[];
    return <String>[
      for (final item in _elements(sst.first.inner, 'si')) _allText(item.inner),
    ];
  }

  /// 把一段内容里所有 `<t>` 的文本接起来。
  static String _allText(String xml) {
    final parts = <String>[];
    for (final text in _elements(xml, 't')) {
      parts.add(_decodeEntities(text.inner));
    }
    return parts.join();
  }

  /// 解开 XML 实体。
  ///
  /// 不处理的话，交易对方里一个 `&amp;` 会原样进到商户名里，
  /// 而这种错看起来又不像错。
  static String _decodeEntities(String text) {
    if (!text.contains('&')) return text;
    return text.replaceAllMapped(RegExp(r'&(#x?[0-9A-Fa-f]+|[A-Za-z]+);'), (
      match,
    ) {
      final body = match.group(1)!;
      if (body.startsWith('#x') || body.startsWith('#X')) {
        final code = int.tryParse(body.substring(2), radix: 16);
        return code == null ? match.group(0)! : String.fromCharCode(code);
      }
      if (body.startsWith('#')) {
        final code = int.tryParse(body.substring(1));
        return code == null ? match.group(0)! : String.fromCharCode(code);
      }
      return switch (body) {
        'amp' => '&',
        'lt' => '<',
        'gt' => '>',
        'quot' => '"',
        'apos' => "'",
        _ => match.group(0)!,
      };
    });
  }

  /// 取出一批同名标签。
  ///
  /// 字面扫描而不是上完整 XML 库：这里要认的标签就十来个，而且全是
  /// 机器生成的固定写法。代价是必须自己把两件事做对 ——
  /// **标签名要有边界**（`<numFmt>` 不能匹配到 `<numFmts>`），
  /// 以及**自闭合标签要单独认**（样式表里的 `<xf/>` 全是自闭合的，
  /// 把它们当成「有开始没结束」会一个都读不到）。
  static List<_XmlElement> _elements(String xml, String name) {
    final result = <_XmlElement>[];
    // 标签名后面必须跟空白、`/` 或 `>`，避免前缀误匹配。
    final open = RegExp('<$name(?:\\s|/|>)');
    var cursor = 0;
    while (cursor < xml.length) {
      final match = open.firstMatch(xml.substring(cursor));
      if (match == null) break;
      final start = cursor + match.start;
      final headerEnd = xml.indexOf('>', start);
      if (headerEnd < 0) break;

      final header = xml.substring(start + name.length + 1, headerEnd);
      if (header.endsWith('/')) {
        result.add(
          _XmlElement(attributes: _parseAttributes(header), inner: ''),
        );
        cursor = headerEnd + 1;
        continue;
      }

      final contentEnd = _findClosing(xml, name, headerEnd + 1);
      if (contentEnd < 0) break;
      final closeEnd = xml.indexOf('>', contentEnd);
      if (closeEnd < 0) break;
      result.add(
        _XmlElement(
          attributes: _parseAttributes(header),
          inner: xml.substring(headerEnd + 1, contentEnd),
        ),
      );
      cursor = closeEnd + 1;
    }
    return result;
  }

  /// 找与 `<name ...>` 配平的 `</name>` 的位置。
  static int _findClosing(String xml, String name, int from) {
    var index = from;
    var depth = 0;
    while (index < xml.length) {
      final next = xml.indexOf('<', index);
      if (next < 0) return -1;

      if (_startsTag(xml, next, name, closing: true)) {
        if (depth == 0) return next;
        depth--;
        final tagEnd = xml.indexOf('>', next);
        if (tagEnd < 0) return -1;
        index = tagEnd + 1;
        continue;
      }

      if (_startsTag(xml, next, name, closing: false)) {
        final tagEnd = xml.indexOf('>', next);
        if (tagEnd < 0) return -1;
        // 自闭合不增加深度。
        if (xml[tagEnd - 1] != '/') depth++;
        index = tagEnd + 1;
        continue;
      }

      final tagEnd = xml.indexOf('>', next);
      if (tagEnd < 0) return -1;
      index = tagEnd + 1;
    }
    return -1;
  }

  /// `xml[at]` 处是不是 `<name`（或 `</name`）且标签名后确实结束。
  static bool _startsTag(
    String xml,
    int at,
    String name, {
    required bool closing,
  }) {
    final prefix = closing ? '</$name' : '<$name';
    if (!xml.startsWith(prefix, at)) return false;
    final after = at + prefix.length;
    if (after >= xml.length) return false;
    final char = xml[after];
    return char == '>' || char == '/' || char == ' ' || char == '\t' || char == '\n' || char == '\r';
  }

  static Map<String, String> _parseAttributes(String header) {
    final attributes = <String, String>{};
    final pattern = RegExp('([\\w:.-]+)\\s*=\\s*"([^"]*)"');
    for (final match in pattern.allMatches(header)) {
      attributes[match.group(1)!] = _decodeEntities(match.group(2)!);
    }
    return attributes;
  }
}

/// 压缩方式不支持（用来从 [_readEntry] 里抛出，在外面转成明确的错误）。
class _UnsupportedCompression implements Exception {
  const _UnsupportedCompression(this.method);

  final int method;
}

final class _XmlElement {
  const _XmlElement({required this.attributes, required this.inner});

  final Map<String, String> attributes;
  final String inner;
}

/// 单元格引用到的格式。
final class _CellStyle {
  const _CellStyle({
    required this.numFmtId,
    required this.formatCode,
    required this.isDate,
  });

  final int numFmtId;
  final String? formatCode;

  /// 这一格是不是日期/时间。
  final bool isDate;
}
