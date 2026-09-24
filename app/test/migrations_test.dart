import 'package:flutter_test/flutter_test.dart';
import 'package:younum/data/db/migrations.dart';

/// 迁移框架测试。
///
/// 这里不碰真实数据库：`applyMigrations` 只接收一个「执行 SQL」的回调，
/// 所以可以在 `flutter test` 里用一个记录语句的假执行器跑完整逻辑。
///
/// 「迁移在真实 SQLite 上不丢数据」由真机集成测试覆盖
/// （`integration_test/database_test.dart`）。
void main() {
  /// 记录被执行的语句。
  late List<String> executed;

  Future<void> fakeExecute(String sql) async => executed.add(sql);

  Migration step(int from, String description, {String? sql}) => Migration(
        from: from,
        to: from + 1,
        description: description,
        run: (execute) => execute(sql ?? 'STEP $from'),
      );

  setUp(() => executed = <String>[]);

  test('版本相同：什么都不做', () async {
    final applied = await applyMigrations(
      fromVersion: 1,
      toVersion: 1,
      migrations: <Migration>[step(1, '不该被执行')],
      execute: fakeExecute,
    );
    expect(applied, isEmpty);
    expect(executed, isEmpty);
  });

  test('版本相同但一步都没注册，也不报错', () async {
    final applied = await applyMigrations(
      fromVersion: 3,
      toVersion: 3,
      migrations: const <Migration>[],
      execute: fakeExecute,
    );
    expect(applied, isEmpty);
  });

  test('逐版推进：v1 → v3 会依次执行 1→2 与 2→3', () async {
    final applied = await applyMigrations(
      fromVersion: 1,
      toVersion: 3,
      migrations: <Migration>[
        step(1, '加图标资源表'),
        step(2, '给分类加图标外键'),
      ],
      execute: fakeExecute,
    );

    expect(executed, <String>['STEP 1', 'STEP 2']);
    expect(applied, hasLength(2));
    expect(applied.first, contains('v1 → v2'));
    expect(applied.last, contains('v2 → v3'));
  });

  test('中间缺一步就明确失败，而不是跳到最新版', () async {
    await expectLater(
      applyMigrations(
        fromVersion: 1,
        toVersion: 3,
        // 缺 2→3。
        migrations: <Migration>[step(1, '只有第一步')],
        execute: fakeExecute,
      ),
      throwsA(
        isA<MigrationError>().having(
          (error) => error.message,
          'message',
          contains('v2 → v3'),
        ),
      ),
    );
  });

  test('不支持降级：把数据改回旧结构只会悄掉数据', () async {
    await expectLater(
      applyMigrations(
        fromVersion: 3,
        toVersion: 1,
        migrations: <Migration>[],
        execute: fakeExecute,
      ),
      throwsA(isA<MigrationError>()),
    );
  });

  test('迁移步骤必须是逐版推进，跨版会在构造时就断言失败', () {
    expect(
      () => Migration(
        from: 1,
        to: 3,
        description: '跳到最新版',
        run: (execute) async {},
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('多个步骤里有相同起点时取第一个，顺序责任在注册方', () async {
    // 这条用例是记录「框架不做去重」这个事实：迁移链应当是唯一的，
    // 注册重复起点属于配置错误，靠 review 保证，而不是靠运行时猜。
    final applied = await applyMigrations(
      fromVersion: 1,
      toVersion: 2,
      migrations: <Migration>[
        step(1, '第一个'),
        step(1, '第二个'),
      ],
      execute: fakeExecute,
    );
    expect(applied.single, contains('第一个'));
    expect(executed, <String>['STEP 1']);
  });
}
