import 'package:flutter/material.dart';

import 'app/app.dart';
import 'core/preferences/app_state_store.dart';
import 'core/preferences/reminder_store.dart';
import 'core/preferences/theme_controller.dart';
import 'core/preferences/theme_store.dart';
import 'data/db/sqflite_ledger_store.dart';
import 'data/files/app_files_directory.dart';
import 'data/files/icon_asset_store.dart';
import 'data/files/icon_image_processor.dart';
import 'data/files/share_poster_renderer.dart';
import 'data/files/system_document_saver.dart';
import 'data/files/system_file_source.dart';
import 'data/files/system_image_source.dart';
import 'data/memory/in_memory_ledger_store.dart';
import 'data/platform/system_reminder_scheduler.dart';
import 'domain/repositories/icon_asset_ports.dart';
import 'domain/repositories/document_saver.dart';
import 'domain/repositories/image_file_source.dart';
import 'domain/repositories/ledger_file_source.dart';
import 'domain/repositories/ledger_repository.dart';
import 'domain/repositories/ledger_store.dart';
import 'domain/repositories/reminder_scheduler.dart';

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
  ReminderStore reminderStore;
  LedgerStore ledgerStore = SqfliteLedgerStore();
  // 分类图片的文件柜。目录从平台通道拿（`filesDir`），这里不猜。
  final IconAssetStore iconFiles = FileIconAssetStore(
    directoryOf: systemFilesDirectory,
  );
  try {
    themeStore = await SharedPreferencesThemeStore.open();
    appStateStore = await SharedPreferencesAppStateStore.open();
    reminderStore = await SharedPreferencesReminderStore.open();
  } catch (_) {
    themeStore = InMemoryThemeStore();
    appStateStore = InMemoryAppStateStore();
    reminderStore = InMemoryReminderStore();
    ledgerStore = InMemoryLedgerStore();
  }

  var repository = LedgerRepository(
    ledgerStore,
    thumbnails: const IconImageProcessor(),
    iconFiles: iconFiles,
  );
  try {
    await repository.initialize();
  } catch (error, stack) {
    // 数据库打不开（磁盘损坏、迁移失败等）：退到内存，让用户仍能看界面，
    // 并把原因打出来，而不是白屏。
    debugPrint('本地数据库初始化失败，本次会话不落盘：$error\n$stack');
    ledgerStore = InMemoryLedgerStore();
    repository = LedgerRepository(
      ledgerStore,
      thumbnails: const IconImageProcessor(),
      iconFiles: iconFiles,
    );
    await repository.initialize();
  }

  final themeController = await ThemeController.restore(themeStore);
  final appStateController = await AppStateController.restore(appStateStore);

  // 选账单文件的能力。
  //
  // 桌面与测试环境没有这条通道，[SystemFileSource.isAvailable] 会返回 false，
  // 界面据此把入口显灰 —— 而不是让用户点了才发现不行。
  // 这里不预判平台：判断留在实现里，注入点保持一个。
  final LedgerFileSource fileSource = SystemFileSource();

  // 分类图片图标的能力。
  //
  // 图片落在应用私有目录（指南 14.4.2）；三个注入点分开给，
  // 测试里换成假实现就能跑完整的「选图 → 裁切 → 落盘」路径。
  final ImageFileSource imageSource = SystemImageSource();

  // 导出能力。
  //
  // 海报用引擎现画（不引图片插件，也不存中间文件）；保存走系统的「创建文档」
  // 流程，字节直接递给系统，不把应用私有路径抖出去（指南 8.1）。
  const posterMaker = SharePosterRenderer();
  final DocumentSaver documentSaver = SystemDocumentSaver();

  // 每月整理提醒。调度在原生侧走 WorkManager + 通知渠道，
  // Dart 只负责「什么时候该有提醒」与如实上报状态（指南 8.2）。
  final ReminderScheduler reminderScheduler = SystemReminderScheduler();

  runApp(
    YounumApp(
      themeController: themeController,
      appStateController: appStateController,
      ledgerRepository: repository,
      ledgerFileSource: fileSource,
      imageFileSource: imageSource,
      posterMaker: posterMaker,
      documentSaver: documentSaver,
      reminderStore: reminderStore,
      reminderScheduler: reminderScheduler,
    ),
  );
}


