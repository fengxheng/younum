import 'package:flutter_test/flutter_test.dart';
import 'package:younum/data/seed/demo_ledger_seed.dart';
import 'package:younum/domain/models/allocation.dart';
import 'package:younum/domain/models/ledger_transaction.dart';
import 'package:younum/domain/models/year_month.dart';
import 'package:younum/domain/rules/monthly_stats.dart';
import 'package:younum/domain/rules/review_progress.dart';

import 'support/ledger_fixtures.dart';

/// 实现指南 10.1「固定金额基准」。
///
/// 这份基准是跨阶段验收的锚点，任何改动都必须让这里的断言继续成立。
void main() {
  final september = YearMonth(2026, 9);
  final october = YearMonth(2026, 10);

  group('10.1 固定金额基准', () {
    test('6 笔全部归类后：总消费 63330 分、餐饮 15480 分、笔数 6', () {
      final summary = MonthlyStats.compute(
        month: september,
        dataset: resolvedBaseline(),
      );

      expect(summary.netExpenseCents, DemoLedgerSeed.baselineTotalCents);
      expect(summary.netExpenseCents, 63330);
      expect(summary.expenseCents, 63330);
      expect(summary.refundCents, 0);
      expect(summary.expenseCount, DemoLedgerSeed.baselineExpenseCount);
      expect(summary.expenseCount, 6);

      final food = summary.byCategory
          .firstWhere((category) => category.categoryId == foodCategoryId);
      expect(food.netCents, DemoLedgerSeed.baselineFoodCents);
      expect(food.netCents, 15480);
    });

    test('分类净额之和等于总净消费（守恒）', () {
      final summary = MonthlyStats.compute(
        month: september,
        dataset: resolvedBaseline(),
      );
      expect(summary.categoryNetTotalCents, summary.netExpenseCents);
      expect(summary.isCategoryBreakdownComplete, isTrue);
      expect(summary.issues, isEmpty);
    });

    test('拆盒马为 餐饮 8680 + 购物 4000：总额不变、分类变化、笔数仍为 6', () {
      final summary = MonthlyStats.compute(
        month: september,
        dataset: baselineWithHemaSplit(),
      );

      expect(summary.netExpenseCents, 63330);
      expect(summary.expenseCount, 6);

      final food = summary.byCategory
          .firstWhere((category) => category.categoryId == foodCategoryId);
      final shopping = summary.byCategory
          .firstWhere((category) => category.categoryId == shoppingCategoryId);
      expect(food.netCents, 11480);
      expect(shopping.netCents, 33900);
      expect(summary.categoryNetTotalCents, 63330);
    });

    test('未整理的消费不计入月度概况', () {
      final summary = MonthlyStats.compute(
        month: september,
        dataset: buildDataset(transactions: pendingBaseline()),
      );

      expect(summary.netExpenseCents, 0);
      expect(summary.expenseCount, 0);
      // 但本月确实有记录，所以不是「空月份」。
      expect(summary.hasRecords, isTrue);
      expect(summary.hasExpense, isFalse);
    });

    test('「已导入」与「已确认归类」是两个口径，不互相冒充', () {
      final pending = MonthlyStats.compute(
        month: september,
        dataset: buildDataset(transactions: pendingBaseline()),
      );

      // 一笔都没整理：已确认消费为 0，但账单里确实有 63330 分。
      expect(pending.expenseCents, 0);
      expect(pending.importedExpenseCents, 63330);
      expect(pending.importedExpenseCount, 6);

      // 全部整理完：两个口径一致。
      final resolved = MonthlyStats.compute(
        month: september,
        dataset: resolvedBaseline(),
      );
      expect(resolved.expenseCents, resolved.importedExpenseCents);
      expect(resolved.expenseCount, resolved.importedExpenseCount);
    });

    test('无记录的月份不显示任何金额', () {
      final summary = MonthlyStats.compute(
        month: YearMonth(2026, 8),
        dataset: resolvedBaseline(),
      );

      expect(summary.hasRecords, isFalse);
      expect(summary.netExpenseCents, 0);
      expect(summary.byCategory, isEmpty);
      // 总额为零时不能给出占比。
      expect(summary.shareBasisPointsOf(foodCategoryId), isNull);
    });
  });

  group('10.1 跨月退款', () {
    /// 10 月 5 日发生、关联 9 月优衣库的 10000 分退款。
    ({List<LedgerTransaction> transactions, List<RefundLink> links}) crossMonthRefund({
      int amountCents = 10000,
    }) {
      final refund = refundTransaction(
        id: 101,
        amountCents: amountCents,
        year: 2026,
        month: 10,
        day: 5,
        merchant: '优衣库退款',
      );
      return (
        transactions: <LedgerTransaction>[refund],
        links: <RefundLink>[
          RefundLink(
            id: 1,
            refundTransactionId: 101,
            originalTransactionId: uniqloTransactionId,
            amountCents: amountCents,
          ),
        ],
      );
    }

    test('9 月净消费变为 53330 分，退款归回原消费月份', () {
      final refund = crossMonthRefund();
      final dataset = resolvedBaseline(
        extraTransactions: refund.transactions,
        refundLinks: refund.links,
      );

      final septemberSummary =
          MonthlyStats.compute(month: september, dataset: dataset);
      expect(septemberSummary.expenseCents, 63330);
      expect(septemberSummary.refundCents, 10000);
      expect(septemberSummary.netExpenseCents, 53330);
      // 退款不增加消费笔数。
      expect(septemberSummary.expenseCount, 6);
      // 抵扣落在优衣库那条分配所属的分类上。
      final shopping = septemberSummary.byCategory
          .firstWhere((category) => category.categoryId == shoppingCategoryId);
      expect(shopping.netCents, 19900);
      expect(septemberSummary.categoryNetTotalCents, 53330);
    });

    test('10 月消费不因这笔退款变为负数', () {
      final refund = crossMonthRefund();
      final dataset = resolvedBaseline(
        extraTransactions: refund.transactions,
        refundLinks: refund.links,
      );

      final octoberSummary =
          MonthlyStats.compute(month: october, dataset: dataset);
      expect(octoberSummary.netExpenseCents, 0);
      expect(octoberSummary.refundCents, 0);
      expect(octoberSummary.expenseCount, 0);
      expect(octoberSummary.byCategory, isEmpty);
      // 10 月仍能查到这笔退款记录本身。
      expect(octoberSummary.hasRecords, isTrue);
    });

    test('拆分消费的退款按明确分配抵扣到各自的分类', () {
      final base = baselineWithHemaSplit();
      final hemaTransactionId = DemoLedgerSeed.transactionIdAt(
        DemoLedgerSeed.baseline.indexWhere((entry) => entry.merchant == '盒马鲜生'),
      );
      final hemaAllocations =
          base.allocations.where((a) => a.transactionId == hemaTransactionId).toList();
      final foodAllocation =
          hemaAllocations.firstWhere((a) => a.categoryId == foodCategoryId);
      final shoppingAllocation =
          hemaAllocations.firstWhere((a) => a.categoryId == shoppingCategoryId);

      final dataset = buildDataset(
        transactions: <LedgerTransaction>[
          ...base.transactions,
          refundTransaction(
            id: 102,
            amountCents: 4000,
            year: 2026,
            month: 9,
            day: 28,
            merchant: '盒马部分退款',
          ),
        ],
        allocations: base.allocations,
        refundLinks: <RefundLink>[
          RefundLink(
            id: 2,
            refundTransactionId: 102,
            originalTransactionId: hemaTransactionId,
            amountCents: 4000,
          ),
        ],
        refundAllocations: <RefundAllocation>[
          // 3000 抵扣购物项，1000 抵扣餐饮项 —— 两项都要被读到，
          // 否则「分配到哪个分类」可能被写死成某一个也能过。
          RefundAllocation(
            id: 1,
            refundLinkId: 2,
            originalAllocationId: shoppingAllocation.id,
            amountCents: 3000,
          ),
          RefundAllocation(
            id: 2,
            refundLinkId: 2,
            originalAllocationId: foodAllocation.id,
            amountCents: 1000,
          ),
        ],
      );

      final summary = MonthlyStats.compute(month: september, dataset: dataset);
      final food =
          summary.byCategory.firstWhere((c) => c.categoryId == foodCategoryId);
      final shopping =
          summary.byCategory.firstWhere((c) => c.categoryId == shoppingCategoryId);

      expect(food.netCents, 11480 - 1000);
      expect(shopping.netCents, 33900 - 3000);
      expect(summary.netExpenseCents, 63330 - 4000);
      expect(summary.categoryNetTotalCents, summary.netExpenseCents);
    });

    test('未完成关联的退款不参与抵扣', () {
      final refund = crossMonthRefund();
      final dataset = resolvedBaseline(
        extraTransactions: refund.transactions,
        // 没有 RefundLink —— 这笔退款还在待核对状态。
      );
      final summary = MonthlyStats.compute(month: september, dataset: dataset);
      expect(summary.netExpenseCents, 63330);
      expect(summary.refundCents, 0);
    });

    test('尚未处理完成的退款不参与抵扣', () {
      final refund = crossMonthRefund();
      final dataset = resolvedBaseline(
        extraTransactions: <LedgerTransaction>[
          refund.transactions.single.copyWith(
            reviewStatus: ReviewStatus.pending,
          ),
        ],
        refundLinks: refund.links,
      );
      final summary = MonthlyStats.compute(month: september, dataset: dataset);
      expect(summary.netExpenseCents, 63330);
    });
  });

  group('收入与转账不计入消费', () {
    test('只有收入的月份不显示消费', () {
      final dataset = buildDataset(
        transactions: <LedgerTransaction>[
          pendingBaseline().first.copyWith(
            nature: TransactionNature.income,
            reviewStatus: ReviewStatus.resolved,
          ),
        ],
      );
      final summary = MonthlyStats.compute(month: september, dataset: dataset);
      expect(summary.netExpenseCents, 0);
      expect(summary.expenseCount, 0);
      expect(summary.hasRecords, isTrue);
      expect(summary.hasExpense, isFalse);
    });

    test('转账与排除统计一样不计入消费', () {
      for (final nature in <TransactionNature>[
        TransactionNature.transfer,
        TransactionNature.excluded,
      ]) {
        final dataset = buildDataset(
          transactions: <LedgerTransaction>[
            pendingBaseline().first.copyWith(
              nature: nature,
              reviewStatus: ReviewStatus.resolved,
              excludeReason: nature == TransactionNature.excluded ? '测试用' : null,
            ),
          ],
        );
        final summary = MonthlyStats.compute(month: september, dataset: dataset);
        expect(summary.netExpenseCents, 0, reason: '$nature 不应计入消费');
      }
    });
  });

  group('数据被外部改坏时不崩，但要把问题说出来', () {
    test('已整理但没有分类分配的消费不计入，并记录问题', () {
      final dataset = buildDataset(
        transactions: <LedgerTransaction>[resolve(pendingBaseline().first)],
      );
      final summary = MonthlyStats.compute(month: september, dataset: dataset);
      expect(summary.netExpenseCents, 0);
      expect(summary.expenseCount, 0);
      expect(summary.issues, isNotEmpty);
    });

    test('分类合计与原金额不一致时以分类合计为准，保证守恒仍然成立', () {
      final dataset = buildDataset(
        transactions: <LedgerTransaction>[resolve(pendingBaseline().first)],
        allocations: <Allocation>[
          const Allocation(
            id: 1,
            transactionId: 1,
            categoryId: SeedCategoryIds.food,
            amountCents: 2700,
          ),
        ],
      );
      final summary = MonthlyStats.compute(month: september, dataset: dataset);
      expect(summary.netExpenseCents, 2700);
      expect(summary.categoryNetTotalCents, 2700);
      expect(summary.issues, isNotEmpty);
    });

    test('拆分消费的退款缺少明确分配时，占比不可用但不产生负数', () {
      final base = baselineWithHemaSplit();
      final hemaTransactionId = DemoLedgerSeed.transactionIdAt(
        DemoLedgerSeed.baseline.indexWhere((entry) => entry.merchant == '盒马鲜生'),
      );
      final dataset = buildDataset(
        transactions: <LedgerTransaction>[
          ...base.transactions,
          refundTransaction(
            id: 103,
            amountCents: 4000,
            year: 2026,
            month: 9,
            day: 28,
          ),
        ],
        allocations: base.allocations,
        refundLinks: <RefundLink>[
          RefundLink(
            id: 3,
            refundTransactionId: 103,
            originalTransactionId: hemaTransactionId,
            amountCents: 4000,
          ),
        ],
      );

      final summary = MonthlyStats.compute(month: september, dataset: dataset);
      expect(summary.netExpenseCents, 63330 - 4000);
      expect(summary.isCategoryBreakdownComplete, isFalse);
      expect(summary.unattributedRefundCents, 4000);
      expect(summary.issues, isNotEmpty);
    });
  });

  group('整理进度', () {
    test('跳过不计完成数，主队列空了但稍后队列非空时不进完成页', () {
      final transactions = <LedgerTransaction>[
        pendingBaseline().first.copyWith(reviewStatus: ReviewStatus.deferred),
        for (final transaction in pendingBaseline().skip(1))
          resolve(transaction),
      ];
      final progress = ReviewProgressRules.compute(
        month: september,
        transactions: transactions,
        coverageConfirmed: true,
      );

      expect(progress.resolvedCount, 5);
      expect(progress.deferredCount, 1);
      expect(progress.totalCount, 6);
      expect(progress.isFullyProcessed, isFalse);
      expect(progress.queueDrainedWithDeferred, isTrue);
      expect(progress.isCompleteMonth, isFalse);
    });

    test('全部处理完但范围未确认：只能算部分账单', () {
      final progress = ReviewProgressRules.compute(
        month: september,
        transactions: <LedgerTransaction>[
          for (final transaction in pendingBaseline()) resolve(transaction),
        ],
        coverageConfirmed: false,
      );

      expect(progress.isFullyProcessed, isTrue);
      expect(progress.isCompleteMonth, isFalse);
      expect(progress.isPartialMonth, isTrue);
      expect(progress.percent, 100);
    });

    test('整理进度不掺入其它月份的记录', () {
      final progress = ReviewProgressRules.compute(
        month: october,
        transactions: <LedgerTransaction>[
          for (final transaction in pendingBaseline()) resolve(transaction),
        ],
        coverageConfirmed: false,
      );
      expect(progress.totalCount, 0);
      expect(progress.ratio, 0);
    });
  });
}
