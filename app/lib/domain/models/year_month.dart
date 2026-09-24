/// 结构化的「年-月」。
///
/// 实现指南 3.1 要求月份由标准化交易时间计算，并使用 `YearMonth` 这类结构化类型，
/// 而不是到处传 `'2026-09'` 字符串：
///
/// * 字符串排序能得出正确月份顺序纯属巧合 —— `'2026-10' < '2026-9'` 是 `true`，
///   一旦按月排序就会错位；
/// * 环比、当月自然日数、跨年推进都需要真实日历，不是字符串运算。
///
/// 设备换时区**不会**改变已保存的月份：数据库里存的是
/// `occurred_at_ms` + `time_zone`，月份只在写入时算一次（指南 3.1 最后一条）。
library;

import '../../core/time/statistics_time.dart';

/// 一个自然月。不可变，可比较、可排序。
final class YearMonth implements Comparable<YearMonth> {
  /// 直接构造。月份必须是 1–12，否则立刻失败而不是产出「2026 年 13 月」。
  YearMonth(this.year, this.month)
      : assert(month >= 1 && month <= 12, '月份必须在 1–12 之间，收到 $month');

  /// 从标准化后的本地时间取年月。
  factory YearMonth.fromDateTime(DateTime time) =>
      YearMonth(time.year, time.month);

  /// 从毫秒时间戳与显式时区取年月。
  ///
  /// `timeZone` 只用于**记录来源选择**；首版统计时区固定 `Asia/Shanghai`，
  /// 所以这里按该偏移解释，不读设备当前时区。
  factory YearMonth.fromEpochMs(int epochMs, {String timeZone = 'Asia/Shanghai'}) {
    if (timeZone != StatisticsTime.timeZone) {
      throw ArgumentError.value(
        timeZone,
        'timeZone',
        '首版只支持 ${StatisticsTime.timeZone}；新增时区前请先补上夏令时规则',
      );
    }
    return YearMonth.fromDateTime(StatisticsTime.toLocal(epochMs));
  }

  /// 解析 `'2026-09'`。格式不符返回 null，由调用方决定如何报错。
  static YearMonth? tryParse(String? text) {
    if (text == null) return null;
    final match = RegExp(r'^(\d{4})-(\d{1,2})$').firstMatch(text.trim());
    if (match == null) return null;
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    if (month < 1 || month > 12) return null;
    return YearMonth(year, month);
  }

  final int year;
  final int month;

  /// `'2026-09'`。数据库与偏好里统一用这个形式。
  String toIso() => '$year-${month.toString().padLeft(2, '0')}';

  /// `'2026年9月'`。首页与月报的月份入口用。
  String get label => '$year年$month月';

  /// `'9月'`。空间紧张处使用。
  String get shortLabel => '$month月';

  /// `'SEPTEMBER, 2026'`。卡片页顶部的小标题沿用原型的英文全大写风格。
  String get englishLabel => '${_englishMonths[month - 1]}, $year';

  static const List<String> _englishMonths = <String>[
    'JANUARY',
    'FEBRUARY',
    'MARCH',
    'APRIL',
    'MAY',
    'JUNE',
    'JULY',
    'AUGUST',
    'SEPTEMBER',
    'OCTOBER',
    'NOVEMBER',
    'DECEMBER',
  ];

  /// 该月的自然日数。月日均必须用它当分母，不能固定除以 30（指南 3.4）。
  int get daysInMonth => DateTime(year, month + 1, 0).day;

  /// 下一个月，自动跨年。
  YearMonth get next =>
      month == 12 ? YearMonth(year + 1, 1) : YearMonth(year, month + 1);

  /// 上一个月，自动跨年。
  YearMonth get previous =>
      month == 1 ? YearMonth(year - 1, 12) : YearMonth(year, month - 1);

  /// 与另一个月份相差几个自然月（`this - other`），用于趋势图取窗口。
  int monthsSince(YearMonth other) =>
      (year - other.year) * 12 + (month - other.month);

  /// 该月第一天（本地午夜）。
  DateTime get firstDay => DateTime(year, month);

  /// 该月最后一刻的前一毫秒，便于构造 `[firstDay, lastMoment]` 查询区间。
  DateTime get lastMoment =>
      DateTime(year, month, daysInMonth, 23, 59, 59, 999);

  @override
  int compareTo(YearMonth other) =>
      year == other.year ? month.compareTo(other.month) : year.compareTo(other.year);

  bool operator <(YearMonth other) => compareTo(other) < 0;

  bool operator <=(YearMonth other) => compareTo(other) <= 0;

  bool operator >(YearMonth other) => compareTo(other) > 0;

  bool operator >=(YearMonth other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is YearMonth && other.year == year && other.month == month;

  @override
  int get hashCode => Object.hash(year, month);

  @override
  String toString() => toIso();
}
