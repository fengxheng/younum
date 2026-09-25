/// 导入规则：表头识别、字段映射、行标准化、去重判定。
///
/// 指南 4.2 里的几条硬要求落在本文件：
///
/// * 平台适配器要识别**标题、说明行、真正表头、末尾合计、收支方向、
///   交易状态**；非成功交易不得直接当已发生消费（[isSuccessfulStatus]）。
/// * **表头版本未知时进入字段匹配，不通过固定列下标猜测**（[detectHeader]）。
/// * 必填项缺失或重复映射时不能继续（[HeaderGuess.isUsable]）。
/// * 优先用「平台/账户命名空间 + 稳定源交易 ID」判定同源重复；
///   没有稳定 ID 时，商户、时间、金额相同**只能作为疑似重复**，
///   不能误删真实的重复消费（[classify]）。
///
/// 全部是纯函数，不碰数据库 —— 真机上也跑同一套判断。
library;

import '../../core/money/money.dart';
import '../../core/time/statistics_time.dart';
import '../models/import_records.dart';
import 'csv_parser.dart';

/// 标准化之后的字段。
enum ImportField {
  /// 交易时间（必填）。
  occurredAt,

  /// 金额（必填）。
  amount,

  /// 交易对方 / 商户（必填）。
  merchant,

  /// 收 / 支方向。
  direction,

  /// 交易状态。
  status,

  /// 稳定来源单号。有它才能做同源去重。
  orderId,

  /// 支付方式 / 来源地。
  paymentMethod,

  /// 备注。
  note;

  /// 用户必须映射的字段。
  static const Set<ImportField> required = <ImportField>{
    occurredAt,
    amount,
    merchant,
  };

  String get label => switch (this) {
    occurredAt => '交易时间',
    amount => '金额',
    merchant => '交易对方',
    direction => '收 / 支',
    status => '交易状态',
    orderId => '交易单号',
    paymentMethod => '支付方式',
    note => '备注',
  };
}

/// 列名别名。表头版本未知时靠它匹配，而不是靠列的下标。
///
/// 别名取的是微信与支付宝实际导出里的写法，以及「另存为 CSV」时常见的英文表头。
const Map<ImportField, List<String>> importFieldAliases =
    <ImportField, List<String>>{
      ImportField.occurredAt: <String>[
        '交易时间',
        '交易创建时间',
        '付款时间',
        '交易日期',
        '日期',
        '时间',
        '发生时间',
        'transaction time',
        'date',
        'datetime',
      ],
      ImportField.amount: <String>[
        '金额',
        '金额(元)',
        '金额（元）',
        '交易金额',
        '收支金额',
        '发生额',
        'amount',
      ],
      ImportField.merchant: <String>[
        '交易对方',
        '交易对方名称',
        '商户',
        '商户名称',
        '收款方',
        '商品',
        '商品名称',
        'merchant',
        'payee',
      ],
      ImportField.direction: <String>[
        '收/支',
        '收／支',
        '收支',
        '收/付',
        '资金流向',
        '借贷标志',
        'direction',
      ],
      ImportField.status: <String>['当前状态', '交易状态', '状态', '资金状态', 'status'],
      ImportField.orderId: <String>[
        '交易单号',
        '交易号',
        '商户单号',
        '商家订单号',
        '订单号',
        '流水号',
        'order id',
        'transaction id',
      ],
      ImportField.paymentMethod: <String>[
        '支付方式',
        '交易来源地',
        '付款方式',
        '支付渠道',
        'payment method',
      ],
      ImportField.note: <String>['备注', '商品说明', '说明', 'note', 'memo'],
    };

/// 表头识别结果。
final class HeaderGuess {
  const HeaderGuess({
    required this.headerRowIndex,
    required this.headers,
    required this.columns,
    required this.platformName,
  });

  /// 表头在文件里的行下标（0 起）。
  ///
  /// -1 表示**一行都没能匹配上任何列名**。注意这不等于「可以直接开始解析」：
  /// 匹配数不够时也会返回一个真实行号，好让映射界面有东西可以预填，
  /// 此时用 [isUsable] 判断能不能直接继续。
  final int headerRowIndex;

  /// 表头文本，按列顺序。
  final List<String> headers;

  /// 字段 → 列下标。
  ///
  /// 可能只是**部分**识别结果（配合 [isUsable] == false 使用）。
  final Map<ImportField, int> columns;

  /// 识别出的平台名，例如「微信支付」。null 表示通用 CSV。
  final String? platformName;

  Set<ImportField> get missingRequired => <ImportField>{
    for (final field in ImportField.required)
      if (!columns.containsKey(field)) field,
  };

  /// 必填项齐全才能继续（指南 4.2.7）。
  bool get isUsable => headerRowIndex >= 0 && missingRequired.isEmpty;

  /// 需要用户手工做字段匹配。
  ///
  /// 表头没找到、或必填项有缺失时都要进映射页，**不能**按固定列下标猜。
  bool get needsManualMapping => !isUsable;

  @override
  String toString() =>
      'HeaderGuess(row=$headerRowIndex, 平台=$platformName, '
      '列数=${headers.length}, 缺失=$missingRequired)';
}

/// 一行的标准化结果。
sealed class RowParse {
  const RowParse();
}

/// 解析成功。
final class RowParsed extends RowParse {
  const RowParsed({
    required this.rowNumber,
    required this.occurredAtMs,
    required this.amountCents,
    required this.direction,
    required this.merchant,
    required this.rawText,
    required this.orderId,
    required this.statusText,
    required this.note,
  });

  final int rowNumber;
  final int occurredAtMs;

  /// 非负绝对值。方向由 [direction] 表达。
  final int amountCents;

  final ImportDirection direction;
  final String merchant;
  final String rawText;
  final String? orderId;
  final String? statusText;
  final String? note;

  /// 来源里的稳定单号存在时才有同源去重能力。
  bool get hasStableId => orderId != null && orderId!.trim().isNotEmpty;
}

/// 解析失败。
final class RowInvalid extends RowParse {
  const RowInvalid({
    required this.rowNumber,
    required this.issue,
    required this.rawText,
  });

  final int rowNumber;
  final String issue;
  final String rawText;
}

/// 整行跳过（说明行、空行、合计行）。
final class RowSkipped extends RowParse {
  const RowSkipped({
    required this.rowNumber,
    required this.reason,
    required this.rawText,
  });

  final int rowNumber;
  final String reason;
  final String rawText;
}

/// 重复判定结果。
enum DuplicateVerdict {
  /// 新记录。
  fresh,

  /// 同源重复：稳定单号一致，可以确定是同一笔。
  sameOrigin,

  /// 疑似重复：商户、时间、金额相同，但没有稳定单号。
  ///
  /// **不能自动排除** —— 同一家店同一分钟刷两笔是真实存在的。
  suspected,
}

/// 导入规则。
/// 跨来源比对用的一笔记录：发生在什么时候、来自哪份账单。
typedef ImportSourceStamp = ({int occurredAtMs, String sourceNamespace});

abstract final class ImportRules {
  /// 扫描表头时最多往下看多少行。
  ///
  /// 微信的导出前面有 10 行左右的说明，支付宝更多，所以给得宽松一些。
  static const int headerScanRows = 60;

  /// 一行里至少要匹配上几个已知列名才算表头。
  ///
  /// 太低会把说明行误判成表头，太高则表头稍有改动就认不出来。
  static const int minHeaderHits = 3;

  // ---------------------------------------------------------------------------
  // 表头识别
  // ---------------------------------------------------------------------------

  /// 在文件里找真正的表头。
  ///
  /// 判据是「这一行里有多少个单元格能匹配已知列名」，而不是「第几行是表头」。
  static HeaderGuess detectHeader(CsvTable table) {
    var bestIndex = -1;
    var bestHits = 0;
    var bestColumns = <ImportField, int>{};

    final limit = table.rows.length < headerScanRows
        ? table.rows.length
        : headerScanRows;

    for (var index = 0; index < limit; index++) {
      final row = table.rows[index];
      final columns = _matchColumns(row);
      if (columns.length > bestHits) {
        bestHits = columns.length;
        bestIndex = index;
        bestColumns = columns;
      }
    }

    if (bestHits == 0) {
      // 一行都没匹配上任何列名：文件里没有任何可用线索，
      // 返回 -1 而不是随便挑一行当表头。
      return const HeaderGuess(
        headerRowIndex: -1,
        headers: <String>[],
        columns: <ImportField, int>{},
        platformName: null,
      );
    }

    // 即使没达到「算作找到了表头」的门槛，也把**部分认出**的那一行带回去。
    //
    // 为什么要这样：门槛（[minHeaderHits]）是用来判断「能不能直接开始解析」
    // 的，而映射界面还需要「表头大概在第几行、哪一列是什么」来预填。
    // 把这两件事合成一个返回值，用户就得从零开始手工指一遍所有列。
    final headers = table.rows[bestIndex];
    return HeaderGuess(
      headerRowIndex: bestIndex,
      headers: headers,
      columns: bestColumns,
      platformName: _platformOf(headers, table),
    );
  }

  static Map<ImportField, int> _matchColumns(List<String> row) {
    final columns = <ImportField, int>{};
    for (var index = 0; index < row.length; index++) {
      final cell = _normalizeHeader(row[index]);
      if (cell.isEmpty) continue;
      for (final entry in importFieldAliases.entries) {
        if (columns.containsKey(entry.key)) continue;
        if (entry.value.any((alias) => _normalizeHeader(alias) == cell)) {
          columns[entry.key] = index;
          break;
        }
      }
    }
    return columns;
  }

  /// 去掉空白、全角括号等差异后再比较，避免因为一个空格就认不出表头。
  static String _normalizeHeader(String raw) => raw
      .replaceAll('\uFEFF', '')
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll('（', '(')
      .replaceAll('）', ')')
      .replaceAll('／', '/')
      .toLowerCase();

  /// 猜平台名。只用于展示，不影响解析。
  static String? _platformOf(List<String> headers, CsvTable table) {
    final joined = headers.join('|');
    if (joined.contains('微信')) return '微信支付';
    if (joined.contains('支付宝')) return '支付宝';

    // 表头本身看不出平台时，看看表头之前那些说明行。
    final before = table.rows.take(6).expand((row) => row).join('|');
    if (before.contains('微信')) return '微信支付';
    if (before.contains('支付宝')) return '支付宝';
    return null;
  }

  // ---------------------------------------------------------------------------
  // 行解析
  // ---------------------------------------------------------------------------

  /// 把一行标准化。
  ///
  /// [headerRowIndex] 之前的行都是说明行，直接跳过。
  static RowParse parseRow({
    required List<String> row,
    required int rowNumber,
    required HeaderGuess header,
  }) {
    final rawText = row.join(',');

    if (rowNumber <= header.headerRowIndex + 1) {
      return RowSkipped(
        rowNumber: rowNumber,
        reason: '表头或说明行',
        rawText: rawText,
      );
    }
    if (row.every((cell) => cell.trim().isEmpty)) {
      return RowSkipped(rowNumber: rowNumber, reason: '空行', rawText: rawText);
    }
    // 末尾的合计行：微信是「共 N 笔,合计,金额」，支付宝是一整行说明。
    if (_looksLikeSummary(row)) {
      return RowSkipped(
        rowNumber: rowNumber,
        reason: '合计或统计行',
        rawText: rawText,
      );
    }

    final amountText = _cell(row, header.columns[ImportField.amount]);
    final timeText = _cell(row, header.columns[ImportField.occurredAt]);
    final merchantText = _cell(row, header.columns[ImportField.merchant]);

    if (amountText.isEmpty) {
      return RowInvalid(rowNumber: rowNumber, issue: '缺少金额', rawText: rawText);
    }
    if (timeText.isEmpty) {
      return RowInvalid(
        rowNumber: rowNumber,
        issue: '缺少交易时间',
        rawText: rawText,
      );
    }
    if (merchantText.isEmpty) {
      return RowInvalid(
        rowNumber: rowNumber,
        issue: '缺少交易对方',
        rawText: rawText,
      );
    }

    final statusText = _cell(row, header.columns[ImportField.status]);
    if (statusText.isNotEmpty && !isSuccessfulStatus(statusText)) {
      // 指南 4.2.6：非成功交易不得直接当已发生消费。
      return RowInvalid(
        rowNumber: rowNumber,
        issue: '交易状态是「$statusText」，不是已完成的消费',
        rawText: rawText,
      );
    }

    final occurredAt = parseOccurredAt(timeText);
    if (occurredAt == null) {
      return RowInvalid(
        rowNumber: rowNumber,
        issue: '看不懂的时间格式：$timeText',
        rawText: rawText,
      );
    }

    final directionText = _cell(row, header.columns[ImportField.direction]);
    final (amount, amountError) = parseAmount(amountText);
    if (amount == null) {
      return RowInvalid(
        rowNumber: rowNumber,
        issue: amountError ?? '金额无法解析：$amountText',
        rawText: rawText,
      );
    }

    final direction = directionOf(directionText, amount.rawSign);
    if (direction == null) {
      // 指南 3.1：负号冲突必须核对，不能猜。
      return RowInvalid(
        rowNumber: rowNumber,
        issue: '金额符号与「$directionText」矛盾，请核对',
        rawText: rawText,
      );
    }

    return RowParsed(
      rowNumber: rowNumber,
      occurredAtMs: occurredAt,
      amountCents: amount.cents,
      direction: direction,
      merchant: merchantText.trim(),
      rawText: rawText,
      orderId: _cell(row, header.columns[ImportField.orderId]),
      statusText: statusText.isEmpty ? null : statusText,
      note: _cell(row, header.columns[ImportField.note]),
    );
  }

  static String _cell(List<String> row, int? index) {
    if (index == null || index < 0 || index >= row.length) return '';
    return row[index].trim();
  }

  /// 是否是合计行 / 统计行。
  static bool _looksLikeSummary(List<String> row) {
    final first = row.isEmpty ? '' : row.first.trim();
    return first.startsWith('共') ||
        first.startsWith('合计') ||
        first.startsWith('总计') ||
        first.contains('账单明细列表') ||
        first.startsWith('---');
  }

  /// 交易状态是否表示「钱真的花出去了」。
  ///
  /// 已退款、交易关闭、已撤销这些都不能算作已发生消费。
  static bool isSuccessfulStatus(String status) {
    final text = status.trim();
    if (text.isEmpty) return true;
    const rejected = <String>[
      '退款',
      '关闭',
      '撤销',
      '失败',
      '未支付',
      '已取消',
      '取消',
      '等待',
      '处理中',
      '退票',
    ];
    for (final word in rejected) {
      if (text.contains(word)) return false;
    }
    return true;
  }

  /// 解析金额文本。
  ///
  /// 返回（金额与符号，错误说明）。金额是**非负绝对值**，符号通过
  /// [ParsedAmount.rawSign] 单独带出来，供方向校验使用。
  static (ParsedAmount?, String?) parseAmount(String raw) {
    var text = raw
        .replaceAll('\u00A5', '') // ¥
        .replaceAll('\uFFE5', '') // ￥
        .replaceAll('元', '')
        .replaceAll(',', '')
        .replaceAll(' ', '')
        .replaceAll('\u3000', '');
    if (text.isEmpty) return (null, '金额是空的');

    var negative = false;
    if (text.startsWith('-') || text.startsWith('\u2212')) {
      negative = true;
      text = text.substring(1);
    } else if (text.startsWith('+')) {
      text = text.substring(1);
    }

    final (cents, error) = Money.parseYuan(text);
    if (cents == null || error != null) {
      return (null, error?.message ?? '金额无法解析：$raw');
    }
    if (cents == 0) return (null, '金额为 0，无法判断是不是有效消费');

    return (ParsedAmount(cents: cents.abs(), rawSign: negative ? -1 : 1), null);
  }

  /// 由「收 / 支」文本与金额符号推方向。
  ///
  /// 两者矛盾时返回 null —— 交给用户核对，不替用户决定
  /// （指南 3.1：负号冲突必须核对）。
  ///
  /// ⚠️ 什么才算「矛盾」：微信与支付宝导出的「支出」行，金额都是**正数**，
  /// 方向完全由「收/支」列表达。所以「支出 + 正数」是最常见的情形，
  /// 不是冲突。真正矛盾的是「收入却是负数」——收入不可能写成负号。
  /// 把「支出 + 正数」当冲突，会让整份账单全部判为无效。
  ///
  /// 符号只在两种时候起作用：一是方向列缺位（[directionText] 为空或只是
  /// 表头文字），二是用来识别上面那种矛盾。
  static ImportDirection? directionOf(String directionText, int rawSign) {
    final text = directionText.trim();
    if (text.isEmpty || _isHeaderLikeDirection(text)) {
      // 没有可用的方向信息，只能靠符号；符号也没有就等用户判断。
      return rawSign < 0 ? ImportDirection.expense : ImportDirection.unknown;
    }

    // 「不计收支」里同时含「收」与「支」两个字，必须先判掉。
    if (text.contains('不计') || text.contains('转账')) {
      return ImportDirection.transfer;
    }

    // 银行账单写的是「转出 / 转入」。⚠️ 必须放在下面的「收 / 支」单字判断之前：
    // 「转出」里既没有「收」也没有「支」，只有这两个词能表达方向。
    // 注意「转出」不含「转账」，所以不会和上面那一支冲突。
    if (text.contains('转出')) return ImportDirection.expense;
    if (text.contains('转入')) return ImportDirection.income;

    final mentionsIncome = text.contains('收入');
    final mentionsExpense = text.contains('支出');
    if (mentionsIncome && !mentionsExpense) {
      // 收入写成负数 —— 这是真的矛盾。
      return rawSign < 0 ? null : ImportDirection.income;
    }
    if (mentionsExpense && !mentionsIncome) {
      return ImportDirection.expense;
    }

    final hasShou = text.contains('收');
    final hasZhi = text.contains('支');
    if (hasShou && !hasZhi) {
      return rawSign < 0 ? null : ImportDirection.income;
    }
    if (hasZhi && !hasShou) return ImportDirection.expense;

    // 同时含「收」与「支」，这一格没给出方向。
    return rawSign < 0 ? ImportDirection.expense : ImportDirection.unknown;
  }

  /// 这一格填的是表头文字本身（比如文件里重复了一次表头），不是方向。
  static bool _isHeaderLikeDirection(String text) {
    final normalized = text.replaceAll('/', '').replaceAll('／', '').trim();
    return normalized == '收支' || normalized == '收付';
  }

  /// 解析交易时间。
  ///
  /// 支持账单里常见的几种写法；一律按统计时区解释，不读设备当前时区。
  static int? parseOccurredAt(String raw) {
    final text = raw.trim().replaceAll('\uFEFF', '');
    if (text.isEmpty) return null;

    // 2026-09-23 14:26:00 / 2026/9/23 14:26 / 2026.09.23 14:26
    final separated = RegExp(
      r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})'
      r'(?:[ T](\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?$',
    ).firstMatch(text);
    if (separated != null) {
      return _epoch(
        year: int.parse(separated.group(1)!),
        month: int.parse(separated.group(2)!),
        day: int.parse(separated.group(3)!),
        hour: separated.group(4) == null ? 0 : int.parse(separated.group(4)!),
        minute: separated.group(5) == null ? 0 : int.parse(separated.group(5)!),
        second: separated.group(6) == null ? 0 : int.parse(separated.group(6)!),
      );
    }

    // 2026年9月23日 14:26
    final chinese = RegExp(
      r'^(\d{4})年(\d{1,2})月(\d{1,2})日'
      r'(?:\s*(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?$',
    ).firstMatch(text);
    if (chinese != null) {
      return _epoch(
        year: int.parse(chinese.group(1)!),
        month: int.parse(chinese.group(2)!),
        day: int.parse(chinese.group(3)!),
        hour: chinese.group(4) == null ? 0 : int.parse(chinese.group(4)!),
        minute: chinese.group(5) == null ? 0 : int.parse(chinese.group(5)!),
        second: chinese.group(6) == null ? 0 : int.parse(chinese.group(6)!),
      );
    }

    return null;
  }

  static int? _epoch({
    required int year,
    required int month,
    required int day,
    required int hour,
    required int minute,
    required int second,
  }) {
    // 先做范围检查，避免 DateTime 把 2 月 30 日悄悄顺延成 3 月 2 日。
    if (month < 1 || month > 12) return null;
    if (day < 1 || day > 31) return null;
    if (hour > 23 || minute > 59 || second > 59) return null;
    final candidate = DateTime.utc(year, month, day);
    if (candidate.year != year ||
        candidate.month != month ||
        candidate.day != day) {
      return null;
    }
    return StatisticsTime.epochMsFor(year, month, day, hour, minute, second);
  }

  // ---------------------------------------------------------------------------
  // 去重
  // ---------------------------------------------------------------------------

  /// 同源去重键：命名空间 + 账户 + 稳定单号。
  ///
  /// 没有稳定单号时返回 null —— 这种情况只能算疑似重复。
  static String? stableKeyOf({
    required String sourceNamespace,
    required String? sourceAccount,
    required String? orderId,
  }) {
    if (orderId == null || orderId.trim().isEmpty) return null;
    return '$sourceNamespace\u0000${sourceAccount ?? ''}\u0000${orderId.trim()}';
  }

  /// 弱去重键：商户 + 时间 + 金额。
  ///
  /// ⚠️ 它**只能**用来提示疑似重复，绝不能用来自动删除：
  /// 同一家店同一分钟买两次是很正常的事（指南 4.3）。
  static String weakKeyOf({
    required String merchant,
    required int occurredAtMs,
    required int amountCents,
  }) => '${merchant.trim().toLowerCase()}\u0000$occurredAtMs\u0000$amountCents';

  /// 判定一行是不是重复。
  ///
  /// [knownStableKeys] 与 [knownWeakKeys] 是「库里已有的」加上
  /// 「本文件里前面出现过的」两个集合的并集。
  static DuplicateVerdict classify({
    required String? stableKey,
    required String weakKey,
    required Set<String> knownStableKeys,
    required Set<String> knownWeakKeys,
  }) {
    if (stableKey != null && knownStableKeys.contains(stableKey)) {
      return DuplicateVerdict.sameOrigin;
    }
    if (knownWeakKeys.contains(weakKey)) {
      return DuplicateVerdict.suspected;
    }
    return DuplicateVerdict.fresh;
  }

  // ---------------------------------------------------------------------------
  // 跨来源疑似重复
  // ---------------------------------------------------------------------------

  /// 跨来源比对的时间窗口：24 小时。
  ///
  /// 取这么宽是因为两份账单记的**不是同一个时刻**：银行卡账单记的是扣款时间，
  /// 支付宝记的是下单时间，两者可能差几秒，也可能因为结算差上几小时。
  /// 窗口放宽的代价只是「多问一句」，而漏掉的代价是同一笔被算两次 ——
  /// 所以宁可宽一点，反正最后一定是用户自己决定（指南 4.3）。
  static const int crossSourceWindowMs = 24 * 60 * 60 * 1000;

  /// 一笔已知记录在「金额相同」候选表里的样子。
  static ImportSourceStamp stampOf({
    required int occurredAtMs,
    required String sourceNamespace,
  }) => (occurredAtMs: occurredAtMs, sourceNamespace: sourceNamespace);

  /// 跨来源疑似重复：**金额相同 + 时间接近 + 来源不同**。
  ///
  /// 为什么单靠 [weakKeyOf] 不够：微信、支付宝的扣款大多走银行卡，同一笔消费会
  /// 同时出现在两份账单里，可是两边记的**商户名完全不同** —— 银行那份写的是
  /// 「支付宝（中国）网络技术有限公司」，时间也不是毫秒级一致。用「商户 + 时间 +
  /// 金额完全相同」那条弱键永远发现不了，结果就是同一笔被算两次。
  ///
  /// ⚠️ 这里**只**产出「疑似」：指南 4.3 明确说跨平台金额相同不等于同一笔，
  /// 必须逐组让用户确认，并且允许「保留两笔」。所以调用方绝不能拿它自动丢弃行。
  ///
  /// 返回与哪一份来源撞上、差了多久；没有撞上时返回 null。
  static ({int gapMs, String otherNamespace})? crossSourceDuplicate({
    required int occurredAtMs,
    required String sourceNamespace,
    required Iterable<ImportSourceStamp> sameAmount,
  }) {
    ({int gapMs, String otherNamespace})? hit;
    for (final candidate in sameAmount) {
      // 同一份来源的重复交给同源键和弱键，不在这里判。
      if (candidate.sourceNamespace == sourceNamespace) continue;
      final gap = (candidate.occurredAtMs - occurredAtMs).abs();
      if (gap > crossSourceWindowMs) continue;
      if (hit == null || gap < hit.gapMs) {
        hit = (gapMs: gap, otherNamespace: candidate.sourceNamespace);
      }
    }
    return hit;
  }

  /// 跨来源疑似重复的提示文案。
  ///
  /// 必须以 [suspectedDuplicateIssuePrefix] 开头：核对页是按这个前缀把行归到
  /// 「疑似重复」那一组里的。
  static String crossSourceIssue({
    required int gapMs,
    required String otherNamespace,
  }) =>
      '$suspectedDuplicateIssuePrefix：金额与「$otherNamespace」账单里的一笔相同，'
      '时间相差${sourceGapText(gapMs)}，很可能是同一笔消费在两份账单里各记了一次'
      '（比如银行卡账单上的「支付宝」扣款），请确认是不是同一笔';

  /// 把时间差说成人话。用于提示文案，不参与任何判断。
  static String sourceGapText(int gapMs) {
    if (gapMs < 60 * 1000) return '不到 1 分钟';
    if (gapMs < 60 * 60 * 1000) return '${gapMs ~/ (60 * 1000)} 分钟';
    if (gapMs < 48 * 60 * 60 * 1000) {
      final hours = gapMs / (60 * 60 * 1000);
      return '${hours.toStringAsFixed(hours < 10 ? 1 : 0)} 小时';
    }
    return '${gapMs ~/ (24 * 60 * 60 * 1000)} 天';
  }

  // ---------------------------------------------------------------------------
  // 人工字段映射
  // ---------------------------------------------------------------------------

  /// 校验用户手工建立的映射。
  static MappingCheck checkMapping(
    ImportFieldMapping mapping, {
    required int columnCount,
  }) {
    final duplicated = <int>{};
    final seen = <int>{};
    for (final index in mapping.columns.values) {
      if (!seen.add(index)) duplicated.add(index);
    }
    final outOfRange = <int>{
      for (final index in mapping.columns.values)
        if (index < 0 || index >= columnCount) index,
    };
    return MappingCheck(
      missingRequired: <ImportField>{
        for (final field in ImportField.required)
          if (!mapping.columns.containsKey(field)) field,
      },
      duplicatedColumns: duplicated,
      outOfRangeColumns: outOfRange,
    );
  }

  /// 从用户映射拼出一个可用的表头，好让 [parseRow] 原样复用。
  ///
  /// 这样「自动识别」与「手工指定」走的是**同一段解析代码**，
  /// 不会出现「自动识别能处理引号、手工映射不能」这种分叉。
  static HeaderGuess headerFromMapping({
    required ImportFieldMapping mapping,
    required List<String> headers,
  }) => HeaderGuess(
    headerRowIndex: mapping.headerRowIndex,
    headers: headers,
    columns: mapping.columns,
    platformName: null,
  );
}

/// 用户手工建立的字段映射。
///
/// 表头版本未知时（或者文件干脆没有表头）走这条路：由用户指出「哪个字段在
/// 哪一列」，而不是程序按固定列下标猜（指南 4.2.7）。
final class ImportFieldMapping {
  const ImportFieldMapping({
    required this.headerRowIndex,
    required this.columns,
  });

  /// 表头所在行（0 起）。用户选「这个文件没有表头」时为 -1，
  /// 表示从第 0 行就是数据。
  final int headerRowIndex;

  /// 字段 → 列下标。
  final Map<ImportField, int> columns;

  ImportFieldMapping withColumn(ImportField field, int? column) {
    final next = Map<ImportField, int>.of(columns);
    if (column == null) {
      next.remove(field);
    } else {
      next[field] = column;
    }
    return ImportFieldMapping(headerRowIndex: headerRowIndex, columns: next);
  }

  /// 用户勾掉「这份文件有表头」时的映射。
  ImportFieldMapping get withoutHeaderRow =>
      ImportFieldMapping(headerRowIndex: -1, columns: columns);
}

/// 映射校验结果。
final class MappingCheck {
  const MappingCheck({
    required this.missingRequired,
    required this.duplicatedColumns,
    required this.outOfRangeColumns,
  });

  final Set<ImportField> missingRequired;

  /// 同一列被指给了多个字段。
  final Set<int> duplicatedColumns;

  /// 指向了文件里不存在的列。
  final Set<int> outOfRangeColumns;

  /// 能不能继续。
  bool get canContinue =>
      missingRequired.isEmpty &&
      duplicatedColumns.isEmpty &&
      outOfRangeColumns.isEmpty;

  /// 不能继续的原因，可直接展示给用户。
  ///
  /// 必须逐条说清，不能只说「映射有误」—— 用户要能照着提示改对。
  List<String> get messages => <String>[
    if (missingRequired.isNotEmpty)
      '还没有指定：${missingRequired.map((field) => field.label).join('、')}',
    if (duplicatedColumns.isNotEmpty)
      '同一列被指定给了多个字段（第 '
          '${duplicatedColumns.map((index) => index + 1).join('、')} 列）',
    if (outOfRangeColumns.isNotEmpty)
      '指向了文件里不存在的列（第 '
          '${outOfRangeColumns.map((index) => index + 1).join('、')} 列）',
  ];
}

/// 解析出来的金额与其原始符号。
final class ParsedAmount {
  const ParsedAmount({required this.cents, required this.rawSign});

  /// 非负绝对值（分）。
  final int cents;

  /// 原文里的符号：-1 表示带负号，1 表示不带。
  final int rawSign;

  @override
  String toString() => 'ParsedAmount($cents, sign=$rawSign)';
}
