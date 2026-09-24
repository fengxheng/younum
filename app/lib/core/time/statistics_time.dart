/// 统计时区。
///
/// 实现指南 3.1：**无时区账单默认按 `Asia/Shanghai` 解释并记录该选择**；
/// 设备旅行后切换时区不应该悄悄移动历史账单所属月份。
///
/// 做法是把「本地时间」和「实例」分开：
/// * 数据库里存的是 UTC 基准的 `occurred_at_ms` **加上** 当时采用的时区名；
/// * 月份只在写入时算一次，之后读出来不再依赖设备当前时区。
///
/// 首版只支持 UTC+8（无夏令时）。遇到别的时区**不猜**，直接抛错 ——
/// 按错误偏移算出来的月份会静默错位，比崩溃更难查。
library;

/// 统计时区相关的换算与展示。
abstract final class StatisticsTime {
  /// 首版固定统计时区。
  static const String timeZone = 'Asia/Shanghai';

  /// 该时区的固定偏移。`Asia/Shanghai` 自 1991 年起不再使用夏令时。
  static const Duration offset = Duration(hours: 8);

  /// 把「当地墙上时间」换成 UTC 基准的毫秒时间戳。
  ///
  /// `epochMsFor(2026, 9, 23, 14, 26)` 得到的是「北京时间 2026-09-23 14:26」
  /// 这个瞬间，与运行设备的时区无关。
  static int epochMsFor(
    int year,
    int month,
    int day, [
    int hour = 0,
    int minute = 0,
    int second = 0,
    int millisecond = 0,
  ]) =>
      DateTime.utc(year, month, day, hour, minute, second, millisecond)
          .millisecondsSinceEpoch -
      offset.inMilliseconds;

  /// 把毫秒时间戳还原成当地墙上时间。
  static DateTime toLocal(int epochMs) =>
      DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true).add(offset);

  /// `09.23 · 14:26`。列表与卡片上的时间摘要。
  static String formatShort(int epochMs) {
    final local = toLocal(epochMs);
    return '${_two(local.month)}.${_two(local.day)} · '
        '${_two(local.hour)}:${_two(local.minute)}';
  }

  /// `2026.09.24 10:32`。导入记录这类需要年份的场合。
  static String formatFull(int epochMs) {
    final local = toLocal(epochMs);
    return '${local.year}.${_two(local.month)}.${_two(local.day)} '
        '${_two(local.hour)}:${_two(local.minute)}';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}
