/// 在线升级用到的两个「能力」端口。
///
/// 与选文件、保存文件、提醒同一套做法：**能做这件事的东西**从外面注入，
/// 纯逻辑与界面都不直接碰网络与系统安装器，因此可以替换、可以测。
///
/// ⚠️ 这是本应用里**唯一**会联网的地方。账单数据一个字节都不会发出去 ——
/// 请求的只是一个公开的版本号。
library;

import 'package:flutter/foundation.dart';

import '../rules/update_rules.dart';

/// 当前安装的版本。
///
/// 从**系统**读（`PackageManager`），不是从 pubspec 抄一份：
/// 抄过来的那份迟早会和真正装上的包对不上，而升级判断全靠它。
class AppVersion {
  const AppVersion({required this.versionName, required this.versionCode});

  final String versionName;
  final int versionCode;

  @override
  String toString() => '$versionName+$versionCode';
}

/// 去哪里问「最新版本是哪个」。
abstract interface class UpdateSource {
  /// 查一次。失败**不抛异常**，返回 [UpdateUnreadable] —— 升级检查
  /// 永远不该让应用崩掉，也不该拦住用户做别的事。
  Future<UpdateReadResult> fetchLatest();
}

/// 桌面、Web、测试环境：没有这套能力。
class UnsupportedUpdateSource implements UpdateSource {
  const UnsupportedUpdateSource();

  @override
  Future<UpdateReadResult> fetchLatest() async =>
      const UpdateUnreadable('这个平台上还不能检查更新');
}

/// 把安装包下载下来，再交给系统的安装界面。
///
/// 分成两步是因为中间那一步**必须由用户点**（系统会问「允许有数安装应用吗」），
/// 而我们不伪造这一步：做不到就如实说明原因。
abstract interface class UpdateInstaller {
  /// 下载进度（0–100）。没在下载时是 null。
  ///
  /// 几十兆的安装包要转上一分钟，界面上必须看得见在动。
  ValueListenable<int?> get progress;

  /// 这台设备允不允许安装未知来源的应用。
  Future<bool> canInstall();

  /// 打开系统的「安装未知应用」设置页，让用户自己打开开关。
  Future<void> openInstallSettings();

  /// 下载并交给系统安装器。返回给用户看的结果。
  Future<InstallOutcome> downloadAndInstall(UpdateInfo info);
}

/// 安装结果。
sealed class InstallOutcome {
  const InstallOutcome();
}

/// 已经交给系统安装器（用户在系统界面上点「安装」）。
final class InstallHandedOff extends InstallOutcome {
  const InstallHandedOff();
}

/// 用户取消，或者被系统拦下。不是错误，不必惊吓用户。
final class InstallCanceled extends InstallOutcome {
  const InstallCanceled();
}

/// 失败。[message] 可以直接给用户看。
final class InstallFailed extends InstallOutcome {
  const InstallFailed(this.message);

  final String message;
}

/// 桌面、Web、测试环境。
class UnsupportedUpdateInstaller implements UpdateInstaller {
  const UnsupportedUpdateInstaller();

  /// 这个实现永远不进下载，所以进度恒为 null。
  ///
  /// 用具静态常量而不是实例字段，是为了保住 `const` 构造 —— 它被当作
  /// `YounumApp` 的默认参数用。
  static final ValueNotifier<int?> _progress = ValueNotifier<int?>(null);

  @override
  ValueListenable<int?> get progress => _progress;

  @override
  Future<bool> canInstall() async => false;

  @override
  Future<void> openInstallSettings() async {}

  @override
  Future<InstallOutcome> downloadAndInstall(UpdateInfo info) async =>
      const InstallFailed('这个平台上还不能安装更新');
}
