/// 演示账本的初始内容。
///
/// 这份数据**不是**视觉填充，而是演示账本真实落库的初始记录：
/// 指南 1.3 明确要求「网页中的 128 笔、¥8,432.60、环比、分类比例都是视觉样例，
/// 正式页面必须来自数据库查询」，所以这些数字必须来自这里写入的记录，
/// 而不是界面上的常量。
///
/// 内容严格对应指南 10.1「固定金额基准」的 6 笔：
///
/// | 商户 | 金额分 | 建议用途 |
/// | --- | ---: | --- |
/// | MANNER COFFEE | 2800 | 餐饮 |
/// | 优衣库 | 29900 | 购物 |
/// | 滴滴出行 | 3650 | 交通 |
/// | 盒马鲜生 | 12680 | 餐饮 |
/// | 周末电影 | 7800 | 娱乐 |
/// | 社区药房 | 6500 | 健康 |
///
/// 全部归类后：总消费 63330 分 / ¥633.30；餐饮 15480 分；消费笔数 6。
///
/// 分类 ID 与交易 ID 都是**显式常量**：演示账本每次重建都得到同一份数据，
/// 测试可以稳定断言，不需要依赖自增顺序。
library;

import '../../core/time/statistics_time.dart';
import '../../domain/models/category.dart';
import '../../domain/models/ledger.dart';
import '../../domain/models/ledger_source.dart';
import '../../domain/models/ledger_transaction.dart';
import '../../domain/models/year_month.dart';

/// 演示账本种子里用到的分类 ID。
///
/// 显式编号（而不是靠 AUTOINCREMENT）让种子可复现，也让退款、拆分这类
/// 需要引用分类 ID 的测试有个稳定锚点。
abstract final class SeedCategoryIds {
  static const int food = 1;
  static const int shopping = 2;
  static const int transport = 3;
  static const int housing = 4;
  static const int entertainment = 5;
  static const int health = 6;
  static const int social = 7;
  static const int other = 8;
  static const int pets = 9;
  static const int study = 10;

  // 餐饮下的细分用途（指南 14.3 的自定义分类范围）。
  static const int diningMeals = 11;
  static const int diningCoffee = 12;
  static const int diningSnack = 13;
  static const int diningGathering = 14;
  static const int diningGroceries = 15;
}

/// 指南 10.1 的一行基准数据。
///
/// [suggestedCategoryId] 是「建议用途」，**不是**预先归类好的结果：
/// 记录落库时都是 `PENDING` 且没有任何分配，必须由用户在整理流程里确认。
final class BaselineEntry {
  const BaselineEntry({
    required this.merchant,
    required this.amountCents,
    required this.sourceNamespace,
    required this.sourceTransactionId,
    required this.day,
    required this.hour,
    required this.minute,
    required this.suggestedCategoryId,
  });

  final String merchant;
  final int amountCents;
  final String sourceNamespace;
  final String sourceTransactionId;
  final int day;
  final int hour;
  final int minute;
  final int suggestedCategoryId;
}

/// 演示账本种子。
abstract final class DemoLedgerSeed {
  /// 演示账本 ID。与真实账本分开，示例数据不可能混进真实账本（指南 1.3）。
  static const int demoLedgerId = 1;

  /// 真实账本 ID。
  static const int realLedgerId = 2;

  static const String demoLedgerName = '示例账本';
  static const String realLedgerName = '我的账本';

  /// 演示账本覆盖的月份。与前端的 `2026年9月` 一致。
  static YearMonth get month => YearMonth(2026, 9);

  /// 演示账本创建时间（北京时间 2026-09-24 10:00）。
  static int get createdAtMs => StatisticsTime.epochMsFor(2026, 9, 24, 10);

  /// 演示账本。`isDemo = true`，仓库层据此隔离查询。
  static Ledger demoLedger() => Ledger(
        id: demoLedgerId,
        name: demoLedgerName,
        isDemo: true,
        createdAtMs: createdAtMs,
        timeZone: StatisticsTime.timeZone,
      );

  /// 真实账本。初始为空 —— 用户导入账单之前不应该有任何金额。
  static Ledger realLedger() => Ledger(
        id: realLedgerId,
        name: realLedgerName,
        isDemo: false,
        createdAtMs: createdAtMs,
        timeZone: StatisticsTime.timeZone,
      );

  /// 指南 10.1 的 6 笔基准，按**时间倒序**（也就是主队列的默认顺序）。
  static const List<BaselineEntry> baseline = <BaselineEntry>[
    BaselineEntry(
      merchant: 'MANNER COFFEE',
      amountCents: 2800,
      sourceNamespace: LedgerSource.wechat,
      sourceTransactionId: 'wx-20260923-0001',
      day: 23,
      hour: 14,
      minute: 26,
      suggestedCategoryId: SeedCategoryIds.food,
    ),
    BaselineEntry(
      merchant: '优衣库 UNIQLO',
      amountCents: 29900,
      sourceNamespace: LedgerSource.alipay,
      sourceTransactionId: 'ali-20260922-0007',
      day: 22,
      hour: 18,
      minute: 9,
      suggestedCategoryId: SeedCategoryIds.shopping,
    ),
    BaselineEntry(
      merchant: '滴滴出行',
      amountCents: 3650,
      sourceNamespace: LedgerSource.wechat,
      sourceTransactionId: 'wx-20260922-0004',
      day: 22,
      hour: 9,
      minute: 10,
      suggestedCategoryId: SeedCategoryIds.transport,
    ),
    BaselineEntry(
      merchant: '盒马鲜生',
      amountCents: 12680,
      sourceNamespace: LedgerSource.alipay,
      sourceTransactionId: 'ali-20260921-0011',
      day: 21,
      hour: 19,
      minute: 5,
      suggestedCategoryId: SeedCategoryIds.food,
    ),
    BaselineEntry(
      merchant: '周末电影',
      amountCents: 7800,
      sourceNamespace: LedgerSource.alipay,
      sourceTransactionId: 'ali-20260920-0003',
      day: 20,
      hour: 16,
      minute: 30,
      suggestedCategoryId: SeedCategoryIds.entertainment,
    ),
    BaselineEntry(
      merchant: '社区药房',
      amountCents: 6500,
      sourceNamespace: LedgerSource.wechat,
      sourceTransactionId: 'wx-20260919-0008',
      day: 19,
      hour: 11,
      minute: 16,
      suggestedCategoryId: SeedCategoryIds.health,
    ),
  ];

  /// 全部归类后的总消费（分）：63330。
  static const int baselineTotalCents = 63330;

  /// 全部归类后的餐饮净额（分）：2800 + 12680 = 15480。
  static const int baselineFoodCents = 15480;

  /// 消费笔数：6。拆成两类仍算一笔，退款不增加笔数。
  static const int baselineExpenseCount = 6;

  /// 8 个内置一级分类 + 2 个自定义分类 + 餐饮下的 5 个细分用途。
  ///
  /// 「其他」用默认叶片图标：图标库里没有 `more` 这个键，
  /// 之前的样例数据写了 `more` 并静默回退成叶片，这里直接用回退结果，不再铺一个无效键。
  static List<Category> categories() => <Category>[
        const Category(
          id: SeedCategoryIds.food,
          name: '餐饮',
          iconType: CategoryIconType.builtin,
          iconKey: 'food',
          sortOrder: 1,
          isBuiltin: true,
        ),
        const Category(
          id: SeedCategoryIds.shopping,
          name: '购物',
          iconType: CategoryIconType.builtin,
          iconKey: 'bag',
          sortOrder: 2,
          isBuiltin: true,
        ),
        const Category(
          id: SeedCategoryIds.transport,
          name: '交通',
          iconType: CategoryIconType.builtin,
          iconKey: 'car',
          sortOrder: 3,
          isBuiltin: true,
        ),
        const Category(
          id: SeedCategoryIds.housing,
          name: '居住',
          iconType: CategoryIconType.builtin,
          iconKey: 'home',
          sortOrder: 4,
          isBuiltin: true,
        ),
        const Category(
          id: SeedCategoryIds.entertainment,
          name: '娱乐',
          iconType: CategoryIconType.builtin,
          iconKey: 'play',
          sortOrder: 5,
          isBuiltin: true,
        ),
        const Category(
          id: SeedCategoryIds.health,
          name: '健康',
          iconType: CategoryIconType.builtin,
          iconKey: 'heart',
          sortOrder: 6,
          isBuiltin: true,
        ),
        const Category(
          id: SeedCategoryIds.social,
          name: '人情',
          iconType: CategoryIconType.builtin,
          iconKey: 'gift',
          sortOrder: 7,
          isBuiltin: true,
        ),
        const Category(
          id: SeedCategoryIds.other,
          name: '其他',
          iconType: CategoryIconType.builtin,
          iconKey: 'leaf',
          sortOrder: 8,
          isBuiltin: true,
        ),
        const Category(
          id: SeedCategoryIds.pets,
          name: '宠物',
          iconType: CategoryIconType.builtin,
          iconKey: 'heart',
          sortOrder: 9,
          isBuiltin: false,
        ),
        const Category(
          id: SeedCategoryIds.study,
          name: '学习成长',
          iconType: CategoryIconType.builtin,
          iconKey: 'file',
          sortOrder: 10,
          isBuiltin: false,
        ),
        const Category(
          id: SeedCategoryIds.diningMeals,
          parentId: SeedCategoryIds.food,
          name: '日常三餐',
          iconType: CategoryIconType.builtin,
          iconKey: 'food',
          sortOrder: 1,
          isBuiltin: true,
        ),
        const Category(
          id: SeedCategoryIds.diningCoffee,
          parentId: SeedCategoryIds.food,
          name: '咖啡茶饮',
          iconType: CategoryIconType.builtin,
          iconKey: 'coffee',
          sortOrder: 2,
          isBuiltin: true,
        ),
        const Category(
          id: SeedCategoryIds.diningSnack,
          parentId: SeedCategoryIds.food,
          name: '水果零食',
          iconType: CategoryIconType.builtin,
          iconKey: 'food',
          sortOrder: 3,
          isBuiltin: true,
        ),
        const Category(
          id: SeedCategoryIds.diningGathering,
          parentId: SeedCategoryIds.food,
          name: '聚餐',
          iconType: CategoryIconType.builtin,
          iconKey: 'food',
          sortOrder: 4,
          isBuiltin: true,
        ),
        const Category(
          id: SeedCategoryIds.diningGroceries,
          parentId: SeedCategoryIds.food,
          name: '买菜',
          iconType: CategoryIconType.builtin,
          iconKey: 'food',
          sortOrder: 5,
          isBuiltin: true,
        ),
      ];

  /// 6 笔基准记录，全部为 `PENDING` 且没有任何分配 —— 必须由用户整理。
  static List<LedgerTransaction> baselineTransactions() => <LedgerTransaction>[
        for (var index = 0; index < baseline.length; index++)
          _transactionOf(baseline[index], index + 1),
      ];

  /// 交易 ID 从 1 开始，与 [transactionIdAt] 的约定一致。
  static const int _firstTransactionId = 1;

  static LedgerTransaction _transactionOf(BaselineEntry entry, int id) =>
      LedgerTransaction(
        id: _firstTransactionId + id - 1,
        ledgerId: demoLedgerId,
        occurredAtMs: StatisticsTime.epochMsFor(2026, 9, entry.day, entry.hour, entry.minute),
        amountCents: entry.amountCents,
        merchant: entry.merchant,
        nature: TransactionNature.expense,
        reviewStatus: ReviewStatus.pending,
        timeZone: StatisticsTime.timeZone,
        sourceNamespace: entry.sourceNamespace,
        sourceTransactionId: entry.sourceTransactionId,
        rawTimeText: '09.${entry.day.toString().padLeft(2, '0')} '
            '${entry.hour.toString().padLeft(2, '0')}:'
            '${entry.minute.toString().padLeft(2, '0')}',
      );

  /// 基准里第 [index] 笔（0 起）的稳定交易 ID。
  static int transactionIdAt(int index) => _firstTransactionId + index;
}
