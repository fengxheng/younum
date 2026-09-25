/// 把明文数据库换成加密数据库（指南 8.3 的「仅本地」再加一层）。
///
/// 为什么单独一个类：这件事**不是**打开数据库的一部分。它要动两个文件、
/// 要能中断、要能回滚，还得把「搬了多少行」讲清楚。塞进 `_open()` 里，
/// 一旦出问题就变成「数据库打不开」这种含糊的故障。
///
/// 顺序上刻意做成「先留底、再搬、最后才删底」：
///
/// 1. 老明文库改名成 `younum.db.plain`（同一目录内改名，几乎瞬间完成）；
/// 2. 新建加密库（走完整的建表 + 迁移链，所以老库在 v1/v2/v3 也能搬）；
/// 3. 在**一个事务**里把所有表逐张搬过去，并核对行数；
/// 4. 核对通过才删掉 `.plain`。
///
/// 任何一步失败都不会留下「搬了一半」的库：删掉半成品、把 `.plain` 改回来，
/// 调用方照旧用明文库打开 —— 数据一条不少，只是这一轮没加密上。
///
/// 中断恢复也是同一条规则：启动时看到 `.plain` 还在，就认为上一次没搬完，
/// 把它改回来重来一遍。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:sqflite_sqlcipher/sqflite.dart';

import 'sqflite_ledger_store.dart';

/// 迁移结果。
enum EncryptionOutcome {
  /// 已经是加密库，什么都不用做。
  alreadyEncrypted,

  /// 这一次搬完了。
  migrated,

  /// 还没有数据库（全新安装）—— 存储层会直接建加密库。
  freshInstall,

  /// 没搬成，已回滚成明文库。
  failed,
}

/// 迁移做了什么。
class EncryptionResult {
  const EncryptionResult({
    required this.outcome,
    this.copiedRows = 0,
    this.tables = 0,
    this.failure,
  });

  final EncryptionOutcome outcome;

  /// 一共搬了多少行 —— 打印出来能对上账，比只说「成功」有用。
  final int copiedRows;

  final int tables;

  /// 失败原因（给用户或日志看）。
  final String? failure;

  bool get isEncrypted => outcome == EncryptionOutcome.alreadyEncrypted ||
      outcome == EncryptionOutcome.migrated;

  @override
  String toString() =>
      'EncryptionResult(${outcome.name}, $tables 表 / $copiedRows 行'
      '${failure == null ? '' : ', $failure'})';
}

/// 明文 SQLite 文件的开头 16 个字节。加密库**没有**这个魔数。
final Uint8List _sqliteMagic = Uint8List.fromList(
  'SQLite format 3\u0000'.codeUnits,
);

abstract final class DatabaseEncryption {
  /// 老库的留底文件名后缀。
  static const String plaintextSuffix = '.plain';

  /// 确保 [path] 上是一个加密库。
  ///
  /// [password] 是数据库口令；[factory] 必须与存储层用的是同一个
  /// （否则会拿到两个不同的单例缓存）。
  static Future<EncryptionResult> ensureEncrypted({
    required DatabaseFactory factory,
    required String path,
    required String password,
  }) async {
    final file = File(path);
    final backup = File('$path$plaintextSuffix');

    // 上一次没搬完（留底还在）：把它改回来重来一遍。
    // 半成品加密库直接丢弃 —— 它的内容本来就不完整。
    if (backup.existsSync()) {
      if (file.existsSync()) file.deleteSync();
      backup.renameSync(path);
    }

    if (!file.existsSync()) {
      return const EncryptionResult(outcome: EncryptionOutcome.freshInstall);
    }
    if (!await _isPlaintext(file)) {
      return const EncryptionResult(
        outcome: EncryptionOutcome.alreadyEncrypted,
      );
    }

    // 1. 留底。
    file.renameSync(backup.path);

    Database? target;
    try {
      // 2. 建加密库：这里会跑完整建表与迁移链，
      //    所以老库停在 v1/v2/v3 也能搬过来。
      target = await factory.openDatabase(
        path,
        options: SqfliteLedgerStore.buildOptions(password: password),
      );

      // 3. 搬数据。
      final copied = await _copyAll(from: backup.path, to: target, factory: factory);

      // 4. 核对无误才删留底。
      backup.deleteSync();
      return EncryptionResult(
        outcome: EncryptionOutcome.migrated,
        copiedRows: copied.$1,
        tables: copied.$2,
      );
    } on Object catch (error) {
      // 回滚：删掉半成品，把明文库改回来。调用方会照旧用明文打开。
      try {
        await target?.close();
      } catch (_) {
        // 关不上也要继续回滚。
      }
      try {
        if (file.existsSync()) file.deleteSync();
        if (backup.existsSync()) backup.renameSync(path);
      } catch (_) {
        // 连回滚都失败的话，至少把原因带上去，让人能手动救。
      }
      return EncryptionResult(
        outcome: EncryptionOutcome.failed,
        failure: '数据加密没有完成：$error',
      );
    }
  }

  /// 文件开头是不是明文 SQLite。
  static Future<bool> _isPlaintext(File file) async {
    final handle = await file.open();
    try {
      final header = await handle.read(_sqliteMagic.length);
      if (header.length < _sqliteMagic.length) return false;
      for (var i = 0; i < _sqliteMagic.length; i++) {
        if (header[i] != _sqliteMagic[i]) return false;
      }
      return true;
    } finally {
      await handle.close();
    }
  }

  /// 逐表搬运，返回 (行数, 表数)。
  ///
  /// 表的清单从**目标库**的 `sqlite_master` 里取：目标库是这次新建的，
  /// 结构与代码一致；老库里可能多出已经被删掉的旧表，那些不该带过来。
  static Future<(int, int)> _copyAll({
    required String from,
    required Database to,
    required DatabaseFactory factory,
  }) async {
    final source = await factory.openDatabase(
      from,
      // 老库用同一套选项打开：迁移链会先把它升到当前版本，
      // 于是每张表的列与当前代码一致，逐列照搬不会错位。
      options: SqfliteLedgerStore.buildOptions(),
      // 注意：不传 readOnly —— 老库需要被迁移链写一次（升版本号），
      // 而且它与加密库是两个不同的文件，不会串味。
    );

    try {
      final tables = <String>[
        for (final row in await to.query(
          'sqlite_master',
          columns: <String>['name'],
          where: "type = 'table' AND name NOT LIKE 'sqlite_%'",
        ))
          row['name']! as String,
      ];

      var rows = 0;
      // 外键在搬运期间关掉：逐表插入时顺序不可能满足所有引用，
      // 而数据本身是自洽的（来自同一个库）。SQLite 不允许在事务里改这个开关，
      // 所以放在事务外面。
      await to.execute('PRAGMA foreign_keys = OFF');
      try {
        await to.transaction((txn) async {
          for (final table in tables) {
            final data = await source.query(table);
            if (data.isEmpty) continue;
            final batch = txn.batch();
            for (final row in data) {
              batch.insert(table, row);
            }
            await batch.commit(noResult: true);
            rows += data.length;
          }
        });
      } finally {
        await to.execute('PRAGMA foreign_keys = ON');
      }

      // 核对行数：少一行都不算成功 —— 账目数据没有「差不多」。
      for (final table in tables) {
        final expected = await _count(source, table);
        final actual = await _count(to, table);
        if (expected != actual) {
          throw StateError('$table 的行数对不上（$expected → $actual）');
        }
      }

      return (rows, tables.length);
    } finally {
      await source.close();
    }
  }

  /// 数一张表有多少行。
  static Future<int> _count(DatabaseExecutor db, String table) async {
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM $table');
    return (rows.first['c']! as int);
  }
}
