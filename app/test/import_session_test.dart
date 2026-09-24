import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/import_records.dart';
import 'package:younum/domain/repositories/import_workflow.dart';
import 'package:younum/domain/repositories/ledger_file_source.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/domain/rules/import_rules.dart';
import 'package:younum/domain/rules/text_decoding.dart';
import 'package:younum/features/import_flow/import_session.dart';

import 'support/fake_file_source.dart';

/// 一份仿微信导出：6 行说明 + 表头 + 3 笔消费 + 1 笔退款 + 合计行。
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

/// 没有单号列的账单：两行同商户同时间同金额 → 疑似重复。
const String _noIdBill = '''
交易时间,交易对方,收/支,金额(元)
2026-09-23 12:00:00,便利店,支出,12.00
2026-09-23 12:00:00,便利店,支出,12.00
''';

/// 表头全部认不出来。
const String _unknownHeaderBill = '''
日期戳,摘要,数额
2026-09-23 14:26:00,老王牛肉面,28.00
''';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late FakeFileSource fileSource;
  late ImportSession session;

  const real = DemoLedgerSeed.realLedgerId;

  setUp(() async {
    store = InMemoryLedgerStore();
    repository = LedgerRepository(store);
    await repository.initialize();
    fileSource = FakeFileSource(bytes: _bytes(_bill));
    session = ImportSession(
      repository: repository,
      fileSource: fileSource,
      ledgerId: real,
    );
  });

  Future<void> pickAndSettle() async {
    await session.pickAndStage();
  }

  group('起点', () {
    test('还没选文件时是 idle，也没有错误', () {
      expect(session.phase, ImportPhase.idle);
      expect(session.errorMessage, isNull);
      expect(session.canPick, isTrue);
      expect(session.canCommit, isFalse);
    });

    test('设备不支持选择文件时给出说明，而不是卡住', () async {
      session = ImportSession(
        repository: repository,
        fileSource: FakeFileSource(available: false),
        ledgerId: real,
      );

      await session.pickAndStage();
      expect(session.phase, ImportPhase.failed);
      expect(session.errorMessage, contains('不能选择'));
      expect(session.canPick, isTrue, reason: '出错之后要能再试');
    });
  });

  group('选文件', () {
    test('用户取消：状态回到原样、不报错、不卡住', () async {
      fileSource.cancel = true;
      await pickAndSettle();

      expect(session.phase, ImportPhase.idle);
      expect(session.errorMessage, isNull, reason: '取消不是错误，不该弹提示');
      expect(session.canPick, isTrue, reason: '取消之后按钮必须还能点，否则用户就被锁在外面了');
    });

    test('选文件的过程中挡住连点', () async {
      final pending = session.pickAndStage();
      expect(session.phase, ImportPhase.picking);
      expect(session.isBusy, isTrue);
      expect(session.canPick, isFalse, reason: '选择器开着时不能再开一个');
      await pending;
      expect(session.isBusy, isFalse);
    });

    test('授权失效时标记为「需要重新选择」', () async {
      fileSource.failure = const PickFailed(
        '这个文件的读取权限已经失效，请重新选择一次',
        needsReselect: true,
      );
      await pickAndSettle();

      expect(session.phase, ImportPhase.failed);
      expect(session.errorNeedsReselect, isTrue);
    });

    test('解析成功后进入核对态，统计与暂存行都对得上', () async {
      await pickAndSettle();

      expect(session.phase, ImportPhase.ready);
      expect(session.fileName, '2026-09.csv');
      expect(session.preview!.freshCount, 3);
      expect(session.preview!.freshCents, 2800 + 500 + 900);
      expect(session.rows, hasLength(4), reason: '3 笔消费 + 1 笔退款');
      expect(session.invalidRows, hasLength(1));
      expect(session.commitCount, 3);
      expect(session.commitCents, 4200);
      expect(session.canCommit, isTrue);
    });

    test('解析失败时报错并保留文件，可以直接重试', () async {
      fileSource.bytes = Uint8List(0);
      await pickAndSettle();
      expect(session.phase, ImportPhase.failed);
    });
  });

  group('编码重试', () {
    test('换一个编码会重新解析同一份文件', () async {
      await session.stageDocument(
        PickedDocument(
          name: 'gbk.csv',
          bytes: Uint8List.fromList(<int>[0x81, 0x40, 0x81, 0x40]),
        ),
      );
      // 这串字节分不清是 UTF-8 还是 GBK，先按探测结果走；再强制一次。
      final before = session.phase;
      await session.retryWithEncoding(TextEncoding.gbk);

      expect(session.encodingOverride, TextEncoding.gbk, reason: '用户选过的编码要记住');
      expect(
        session.phase,
        isNot(ImportPhase.idle),
        reason: '重试之后不该回到起点（$before）',
      );
    });
  });

  group('字段映射', () {
    test('表头认不出来时进入映射态，且什么都不落库', () async {
      await session.stageDocument(
        PickedDocument(name: 'custom.csv', bytes: _bytes(_unknownHeaderBill)),
      );

      expect(session.phase, ImportPhase.needsMapping);
      expect(session.mapping, isNotNull);
      expect(session.mapping!.previewRows.first, <String>['日期戳', '摘要', '数额']);
      expect(session.commitCount, 0);
      expect(await repository.importBatches(ledgerId: real), isEmpty);
    });

    test('映射齐全后进入核对态', () async {
      await session.stageDocument(
        PickedDocument(name: 'custom.csv', bytes: _bytes(_unknownHeaderBill)),
      );

      await session.applyMapping(
        const ImportFieldMapping(
          headerRowIndex: 0,
          columns: <ImportField, int>{
            ImportField.occurredAt: 0,
            ImportField.merchant: 1,
            ImportField.amount: 2,
          },
        ),
      );

      expect(session.phase, ImportPhase.ready);
      expect(session.commitCount, 1);
      expect(session.commitCents, 2800);
    });

    test('映射仍不齐全时带着原因退回映射态', () async {
      await session.stageDocument(
        PickedDocument(name: 'custom.csv', bytes: _bytes(_unknownHeaderBill)),
      );
      await session.applyMapping(
        const ImportFieldMapping(
          headerRowIndex: 0,
          columns: <ImportField, int>{ImportField.amount: 2},
        ),
      );

      expect(session.phase, ImportPhase.needsMapping);
      expect(session.mapping!.issues, isNotEmpty);
      expect(session.mapping!.issues.single, contains('交易时间'));
    });
  });

  group('核对', () {
    test('取消勾选会立刻反映到笔数与金额上', () async {
      await pickAndSettle();
      final target = session.rows.firstWhere((row) => row.merchant == '地铁公司');

      await session.setIncluded(target.id, false);

      expect(session.commitCount, 2);
      expect(session.commitCents, 2800 + 900);
      expect(session.preview, isNotNull, reason: '取消勾选不能把批次信息弄丢，否则后面提交会失败');
      expect(session.canCommit, isTrue, reason: '还能提交剩下的两笔');
    });

    test('全部取消勾选后不能提交', () async {
      await pickAndSettle();
      for (final row in session.rows.where(
        (row) => row.status == ImportRowStatus.newRow,
      )) {
        await session.setIncluded(row.id, false);
      }

      expect(session.commitCount, 0);
      expect(session.canCommit, isFalse);
    });
  });

  group('疑似重复', () {
    setUp(() async {
      fileSource.bytes = _bytes(_noIdBill);
    });

    test('默认都留着，但必须先逐组确认才能提交', () async {
      await pickAndSettle();

      expect(session.commitCount, 2, reason: '没有单号就不能替用户删');
      expect(session.duplicateGroups, hasLength(1));
      expect(session.hasUndecidedDuplicates, isTrue);
      expect(
        session.canCommit,
        isFalse,
        reason: '指南 4.3：疑似重复必须逐组明确处理，不能直接说「完成」',
      );
    });

    test('选择保留两笔时才计入并允许提交', () async {
      await pickAndSettle();
      final group = session.duplicateGroups.single;

      await session.decideDuplicateGroup(group, keep: true);

      expect(session.hasUndecidedDuplicates, isFalse);
      expect(session.commitCount, 2);
      expect(session.canCommit, isTrue);
    });

    test('选择只留一笔时另一笔不计入', () async {
      await pickAndSettle();
      final group = session.duplicateGroups.single;

      await session.decideDuplicateGroup(group, keep: false);

      expect(session.hasUndecidedDuplicates, isFalse);
      expect(session.commitCount, 1);
      expect(session.canCommit, isTrue);
    });

    test('全部处理完之后能提交，且真的只写进去那么多笔', () async {
      await pickAndSettle();
      await session.decideDuplicateGroup(
        session.duplicateGroups.single,
        keep: false,
      );
      await session.commit();

      expect(session.phase, ImportPhase.committed);
      expect(session.committed!.count, 1);
      expect(
        (await repository.dataset(ledgerId: real)).transactions,
        hasLength(1),
      );
    });
  });

  group('同源重复', () {
    test('同一份文件导入两次：第二次数出来的全是同源重复', () async {
      await pickAndSettle();
      await session.commit();
      expect(session.phase, ImportPhase.committed);

      // 同一份文件再来一次。
      final second = ImportSession(
        repository: repository,
        fileSource: fileSource,
        ledgerId: real,
      );
      await second.pickAndStage();

      expect(second.commitCount, 0);
      expect(second.duplicateGroups, hasLength(3), reason: '3 笔都有稳定单号');
      expect(second.duplicateGroups.every((g) => g.isSameOrigin), isTrue);
    });

    test('同源重复即使选「保留」也不会变成独立一笔', () async {
      await pickAndSettle();
      await session.commit();

      final second = ImportSession(
        repository: repository,
        fileSource: fileSource,
        ledgerId: real,
      );
      await second.pickAndStage();
      // 这一组的「保留」在这类重复上是没有意义的：同一个交易单号就是同一笔，
      // 真的插两条会撞唯一索引。所以这里明确没有可计入的行。
      for (final group in second.duplicateGroups) {
        await second.decideDuplicateGroup(group, keep: true);
      }

      expect(second.commitCount, 0, reason: '同一笔不能被记两次，界面也不能让用户以为可以');
      expect(
        (await repository.dataset(ledgerId: real)).transactions,
        hasLength(3),
        reason: '库里还是原来的 3 笔',
      );
    });
  });

  group('提交与撤回', () {
    test('提交后进正式账，历史里出现这个批次', () async {
      await pickAndSettle();
      await session.commit();

      expect(session.phase, ImportPhase.committed);
      expect(session.committed!.count, 3);
      expect(session.committed!.amountCents, 4200);
      expect(session.history, hasLength(1));
      expect(session.history.first.stage, ImportStage.committed);
      expect(
        (await repository.dataset(ledgerId: real)).transactions,
        hasLength(3),
      );
    });

    test('重复点提交不会写第二遍', () async {
      await pickAndSettle();
      await session.commit();
      final before = session.phase;
      await session.commit();

      expect(before, ImportPhase.committed);
      expect(
        (await repository.dataset(ledgerId: real)).transactions,
        hasLength(3),
        reason: '已提交之后 canCommit 为假，再点不该再写一遍',
      );
    });

    test('撤回后交易消失，批次留在历史里', () async {
      await pickAndSettle();
      await session.commit();
      final batchId = session.committed!.batch.id;

      final revert = await session.revert(batchId);

      expect(revert!.deletedCount, 3);
      expect(session.phase, ImportPhase.reverted);
      expect((await repository.dataset(ledgerId: real)).transactions, isEmpty);
      expect(session.history, hasLength(1), reason: '历史要留着，用户才看得到发生过什么');
      expect(session.history.first.isReverted, isTrue);
    });

    test('丢弃还没提交的批次：回到起点并释放文件授权', () async {
      await pickAndSettle();
      final batchId = session.preview!.batchId;

      await session.discard(batchId);

      expect(session.phase, ImportPhase.idle);
      expect(session.history, isEmpty);
      expect(
        fileSource.releasedUris,
        contains('content://test/bill.csv'),
        reason: '不用了就该把系统授权还回去，不能一直占着',
      );
    });
  });

  group('历史', () {
    test('loadHistory 读得到真实批次', () async {
      await pickAndSettle();
      await session.commit();
      session.reset();
      await session.loadHistory();

      expect(session.history, hasLength(1));
      expect(session.history.first.fileName, '2026-09.csv');
      expect(session.history.first.newCount, 3);
      expect(session.history.first.sourceUri, 'content://test/bill.csv');
    });
  });

  group('状态一致性', () {
    test('提交的笔数与金额，与核对页上显示的完全一致', () async {
      await pickAndSettle();
      final shownCount = session.commitCount;
      final shownCents = session.commitCents;

      await session.commit();

      expect(session.committed!.count, shownCount);
      expect(session.committed!.amountCents, shownCents);
      final dataset = await repository.dataset(ledgerId: real);
      expect(dataset.transactions, hasLength(shownCount));
      var total = 0;
      for (final transaction in dataset.transactions) {
        total += transaction.amountCents;
      }
      expect(total, shownCents, reason: '界面上写的数字必须就是真正落库的数字');
    });

    test('出错之后能清掉错误回到可用状态', () async {
      fileSource.failure = const PickFailed('读不了这个文件');
      await pickAndSettle();
      expect(session.phase, ImportPhase.failed);

      session.clearError();

      expect(session.errorMessage, isNull);
      expect(session.phase, ImportPhase.idle);
      expect(session.canPick, isTrue);
    });

    test('解析中的状态不允许重复触发选择', () async {
      final pending = session.pickAndStage();
      expect(session.isBusy, isTrue);
      expect(session.canPick, isFalse);
      await pending;
      expect(session.isBusy, isFalse);
      expect(session.canPick, isTrue);
    });
  });
}
