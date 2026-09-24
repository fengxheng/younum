import 'package:flutter_test/flutter_test.dart';
import 'package:younum/core/money/money.dart';
import 'package:younum/core/time/statistics_time.dart';
import 'package:younum/domain/models/import_records.dart';
import 'package:younum/domain/rules/csv_parser.dart';
import 'package:younum/domain/rules/import_rules.dart';

/// 解析一份 CSV。测试里用的 CSV 都是我们自己写的，解不出来说明是测试写错了，
/// 所以这里直接断言成功，免得每个用例都写一遍错误分支。
CsvTable _parseCsv(String text) {
  final (table, error) = CsvParser.parse(text);
  expect(error, isNull, reason: '测试用 CSV 应当能解析，实际报错：$error');
  return table!;
}

/// 一份仿微信导出的账单：前面有说明行、表头在第 6 行、末尾有合计行。
const String _wechatExport = '''
微信支付账单明细
微信昵称：[有数测试]
起始时间：[2026-09-01 00:00:00] 终止时间：[2026-09-30 23:59:59]
导出类型：[全部]
导出时间：[2026-10-01 09:12:03]
----------------------微信支付账单明细列表--------------------
交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态,交易单号,商户单号,备注
2026-09-23 14:26:00,商户消费,老王牛肉面,牛肉面,支出,¥28.00,零钱,支付成功,4200001,M1001,/
2026-09-24 09:02:11,商户消费,地铁公司,地铁,支出,¥5.00,零钱,支付成功,4200002,M1002,/
2026-09-25 20:31:40,转账,张三,转账,不计收支,¥200.00,零钱,已存入零钱,4200003,M1003,/
2026-09-26 11:05:00,商户消费,某网店,杯子,支出,¥32.50,零钱,已全额退款,4200004,M1004,退款
2026-09-27 08:00:00,商户消费,早餐铺,包子,支出,¥9.00,零钱,支付成功,4200005,M1005,/
共 5 笔,合计,-274.50,,,,
''';

void main() {
  group('表头识别', () {
    test('能在说明行之后找到真正的表头', () {
      final table = _parseCsv(_wechatExport);
      final header = ImportRules.detectHeader(table);

      expect(header.headerRowIndex, 6, reason: '前面 6 行是说明，表头是第 7 行');
      expect(header.platformName, '微信支付', reason: '说明行里写着微信');
      expect(header.missingRequired, isEmpty);
      expect(header.isUsable, isTrue);
      expect(header.needsManualMapping, isFalse);
      expect(header.columns[ImportField.occurredAt], 0);
      expect(header.columns[ImportField.merchant], 2);
      expect(header.columns[ImportField.amount], 5);
      expect(header.columns[ImportField.direction], 4);
      expect(header.columns[ImportField.orderId], 8);
    });

    test('列顺序换过也能认出来（不靠固定下标）', () {
      const swapped =
          '金额（元）,交易对方,交易时间,当前状态\n'
          '¥12.00,便利店,2026-09-01 08:00:00,支付成功\n';
      final header = ImportRules.detectHeader(_parseCsv(swapped));

      expect(header.isUsable, isTrue);
      expect(header.columns[ImportField.amount], 0);
      expect(header.columns[ImportField.merchant], 1);
      expect(header.columns[ImportField.occurredAt], 2);
    });

    test('英文字头也能匹配', () {
      const english = 'Date,Merchant,Amount\n2026-09-01,Shop,12.00\n';
      final header = ImportRules.detectHeader(_parseCsv(english));

      expect(header.isUsable, isTrue, reason: 'Time/Merchant/Amount 三个都认得出');
      expect(header.platformName, isNull);
    });

    test('缺少必填列时要求人工映射', () {
      const missing =
          '交易时间,金额(元),当前状态\n'
          '2026-09-01 08:00:00,¥12.00,支付成功\n';
      final header = ImportRules.detectHeader(_parseCsv(missing));

      expect(header.isUsable, isFalse);
      expect(header.needsManualMapping, isTrue);
      expect(header.missingRequired, contains(ImportField.merchant));
    });

    test('完全认不出来时返回 -1，而不是硬认一个表头', () {
      const nonsense = 'a,b,c\n1,2,3\n';
      final header = ImportRules.detectHeader(_parseCsv(nonsense));

      expect(header.headerRowIndex, -1);
      expect(header.isUsable, isFalse);
    });

    test('表头里的空格与全角括号不影响匹配', () {
      const spaced = '交易 时间,交易对方 ,金额（元）\n2026-09-01,店,¥1.00\n';
      final header = ImportRules.detectHeader(_parseCsv(spaced));

      expect(header.isUsable, isTrue);
    });
  });

  group('逐行解析', () {
    late HeaderGuess header;

    setUp(() {
      header = ImportRules.detectHeader(_parseCsv(_wechatExport));
    });

    test('说明行、表头行、合计行都被跳过', () {
      final table = _parseCsv(_wechatExport);
      final kinds = <int, RowParse>{};
      for (var i = 0; i < table.rows.length; i++) {
        kinds[i + 1] = ImportRules.parseRow(
          row: table.rows[i],
          rowNumber: i + 1,
          header: header,
        );
      }

      expect(kinds[1], isA<RowSkipped>());
      expect(kinds[7], isA<RowSkipped>(), reason: '表头本身（行号 7）');
      expect(kinds[13], isA<RowSkipped>(), reason: '末尾合计行（行号 13）');
      expect(kinds[8], isA<RowParsed>(), reason: '第一行数据（行号 8）');
    });

    test('正常一行解析出时间、金额、方向、商户', () {
      final table = _parseCsv(_wechatExport);
      final parsed = ImportRules.parseRow(
        row: table.rows[7],
        rowNumber: 8,
        header: header,
      ) as RowParsed;

      expect(parsed.merchant, '老王牛肉面');
      expect(parsed.amountCents, 2800);
      expect(parsed.direction, ImportDirection.expense);
      expect(parsed.orderId, '4200001');
      expect(parsed.hasStableId, isTrue);
      expect(
        parsed.occurredAtMs,
        StatisticsTime.epochMsFor(2026, 9, 23, 14, 26, 0),
      );
    });

    test('「不计收支」的转账不会被当成消费', () {
      final table = _parseCsv(_wechatExport);
      final parsed = ImportRules.parseRow(
        row: table.rows[9],
        rowNumber: 10,
        header: header,
      ) as RowParsed;

      expect(parsed.direction, ImportDirection.transfer);
      expect(parsed.direction.label, '转账');
    });

    test('已全额退款的行被排除，不进正式账', () {
      final table = _parseCsv(_wechatExport);
      final result = ImportRules.parseRow(
        row: table.rows[10],
        rowNumber: 11,
        header: header,
      );

      expect(result, isA<RowInvalid>());
      expect((result as RowInvalid).issue, contains('全额退款'));
    });

    test('缺金额时明确报错，不静默放过', () {
      // 金额列是下标 5，这里刻意留空
      final result = ImportRules.parseRow(
        row: <String>['2026-09-01 08:00:00', '商户消费', '店', '商品', '支出', '', '零钱'],
        rowNumber: 99,
        header: header,
      );
      expect(result, isA<RowInvalid>());
      expect((result as RowInvalid).issue, contains('金额'));
    });

    test('交易状态是「已关闭」时排除', () {
      expect(ImportRules.isSuccessfulStatus('支付成功'), isTrue);
      expect(ImportRules.isSuccessfulStatus('已存入零钱'), isTrue);
      expect(ImportRules.isSuccessfulStatus('已全额退款'), isFalse);
      expect(ImportRules.isSuccessfulStatus('交易关闭'), isFalse);
      expect(ImportRules.isSuccessfulStatus('已撤销'), isFalse);
      expect(ImportRules.isSuccessfulStatus(''), isTrue);
    });
  });

  group('金额解析', () {
    test('各种写法都能读出分值', () {
      expect(ImportRules.parseAmount('¥28.00').$1!.cents, 2800);
      expect(ImportRules.parseAmount('28.00元').$1!.cents, 2800);
      expect(ImportRules.parseAmount('1,234.56').$1!.cents, 123456);
      expect(ImportRules.parseAmount('0.01').$1!.cents, 1);
      expect(ImportRules.parseAmount('28').$1!.cents, 2800);
    });

    test('负号被单独带出来，而不是丢掉', () {
      final (amount, error) = ImportRules.parseAmount('-28.00');
      expect(error, isNull);
      expect(amount!.cents, 2800, reason: '存绝对值');
      expect(amount.rawSign, -1, reason: '符号要单独保留供方向校验');
    });

    test('0 与空值都算无效', () {
      expect(ImportRules.parseAmount('0.00').$1, isNull);
      expect(ImportRules.parseAmount('').$1, isNull);
      expect(ImportRules.parseAmount('¥').$1, isNull);
    });
  });

  group('收支方向', () {
    test('文本与符号一致时给出方向', () {
      expect(ImportRules.directionOf('支出', -1), ImportDirection.expense);
      expect(ImportRules.directionOf('收入', 1), ImportDirection.income);
      expect(ImportRules.directionOf('不计收支', 1), ImportDirection.transfer);
    });

    test('「支出 + 正数」是最常见的情形，不能当成矛盾', () {
      // 微信与支付宝导出的支出行，金额都是正数，方向由「收/支」列表达。
      // 把这一情形当冲突，会让整份账单全部判为无效。
      expect(ImportRules.directionOf('支出', 1), ImportDirection.expense);
      expect(ImportRules.directionOf('支出', -1), ImportDirection.expense);
    });

    test('「收入却是负数」才是真矛盾，返回 null 交给用户核对', () {
      expect(ImportRules.directionOf('收入', -1), isNull);
    });

    test('方向列缺位时靠符号推断', () {
      expect(ImportRules.directionOf('', -1), ImportDirection.expense);
      expect(
        ImportRules.directionOf('', 1),
        ImportDirection.unknown,
        reason: '正数且无方向列，无法判断是收入还是支出',
      );
    });

    test('文件里重复了一次表头时，「收/支」不当方向', () {
      expect(ImportRules.directionOf('收/支', 1), ImportDirection.unknown);
      expect(ImportRules.directionOf('收支', -1), ImportDirection.expense);
    });
  });

  group('时间解析', () {
    test('支持账单里常见的几种写法', () {
      final expected = StatisticsTime.epochMsFor(2026, 9, 23, 14, 26, 0);
      expect(ImportRules.parseOccurredAt('2026-09-23 14:26:00'), expected);
      expect(ImportRules.parseOccurredAt('2026-09-23 14:26'), expected);
      expect(ImportRules.parseOccurredAt('2026/9/23 14:26'), expected);
      expect(ImportRules.parseOccurredAt('2026年9月23日 14:26'), expected);
      expect(
        ImportRules.parseOccurredAt('2026.09.23'),
        StatisticsTime.epochMsFor(2026, 9, 23),
      );
    });

    test('不存在的日期不会被顺延成下个月', () {
      expect(
        ImportRules.parseOccurredAt('2026-02-30'),
        isNull,
        reason: '如果直接丢给 DateTime，2 月 30 日会变成 3 月 2 日',
      );
      expect(ImportRules.parseOccurredAt('2026-13-01'), isNull);
      expect(ImportRules.parseOccurredAt('2026-09-23 25:00'), isNull);
    });

    test('认不出的格式返回 null', () {
      expect(ImportRules.parseOccurredAt('昨天'), isNull);
      expect(ImportRules.parseOccurredAt(''), isNull);
      expect(ImportRules.parseOccurredAt('23/09/2026'), isNull);
    });
  });

  group('去重', () {
    test('有稳定单号时按命名空间 + 单号判定同源重复', () {
      final key = ImportRules.stableKeyOf(
        sourceNamespace: 'wechat',
        sourceAccount: '零钱',
        orderId: '4200001',
      );
      expect(key, isNotNull);

      final differentAccount = ImportRules.stableKeyOf(
        sourceNamespace: 'wechat',
        sourceAccount: '银行卡',
        orderId: '4200001',
      );
      expect(differentAccount, isNot(key), reason: '不同账户下的同号不是同一笔');
    });

    test('没有稳定单号时没有同源键', () {
      expect(
        ImportRules.stableKeyOf(
          sourceNamespace: 'wechat',
          sourceAccount: null,
          orderId: null,
        ),
        isNull,
      );
      expect(
        ImportRules.stableKeyOf(
          sourceNamespace: 'wechat',
          sourceAccount: null,
          orderId: '  ',
        ),
        isNull,
      );
    });

    test('同源键命中可以确定重复；弱键命中只能算疑似', () {
      final stable = ImportRules.stableKeyOf(
        sourceNamespace: 'wechat',
        sourceAccount: '零钱',
        orderId: '4200001',
      )!;
      const weak = '老王牛肉面\u00002800\u0000';

      expect(
        ImportRules.classify(
          stableKey: stable,
          weakKey: weak,
          knownStableKeys: <String>{stable},
          knownWeakKeys: const <String>{},
        ),
        DuplicateVerdict.sameOrigin,
      );

      expect(
        ImportRules.classify(
          stableKey: null,
          weakKey: weak,
          knownStableKeys: const <String>{},
          knownWeakKeys: const <String>{weak},
        ),
        DuplicateVerdict.suspected,
        reason: '同一家店同一分钟买两次是真实存在的，只能提示不能自动排除',
      );

      expect(
        ImportRules.classify(
          stableKey: null,
          weakKey: 'other',
          knownStableKeys: const <String>{},
          knownWeakKeys: const <String>{weak},
        ),
        DuplicateVerdict.fresh,
      );
    });

    test('弱键忽略商户大小写与首尾空格', () {
      final a = ImportRules.weakKeyOf(
        merchant: ' Shop ',
        occurredAtMs: 1,
        amountCents: 100,
      );
      final b = ImportRules.weakKeyOf(
        merchant: 'shop',
        occurredAtMs: 1,
        amountCents: 100,
      );
      expect(a, b);
    });
  });

  group('整条链路', () {
    test('仿微信账单：识别 5 行数据，4 笔可入账、1 笔退款被排除', () {
      final table = _parseCsv(_wechatExport);
      final header = ImportRules.detectHeader(table);
      expect(header.isUsable, isTrue);

      var parsed = 0;
      var invalid = 0;
      var skipped = 0;
      var totalCents = 0;
      final knownStable = <String>{};
      final knownWeak = <String>{};
      final verdicts = <DuplicateVerdict>[];

      for (var i = 0; i < table.rows.length; i++) {
        final result = ImportRules.parseRow(
          row: table.rows[i],
          rowNumber: i + 1,
          header: header,
        );
        switch (result) {
          case RowSkipped():
            skipped++;
          case RowInvalid():
            invalid++;
          case RowParsed():
            parsed++;
            if (result.direction != ImportDirection.expense) continue;

            final stable = ImportRules.stableKeyOf(
              sourceNamespace: 'wechat',
              sourceAccount: null,
              orderId: result.orderId,
            );
            final weak = ImportRules.weakKeyOf(
              merchant: result.merchant,
              occurredAtMs: result.occurredAtMs,
              amountCents: result.amountCents,
            );
            final verdict = ImportRules.classify(
              stableKey: stable,
              weakKey: weak,
              knownStableKeys: knownStable,
              knownWeakKeys: knownWeak,
            );
            verdicts.add(verdict);
            if (verdict != DuplicateVerdict.fresh) continue;

            totalCents += result.amountCents;
            if (stable != null) knownStable.add(stable);
            knownWeak.add(weak);
        }
      }

      expect(skipped, 8, reason: '前 7 行说明与表头 + 1 行末尾合计');
      expect(parsed, 4, reason: '5 行真实数据里有 1 行是退款');
      expect(invalid, 1, reason: '退款那行');
      expect(verdicts, hasLength(3), reason: '只有 3 笔是成功消费（转账不算）');
      expect(verdicts.every((v) => v == DuplicateVerdict.fresh), isTrue);
      expect(totalCents, 2800 + 500 + 900, reason: '转账不计、退款不计');
    });

    test('同一份文件导入两次：第二次数出来的全是同源重复', () {
      final table = _parseCsv(_wechatExport);
      final header = ImportRules.detectHeader(table);

      final knownStable = <String>{};
      for (var round = 0; round < 2; round++) {
        var sameOrigin = 0;
        for (var i = 0; i < table.rows.length; i++) {
          final result = ImportRules.parseRow(
            row: table.rows[i],
            rowNumber: i + 1,
            header: header,
          );
          if (result is! RowParsed) continue;
          final stable = ImportRules.stableKeyOf(
            sourceNamespace: 'wechat',
            sourceAccount: null,
            orderId: result.orderId,
          );
          if (round == 0) {
            if (stable != null) knownStable.add(stable);
            continue;
          }
          if (stable != null && knownStable.contains(stable)) sameOrigin++;
        }
        if (round == 1) {
          expect(sameOrigin, 4, reason: '4 笔都解析成功且都有稳定单号，第二遍应全部判为同源重复');
        }
      }
    });
  });

  group('金额与存储的约定', () {
    test('解析出来的金额永远非负，符号不进入金额本身', () {
      for (final raw in <String>['¥28.00', '-28.00', '+28.00', '28.00元']) {
        final (amount, _) = ImportRules.parseAmount(raw);
        expect(amount!.cents, 2800);
        expect(amount.cents, greaterThan(0));
      }
    });

    test('Money 格式化与解析互逆', () {
      final (cents, _) = Money.parseYuan('633.30');
      expect(cents, 63330);
      expect(Money.format(cents!), '633.30');
    });
  });
}
