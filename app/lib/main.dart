import 'package:flutter/material.dart';

import 'app/app.dart';
import 'core/preferences/app_state_store.dart';
import 'core/preferences/theme_controller.dart';
import 'core/preferences/theme_store.dart';
import 'data/db/sqflite_ledger_store.dart';
import 'data/memory/in_memory_ledger_store.dart';
import 'domain/repositories/ledger_repository.dart';
import 'domain/repositories/ledger_store.dart';

/// 应用入口。
///
/// 三件事在**首帧之前**完成：
///
/// 1. 读主题偏好，避免启动时先闪一下默认配色再切到用户选的（指南 7.2）；
/// 2. 读引导状态与账本模式；
/// 3. 打开本地数据库、建表与迁移，写入初始账本与分类。
///
/// 任何一步失败都**不**崩溃：退回内存实现，界面仍然可用，只是本次会话不落盘。
/// 但也不会假装已经保存 —— 界面上的「保存失败」提示来自真实的写入结果。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  ThemeStore themeStore;
  AppStateStore appStateStore;
  LedgerStore ledgerStore = SqfliteLedgerStore();
  try {
    themeStore = await SharedPreferencesThemeStore.open();
    appStateStore = await SharedPreferencesAppStateStore.open();
  } catch (_) {
    themeStore = InMemoryThemeStore();
    appStateStore = InMemoryAppStateStore();
    ledgerStore = InMemoryLedgerStore();
  }

  var repository = LedgerRepository(ledgerStore);
  try {
    await repository.initialize();
  } catch (error, stack) {
    // 数据库打不开（磁盘损坏、迁移失败等）：退到内存，让用户仍能看界面，
    // 并把原因打出来，而不是白屏。
    debugPrint('本地数据库初始化失败，本次会话不落盘：$error\n$stack');
    ledgerStore = InMemoryLedgerStore();
    repository = LedgerRepository(ledgerStore);
    await repository.initialize();
  }

  final themeController = await ThemeController.restore(themeStore);
  final appStateController = await AppStateController.restore(appStateStore);

  runApp(
    YounumApp(
      themeController: themeController,
      appStateController: appStateController,
      ledgerRepository: repository,
    ),
  );
}
