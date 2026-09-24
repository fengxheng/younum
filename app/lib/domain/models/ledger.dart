/// 账本。
///
/// 指南 1.3 要求示例体验只能进入**独立的演示账本**，退出后恢复真实数据。
/// 把 `isDemo` 做成账本自身的属性（而不是界面上一个开关）之后，
/// 只要每个查询都带上 `ledgerId`，就结构性地不可能出现
/// 「示例记录混进真实月度概况」这类事故。
///
/// 因此仓库层**不提供**「不带账本 ID 的查询」入口，见 `LedgerRepository`。
library;

/// 一个账本。
final class Ledger {
  const Ledger({
    required this.id,
    required this.name,
    required this.isDemo,
    required this.createdAtMs,
    this.currency = defaultCurrency,
    this.timeZone = defaultTimeZone,
  }) : assert(id != idUnassigned, '账本 ID 必须由数据库分配，不能用占位值');

  /// 还没写进数据库时的占位 ID。
  static const int idUnassigned = 0;

  /// 首版只统计人民币（指南 4.1）。外币行标记不支持，不自行猜汇率。
  static const String defaultCurrency = 'CNY';

  /// 无时区账单的默认解释时区（指南 3.1）。
  static const String defaultTimeZone = 'Asia/Shanghai';

  /// 稳定 ID。
  final int id;

  final String name;

  /// 真实账本 / 演示账本。两者数据互不可见。
  final bool isDemo;

  final String currency;

  /// 统计时区。历史账单的月份按它解释，不随设备时区漂移。
  final String timeZone;

  /// 创建时间（毫秒时间戳）。
  final int createdAtMs;

  @override
  bool operator ==(Object other) => other is Ledger && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Ledger($id, $name, demo=$isDemo)';
}
