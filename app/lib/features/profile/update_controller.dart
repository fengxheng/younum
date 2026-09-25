import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../core/preferences/update_store.dart';
import '../../domain/repositories/update_ports.dart';
import '../../domain/rules/update_rules.dart';

/// 升级检查处于哪一步。
enum UpdatePhase {
  /// 还没查过（或还没查完）。
  idle,

  /// 正在查。
  checking,

  /// 已经是最新的。
  upToDate,

  /// 有新版本可用。
  available,

  /// 有新版本，但用户忽略过它（只在手动进来时显示）。
  skipped,

  /// 正在下载并交给系统安装器。
  installing,

  /// 查不到（断网、超时、仓库没发过版本……）。
  unreadable,
}

/// 在线升级的状态机。
///
/// 设计上有两条硬要求：
///
/// 1. **不打扰**：检查失败什么都不做。断网、被墙、超时都是常态，
///    不能每次启动弹一个「检查更新失败」。
/// 2. **不撒谎**：「已是最新」只在**真的查到并且比对过**之后才说；
///    查不到就说查不到，绝不把「没查到」说成「已是最新」。
class UpdateController extends ChangeNotifier {
  UpdateController({
    required this.source,
    required this.installer,
    required this.store,
    this.currentVersionCode = 0,
    this.currentVersionName = '',
  });

  final UpdateSource source;
  final UpdateInstaller installer;
  final UpdateStore store;

  /// 当前安装的版本。由构建带进来（`versionCode` / `versionName`）。
  final int currentVersionCode;
  final String currentVersionName;

  UpdatePhase _phase = UpdatePhase.idle;
  UpdateInfo? _available;
  String? _message;
  int? _skippedCode;
  bool _disposed = false;

  /// 正在跑的那次检查，用来避免重复请求（启动时 + 用户手动点可能撞上）。
  Future<void>? _inFlight;

  UpdatePhase get phase => _phase;

  /// 可安装的新版本；没有时是 null。
  UpdateInfo? get available => _available;

  /// 给用户看的一句话（失败原因、安装结果等）。
  String? get message => _message;

  /// 用户忽略过的版本序号。
  int? get skippedVersionCode => _skippedCode;

  /// 下载进度（0–100），没在下载时是 null。
  ValueListenable<int?> get downloadProgress => installer.progress;

  /// 用户主动来过这一页没有。
  ///
  /// 启动时的静默检查如果没查到东西，界面上不该一直挂着「查不到」；
  /// 只有用户自己点了「检查更新」，失败原因才值得显示出来。
  bool _userAsked = false;

  bool get userAsked => _userAsked;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// 查一次最新版本。
  ///
  /// [byUser] 为 true 时会把失败原因显示出来；启动时的静默检查不显示。
  /// 已经在查就直接复用那一次（用户连点两下不会发两次请求）。
  Future<void> check({bool byUser = false}) async {
    if (byUser) _userAsked = true;
    final running = _inFlight;
    if (running != null) {
      await running;
      return;
    }
    _inFlight = _run(byUser: byUser);
    try {
      await _inFlight;
    } finally {
      _inFlight = null;
    }
  }

  Future<void> _run({required bool byUser}) async {
    _phase = UpdatePhase.checking;
    if (byUser) _message = null;
    _safeNotify();

    _skippedCode = await store.loadSkippedVersionCode();
    final result = await source.fetchLatest();
    if (_disposed) return;

    switch (result) {
      case UpdateFound(:final info):
        if (!UpdateRules.isNewer(
          currentCode: currentVersionCode,
          candidateCode: info.versionCode,
        )) {
          _available = null;
          _phase = UpdatePhase.upToDate;
          _message = null;
          break;
        }
        _available = info;
        final prompt = UpdateRules.shouldPrompt(
          currentCode: currentVersionCode,
          candidateCode: info.versionCode,
          skippedCode: _skippedCode,
        );
        _phase = prompt ? UpdatePhase.available : UpdatePhase.skipped;
        _message = prompt
            ? '发现新版本 ${info.versionName}'
            : '${info.versionName} 已被你忽略，点「去更新」仍可安装';
      case UpdateUnreadable(:final reason):
        _available = null;
        _phase = UpdatePhase.unreadable;
        // 静默检查失败不留痕：用户没问，就别告诉他「查不到」。
        _message = byUser ? reason : null;
    }
    _safeNotify();
  }

  /// 忽略当前这个新版本：同一个版本不再提示，出现更高版本时再说。
  Future<void> skipCurrent() async {
    final info = _available;
    if (info == null) return;
    _skippedCode = info.versionCode;
    await store.saveSkippedVersionCode(info.versionCode);
    if (_disposed) return;
    _phase = UpdatePhase.skipped;
    _message = '已忽略 ${info.versionName}，出现更新的版本时会再提醒你';
    _safeNotify();
  }

  /// 这个平台上能不能自己装更新（桌面与测试环境不能）。
  Future<bool> canInstall() => installer.canInstall();

  /// 打开系统的「安装未知应用」设置页。
  Future<void> openInstallSettings() => installer.openInstallSettings();

  /// 下载并安装。
  ///
  /// 下载下来的 APK 交给**系统的安装器** —— 最后那一下「安装」必须用户自己点，
  /// 应用不会也不能替他做。
  Future<void> install() async {
    final info = _available;
    if (info == null) return;

    _phase = UpdatePhase.installing;
    _message = '正在下载安装包，请在系统的安装界面完成安装';
    _safeNotify();

    final outcome = await installer.downloadAndInstall(info);
    if (_disposed) return;

    switch (outcome) {
      case InstallHandedOff():
        _phase = UpdatePhase.available;
        _message = '安装包已交给系统，请在系统界面点「安装」';
      case InstallCanceled():
        _phase = UpdatePhase.available;
        _message = '取消安装，随时可以再来一次';
      case InstallFailed(:final message):
        _phase = UpdatePhase.available;
        _message = message;
    }
    _safeNotify();
  }

  /// 版本变化后清掉没意义的「忽略」记录（装上更新之后就过期了）。
  ///
  /// 在 [check] 里顺带做：每次检查都是「现在的我」和「最新的它」比较，
  /// 所以这里只看当前版本号。
  Future<void> pruneSkipped() async {
    final skipped = await store.loadSkippedVersionCode();
    if (UpdateRules.shouldKeepSkipped(
      currentCode: currentVersionCode,
      skippedCode: skipped,
    )) {
      _skippedCode = skipped;
      return;
    }
    _skippedCode = null;
    await store.saveSkippedVersionCode(null);
  }
}

/// 把升级状态提供给子树（「我的 → 检查更新」那一页，以及入口上的角标）。
class UpdateScope extends InheritedNotifier<UpdateController> {
  const UpdateScope({
    super.key,
    required UpdateController controller,
    required super.child,
  }) : super(notifier: controller);

  static UpdateController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<UpdateScope>();
    assert(scope != null, 'UpdateScope 未挂载：请检查 app.dart 的根部装配。');
    return scope!.notifier!;
  }
}
