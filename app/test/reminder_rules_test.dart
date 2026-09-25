import 'package:flutter_test/flutter_test.dart';
import 'package:younum/core/preferences/reminder_store.dart';
import 'package:younum/domain/rules/reminder_rules.dart';

/// 每月提醒的时间推算。
///
/// 指南 8.2 要求「按日历计算下次时间，不能把「每月」实现为固定 30 天」，
/// 以及「允许系统节电造成合理延迟，文案注明约在此时间」。
void main() {
  ReminderSettings on({int day = 1, int hour = 20, int minute = 0}) =>
      ReminderSettings(enabled: true, day: day, hour: hour, minute: minute);

  DateTime at(int year, int month, int day, [int hour = 0, int minute = 0]) =>
      DateTime(year, month, day, hour, minute);

  group('短月顺延', () {
    test('31 日在 2 月落到月末，不是跳过这个月', () {
      expect(ReminderRules.effectiveDay(2026, 2, 31), 28);
      expect(ReminderRules.effectiveDay(2028, 2, 31), 29, reason: '闰年');
      expect(ReminderRules.effectiveDay(2026, 4, 31), 30);
      expect(ReminderRules.effectiveDay(2026, 9, 31), 30);
      expect(ReminderRules.effectiveDay(2026, 1, 31), 31);
    });

    test('正常日期不动它', () {
      expect(ReminderRules.effectiveDay(2026, 9, 3), 3);
      expect(ReminderRules.effectiveDay(2026, 2, 28), 28);
    });

    test('越界的配置被夹回范围内', () {
      expect(ReminderRules.effectiveDay(2026, 9, 0), 1);
      expect(ReminderRules.effectiveDay(2026, 9, 99), 30);
    });
  });

  group('下次提醒时间', () {
    test('关闭时没有「下次提醒」', () {
      final off = on().copyWith(enabled: false);
      expect(ReminderRules.nextRun(off, now: at(2026, 9, 1)), isNull);
    });

    test('当月还没到就落在当月', () {
      final next = ReminderRules.nextRun(
        on(day: 10, hour: 20),
        now: at(2026, 9, 3, 9, 0),
      );
      expect(next, at(2026, 9, 10, 20, 0));
    });

    test('当月已过就顺延到下个月（按日历，不是 30 天）', () {
      final next = ReminderRules.nextRun(
        on(day: 10, hour: 20),
        now: at(2026, 9, 10, 21, 0),
      );
      expect(next, at(2026, 10, 10, 20, 0));
    });

    test('正好到点也算已过：不会同一分钟里连发两次', () {
      final next = ReminderRules.nextRun(
        on(day: 10, hour: 20),
        now: at(2026, 9, 10, 20, 0),
      );
      expect(next, at(2026, 10, 10, 20, 0));
    });

    test('跨年：12 月的下一次是明年 1 月', () {
      final next = ReminderRules.nextRun(
        on(day: 5, hour: 8),
        now: at(2026, 12, 20, 9, 0),
      );
      expect(next, at(2027, 1, 5, 8, 0));
    });

    test('31 日设置：2 月的下一次落在 2 月 28 日', () {
      final next = ReminderRules.nextRun(
        on(day: 31, hour: 20),
        now: at(2026, 2, 1, 9, 0),
      );
      expect(next, at(2026, 2, 28, 20, 0));
    });

    test('分钟也参与计算', () {
      final next = ReminderRules.nextRun(
        on(day: 3, hour: 7, minute: 45),
        now: at(2026, 9, 3, 7, 44),
      );
      expect(next, at(2026, 9, 3, 7, 45));
    });
  });

  group('说明文案', () {
    test('说出具体日期时间', () {
      expect(
        ReminderRules.describe(at(2026, 11, 1, 20, 0)),
        '11 月 1 日 20:00',
      );
      expect(ReminderRules.describe(at(2026, 9, 3, 7, 5)), '9 月 3 日 07:05');
    });

    test('按「哪一天」说还剩多久', () {
      final now = at(2026, 9, 1, 23, 0);
      expect(ReminderRules.remainingLabel(at(2026, 9, 1, 8, 0), now: now), '今天');
      expect(ReminderRules.remainingLabel(at(2026, 9, 2, 8, 0), now: now), '明天');
      expect(
        ReminderRules.remainingLabel(at(2026, 9, 8, 20, 0), now: now),
        '约 7 天后',
      );
    });
  });

  group('设置本身', () {
    test('默认是关闭的', () {
      expect(ReminderRules.defaults.enabled, isFalse);
      expect(ReminderRules.defaults.day, 1);
      expect(ReminderRules.defaults.hour, 20);
    });

    test('copyWith 只改点到的字段', () {
      final next = ReminderRules.defaults.copyWith(enabled: true, day: 15);
      expect(next.enabled, isTrue);
      expect(next.day, 15);
      expect(next.hour, 20);
      expect(next.minute, 0);
    });

    test('相等性按值比较（落盘后读回来要相等）', () {
      expect(on(day: 3, hour: 7, minute: 5), on(day: 3, hour: 7, minute: 5));
      expect(on(day: 3), isNot(on(day: 4)));
      expect(on().hashCode, on().hashCode);
    });

    test('存盘带版本号与时区口径', () {
      final json = on().toJson();
      expect(json['version'], 1);
      expect(json['enabled'], isTrue);
      expect(json['timeZone'], ReminderRules.timeZone);
      expect(ReminderRules.timeZone, 'Asia/Shanghai');
    });
  });

  group('存储', () {
    test('内存实现：没设置过是 null，存了能读回来', () async {
      final store = InMemoryReminderStore();
      expect(await store.load(), isNull);

      final settings = on(day: 15, hour: 9, minute: 30);
      await store.save(settings);
      expect(await store.load(), settings);
    });
  });
}
