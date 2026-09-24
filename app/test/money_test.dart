import 'package:flutter_test/flutter_test.dart';
import 'package:younum/core/money/money.dart';

/// 金额规则测试。
///
/// 对应实现指南 3.1 与 10.1：金额以「分」保存、精确十进制解析、
/// 加总检查溢出。
void main() {
  group('格式化', () {
    test('两位小数补零', () {
      expect(Money.format(2800), '28.00');
      expect(Money.format(5), '0.05');
      expect(Money.format(0), '0.00');
    });

    test('千分位分组', () {
      expect(Money.format(843260, grouped: true), '8,432.60');
      expect(Money.format(100000000, grouped: true), '1,000,000.00');
    });

    test('带符号展示使用 U+2212 减号', () {
      expect(Money.formatWithSign(-2800), '\u221228.00');
      expect(Money.formatWithSign(2800), '+28.00');
    });
  });

  group('解析：精确十进制，不经过 double', () {
    test('普通值与别名输入', () {
      expect(Money.parseYuan('28').$1, 2800);
      expect(Money.parseYuan('28.5').$1, 2850);
      expect(Money.parseYuan('28.50').$1, 2850);
      expect(Money.parseYuan(' 1,234.56 ').$1, 123456);
      expect(Money.parseYuan('+28').$1, 2800);
      expect(Money.parseYuan('-28').$1, -2800);
      expect(Money.parseYuan('.5').$1, 50);
    });

    test('超过两位小数必须报错，不能默默四舍五入', () {
      final (cents, error) = Money.parseYuan('0.005');
      expect(cents, isNull);
      expect(error, isA<InvalidAmount>());
      expect(error!.message, contains('两位小数'));
    });

    test('空输入与非法字符', () {
      expect(Money.parseYuan('').$2, isA<EmptyAmount>());
      expect(Money.parseYuan('  ').$2, isA<EmptyAmount>());
      expect(Money.parseYuan('abc').$2, isA<InvalidAmount>());
      expect(Money.parseYuan('1.2.3').$2, isA<InvalidAmount>());
      expect(Money.parseYuan('-').$2, isA<InvalidAmount>());
    });

    test('超出范围', () {
      expect(Money.parseYuan('999999999999').$2, isA<AmountOutOfRange>());
    });

    test('0.1 + 0.2 语义：分级别相加无误差', () {
      final a = Money.parseYuan('0.1').$1!;
      final b = Money.parseYuan('0.2').$1!;
      expect(Money.format(a + b), '0.30');
    });
  });

  group('加总溢出检查', () {
    test('正常求和', () {
      expect(Money.addAll(<int>[2800, 29900, 3650]), 36350);
    });

    test('超出范围返回 null 而不是截断', () {
      expect(Money.addAll(<int>[Money.maxAbsCents, 1]), isNull);
    });
  });

  group('指南 10.1 固定金额基准', () {
    // MANNER 2800 + 优衣库 29900 + 滴滴 3650 + 盒马 12680 + 电影 7800 + 药房 6500
    const baseline = <int>[2800, 29900, 3650, 12680, 7800, 6500];

    test('6 笔合计 63330 分 / ¥633.30', () {
      expect(Money.addAll(baseline), 63330);
      expect(Money.format(63330, grouped: true), '633.30');
    });

    test('餐饮小计 15480 分（MANNER + 盒马）', () {
      expect(Money.addAll(<int>[2800, 12680]), 15480);
    });

    test('拆分盒马为 8680 + 4000 后总额不变', () {
      final split = <int>[2800, 29900, 3650, 8680, 4000, 7800, 6500];
      expect(Money.addAll(split), 63330);
      // 餐饮 = MANNER 2800 + 买菜 8680
      expect(Money.addAll(<int>[2800, 8680]), 11480);
      // 购物 = 优衣库 29900 + 日用品 4000
      expect(Money.addAll(<int>[29900, 4000]), 33900);
    });

    test('新增 10 月发生的 10000 分退款后 9 月净消费为 53330', () {
      expect(Money.addAll(<int>[63330, -10000]), 53330);
    });
  });
}
