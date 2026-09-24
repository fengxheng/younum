/// 版本化迁移。
///
/// 指南 2.1 要求「启用外键、索引、**迁移测试**」。
///
/// 这里把「按顺序执行哪些步骤」与「怎么在具体数据库上执行」分开：
/// [applyMigrations] 只接收一个执行 SQL 的回调，因此这套逻辑可以在
/// `flutter test` 里用一个记录语句的假执行器跑，不必依赖原生 SQLite；
/// 真机上则由 `SqfliteLedgerStore` 把回调接到真实数据库。
///
/// 迁移步骤必须是**累积**的：从 v1 升到 v3 会依次执行 1→2 与 2→3，
/// 不允许写「一步到位到最新版」的跳版迁移 —— 那样中间版本就永远没人测过。
library;

/// 一个迁移步骤。
final class Migration {
  const Migration({
    required this.from,
    required this.to,
    required this.description,
    required this.run,
  }) : assert(to == from + 1, '迁移必须逐版推进，不能跨越版本');

  /// 起始版本。
  final int from;

  /// 目标版本，必须等于 [from] + 1。
  final int to;

  /// 这一步做了什么。出错时打日志用。
  final String description;

  /// 执行迁移。可能包含多条 DDL / DML。
  final Future<void> Function(Future<void> Function(String sql) execute) run;
}

/// 迁移链不完整或版本无法到达时抛出。
final class MigrationError implements Exception {
  const MigrationError(this.message);

  final String message;

  @override
  String toString() => 'MigrationError: $message';
}

/// 从 [fromVersion] 升到 [toVersion]。
///
/// 返回实际执行了哪几步的描述，便于写入日志与测试断言。
/// 版本相同则什么都不做；降级会明确失败 —— 猜「怎么把数据改回旧结构」
/// 只会悄悄丢数据。
Future<List<String>> applyMigrations({
  required int fromVersion,
  required int toVersion,
  required List<Migration> migrations,
  required Future<void> Function(String sql) execute,
}) async {
  if (fromVersion == toVersion) return const <String>[];
  if (toVersion < fromVersion) {
    throw MigrationError('不支持降级：数据库是 v$fromVersion，代码期望 v$toVersion');
  }

  final applied = <String>[];
  var current = fromVersion;
  while (current < toVersion) {
    final step = _findStep(migrations, current);
    if (step == null) {
      throw MigrationError('缺少 v$current → v${current + 1} 的迁移步骤');
    }
    await step.run(execute);
    applied.add('v${step.from} → v${step.to}：${step.description}');
    current = step.to;
  }
  return applied;
}

Migration? _findStep(List<Migration> migrations, int from) {
  for (final migration in migrations) {
    if (migration.from == from) return migration;
  }
  return null;
}
