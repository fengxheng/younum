import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:younum/domain/models/allocation.dart';
import 'package:younum/domain/models/category.dart';
import 'package:younum/domain/models/ledger_dataset.dart';
import 'package:younum/domain/models/ledger_transaction.dart';
import 'package:younum/domain/models/year_month.dart';
import 'package:younum/domain/rules/export_rules.dart';
import 'package:younum/domain/rules/month_overview.dart';
import 'package:younum/domain/rules/share_poster_rules.dart';

/// 月报分享海报的内容与隐私开关。
///
/// 指南 10.4 明确要求「隐藏金额后检查生成的 PNG，而非只检查屏幕遮罩」。
/// 自动化的做法是：海报要画什么由 [SharePosterSpec] 这份纯数据决定，
/// 渲染器没有别的输入。所以这里断言「清单里根本没有那个数字」，
/// 等价于「生成的图里画不出那个数字」。
void main() {
  const palette = PosterPalette(
    background: Color(0xFFE8EFE4),
    foreground: Color(0xFF22331D),
    muted: Color(0xFF6B7A63),
  );

  final september = YearMonth(2026, 9);

  int at(int day, int hour, int minute) =>
      DateTime.utc(2026, 9, day, hour - 8, minute).millisecondsSinceEpoch;

  /// 6 笔消费 + 一笔收入：合计 633.30 元（指南 10.1 的固定基准）。
  LedgerDataset dataset({bool empty = false}) {
    if (empty) return LedgerDataset();
    final rows = <(int, int, String, int)>[
      (1, 2800, 'MANNER COFFEE', 1),
      (2, 29900, '优衣库', 2),
      (3, 3650, '滴滴出行', 3),
      (4, 12680, '盒马鲜生', 1),
      (5, 7800, '周末电影', 4),
      (6, 6500, '社区药房', 5),
    ];
    return LedgerDataset(
      transactions: <LedgerTransaction>[
        for (final row in rows)
          LedgerTransaction(
            id: row.$1,
            ledgerId: 1,
            occurredAtMs: at(row.$1 + 10, 12, 0),
            amountCents: row.$4 == 0 ? row.$2 : row.$2,
            merchant: row.$3,
            nature: TransactionNature.expense,
            reviewStatus: ReviewStatus.resolved,
            timeZone: 'Asia/Shanghai',
          ),
        LedgerTransaction(
          id: 99,
          ledgerId: 1,
          occurredAtMs: at(20, 9, 0),
          amountCents: 50000,
          merchant: '某公司',
          nature: TransactionNature.income,
          reviewStatus: ReviewStatus.resolved,
          timeZone: 'Asia/Shanghai',
        ),
      ],
      categories: <Category>[
        for (var id = 1; id <= 5; id++)
          Category(
            id: id,
            name: '用途$id',
            iconType: CategoryIconType.builtin,
            iconKey: 'food',
            sortOrder: id,
            isBuiltin: true,
          ),
      ],
      allocations: <Allocation>[
        for (final row in rows)
          Allocation(
            id: row.$1,
            transactionId: row.$1,
            categoryId: row.$4,
            amountCents: row.$2,
          ),
      ],
    );
  }

  MonthOverview overview({bool empty = false}) => MonthOverview.compute(
    month: september,
    dataset: dataset(empty: empty),
    coverageConfirmed: true,
    isDemoLedger: true,
  );

  SharePosterSpec build({required bool showAmount, bool empty = false}) =>
      SharePosterRules.build(
        overview: overview(empty: empty),
        privacy: ExportPrivacy(showAmount: showAmount),
        palette: palette,
      );

  test('默认隐藏金额：清单里根本没有那个数字', () {
    final spec = build(showAmount: false);

    expect(spec.showsAmount, isFalse);
    expect(spec.amountText, SharePosterRules.hiddenAmountText);
    // 6 笔合计 633.30 元。这个数字不能出现在海报的任何一行文字里。
    for (final text in spec.allText) {
      expect(text.contains('633.30'), isFalse, reason: '漏了金额：$text');
      expect(text.contains('633'), isFalse, reason: '漏了金额：$text');
    }
  });

  test('默认不出现商户名与用途名', () {
    final spec = build(showAmount: true);
    for (final text in spec.allText) {
      expect(text.contains('MANNER COFFEE'), isFalse, reason: '漏了商户：$text');
      expect(text.contains('盒马鲜生'), isFalse, reason: '漏了商户：$text');
      expect(text.contains('用途1'), isFalse, reason: '漏了用途名：$text');
    }
  });

  test('打开开关：金额按主题无关的数字格式出现', () {
    final spec = build(showAmount: true);

    expect(spec.showsAmount, isTrue);
    expect(spec.amountText, '¥ 633.30');
    expect(spec.allText, contains('¥ 633.30'));
  });

  test('统计行用真实笔数与用途个数，不含分类名', () {
    final spec = build(showAmount: false);

    expect(spec.statsLine, '6 笔生活记录 · 5 种生活用途');
    expect(spec.periodLabel, '2026 / 09');
    expect(spec.subtitle, '我的 9 月消费手记');
    expect(spec.headline, hasLength(2));
    expect(spec.brand, contains('有数'));
  });

  test('空月份：不假装花了 0 元，也不给 0 种用途', () {
    final hidden = build(showAmount: false, empty: true);
    expect(hidden.statsLine, SharePosterRules.emptyStatsLine);
    expect(hidden.amountText, SharePosterRules.hiddenAmountText);

    final shown = build(showAmount: true, empty: true);
    expect(shown.amountText, SharePosterRules.emptyAmountText);
    expect(shown.showsAmount, isFalse, reason: '没有记录就没有金额可展示');
    for (final text in shown.allText) {
      expect(text.contains('0.00'), isFalse);
    }
  });

  test('尺寸是 3:4 的设计单位，与原型一致', () {
    final spec = build(showAmount: false);
    expect(spec.width, 750);
    expect(spec.height, 1000);
    expect(spec.palette, same(palette));
  });
}
