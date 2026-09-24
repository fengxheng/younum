import 'package:flutter_test/flutter_test.dart';
import 'package:younum/core/time/statistics_time.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/allocation.dart';
import 'package:younum/domain/models/ledger_transaction.dart';
import 'package:younum/domain/models/year_month.dart';
import 'package:younum/domain/rules/month_insights.dart';

import 'support/ledger_fixtures.dart';

/// 月度洞察与趋势。
///
/// 重点验证指南 3.4 里三条容易被做错的规则：
/// 日均的分母、环比的前提条件、以及「不伪造缺失月份」。
void main() {
  final august = YearMonth(2026, 8);
  final september = YearMonth(2026, 9);

  /// 8 月两笔：餐饮 100 元 + 购物 200 元 = 30000 分。
  List<LedgerTransaction> augustTransactions({int amountCents = 10000, int day = 10}) =>
      <LedgerTransaction>[
        LedgerTransaction(
          id: 201,
          ledgerId: DemoLedgerSeed.demoLedgerId,
          occurredAtMs: StatisticsTime.epochMsFor(2026, 8, day, 12),
          amountCents: amountCents,
          merchant: '8月餐饮',
          nature: TransactionNature.expense,
          reviewStatus: ReviewStatus.resolved,
          timeZone: StatisticsTime.timeZone,
        ),
        LedgerTransaction(
          id: 202,
          ledgerId: DemoLedgerSeed.demoLedgerId,
          occurredAtMs: StatisticsTime.epochMsFor(2026, 8, day + 1, 12),
          amountCents: 20000,
          merchant: '8月购物',
          nature: TransactionNature.expense,
          reviewStatus: ReviewStatus.resolved,
          timeZone: StatisticsTime.timeZone,
        ),
      ];

  List<Allocation> augustAllocations() => <Allocation>[
        const Allocation(
          id: 201,
          transactionId: 201,
          categoryId: SeedCategoryIds.food,
          amountCents: 10000,
        ),
        const Allocation(
          id: 202,
          transactionId: 202,
          categoryId: SeedCategoryIds.shopping,
          amountCents: 20000,
        ),
      ];

  /// 9 月基准全部归类 + 可选的 8 月数据。
  MonthReport buildReport({
    bool withAugust = true,
    Set<YearMonth> confirmed = const <YearMonth>{},
    List<LedgerTransaction> extra = const <LedgerTransaction>[],
  }) {
    final base = resolvedBaseline();
    return MonthReports.build(
      month: september,
      dataset: buildDataset(
        transactions: <LedgerTransaction>[
          ...base.transactions,
          if (withAugust) ...augustTransactions(),
          ...extra,
        ],
        allocations: <Allocation>[
          ...base.allocations,
          if (withAugust) ...augustAllocations(),
        ],
      ),
      isDemoLedger: true,
      coverageConfirmed: confirmed,
    );
  }

  group('日均', () {
    test('范围已确认完整时按当月自然日数', () {
      final report = buildReport(confirmed: <YearMonth>{september});
      final insights = report.insights;

      expect(insights.averageUsesFullMonth, isTrue);
      expect(insights.averageDenominatorDays, 30, reason: '9 月有 30 天');
      // 63330 / 30 = 2111
      expect(insights.dayAverageCents, 2111);
    });

    test('范围未确认时按已覆盖天数，并把分母交出来', () {
      final report = buildReport();
      final insights = report.insights;

      expect(insights.averageUsesFullMonth, isFalse);
      // 9 月基准最晚的一笔在 23 日，因此覆盖到 23 天。
      expect(insights.averageDenominatorDays, 23, reason: '不能仍除以 30');
      expect(insights.dayAverageCents, (63330 / 23).round());
      expect(insights.dayAverageCents, 2753);
    });

    test('没有消费时不给日均', () {
      final report = MonthReports.build(
        month: september,
        dataset: buildDataset(transactions: pendingBaseline()),
        isDemoLedger: true,
      );
      expect(report.insights.dayAverageCents, isNull);
    });
  });

  group('单笔最高与最低消费日', () {
    test('单笔最高取归类金额最大的那一笔，并带上分类', () {
      final report = buildReport(confirmed: <YearMonth>{september});
      final insights = report.insights;

      expect(insights.highestSingle?.merchant, '优衣库 UNIQLO');
      expect(insights.highestSingle?.amountCents, 29900);
      expect(insights.highestSingleCategoryName, '购物');
    });

    test('最低消费日在**有消费的日子**里比较，不拿没消费的日子凑数', () {
      final report = buildReport(confirmed: <YearMonth>{september});
      final insights = report.insights;

      // 9 月基准里最少的一天是 23 日的 MANNER 28.00。
      expect(insights.lowestSpendingDay?.day, 23);
      expect(insights.lowestSpendingDay?.expenseCents, 2800);
      expect(insights.lowestSpendingDay?.count, 1);
    });

    test('未整理的记录不进入单笔最高', () {
      final base = resolvedBaseline();
      final report = MonthReports.build(
        month: september,
        dataset: buildDataset(
          transactions: <LedgerTransaction>[
            ...base.transactions,
            // 一笔很大的、还没整理的消费。
            pendingBaseline().first.copyWith(id: 300, amountCents: 999999),
          ],
          allocations: base.allocations,
        ),
        isDemoLedger: true,
      );
      expect(report.insights.highestSingle?.amountCents, 29900);
    });
  });

  group('环比', () {
    test('两个月都完整且上月大于零时给出百分比与差额', () {
      final report = buildReport(
        confirmed: <YearMonth>{august, september},
      );
      final insights = report.insights;

      expect(insights.previousNetExpenseCents, 30000);
      expect(insights.monthOverMonthDeltaCents, 33330);
      // 33330 / 30000 = 111.1%
      expect(insights.monthOverMonthBasisPoints, 11110);
      expect(insights.canShowMonthOverMonthPercent, isTrue);
    });

    test('上月为零时只给金额差，不给百分比（避免「无限增长」）', () {
      final base = resolvedBaseline();
      final report = MonthReports.build(
        month: september,
        dataset: buildDataset(
          transactions: <LedgerTransaction>[
            ...base.transactions,
            // 8 月有记录，但一笔都没确认归类 → 净消费为 0。
            ...augustTransactions().map(
              (transaction) => transaction.copyWith(
                reviewStatus: ReviewStatus.pending,
              ),
            ),
          ],
          allocations: base.allocations,
        ),
        isDemoLedger: true,
        coverageConfirmed: <YearMonth>{august, september},
      );

      expect(report.insights.previousNetExpenseCents, 0);
      expect(report.insights.canShowMonthOverMonthDelta, isTrue);
      expect(report.insights.monthOverMonthDeltaCents, 63330);
      expect(report.insights.canShowMonthOverMonthPercent, isFalse);
      expect(report.insights.monthOverMonthBasisPoints, isNull);
    });

    test('上月没确认范围完整时完全不比较', () {
      final report = buildReport(confirmed: <YearMonth>{september});
      expect(report.insights.previousIsComplete, isFalse);
      expect(report.insights.canShowMonthOverMonthDelta, isFalse);
      expect(report.insights.monthOverMonthBasisPoints, isNull);
    });

    test('本月没确认时也不比较', () {
      final report = buildReport(confirmed: <YearMonth>{august});
      expect(report.insights.canShowMonthOverMonthDelta, isFalse);
    });
  });

  group('分类变化', () {
    test('两个月都完整时给出变化最大的几项', () {
      final report = buildReport(confirmed: <YearMonth>{august, september});
      final changes = report.insights.categoryChanges;

      // 购物 29900 - 20000 = 9900 是变动最大的一项。
      // 变化项共有 5 个（交通 / 娱乐 / 健康 在上月为 0），按绝对变动截前 3 条。
      expect(changes, hasLength(3));
      expect(changes.first.categoryName, '购物');
      expect(changes.first.deltaCents, 9900);
      expect(changes.first.isIncrease, isTrue);

      // 按绝对变动降序。
      for (var index = 1; index < changes.length; index++) {
        expect(
          changes[index - 1].deltaCents.abs(),
          greaterThanOrEqualTo(changes[index].deltaCents.abs()),
        );
      }

      // 餐饮只多了 5480，排在第 4 位，被截掉了 —— 这里顺便固定住「最多 3 条」。
      expect(
        changes.any((change) => change.categoryName == '餐饮'),
        isFalse,
      );
    });

    test('缺少可比月份时不给分类变化', () {
      final report = buildReport(confirmed: <YearMonth>{september});
      expect(report.insights.categoryChanges, isEmpty);
    });
  });

  group('趋势窗口', () {
    test('窗口包含当前月在内的连续 6 个月，空月份也保留', () {
      final report = buildReport();
      expect(report.trend, hasLength(6));
      expect(
        report.trend.map((point) => point.month.toIso()).toList(),
        <String>['2026-04', '2026-05', '2026-06', '2026-07', '2026-08', '2026-09'],
      );
      // 空月份不伪造金额，但也要能被识别出来。
      final april = report.trend.first;
      expect(april.netExpenseCents, 0);
      expect(april.hasRecords, isFalse);
      expect(report.trend.last.hasRecords, isTrue);
    });

    test('峰值用于图表缩放', () {
      final report = buildReport();
      expect(report.trendPeakCents, 63330);
    });

    test('有记录的月份按时间倒序', () {
      final report = buildReport();
      expect(
        report.recordedMonths.map((month) => month.toIso()).toList(),
        <String>['2026-09', '2026-08'],
      );
    });
  });

  group('任意月份查询', () {
    test('overviewOf 按需算出目标月份的数字', () {
      final report = buildReport(confirmed: <YearMonth>{august, september});

      final augustSummary = report.overviewOf(august).summary;
      expect(augustSummary.netExpenseCents, 30000);
      expect(augustSummary.expenseCount, 2);
      expect(report.overviewOf(august).progress.coverageConfirmed, isTrue);

      // 完全没有记录的月份不给任何金额。
      final july = report.overviewOf(YearMonth(2026, 7));
      expect(july.summary.hasRecords, isFalse);
      expect(july.summary.netExpenseCents, 0);
      expect(july.summary.byCategory, isEmpty);
      expect(report.hasRecordsOf(YearMonth(2026, 7)), isFalse);
    });
  });

  group('这个月的发现', () {
    test('文案由数字生成，不写死', () {
      final report = buildReport(confirmed: <YearMonth>{august, september});
      final findings = report.insights.findings;

      // 购物净额最高（29900 / 63330 = 47.2%）。
      expect(findings.first, contains('购物'));
      expect(findings.first, contains('47.2%'));
      expect(
        findings.any((line) => line.contains('这个月比上月多')),
        isTrue,
      );
      expect(findings.last, '日常的小选择，也在慢慢改变。');
    });

    test('没有消费时给一句得体的话，而不是空白', () {
      final report = MonthReports.build(
        month: september,
        dataset: buildDataset(transactions: pendingBaseline()),
        isDemoLedger: true,
      );
      expect(report.insights.findings.first, contains('记录还不多'));
    });
  });
}
