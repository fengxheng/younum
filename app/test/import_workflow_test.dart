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

    test('撤回预览什么也不改', () async {
      final staged = await stage();
      await repository.commitImport(
        ledgerId: real,
        batchId: staged.preview.batchId,
      );
      final before = await repository.dataset(ledgerId: real);

      final preview = await repository.previewRevert(
        batchId: staged.preview.batchId,
      );

      expect(preview.deletedCount, 3, reason: '预览要算出真正会发生什么');
      final after = await repository.dataset(ledgerId: real);
      expect(after.transactions, hasLength(before.transactions.length));
      final batch = await repository.importBatch(
        ledgerId: real,
        batchId: staged.preview.batchId,
      );
      expect(batch!.isReverted, isFalse, reason: '预览不能把批次标成已撤回');
    });

    test('撤回预览与真正撤回的结果完全一致', () async {
      // 指南 4.4 要求撤回前展示真实影响，而展示的数字必须就是执行的结果。
      // 两者走同一段判定代码，这条用例就是锁住这一点。
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

      final preview = await repository.previewRevert(
        batchId: staged.preview.batchId,
      );
      final actual = await repository.revertImport(
        batchId: staged.preview.batchId,
      );

      List<int> sorted(Iterable<int> ids) => ids.toList()..sort();
      expect(
        sorted(actual.deletedTransactionIds),
        sorted(preview.deletedTransactionIds),
      );
      expect(
        sorted(actual.sharedTransactionIds),
        sorted(preview.sharedTransactionIds),
      );
      expect(
        sorted(actual.editedTransactionIds),
        sorted(preview.editedTransactionIds),
      );
      expect(preview.editedTransactionIds, <int>[classified.id]);
    });

    test('预览能看出哪些交易被别的批次共享', () async {
      final first = await stage(text: _bill, file: 'wechat.csv');
      await repository.commitImport(
        ledgerId: real,
        batchId: first.preview.batchId,
      );

      final second = await stage(text: _bill, file: 'again.csv');
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

      final preview = await repository.previewRevert(
        batchId: first.preview.batchId,
      );

      expect(preview.deletedCount, 2);
      expect(preview.sharedTransactionIds, hasLength(1));
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

    test('撤回把原消费删掉时，退款不被连带删掉，而是解除关联回到待核对', () async {
      // 指南 3.5.7 说的正是这种情况：撤回原消费，但还有一笔独立来源的退款
      // 关联着它。退款不能跟着消失（它可能是另一份账单导进来的），
      // 连接也不能留着（会指向一笔已经不存在的消费）。
      final staged = await stage();
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
      // 用低层 `linkRefund` 建连接（不给退款分配）：这样原消费仍然是
      // 「没动过」的 —— 撤回时它在删除名单里，正好走指南 3.5.7 那条路。
      // 界面上的路径（`linkRefundAndResolve`）要求原消费先有用途，
      // 而有用途的记录撤回时会被保留，碰不到这个分支。
      expect(
        await repository.linkRefund(
          ledgerId: real,
          month: month,
          refundTransactionId: refundId,
          originalTransactionId: original.id,
          amountCents: 2800,
        ),
        isA<ReviewSucceeded>(),
      );

      // 预览就要说清退款会怎样，而且预览本身不能动数据。
      final preview = await repository.previewRevert(
        batchId: staged.preview.batchId,
      );
      expect(preview.deletedTransactionIds, contains(original.id));
      expect(preview.unlinkedRefundIds, <int>[refundId]);
      expect(
        await store.refundLinkOf(refundId),
        isNotNull,
        reason: '预览什么都不能改',
      );

      final reverted = await repository.revertImport(
        batchId: staged.preview.batchId,
      );
      expect(reverted.unlinkedRefundIds, <int>[refundId]);

      expect(await store.transactionById(original.id), isNull, reason: '原消费该删');
      final refund = (await store.transactionById(refundId))!;
      expect(refund.nature, TransactionNature.unknown);
      expect(refund.reviewStatus, ReviewStatus.pending, reason: '指南 3.5.7：恢复待核对');
      expect(await store.refundLinkOf(refundId), isNull);
    });
  });

  group('人工字段映射', () {
    // 一份表头全部认不出来的账单：列名不在别名表里。
    const customBill =
        '''日期戳,摘要,数额,方向Z
'''
        '''2026-09-23 14:26:00,老王牛肉面,28.00,支
'''
        '''2026-09-24 09:02:11,地铁公司,5.00,支
'''; // ignore: missing_whitespace_between_adjacent_strings

    test('表头认不出来时要求人工映射，并给出预览与已认出的列', () async {
      final result = await repository.stageImport(
        ledgerId: real,
        fileName: 'custom.csv',
        bytes: _bytes(customBill),
        sourceNamespace: 'manual',
      );

      expect(result, isA<ImportMappingRequired>());
      final mapping = result as ImportMappingRequired;
      expect(mapping.previewRows.first, <String>[
        '日期戳',
        '摘要',
        '数额',
        '方向Z',
      ], reason: '映射界面要能指出哪一行是表头，所以预览必须包含表头行');
      expect(mapping.previewRows.length, greaterThanOrEqualTo(2));
      expect(mapping.columnCount, 4);
      expect(
        mapping.guessedHeaderRowIndex,
        -1,
        reason: '一行都没匹配上，不随便挑一行当表头；界面默认用第 0 行',
      );
      expect(
        mapping.missingFields,
        containsAll(<ImportField>[
          ImportField.occurredAt,
          ImportField.amount,
          ImportField.merchant,
        ]),
      );
      expect(await repository.importBatches(ledgerId: real), isEmpty);
    });

    test('映射齐全后走同一段解析代码，结果与自动识别一致', () async {
      final result = await repository.stageImport(
        ledgerId: real,
        fileName: 'custom.csv',
        bytes: _bytes(customBill),
        sourceNamespace: 'manual',
        mapping: const ImportFieldMapping(
          headerRowIndex: 0,
          columns: <ImportField, int>{
            ImportField.occurredAt: 0,
            ImportField.merchant: 1,
            ImportField.amount: 2,
            ImportField.direction: 3,
          },
        ),
      );

      expect(result, isA<ImportStaged>(), reason: '$result');
      final staged = result as ImportStaged;
      expect(staged.preview.freshCount, 2);
      expect(staged.preview.freshCents, 2800 + 500);

      final rows = await repository.importRows(batchId: staged.preview.batchId);
      expect(rows, hasLength(2), reason: '表头那一行不该进暂存区');
      expect(rows.first.merchant, '老王牛肉面');
      expect(rows.first.amountCents, 2800);
      expect(rows.first.direction, ImportDirection.expense);
    });

    test('映射还是不全时不落库，并把原因带回去', () async {
      final result = await repository.stageImport(
        ledgerId: real,
        fileName: 'custom.csv',
        bytes: _bytes(customBill),
        sourceNamespace: 'manual',
        mapping: const ImportFieldMapping(
          headerRowIndex: 0,
          columns: <ImportField, int>{ImportField.amount: 2},
        ),
      );

      expect(result, isA<ImportMappingRequired>());
      final mapping = result as ImportMappingRequired;
      expect(mapping.issues, isNotEmpty);
      expect(mapping.issues.single, contains('交易对方'));
      expect(mapping.guessedHeaderRowIndex, 0, reason: '用户选过的表头行要带回去，不能又回到默认值');
      expect(await repository.importBatches(ledgerId: real), isEmpty);
    });

    test('自动识别得出的列会用来预填映射界面', () async {
      // 英文表头能认出大部分，但缺少「交易对方」这个必填项。
      final result = await repository.stageImport(
        ledgerId: real,
        fileName: 'semi.csv',
        bytes: _bytes('Date,Amount\n2026-09-23,28.00\n'),
        sourceNamespace: 'manual',
      );

      expect(result, isA<ImportMappingRequired>());
      expect(
        (result as ImportMappingRequired).guessedColumns[ImportField.amount],
        1,
        reason: '已经认出来的列不该让用户再选一遍',
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

  group('分享进来的文件', () {
    /// 一整块 OLE2 头。真正的老式 `.xls` 长这样，而我们**不实现** BIFF 解析。
    Uint8List ole2Bytes() => Uint8List.fromList(<int>[
      0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]);

    test('老式 .xls 如实说读不了，并给出下一步', () async {
      // 为什么值得写：认不出来的后果是实的 —— 那些二进制字节会被当成文本硬解，
      // 用户看到的是乱码，还被领到字段映射页对着乱码指列。
      final result = await repository.stageImport(
        ledgerId: real,
        fileName: '平安银行交易明细.xls',
        bytes: ole2Bytes(),
        sourceNamespace: 'manual',
      );

      expect(result, isA<ImportStageRejected>());
      final message = (result as ImportStageRejected).message;
      expect(message, contains('另存为'), reason: '要说清用户做得到的那一步');
      expect(message, contains('.xlsx'));
    });

    test('老式 .xls 认的是**内容**，不是后缀', () async {
      // 改名叫 .csv 也一样：这是防「换个后缀就能骗过判断」。
      final result = await repository.stageImport(
        ledgerId: real,
        fileName: '明细.csv',
        bytes: ole2Bytes(),
        sourceNamespace: 'manual',
      );

      expect((result as ImportStageRejected).message, contains('另存为'));
    });

    test('按内容认来源：微信 / 支付宝 / 通用', () {
      // 微信：说明行里有「微信」。
      expect(repository.sniffImportSource(_bytes(_bill)), 'wechat');

      // 支付宝：说明行里有「支付宝」，且**数据行里的关键词不能带偏它**
      // （表头本身没有「支付宝」两个字，只能靠表头之前的说明行）。
      const alipay = '''
支付宝交易记录明细查询
账号:[test@example.com]
交易时间,交易分类,交易对方,商品说明,收/支,金额(元),交易状态,交易订单号
2026-09-23 18:09:20,餐饮美食,天际美食荟,餐费,支出,20.00,交易成功,2026092322001
''';
      expect(repository.sniffImportSource(_bytes(alipay)), 'alipay');

      // 认不出来就是通用表格 —— 宁可漏认（去重时多问一句），不可错认。
      expect(repository.sniffImportSource(_bytes(_noIdBill)), 'manual');
    });

    test('读不了的文件不会被硬说成某个来源', () {
      // 一份看不懂的东西（老式 .xls / 空文件）：来源只能是通用表格。
      // 这里若返回 wechat/alipay，用户的分账口径会被一份根本不是账单的
      // 文件污染。
      expect(repository.sniffImportSource(ole2Bytes()), 'manual');
      expect(repository.sniffImportSource(Uint8List(0)), 'manual');
    });

    test('分享进来的微信账单与从入口导入的算**同一个来源**', () async {
      // 这条是分享这条路最容易错的地方：命名空间参与同源去重键，
      // 认错了（例如一律当 manual）就会出现「先分享一次、再从微信入口导一次」，
      // 同一个单号只能报成「疑似重复」，用户得一组一组确认。
      final shared = await repository.stageImport(
        ledgerId: real,
        fileName: '微信支付账单.csv',
        bytes: _bytes(_bill),
        sourceNamespace: repository.sniffImportSource(_bytes(_bill)),
        sourceAccount: '零钱',
      );
      await repository.commitImport(
        ledgerId: real,
        batchId: (shared as ImportStaged).preview.batchId,
      );

      final again = await repository.stageImport(
        ledgerId: real,
        fileName: '2026-09.csv',
        bytes: _bytes(_bill),
        sourceNamespace: 'wechat',
        sourceAccount: '零钱',
      );

      expect(
        (again as ImportStaged).preview.duplicateCount,
        3,
        reason: '3 笔消费都要被认成同源重复，而不是疑似重复',
      );
      expect(again.preview.suspectedCount, 0);
    });
  });
}
