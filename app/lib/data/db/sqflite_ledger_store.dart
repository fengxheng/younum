/// 基于 sqflite 的账本存储。
///
/// 为什么是 sqflite 而不是 drift：sqflite 在 Android 上直接用系统自带的
/// SQLite（`android.database.sqlite`），**不需要编译任何原生库**，
/// 因此不引入 NDK / CMake 环节；本机的 Android 工具链已经出过两次
/// 组件安装问题（见 `docs/DECISIONS.md`），少一个编译环节少一个坑。
///
/// 代价是没有编译期的查询类型检查，所以这里用显式 SQL + 集中在一处的
/// 行映射函数换取可读性，并把「金额守恒、跨月退款」这类真正的业务规则
/// 放在领域层（`lib/domain/rules/`），由单元测试覆盖 ——
/// 不依赖 ORM 的类型安全。
///
/// 外键在 `onConfigure` 里显式打开：**SQLite 默认不强制外键**，
/// 不写这一句，所有 `REFERENCES` 都只是注释。
library;

import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../core/time/statistics_time.dart';
import '../../data/seed/demo_ledger_seed.dart';
import '../../domain/models/allocation.dart';
import '../../domain/models/category.dart';
import '../../domain/models/ledger.dart';
import '../../domain/models/ledger_dataset.dart';
import '../../domain/models/ledger_transaction.dart';
import '../../domain/models/review_session_record.dart';
import '../../domain/models/year_month.dart';
import '../../domain/repositories/ledger_store.dart';
import 'migrations.dart';
import 'younum_migrations.dart';
import 'younum_schema.dart';

/// SQLite 存储。
final class SqfliteLedgerStore implements LedgerStore {
  SqfliteLedgerStore({String? databasePath, DatabaseFactory? factory})
      : _customPath = databasePath,
        _factory = factory ?? databaseFactory;

  static const String fileName = 'younum.db';

  final String? _customPath;
  final DatabaseFactory _factory;

  Database? _database;

  /// 打开（必要时创建并迁移）数据库。
  Future<Database> _open() async {
    final existing = _database;
    if (existing != null) return existing;

    final path = _customPath ?? p.join(await _factory.getDatabasesPath(), fileName);
    final database = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: younumSchemaVersion,
        onConfigure: (db) async {
          // 关键一步：不打开这个开关，所有外键都形同虚设。
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, version) async {
          // 全新安装先建 v1，再跑迁移链升到当前版本。
          // 这样「升级路径」在每次全新安装时都被走一遍。
          for (final statement in younumSchemaV1) {
            await db.execute(statement);
          }
          await _runMigrations(db, from: 1, to: version);
        },
        onUpgrade: (db, oldVersion, newVersion) =>
            _runMigrations(db, from: oldVersion, to: newVersion),
        onDowngrade: (db, oldVersion, newVersion) async {
          throw MigrationError(
            '数据库版本 v$oldVersion 高于代码期望的 v$newVersion，'
            '不支持降级',
          );
        },
      ),
    );
    _database = database;
    return database;
  }

  static Future<void> _runMigrations(
    Database db, {
    required int from,
    required int to,
  }) async {
    await applyMigrations(
      fromVersion: from,
      toVersion: to,
      migrations: younumMigrations,
      execute: (sql) async {
        await db.execute(sql);
      },
    );
  }

  Future<Database> get _db => _open();

  /// 关闭连接。测试与「清除数据」之后使用。
  Future<void> close() async {
    await _database?.close();
    _database = null;
  }

  // ---------------------------------------------------------------------------
  // 初始化
  // ---------------------------------------------------------------------------

  @override
  Future<void> initialize() async {
    final db = await _db;
    await db.transaction((txn) async {
      // 全部用 OR IGNORE：重复调用不会覆盖用户已经改过的数据。
      for (final ledger in <Ledger>[
        DemoLedgerSeed.demoLedger(),
        DemoLedgerSeed.realLedger(),
      ]) {
        await txn.insert(
          'ledger',
          <String, Object?>{
            'id': ledger.id,
            'name': ledger.name,
            'is_demo': ledger.isDemo ? 1 : 0,
            'currency': ledger.currency,
            'time_zone': ledger.timeZone,
            'created_at_ms': ledger.createdAtMs,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      for (final category in DemoLedgerSeed.categories()) {
        await txn.insert(
          'category',
          _categoryValues(category),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      for (final transaction in DemoLedgerSeed.baselineTransactions()) {
        await txn.insert(
          'txn',
          _transactionValues(transaction),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    });
  }

  @override
  Future<void> clearAll() async {
    final db = await _db;
    await db.transaction((txn) async {
      // 顺序跟着外键关系走：先删引用了别的表的行。
      // refund_link.original_transaction_id 是 ON DELETE RESTRICT，
      // 必须先删关联再删交易。
      await txn.delete('review_action');
      await txn.delete('review_queue_item');
      await txn.delete('review_session');
      await txn.delete('month_review');
      await txn.delete('refund_allocation');
      await txn.delete('refund_link');
      await txn.delete('allocation');
      await txn.delete('txn');
      await txn.delete('category', where: 'is_builtin = 0');
    });
    // 重新写入初始的演示账单（INSERT OR IGNORE，不会重复）。
    await initialize();
  }

  // ---------------------------------------------------------------------------
  // 读
  // ---------------------------------------------------------------------------

  @override
  Future<List<Ledger>> ledgers() async {
    final db = await _db;
    final rows = await db.query('ledger', orderBy: 'id ASC');
    return <Ledger>[for (final row in rows) _ledgerFrom(row)];
  }

  @override
  Future<List<Category>> categories({required int ledgerId}) async {
    // v1 的分类集合不按账本划分（指南 3.2 的 Category 没有账本维度），
    // 参数保留是为了后续支持「每本账一套分类」时不用改调用方。
    final db = await _db;
    final rows = await db.query('category', orderBy: 'parent_id ASC, sort_order ASC, id ASC');
    return <Category>[for (final row in rows) _categoryFrom(row)];
  }

  @override
  Future<LedgerTransaction?> transactionById(int transactionId) async {
    final db = await _db;
    final rows = await db.query(
      'txn',
      where: 'id = ?',
      whereArgs: <Object?>[transactionId],
      limit: 1,
    );
    return rows.isEmpty ? null : _transactionFrom(rows.first);
  }

  @override
  Future<LedgerDataset> dataset({
    required int ledgerId,
    Set<YearMonth>? months,
  }) async {
    final db = await _db;

    if (months != null && months.isEmpty) {
      return LedgerDataset(categories: await categories(ledgerId: ledgerId));
    }

    final where = StringBuffer('ledger_id = ?');
    final args = <Object?>[ledgerId];
    if (months != null) {
      final clauses = <String>[];
      for (final month in months) {
        clauses.add('(occurred_at_ms BETWEEN ? AND ?)');
        args
          ..add(_startOf(month))
          ..add(_endOf(month));
      }
      where.write(' AND (${clauses.join(' OR ')})');
    }

    final transactionRows = await db.rawQuery(
      'SELECT * FROM txn WHERE $where ORDER BY occurred_at_ms DESC, id DESC',
      args,
    );
    final transactions = <LedgerTransaction>[
      for (final row in transactionRows) _transactionFrom(row),
    ];
    final baseIds = <int>[for (final transaction in transactions) transaction.id];

    // 跨月退款：还要把「关联到这些消费的退款」带进来，即使退款本身在别的月份。
    final links = <RefundLink>[];
    final extraTransactions = <LedgerTransaction>[];
    if (months != null && baseIds.isNotEmpty) {
      final linkRows = await _queryIn(
        db,
        table: 'refund_link',
        column: 'original_transaction_id',
        ids: baseIds,
      );
      links.addAll(<RefundLink>[for (final row in linkRows) _refundLinkFrom(row)]);
      final refundIds = <int>[
        for (final link in links) link.refundTransactionId,
      ];
      final refundRows = await _queryIn(
        db,
        table: 'txn',
        column: 'id',
        ids: refundIds,
      );
      extraTransactions.addAll(<LedgerTransaction>[
        for (final row in refundRows) _transactionFrom(row),
      ]);
    }

    final allIds = <int>[
      ...baseIds,
      for (final transaction in extraTransactions) transaction.id,
    ];

    final allocationRows = await _queryIn(
      db,
      table: 'allocation',
      column: 'transaction_id',
      ids: allIds,
    );
    final linkIds = <int>[for (final link in links) link.id];
    final refundAllocationRows = await _queryIn(
      db,
      table: 'refund_allocation',
      column: 'refund_link_id',
      ids: linkIds,
    );

    return LedgerDataset(
      transactions: <LedgerTransaction>[...transactions, ...extraTransactions],
      allocations: <Allocation>[
        for (final row in allocationRows) _allocationFrom(row),
      ],
      refundLinks: links,
      refundAllocations: <RefundAllocation>[
        for (final row in refundAllocationRows) _refundAllocationFrom(row),
      ],
      categories: await categories(ledgerId: ledgerId),
    );
  }

  /// 按 ID 批量查询，自动分块（SQLite 对单条语句的变量数有上限）。
  Future<List<Map<String, Object?>>> _queryIn(
    DatabaseExecutor db, {
    required String table,
    required String column,
    required List<int> ids,
  }) async {
    if (ids.isEmpty) return const <Map<String, Object?>>[];
    final unique = ids.toSet().toList();
    final result = <Map<String, Object?>>[];
    const chunkSize = 400;
    for (var start = 0; start < unique.length; start += chunkSize) {
      final chunk = unique.sublist(
        start,
        start + chunkSize > unique.length ? unique.length : start + chunkSize,
      );
      final placeholders = List<String>.filled(chunk.length, '?').join(', ');
      result.addAll(
        await db.rawQuery(
          'SELECT * FROM $table WHERE $column IN ($placeholders)',
          chunk,
        ),
      );
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // 写
  // ---------------------------------------------------------------------------

  @override
  Future<int> insertTransaction(LedgerTransaction transaction) async {
    final db = await _db;
    return db.insert('txn', _transactionValues(transaction, includeId: false));
  }

  @override
  Future<bool> updateTransaction({
    required LedgerTransaction transaction,
    required int expectedVersion,
  }) async {
    final db = await _db;
    final updated = await db.rawUpdate(
      '''
      UPDATE txn SET
        occurred_at_ms = ?, amount_cents = ?, merchant = ?, note = ?,
        nature = ?, review_status = ?, exclude_reason = ?,
        source_namespace = ?, source_account = ?, source_transaction_id = ?,
        dedupe_key = ?, raw_time_text = ?, version = version + 1
      WHERE id = ? AND version = ?
      ''',
      <Object?>[
        transaction.occurredAtMs,
        transaction.amountCents,
        transaction.merchant,
        transaction.note,
        transaction.nature.storageValue,
        transaction.reviewStatus.storageValue,
        transaction.excludeReason,
        transaction.sourceNamespace,
        transaction.sourceAccount,
        transaction.sourceTransactionId,
        transaction.dedupeKey,
        transaction.rawTimeText,
        transaction.id,
        expectedVersion,
      ],
    );
    return updated == 1;
  }

  @override
  Future<bool> resolveTransaction({
    required LedgerTransaction before,
    required int categoryId,
    required ReviewSessionRecord session,
    required UndoRecord undo,
  }) async {
    final db = await _db;
    var conflicted = false;
    await db.transaction((txn) async {
      final updated = await txn.rawUpdate(
        '''
        UPDATE txn SET review_status = ?, version = version + 1
        WHERE id = ? AND version = ?
        ''',
        <Object?>[ReviewStatus.resolved.storageValue, before.id, before.version],
      );
      if (updated != 1) {
        conflicted = true;
        return;
      }
      await txn.delete(
        'allocation',
        where: 'transaction_id = ?',
        whereArgs: <Object?>[before.id],
      );
      await txn.insert('allocation', <String, Object?>{
        'transaction_id': before.id,
        'category_id': categoryId,
        'amount_cents': before.amountCents,
      });
      await _writeSession(txn, session);
      await _appendAction(txn, session, undo);
    });
    return !conflicted;
  }

  @override
  Future<bool> deferTransaction({
    required LedgerTransaction before,
    required ReviewSessionRecord session,
    required UndoRecord undo,
  }) async {
    final db = await _db;
    var conflicted = false;
    await db.transaction((txn) async {
      final updated = await txn.rawUpdate(
        '''
        UPDATE txn SET review_status = ?, version = version + 1
        WHERE id = ? AND version = ?
        ''',
        <Object?>[ReviewStatus.deferred.storageValue, before.id, before.version],
      );
      if (updated != 1) {
        conflicted = true;
        return;
      }
      await _writeSession(txn, session);
      await _appendAction(txn, session, undo);
    });
    return !conflicted;
  }

  @override
  Future<bool> reopenDeferred({
    required List<LedgerTransaction> transactions,
    required ReviewSessionRecord session,
    required UndoRecord undo,
  }) async {
    final db = await _db;
    var conflicted = false;
    await db.transaction((txn) async {
      for (final transaction in transactions) {
        final updated = await txn.rawUpdate(
          '''
          UPDATE txn SET review_status = ?, version = version + 1
          WHERE id = ? AND version = ?
          ''',
          <Object?>[
            ReviewStatus.pending.storageValue,
            transaction.id,
            transaction.version,
          ],
        );
        if (updated != 1) {
          conflicted = true;
          return;
        }
      }
      await _writeSession(txn, session);
      await _appendAction(txn, session, undo);
    });
    return !conflicted;
  }

  @override
  Future<void> saveSessionWithUndo({
    required ReviewSessionRecord session,
    required UndoRecord undo,
  }) async {
    final db = await _db;
    await db.transaction((txn) async {
      await _writeSession(txn, session);
      await _appendAction(txn, session, undo);
    });
  }

  @override
  Future<void> saveReviewSession({required ReviewSessionRecord record}) async {
    final db = await _db;
    await db.transaction((txn) async {
      await _writeSession(txn, record);
    });
  }

  @override
  Future<int> insertRefundLink({
    required int refundTransactionId,
    required int originalTransactionId,
    required int amountCents,
    List<RefundAllocationDraft> allocations = const <RefundAllocationDraft>[],
  }) async {
    final db = await _db;
    return db.transaction<int>((txn) async {
      final linkId = await txn.insert('refund_link', <String, Object?>{
        'refund_transaction_id': refundTransactionId,
        'original_transaction_id': originalTransactionId,
        'amount_cents': amountCents,
      });
      for (final draft in allocations) {
        await txn.insert('refund_allocation', <String, Object?>{
          'refund_link_id': linkId,
          'original_allocation_id': draft.originalAllocationId,
          'amount_cents': draft.amountCents,
        });
      }
      return linkId;
    });
  }

  // ---------------------------------------------------------------------------
  // 会话
  // ---------------------------------------------------------------------------

  @override
  Future<ReviewSessionRecord?> loadReviewSession({
    required int ledgerId,
    required YearMonth month,
  }) async {
    final db = await _db;
    final rows = await db.query(
      'review_session',
      where: 'ledger_id = ? AND year = ? AND month = ?',
      whereArgs: <Object?>[ledgerId, month.year, month.month],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final sessionId = row['id']! as int;
    final itemRows = await db.query(
      'review_queue_item',
      where: 'session_id = ?',
      whereArgs: <Object?>[sessionId],
      orderBy: 'position ASC',
    );
    return ReviewSessionRecord(
      id: sessionId,
      ledgerId: ledgerId,
      month: month,
      entries: <ReviewQueueEntry>[
        for (final item in itemRows)
          ReviewQueueEntry(
            transactionId: item['transaction_id']! as int,
            bucket: ReviewBucket.parse(item['bucket']! as String),
          ),
      ],
      updatedAtMs: row['updated_at_ms']! as int,
      currentTransactionId: row['current_transaction_id'] as int?,
      sortMode: row['sort_mode']! as String,
    );
  }

  @override
  Future<bool> coverageConfirmed({
    required int ledgerId,
    required YearMonth month,
  }) async {
    final db = await _db;
    final rows = await db.query(
      'month_review',
      columns: <String>['coverage_confirmed'],
      where: 'ledger_id = ? AND year = ? AND month = ?',
      whereArgs: <Object?>[ledgerId, month.year, month.month],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    return (rows.first['coverage_confirmed']! as int) == 1;
  }

  @override
  Future<void> setCoverageConfirmed({
    required int ledgerId,
    required YearMonth month,
    required bool value,
  }) async {
    final db = await _db;
    await db.rawInsert(
      '''
      INSERT INTO month_review
        (ledger_id, year, month, coverage_confirmed, confirmed_at_ms, revision)
      VALUES (?, ?, ?, ?, ?, 1)
      ON CONFLICT(ledger_id, year, month) DO UPDATE SET
        coverage_confirmed = excluded.coverage_confirmed,
        confirmed_at_ms = excluded.confirmed_at_ms,
        revision = month_review.revision + 1
      ''',
      <Object?>[
        ledgerId,
        month.year,
        month.month,
        value ? 1 : 0,
        value ? DateTime.now().millisecondsSinceEpoch : null,
      ],
    );
  }

  @override
  Future<UndoRecord?> latestAvailableAction({
    required int ledgerId,
    required YearMonth month,
  }) async {
    final db = await _db;
    final rows = await db.rawQuery(
      '''
      SELECT action.* FROM review_action AS action
      JOIN review_session AS session ON session.id = action.session_id
      WHERE session.ledger_id = ? AND session.year = ? AND session.month = ?
        AND action.undo_state = ?
      ORDER BY action.id DESC
      LIMIT 1
      ''',
      <Object?>[ledgerId, month.year, month.month, ReviewActionState.available.storageValue],
    );
    if (rows.isEmpty) return null;
    return _undoFromRow(rows.first, ledgerId: ledgerId, month: month);
  }

  @override
  Future<bool> applyUndo({
    required UndoRecord action,
    required ReviewSessionRecord session,
  }) async {
    final db = await _db;
    var conflicted = false;
    await db.transaction((txn) async {
      // 先把所有目标校验完再写：任一对不上就整体不写（事务回滚）。
      for (final target in action.targets) {
        final rows = await txn.query(
          'txn',
          columns: <String>['version'],
          where: 'id = ?',
          whereArgs: <Object?>[target.transactionId],
          limit: 1,
        );
        if (rows.isEmpty ||
            (rows.first['version']! as int) != target.afterVersion) {
          conflicted = true;
          return;
        }
      }

      for (final target in action.targets) {
        await txn.rawUpdate(
          '''
          UPDATE txn SET review_status = ?, nature = ?, version = ?
          WHERE id = ?
          ''',
          <Object?>[
            target.beforeStatus.storageValue,
            target.beforeNature.storageValue,
            target.beforeVersion + 1,
            target.transactionId,
          ],
        );
        await txn.delete(
          'allocation',
          where: 'transaction_id = ?',
          whereArgs: <Object?>[target.transactionId],
        );
        for (final draft in target.beforeAllocations) {
          await txn.insert('allocation', <String, Object?>{
            'transaction_id': target.transactionId,
            'category_id': draft.categoryId,
            'amount_cents': draft.amountCents,
          });
        }
      }

      await txn.update(
        'review_action',
        <String, Object?>{'undo_state': ReviewActionState.used.storageValue},
        where: 'id = ?',
        whereArgs: <Object?>[action.id],
      );
      await _writeSession(txn, session);
    });
    return !conflicted;
  }

  @override
  Future<void> invalidateAction(int actionId) async {
    final db = await _db;
    await db.update(
      'review_action',
      <String, Object?>{'undo_state': ReviewActionState.invalidated.storageValue},
      where: 'id = ?',
      whereArgs: <Object?>[actionId],
    );
  }

  /// 写入会话与队列顺序。
  Future<int> _writeSession(
    DatabaseExecutor executor,
    ReviewSessionRecord session,
  ) async {
    final sessionId = await _ensureSessionRow(executor, session);
    await executor.update(
      'review_session',
      <String, Object?>{
        'current_transaction_id': session.currentTransactionId,
        'sort_mode': session.sortMode,
        'updated_at_ms': session.updatedAtMs,
      },
      where: 'id = ?',
      whereArgs: <Object?>[sessionId],
    );
    // 队列很短（一个月几十条），整体重写比维护增量更不容易出错。
    await executor.delete(
      'review_queue_item',
      where: 'session_id = ?',
      whereArgs: <Object?>[sessionId],
    );
    for (var position = 0; position < session.entries.length; position++) {
      final entry = session.entries[position];
      await executor.insert(
        'review_queue_item',
        <String, Object?>{
          'session_id': sessionId,
          'position': position,
          'transaction_id': entry.transactionId,
          'bucket': entry.bucket.storageValue,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    return sessionId;
  }

  Future<int> _ensureSessionRow(
    DatabaseExecutor executor,
    ReviewSessionRecord session,
  ) async {
    final rows = await executor.query(
      'review_session',
      columns: <String>['id'],
      where: 'ledger_id = ? AND year = ? AND month = ?',
      whereArgs: <Object?>[session.ledgerId, session.month.year, session.month.month],
      limit: 1,
    );
    if (rows.isNotEmpty) return rows.first['id']! as int;
    return executor.insert('review_session', <String, Object?>{
      'ledger_id': session.ledgerId,
      'year': session.month.year,
      'month': session.month.month,
      'current_transaction_id': session.currentTransactionId,
      'sort_mode': session.sortMode,
      'updated_at_ms': session.updatedAtMs,
    });
  }

  Future<void> _appendAction(
    DatabaseExecutor executor,
    ReviewSessionRecord session,
    UndoRecord undo,
  ) async {
    final sessionId = await _ensureSessionRow(executor, session);
    await executor.insert('review_action', <String, Object?>{
      'session_id': sessionId,
      'action_type': undo.type.storageValue,
      'label': undo.label,
      'before_json': _encodeUndo(undo),
      'undo_state': undo.state.storageValue,
      'created_at_ms': undo.createdAtMs,
    });
  }

  // ---------------------------------------------------------------------------
  // 行映射
  // ---------------------------------------------------------------------------

  static int _startOf(YearMonth month) =>
      StatisticsTime.epochMsFor(month.year, month.month, 1);

  static int _endOf(YearMonth month) => _startOf(month.next) - 1;

  static Ledger _ledgerFrom(Map<String, Object?> row) => Ledger(
        id: row['id']! as int,
        name: row['name']! as String,
        isDemo: (row['is_demo']! as int) == 1,
        currency: row['currency']! as String,
        timeZone: row['time_zone']! as String,
        createdAtMs: row['created_at_ms']! as int,
      );

  static Category _categoryFrom(Map<String, Object?> row) => Category(
        id: row['id']! as int,
        parentId: row['parent_id'] as int?,
        name: row['name']! as String,
        iconType: CategoryIconType.parse(row['icon_type']! as String),
        iconKey: row['icon_key'] as String?,
        sortOrder: row['sort_order']! as int,
        isBuiltin: (row['is_builtin']! as int) == 1,
        archived: (row['archived']! as int) == 1,
      );

  static LedgerTransaction _transactionFrom(Map<String, Object?> row) =>
      LedgerTransaction(
        id: row['id']! as int,
        ledgerId: row['ledger_id']! as int,
        occurredAtMs: row['occurred_at_ms']! as int,
        amountCents: row['amount_cents']! as int,
        merchant: row['merchant']! as String,
        nature: TransactionNature.parse(row['nature']! as String),
        reviewStatus: ReviewStatus.parse(row['review_status']! as String),
        timeZone: row['time_zone']! as String,
        sourceNamespace: row['source_namespace'] as String?,
        sourceAccount: row['source_account'] as String?,
        sourceTransactionId: row['source_transaction_id'] as String?,
        rawTimeText: row['raw_time_text'] as String?,
        note: row['note'] as String?,
        excludeReason: row['exclude_reason'] as String?,
        importBatchId: row['import_batch_id'] as int?,
        version: row['version']! as int,
        currency: row['currency']! as String,
      );

  static Map<String, Object?> _transactionValues(
    LedgerTransaction transaction, {
    bool includeId = true,
  }) =>
      <String, Object?>{
        if (includeId && transaction.isPersisted) 'id': transaction.id,
        'ledger_id': transaction.ledgerId,
        'source_namespace': transaction.sourceNamespace,
        'source_account': transaction.sourceAccount,
        'source_transaction_id': transaction.sourceTransactionId,
        'dedupe_key': transaction.dedupeKey,
        'occurred_at_ms': transaction.occurredAtMs,
        'raw_time_text': transaction.rawTimeText,
        'time_zone': transaction.timeZone,
        'amount_cents': transaction.amountCents,
        'currency': transaction.currency,
        'merchant': transaction.merchant,
        'note': transaction.note,
        'nature': transaction.nature.storageValue,
        'review_status': transaction.reviewStatus.storageValue,
        'exclude_reason': transaction.excludeReason,
        'version': transaction.version,
        'import_batch_id': transaction.importBatchId,
      };

  static Map<String, Object?> _categoryValues(Category category) =>
      <String, Object?>{
        'id': category.id,
        'parent_id': category.parentId,
        'name': category.name,
        'icon_type': category.iconType.storageValue,
        'icon_key': category.iconKey,
        'sort_order': category.sortOrder,
        'is_builtin': category.isBuiltin ? 1 : 0,
        'archived': category.archived ? 1 : 0,
      };

  static Allocation _allocationFrom(Map<String, Object?> row) => Allocation(
        id: row['id']! as int,
        transactionId: row['transaction_id']! as int,
        categoryId: row['category_id']! as int,
        amountCents: row['amount_cents']! as int,
      );

  static RefundLink _refundLinkFrom(Map<String, Object?> row) => RefundLink(
        id: row['id']! as int,
        refundTransactionId: row['refund_transaction_id']! as int,
        originalTransactionId: row['original_transaction_id']! as int,
        amountCents: row['amount_cents']! as int,
      );

  static RefundAllocation _refundAllocationFrom(Map<String, Object?> row) =>
      RefundAllocation(
        id: row['id']! as int,
        refundLinkId: row['refund_link_id']! as int,
        originalAllocationId: row['original_allocation_id']! as int,
        amountCents: row['amount_cents']! as int,
      );

  // ---------------------------------------------------------------------------
  // 撤销快照的 JSON 编解码
  // ---------------------------------------------------------------------------

  /// 序列化「操作前快照」。
  ///
  /// 存 JSON 而不是再开几张表：快照的字段会随规则演进（阶段 4 会加退款关联），
  /// 而它只是**日志**，不需要被 SQL 查询，也不需要外键。
  /// 需要被查询的部分（状态、版本、分配）都在正式表里。
  static String _encodeUndo(UndoRecord undo) => jsonEncode(<String, Object?>{
        'targets': <Map<String, Object?>>[
          for (final target in undo.targets)
            <String, Object?>{
              'id': target.transactionId,
              'version': target.beforeVersion,
              'status': target.beforeStatus.storageValue,
              'nature': target.beforeNature.storageValue,
              'allocations': <Map<String, Object?>>[
                for (final draft in target.beforeAllocations)
                  <String, Object?>{
                    'categoryId': draft.categoryId,
                    'amountCents': draft.amountCents,
                  },
              ],
            },
        ],
        'entries': <String>[
          for (final entry in undo.beforeEntries)
            '${entry.bucket.storageValue}:${entry.transactionId}',
        ],
      });

  static UndoRecord _undoFromRow(
    Map<String, Object?> row, {
    required int ledgerId,
    required YearMonth month,
  }) {
    final decoded = jsonDecode(row['before_json']! as String) as Map<String, Object?>;
    final targets = <UndoTarget>[
      for (final raw in (decoded['targets']! as List<Object?>))
        _targetFromJson(raw! as Map<String, Object?>),
    ];
    final entries = <ReviewQueueEntry>[
      for (final raw in (decoded['entries']! as List<Object?>))
        _entryFromString(raw! as String),
    ];
    return UndoRecord(
      id: row['id']! as int,
      type: ReviewActionType.parse(row['action_type']! as String),
      label: row['label']! as String,
      ledgerId: ledgerId,
      month: month,
      targets: targets,
      beforeEntries: entries,
      createdAtMs: row['created_at_ms']! as int,
      state: ReviewActionState.parse(row['undo_state']! as String),
    );
  }

  static UndoTarget _targetFromJson(Map<String, Object?> raw) => UndoTarget(
        transactionId: raw['id']! as int,
        beforeVersion: raw['version']! as int,
        beforeStatus: ReviewStatus.parse(raw['status']! as String),
        beforeNature: TransactionNature.parse(raw['nature']! as String),
        beforeAllocations: <AllocationDraft>[
          for (final draft in (raw['allocations']! as List<Object?>))
            _draftFromJson(draft! as Map<String, Object?>),
        ],
      );

  static AllocationDraft _draftFromJson(Map<String, Object?> raw) =>
      AllocationDraft(
        categoryId: raw['categoryId']! as int,
        amountCents: raw['amountCents']! as int,
      );

  static ReviewQueueEntry _entryFromString(String raw) {
    final separator = raw.indexOf(':');
    return ReviewQueueEntry(
      bucket: ReviewBucket.parse(raw.substring(0, separator)),
      transactionId: int.parse(raw.substring(separator + 1)),
    );
  }
}
