import 'package:flutter_test/flutter_test.dart';
import 'package:younum/data/memory/in_memory_ledger_store.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/repositories/ledger_repository.dart';
import 'package:younum/features/organize/review_session.dart';

/// 整理会话状态机测试。
///
/// 对应实现指南 3.3 与 10.3：跳过不增加已完成数、未选分类不可提交、
/// 撤销恢复记录与队列位置、主队列空但稍后队列非空时不算完成。
///
/// 会话接的是真实仓库（后端换成内存存储），所以这些断言同时也是
/// 「界面经过的那条路径」的断言，而不是一个独立的状态机玩具实现。
void main() {
  late InMemoryLedgerStore store;
  late LedgerRepository repository;
  late ReviewSession session;

  setUp(() async {
    store = InMemoryLedgerStore();
    repository = LedgerRepository(store);
    await repository.initialize();
    session = ReviewSession(repository: repository);
    // 演示账本在偏好里是「用户主动进入」的模式，测试里直接指定。
    await session.useLedger(isDemo: true);
  });

  tearDown(() {
    session.dispose();
  });

  test('初始状态：6 笔待整理，主队列第一笔是当前卡片', () {
    expect(session.isReady, isTrue);
    expect(session.totalCount, 6);
    expect(session.doneCount, 0);
    expect(session.remainingCount, 6);
    expect(session.current?.merchant, 'MANNER COFFEE');
    expect(session.selectedCategory, isNull);
    expect(session.canUndo, isFalse);
    expect(session.isDemoLedger, isTrue);
  });

  test('未选择分类时不能提交', () async {
    final ok = await session.confirmCurrent();
    expect(ok, isFalse);
    expect(session.doneCount, 0);
    expect(session.current?.merchant, 'MANNER COFFEE');
  });

  test('确认后完成数 +1，临时选择被清空，下一张成为当前卡片', () async {
    session.select('餐饮');
    final ok = await session.confirmCurrent();
    expect(ok, isTrue);
    expect(session.doneCount, 1);
    expect(session.done.single.category, '餐饮');
    expect(session.selectedCategory, isNull);
    expect(session.current?.merchant, '优衣库 UNIQLO');
  });

  test('稍后处理不增加完成数，而是进入稍后队列', () async {
    final ok = await session.deferCurrent();
    expect(ok, isTrue);
    expect(session.doneCount, 0);
    expect(session.deferred.single.merchant, 'MANNER COFFEE');
    expect(session.remainingCount, 6);
    expect(session.current?.merchant, '优衣库 UNIQLO');
  });

  test('撤销恢复记录与队列位置，而不只是最后一笔', () async {
    session.select('餐饮');
    await session.confirmCurrent();
    session.select('购物');
    await session.confirmCurrent();
    expect(session.doneCount, 2);
    expect(session.current?.merchant, '滴滴出行');

    expect(await session.undo(), isTrue);
    expect(session.doneCount, 1);
    expect(session.current?.merchant, '优衣库 UNIQLO');

    expect(await session.undo(), isTrue);
    expect(session.doneCount, 0);
    expect(session.current?.merchant, 'MANNER COFFEE');
    expect(session.queue, hasLength(6));
    expect(session.canUndo, isFalse);
  });

  test('撤销也能回退稍后处理', () async {
    await session.deferCurrent();
    expect(session.deferred, hasLength(1));

    expect(await session.undo(), isTrue);
    expect(session.deferred, isEmpty);
    expect(session.current?.merchant, 'MANNER COFFEE');
  });

  test('没有可撤销的操作时返回 false', () async {
    expect(await session.undo(), isFalse);
  });

  test('跳过第一笔、完成其余 5 笔：不应判定为完成', () async {
    await session.deferCurrent();
    for (final category in <String>['购物', '交通', '餐饮', '娱乐', '健康']) {
      session.select(category);
      await session.confirmCurrent();
    }
    expect(session.doneCount, 5);
    expect(session.isQueueEmpty, isTrue);
    expect(session.hasDeferred, isTrue);
    // 主队列空了，但稍后队列还有记录 —— 不是完成态。
    expect(session.isComplete, isFalse);
  });

  test('重新整理稍后记录后可以完成', () async {
    await session.deferCurrent();
    for (final category in <String>['购物', '交通', '餐饮', '娱乐', '健康']) {
      session.select(category);
      await session.confirmCurrent();
    }
    expect(await session.resumeDeferred(), isTrue);
    expect(session.isComplete, isFalse);
    expect(session.current?.merchant, 'MANNER COFFEE');

    session.select('其他');
    await session.confirmCurrent();
    expect(session.doneCount, 6);
    expect(session.isComplete, isTrue);
    expect(session.progress, 1.0);
  });

  test('全部归类后金额守恒：合计 63330 分', () async {
    for (final category in <String>['餐饮', '购物', '交通', '餐饮', '娱乐', '健康']) {
      session.select(category);
      await session.confirmCurrent();
    }

    expect(session.doneCount, 6);
    final overview = session.overview!;
    expect(overview.summary.netExpenseCents, DemoLedgerSeed.baselineTotalCents);
    expect(overview.summary.netExpenseCents, 63330);
    expect(overview.summary.expenseCount, 6);
    expect(overview.summary.categoryNetTotalCents, 63330);
    expect(overview.summary.issues, isEmpty);
  });

  test('保存失败时数据不变，且选择保留以便重试', () async {
    session.select('餐饮');
    session.setDebugFailNextCommit(true);

    final ok = await session.confirmCurrent();
    expect(ok, isFalse);
    expect(session.doneCount, 0);
    expect(session.current?.merchant, 'MANNER COFFEE');
    // 选择必须保留，否则用户要重新选一次。
    expect(session.selectedCategory, '餐饮');

    // 再点一次可以成功。
    final retry = await session.confirmCurrent();
    expect(retry, isTrue);
    expect(session.doneCount, 1);
  });

  test('范围完整性由用户确认，不会被自动判定', () async {
    for (final category in <String>['餐饮', '购物', '交通', '餐饮', '娱乐', '健康']) {
      session.select(category);
      await session.confirmCurrent();
    }
    // 全部处理完，但没有人确认范围完整。
    expect(session.overview!.progress.isFullyProcessed, isTrue);
    expect(session.coverageConfirmed, isFalse);
    expect(session.overview!.canOpenCompleteReport, isFalse);
    expect(session.overview!.isPartialMonth, isTrue);

    await session.confirmCoverage(true);
    expect(session.coverageConfirmed, isTrue);
    expect(session.overview!.canOpenCompleteReport, isTrue);
  });

  test('进度跨实例保留：换一个会话仍然读到已确认的进度', () async {
    session.select('餐饮');
    await session.confirmCurrent();

    // 模拟杀进程重启：同一个存储，新的仓库与会话。
    final restarted = ReviewSession(repository: LedgerRepository(store));
    await restarted.useLedger(isDemo: true);
    expect(restarted.doneCount, 1);
    expect(restarted.current?.merchant, '优衣库 UNIQLO');
    expect(restarted.canUndo, isTrue);
    restarted.dispose();
  });

  test('清除本地数据后会话回到初始状态', () async {
    session.select('餐饮');
    await session.confirmCurrent();
    expect(session.doneCount, 1);

    // 「清除本地数据」先真实清空存储，会话再重载。
    await repository.clearAllData();
    await session.reset();

    expect(session.doneCount, 0);
    expect(session.queue, hasLength(6));
    expect(session.current?.merchant, 'MANNER COFFEE');
    expect(session.coverageConfirmed, isFalse);
  });

  test('未归档的一级分类可用于选择，细分用途不进入卡片网格', () {
    final names = session.categories.map((category) => category.name).toList();
    expect(names, contains('餐饮'));
    // 自建分类不进卡片网格：它是第 3 行，会把底部操作行挤出屏幕。
    expect(names, isNot(contains('宠物')));
    // 「日常三餐」挂在餐饮下面，只出现在「全部分类」里。
    expect(names, isNot(contains('日常三餐')));
    expect(
      session.allCategories.map((category) => category.name),
      contains('日常三餐'),
    );
  });

  test('切换账本会整体重载，演示数据不会混进真实账本', () async {
    expect(session.isDemoLedger, isTrue);
    expect(session.totalCount, 6);

    await session.useLedger(isDemo: false);
    expect(session.isDemoLedger, isFalse);
    expect(session.totalCount, 0);
    expect(session.hasAnyRecord, isFalse);
    expect(session.current, isNull);
  });
}
