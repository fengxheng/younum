import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:younum/data/db/sqflite_ledger_store.dart';
import 'package:younum/data/db/younum_schema.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/ledger_transaction.dart';
import 'package:younum/domain/models/review_session_record.dart';
import 'package:younum/domain/models/year_month.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';

/// 数据库层测试，跑在**真实的 Android SQLite** 上。
///
/// 为什么必须放到真机：`flutter test` 跑在 Windows 的 Dart 虚拟机上，
/// 用 SQLite 需要一个本机并不存在的 `sqlite3.dll`。
/// 更关键的是 —— 外键、唯一约束、`ON DELETE RESTRICT` 这类事情
/// **只有真实数据库能证明**，内存实现里的绿灯不算数。
///
/// 运行方式（需要已连接设备）：
///
/// ```powershell
/// flutter test integration_test/database_test.dart -d <device-id>
/// ```
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late String databasePath;
  late SqfliteLedgerStore store;
  var sequence = 0;

  setUp(() async {
    // 每次用独立的数据库文件，绝不碰应用真正使用的那一份。
    final directory = await getDatabasesPath();
    databasePath = p.join(
      directory,
      'younum_test_${DateTime.now().microsecondsSinceEpoch}_${sequence++}.db',
    );
    store = SqfliteLedgerStore(databasePath: databasePath);
    await store.initialize();
  });

  tearDown(() async {
    await store.close();
    await databaseFactory.deleteDatabase(databasePath);
  });

  /// 直接开一条原始连接，用来执行测试专用的 SQL。
  Future<Database> openRaw() => databaseFactory.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        ),
      );

  /// 统计某个表的行数。
  Future<int> countOf(Database db, String table) async {
    final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM $table');
    return rows.first['n']! as int;
  }

  group('结构与版本', () {
    test('建库后版本号等于当前结构版本', () async {
      final db = await openRaw();
      final rows = await db.rawQuery('PRAGMA user_version');
      expect(rows.first.values.first, younumSchemaVersion);
    });

    test('十张表与关键索引都建好了', () async {
      final db = await openRaw();
      final tables = <String>{
        for (final row in await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table'",
        ))
          row['name']! as String,
      };
      expect(
        tables,
        containsAll(<String>[
          'ledger',
          'category',
          'txn',
          'allocation',
          'refund_link',
          'refund_allocation',
          'review_session',
          'review_queue_item',
          'review_action',
          'month_review',
        ]),
      );

      final indexes = <String>{
        for (final row in await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'index'",
        ))
          row['name']! as String,
      };
      expect(
        indexes,
        containsAll(<String>[
          'idx_txn_source',
          'idx_allocation_tx_category',
          'idx_refund_link_refund',
          'idx_category_parent_name',
          'idx_review_session_unique',
        ]),
      );
    });

    test('initialize 幂等：重复调用不会产生重复账本或分类', () async {
      await store.initialize();
      await store.initialize();

      final db = await openRaw();
      expect(await countOf(db, 'ledger'), 2);
      expect(await countOf(db, 'txn'), 6);
      expect(await countOf(db, 'category'), 15);
    });

    test('重新打开同一份数据库，数据还在（不是每次重建）', () async {
      await store.close();
      store = SqfliteLedgerStore(databasePath: databasePath);

      final ledgers = await store.ledgers();
      expect(ledgers, hasLength(2));
      final dataset = await store.dataset(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        months: <YearMonth>{DemoLedgerSeed.month},
      );
      expect(dataset.transactions, hasLength(6));
    });
  });

  group('外键真的在生效', () {
    test('外键开关已打开：关联指向不存在的交易会失败', () async {
      // 这一条同时证明了 `PRAGMA foreign_keys = ON` 确实执行了 ——
      // 不写那句，下面这个插入会被默默接受。
      await expectLater(
        store.insertRefundLink(
          refundTransactionId: 9999,
          originalTransactionId: DemoLedgerSeed.transactionIdAt(0),
          amountCents: 100,
        ),
        throwsA(anything),
      );
    });

    test('分配不能指向不存在的分类', () async {
      final db = await openRaw();
      await expectLater(
        db.insert('allocation', <String, Object?>{
          'transaction_id': DemoLedgerSeed.transactionIdAt(0),
          'category_id': 9999,
          'amount_cents': 2800,
        }),
        throwsA(anything),
      );
    });

    test('删除被分配引用的分类会被拒绝（RESTRICT）', () async {
      final db = await openRaw();
      await db.insert('allocation', <String, Object?>{
        'transaction_id': DemoLedgerSeed.transactionIdAt(0),
        'category_id': SeedCategoryIds.food,
        'amount_cents': 2800,
      });

      // 指南 3.5.8：分类删除默认归档，历史引用必须继续有效。
      // 数据库这一层就不允许把还在被引用的分类直接删掉。
      await expectLater(
        db.delete(
          'category',
          where: 'id = ?',
          whereArgs: <Object?>[SeedCategoryIds.food],
        ),
        throwsA(anything),
      );
    });

    test('删除交易会级联删掉它的分配', () async {
      final db = await openRaw();
      final transactionId = DemoLedgerSeed.transactionIdAt(0);
      await db.insert('allocation', <String, Object?>{
        'transaction_id': transactionId,
        'category_id': SeedCategoryIds.food,
        'amount_cents': 2800,
      });
      expect(await countOf(db, 'allocation'), 1);

      await db.delete('txn', where: 'id = ?', whereArgs: <Object?>[transactionId]);
      expect(await countOf(db, 'allocation'), 0);
    });
  });

  group('唯一约束挡住重复数据', () {
    test('同源同 ID 的交易不能写入两次', () async {
      final seeded = DemoLedgerSeed.baselineTransactions().first;

      await expectLater(
        store.insertTransaction(
          seeded.copyWith(id: LedgerTransaction.idUnassigned),
        ),
        throwsA(anything),
      );

      final dataset = await store.dataset(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        months: <YearMonth>{DemoLedgerSeed.month},
      );
      expect(dataset.transactions, hasLength(6), reason: '不能多出一笔重复交易');
    });

    test('同一笔消费不能对同一分类拆出两项', () async {
      final db = await openRaw();
      final transactionId = DemoLedgerSeed.transactionIdAt(0);
      await db.insert('allocation', <String, Object?>{
        'transaction_id': transactionId,
        'category_id': SeedCategoryIds.food,
        'amount_cents': 1400,
      });

      await expectLater(
        db.insert('allocation', <String, Object?>{
          'transaction_id': transactionId,
          'category_id': SeedCategoryIds.food,
          'amount_cents': 1400,
        }),
        throwsA(anything),
      );
    });

    test('同一笔退款只能关联一次（否则会重复抵扣）', () async {
      final refundId = await store.insertTransaction(
        DemoLedgerSeed.baselineTransactions().first.copyWith(
          id: LedgerTransaction.idUnassigned,
          merchant: '优衣库退款',
          nature: TransactionNature.refund,
          sourceTransactionId: 'refund-uniqlo-1',
        ),
      );
      final originalId = DemoLedgerSeed.transactionIdAt(1);

      await store.insertRefundLink(
        refundTransactionId: refundId,
        originalTransactionId: originalId,
        amountCents: 10000,
      );

      await expectLater(
        store.insertRefundLink(
          refundTransactionId: refundId,
          originalTransactionId: originalId,
          amountCents: 10000,
        ),
        throwsA(anything),
      );
    });

    test('同级分类不能重名，但不同层级可以重名', () async {
      final db = await openRaw();
      await expectLater(
        db.insert('category', <String, Object?>{
          'name': '餐饮',
          'icon_type': 'BUILTIN',
          'icon_key': 'food',
          'sort_order': 99,
          'is_builtin': 0,
        }),
        throwsA(anything),
      );

      // 一级分类与它下面的细分可以同名 —— 这正是用
      // `ifnull(parent_id, -1)` 表达式索引的原因：
      // 直接 UNIQUE(parent_id, name) 会把两个 NULL 当成互不相等，
      // 一级分类就可以重名了。
      final ok = await db.insert('category', <String, Object?>{
        'parent_id': SeedCategoryIds.food,
        'name': '餐饮',
        'icon_type': 'BUILTIN',
        'icon_key': 'food',
        'sort_order': 99,
        'is_builtin': 0,
      });
      expect(ok, greaterThan(0));
    });

    test('同一账本同一月份只能有一条整理会话', () async {
      final db = await openRaw();
      final values = <String, Object?>{
        'ledger_id': DemoLedgerSeed.demoLedgerId,
        'year': 2026,
        'month': 9,
        'sort_mode': 'TIME_DESC',
        'updated_at_ms': 1,
      };
      await db.insert('review_session', values);
      await expectLater(
        db.insert('review_session', values),
        throwsA(anything),
      );
    });
  });

  group('CHECK 约束', () {
    test('金额不能是负数', () async {
      final db = await openRaw();
      await expectLater(
        db.insert('txn', <String, Object?>{
          'ledger_id': DemoLedgerSeed.demoLedgerId,
          'occurred_at_ms': 1,
          'time_zone': 'Asia/Shanghai',
          'amount_cents': -1,
          'currency': 'CNY',
          'merchant': '负数',
          'nature': 'EXPENSE',
          'review_status': 'PENDING',
          'version': 1,
        }),
        throwsA(anything),
      );
    });

    test('排除统计必须保留原因', () async {
      final db = await openRaw();
      await expectLater(
        db.insert('txn', <String, Object?>{
          'ledger_id': DemoLedgerSeed.demoLedgerId,
          'occurred_at_ms': 1,
          'time_zone': 'Asia/Shanghai',
          'amount_cents': 100,
          'currency': 'CNY',
          'merchant': '排除但没有原因',
          'nature': 'EXCLUDED',
          'review_status': 'RESOLVED',
          'version': 1,
        }),
        throwsA(anything),
      );
    });

    test('未知的交易性质会被拒绝，不会静默存进去', () async {
      final db = await openRaw();
      await expectLater(
        db.insert('txn', <String, Object?>{
          'ledger_id': DemoLedgerSeed.demoLedgerId,
          'occurred_at_ms': 1,
          'time_zone': 'Asia/Shanghai',
          'amount_cents': 100,
          'currency': 'CNY',
          'merchant': '未知性质',
          'nature': 'SOMETHING_NEW',
          'review_status': 'PENDING',
          'version': 1,
        }),
        throwsA(anything),
      );
    });

    test('退款不能关联到自己', () async {
      final db = await openRaw();
      final transactionId = DemoLedgerSeed.transactionIdAt(0);
      await expectLater(
        db.insert('refund_link', <String, Object?>{
          'refund_transaction_id': transactionId,
          'original_transaction_id': transactionId,
          'amount_cents': 100,
        }),
        throwsA(anything),
      );
    });
  });

  group('整理的写入是原子的', () {
    test('版本过期的写入请求被拒绝，且什么都不写', () async {
      final transactionId = DemoLedgerSeed.transactionIdAt(0);
      final stale = (await store.transactionById(transactionId))!;

      // 模拟「别的路径先改了这笔」：版本前进到 2。
      final updated = await store.updateTransaction(
        transaction: stale.copyWith(version: stale.version + 1),
        expectedVersion: stale.version,
      );
      expect(updated, isTrue);

      // 现在用过期的 before（版本仍是 1）去写。
      final ok = await store.resolveTransaction(
        before: stale,
        categoryId: SeedCategoryIds.food,
        session: ReviewSessionRecord(
          ledgerId: DemoLedgerSeed.demoLedgerId,
          month: DemoLedgerSeed.month,
          entries: const <ReviewQueueEntry>[],
          updatedAtMs: 1,
        ),
        undo: UndoRecord(
          type: ReviewActionType.resolve,
          label: '过期请求',
          ledgerId: DemoLedgerSeed.demoLedgerId,
          month: DemoLedgerSeed.month,
          targets: <UndoTarget>[
            UndoTarget(
              transactionId: transactionId,
              beforeVersion: stale.version,
              beforeStatus: stale.reviewStatus,
              beforeNature: stale.nature,
            ),
          ],
          beforeEntries: const <ReviewQueueEntry>[],
          createdAtMs: 1,
        ),
      );
      expect(ok, isFalse);

      // 关键：不能留下「状态变了但分配没写进去」这种半个结果。
      final db = await openRaw();
      expect(await countOf(db, 'allocation'), 0);
      expect(await countOf(db, 'review_action'), 0);
      final rows = await db.query(
        'txn',
        columns: <String>['review_status', 'version'],
        where: 'id = ?',
        whereArgs: <Object?>[transactionId],
      );
      expect(rows.first['review_status'], 'PENDING');
      expect(rows.first['version'], 2, reason: '被拒绝的写入不应该改动版本号');
    });

    test('正常确认会同时写状态、分配、会话与撤销日志', () async {
      final repository = _repositoryFor(store);
      final snapshot = await repository.loadSnapshot(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
      );
      final current = snapshot.current!;

      final outcome = await repository.confirm(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
        transactionId: current.id,
        categoryId: SeedCategoryIds.food,
      );
      expect(outcome, isA<ReviewSucceeded>());

      final db = await openRaw();
      expect(await countOf(db, 'allocation'), 1);
      expect(await countOf(db, 'review_session'), 1);
      expect(await countOf(db, 'review_queue_item'), 5);
      expect(await countOf(db, 'review_action'), 1);

      // 撤销要把四样东西一起恢复。
      final undone = await repository.undo(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
      );
      expect(undone, isA<ReviewSucceeded>());
      expect(await countOf(db, 'allocation'), 0);
      expect(await countOf(db, 'review_queue_item'), 6);
      final action =
          await db.query('review_action', columns: <String>['undo_state']);
      expect(action.first['undo_state'], 'USED');
    });

    test('有关联退款时拒绝撤销原消费，避免退款去抵扣不存在的消费', () async {
      final repository = _repositoryFor(store);
      final snapshot = await repository.loadSnapshot(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
      );
      final current = snapshot.current!;
      await repository.confirm(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
        transactionId: current.id,
        categoryId: SeedCategoryIds.food,
      );

      final refundId = await store.insertTransaction(
        (await store.transactionById(current.id))!.copyWith(
          id: LedgerTransaction.idUnassigned,
          merchant: '退款',
          nature: TransactionNature.refund,
          sourceTransactionId: 'refund-atomic-1',
        ),
      );
      final linked = await repository.linkRefund(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
        refundTransactionId: refundId,
        originalTransactionId: current.id,
        amountCents: 1000,
      );
      expect(linked, isA<ReviewSucceeded>());

      // 撤销必须被拒绝并说明原因，而不是先撤销再留下一个指向空分配的退款。
      final undone = await repository.undo(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
      );
      expect(undone, isA<ReviewRejected>());
      expect((undone as ReviewRejected).message, contains('解除退款关联'));

      final db = await openRaw();
      expect(await countOf(db, 'allocation'), 1, reason: '原分配必须还在');
      expect(await countOf(db, 'refund_link'), 1, reason: '退款关联必须还在');
    });
  });
}

/// 让集成测试用同一套编排逻辑。
///
/// 这里刻意不导入界面层：数据库测试验证的是仓库 + SQL，不含 UI。
LedgerRepository _repositoryFor(SqfliteLedgerStore store) =>
    LedgerRepository(store);
