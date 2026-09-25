/// 具体的迁移链。
///
/// 关键约定：`SqfliteLedgerStore` 在**全新安装**时也是先建 v1、再跑迁移链升到
/// 当前版本。所以任何一次新增迁移都会被每次全新安装走到，
/// 不会出现「老用户的升级路径从没被执行过」这种情况。
library;

import 'migrations.dart';
import 'younum_schema.dart';

/// 全部迁移步骤，按版本顺序。
///
/// 每一步都必须是**逐版推进**的（`to == from + 1`），框架会在构造时就断言。
const List<Migration> younumMigrations = <Migration>[
  Migration(
    from: 1,
    to: 2,
    description: '新增导入批次、导入行暂存与交易来源绑定三张表',
    run: _addImportTables,
  ),
  Migration(
    from: 2,
    to: 3,
    description: '导入批次记住来源 URI，供导入历史重新解析',
    run: _addImportSourceUri,
  ),
  Migration(
    from: 3,
    to: 4,
    description: '新增分类图片图标资源表',
    run: _addIconAssetTable,
  ),
];

/// v3 → v4：分类图片图标的资源表。
///
/// 纯新增表，不动既有数据：升级后已有的分类仍然指向内置图标，
/// 不因为加了图片能力而变样。
Future<void> _addIconAssetTable(Future<void> Function(String sql) execute) async {
  for (final statement in younumSchemaV4) {
    await execute(statement);
  }
}

/// v1 → v2：导入相关结构。
///
/// 纯新增表，不改动既有数据，因此对已经存有账单的用户是安全的。
Future<void> _addImportTables(Future<void> Function(String sql) execute) async {
  for (final statement in younumSchemaV2) {
    await execute(statement);
  }
}

/// v2 → v3：导入批次记住来源 URI。
///
/// 为什么要存 URI：指南 4.2.2 要求「URI 仍可能失效时提供重新选择入口」。
/// 不记下来，用户想在导入历史里重新解析同一份文件就只能重新翻找。
///
/// 用 `ALTER TABLE ... ADD COLUMN` 而不是建新表再搬数据：新增可空列是
/// SQLite 从最老的版本就支持的写法，Android 8（minSdk 26）上也稳。
/// 反过来 `DROP COLUMN` 要 SQLite 3.35+，在这个工程里用不了。
///
/// 老批次这一列是 NULL —— 这是对的：它们本来就没记过来源 URI，
/// 界面上把 NULL 当作「来源文件已不可追溯」，不假装能重新解析。
Future<void> _addImportSourceUri(Future<void> Function(String sql) execute) async {
  await execute('ALTER TABLE import_batch ADD COLUMN source_uri TEXT');
}
