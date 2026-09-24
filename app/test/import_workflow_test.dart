import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/import_records.dart';
import 'package:younum/domain/models/ledger_transaction.dart';
import 'package:younum/domain/models/review_session_record.dart';
import 'package:younum/domain/models/year_month.dart';
import 'package:younum/domain/repositories/import_workflow.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/domain/rules/import_rules.dart';

/// 一份仿微信导出：6 行说明 + 表头 + 3 笔成功消费 + 1 笔退款 + 合计行。
const String _bill = '''
微信支付账单明细
微信昵称：[有数测试]
起始时间：[2026-09-01 00:00:00] 终止时间：[2026-09-30 23:59:59]
导出类型：[全部]
导出时间：[2026-10-01 09:12:03]
----------------------微信支付账单明细列表--------------------
交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号,商户单号,备注
2026-09-23 14:26:00,商户消费,老王牛肉面,牛肉面,支出,¥28.00,零钱,支付成功,4200001,M1001,/
2026-09-24 09:02:11,商户消费,地铁公司,地铁,支出,¥5.00,零钱,支付成功,4200002,M1002,/
2026-09-27 08:00:00,商户消费,早餐铺,包子,支出,¥9.00,零钱,支付成功,4200005,M1005,/
2026-09-26 11:05:00,商户消费,某网店,杯子,支出,¥32.50,零钱,已全额退款,4200004,M1004,退款
共 4 笔,合计,-42.50,,,,
''';

/// 没有单号列的账单，用来验证「疑似重复」这一级。
const String _noIdBill = '''
交易时间,交易对方,收/支,金额(元)
2026-09-23 12:00:00,便利店,支出,12.00
2026-09-23 12:00:00,便利店,支出,12.00
''';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;

  const real = DemoLedgerSeed.realLedgerId;
  final month = YearMonth(2026, 9);

  setUp(() async {
    store = InMemoryLedgerStore();
    repository = LedgerRepository(store);
    await repository.initialize();
    // 真实账本一开始是空的（演示账本才有初始数据）。
    expect(
      (await repository.dataset(ledgerId: real)).transactions,
      isEmpty,
      reason: '前提：真实账本为空',
    );
  });

  Future<ImportStaged> stage({
    String text = _bill,
    String file = '2026-09.csv',
  }) async {
    final result = await repository.stageImport(
      ledgerId: real,
      fileName: file,
      bytes: _bytes(text),
      sourceNamespace: 'wechat',
      sourceAccount: '零钱',
    );
    expect(result, isA<ImportStaged>(), reason: '$result');
    return result as ImportStaged;
  }

  group('暂存', () {
    test('暂存只写暂存区，首页金额一分不动', () async {
      final staged = await stage();

      expect(staged.preview.freshCount, 3);
      expect(staged.preview.freshCents, 2800 + 500 + 900);
      expect(staged.preview.invalidCount, 1, reason: '退款那笔');
      expect(staged.preview.duplicateCount, 0);

      // 这一条是整个导入设计的地基：没确认的数据绝不能进正式账。
      final after = await repository.dataset(ledgerId: real);
      expect(after.transactions, isEmpty, reason: '暂存不得影响首页金额');

      final batches = await repository.importBatches(ledgerId: real);
      expect(batches, hasLength(1));
      expect(batches.first.stage, ImportStage.reviewRequired);
      expect(batches.first.fileName, '2026-09.csv');
      expect(batches.first.encoding, 'UTF-8');
      expect(batches.first.delimiter, ',');
    });

    test('暂存行带上行号与原始文本，便于回到原文件核对', () async {
      final staged = await stage();
      final rows = await repository.importRows(batchId: staged.preview.batchId);

      expect(rows, hasLength(4), reason: '3 笔成功 + 1 笔退款；说明行、表头与合计行不入暂存区');
      final first = rows.firstWhere((row) => row.rowNumber == 8);
      expect(first.merchant, '老王牛肉面');
      expect(first.amountCents, 2800);
      expect(first.direction, ImportDirection.expense);
      expect(first.included, isTrue);
      expect(first.rawText, contains('老王牛肉面'));

      final refund = rows.firstWhere((row) => row.rowNumber == 11);
      expect(refund.status, ImportRowStatus.invalid);
      expect(refund.included, isFalse, reason: '退款不进正式账');
      expect(refund.issue, contains('退款'));
    });

    test('表头认不出来时要求人工映射，并且什么都不落库', () async {
      final result = await repository.stageImport(
        ledgerId: real,
        fileName: 'unknown.csv',
        bytes: _bytes('a,b,c\n1,2,3\n'),
        sourceNamespace: 'wechat',
      );

      expect(result, isA<ImportMappingRequired>());
      final mapping = result as ImportMappingRequired;
      expect(mapping.missingFields, contains(ImportField.amount));
      expect(
        await repository.importBatches(ledgerId: real),
        isEmpty,
        reason: '还不知道怎么映射，就不该留下半份数据',
      );
    });

    test('空文件直接拒绝，并说明原因', () async {
      final result = await repository.stageImport(
        ledgerId: real,
        fileName: 'empty.csv',
        bytes: Uint8List(0),
        sourceNamespace: 'wechat',
      );

      expect(result, isA<ImportStageRejected>());
      expect((result as ImportStageRejected).message, contains('空'));
    });

    test('分不清编码时给出可操作的说明，而不是猜一份乱码', () async {
      // 一串无法构成合法 UTF-8、也不像 GBK 文本的字节。
      final result = await repository.stageImport(
        ledgerId: real,
        fileName: 'binary.csv',
        bytes: Uint8List.fromList(List<int>.generate(64, (i) => 0x81 + i % 2)),
        sourceNamespace: 'wechat',
      );

      expect(result, isA<ImportStageRejected>());
    });
  });

  group('提交', () {
    test('提交后才进正式账，金额与笔数对得上', () async {
      final staged = await stage();
      final committed = await repository.commitImport(
        ledgerId: real,
        batchId: staged.preview.batchId,
      );

      expect(committed.count, 3);
      expect(committed.amountCents, 2800 + 500 + 900);

      final dataset = await repository.dataset(ledgerId: real);
      expect(dataset.transactions, hasLength(3));
      for (final transaction in dataset.transactions) {
        expect(transaction.nature, TransactionNature.expense);
        expect(transaction.amountCents, greaterThan(0), reason: '存绝对值');
        expect(
          transaction.reviewStatus,
          ReviewStatus.pending,
          reason: '导入不等于归类，不能替用户把整理状态标成已完成',
        );
        expect(transaction.importBatchId, staged.preview.batchId);
      }
    });

    test('提交后批次变成已提交，暂存行指向真实的交易', () async {
      final staged = await stage();
      await repository.commitImport(
        ledgerId: real,
        batchId: staged.preview.batchId,
      );

      final batch = await repository.importBatch(
        ledgerId: real,
        batchId: staged.preview.batchId,
      );
      expect(batch!.stage, ImportStage.committed);
      expect(batch.newCount, 3);
      expect(batch.canRevert, isTrue);

      final rows = await repository.importRows(batchId: staged.preview.batchId);
      final imported = rows.where(
        (row) => row.status == ImportRowStatus.imported,
      );
      expect(imported, hasLength(3));
      for (final row in imported) {
        expect(row.transactionId, isNotNull);
      }
    });

    test('重复提交被拒绝，金额不会翻倍', () async {
      final staged = await stage();
      await repository.commitImport(
        ledgerId: real,
        batchId: staged.preview.batchId,
      );

      await expectLater(
        repository.commitImport(
          ledgerId: real,
          batchId: staged.preview.batchId,
        ),
        throwsA(isA<StateError>()),
        reason: '重试或双击不能把整批交易再写一遍',
      );

      final dataset = await repository.dataset(ledgerId: real);
      expect(dataset.transactions, hasLength(3));
    });

    test('同一份文件导入两次，第二次数出来的全是同源重复', () async {
      final first = await stage();
      await repository.commitImport(
        ledgerId: real,
        batchId: first.preview.batchId,
      );

      final second = await stage(file: '2026-09-再来一次.csv');
      expect(second.preview.freshCount, 0);
      expect(second.preview.duplicateCount, 3, reason: '3 笔都有稳定单号');
      expect(second.preview.isEmpty, isTrue);

      await repository.commitImport(
        ledgerId: real,
        batchId: second.preview.batchId,
      );
      final dataset = await repository.dataset(ledgerId: real);
      expect(dataset.transactions, hasLength(3), reason: '笔数不能翻倍');
    });

    test('没有单号时只能算疑似重复，默认仍然保留', () async {
      final staged = await stage(text: _noIdBill, file: 'no-id.csv');

      expect(staged.preview.suspectedCount, 1, reason: '第二行与第一行同商户同时间同金额');
      expect(staged.preview.freshCount, 2, reason: '但不能替用户删掉它');
      expect(staged.preview.needsReview, isTrue);

      await repository.commitImport(
        ledgerId: real,
        batchId: staged.preview.batchId,
      );
      final dataset = await repository.dataset(ledgerId: real);
      expect(
        dataset.transactions,
        hasLength(2),
        reason: '同一家店同一分钟买两次是真实存在的，宁可多留',
      );
    });

    test('用户取消勾选的行不会进入正式账', () async {
      final staged = await stage();
      final rows = await repository.importRows(batchId: staged.preview.batchId);
      final target = rows.firstWhere((row) => row.merchant == '地铁公司');

      await repository.updateImportRows(<ImportRow>[
        target.copyWith(included: false, status: ImportRowStatus.skipped),
      ]);
      final committed = await repository.commitImport(
        ledgerId: real,
        batchId: staged.preview.batchId,
      );

      expect(committed.count, 2);
      expect(committed.amountCents, 2800 + 900);
    });
  });

  group('撤回', () {
    test('撤回删掉只被这一个批次引用的交易', () async {
      final staged = await stage();
      await repository.commitImport(
        ledgerId: real,
        batchId: staged.preview.batchId,
      );

      final reverted = await repository.revertImport(
        batchId: staged.preview.batchId,
      );

      expect(reverted.deletedCount, 3);
      expect(reverted.keptCount, 0);
      expect((await repository.dataset(ledgerId: real)).transactions, isEmpty);
    });

    test('撤回不动用户已经整理过的交易', () async {
      final staged = await stage();
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
        month: month,
        transactionId: classified.id,
        categoryId: SeedCategoryIds.food,
      );

      final reverted = await repository.revertImport(
        batchId: staged.preview.batchId,
      );

      expect(reverted.deletedCount, 2);
      expect(reverted.editedTransactionIds, <int>[classified.id]);
      final after = await repository.dataset(ledgerId: real);
      expect(after.transactions, hasLength(1));
      expect(
        after.categoryName(SeedCategoryIds.food),
        isNotNull,
        reason: '用户分了类的那一笔与它的分类必须都还在',
      );
    });

    test('同一笔消费被两份账单导入时，撤回其中一份不会删掉它', () async {
      // 第一份：微信。
      final first = await stage(text: _bill, file: 'wechat.csv');
      await repository.commitImport(
        ledgerId: real,
        batchId: first.preview.batchId,
      );

      // 第二份：支付宝，里面有一笔和微信那份的「同源键」一致。
      // 这里直接用同样的命名空间与账户、同样的单号来构造这种情况。
      final second = await repository.stageImport(
        ledgerId: real,
        fileName: 'alipay.csv',
        bytes: _bytes(_bill),
        sourceNamespace: 'wechat',
        sourceAccount: '零钱',
      );
      // 第二份会被判成全部同源重复，所以人为把其中一行改成纳入。
      final stagedSecond = second as ImportStaged;
      final rows = await repository.importRows(
        batchId: stagedSecond.preview.batchId,
      );
      final duplicate = rows.firstWhere(
        (row) => row.status == ImportRowStatus.duplicate,
      );
      await repository.updateImportRows(<ImportRow>[
        duplicate.copyWith(included: true, status: ImportRowStatus.newRow),
      ]);

      await repository.commitImport(
        ledgerId: real,
        batchId: stagedSecond.preview.batchId,
      );

      final before = await repository.dataset(ledgerId: real);
      expect(
        before.transactions,
        hasLength(3),
        reason:
            '第二份没有插一条新交易，而是绑到了已有那一笔上。'
            '否则真机上会直接撞 (ledger_id, dedupe_key) 唯一索引',
      );

      final reverted = await repository.revertImport(
        batchId: first.preview.batchId,
      );

      // 第一份的 3 笔里，有 1 笔还被第二份引用着，不能删。
      expect(reverted.deletedCount, 2);
      expect(reverted.sharedTransactionIds, hasLength(1));
      final after = await repository.dataset(ledgerId: real);
      expect(
        after.transactions,
        hasLength(1),
        reason: '被第二份引用的那笔必须留下，否则用户会凭空少一笔消费',
      );
    });

    test('撤回后暂存行回到可再次提交的状态', () async {
      final staged = await stage();
      await repository.commitImport(
        ledgerId: real,
        batchId: staged.preview.batchId,
      );
      await repository.revertImport(batchId: staged.preview.batchId);

      final rows = await repository.importRows(batchId: staged.preview.batchId);
      for (final row in rows.where(
        (row) => row.status != ImportRowStatus.invalid,
      )) {
        expect(row.transactionId, isNull, reason: '不清掉会指向一个已经不存在的交易');
      }

      // 撤回之后还能再提交一次，说明状态是自洽的。
      final again = await repository.commitImport(
        ledgerId: real,
        batchId: staged.preview.batchId,
      );
      expect(again.count, 3);
      expect(
        (await repository.dataset(ledgerId: real)).transactions,
        hasLength(3),
      );
    });

    test('已提交的批次不能当成暂存区直接丢弃', () async {
      final staged = await stage();
      await repository.commitImport(
        ledgerId: real,
        batchId: staged.preview.batchId,
      );

      await expectLater(
        repository.discardImport(staged.preview.batchId),
        throwsA(isA<StateError>()),
        reason: '直接删掉会让交易失去来源记录，以后就判断不出还有没有别处引用',
      );
    });

    test('还没提交的批次可以直接丢弃', () async {
      final staged = await stage();
      await repository.discardImport(staged.preview.batchId);

      expect(await repository.importBatches(ledgerId: real), isEmpty);
      expect(
        await repository.importRows(batchId: staged.preview.batchId),
        isEmpty,
      );
    });
  });

  group('导入与整理的关系', () {
    test('导入进来的交易会出现在待整理队列里', () async {
      final staged = await stage();
      await repository.commitImport(
        ledgerId: real,
        batchId: staged.preview.batchId,
      );

      final snapshot = await repository.loadSnapshot(
        ledgerId: real,
        month: month,
      );
      expect(
        snapshot.record.entries.where(
          (entry) => entry.bucket == ReviewBucket.main,
        ),
        hasLength(3),
      );
      expect(snapshot.dataset.transactions, hasLength(3));
    });
  });
}
