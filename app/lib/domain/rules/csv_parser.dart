/// CSV 解析。
///
/// 指南 4.2.4 明确禁止简单 `split(',')` —— 真实账单里到处是
/// 「商户名带逗号」「备注里有换行」「金额带引号」。所以这里是一个
/// 逐字符的状态机，按 RFC 4180 处理：
///
/// * 双引号包裹的字段里可以出现分隔符与换行；
/// * 字段内的双引号用 `""` 转义；
/// * 换行支持 `\r\n`、`\n`、`\r` 三种（同一个文件里混用也能处理）。
///
/// 分隔符会自动探测（逗号 / 制表符 / 分号），因为「另存为 CSV」在不同
/// 区域设置下会给出不同的分隔符。
library;

/// 解析结果。
final class CsvTable {
  const CsvTable({
    required this.rows,
    required this.delimiter,
    required this.hasTrailingNewline,
  });

  /// 每一行的字段列表。行内字段数可能不一致 —— 这是真实文件的常态，
  /// 校验交给上层的字段映射，不在这里假装数据是规整的。
  final List<List<String>> rows;

  /// 探测或指定的分隔符。
  final String delimiter;

  final bool hasTrailingNewline;

  int get rowCount => rows.length;

  /// 某一行的字段数（越界返回 0）。
  int columnCountOf(int index) =>
      index >= 0 && index < rows.length ? rows[index].length : 0;

  /// 整个表里出现过的最大列数。
  int get maxColumns {
    var max = 0;
    for (final row in rows) {
      if (row.length > max) max = row.length;
    }
    return max;
  }

  /// 是否为「空表」（没有任何非空字段）。
  bool get isEmpty {
    for (final row in rows) {
      for (final field in row) {
        if (field.trim().isNotEmpty) return false;
      }
    }
    return true;
  }

  @override
  String toString() => 'CsvTable(${rows.length} 行, 分隔符 "$delimiter")';
}

/// 解析错误。
sealed class CsvError {
  const CsvError(this.message);

  final String message;
}

/// 引号没有闭合。
///
/// 这通常说明这个文件不是真正的 CSV（比如是 HTML 表格改了后缀），
/// 或者编码判断错了导致引号被当成了别的字符。
final class CsvUnterminatedQuote extends CsvError {
  const CsvUnterminatedQuote(this.line, this.column)
      : super('第 $line 行第 $column 个字段的引号没有闭合，'
            '这个文件可能不是标准 CSV，或者编码判断错了');

  final int line;
  final int column;
}

/// 空内容。
final class CsvEmpty extends CsvError {
  const CsvEmpty() : super('文件里没有可解析的内容');
}

/// CSV 解析器。
abstract final class CsvParser {
  /// 可能的分隔符，探测时按顺序试。
  static const List<String> candidateDelimiters = <String>[',', '\t', ';'];

  /// 解析 [text]。
  ///
  /// [delimiter] 为 null 时自动探测。
  static (CsvTable?, CsvError?) parse(String text, {String? delimiter}) {
    if (text.trim().isEmpty) return (null, const CsvEmpty());

    final separator = delimiter ?? detectDelimiter(text);
    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var quoted = false;
    var inQuotes = false;
    var line = 1;
    var fieldIndex = 1;
    var fieldStartLine = 1;
    var sawAnyChar = false;

    void endField() {
      row.add(field.toString());
      field.clear();
      fieldIndex++;
      quoted = false;
      fieldStartLine = line;
    }

    void endRow() {
      endField();
      rows.add(row);
      row = <String>[];
      fieldIndex = 1;
      fieldStartLine = line;
    }

    for (var index = 0; index < text.length; index++) {
      final char = text[index];
      sawAnyChar = true;

      if (inQuotes) {
        if (char == '"') {
          final next = index + 1 < text.length ? text[index + 1] : '';
          if (next == '"') {
            field.write('"');
            index++; // 跳过转义用的第二个引号
          } else {
            inQuotes = false;
          }
        } else {
          if (char == '\n') line++;
          field.write(char);
        }
        continue;
      }

      if (char == '"' && field.isEmpty && !quoted) {
        inQuotes = true;
        quoted = true;
        continue;
      }
      if (char == separator) {
        endField();
        continue;
      }
      if (char == '\r' || char == '\n') {
        if (char == '\r' && index + 1 < text.length && text[index + 1] == '\n') {
          index++; // CRLF 当成一个换行
        }
        // 先推进行号再收尾：下一行的第一个字段属于**新的一行**，
        // 这样引号未闭合时报出的行号才是用户能在文件里找到的那一行。
        line++;
        endRow();
        continue;
      }
      field.write(char);
    }

    if (inQuotes) {
      // 把行号与字段序号带出去，用户能直接去文件里找。
      return (null, CsvUnterminatedQuote(fieldStartLine, fieldIndex));
    }

    final hasTrailingNewline = text.endsWith('\n') || text.endsWith('\r');
    if (sawAnyChar && !(field.isEmpty && row.isEmpty)) endRow();

    // 去掉末尾的空行（文件结尾多一个换行是常态，不当成一行数据）。
    while (rows.isNotEmpty && rows.last.every((value) => value.trim().isEmpty)) {
      rows.removeLast();
    }

    if (rows.isEmpty) return (null, const CsvEmpty());

    return (
      CsvTable(
        rows: rows,
        delimiter: separator,
        hasTrailingNewline: hasTrailingNewline,
      ),
      null,
    );
  }

  /// 探测分隔符。
  ///
  /// 判据是「按这个分隔符切出来的列数在多数行里一致且大于 1」——
  /// 直接用「出现次数最多」会出错，因为备注里的逗号往往比制表符多。
  ///
  /// 只看前 [sampleRows] 行，避免被末尾的大段备注带偏。
  static String detectDelimiter(String text, {int sampleRows = 20}) {
    var best = candidateDelimiters.first;
    var bestScore = -1.0;

    for (final candidate in candidateDelimiters) {
      final (table, _) = parse(text, delimiter: candidate);
      if (table == null) continue;
      final rows = table.rows.take(sampleRows).toList();
      if (rows.isEmpty) continue;

      // 众数列数
      final counts = <int, int>{};
      for (final row in rows) {
        counts.update(row.length, (value) => value + 1, ifAbsent: () => 1);
      }
      var modeCount = 0;
      var modeRows = 0;
      counts.forEach((columnCount, occurrences) {
        if (occurrences > modeRows ||
            (occurrences == modeRows && columnCount > modeCount)) {
          modeRows = occurrences;
          modeCount = columnCount;
        }
      });

      if (modeCount < 2) continue; // 切不出列，不是它
      final consistency = modeRows / rows.length;
      final score = consistency * 100 + modeCount;
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    return best;
  }
}
