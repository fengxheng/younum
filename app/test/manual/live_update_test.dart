import 'package:flutter_test/flutter_test.dart';
import 'package:younum/data/net/github_update_source.dart';
import 'package:younum/domain/rules/update_rules.dart';

/// 对着**真的** GitHub 接口跑一次，确认线上拿得到东西。
///
/// 默认**跳过**：单元测试不该依赖网络（断网、限流、被墙都会让测试变红，
/// 而那是环境问题，不是代码问题）。要跑就显式打开：
///
/// ```powershell
/// flutter test test/manual/live_update_test.dart --dart-define=YOUNUM_LIVE=1
/// ```
///
/// 这两条用例的价值在于：单元测试里的 JSON 是**我编的**，而线上那个是
/// **真的** —— 字段名、嵌套方式、有没有 `assets`，只有真跑一次才知道。
void main() {
  const live = bool.fromEnvironment('YOUNUM_LIVE');

  test('线上真实接口：能读到版本号与 APK 地址', () async {
    final source = GithubUpdateSource(owner: 'fengxheng', repo: 'younum');
    try {
      final result = await source.fetchLatest();

      switch (result) {
        case UpdateFound(:final info):
          // ignore: avoid_print
          print(
            'LIVE OK: ${info.versionName}+${info.versionCode} '
            'apk=${info.apkUrl}',
          );
          expect(info.versionCode, greaterThan(0));
          expect(info.apkUrl, contains('github.com'));
        case UpdateUnreadable(:final reason):
          // 仓库还没发过版本也算「读到了线上状态」，但要让跑的人看见原因。
          // ignore: avoid_print
          print('LIVE UNREADABLE: $reason');
          expect(reason, isNotEmpty);
      }
    } finally {
      source.close();
    }
  }, skip: live ? false : '需要 --dart-define=YOUNUM_LIVE=1 才跑（要联网）');
}
