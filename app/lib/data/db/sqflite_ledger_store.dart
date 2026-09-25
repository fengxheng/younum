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
import '../../domain/models/import_records.dart';
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

    final path =
        _customPath ?? p.join(await _factory.getDatabasesPath(), fileName);
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
        await txn.insert('ledger', <String, Object?>{
          'id': ledger.id,
          'name': ledger.name,
          'is_demo': ledger.isDemo ? 1 : 0,
          'currency': ledger.currency,
          'time_zone': ledger.timeZone,
          'created_at_ms': ledger.createdAtMs,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
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
    final rows = await db.query(
      'category',
      orderBy: 'parent_id ASC, sort_order ASC, id ASC',
    );
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
    final baseIds = <int>[
      for (final transaction in transactions) transaction.id,
    ];

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
      links.addAll(<RefundLink>[
        for (final row in linkRows) _refundLinkFrom(row),
      ]);
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
    required List<AllocationDraft> items,
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
        <Object?>[
          ReviewStatus.resolved.storageValue,
          before.id,
          before.version,
        ],
      );
      if (updated != 1) {
        conflicted = true;
        return;
      }
      // 拆分就是「旧分配整体换成一组新分配」，所以先清后写。
      await txn.delete(
        'allocation',
        where: 'transaction_id = ?',
        whereArgs: <Object?>[before.id],
      );
      for (final item in items) {
        await txn.insert('allocation', <String, Object?>{
          'transaction_id': before.id,
          'category_id': item.categoryId,
          'amount_cents': item.amountCents,
        });
      }
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
        <Object?>[
          ReviewStatus.deferred.storageValue,
          before.id,
          before.version,
        ],
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
  Future<bool> linkRefundAndResolve({
    required LedgerTransaction before,
    required int originalTransactionId,
    required int amountCents,
    required ReviewSessionRecord session,
  }) async {
    final db = await _db;
    var conflicted = false;
    await db.transaction((txn) async {
      final updated = await txn.rawUpdate(
        '''
        UPDATE txn
        SET nature = ?, review_status = ?, exclude_reason = NULL,
            version = version + 1
        WHERE id = ? AND version = ?
        ''',
        <Object?>[
          TransactionNature.refund.storageValue,
          ReviewStatus.resolved.storageValue,
          before.id,
          before.version,
        ],
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
      // 「同一笔退款只能关联一次」由唯一索引兑底；上层已经先校验过，
      // 这里只是最后一道。
      await txn.insert('refund_link', <String, Object?>{
        'refund_transaction_id': before.id,
        'original_transaction_id': originalTransactionId,
        'amount_cents': amountCents,
      });
      await _writeSession(txn, session);
    });
    return !conflicted;
  }

  @override
  Future<RefundLink?> refundLinkOf(int refundTransactionId) async {
    final db = await _db;
    final rows = await db.query(
      'refund_link',
      where: 'refund_transaction_id = ?',
      whereArgs: <Object?>[refundTransactionId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _refundLinkFrom(rows.first);
  }

  @override
  Future<bool> unlinkRefund({
    required int refundTransactionId,
    required ReviewSessionRecord session,
  }) async {
    final db = await _db;
    var unlinked = false;
    await db.transaction((txn) async {
      unlinked = await _unlinkRefundIn(txn, refundTransactionId);
      if (!unlinked) return;
      await _writeSession(txn, session);
    });
    return unlinked;
  }

  /// 解除关联，不管会话 —— 调用方决定要不要存会话。
  ///
  /// `refund_allocation` 挂在连接上（`ON DELETE CASCADE`），连接删了它自己就没；
  /// `txn` 那一行改回「待核对 + 不知道这是什么」。
  Future<bool> _unlinkRefundIn(
    DatabaseExecutor txn,
    int refundTransactionId,
  ) async {
    final rows = await txn.query(
      'refund_link',
      columns: <String>['id'],
      where: 'refund_transaction_id = ?',
      whereArgs: <Object?>[refundTransactionId],
      limit: 1,
    );
    if (rows.isEmpty) return false;

    await txn.delete(
      'refund_link',
      where: 'refund_transaction_id = ?',
      whereArgs: <Object?>[refundTransactionId],
    );
    await txn.rawUpdate(
      '''
      UPDATE txn
      SET nature = ?, review_status = ?, exclude_reason = NULL,
          version = version + 1
      WHERE id = ?
      ''',
      <Object?>[
        TransactionNature.unknown.storageValue,
        ReviewStatus.pending.storageValue,
        refundTransactionId,
      ],
    );
    return true;
  }

  @override
  Future<bool> saveDetails({
    required LedgerTransaction before,
    required String? note,
    required List<AllocationDraft>? items,
    required ReviewSessionRecord session,
    required UndoRecord undo,
  }) async {
    final db = await _db;
    var conflicted = false;
    await db.transaction((txn) async {
      // 用途没变就不动状态，只改备注。
      final assignments = <String>['note = ?', 'version = version + 1'];
      final args = <Object?>[note];
      if (items != null) {
        assignments.add('review_status = ?');
        args.add(ReviewStatus.resolved.storageValue);
      }
      args
        ..add(before.id)
        ..add(before.version);

      final updated = await txn.rawUpdate(
        'UPDATE txn SET ${assignments.join(', ')} WHERE id = ? AND version = ?',
        args,
      );
      if (updated != 1) {
        conflicted = true;
        return;
      }
      if (items != null) {
        await txn.delete(
          'allocation',
          where: 'transaction_id = ?',
          whereArgs: <Object?>[before.id],
        );
        for (final item in items) {
          await txn.insert('allocation', <String, Object?>{
            'transaction_id': before.id,
            'category_id': item.categoryId,
            'amount_cents': item.amountCents,
          });
        }
      }
      await _writeSession(txn, session);
      await _appendAction(txn, session, undo);
    });
    return !conflicted;
  }

  @override
  Future<bool> setTransactionNature({
    required LedgerTransaction before,
    required TransactionNature nature,
    required String? excludeReason,
    required ReviewSessionRecord session,
    required UndoRecord undo,
  }) async {
    final db = await _db;
    var conflicted = false;
    await db.transaction((txn) async {
      final updated = await txn.rawUpdate(
        '''
        UPDATE txn
        SET nature = ?, exclude_reason = ?, review_status = ?,
            version = version + 1
        WHERE id = ? AND version = ?
        ''',
        <Object?>[
          nature.storageValue,
          excludeReason,
          ReviewStatus.resolved.storageValue,
          before.id,
          before.version,
        ],
      );
      if (updated != 1) {
        conflicted = true;
        return;
      }
      if (!nature.isExpense) {
        await txn.delete(
          'allocation',
          where: 'transaction_id = ?',
          whereArgs: <Object?>[before.id],
        );
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
  Future<Map<String, int>> transactionIdsByDedupeKey({
    required int ledgerId,
    required List<String> dedupeKeys,
  }) async {
    if (dedupeKeys.isEmpty) return const <String, int>{};
    final db = await _db;
    final unique = dedupeKeys.toSet().toList();
    final found = <String, int>{};
    // 自己分块，而不是复用 _queryIn：那个辅助函数的 ids 是 List<int>，
    // 在 SQL 里拼字符串键的占位符并不合适。
    const chunkSize = 200;
    for (var start = 0; start < unique.length; start += chunkSize) {
      final chunk = unique.sublist(
        start,
        start + chunkSize > unique.length ? unique.length : start + chunkSize,
      );
      final placeholders = List<String>.filled(chunk.length, '?').join(', ');
      final rows = await db.rawQuery(
        'SELECT id, dedupe_key FROM txn '
        'WHERE ledger_id = ? AND dedupe_key IN ($placeholders)',
        <Object?>[ledgerId, ...chunk],
      );
      for (final row in rows) {
        final key = row['dedupe_key'] as String?;
        if (key != null) found[key] = row['id']! as int;
      }
    }
    return found;
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
  Future<Set<YearMonth>> confirmedMonths({required int ledgerId}) async {
    final db = await _db;
    final rows = await db.query(
      'month_review',
      columns: <String>['year', 'month'],
      where: 'ledger_id = ? AND coverage_confirmed = 1',
      whereArgs: <Object?>[ledgerId],
    );
    return <YearMonth>{
      for (final row in rows)
        YearMonth(row['year']! as int, row['month']! as int),
    };
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
      <Object?>[
        ledgerId,
        month.year,
        month.month,
        ReviewActionState.available.storageValue,
      ],
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
          UPDATE txn
          SET review_status = ?, nature = ?, exclude_reason = ?, note = ?,
              version = ?
          WHERE id = ?
          ''',
          <Object?>[
            target.beforeStatus.storageValue,
            target.beforeNature.storageValue,
            target.beforeExcludeReason,
            target.beforeNote,
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
      <String, Object?>{
        'undo_state': ReviewActionState.invalidated.storageValue,
      },
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
      await executor.insert('review_queue_item', <String, Object?>{
        'session_id': sessionId,
        'position': position,
        'transaction_id': entry.transactionId,
        'bucket': entry.bucket.storageValue,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
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
      whereArgs: <Object?>[
        session.ledgerId,
        session.month.year,
        session.month.month,
      ],
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

  // ---------------------------------------------------------------------------
  // 导入
  // ---------------------------------------------------------------------------

  @override
  Future<int> insertImportBatch({
    required ImportBatch batch,
    required List<ImportRow> rows,
  }) async {
    final db = await _db;
    return db.transaction<int>((txn) async {
      final batchId = await txn.insert(
        'import_batch',
        _importBatchValues(batch),
      );
      for (final row in rows) {
        await txn.insert('import_row', _importRowValues(row, batchId: batchId));
      }
      return batchId;
    });
  }

  @override
  Future<void> updateImportBatch(ImportBatch batch) async {
    final db = await _db;
    await db.update(
      'import_batch',
      _importBatchValues(batch),
      where: 'id = ?',
      whereArgs: <Object?>[batch.id],
    );
  }

  @override
  Future<void> deleteImportBatch(int batchId) async {
    final db = await _db;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'import_batch',
        columns: <String>['stage', 'reverted_at_ms'],
        where: 'id = ?',
        whereArgs: <Object?>[batchId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final committed = ImportStage.parse(rows.first['stage']! as String)
          .isCommitted;
      final reverted = rows.first['reverted_at_ms'] != null;
      if (committed && !reverted) {
        // 提交过的批次不能这样删掉：交易会失去来源记录，
        // 撤回时就再也判断不出「还有没有别处引用」了。
        // 但**已撤回**的批次名下已经没有交易，可以放心删。
        throw StateError('已提交的批次不能直接删除，请先撤回');
      }
      await txn.delete(
        'transaction_origin',
        where: 'batch_id = ?',
        whereArgs: <Object?>[batchId],
      );
      await txn.delete(
        'import_row',
        where: 'batch_id = ?',
        whereArgs: <Object?>[batchId],
      );
      await txn.delete(
        'import_batch',
        where: 'id = ?',
        whereArgs: <Object?>[batchId],
      );
    });
  }

  @override
  Future<List<ImportBatch>> importBatches({required int ledgerId}) async {
    final db = await _db;
    final rows = await db.query(
      'import_batch',
      where: 'ledger_id = ?',
      whereArgs: <Object?>[ledgerId],
      orderBy: 'id DESC',
    );
    return <ImportBatch>[for (final row in rows) _importBatchFrom(row)];
  }

  @override
  Future<List<ImportRow>> importRows({required int batchId}) async {
    final db = await _db;
    final rows = await db.query(
      'import_row',
      where: 'batch_id = ?',
      whereArgs: <Object?>[batchId],
      orderBy: 'row_number ASC',
    );
    return <ImportRow>[for (final row in rows) _importRowFrom(row)];
  }

  @override
  Future<void> updateImportRows(List<ImportRow> rows) async {
    if (rows.isEmpty) return;
    final db = await _db;
    await db.transaction((txn) async {
      for (final row in rows) {
        await txn.update(
          'import_row',
          <String, Object?>{
            'status': row.status.storageValue,
            'included': row.included ? 1 : 0,
            'transaction_id': row.transactionId,
          },
          where: 'id = ?',
          whereArgs: <Object?>[row.id],
        );
      }
    });
  }

  @override
  Future<List<int>> commitImport({
    required int batchId,
    required List<({ImportRow row, LedgerTransaction transaction})> entries,
    required int nowMs,
    required int totalRows,
    required int duplicateCount,
    required int invalidCount,
    required int amountCents,
  }) async {
    final db = await _db;
    return db.transaction<List<int>>((txn) async {
      final batches = await txn.query(
        'import_batch',
        columns: <String>['stage', 'reverted_at_ms'],
        where: 'id = ?',
        whereArgs: <Object?>[batchId],
        limit: 1,
      );
      if (batches.isEmpty) {
        throw StateError('批次 $batchId 不存在');
      }
      final committed = ImportStage.parse(batches.first['stage']! as String)
          .isCommitted;
      final reverted = batches.first['reverted_at_ms'] != null;
      // 已撤回的批次可以再提交一次：那是用户主动退回后又想装回来。
      if (committed && !reverted) {
        // 幂等：重复提交不能再写一遍交易，否则首页金额直接翻倍。
        throw StateError('批次 $batchId 已经提交过');
      }

      final written = <int>[];
      for (final entry in entries) {
        final int transactionId;
        if (entry.transaction.isPersisted) {
          // 库里已经有了同一笔（同源键命中）：只新增来源绑定。
          // 再插一条会直接撞 (ledger_id, dedupe_key) 唯一索引，整批失败。
          transactionId = entry.transaction.id;
        } else {
          final values = _transactionValues(
            entry.transaction,
            includeId: false,
          );
          // 只作为「最早发现这笔的批次」留个痕。撤回判定一律走
          // transaction_origin —— 见 DECISIONS 第 30 节。
          values['import_batch_id'] = batchId;
          transactionId = await txn.insert('txn', values);
        }

        await txn.insert('transaction_origin', <String, Object?>{
          'transaction_id': transactionId,
          'batch_id': batchId,
          'row_number': entry.row.rowNumber,
        });

        if (entry.row.id != ImportRow.idUnassigned) {
          await txn.update(
            'import_row',
            <String, Object?>{
              'status': ImportRowStatus.imported.storageValue,
              'transaction_id': transactionId,
            },
            where: 'id = ?',
            whereArgs: <Object?>[entry.row.id],
          );
        }
        written.add(transactionId);
      }

      await txn.update(
        'import_batch',
        <String, Object?>{
          'stage': ImportStage.committed.storageValue,
          'committed_at_ms': nowMs,
          'reverted_at_ms': null,
          'total_rows': totalRows,
          'new_count': written.length,
          'duplicate_count': duplicateCount,
          'invalid_count': invalidCount,
          'amount_cents': amountCents,
        },
        where: 'id = ?',
        whereArgs: <Object?>[batchId],
      );
      return written;
    });
  }

  @override
  Future<ImportRevert> revertImport({
    required int batchId,
    required int nowMs,
    bool dryRun = false,
  }) async {
    final db = await _db;
    return db.transaction<ImportRevert>((txn) async {
      final origins = await txn.query(
        'transaction_origin',
        columns: <String>['transaction_id'],
        where: 'batch_id = ?',
        whereArgs: <Object?>[batchId],
      );
      final owned = <int>{
        for (final row in origins) row['transaction_id']! as int,
      };

      final deleted = <int>[];
      final shared = <int>[];
      final edited = <int>[];
      final unlinked = <int>[];
      for (final transactionId in owned) {
        final others = await txn.query(
          'transaction_origin',
          columns: <String>['id'],
          where: 'transaction_id = ? AND batch_id <> ?',
          whereArgs: <Object?>[transactionId, batchId],
          limit: 1,
        );
        if (others.isNotEmpty) {
          shared.add(transactionId);
          continue;
        }

        final allocations = await txn.query(
          'allocation',
          columns: <String>['id'],
          where: 'transaction_id = ?',
          whereArgs: <Object?>[transactionId],
          limit: 1,
        );
        final rows = await txn.query(
          'txn',
          columns: <String>['version', 'review_status'],
          where: 'id = ?',
          whereArgs: <Object?>[transactionId],
          limit: 1,
        );
        final touched =
            allocations.isNotEmpty ||
            (rows.isNotEmpty &&
                ((rows.first['version']! as int) > 1 ||
                    rows.first['review_status'] !=
                        ReviewStatus.pending.storageValue));
        if (touched) {
          edited.add(transactionId);
          continue;
        }

        deleted.add(transactionId);

        // 指南 3.5.7：原消费要删，但不要连带删掉它的退款 ——
        // 退款可能是另一份账单导进来的。先解除关联（否则
        // `refund_link.original_transaction_id` 的 ON DELETE RESTRICT
        // 会让整次撤回失败），把退款恢复待核对，再删原消费。
        final linked = await txn.query(
          'refund_link',
          columns: <String>['refund_transaction_id'],
          where: 'original_transaction_id = ?',
          whereArgs: <Object?>[transactionId],
        );
        final linkedRefunds = <int>[
          for (final row in linked) row['refund_transaction_id']! as int,
        ];
        unlinked.addAll(linkedRefunds);
        if (dryRun) continue;

        for (final refundId in linkedRefunds) {
          await _unlinkRefundIn(txn, refundId);
        }
        // allocation 那边有 ON DELETE CASCADE，但只可能是空的（上面已经挡过）。
        await txn.delete(
          'txn',
          where: 'id = ?',
          whereArgs: <Object?>[transactionId],
        );
      }

      // dry run 到此为止：只回答「会发生什么」，不改任何东西。
      if (dryRun) {
        return ImportRevert(
          deletedTransactionIds: deleted,
          sharedTransactionIds: shared,
          editedTransactionIds: edited,
          unlinkedRefundIds: unlinked,
        );
      }

      await txn.delete(
        'transaction_origin',
        where: 'batch_id = ?',
        whereArgs: <Object?>[batchId],
      );
      // 暂存行回到「可再次提交」的样子。不清 transaction_id 的话，
      // 界面会显示一个已经不存在的交易 ID。
      await txn.update(
        'import_row',
        <String, Object?>{
          'transaction_id': null,
          'status': ImportRowStatus.newRow.storageValue,
        },
        where: 'batch_id = ? AND status = ?',
        whereArgs: <Object?>[batchId, ImportRowStatus.imported.storageValue],
      );
      await txn.update(
        'import_batch',
        <String, Object?>{'reverted_at_ms': nowMs},
        where: 'id = ?',
        whereArgs: <Object?>[batchId],
      );

      return ImportRevert(
        deletedTransactionIds: deleted,
        sharedTransactionIds: shared,
        editedTransactionIds: edited,
        unlinkedRefundIds: unlinked,
      );
    });
  }

  static Map<String, Object?> _importBatchValues(ImportBatch batch) =>
      <String, Object?>{
        if (batch.id != ImportBatch.idUnassigned) 'id': batch.id,
        'ledger_id': batch.ledgerId,
        'source_namespace': batch.sourceNamespace,
        'file_name': batch.fileName,
        'file_hash': batch.fileHash,
        'file_size_bytes': batch.fileSizeBytes,
        'encoding': batch.encoding,
        'delimiter': batch.delimiter,
        'source_uri': batch.sourceUri,
        'range_start_ms': batch.rangeStartMs,
        'range_end_ms': batch.rangeEndMs,
        'stage': batch.stage.storageValue,
        'total_rows': batch.totalRows,
        'new_count': batch.newCount,
        'duplicate_count': batch.duplicateCount,
        'invalid_count': batch.invalidCount,
        'amount_cents': batch.amountCents,
        'started_at_ms': batch.startedAtMs,
        'committed_at_ms': batch.committedAtMs,
        'reverted_at_ms': batch.revertedAtMs,
      };

  static Map<String, Object?> _importRowValues(
    ImportRow row, {
    required int batchId,
  }) => <String, Object?>{
    if (row.id != ImportRow.idUnassigned) 'id': row.id,
    'batch_id': batchId,
    'row_number': row.rowNumber,
    'raw_text': row.rawText,
    'occurred_at_ms': row.occurredAtMs,
    'amount_cents': row.amountCents,
    'direction': row.direction?.storageValue,
    'merchant': row.merchant,
    'status': row.status.storageValue,
    'issue': row.issue,
    'dedupe_key': row.dedupeKey,
    'included': row.included ? 1 : 0,
    'transaction_id': row.transactionId,
  };

  static ImportBatch _importBatchFrom(Map<String, Object?> row) => ImportBatch(
    id: row['id']! as int,
    ledgerId: row['ledger_id']! as int,
    sourceNamespace: row['source_namespace']! as String,
    fileName: row['file_name']! as String,
    fileHash: row['file_hash']! as String,
    fileSizeBytes: row['file_size_bytes']! as int,
    encoding: row['encoding']! as String,
    delimiter: row['delimiter']! as String,
    stage: ImportStage.parse(row['stage']! as String),
    startedAtMs: row['started_at_ms']! as int,
    sourceUri: row['source_uri'] as String?,
    rangeStartMs: row['range_start_ms'] as int?,
    rangeEndMs: row['range_end_ms'] as int?,
    totalRows: row['total_rows']! as int,
    newCount: row['new_count']! as int,
    duplicateCount: row['duplicate_count']! as int,
    invalidCount: row['invalid_count']! as int,
    amountCents: row['amount_cents']! as int,
    committedAtMs: row['committed_at_ms'] as int?,
    revertedAtMs: row['reverted_at_ms'] as int?,
  );

  static ImportRow _importRowFrom(Map<String, Object?> row) => ImportRow(
    id: row['id']! as int,
    batchId: row['batch_id']! as int,
    rowNumber: row['row_number']! as int,
    status: ImportRowStatus.parse(row['status']! as String),
    rawText: row['raw_text'] as String?,
    occurredAtMs: row['occurred_at_ms'] as int?,
    amountCents: row['amount_cents'] as int?,
    direction: row['direction'] == null
        ? null
        : ImportDirection.parse(row['direction']! as String),
    merchant: row['merchant'] as String?,
    issue: row['issue'] as String?,
    dedupeKey: row['dedupe_key'] as String?,
    included: (row['included']! as int) == 1,
    transactionId: row['transaction_id'] as int?,
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
  }) => <String, Object?>{
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
          'excludeReason': target.beforeExcludeReason,
          'note': target.beforeNote,
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
    final decoded =
        jsonDecode(row['before_json']! as String) as Map<String, Object?>;
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
    // 旧日志里没有这个键，缺失就是 null（当时的实现也没有原因）。
    beforeExcludeReason: raw['excludeReason'] as String?,
    beforeNote: raw['note'] as String?,
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
