/// 具体的迁移链。
///
/// v1 是初始结构，所以现在这一步是空的 —— 但**框架是活的**：
/// `SqfliteLedgerStore` 在全新安装时也会先建 v1 再跑迁移链，
/// 因此任何一次新增迁移都会被每次全新安装走到，不会出现
/// 「老用户升级路径从没被跑过」这种情况。
///
/// 阶段 4 会加第一步真实迁移：为分类自定义图片补上
/// `category_icon_asset` 表与 `category.icon_asset_id` 外键。
library;

import 'migrations.dart';

/// 全部迁移步骤，按版本顺序。
const List<Migration> younumMigrations = <Migration>[];
