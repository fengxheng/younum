/// 整理会话。
///
/// 阶段 2 起这个会话是**持久化**的：队列顺序、已完成分类、稍后队列、
/// 撤销日志都在数据库里，杀进程重启后进度不丢（指南 2.3.5 / 阶段 4 验收）。
///
/// 这里只做界面状态适配与调用编排；真正的业务规则与事务在
/// `LedgerRepository` 与 `lib/domain/rules/` 里，与单元测试共用同一份实现。
///
/// 已经按目标形态约束好的行为：
/// * 跳过不增加已完成数；
/// * 未选择分类时确认不可提交；
/// * 每次操作后清空临时选择，新卡片默认未选分类；
/// * 撤销恢复记录与**队列位置**，而不只是最后一笔；
/// * 提交期间不允许并发提交；
/// * 保存失败时不假装成功，用户的选择留在原地可以重试。
library;

import 'package:flutter/widgets.dart';

import '../../domain/models/allocation.dart';
import '../../domain/models/category.dart';
import '../../domain/models/ledger_transaction.dart';
import '../../domain/models/year_month.dart';
import '../../domain/repositories/ledger_repository.dart';
import '../../domain/rules/month_insights.dart';
import '../../domain/rules/month_overview.dart';
import 'review_card.dart';

/// 整理会话状态。
class ReviewSession extends ChangeNotifier {
  ReviewSession({required this.repository});

  /// 账本仓库。规则与事务都在它里面。
  final LedgerRepository repository;

  ReviewSnapshot? _snapshot;
  MonthReport? _report;
  List<Category> _categories = const <Category>[];
  String? _loadError;
  bool _loading = false;
  bool _committing = false;
  bool _isDemo = false;
  bool _debugFailNextCommit = false;
  bool _hasRecords = false;
  int? _ledgerId;
  YearMonth? _month;
  String? _selectedCategory;
  String? _lastFailure;

  // ---------------------------------------------------------------------------
  // 加载
  // ---------------------------------------------------------------------------

  bool get isLoading => _loading;

  /// 加载失败的原因。为 null 表示上次加载成功。
  String? get loadError => _loadError;

  /// 最近一次操作的失败说明（保存失败 / 被规则拒绝 / 版本冲突）。
  String? get lastFailure => _lastFailure;

  /// 切换账本（真实 / 演示）并重新加载。
  ///
  /// 两个账本的数据互不可见，切换时必须整体重载，不能沿用上一本的队列。
  Future<void> useLedger({required bool isDemo}) async {
    if (_isDemo == isDemo && _snapshot != null) return;
    _isDemo = isDemo;
    _month = null;
    _snapshot = null;
    _report = null;
    _selectedCategory = null;
    await load();
  }

  /// 切换到另一个月份。
  ///
  /// 切月后必须读对应月份的数据，不能继续展示上一份固定报告
  /// （指南第 5 节 months 的验收项）。
  Future<void> selectMonth(YearMonth month) async {
    if (_month == month) return;
    _month = month;
    _selectedCategory = null;
    await load();
  }

  /// 加载（必要时创建）整理会话与当前月份的报告。
  Future<void> load() async {
    _loading = true;
    _loadError = null;
    notifyListeners();
    try {
      final ledger = await repository.ledgerFor(isDemo: _isDemo);
      _ledgerId = ledger.id;
      final state = await repository.preferredMonthState(ledgerId: ledger.id);
      _month ??= state.month;
      _hasRecords = state.hasRecords;
      _categories = await repository.categories(ledgerId: ledger.id);
      _snapshot = await repository.loadSnapshot(
        ledgerId: ledger.id,
        month: _month!,
      );
      // 报告与队列用的是同一份数据，因此首页与月报永远给出同一组数字。
      _report = await repository.monthReport(
        ledgerId: ledger.id,
        month: _month!,
      );
    } catch (error) {
      _loadError = '$error';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 重新加载当前账本与月份。
  ///
  /// [followPreferredMonth] 为真时，**像刚打开应用那样**重新判断该看哪个月
  /// （有记录就取最新记录所在月，没有就用当前自然月）—— 导入之后要用它。
  ///
  /// 为什么导入非要用这一条：用户导入的账单可能不是他正在看的那一个月，
  /// 光重读数据、不跟着走，界面依旧停在原地，看到的还是「这个月还没有账单」。
  /// 这条规则的口径很干脆：**导入之后看到的，和重启之后看到的一模一样**。
  Future<void> reload({bool followPreferredMonth = false}) async {
    if (followPreferredMonth) _month = null;
    await load();
  }

  // ---------------------------------------------------------------------------
  // 读取
  // ---------------------------------------------------------------------------

  /// 当前月份的完整报告：概况、洞察、趋势、有记录的月份、数据集。
  ///
  /// 月报 / 趋势 / 明细 / 分享 / 月份页都从这里取数，
  /// 与首页用的是同一份计算结果。
  MonthReport? get report => _report;

  /// 当前月份的金额与分类概况。
  MonthOverview? get overview => _report?.overview;

  /// 当前月份的洞察：日均、单笔最高、最低消费日、环比、分类变化。
  MonthInsights? get insights => _report?.insights;

  /// 近 N 个月的趋势，按时间升序。
  List<MonthTrendPoint> get trend =>
      _report?.trend ?? const <MonthTrendPoint>[];

  /// 有记录的月份，倒序。
  List<YearMonth> get recordedMonths =>
      _report?.recordedMonths ?? const <YearMonth>[];

  /// 会话是否已经成功加载过。
  ///
  /// 界面靠它区分「还没有数据」与「这个月确实什么都没有」——
  /// 两者都表现为 current 为 null，但展示完全不同。
  bool get isReady => _snapshot != null;

  /// 这本账本里到底有没有记录。
  bool get hasAnyRecord => _hasRecords;

  YearMonth? get month => _month;

  bool get isDemoLedger => _isDemo;

  /// 卡片页分类网格里显示的分类。
  ///
  /// 只放**内置的一级分类**（8 个），与设计稿一致。
  ///
  /// 为什么不是「所有一级分类」：用户自建分类会把网格从 2 行撑到 3 行，
  /// 而确认按钮与撤销 / 稍后 / 更多操作行必须在不滚动的情况下可见
  /// （指南 6.2「核心确认区尽量稳定可达」）。自建分类通过
  /// 「全部分类 ›」进入，见 [allCategories]。
  List<Category> get categories => <Category>[
        for (final category in _categories)
          if (!category.archived && category.isRoot && category.isBuiltin)
            category,
      ];

  /// 全部未归档分类，含细分用途与自建分类。
  List<Category> get allCategories => <Category>[
        for (final category in _categories)
          if (!category.archived) category,
      ];

  /// 本月可作为「原消费」的记录，供退款关联选择。
  ///
  /// 只放消费：退款只能抵扣消费（指南 3.5）。已经拆过的原消费也放进来，
  /// 由仓库层告诉用户「这种要先指定抵扣到哪些用途」，
  /// 而不是在列表里默默隐掉一整类记录。
  List<ReviewCard> get refundableOriginals {
    final dataset = _report?.dataset ?? _snapshot?.dataset;
    if (dataset == null) return const <ReviewCard>[];
    return <ReviewCard>[
      for (final transaction in dataset.transactions)
        if (transaction.nature.isExpense) _cardOf(transaction),
    ];
  }

  /// 当前卡片。
  ReviewCard? get current {
    final transaction = _snapshot?.current;
    if (transaction == null) return null;
    return _cardOf(transaction);
  }

  /// 主队列。
  List<ReviewCard> get queue => <ReviewCard>[
        for (final transaction
            in _snapshot?.mainQueue ?? const <LedgerTransaction>[])
          _cardOf(transaction),
      ];

  /// 稍后队列。
  List<ReviewCard> get deferred => <ReviewCard>[
        for (final transaction
            in _snapshot?.deferred ?? const <LedgerTransaction>[])
          _cardOf(transaction),
      ];

  /// 已经整理完成的记录，按时间倒序。详情页要按 ID 找到它们。
  List<ReviewDoneEntry> get done {
    final snapshot = _snapshot;
    if (snapshot == null) return const <ReviewDoneEntry>[];
    final entries = <ReviewDoneEntry>[];
    for (final transaction in snapshot.dataset.transactions) {
      if (transaction.month != snapshot.record.month) continue;
      if (transaction.reviewStatus != ReviewStatus.resolved) continue;
      final card = _cardOf(transaction);
      entries.add(
        ReviewDoneEntry(card: card, category: card.categoryName ?? '未分类'),
      );
    }
    entries.sort(
      (a, b) =>
          b.transaction.occurredAtMs.compareTo(a.transaction.occurredAtMs),
    );
    return entries;
  }

  int get doneCount => _snapshot?.resolvedCount ?? 0;

  int get totalCount => _snapshot?.totalCount ?? 0;

  /// 「还剩」= 主队列 + 稍后队列。跳过不会减少这个数字（指南 3.3）。
  int get remainingCount => queue.length + deferred.length;

  double get progress => _snapshot?.progress ?? 0;

  int get progressPercent => (progress * 100).round();

  /// 当前选中的分类名称。
  String? get selectedCategory => _selectedCategory;

  /// 当前选中的分类 ID。未选择、或选中的名字找不到对应分类时为 null。
  int? get selectedCategoryId {
    final name = _selectedCategory;
    return name == null ? null : categoryIdNamed(name);
  }

  /// 按**名字**找分类 ID。
  ///
  /// 分类选择页返回的是名字（不是 ID），详情页拿到之后要换回 ID 才能写库。
  /// 重名时取第一个 —— 与 `select()` 的行为一致。
  int? categoryIdNamed(String name) {
    for (final category in allCategories) {
      if (category.name == name) return category.id;
    }
    return null;
  }

  bool get isCommitting => _committing;

  bool get canUndo => _snapshot?.canUndo ?? false;

  bool get isQueueEmpty => queue.isEmpty;

  /// 主队列空了但还有稍后记录 —— 此时进稍后列表，不进完成页（指南 14.2）。
  bool get hasDeferred => deferred.isNotEmpty;

  /// 全部处理完：主队列与稍后队列都为空。
  bool get isComplete => isQueueEmpty && !hasDeferred;

  /// 用户是否确认了当前月份的账单范围完整。
  bool get coverageConfirmed => _snapshot?.coverageConfirmed ?? false;

  /// 撤销栈顶操作的描述，用于按钮朗读文本。
  String? get lastActionLabel => _snapshot?.lastActionLabel;

  /// 设计走查用：让下一次提交失败，以便检查「卡片恢复、选择保留」路径。
  ///
  /// 只影响一次提交；开关变化会通知界面更新说明文案。
  void setDebugFailNextCommit(bool value) {
    if (_debugFailNextCommit == value) return;
    _debugFailNextCommit = value;
    notifyListeners();
  }

  bool get debugFailNextCommitEnabled => _debugFailNextCommit;

  // ---------------------------------------------------------------------------
  // 操作
  // ---------------------------------------------------------------------------

  void select(String category) {
    if (_committing) return;
    if (_selectedCategory == category) return;
    _selectedCategory = category;
    notifyListeners();
  }

  /// 确认当前用途。
  ///
  /// 返回 false 表示未提交；调用方据此让卡片回弹并保留选择。
  Future<bool> confirmCurrent() async {
    if (_committing) return false;
    final categoryId = selectedCategoryId;
    // 未选择分类时确认按钮不可提交（含右滑）。
    if (categoryId == null) return false;
    final card = current;
    if (card == null) return false;

    return _commit(
      () => repository.confirm(
        ledgerId: _ledgerId!,
        month: _month!,
        transactionId: card.id,
        categoryId: categoryId,
      ),
    );
  }

  /// 拆分某笔交易：一笔金额拆到多个用途。
  ///
  /// 传交易 ID 而不是「当前卡片」：拆分是从明细 / 详情页进来的，
  /// 那时当前卡片可能是别的记录。
  Future<bool> splitTransaction({
    required int transactionId,
    required List<AllocationDraft> items,
  }) async {
    if (_committing) return false;
    final ledgerId = _ledgerId;
    final month = _month;
    if (ledgerId == null || month == null) return false;

    return _commit(
      () => repository.split(
        ledgerId: ledgerId,
        month: month,
        transactionId: transactionId,
        items: items,
      ),
    );
  }

  /// 保存详情页的修改：备注，以及（可选的）用途变更。
  ///
  /// [categoryId] 为 null 表示不改用途。
  Future<bool> saveDetails({
    required int transactionId,
    required String? note,
    int? categoryId,
  }) async {
    if (_committing) return false;
    final ledgerId = _ledgerId;
    final month = _month;
    if (ledgerId == null || month == null) return false;

    return _commit(
      () => repository.saveDetails(
        ledgerId: ledgerId,
        month: month,
        transactionId: transactionId,
        note: note,
        categoryId: categoryId,
      ),
    );
  }

  /// 把一笔退款关联到原消费，并同时把它标成退款、处理完成。
  ///
  /// [allocations] 是拆分消费的退款分配（指南 3.5.5）：原消费没拆过就留空。
  Future<bool> linkRefundAndResolve({
    required int refundTransactionId,
    required int originalTransactionId,
    List<RefundAllocationDraft> allocations = const <RefundAllocationDraft>[],
  }) async {
    if (_committing) return false;
    final ledgerId = _ledgerId;
    final month = _month;
    if (ledgerId == null || month == null) return false;

    return _commit(
      () => repository.linkRefundAndResolve(
        ledgerId: ledgerId,
        month: month,
        refundTransactionId: refundTransactionId,
        originalTransactionId: originalTransactionId,
        allocations: allocations,
      ),
    );
  }

  /// 解除一笔退款的关联（指南 3.5.7），退款回到待整理。
  Future<bool> unlinkRefund(int refundTransactionId) async {
    if (_committing) return false;
    final ledgerId = _ledgerId;
    if (ledgerId == null) return false;

    return _commit(
      () => repository.unlinkRefund(
        ledgerId: ledgerId,
        refundTransactionId: refundTransactionId,
      ),
    );
  }

  /// 这笔退款现在关联到了谁（没有关联则是 null）。
  ///
  /// 直查而不是从快照里找：快照里的退款连接是跟着**原消费所在月份**
  /// 带出来的，跨月退款在原消费不在本月时就找不到 —— 而这里问的正是
  /// 「这笔退款」关联到了谁。
  Future<RefundLink?> refundLinkOf(int refundTransactionId) =>
      repository.refundLinkOf(refundTransactionId);

  /// 按 ID 取一笔记录（只读：显示原消费的商户名这类）。
  Future<LedgerTransaction?> transactionById(int transactionId) =>
      repository.transactionById(transactionId);

  /// 稍后处理。不增加完成数。
  Future<bool> deferCurrent() async {
    if (_committing) return false;
    final card = current;
    if (card == null) return false;

    return _commit(
      () => repository.defer(
        ledgerId: _ledgerId!,
        month: _month!,
        transactionId: card.id,
      ),
    );
  }

  /// 把稍后队列重新放进主队列。
  Future<bool> resumeDeferred() async {
    if (_committing || deferred.isEmpty) return false;
    return _commit(
      () => repository.reopenDeferred(ledgerId: _ledgerId!, month: _month!),
    );
  }

  /// 改一笔记录的交易性质（转账 / 收入 / 排除统计 / 改回消费）。
  Future<bool> setNature({
    required int transactionId,
    required TransactionNature nature,
    String? excludeReason,
  }) async {
    if (_committing) return false;
    final ledgerId = _ledgerId;
    final month = _month;
    if (ledgerId == null || month == null) return false;

    return _commit(
      () => repository.setNature(
        ledgerId: ledgerId,
        month: month,
        transactionId: transactionId,
        nature: nature,
        excludeReason: excludeReason,
      ),
    );
  }

  /// 撤销最近一次成功的操作，恢复记录与队列位置。
  Future<bool> undo() async {
    if (_committing) return false;
    if (!canUndo) return false;
    return _commit(
      () => repository.undo(ledgerId: _ledgerId!, month: _month!),
    );
  }

  /// 用户确认当月账单范围是否完整。
  ///
  /// 这个值只能由用户显式给出，不能因为数据里恰好有月初和月底的记录就自动判定。
  Future<void> confirmCoverage(bool value) async {
    final ledgerId = _ledgerId;
    final month = _month;
    if (ledgerId == null || month == null) return;
    try {
      await repository.setCoverageConfirmed(
        ledgerId: ledgerId,
        month: month,
        value: value,
      );
      await reload();
    } catch (error) {
      _lastFailure = '$error';
      notifyListeners();
    }
  }

  /// 清空会话并重新加载。
  ///
  /// 用于「清除本地数据」之后：会话状态必须跟着账本一起归零，
  /// 不能留下上一份账本的完成数（指南 8.3）。
  Future<void> reset() async {
    _snapshot = null;
    _report = null;
    _selectedCategory = null;
    _lastFailure = null;
    _month = null;
    notifyListeners();
    await load();
  }

  /// 真实清空本地数据，然后重载会话。
  ///
  /// 保留主题偏好与引导状态（指南 8.3）。清除过程中不抛异常到界面：
  /// 失败时把原因放进 [lastFailure]，界面据此提示，而不是假装成功。
  Future<void> clearAllData() async {
    try {
      await repository.clearAllData();
    } catch (error) {
      _lastFailure = '清除失败：$error';
    }
    await reset();
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  Future<bool> _commit(Future<ReviewOutcome> Function() action) async {
    _committing = true;
    _lastFailure = null;
    notifyListeners();
    try {
      // 走查用的一次性失败开关：不落到数据库，但走同一条「失败不改状态」路径。
      if (_debugFailNextCommit) {
        _debugFailNextCommit = false;
        return false;
      }

      final outcome = await action();
      switch (outcome) {
        case ReviewSucceeded(:final snapshot):
          _snapshot = snapshot;
          // 金额随之变化，报告也要重算 —— 否则首页与月报会出现两套数字。
          _report = await repository.monthReport(
            ledgerId: _ledgerId!,
            month: _month!,
          );
          // 每次操作后清空临时选择，下一张默认未选分类。
          _selectedCategory = null;
          return true;
        case ReviewRejected(:final message):
          _lastFailure = message;
          return false;
        case ReviewConflict(:final message):
          _lastFailure = message;
          return false;
        case ReviewFailed():
          _lastFailure = '保存失败，数据没有被修改，可以重试';
          return false;
      }
    } catch (error) {
      // 存储异常一律当成「没保存成功」：保留用户输入，不提前显示成功。
      _lastFailure = '保存失败，数据没有被修改，可以重试';
      return false;
    } finally {
      _committing = false;
      notifyListeners();
    }
  }

  /// 按 ID 取一张卡片。
  ///
  /// 详情页用它：明细、分类下钻、分享都可能指向**不在当前队列里**的记录
  /// （已归类、收入、退款、其它月份），所以从完整数据集里找，
  /// 而不是只翻队列。
  ReviewCard? cardFor(int transactionId) {
    final transaction = (_report?.dataset ?? _snapshot?.dataset)
        ?.transaction(transactionId);
    if (transaction == null) return null;
    return _cardOf(transaction);
  }

  /// 按 ID 找分类。
  Category? categoryOf(int categoryId) => _categoryById(categoryId);

  /// 把交易记录翻译成展示模型。
  ReviewCard _cardOf(LedgerTransaction transaction) {
    final dataset = _report?.dataset ?? _snapshot?.dataset;
    if (dataset == null) return ReviewCard(transaction: transaction);
    final allocations = dataset.allocationsOf(transaction.id);
    if (allocations.isEmpty) return ReviewCard(transaction: transaction);
    return ReviewCard(
      transaction: transaction,
      allocations: allocations,
      category: _categoryById(allocations.first.categoryId),
    );
  }

  Category? _categoryById(int id) {
    for (final category in _categories) {
      if (category.id == id) return category;
    }
    return null;
  }
}

/// 把整理会话提供给子树，让切换标签后进度不丢。
class ReviewSessionScope extends InheritedNotifier<ReviewSession> {
  const ReviewSessionScope({
    super.key,
    required ReviewSession session,
    required super.child,
  }) : super(notifier: session);

  static ReviewSession of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ReviewSessionScope>();
    assert(scope != null, 'ReviewSessionScope 未挂载：请检查 app.dart 的根部装配。');
    return scope!.notifier!;
  }

  /// 不需要订阅变化时使用，例如在异步回调里读取。
  static ReviewSession read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<ReviewSessionScope>();
    assert(scope != null, 'ReviewSessionScope 未挂载：请检查 app.dart 的根部装配。');
    return scope!.notifier!;
  }
}
