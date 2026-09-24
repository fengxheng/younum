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
];

/// v1 → v2：导入相关结构。
///
/// 纯新增表，不改动既有数据，因此对已经存有账单的用户是安全的。
Future<void> _addImportTables(Future<void> Function(String sql) execute) async {
  for (final statement in younumSchemaV2) {
    await execute(statement);
  }
}
