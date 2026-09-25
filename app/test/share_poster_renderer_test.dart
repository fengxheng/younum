import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:younum/data/files/share_poster_renderer.dart';
import 'package:younum/domain/models/allocation.dart';
import 'package:younum/domain/models/category.dart';
import 'package:younum/domain/models/ledger_dataset.dart';
import 'package:younum/domain/models/ledger_transaction.dart';
import 'package:younum/domain/models/year_month.dart';
import 'package:younum/domain/repositories/poster_ports.dart';
import 'package:younum/domain/rules/export_rules.dart';
import 'package:younum/domain/rules/month_overview.dart';
import 'package:younum/domain/rules/share_poster_rules.dart';

/// 海报真的渲染成 PNG。
///
/// 指南 10.4 要求「隐藏金额后检查生成的 PNG，而非只检查屏幕遮罩」。
/// 这里两头都验：内容层面由 `share_poster_rules_test.dart` 断言清单里没有
/// 那个数字；文件层面在这里断言**开关确实改变了字节**（不是同一张图换个遮罩）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const palette = PosterPalette(
    background: ui.Color(0xFFE8EFE4),
    foreground: ui.Color(0xFF22331D),
    muted: ui.Color(0xFF6B7A63),
  );

  /// 换一套主题色，用来验证「封面跟着主题变」。
  const otherPalette = PosterPalette(
    background: ui.Color(0xFFF2E6EA),
    foreground: ui.Color(0xFF3A1F28),
    muted: ui.Color(0xFF7A6470),
  );

  final september = YearMonth(2026, 9);

  MonthOverview overview() {
    LedgerTransaction tx(
      int id,
      int amountCents,
      String merchant,
      int categoryId,
      TransactionNature nature,
    ) => LedgerTransaction(
      id: id,
      ledgerId: 1,
      occurredAtMs: DateTime.utc(2026, 9, 10 + id, 4, 0).millisecondsSinceEpoch,
      amountCents: amountCents,
      merchant: merchant,
      nature: nature,
      reviewStatus: ReviewStatus.resolved,
      timeZone: 'Asia/Shanghai',
    );

    final dataset = LedgerDataset(
      transactions: <LedgerTransaction>[
        tx(1, 2800, 'MANNER COFFEE', 1, TransactionNature.expense),
        tx(2, 29900, '优衣库', 2, TransactionNature.expense),
        tx(3, 3650, '滴滴出行', 3, TransactionNature.expense),
      ],
      categories: <Category>[
        for (var id = 1; id <= 3; id++)
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
        Allocation(id: 1, transactionId: 1, categoryId: 1, amountCents: 2800),
        Allocation(id: 2, transactionId: 2, categoryId: 2, amountCents: 29900),
        Allocation(id: 3, transactionId: 3, categoryId: 3, amountCents: 3650),
      ],
    );

    return MonthOverview.compute(
      month: september,
      dataset: dataset,
      coverageConfirmed: true,
      isDemoLedger: true,
    );
  }

  SharePosterSpec spec({
    required bool showAmount,
    PosterPalette colors = palette,
  }) => SharePosterRules.build(
    overview: overview(),
    privacy: ExportPrivacy(showAmount: showAmount),
    palette: colors,
  );

  Future<PosterRendered> rendered(SharePosterSpec input, {double scale = 2}) async {
    final result = await const SharePosterRenderer().render(input, scale: scale);
    expect(result, isA<PosterRendered>(), reason: '$result');
    return result as PosterRendered;
  }

  int u32(Uint8List bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      (bytes[offset + 3]);

  test('导出的是真 PNG，尺寸是设计尺寸乘以倍数', () async {
    final output = await rendered(spec(showAmount: false));

    expect(
      output.bytes.sublist(0, 8),
      <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
      reason: 'PNG 文件头',
    );
    // IHDR 里第 16..24 字节是宽高（大端）。
    expect(u32(output.bytes, 16), 1500);
    expect(u32(output.bytes, 20), 2000);
    expect(output.width, 1500);
    expect(output.height, 2000);

    // 能被引擎重新解码 —— 不是拼出来的假文件。
    final codec = await ui.instantiateImageCodec(output.bytes);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 1500);
    expect(frame.image.height, 2000);
    frame.image.dispose();
    codec.dispose();
  });

  test('隐藏金额与展示金额出来的是**两张不同的图**，不是同一张加遮罩', () async {
    final hidden = await rendered(spec(showAmount: false));
    final shown = await rendered(spec(showAmount: true));

    expect(
      _sameBytes(hidden.bytes, shown.bytes),
      isFalse,
      reason: '开关必须改变最终文件，否则就是屏幕遮罩',
    );
  });

  test('换主题出来的是不同的图：封面跟着主题走', () async {
    final warm = await rendered(spec(showAmount: false));
    final cool = await rendered(spec(showAmount: false, colors: otherPalette));

    expect(_sameBytes(warm.bytes, cool.bytes), isFalse);
  });

  test('放大倍数可以调，尺寸跟着变', () async {
    final single = await rendered(spec(showAmount: false), scale: 1);
    expect(single.width, 750);
    expect(single.height, 1000);
  });

  test('倍数不合法时如实失败，不产出半张图', () async {
    for (final scale in <double>[0, -1, double.nan, double.infinity]) {
      final result = await const SharePosterRenderer().render(
        spec(showAmount: false),
        scale: scale,
      );
      expect(result, isA<PosterRenderFailed>(), reason: 'scale=$scale');
    }
  });

  test('不支持的实现给出可读的中文提示', () async {
    final result = await const UnsupportedPosterMaker().render(
      spec(showAmount: false),
    );
    expect(result, isA<PosterRenderFailed>());
    expect((result as PosterRenderFailed).message, isNotEmpty);
  });
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}
