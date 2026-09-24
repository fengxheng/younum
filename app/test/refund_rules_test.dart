import 'package:flutter_test/flutter_test.dart';
import 'package:younum/domain/models/allocation.dart';
import 'package:younum/domain/models/ledger_dataset.dart';
import 'package:younum/domain/models/ledger_transaction.dart';
import 'package:younum/domain/rules/refund_rules.dart';

import 'support/ledger_fixtures.dart';

/// 实现指南 3.5 与 10.1 的退款规则。
void main() {
  /// 造一笔已处理完成的退款交易。
  LedgerTransaction refund({
    int id = 101,
    int amountCents = 10000,
    int month = 10,
    int day = 5,
  }) =>
      refundTransaction(
        id: id,
        amountCents: amountCents,
        year: 2026,
        month: month,
        day: day,
      );

  group('关联原消费', () {
    test('正常的 10000 分退款可以关联 29900 分的优衣库', () {
      final dataset = resolvedBaseline(
        extraTransactions: <LedgerTransaction>[refund()],
      );
      expect(
        RefundRules.validateLink(
          dataset: dataset,
          refundTransactionId: 101,
          originalTransactionId: uniqloTransactionId,
          amountCents: 10000,
        ),
        isNull,
      );
    });

    test('退款不能关联到自己', () {
      final dataset = resolvedBaseline(
        extraTransactions: <LedgerTransaction>[refund()],
      );
      expect(
        RefundRules.validateLink(
          dataset: dataset,
          refundTransactionId: 101,
          originalTransactionId: 101,
          amountCents: 10000,
        ),
        isA<RefundSelfReference>(),
      );
    });

    test('不能关联到收入或转账', () {
      final dataset = buildDataset(
        transactions: <LedgerTransaction>[
          resolvedBaseline().transactions.first.copyWith(
                nature: TransactionNature.income,
              ),
          refund(),
        ],
      );
      expect(
        RefundRules.validateLink(
          dataset: dataset,
          refundTransactionId: 101,
          originalTransactionId: 1,
          amountCents: 1000,
        ),
        isA<RefundOriginalNotExpense>(),
      );
    });

    test('关联金额必须大于 0', () {
      final dataset = resolvedBaseline(
        extraTransactions: <LedgerTransaction>[refund()],
      );
      expect(
        RefundRules.validateLink(
          dataset: dataset,
          refundTransactionId: 101,
          originalTransactionId: uniqloTransactionId,
          amountCents: 0,
        ),
        isA<RefundAmountNotPositive>(),
      );
    });

    test('关联金额不能超过退款本身的金额', () {
      final dataset = resolvedBaseline(
        extraTransactions: <LedgerTransaction>[refund(amountCents: 5000)],
      );
      expect(
        RefundRules.validateLink(
          dataset: dataset,
          refundTransactionId: 101,
          originalTransactionId: uniqloTransactionId,
          amountCents: 5001,
        ),
        isA<RefundExceedsRefundAmount>(),
      );
    });

    test('找不到的退款或原消费都明确失败', () {
      final dataset = resolvedBaseline(
        extraTransactions: <LedgerTransaction>[refund()],
      );
      expect(
        RefundRules.validateLink(
          dataset: dataset,
          refundTransactionId: 999,
          originalTransactionId: uniqloTransactionId,
          amountCents: 1000,
        ),
        isA<RefundTargetNotFound>(),
      );
      expect(
        RefundRules.validateLink(
          dataset: dataset,
          refundTransactionId: 101,
          originalTransactionId: 999,
          amountCents: 1000,
        ),
        isA<RefundTargetNotFound>(),
      );
    });

    test('同一笔退款再次关联必须失败（10.1「重复关联不得重复抵扣」的源头）', () {
      final dataset = resolvedBaseline(
        extraTransactions: <LedgerTransaction>[refund()],
        refundLinks: <RefundLink>[
          RefundLink(
            id: 1,
            refundTransactionId: 101,
            originalTransactionId: uniqloTransactionId,
            amountCents: 10000,
          ),
        ],
      );

      final error = RefundRules.validateLink(
        dataset: dataset,
        refundTransactionId: 101,
        originalTransactionId: uniqloTransactionId,
        amountCents: 10000,
      );
      expect(error, isA<RefundAlreadyLinked>());
      expect((error! as RefundAlreadyLinked).existingOriginalTransactionId,
          uniqloTransactionId);
    });

    test('累计抵扣超过原消费金额时明确失败，并给出剩余额度', () {
      // 优衣库 29900 已经全额被关联，再关联 100 分必须失败。
      final dataset = resolvedBaseline(
        extraTransactions: <LedgerTransaction>[refund(id: 102, amountCents: 100)],
        refundLinks: <RefundLink>[
          RefundLink(
            id: 1,
            refundTransactionId: 101,
            originalTransactionId: uniqloTransactionId,
            amountCents: 29900,
          ),
        ],
      );

      final error = RefundRules.validateLink(
        dataset: dataset,
        refundTransactionId: 102,
        originalTransactionId: uniqloTransactionId,
        amountCents: 100,
      );
      expect(error, isA<RefundExceedsOriginal>());
      expect((error! as RefundExceedsOriginal).remainingCents, 0);
    });

    test('多笔退款可以累加到原消费，但不得超过原金额', () {
      // 已关联 20000，剩 9900：关联 9900 可以，10000 不行。
      final dataset = resolvedBaseline(
        extraTransactions: <LedgerTransaction>[refund(id: 102, amountCents: 10000)],
        refundLinks: <RefundLink>[
          RefundLink(
            id: 1,
            refundTransactionId: 101,
            originalTransactionId: uniqloTransactionId,
            amountCents: 20000,
          ),
        ],
      );

      expect(
        RefundRules.validateLink(
          dataset: dataset,
          refundTransactionId: 102,
          originalTransactionId: uniqloTransactionId,
          amountCents: 9900,
        ),
        isNull,
      );

      final error = RefundRules.validateLink(
        dataset: dataset,
        refundTransactionId: 102,
        originalTransactionId: uniqloTransactionId,
        amountCents: 10000,
      );
      expect((error! as RefundExceedsOriginal).remainingCents, 9900);
    });
  });

  group('退款分配', () {
    test('单分类消费不需要明确分配', () {
      final dataset = resolvedBaseline(
        extraTransactions: <LedgerTransaction>[refund()],
      );
      expect(
        RefundRules.validateRefundAllocations(
          dataset: dataset,
          refundTransactionId: 101,
          originalTransactionId: uniqloTransactionId,
          refundAmountCents: 10000,
          drafts: const <RefundAllocationDraft>[],
        ),
        isNull,
      );
    });

    test('拆分消费不给出分配就失败', () {
      final base = baselineWithHemaSplit();
      final hemaTransactionId = 4;
      final dataset = buildDataset(
        transactions: <LedgerTransaction>[
          ...base.transactions,
          refund(id: 103, amountCents: 4000, month: 9, day: 28),
        ],
        allocations: base.allocations,
      );

      expect(
        RefundRules.validateRefundAllocations(
          dataset: dataset,
          refundTransactionId: 103,
          originalTransactionId: hemaTransactionId,
          refundAmountCents: 4000,
          drafts: const <RefundAllocationDraft>[],
        ),
        isA<RefundAllocationRequired>(),
      );
    });

    test('退款分配合计必须精确等于退款金额', () {
      final base = baselineWithHemaSplit();
      final hemaTransactionId = 4;
      final dataset = buildDataset(
        transactions: <LedgerTransaction>[
          ...base.transactions,
          refund(id: 103, amountCents: 4000, month: 9, day: 28),
        ],
        allocations: base.allocations,
      );

      final error = RefundRules.validateRefundAllocations(
        dataset: dataset,
        refundTransactionId: 103,
        originalTransactionId: hemaTransactionId,
        refundAmountCents: 4000,
        drafts: const <RefundAllocationDraft>[
          RefundAllocationDraft(originalAllocationId: 100, amountCents: 3000),
          RefundAllocationDraft(originalAllocationId: 101, amountCents: 999),
        ],
      );

      expect(error, isA<RefundAllocationSumMismatch>());
      expect((error! as RefundAllocationSumMismatch).differenceCents, 1);
    });

    test('单项抵扣不能超过该拆分项自己的金额', () {
      final base = baselineWithHemaSplit();
      final hemaTransactionId = 4;
      final dataset = buildDataset(
        transactions: <LedgerTransaction>[
          ...base.transactions,
          refund(id: 103, amountCents: 5000, month: 9, day: 28),
        ],
        allocations: base.allocations,
      );

      // 购物项只有 4000，却要抵扣 5000。
      final error = RefundRules.validateRefundAllocations(
        dataset: dataset,
        refundTransactionId: 103,
        originalTransactionId: hemaTransactionId,
        refundAmountCents: 5000,
        drafts: const <RefundAllocationDraft>[
          RefundAllocationDraft(originalAllocationId: 101, amountCents: 5000),
        ],
      );

      expect(error, isA<RefundAllocationExceedsOriginalItem>());
      expect(
        (error! as RefundAllocationExceedsOriginalItem).remainingCents,
        4000,
      );
    });

    test('分配指向不属于这笔消费的拆分项时失败', () {
      final base = baselineWithHemaSplit();
      final dataset = buildDataset(
        transactions: <LedgerTransaction>[
          ...base.transactions,
          refund(id: 103, amountCents: 4000, month: 9, day: 28),
        ],
        allocations: base.allocations,
      );

      final error = RefundRules.validateRefundAllocations(
        dataset: dataset,
        refundTransactionId: 103,
        originalTransactionId: 4,
        refundAmountCents: 4000,
        drafts: const <RefundAllocationDraft>[
          // 1 号分配属于 MANNER，不是这笔盒马消费的。
          RefundAllocationDraft(originalAllocationId: 1, amountCents: 4000),
        ],
      );

      expect(error, isA<RefundAllocationUnknownItem>());
    });
  });

  group('已有退款时不能破坏原拆分结构', () {
    test('删掉或改小被退款抵扣过的拆分项会被拦下', () {
      final base = baselineWithHemaSplit();
      final dataset = buildDataset(
        transactions: <LedgerTransaction>[
          ...base.transactions,
          refund(id: 104, amountCents: 2000, month: 9, day: 28),
        ],
        allocations: base.allocations,
        refundLinks: <RefundLink>[
          RefundLink(
            id: 4,
            refundTransactionId: 104,
            originalTransactionId: 4,
            amountCents: 2000,
          ),
        ],
        refundAllocations: <RefundAllocation>[
          RefundAllocation(
            id: 1,
            refundLinkId: 4,
            originalAllocationId: 101,
            amountCents: 2000,
          ),
        ],
      );

      // 购物项已抵扣 2000：保留 4000 可以，缩减到 1999 不行，删掉也不行。
      expect(
        RefundRules.validateSplitChange(
          dataset: dataset,
          originalTransactionId: 4,
          retainedAmountsByAllocationId: const <int, int>{100: 8680, 101: 4000},
        ),
        isNull,
      );

      expect(
        RefundRules.validateSplitChange(
          dataset: dataset,
          originalTransactionId: 4,
          retainedAmountsByAllocationId: const <int, int>{100: 10680, 101: 1999},
        ),
        isA<RefundSplitBreaksLinkedRefunds>(),
      );

      expect(
        RefundRules.validateSplitChange(
          dataset: dataset,
          originalTransactionId: 4,
          retainedAmountsByAllocationId: const <int, int>{100: 12680},
        ),
        isA<RefundSplitBreaksLinkedRefunds>(),
      );
    });
  });

  group('数据集本身的一致性', () {
    test('同一笔退款只能有一条关联记录', () {
      final dataset = LedgerDataset(
        transactions: <LedgerTransaction>[resolvedBaseline().transactions.first],
        refundLinks: <RefundLink>[
          const RefundLink(
            id: 1,
            refundTransactionId: 101,
            originalTransactionId: 1,
            amountCents: 1000,
          ),
          const RefundLink(
            id: 2,
            refundTransactionId: 101,
            originalTransactionId: 1,
            amountCents: 1000,
          ),
        ],
      );
      // 数据集只保留最后一条（数据库层靠 UNIQUE 约束拒绝这种数据）。
      expect(dataset.refundsOf(1), hasLength(2));
      expect(dataset.linkForRefund(101)?.id, 2);
    });
  });
}
