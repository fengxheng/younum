import 'package:flutter_test/flutter_test.dart';
import 'package:younum/core/money/money.dart';
import 'package:younum/domain/models/allocation.dart';
import 'package:younum/domain/rules/allocation_rules.dart';

import 'support/ledger_fixtures.dart';

/// 实现指南 3.5.1 与 10.1：拆分合计必须**精确**等于原金额，每项大于 0。
void main() {
  group('拆分校验', () {
    test('合法的两项拆分可以通过', () {
      // 指南 10.1 的盒马拆分：8680 + 4000 = 12680。
      final error = AllocationRules.validate(
        originalCents: 12680,
        items: const <AllocationDraft>[
          AllocationDraft(categoryId: foodCategoryId, amountCents: 8680),
          AllocationDraft(categoryId: shoppingCategoryId, amountCents: 4000),
        ],
      );
      expect(error, isNull);
    });

    test('未拆分的单分类消费可以通过', () {
      expect(
        AllocationRules.validate(
          originalCents: 2800,
          items: AllocationRules.singleCategory(foodCategoryId, 2800),
        ),
        isNull,
      );
    });

    test('合计少 1 分不能提交，并给出差额', () {
      final error = AllocationRules.validate(
        originalCents: 12680,
        items: const <AllocationDraft>[
          AllocationDraft(categoryId: foodCategoryId, amountCents: 8680),
          AllocationDraft(categoryId: shoppingCategoryId, amountCents: 3999),
        ],
      );

      expect(error, isA<AllocationSumMismatch>());
      expect((error! as AllocationSumMismatch).differenceCents, 1);
      expect((error as AllocationSumMismatch).actual, 12679);
    });

    test('合计多 1 分不能提交，差额为负', () {
      final error = AllocationRules.validate(
        originalCents: 12680,
        items: const <AllocationDraft>[
          AllocationDraft(categoryId: foodCategoryId, amountCents: 8680),
          AllocationDraft(categoryId: shoppingCategoryId, amountCents: 4001),
        ],
      );

      expect(error, isA<AllocationSumMismatch>());
      expect((error! as AllocationSumMismatch).differenceCents, -1);
    });

    test('零金额项不能提交，并指出是第几项', () {
      final error = AllocationRules.validate(
        originalCents: 2800,
        items: const <AllocationDraft>[
          AllocationDraft(categoryId: foodCategoryId, amountCents: 2800),
          AllocationDraft(categoryId: shoppingCategoryId, amountCents: 0),
        ],
      );

      expect(error, isA<AllocationItemNotPositive>());
      expect((error! as AllocationItemNotPositive).index, 1);
    });

    test('负金额项不能提交', () {
      final error = AllocationRules.validate(
        originalCents: 2800,
        items: const <AllocationDraft>[
          AllocationDraft(categoryId: foodCategoryId, amountCents: 2800),
          AllocationDraft(categoryId: shoppingCategoryId, amountCents: -1),
        ],
      );
      expect(error, isA<AllocationItemNotPositive>());
    });

    test('一项都没有不能提交', () {
      expect(
        AllocationRules.validate(originalCents: 2800, items: const <AllocationDraft>[]),
        isA<AllocationItemsEmpty>(),
      );
    });

    test('原金额不是正数不能提交', () {
      expect(
        AllocationRules.validate(
          originalCents: 0,
          items: AllocationRules.singleCategory(foodCategoryId, 0),
        ),
        isA<AllocationSourceNotPositive>(),
      );
    });

    test('同一分类重复出现不能提交', () {
      final error = AllocationRules.validate(
        originalCents: 2800,
        items: const <AllocationDraft>[
          AllocationDraft(categoryId: foodCategoryId, amountCents: 1400),
          AllocationDraft(categoryId: foodCategoryId, amountCents: 1400),
        ],
      );

      expect(error, isA<AllocationDuplicateCategory>());
      expect((error! as AllocationDuplicateCategory).categoryId, foodCategoryId);
    });

    test('超过两位小数的输入在解析阶段就失败，不会产生一份草稿', () {
      // 「非法小数必须不能提交」：拦截发生在金额解析，而不是靠拆分校验兜底。
      final (cents, error) = Money.parseYuan('0.005');
      expect(cents, isNull);
      expect(error, isA<InvalidAmount>());
    });

    test('合计溢出时明确失败，不静默回绕', () {
      final error = AllocationRules.validate(
        originalCents: Money.maxAbsCents,
        items: const <AllocationDraft>[
          AllocationDraft(categoryId: foodCategoryId, amountCents: Money.maxAbsCents),
          AllocationDraft(categoryId: shoppingCategoryId, amountCents: Money.maxAbsCents),
        ],
      );
      expect(error, isA<AllocationAmountOverflow>());
    });
  });
}
