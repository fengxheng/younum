import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart' show databaseFactory;

import 'app/app.dart';
import 'core/preferences/app_state_store.dart';
import 'core/preferences/reminder_store.dart';
import 'core/preferences/theme_controller.dart';
import 'core/preferences/theme_store.dart';
import 'core/preferences/update_store.dart';
import 'data/db/database_encryption.dart';
import 'data/db/sqflite_ledger_store.dart';
import 'data/files/app_files_directory.dart';
import 'data/files/icon_asset_store.dart';
import 'data/files/icon_image_processor.dart';
import 'data/files/share_poster_renderer.dart';
import 'data/files/system_document_saver.dart';
import 'data/files/system_file_source.dart';
import 'data/files/system_image_source.dart';
import 'data/memory/in_memory_ledger_store.dart';
import 'data/net/github_update_source.dart';
import 'data/platform/system_database_secret.dart';
import 'data/platform/system_reminder_scheduler.dart';
import 'data/platform/system_update_installer.dart';
import 'domain/repositories/database_secret.dart';
import 'domain/repositories/icon_asset_ports.dart';
import 'domain/repositories/document_saver.dart';
import 'domain/repositories/image_file_source.dart';
import 'domain/repositories/ledger_file_source.dart';
import 'domain/repositories/ledger_repository.dart';
import 'domain/repositories/ledger_store.dart';
import 'domain/repositories/reminder_scheduler.dart';
import 'domain/repositories/update_ports.dart';

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
  UpdateStore updateStore;
  LedgerStore ledgerStore;
  // 分类图片的文件柜。目录从平台通道拿（`filesDir`），这里不猜。
  final IconAssetStore iconFiles = FileIconAssetStore(
    directoryOf: systemFilesDirectory,
  );

  // 数据库加密（方案 A）。
  //
  // 顺序很重要：**先把老明文库换成加密库，再用口令打开它**。
  // 口令由 Android Keystore 保管（它自己不出 Keystore，所以文件被拷走也没用）。
  // 取不到口令时**不偷偷换一把新的**，而是这一轮不加密并把原因带上去 ——
  // 否则用户会看到一个空账本，那看起来就像账单被删了。
  String? databasePassword;
  String? encryptionNote;
  try {
    final secret = SystemDatabaseSecret();
    final passphrase = await secret.databasePassphrase();
    if (passphrase != null) {
      final path = p.join(
        await databaseFactory.getDatabasesPath(),
        SqfliteLedgerStore.fileName,
      );
      final result = await DatabaseEncryption.ensureEncrypted(
        factory: databaseFactory,
        path: path,
        password: passphrase,
      );
      debugPrint('数据库加密：$result');
      if (result.isEncrypted) {
        databasePassword = passphrase;
      } else {
        encryptionNote = result.failure ?? '数据加密没有完成，账单仍是未加密存储';
      }
    }
  } on DatabaseSecretUnavailable catch (error) {
    encryptionNote = error.message;
    debugPrint('数据库口令取不出来，本轮不加密：${error.message}');
  } on Object catch (error) {
    encryptionNote = '数据加密没有完成：$error';
    debugPrint('数据库加密出错：$error');
  }

  try {
    themeStore = await SharedPreferencesThemeStore.open();
    appStateStore = await SharedPreferencesAppStateStore.open();
    reminderStore = await SharedPreferencesReminderStore.open();
    updateStore = await SharedPreferencesUpdateStore.open();
    ledgerStore = SqfliteLedgerStore(password: databasePassword);
  } catch (_) {
    themeStore = InMemoryThemeStore();
    appStateStore = InMemoryAppStateStore();
    reminderStore = InMemoryReminderStore();
    updateStore = InMemoryUpdateStore();
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

  // 启动时把「上次提交没写完」的导入收尾（指南 10.2 / 阶段 7）。
  // 库里已经有这批交易就补记为已提交，没有就放回待提交 —— 两种都不能让用户
  // 再提交一次而重复入账。失败也不影响使用，如实打日志即可。
  try {
    final recovery = await repository.recoverInterruptedImports();
    if (recovery.reopened > 0 || recovery.closed > 0) {
      debugPrint(
        '导入恢复：放回待提交 ${recovery.reopened} 批，补记已提交 ${recovery.closed} 批',
      );
    }
  } catch (error) {
    debugPrint('导入恢复失败（不影响使用）：$error');
  }

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

  // 在线升级。
  //
  // ⚠️ 这是全应用**唯一**联网的地方：只向 GitHub 要一个公开的版本号，
  // 再（经用户同意后）下载安装包。账单数据不参与。
  // 版本号从系统读（`PackageManager`），不是从 pubspec 抄一份：
  // 抄的那份迟早会和真正装上的包对不上，而升级判断全靠它。
  // 读不到就不做升级提示 —— 宁可不说，也不拿猜出来的版本去比。
  final updateInstaller = SystemUpdateInstaller();
  final githubUpdateSource = GithubUpdateSource(
    owner: 'fengxheng',
    repo: 'younum',
  );
  AppVersion? appVersion;
  try {
    appVersion = await updateInstaller.readAppVersion();
  } catch (error) {
    debugPrint('读不到版本号，本次不做升级检查：$error');
  }

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
      updateSource: githubUpdateSource,
      updateInstaller: updateInstaller,
      updateStore: updateStore,
      appVersion: appVersion,
      databaseEncrypted: databasePassword != null,
      databaseEncryptionNote: encryptionNote,
    ),
  );
}


