import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:younum/core/preferences/update_store.dart';
import 'package:younum/domain/repositories/update_ports.dart';
import 'package:younum/domain/rules/update_rules.dart';
import 'package:younum/features/profile/update_controller.dart';

/// 升级状态机。
///
/// 两条硬要求各有一个用例守着：**不打扰**（查不到就别出声）、
/// **不撒谎**（没查到不能说成「已是最新」）。
void main() {
  UpdateInfo info(int code, [String name = '1.1.0']) => UpdateInfo(
    versionCode: code,
    versionName: name,
    apkUrl: 'https://example.com/younum-$code.apk',
    releaseUrl: 'https://example.com/releases/$code',
  );

  late _FakeSource source;
  late _FakeInstaller installer;
  late InMemoryUpdateStore store;

  UpdateController controllerFor({int currentCode = 1}) => UpdateController(
    source: source,
    installer: installer,
    store: store,
    currentVersionCode: currentCode,
    currentVersionName: '1.0.0',
  );

  setUp(() {
    source = _FakeSource();
    installer = _FakeInstaller();
    store = InMemoryUpdateStore();
  });

  group('检查', () {
    test('有新版本：进入 available，并给出提示文案', () async {
      source.result = UpdateFound(info(2));
      final controller = controllerFor();

      await controller.check(byUser: true);

      expect(controller.phase, UpdatePhase.available);
      expect(controller.available?.versionCode, 2);
      expect(controller.message, contains('1.1.0'));
    });

    test('版本相同或更旧：说是最新，不提供下载', () async {
      source.result = UpdateFound(info(1));
      final controller = controllerFor(currentCode: 1);

      await controller.check(byUser: true);

      expect(controller.phase, UpdatePhase.upToDate);
      expect(controller.available, isNull, reason: '没有新版本就不该有下载按钮');
    });

    test('用户主动查失败：显示原因（但只在他问过之后）', () async {
      source.result = const UpdateUnreadable('连不上网络，稍后再试');
      final controller = controllerFor();

      await controller.check(byUser: true);

      expect(controller.phase, UpdatePhase.unreadable);
      expect(controller.message, '连不上网络，稍后再试');
      expect(controller.available, isNull);
    });

    test('启动时的静默检查失败：一声不吭', () async {
      source.result = const UpdateUnreadable('连不上网络，稍后再试');
      final controller = controllerFor();

      await controller.check();

      expect(controller.phase, UpdatePhase.unreadable);
      expect(controller.message, isNull, reason: '用户没问，就别告诉他查不到');
      expect(controller.userAsked, isFalse);
    });

    test('同时点两次只发一次请求', () async {
      source.result = UpdateFound(info(2));
      final controller = controllerFor();

      await Future.wait(<Future<void>>[
        controller.check(byUser: true),
        controller.check(byUser: true),
      ]);

      expect(source.calls, 1);
    });
  });

  group('忽略某个版本', () {
    test('忽略之后不再提示，但记录留在偏好里', () async {
      source.result = UpdateFound(info(2));
      final controller = controllerFor();
      await controller.check(byUser: true);
      expect(controller.phase, UpdatePhase.available);

      await controller.skipCurrent();

      expect(controller.phase, UpdatePhase.skipped);
      expect(await store.loadSkippedVersionCode(), 2);
      expect(controller.available, isNotNull, reason: '忽略不等于隐藏：还能手动装');
    });

    test('出现更高版本时，即使忽略过也要再提示一次', () async {
      await store.saveSkippedVersionCode(2);
      source.result = UpdateFound(info(3, '1.2.0'));
      final controller = controllerFor();

      await controller.check(byUser: true);

      expect(controller.phase, UpdatePhase.available);
    });

    test('装上更新之后清掉过期的忽略记录', () async {
      // 忽略记录只在「它还没过期」时有意义：用户已经装上 3 了，
      // 那条「忽略 2」就只是偏好里的一句废记录。
      await store.saveSkippedVersionCode(2);
      final controller = controllerFor(currentCode: 3);

      await controller.pruneSkipped();

      expect(await store.loadSkippedVersionCode(), isNull);
    });
  });

  group('下载与安装', () {
    test('安装成功后把「已交给系统」说清楚，而不是说「装好了」', () async {
      // 最后那一下「安装」是用户在系统界面上点的，我们不知道结果。
      source.result = UpdateFound(info(2));
      installer.outcome = const InstallHandedOff();
      final controller = controllerFor();
      await controller.check(byUser: true);

      await controller.install();

      expect(installer.installedUrls, <String>['https://example.com/younum-2.apk']);
      expect(controller.phase, UpdatePhase.available);
      expect(controller.message, contains('系统'));
    });

    test('失败：如实说原因，并且可以重试', () async {
      source.result = UpdateFound(info(2));
      installer.outcome = const InstallFailed('下载没有完成：服务器返回 404');
      final controller = controllerFor();
      await controller.check(byUser: true);

      await controller.install();

      expect(controller.message, '下载没有完成：服务器返回 404');
      expect(controller.available, isNotNull, reason: '失败了还能再试一次');
    });

    test('没有可装的新版本时，安装什么都不做', () async {
      final controller = controllerFor();
      await controller.install();
      expect(installer.installedUrls, isEmpty);
    });
  });
}

final class _FakeSource implements UpdateSource {
  UpdateReadResult result = const UpdateUnreadable('测试没准备结果');
  int calls = 0;

  @override
  Future<UpdateReadResult> fetchLatest() async {
    calls++;
    return result;
  }
}

final class _FakeInstaller implements UpdateInstaller {
  InstallOutcome outcome = const InstallHandedOff();
  final List<String> installedUrls = <String>[];

  @override
  ValueListenable<int?> get progress => _progress;
  final ValueNotifier<int?> _progress = ValueNotifier<int?>(null);

  @override
  Future<bool> canInstall() async => true;

  @override
  Future<void> openInstallSettings() async {}

  @override
  Future<InstallOutcome> downloadAndInstall(UpdateInfo info) async {
    installedUrls.add(info.apkUrl);
    return outcome;
  }
}
