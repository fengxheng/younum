import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../domain/repositories/update_ports.dart';
import '../../domain/rules/update_rules.dart';

/// 在线升级的原生通道（Kotlin 侧见 `MainActivity`）。
///
/// 为什么升级要过原生：
///
/// 1. 下载几十兆的安装包、写进缓存目录，交给**系统安装器**的活儿是平台的事；
/// 2. 「允许安装未知应用」这个开关只有用户能在系统设置里打开 ——
///    应用能做的是**把他带到那个页面**，不能替他点。
///
/// 这个类只做翻译：把原生返回的简短字符串变成 [InstallOutcome]，
/// 把原生发来的百分比转成可监听的进度。判断逻辑都在 Dart 侧。
class SystemUpdateInstaller implements UpdateInstaller {
  SystemUpdateInstaller({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  /// 与 `MainActivity.UPDATE_CHANNEL` 必须一致。
  static const String channelName = 'com.younum.app/update';

  final MethodChannel _channel;

  /// 下载进度（0–100）。没在下载时是 null。
  ///
  /// 用一个可监听的值而不是回调：界面只关心「现在到多少了」，
  /// 不需要在创建时就把它自己交给别人。
  final ValueNotifier<int?> _progress = ValueNotifier<int?>(null);

  @override
  ValueListenable<int?> get progress => _progress;

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method == 'progress') {
      final value = call.arguments;
      if (value is int) _progress.value = value;
    }
  }

  @override
  Future<bool> canInstall() async {
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 读当前安装的版本（`MainActivity.appVersion`）。
  ///
  /// 读不到就返回 null —— 调用方据此**不做升级提示**，而不是拿一个
  /// 猜出来的版本号去比较（比错的后果是给用户推一个更旧的版本）。
  Future<AppVersion?> readAppVersion() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('appVersion');
      final name = raw?['versionName'];
      final code = raw?['versionCode'];
      if (name is! String || code is! int) return null;
      return AppVersion(versionName: name, versionCode: code);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> openInstallSettings() async {
    try {
      await _channel.invokeMethod<bool>('openInstallSettings');
    } on MissingPluginException {
      // 桌面或测试环境：没有这个页面，什么也不做（按钮本来就不会出现）。
    } on PlatformException {
      // 打不开就算了：用户可以自己去系统设置里找。
    }
  }

  @override
  Future<InstallOutcome> downloadAndInstall(UpdateInfo info) async {
    _progress.value = 0;
    try {
      final code = await _channel.invokeMethod<String>('downloadAndInstall', {
        'url': info.apkUrl,
        // 文件名固定成「版本号」，方便用户在系统的下载/安装界面认出这是哪一版。
        'fileName': 'younum-${info.versionName}-${info.versionCode}.apk',
      });
      return _outcomeOf(code);
    } on MissingPluginException {
      return const InstallFailed('这个平台上还不能安装更新');
    } on PlatformException catch (error) {
      return InstallFailed(error.message ?? '安装没有完成');
    } finally {
      _progress.value = null;
    }
  }

  /// 原生只回这几种：`handedOff` / `needPermission` / `failed:原因`。
  ///
  /// 刻意用字符串而不是异常：这些都不是「程序出错了」，而是
  /// 用户接下来该怎么做，文案要能直接给他看。
  static InstallOutcome _outcomeOf(String? code) {
    if (code == null) return const InstallFailed('安装没有完成，可以再试一次');
    if (code == 'handedOff') return const InstallHandedOff();
    if (code == 'needPermission') {
      return const InstallFailed('需要先允许「有数」安装应用，再试一次');
    }
    if (code.startsWith('failed:')) {
      return InstallFailed(code.substring('failed:'.length));
    }
    return InstallFailed('安装没有完成：$code');
  }
}
