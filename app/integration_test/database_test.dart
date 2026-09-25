import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:younum/core/time/statistics_time.dart';
import 'package:younum/data/db/sqflite_ledger_store.dart';
import 'package:younum/data/db/younum_schema.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/allocation.dart';
import 'package:younum/domain/models/import_records.dart';
import 'package:younum/domain/models/ledger_transaction.dart';
import 'package:younum/domain/models/review_session_record.dart';
import 'package:younum/domain/models/year_month.dart';
import 'package:younum/domain/repositories/import_workflow.dart';
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
  ///
  /// [path] 缺省用 setUp 建好的那一份；迁移用例需要指向自己造的老库。
  Future<Database> openRaw([String? path]) => databaseFactory.openDatabase(
    path ?? databasePath,
    options: OpenDatabaseOptions(
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    ),
  );

  /// 统计某个表的行数。
  Future<int> countOf(Database db, String table) async {
    final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM $table');
    return rows.first['n']! as int;
  }

  /// 某个表的列名。用来证明迁移真的加上了列，而不只是版本号变了。
  Future<List<String>> columnNamesOf(Database db, String table) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return <String>[for (final row in rows) row['name']! as String];
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

  group('分类落库（指南 3.5.8 / 14.3）', () {
    test('新建分类与图标改动，重开数据库仍然在', () async {
      final repository = _repositoryFor(store);

      final created = await repository.createCategory(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        name: '养花',
        iconKey: 'leaf',
      );
      expect(created, isA<CategorySaved>(), reason: '$created');
      final categoryId = (created as CategorySaved).category.id;
      expect(
        await repository.setCategoryIcon(
          ledgerId: DemoLedgerSeed.demoLedgerId,
          categoryId: categoryId,
          iconKey: 'coffee',
        ),
        isA<CategorySaved>(),
      );

      // 关掉再按同一份数据库打开 —— 这就是「重启之后还在」。
      await store.close();
      store = SqfliteLedgerStore(databasePath: databasePath);

      final categories = await store.categories(
        ledgerId: DemoLedgerSeed.demoLedgerId,
      );
      final saved = categories.firstWhere(
        (category) => category.name == '养花',
      );
      expect(saved.id, categoryId, reason: 'ID 必须稳定，否则历史分配会对不上');
      expect(saved.iconKey, 'coffee');
      expect(saved.isBuiltin, isFalse);
      expect(saved.archived, isFalse);
    });

    test('同级重名被拒，数据库里不多一条', () async {
      final repository = _repositoryFor(store);
      final before = await countOf(await openRaw(), 'category');

      final result = await repository.createCategory(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        name: '餐饮',
        iconKey: 'leaf',
      );

      expect(result, isA<CategoryRejected>());
      expect(await countOf(await openRaw(), 'category'), before);
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

      await db.delete(
        'txn',
        where: 'id = ?',
        whereArgs: <Object?>[transactionId],
      );
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
      await expectLater(db.insert('review_session', values), throwsA(anything));
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
        items: <AllocationDraft>[
          AllocationDraft(
            categoryId: SeedCategoryIds.food,
            amountCents: stale.amountCents,
          ),
        ],
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
      final action = await db.query(
        'review_action',
        columns: <String>['undo_state'],
      );
      expect(action.first['undo_state'], 'USED');
    });

    test('拆分把一笔写成多条分配，撤销后回到原来那一条', () async {
      final repository = _repositoryFor(store);
      final snapshot = await repository.loadSnapshot(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
      );
      final current = snapshot.current!;
      final originalCents = current.amountCents;

      // 先按单分类归类，再拆成两项 —— 两条路走的是同一个写入口。
      await repository.confirm(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
        transactionId: current.id,
        categoryId: SeedCategoryIds.food,
      );
      final half = originalCents ~/ 2;

      final outcome = await repository.split(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
        transactionId: current.id,
        items: <AllocationDraft>[
          AllocationDraft(categoryId: SeedCategoryIds.food, amountCents: half),
          AllocationDraft(
            categoryId: SeedCategoryIds.shopping,
            amountCents: originalCents - half,
          ),
        ],
      );
      expect(outcome, isA<ReviewSucceeded>(), reason: '$outcome');

      final db = await openRaw();
      final rows = await db.query('allocation');
      expect(rows, hasLength(2), reason: '旧的单条分配必须被替换，而不是叠加');
      expect(
        rows.fold<int>(0, (sum, row) => sum + (row['amount_cents']! as int)),
        originalCents,
        reason: '指南 3.5：合计精确等于原始金额',
      );

      // 撤销要把拆分整体还原成原样那一条。
      final undone = await repository.undo(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
      );
      expect(undone, isA<ReviewSucceeded>());
      final restored = await db.query('allocation');
      expect(restored, hasLength(1));
      expect(restored.single['amount_cents'], originalCents);
      expect(restored.single['category_id'], SeedCategoryIds.food);
    });

    test('详情页保存：备注与用途一次写完，撤销把两者都还原', () async {
      final repository = _repositoryFor(store);
      final snapshot = await repository.loadSnapshot(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
      );
      final current = snapshot.current!;

      // 先造一个「原来就有备注、也归过类」的状态。
      var outcome = await repository.saveDetails(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
        transactionId: current.id,
        note: '原来的备注',
        categoryId: SeedCategoryIds.food,
      );
      expect(outcome, isA<ReviewSucceeded>(), reason: '$outcome');

      final db = await openRaw();
      Future<Map<String, Object?>> row() async => (await db.query(
        'txn',
        where: 'id = ?',
        whereArgs: <Object?>[current.id],
      )).single;

      expect((await row())['note'], '原来的备注');
      expect(await countOf(db, 'allocation'), 1);

      // 改备注 + 换用途。
      outcome = await repository.saveDetails(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
        transactionId: current.id,
        note: '改过的备注',
        categoryId: SeedCategoryIds.shopping,
      );
      expect(outcome, isA<ReviewSucceeded>(), reason: '$outcome');
      expect((await row())['note'], '改过的备注');
      final allocations = await db.query('allocation');
      expect(allocations, hasLength(1), reason: '换用途是替换，不是叠加');
      expect(allocations.single['category_id'], SeedCategoryIds.shopping);

      // 撤销：备注与用途都要回来。
      final undone = await repository.undo(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
      );
      expect(undone, isA<ReviewSucceeded>());
      expect((await row())['note'], '原来的备注', reason: '撤销不能把备注弄丢');
      expect((await db.query('allocation')).single['category_id'], SeedCategoryIds.food);
    });

    test('改交易性质：离开消费时删掉旧分配，撤销再还回来', () async {
      final repository = _repositoryFor(store);
      final snapshot = await repository.loadSnapshot(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
      );
      final current = snapshot.current!;

      // 先当消费归类，制造一条旧分配。
      await repository.confirm(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
        transactionId: current.id,
        categoryId: SeedCategoryIds.food,
      );
      final db = await openRaw();
      expect(await countOf(db, 'allocation'), 1);

      final outcome = await repository.setNature(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
        transactionId: current.id,
        nature: TransactionNature.excluded,
        excludeReason: '朋友还我的钱',
      );
      expect(outcome, isA<ReviewSucceeded>(), reason: '$outcome');

      Future<Map<String, Object?>> row() async => (await db.query(
        'txn',
        where: 'id = ?',
        whereArgs: <Object?>[current.id],
      )).single;

      var updated = await row();
      expect(updated['nature'], 'EXCLUDED');
      expect(updated['exclude_reason'], '朋友还我的钱');
      expect(updated['review_status'], 'RESOLVED');
      expect(await countOf(db, 'allocation'), 0, reason: '离开消费时旧分配要删掉');

      // 撤销要把性质、原因与分配一起还回来。
      final undone = await repository.undo(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
      );
      expect(undone, isA<ReviewSucceeded>());

      updated = await row();
      expect(updated['nature'], 'EXPENSE');
      expect(
        updated['exclude_reason'],
        isNull,
        reason: '原因要跟着性质一起还原，否则会留下一条对不上的说明',
      );
      expect(await countOf(db, 'allocation'), 1);
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

    test('收到退款：一次写入改性质并建关联，同一笔不能关联两次', () async {
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
          merchant: '退款 · 某笔消费',
          amountCents: 1000,
          nature: TransactionNature.refund,
          reviewStatus: ReviewStatus.pending,
          sourceTransactionId: 'refund-link-1',
        ),
      );

      final outcome = await repository.linkRefundAndResolve(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
        refundTransactionId: refundId,
        originalTransactionId: current.id,
      );
      expect(outcome, isA<ReviewSucceeded>(), reason: '$outcome');

      final db = await openRaw();
      final refundRow = (await db.query(
        'txn',
        where: 'id = ?',
        whereArgs: <Object?>[refundId],
      )).single;
      expect(refundRow['nature'], 'REFUND');
      expect(refundRow['review_status'], 'RESOLVED');
      expect(refundRow['exclude_reason'], isNull, reason: '退款不该留着排除原因');

      final link = (await db.query('refund_link')).single;
      expect(link['refund_transaction_id'], refundId);
      expect(link['original_transaction_id'], current.id);
      expect(link['amount_cents'], 1000);
      expect(await countOf(db, 'allocation'), 1, reason: '退款自己不该留下分配');

      // 同一笔退款再来一次：必须被拒，而且不能多出一条连接。
      final again = await repository.linkRefundAndResolve(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
        refundTransactionId: refundId,
        originalTransactionId: current.id,
      );
      expect(again, isA<ReviewRejected>());
      expect(await countOf(db, 'refund_link'), 1);
    });

    test('跨月退款：原消费在上个月也能关联并落库', () async {
      final repository = _repositoryFor(store);
      final snapshot = await repository.loadSnapshot(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
      );
      final current = snapshot.current!;
      final august = YearMonth(DemoLedgerSeed.month.year, 8);

      // 上个月的一笔已分类消费 —— 它的分配在另一个月里。
      final augustId = await store.insertTransaction(
        (await store.transactionById(current.id))!.copyWith(
          id: LedgerTransaction.idUnassigned,
          occurredAtMs: StatisticsTime.epochMsFor(august.year, 8, 20, 12),
          merchant: '上个月的消费',
          sourceTransactionId: 'aug-cross-month-1',
        ),
      );
      expect(
        await repository.confirm(
          ledgerId: DemoLedgerSeed.demoLedgerId,
          month: august,
          transactionId: augustId,
          categoryId: SeedCategoryIds.food,
        ),
        isA<ReviewSucceeded>(),
      );

      final refundId = await store.insertTransaction(
        (await store.transactionById(current.id))!.copyWith(
          id: LedgerTransaction.idUnassigned,
          merchant: '退款 · 上个月的消费',
          amountCents: 1000,
          nature: TransactionNature.refund,
          reviewStatus: ReviewStatus.pending,
          sourceTransactionId: 'refund-cross-month-1',
        ),
      );

      final outcome = await repository.linkRefundAndResolve(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
        refundTransactionId: refundId,
        originalTransactionId: augustId,
      );
      expect(
        outcome,
        isA<ReviewSucceeded>(),
        reason: '指南 3.5.4：跨月退款要能关联到上个月的消费，$outcome',
      );

      final db = await openRaw();
      final link = (await db.query('refund_link')).single;
      expect(link['original_transaction_id'], augustId);
      final augustRow = (await db.query(
        'txn',
        where: 'id = ?',
        whereArgs: <Object?>[augustId],
      )).single;
      expect(augustRow['nature'], 'EXPENSE', reason: '原消费的性质不该被改');
    });

    test('解除关联：连接真的删掉，退款回到待核对', () async {
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
          merchant: '退款 · 某笔消费',
          amountCents: 1000,
          nature: TransactionNature.refund,
          reviewStatus: ReviewStatus.pending,
          sourceTransactionId: 'refund-unlink-1',
        ),
      );
      expect(
        await repository.linkRefundAndResolve(
          ledgerId: DemoLedgerSeed.demoLedgerId,
          month: DemoLedgerSeed.month,
          refundTransactionId: refundId,
          originalTransactionId: current.id,
        ),
        isA<ReviewSucceeded>(),
      );

      final outcome = await repository.unlinkRefund(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        refundTransactionId: refundId,
      );
      expect(outcome, isA<ReviewSucceeded>(), reason: '$outcome');

      final db = await openRaw();
      expect(await countOf(db, 'refund_link'), 0);
      final row = (await db.query(
        'txn',
        where: 'id = ?',
        whereArgs: <Object?>[refundId],
      )).single;
      expect(row['nature'], TransactionNature.unknown.storageValue);
      expect(row['review_status'], ReviewStatus.pending.storageValue);
    });

    test('拆分消费的退款分配合计正确才落库，解除关联会连带删掉', () async {
      final repository = _repositoryFor(store);
      final snapshot = await repository.loadSnapshot(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
      );
      final original = snapshot.current!;

      // 把这笔拆成两项（1400 + 1400）。
      expect(
        await repository.split(
          ledgerId: DemoLedgerSeed.demoLedgerId,
          month: DemoLedgerSeed.month,
          transactionId: original.id,
          items: <AllocationDraft>[
            const AllocationDraft(
              categoryId: SeedCategoryIds.food,
              amountCents: 1400,
            ),
            const AllocationDraft(
              categoryId: SeedCategoryIds.shopping,
              amountCents: 1400,
            ),
          ],
        ),
        isA<ReviewSucceeded>(),
      );
      final items = (await store.dataset(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        months: <YearMonth>{DemoLedgerSeed.month},
      )).allocationsOf(original.id);
      expect(items, hasLength(2));

      final refundId = await store.insertTransaction(
        (await store.transactionById(original.id))!.copyWith(
          id: LedgerTransaction.idUnassigned,
          merchant: '退款 · 拆分过的消费',
          amountCents: 1000,
          nature: TransactionNature.refund,
          reviewStatus: ReviewStatus.pending,
          sourceTransactionId: 'refund-split-1',
        ),
      );

      // 合计不对：必须被拒，且 `refund_allocation` 一行都不写。
      final mismatch = await repository.linkRefundAndResolve(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
        refundTransactionId: refundId,
        originalTransactionId: original.id,
        allocations: <RefundAllocationDraft>[
          RefundAllocationDraft(
            originalAllocationId: items.first.id,
            amountCents: 600,
          ),
          RefundAllocationDraft(
            originalAllocationId: items.last.id,
            amountCents: 300,
          ),
        ],
      );
      expect(mismatch, isA<ReviewRejected>());
      expect(await countOf(await openRaw(), 'refund_allocation'), 0);

      // 合计对上：连接 + 两条分配一起落库。
      final ok = await repository.linkRefundAndResolve(
        ledgerId: DemoLedgerSeed.demoLedgerId,
        month: DemoLedgerSeed.month,
        refundTransactionId: refundId,
        originalTransactionId: original.id,
        allocations: <RefundAllocationDraft>[
          RefundAllocationDraft(
            originalAllocationId: items.first.id,
            amountCents: 600,
          ),
          RefundAllocationDraft(
            originalAllocationId: items.last.id,
            amountCents: 400,
          ),
        ],
      );
      expect(ok, isA<ReviewSucceeded>(), reason: '$ok');

      final db = await openRaw();
      final saved = await db.query('refund_allocation');
      expect(saved, hasLength(2));
      expect(
        saved.fold<int>(0, (sum, row) => sum + (row['amount_cents']! as int)),
        1000,
      );

      // 解除关联：`refund_allocation` 挂在连接上（ON DELETE CASCADE），
      // 连接没了它自己就没 —— 真机证明这条级联真的生效。
      expect(
        await repository.unlinkRefund(
          ledgerId: DemoLedgerSeed.demoLedgerId,
          refundTransactionId: refundId,
        ),
        isA<ReviewSucceeded>(),
      );
      expect(await countOf(await openRaw(), 'refund_allocation'), 0);
    });
  });

  group('结构迁移', () {
    test('v1 库升到当前版本：既有数据一条不少', () async {
      // 先手工造一个「老版本」的库：只建 v1 的表，版本号写着 1。
      //
      // ⚠️ 必须用**另一个**路径。setUp 里已经按当前版本建好了 databasePath，
      // 在那儿再按 version: 1 打开会被当成降级直接报错。
      final legacyPath = '$databasePath.v1';
      addTearDown(() => databaseFactory.deleteDatabase(legacyPath));
      final legacy = await databaseFactory.openDatabase(
        legacyPath,
        options: OpenDatabaseOptions(
          version: 1,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          onCreate: (db, _) async {
            for (final statement in younumSchemaV1) {
              await db.execute(statement);
            }
          },
        ),
      );

      // 往老库里塞一份「用户存有账单」的状态：账本、分类、交易、分配、
      // 整理进度、月范围确认都放上，迁移后再逐项核对。
      await legacy.insert('ledger', <String, Object?>{
        'id': DemoLedgerSeed.realLedgerId,
        'name': '我的账本',
        'is_demo': 0,
        'created_at_ms': 1000,
        'currency': 'CNY',
        'time_zone': 'Asia/Shanghai',
      });
      await legacy.insert('category', <String, Object?>{
        'id': SeedCategoryIds.food,
        'parent_id': null,
        'name': '餐饮',
        'icon_type': 'BUILTIN',
        'icon_key': 'food',
        'sort_order': 0,
        'is_builtin': 1,
        'archived': 0,
      });
      await legacy.insert('txn', <String, Object?>{
        // 刻意用一个大号码：演示账单占掉了 1..6，
        // 用 1 的话会被 initialize() 的 OR IGNORE 忽略掉，
        // 让「数据还在吗」这个断言变得看运气。
        'id': 9001,
        'ledger_id': DemoLedgerSeed.realLedgerId,
        'occurred_at_ms': 5000,
        'time_zone': 'Asia/Shanghai',
        'amount_cents': 2800,
        'merchant': '老王牛肉面',
        'nature': 'EXPENSE',
        'review_status': 'RESOLVED',
        'source_namespace': 'wechat',
        'source_account': '零钱',
        'source_transaction_id': '4200001',
        'dedupe_key': 'wechat\u0000零钱\u00004200001',
        'currency': 'CNY',
        'version': 1,
      });
      await legacy.insert('allocation', <String, Object?>{
        'transaction_id': 9001,
        'category_id': SeedCategoryIds.food,
        'amount_cents': 2800,
      });
      await legacy.insert('review_session', <String, Object?>{
        'ledger_id': DemoLedgerSeed.realLedgerId,
        'year': 2026,
        'month': 9,
        'sort_mode': 'TIME_DESC',
        'updated_at_ms': 6000,
      });
      await legacy.insert('month_review', <String, Object?>{
        'ledger_id': DemoLedgerSeed.realLedgerId,
        'year': 2026,
        'month': 9,
        'coverage_confirmed': 1,
        'confirmed_at_ms': 7000,
      });

      expect(await countOf(legacy, 'txn'), 1);
      final versionBefore = await legacy.getVersion();
      expect(versionBefore, 1, reason: '这一份确实是老版本的库');
      await legacy.close();

      // 现在按正常路径打开：sqflite 看到版本 1 < 2，走 onUpgrade。
      final upgraded = SqfliteLedgerStore(databasePath: legacyPath);
      await upgraded.initialize();
      addTearDown(upgraded.close);

      final db = await openRaw(legacyPath);
      expect(await db.getVersion(), younumSchemaVersion);

      // 新表建出来了。
      expect(await countOf(db, 'import_batch'), 0);
      expect(await countOf(db, 'import_row'), 0);
      expect(await countOf(db, 'transaction_origin'), 0);

      // 迁移链是跑完整条，不是只跑一步：v1 升上来也该有 v3 加的列。
      expect(await columnNamesOf(db, 'import_batch'), contains('source_uri'));

      // 老数据一条不少。
      //
      // 期望是 7 而不是 1：升级后会跑一遍 initialize()，
      // 把 6 笔演示账单写进演示账本，而真实账本里我们那笔必须原封不动。
      expect(await countOf(db, 'txn'), 7, reason: '6 笔演示 + 1 笔旧数据');
      expect(await countOf(db, 'allocation'), 1);
      expect(await countOf(db, 'month_review'), 1);
      expect(await countOf(db, 'review_session'), 1);

      // 用户改过的账本不会被种子覆盖（initialize 用的是 OR IGNORE）。
      final ledgers = await db.query(
        'ledger',
        where: 'id = ?',
        whereArgs: <Object?>[DemoLedgerSeed.realLedgerId],
      );
      expect(ledgers.first['name'], '我的账本', reason: '用户改过的名字不能被种子盖掉');

      // 按 id 取，不能 .first —— 演示账单也在同一张表里。
      final txns = await db.query(
        'txn',
        where: 'id = ?',
        whereArgs: <Object?>[9001],
      );
      expect(txns, hasLength(1), reason: '旧数据必须原封不动还在');
      expect(txns.first['merchant'], '老王牛肉面');
      expect(txns.first['amount_cents'], 2800);
      expect(txns.first['review_status'], 'RESOLVED');
      expect(txns.first['source_transaction_id'], '4200001');
      expect(
        txns.first['dedupe_key'],
        'wechat\u0000零钱\u00004200001',
        reason: '同源去重键是历史数据的一部分，升级不能让后续导入重复入账',
      );

      // 分类行数会因为种子变多，所以按内容核对而不是数行数。
      final categories = await db.query(
        'category',
        where: 'id = ?',
        whereArgs: <Object?>[SeedCategoryIds.food],
      );
      expect(categories.first['name'], '餐饮');

      final monthReview = await db.query('month_review');
      expect(
        monthReview.first['coverage_confirmed'],
        1,
        reason: '「本月范围完整」这个用户确认不能因为升级丢掉',
      );

      // 升级后业务照旧能跑：数据集里该笔消费还在，分类名也取得出来。
      final dataset = await upgraded.dataset(
        ledgerId: DemoLedgerSeed.realLedgerId,
      );
      expect(dataset.transactions, hasLength(1));
      expect(dataset.categoryName(SeedCategoryIds.food), '餐饮');
      expect(
        await upgraded.coverageConfirmed(
          ledgerId: DemoLedgerSeed.realLedgerId,
          month: YearMonth(2026, 9),
        ),
        isTrue,
      );
    });

    test('全新安装也是「先建 v1 再跑迁移链」，新表同样存在', () async {
      // 这条用例看着多余，但它证明的是：上面那条升级用例走到的代码路径，
      // 与全新安装走的是同一段。否则「升级路径从没被执行过」的坑会一直埋着。
      final db = await openRaw();
      expect(await db.getVersion(), younumSchemaVersion);
      for (final table in <String>[
        'import_batch',
        'import_row',
        'transaction_origin',
      ]) {
        final found = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          <Object?>[table],
        );
        expect(found, hasLength(1), reason: '$table 应当存在');
      }
    });

    test('来源绑定与批次的外键约束真的生效', () async {
      final db = await openRaw();

      // 不存在的事务 ID —— 必须被外键拦住，否则来源表会慢慢积累孤儿记录。
      await expectLater(
        db.insert('transaction_origin', <String, Object?>{
          'transaction_id': 999999,
          'batch_id': 1,
          'row_number': 1,
        }),
        throwsA(isA<DatabaseException>()),
      );

      // 批次行数不存在于文件里时，阶段值必须落在枚举之内。
      await expectLater(
        db.insert('import_batch', <String, Object?>{
          'ledger_id': DemoLedgerSeed.demoLedgerId,
          'source_namespace': 'wechat',
          'file_name': 'x.csv',
          'file_hash': 'h',
          'file_size_bytes': 10,
          'encoding': 'UTF-8',
          'delimiter': ',',
          'stage': 'NOT_A_STAGE',
          'started_at_ms': 1,
        }),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('同一批次里的同一行不能被绑定两次', () async {
      final db = await openRaw();
      await db.insert('import_batch', <String, Object?>{
        'ledger_id': DemoLedgerSeed.demoLedgerId,
        'source_namespace': 'wechat',
        'file_name': '2026-09.csv',
        'file_hash': 'abc',
        'file_size_bytes': 10,
        'encoding': 'UTF-8',
        'delimiter': ',',
        'stage': 'COMMITTED',
        'started_at_ms': 1000,
      });
      final batchId = await db.query('import_batch', limit: 1);
      final id = batchId.first['id']! as int;

      // 直接用种子数据里已有的交易，既不重复列清单一遍，
      // 也顺带证明演示账本真的落库了。
      final existing = await db.query('txn', columns: <String>['id'], limit: 1);
      final txId = existing.first['id']! as int;

      Future<int> bind() => db.insert('transaction_origin', <String, Object?>{
        'transaction_id': txId,
        'batch_id': id,
        'row_number': 8,
      });

      await bind();
      await expectLater(
        bind(),
        throwsA(isA<DatabaseException>()),
        reason:
            '提交过程重试时不能把同一行绑两次，否则引用计数会虚高、'
            '撤回批次时该删的交易删不掉',
      );
    });
  });
  group('结构迁移 v2 → v3', () {
    test('v2 库里的导入批次不会因为加列而丢', () async {
      // 造一个 v2 的库：v1 的 DDL + v2 的导入三表，版本号写着 2。
      final legacyPath = '$databasePath.v2';
      addTearDown(() => databaseFactory.deleteDatabase(legacyPath));
      final legacy = await databaseFactory.openDatabase(
        legacyPath,
        options: OpenDatabaseOptions(
          version: 2,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          onCreate: (db, _) async {
            for (final statement in <String>[
              ...younumSchemaV1,
              ...younumSchemaV2,
            ]) {
              await db.execute(statement);
            }
          },
        ),
      );

      await legacy.insert('ledger', <String, Object?>{
        'id': DemoLedgerSeed.realLedgerId,
        'name': '我的账本',
        'is_demo': 0,
        'created_at_ms': 1000,
        'currency': 'CNY',
        'time_zone': 'Asia/Shanghai',
      });
      // v2 的批次表还没有 source_uri 这一列。
      expect(
        await columnNamesOf(legacy, 'import_batch'),
        isNot(contains('source_uri')),
        reason: '前提：这确实是一份 v2 的库',
      );
      await legacy.insert('import_batch', <String, Object?>{
        'ledger_id': DemoLedgerSeed.realLedgerId,
        'source_namespace': 'wechat',
        'file_name': '2026-09.csv',
        'file_hash': 'abc',
        'file_size_bytes': 1024,
        'encoding': 'UTF-8',
        'delimiter': ',',
        'stage': 'COMMITTED',
        'total_rows': 10,
        'new_count': 8,
        'amount_cents': 12345,
        'started_at_ms': 5000,
        'committed_at_ms': 6000,
      });
      await legacy.insert('import_row', <String, Object?>{
        'batch_id': 1,
        'row_number': 3,
        'merchant': '老王牛肉面',
        'amount_cents': 2800,
        'direction': 'EXPENSE',
        'status': 'IMPORTED',
        'included': 1,
      });

      expect(await legacy.getVersion(), 2);
      await legacy.close();

      final upgraded = SqfliteLedgerStore(databasePath: legacyPath);
      await upgraded.initialize();
      addTearDown(upgraded.close);

      final db = await openRaw(legacyPath);
      expect(await db.getVersion(), younumSchemaVersion);
      expect(await columnNamesOf(db, 'import_batch'), contains('source_uri'));

      // 老批次原封不动，新列是 NULL。
      final batches = await db.query('import_batch');
      expect(batches, hasLength(1));
      expect(batches.first['file_name'], '2026-09.csv');
      expect(batches.first['new_count'], 8);
      expect(batches.first['amount_cents'], 12345);
      expect(
        batches.first['source_uri'],
        isNull,
        reason: '老批次本来就没记过来源 URI，不能假装它能重新解析',
      );
      expect(await countOf(db, 'import_row'), 1);

      // 升级后新批次能正常写入并读回来。
      final store = upgraded;
      final batchId = await store.insertImportBatch(
        batch: ImportBatch(
          id: ImportBatch.idUnassigned,
          ledgerId: DemoLedgerSeed.realLedgerId,
          sourceNamespace: 'alipay',
          fileName: '2026-10.csv',
          fileHash: 'def',
          fileSizeBytes: 2048,
          encoding: 'GBK',
          delimiter: ',',
          stage: ImportStage.reviewRequired,
          startedAtMs: 7000,
          sourceUri: 'content://downloads/42',
        ),
        rows: const <ImportRow>[],
      );

      final loaded = await store.importBatches(
        ledgerId: DemoLedgerSeed.realLedgerId,
      );
      final stored = loaded.firstWhere((batch) => batch.id == batchId);
      expect(stored.sourceUri, 'content://downloads/42');
      expect(stored.encoding, 'GBK');
      expect(loaded, hasLength(2), reason: '老批次还在');
    });
  });

  group('导入的暂存、提交与撤回', () {
    const real = DemoLedgerSeed.realLedgerId;
    final billedMonth = YearMonth(2026, 9);

    final billBytes = Uint8List.fromList(
      utf8.encode('''
微信支付账单明细
交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号,商户单号,备注
2026-09-23 14:26:00,商户消费,老王牛肉面,牛肉面,支出,¥28.00,零钱,支付成功,4200001,M1001,/
2026-09-24 09:02:11,商户消费,地铁公司,地铁,支出,¥5.00,零钱,支付成功,4200002,M1002,/
2026-09-26 11:05:00,商户消费,某网店,杯子,支出,¥32.50,零钱,已全额退款,4200004,M1004,退款
共 3 笔,合计,-33.00,,,,
'''),
    );

    Future<ImportStaged> stageImport(
      LedgerRepository repository,
      String name,
    ) async {
      final result = await repository.stageImport(
        ledgerId: real,
        fileName: name,
        bytes: billBytes,
        sourceNamespace: 'wechat',
        sourceAccount: '零钱',
      );
      expect(result, isA<ImportStaged>(), reason: '$result');
      return result as ImportStaged;
    }

    test('暂存时不进正式账，提交后才在一个事务里写进去', () async {
      final repository = _repositoryFor(store);
      final staged = await stageImport(repository, 'wechat.csv');
      expect(staged.preview.freshCount, 2);
      expect(staged.preview.invalidCount, 1, reason: '退款那行');

      // 这是整个导入设计的地基：没确认的数据不能进首页金额。
      expect(
        (await repository.dataset(ledgerId: real)).transactions,
        isEmpty,
        reason: '真实账本仍是空的',
      );

      final committed = await repository.commitImport(
        ledgerId: real,
        batchId: staged.preview.batchId,
      );
      expect(committed.count, 2);
      expect(committed.amountCents, 2800 + 500);

      final db = await openRaw();
      expect(await countOf(db, 'txn'), 8, reason: '6 笔演示 + 2 笔导入');
      expect(await countOf(db, 'transaction_origin'), 2);
      expect(await countOf(db, 'import_row'), 3, reason: '2 笔入账 + 1 笔退款');

      final batches = await db.query('import_batch');
      expect(batches.first['stage'], 'COMMITTED');
      expect(batches.first['new_count'], 2);
      expect(batches.first['amount_cents'], 3300);

      // 同一份文件再导一次，交易不再增加（同源键顶住了）。
      expect(
        (await repository.dataset(ledgerId: real)).transactions,
        hasLength(2),
      );
    });

    test('撤回只删不再被任何批次引用的交易', () async {
      final repository = _repositoryFor(store);
      final first = await stageImport(repository, 'wechat.csv');
      await repository.commitImport(
        ledgerId: real,
        batchId: first.preview.batchId,
      );

      // 第二份账单：同一批单号，但用户在核对页上决定「仍然导入」其中一笔。
      // 这一步在真机 SQL 上是关键 —— 如果提交时又插一条交易，
      // 会直接撞 (ledger_id, dedupe_key) 唯一索引，整批失败。
      final second = await stageImport(repository, 'wechat-again.csv');
      expect(second.preview.duplicateCount, 2);
      final rows = await repository.importRows(batchId: second.preview.batchId);
      final duplicate = rows.firstWhere(
        (row) => row.status == ImportRowStatus.duplicate,
      );
      await repository.updateImportRows(<ImportRow>[
        duplicate.copyWith(included: true, status: ImportRowStatus.newRow),
      ]);
      await repository.commitImport(
        ledgerId: real,
        batchId: second.preview.batchId,
      );

      final db = await openRaw();
      expect(await countOf(db, 'txn'), 8, reason: '复用已有那一笔，不再插新交易');
      expect(await countOf(db, 'transaction_origin'), 3, reason: '那一笔有两处来源');

      final reverted = await repository.revertImport(
        batchId: first.preview.batchId,
      );
      expect(reverted.deletedCount, 1);
      expect(reverted.sharedTransactionIds, hasLength(1));
      expect(
        (await repository.dataset(ledgerId: real)).transactions,
        hasLength(1),
        reason: '被第二份引用的那笔必须留下，否则用户会凭空少一笔消费',
      );
    });

    test('撤回不动用户已经分过类的交易', () async {
      final repository = _repositoryFor(store);
      final staged = await stageImport(repository, 'wechat.csv');
      await repository.commitImport(
        ledgerId: real,
        batchId: staged.preview.batchId,
      );

      final dataset = await repository.dataset(ledgerId: real);
      final classified = dataset.transactions.firstWhere(
        (transaction) => transaction.merchant == '老王牛肉面',
      );
      await repository.confirm(
        ledgerId: real,
        month: billedMonth,
        transactionId: classified.id,
        categoryId: SeedCategoryIds.food,
      );

      final reverted = await repository.revertImport(
        batchId: staged.preview.batchId,
      );
      expect(reverted.deletedCount, 1);
      expect(reverted.editedTransactionIds, <int>[classified.id]);

      final db = await openRaw();
      expect(await countOf(db, 'allocation'), 1, reason: '用户做的分类不能因为撤回导入而消失');
      expect(await countOf(db, 'txn'), 7, reason: '6 笔演示 + 1 笔保留下来的');
    });

    test('撤回原消费时先解除退款关联，不会被外键挡住', () async {
      // 指南 3.5.7。`refund_link.original_transaction_id` 是 ON DELETE RESTRICT：
      // 不先断连接，整次撤回会直接报外键错误 —— 用户看到的就是「撤不回去」。
      final repository = _repositoryFor(store);
      final staged = await stageImport(repository, 'wechat.csv');
      await repository.commitImport(
        ledgerId: real,
        batchId: staged.preview.batchId,
      );

      final dataset = await repository.dataset(ledgerId: real);
      final original = dataset.transactions.firstWhere(
        (transaction) => transaction.merchant == '老王牛肉面',
      );
      final refundId = await store.insertTransaction(
        original.copyWith(
          id: LedgerTransaction.idUnassigned,
          merchant: '退款 · 老王牛肉面',
          nature: TransactionNature.income,
          reviewStatus: ReviewStatus.pending,
          sourceTransactionId: 'refund-revert-1',
        ),
      );
      expect(
        // 用低层 `linkRefund` 建连接：这样原消费还是「没动过」的，
        // 撤回时它才会进入删除名单 —— 正是要验证的那条路（指南 3.5.7）。
        // 界面那条路径要求原消费先有用途，而有用途的记录撤回时会被保留。
        await repository.linkRefund(
          ledgerId: real,
          month: billedMonth,
          refundTransactionId: refundId,
          originalTransactionId: original.id,
          amountCents: original.amountCents,
        ),
        isA<ReviewSucceeded>(),
      );

      final reverted = await repository.revertImport(
        batchId: staged.preview.batchId,
      );
      expect(reverted.deletedTransactionIds, contains(original.id));
      expect(reverted.unlinkedRefundIds, <int>[refundId]);

      final db = await openRaw();
      expect(await countOf(db, 'refund_link'), 0);
      final rows = await db.query(
        'txn',
        where: 'id = ?',
        whereArgs: <Object?>[refundId],
      );
      expect(rows, hasLength(1), reason: '退款不能被连带删掉');
      expect(rows.single['nature'], TransactionNature.unknown.storageValue);
      expect(
        rows.single['review_status'],
        ReviewStatus.pending.storageValue,
        reason: '指南 3.5.7：恢复待核对',
      );
    });
  });
}

/// 让集成测试用同一套编排逻辑。
///
/// 这里刻意不导入界面层：数据库测试验证的是仓库 + SQL，不含 UI。
LedgerRepository _repositoryFor(SqfliteLedgerStore store) =>
    LedgerRepository(store);
