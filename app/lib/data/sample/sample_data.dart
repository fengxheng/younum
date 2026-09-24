/// 视觉走查阶段的样例数据。
///
/// ⚠️ 这里的所有数字都是**设计稿里的视觉样例**，不是业务结果。
///
/// 实现指南 9-阶段 1 与 1.3 明确允许「先用假数据搭布局」，但要求阶段结束时把
/// 承诺的真实逻辑接通。因此：
/// * 本文件存在的唯一目的是让 33 个设计状态有可信的排版内容；
/// * 阶段 2 起，首页 / 月报 / 明细 / 趋势的每一个数字都必须改为数据库查询结果；
/// * 演示账本与真实账本必须隔离，交互演示只能进入独立账本（指南 1.3）。
///
/// 检索 `SampleData` 即可列出所有待替换的调用点。
library;

import '../../core/money/money.dart';

/// 样例分类。
class SampleCategory {
  const SampleCategory({required this.name, required this.iconKey, required this.amountCents});

  final String name;
  final String iconKey;

  /// 本月该分类的净额（分）。仅用于走查排版。
  final int amountCents;
}

/// 一条样例交易。
class SampleTransaction {
  const SampleTransaction({
    required this.id,
    required this.merchant,
    required this.amountCents,
    required this.dateText,
    required this.source,
    required this.categoryName,
  });

  /// 稳定 ID。UI 绑定的是它，而不是列表下标（指南 14.2）。
  final String id;

  final String merchant;
  final int amountCents;

  /// 形如 `09.23 · 14:26`。
  final String dateText;

  final String source;
  final String categoryName;
}

/// 账单来源汇总行。
class SampleSource {
  const SampleSource({
    required this.name,
    required this.iconKey,
    required this.rangeText,
    required this.count,
    required this.amountCents,
    required this.tileTone,
  });

  final String name;
  final String iconKey;
  final String rangeText;
  final int count;
  final int amountCents;

  /// `neutral` / `blue` / `purple`，对应原型的图标底色。
  final String tileTone;
}

/// 一个月的样例汇总。
class SampleMonth {
  const SampleMonth({
    required this.totalCents,
    required this.transactionCount,
    required this.sourceCount,
    required this.doneCount,
    required this.remainingCount,
  });

  final int totalCents;
  final int transactionCount;
  final int sourceCount;
  final int doneCount;
  final int remainingCount;

  int get progressPercent =>
      transactionCount == 0 ? 0 : (doneCount * 100 / transactionCount).round();

  /// 0–1 的整理进度，直接供进度条使用。
  double get progress =>
      transactionCount == 0 ? 0 : doneCount / transactionCount;
}

abstract final class SampleData {
  /// 走查使用的月份展示文案。
  static const String monthLabel = '2026年9月';
  static const String shortMonthLabel = '9月';

  // ---------------------------------------------------------------------------
  // 整理流程：实现指南 10.1 的 6 笔固定基准
  // ---------------------------------------------------------------------------

  /// 演示账本的 6 笔记录。金额与指南 10.1 的基准完全一致，
  /// 归类完成后总消费应为 63330 分 / ¥633.30。
  static const List<SampleTransaction> reviewQueue = <SampleTransaction>[
    SampleTransaction(
      id: 'tx-01',
      merchant: 'MANNER COFFEE',
      amountCents: 2800,
      dateText: '09.23 · 14:26',
      source: '微信支付',
      categoryName: '餐饮',
    ),
    SampleTransaction(
      id: 'tx-02',
      merchant: '优衣库 UNIQLO',
      amountCents: 29900,
      dateText: '09.22 · 18:09',
      source: '支付宝',
      categoryName: '购物',
    ),
    SampleTransaction(
      id: 'tx-03',
      merchant: '滴滴出行',
      amountCents: 3650,
      dateText: '09.22 · 09:10',
      source: '微信支付',
      categoryName: '交通',
    ),
    SampleTransaction(
      id: 'tx-04',
      merchant: '盒马鲜生',
      amountCents: 12680,
      dateText: '09.21 · 19:05',
      source: '支付宝',
      categoryName: '餐饮',
    ),
    SampleTransaction(
      id: 'tx-05',
      merchant: '周末电影',
      amountCents: 7800,
      dateText: '09.20 · 16:30',
      source: '支付宝',
      categoryName: '娱乐',
    ),
    SampleTransaction(
      id: 'tx-06',
      merchant: '社区药房',
      amountCents: 6500,
      dateText: '09.19 · 11:16',
      source: '微信支付',
      categoryName: '健康',
    ),
  ];

  /// 演示账本的固定基准总额：6 笔全部归类后应为 63330 分。
  static const int reviewBaselineTotalCents = 63330;

  /// 稍后队列的样例（主队列之外独立存在）。
  static const List<SampleTransaction> deferredQueue = <SampleTransaction>[
    SampleTransaction(
      id: 'tx-d1',
      merchant: '个人收款码',
      amountCents: 5600,
      dateText: '09.18 · 12:08',
      source: '微信支付',
      categoryName: '待整理',
    ),
    SampleTransaction(
      id: 'tx-d2',
      merchant: '线下商户',
      amountCents: 12000,
      dateText: '09.16 · 20:13',
      source: '支付宝',
      categoryName: '待整理',
    ),
    SampleTransaction(
      id: 'tx-d3',
      merchant: '朋友转账',
      amountCents: 20000,
      dateText: '09.12 · 18:06',
      source: '微信支付',
      categoryName: '待整理',
    ),
  ];

  // ---------------------------------------------------------------------------
  // 首页与月报的月度汇总
  // ---------------------------------------------------------------------------

  static const SampleMonth month = SampleMonth(
    totalCents: 843260,
    transactionCount: 128,
    sourceCount: 2,
    doneCount: 86,
    remainingCount: 42,
  );

  static const List<SampleSource> sources = <SampleSource>[
    SampleSource(
      name: '微信支付',
      iconKey: 'wallet',
      rangeText: '9月1日—9月30日 · 76 笔',
      count: 76,
      amountCents: 482620,
      tileTone: 'neutral',
    ),
    SampleSource(
      name: '支付宝',
      iconKey: 'wallet',
      rangeText: '9月1日—9月30日 · 52 笔',
      count: 52,
      amountCents: 360640,
      tileTone: 'blue',
    ),
  ];

  // ---------------------------------------------------------------------------
  // 分类
  // ---------------------------------------------------------------------------

  /// 8 个内置分类。金额之和等于 [month] 的总额（守恒关系，指南 3.4）。
  static const List<SampleCategory> categories = <SampleCategory>[
    SampleCategory(name: '餐饮', iconKey: 'food', amountCents: 124960),
    SampleCategory(name: '购物', iconKey: 'bag', amountCents: 189900),
    SampleCategory(name: '交通', iconKey: 'car', amountCents: 46800),
    SampleCategory(name: '居住', iconKey: 'home', amountCents: 320000),
    SampleCategory(name: '娱乐', iconKey: 'play', amountCents: 39800),
    SampleCategory(name: '健康', iconKey: 'heart', amountCents: 36000),
    SampleCategory(name: '人情', iconKey: 'gift', amountCents: 23800),
    SampleCategory(name: '其他', iconKey: 'more', amountCents: 62000),
  ];

  /// 「我的分类」里的自定义分类。图标可被用户替换（指南 14.3）。
  static const List<String> customCategoryNames = <String>['宠物', '学习成长'];

  /// 餐饮下的细分用途。
  static const List<String> diningSubcategories = <String>[
    '日常三餐',
    '咖啡茶饮',
    '水果零食',
    '聚餐',
    '买菜',
  ];

  /// 按分类名取图标键，未知分类回退到叶片。
  static String iconKeyFor(String categoryName) {
    for (final category in categories) {
      if (category.name == categoryName) return category.iconKey;
    }
    return 'leaf';
  }

  /// 按分类名取金额（分）。
  static int amountFor(String categoryName) {
    for (final category in categories) {
      if (category.name == categoryName) return category.amountCents;
    }
    return 0;
  }

  // ---------------------------------------------------------------------------
  // 趋势
  // ---------------------------------------------------------------------------

  /// 近 6 个月消费（分）。4–9 月。
  static const List<int> recentMonthsCents = <int>[
    720000,
    860000,
    790000,
    910000,
    967040,
    843260,
  ];

  static const int firstTrendMonth = 4;

  static const String dayAverageText = '¥281.09';
  static const String highestSingleText = '¥3,200.00 · 房租';
  static const String lowestDayText = '9月7日 · ¥0.00';
  static const String monthOverMonthText = '比上月少 12.8%';
  static const String monthOverMonthDeltaText = '比上月减少 ¥1,237.80';

  /// 「这个月的发现」段落文案，直接沿用原型语气。
  static const List<String> insights = <String>[
    '居住占比最高；餐饮比上月少 ¥216.40。',
    '日常的小选择，也在慢慢改变。',
  ];

  // ---------------------------------------------------------------------------
  // 导入流程
  // ---------------------------------------------------------------------------

  static const int importedRecordCount = 146;
  static const int importNewExpenseCount = 128;
  static const String importRangeText = '2026.09.01 — 09.30';
  static const int duplicateGroupCount = 4;
  static const int incomeRecordCount = 8;
  static const int transferRecordCount = 6;
  static const int invalidRowCount = 3;

  // ---------------------------------------------------------------------------
  // 导入记录
  // ---------------------------------------------------------------------------

  static const List<SampleImportBatch> importBatches = <SampleImportBatch>[
    SampleImportBatch(
      name: '微信支付账单',
      fileName: '微信支付账单_202609.csv',
      fileSizeText: '32 KB',
      importedAtText: '2026.09.24 10:32',
      newCount: 76,
      excludedDuplicateCount: 4,
      amountCents: 482620,
    ),
    SampleImportBatch(
      name: '支付宝账单',
      fileName: '支付宝账单_202609.csv',
      fileSizeText: '28 KB',
      importedAtText: '2026.09.24 10:35',
      newCount: 52,
      excludedDuplicateCount: 0,
      amountCents: 360640,
    ),
  ];

  /// 已记录的月份数，用于「我的」页头像说明。
  static const int recordedMonthCount = 6;
}

/// 一条导入批次记录。
class SampleImportBatch {
  const SampleImportBatch({
    required this.name,
    required this.fileName,
    required this.fileSizeText,
    required this.importedAtText,
    required this.newCount,
    required this.excludedDuplicateCount,
    required this.amountCents,
  });

  final String name;
  final String fileName;
  final String fileSizeText;
  final String importedAtText;
  final int newCount;
  final int excludedDuplicateCount;
  final int amountCents;

  String get amountText => '¥${Money.format(amountCents, grouped: true)}';
}
