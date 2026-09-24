/// 数据库结构与版本。
///
/// 设计原则（实现指南 2.1「启用外键、索引、迁移测试」）：
///
/// * **外键真的开**。SQLite 默认不强制外键，必须在 `onConfigure` 里
///   `PRAGMA foreign_keys = ON`，否则「悬空分类」「删除被引用的交易」
///   这类问题不会被拦住。
/// * **能由数据库保证的不靠代码自觉**：同源重复、重复拆分项、
///   同一退款重复抵扣、同一账本月份重复会话，都写成唯一索引。
/// * 枚举以**文本**存储并配 `CHECK` 约束：直接读数据库也能看懂，
///   而且新增枚举值时会立刻报错，不会静默写入一个没人认识的值。
library;

/// 当前结构版本。
const int younumSchemaVersion = 1;

/// v1 的建表语句。
///
/// 顺序有依赖：被引用的表必须先建（`ledger` → `txn` → `allocation`）。
const List<String> younumSchemaV1 = <String>[
  // 账本。演示账本与真实账本是两条记录，查询一律带 ledger_id。
  '''
  CREATE TABLE ledger (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    is_demo INTEGER NOT NULL CHECK (is_demo IN (0, 1)),
    currency TEXT NOT NULL,
    time_zone TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL
  )
  ''',
  'CREATE UNIQUE INDEX idx_ledger_name ON ledger(name)',

  // 分类。v1 的分类集合全局共享（指南 3.2 的 Category 不含账本维度）。
  '''
  CREATE TABLE category (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    parent_id INTEGER REFERENCES category(id) ON DELETE RESTRICT,
    name TEXT NOT NULL,
    icon_type TEXT NOT NULL CHECK (icon_type IN ('BUILTIN', 'IMAGE')),
    icon_key TEXT,
    sort_order INTEGER NOT NULL DEFAULT 0,
    is_builtin INTEGER NOT NULL CHECK (is_builtin IN (0, 1)),
    archived INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
    CHECK (icon_type <> 'BUILTIN' OR icon_key IS NOT NULL)
  )
  ''',
  // 同级分类不能重名。parent_id 为 NULL 时 ifnull 把它折成 -1，
  // 否则 SQLite 认为两个 NULL 互不相等，一级分类可以重名。
  '''
  CREATE UNIQUE INDEX idx_category_parent_name
    ON category(ifnull(parent_id, -1), name)
  ''',
  'CREATE INDEX idx_category_parent ON category(parent_id, sort_order)',

  // 交易。
  '''
  CREATE TABLE txn (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ledger_id INTEGER NOT NULL REFERENCES ledger(id) ON DELETE CASCADE,
    source_namespace TEXT,
    source_account TEXT,
    source_transaction_id TEXT,
    dedupe_key TEXT,
    occurred_at_ms INTEGER NOT NULL,
    raw_time_text TEXT,
    time_zone TEXT NOT NULL,
    amount_cents INTEGER NOT NULL CHECK (amount_cents >= 0),
    currency TEXT NOT NULL,
    merchant TEXT NOT NULL DEFAULT '',
    note TEXT,
    nature TEXT NOT NULL CHECK (
      nature IN ('EXPENSE', 'INCOME', 'TRANSFER', 'REFUND', 'EXCLUDED', 'UNKNOWN')
    ),
    review_status TEXT NOT NULL CHECK (
      review_status IN ('PENDING', 'DEFERRED', 'RESOLVED')
    ),
    exclude_reason TEXT,
    version INTEGER NOT NULL DEFAULT 1 CHECK (version >= 1),
    import_batch_id INTEGER,
    -- 排除统计必须保留原因（指南 3.3）。
    CHECK (nature <> 'EXCLUDED' OR exclude_reason IS NOT NULL)
  )
  ''',
  // 同源去重：同一账本内，同一「命名空间 + 账户 + 源交易 ID」只能有一条。
  // 部分索引：没有稳定来源 ID 的记录不参与（它们只能算疑似重复，不能自动删）。
  '''
  CREATE UNIQUE INDEX idx_txn_source
    ON txn(ledger_id, dedupe_key)
    WHERE dedupe_key IS NOT NULL
  ''',
  'CREATE INDEX idx_txn_ledger_month ON txn(ledger_id, occurred_at_ms DESC)',
  'CREATE INDEX idx_txn_ledger_status ON txn(ledger_id, review_status)',

  // 分配。未拆分的单分类消费也有一条，统计代码因此只有一条路径。
  '''
  CREATE TABLE allocation (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    transaction_id INTEGER NOT NULL REFERENCES txn(id) ON DELETE CASCADE,
    category_id INTEGER NOT NULL REFERENCES category(id) ON DELETE RESTRICT,
    amount_cents INTEGER NOT NULL CHECK (amount_cents > 0)
  )
  ''',
  // 同一笔消费不能对同一分类拆出两项（指南 4.3 的「重复拆分项」）。
  '''
  CREATE UNIQUE INDEX idx_allocation_tx_category
    ON allocation(transaction_id, category_id)
  ''',
  'CREATE INDEX idx_allocation_category ON allocation(category_id)',

  // 退款关联。首版一笔退款对应一笔原消费，因此 refund_transaction_id 唯一。
  '''
  CREATE TABLE refund_link (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    refund_transaction_id INTEGER NOT NULL REFERENCES txn(id) ON DELETE CASCADE,
    original_transaction_id INTEGER NOT NULL REFERENCES txn(id) ON DELETE RESTRICT,
    amount_cents INTEGER NOT NULL CHECK (amount_cents > 0),
    CHECK (refund_transaction_id <> original_transaction_id)
  )
  ''',
  '''
  CREATE UNIQUE INDEX idx_refund_link_refund
    ON refund_link(refund_transaction_id)
  ''',
  'CREATE INDEX idx_refund_link_original ON refund_link(original_transaction_id)',

  // 退款分配：拆分消费的退款必须说明抵扣到哪一项。
  '''
  CREATE TABLE refund_allocation (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    refund_link_id INTEGER NOT NULL REFERENCES refund_link(id) ON DELETE CASCADE,
    original_allocation_id INTEGER NOT NULL REFERENCES allocation(id) ON DELETE RESTRICT,
    amount_cents INTEGER NOT NULL CHECK (amount_cents > 0)
  )
  ''',
  '''
  CREATE UNIQUE INDEX idx_refund_allocation_unique
    ON refund_allocation(refund_link_id, original_allocation_id)
  ''',

  // 整理会话。
  '''
  CREATE TABLE review_session (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ledger_id INTEGER NOT NULL REFERENCES ledger(id) ON DELETE CASCADE,
    year INTEGER NOT NULL,
    month INTEGER NOT NULL CHECK (month BETWEEN 1 AND 12),
    current_transaction_id INTEGER REFERENCES txn(id) ON DELETE SET NULL,
    sort_mode TEXT NOT NULL,
    updated_at_ms INTEGER NOT NULL
  )
  ''',
  '''
  CREATE UNIQUE INDEX idx_review_session_unique
    ON review_session(ledger_id, year, month)
  ''',

  // 队列顺序。position 显式保存，重启后顺序不丢。
  '''
  CREATE TABLE review_queue_item (
    session_id INTEGER NOT NULL REFERENCES review_session(id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    transaction_id INTEGER NOT NULL REFERENCES txn(id) ON DELETE CASCADE,
    bucket TEXT NOT NULL CHECK (bucket IN ('MAIN', 'DEFERRED')),
    PRIMARY KEY (session_id, position)
  )
  ''',
  '''
  CREATE UNIQUE INDEX idx_review_queue_tx
    ON review_queue_item(session_id, transaction_id)
  ''',

  // 整理操作日志。before_json 保存「操作前快照」，撤销据此恢复。
  '''
  CREATE TABLE review_action (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL REFERENCES review_session(id) ON DELETE CASCADE,
    action_type TEXT NOT NULL CHECK (
      action_type IN ('RESOLVE', 'DEFER', 'REOPEN_DEFERRED')
    ),
    label TEXT NOT NULL,
    before_json TEXT NOT NULL,
    undo_state TEXT NOT NULL CHECK (
      undo_state IN ('AVAILABLE', 'USED', 'INVALIDATED')
    ),
    created_at_ms INTEGER NOT NULL
  )
  ''',
  '''
  CREATE INDEX idx_review_action_session
    ON review_action(session_id, id DESC)
  ''',

  // 月份范围确认。coverage_confirmed 只能由用户显式确认（指南 3.4）。
  '''
  CREATE TABLE month_review (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ledger_id INTEGER NOT NULL REFERENCES ledger(id) ON DELETE CASCADE,
    year INTEGER NOT NULL,
    month INTEGER NOT NULL CHECK (month BETWEEN 1 AND 12),
    coverage_confirmed INTEGER NOT NULL DEFAULT 0
      CHECK (coverage_confirmed IN (0, 1)),
    confirmed_at_ms INTEGER,
    revision INTEGER NOT NULL DEFAULT 1
  )
  ''',
  '''
  CREATE UNIQUE INDEX idx_month_review_unique
    ON month_review(ledger_id, year, month)
  ''',
];
