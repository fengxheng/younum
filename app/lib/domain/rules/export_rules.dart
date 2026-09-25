/// 导出规则：明细 CSV 与分享隐私开关。
///
/// 指南 8.1 的硬要求落在这里：
///
/// * CSV 要从**真实查询结果**生成（不是界面上那张表的截图），正确处理逗号、
///   引号、换行和 UTF-8 BOM；
/// * 商户、备注这类**文本**列要防电子表格公式注入（`= + - @` 开头会被 Excel
///   当公式执行），**但数值列必须保留数字语义** —— 不能为了防注入给金额也加引号；
/// * 「隐藏金额」必须作用于**最终文件**，不是屏幕上的遮罩：所以开关在读进
///   [ExportPrivacy] 的那一刻就决定了内容，而不是等画完再盖一层；
/// * CSV 只是数据导出，**不等于完整备份**（首版没有可恢复的备份格式），
///   所以界面文案不能说成「备份」。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../core/money/money.dart';
import '../../core/time/statistics_time.dart';
import '../models/ledger_dataset.dart';
import '../models/year_month.dart';

/// 导出与分享的隐私开关。
final class ExportPrivacy {
  const ExportPrivacy({this.showAmount = false});

  /// 分享图里是否展示具体金额。
  ///
  /// 默认 **false**，而且**每次进入分享都回到默认值**，不沿用上一次公开出去的
  /// 设置（指南 8.1）—— 上次是私密发给自己，这次可能是发到群里。
  final bool showAmount;

  /// 默认开关。
  static const ExportPrivacy defaults = ExportPrivacy();

  ExportPrivacy copyWith({bool? showAmount}) =>
      ExportPrivacy(showAmount: showAmount ?? this.showAmount);

  @override
  bool operator ==(Object other) =>
      other is ExportPrivacy && other.showAmount == showAmount;

  @override
  int get hashCode => showAmount.hashCode;

  @override
  String toString() => 'ExportPrivacy(showAmount: $showAmount)';
}

/// 明细 CSV 的一行。
final class ExportRow {
  const ExportRow({
    required this.occurredAtMs,
    required this.merchant,
    required this.amountCents,
    required this.amountSign,
    required this.natureLabel,
    required this.categoryNames,
    required this.note,
  });

  final int occurredAtMs;

  /// 交易对方。可能为空。
  final String merchant;

  /// 金额（分，**绝对值**）。
  final int amountCents;

  /// 方向：`-1` 支出，`1` 收入或退款，**null 表示没有方向**（转账、排除统计、
  /// 待判断）。null 时导出按绝对值写。
  final int? amountSign;

  /// 收支文案。
  final String natureLabel;

  /// 用途。拆分过的消费会有多个。
  final List<String> categoryNames;

  final String note;

  @override
  String toString() => 'ExportRow($occurredAtMs, $merchant, $amountCents)';
}

abstract final class ExportRules {
  /// UTF-8 BOM。没有它 Excel 打开中文 CSV 就是乱码。
  static const String bom = '\uFEFF';

  /// 换行一律 CRLF（RFC 4180）。
  static const String lineEnding = '\r\n';

  /// 明细 CSV 的列。顺序固定，方便用户按同样的列名再导入回来。
  static const List<String> detailHeader = <String>[
    '时间',
    '商户',
    '金额',
    '收支',
    '用途',
    '备注',
  ];

  /// 会被电子表格当成公式起始的字符。
  ///
  /// 制表符和回车也在里面：`\t=1+1` 这类同样会被执行。
  static const List<String> formulaLeaders = <String>[
    '=',
    '+',
    '-',
    '@',
    '\t',
    '\r',
  ];

  /// 给**文本**列防公式注入。
  ///
  /// ⚠️ 只能用在文本列（商户、备注、用途）。金额列绝不能走这里 ——
  /// 负金额天然以 `-` 开头，加个前缀它就不是数字了，
  /// 而指南 8.1 明确要求数值列保持数字语义。
  ///
  /// 前导空格后面跟着公式起始符也一并挡掉：`\t=` 与 ` =` 在部分表格里同样危险。
  static String guardFormula(String raw) {
    if (raw.isEmpty) return raw;
    var index = 0;
    while (index < raw.length && raw[index] == ' ') {
      index++;
    }
    if (index >= raw.length) return raw;
    if (!formulaLeaders.contains(raw[index])) return raw;
    // 单引号是 Excel / LibreOffice 都认的「这一格是文本」写法，
    // 而且不破坏 CSV 结构，重新导入仍然可解析。
    return "'$raw";
  }

  /// 编码一个 CSV 单元格：该加引号的加引号，文本列先防注入。
  static String csvCell(String raw) {
    final guarded = guardFormula(raw);
    final needsQuotes =
        guarded.contains(',') ||
        guarded.contains('"') ||
        guarded.contains('\n') ||
        guarded.contains('\r');
    if (!needsQuotes) return guarded;
    return '"${guarded.replaceAll('"', '""')}"';
  }

  /// 金额列：纯数字，不带货币符号，**不做**公式防护。
  static String amountCell(int amountCents, {int? sign}) {
    final signed = sign == null ? amountCents : sign * amountCents;
    final text = Money.format(signed.abs());
    return signed < 0 ? '-$text' : text;
  }

  /// 从**真实数据集**里取出某个月的明细。
  ///
  /// 只保留目标月份的交易：导出内容必须和所选月份一致（阶段 5 验收）。
  /// 排序按时间升序 —— 用户拿它和账单对账，顺序一致最省事。
  static List<ExportRow> detailRows({
    required LedgerDataset dataset,
    required YearMonth month,
  }) {
    final rows = <ExportRow>[];
    for (final transaction in dataset.transactions) {
      final local = StatisticsTime.toLocal(transaction.occurredAtMs);
      if (local.year != month.year || local.month != month.month) continue;
      rows.add(
        ExportRow(
          occurredAtMs: transaction.occurredAtMs,
          merchant: transaction.merchant,
          amountCents: transaction.amountCents,
          amountSign: transaction.nature.amountSign,
          natureLabel: transaction.nature.label,
          categoryNames: <String>[
            for (final allocation in dataset.allocationsOf(transaction.id))
              dataset.categoryName(allocation.categoryId),
          ],
          note: transaction.note ?? '',
        ),
      );
    }
    rows.sort((a, b) => a.occurredAtMs.compareTo(b.occurredAtMs));
    return rows;
  }

  /// 明细 CSV 文本：BOM + 表头 + 每行 CRLF。
  static String detailCsv(List<ExportRow> rows) {
    final buffer = StringBuffer()
      ..write(bom)
      ..write(detailHeader.map(csvCell).join(','))
      ..write(lineEnding);
    for (final row in rows) {
      buffer
        ..write(csvCell(StatisticsTime.formatFull(row.occurredAtMs)))
        ..write(',')
        ..write(csvCell(row.merchant))
        ..write(',')
        ..write(amountCell(row.amountCents, sign: row.amountSign))
        ..write(',')
        ..write(csvCell(row.natureLabel))
        ..write(',')
        ..write(csvCell(row.categoryNames.join(' / ')))
        ..write(',')
        ..write(csvCell(row.note))
        ..write(lineEnding);
    }
    return buffer.toString();
  }

  /// 写文件用的字节：UTF-8。BOM 已经在文本里，编码后就是 `EF BB BF`。
  static Uint8List detailCsvBytes(List<ExportRow> rows) =>
      Uint8List.fromList(utf8.encode(detailCsv(rows)));
}
