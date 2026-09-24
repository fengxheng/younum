import 'dart:math' as math;

/// 可替换的时钟。
///
/// 实现指南 3.1 要求时间相关逻辑依赖可替换的 Clock，便于测试；
/// 也避免「设备旅行后切时区把历史账单挪月份」这类问题。
///
/// 首版只用于展示「下次提醒大致时间」，因此保持极简；
/// 阶段 6 接入真实提醒时会扩展为可注入的实例。
abstract final class YounumClock {
  static DateTime Function() _source = DateTime.now;

  /// 当前时间。
  static DateTime now() => _source();

  /// 测试用：替换时钟实现。
  static void overrideWith(DateTime Function() source) => _source = source;

  /// 恢复真实时钟。
  static void reset() => _source = DateTime.now;

  /// 显式指定时区，避免依赖设备默认时区（指南 3.1）。
  static const String statisticsTimeZone = 'Asia/Shanghai';

  /// 计算「每月第 [day] 日的 [hour] 点」的下一次触发时间（当地时间）。
  ///
  /// 按日历推算，而不是固定 30 天（指南 8.2）。
  /// 若当月该时刻已过，则顺延到下个月。
  static DateTime nextMonthly(int day, int hour, {DateTime? from}) {
    final base = from ?? now();
    final safeDay = day.clamp(1, 28);
    var candidate = DateTime(base.year, base.month, safeDay, hour);
    if (!candidate.isAfter(base)) {
      final nextMonth = base.month == 12 ? 1 : base.month + 1;
      final nextYear = base.month == 12 ? base.year + 1 : base.year;
      candidate = DateTime(nextYear, nextMonth, safeDay, hour);
    }
    return candidate;
  }
}

/// 剩余天数，用于「约 x 天后」这类不带压迫感的说明。
int daysUntil(DateTime target) {
  final now = YounumClock.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(target.year, target.month, target.day);
  return math.max(0, day.difference(today).inDays);
}
