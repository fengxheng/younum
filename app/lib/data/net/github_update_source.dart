import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/repositories/update_ports.dart';
import '../../domain/rules/update_rules.dart';

/// 从 GitHub Releases 读最新版本。
///
/// 用 `dart:io` 的 `HttpClient` 而不是再加一个 http 包：这一处只发一个 GET、
/// 只读一小段 JSON，标准库够用（与「不加第三方依赖」的取舍一致）。
///
/// 三件事刻意做死：
///
/// 1. **超时很短**（6 秒）。失败就当作没检查，绝不拖慢启动；
/// 2. **任何错误都变成 [UpdateUnreadable]**，不抛出去 —— 应用里没有一处
///    应该因为「版本查不到」而报错；
/// 3. **不带任何用户数据**：请求头只有 GitHub 要求的 `Accept` 与 `User-Agent`，
///    没有设备号、没有安装 ID、没有账单相关的任何东西。
class GithubUpdateSource implements UpdateSource {
  GithubUpdateSource({
    required this.owner,
    required this.repo,
    this.timeout = const Duration(seconds: 6),
    HttpClient? client,
  }) : _client = client ?? HttpClient();

  final String owner;
  final String repo;
  final Duration timeout;
  final HttpClient _client;

  Uri get latestReleaseUri =>
      Uri.https('api.github.com', '/repos/$owner/$repo/releases/latest');

  @override
  Future<UpdateReadResult> fetchLatest() async {
    try {
      final request = await _client.getUrl(latestReleaseUri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      // GitHub 要求带 User-Agent，否则直接 403。
      request.headers.set(HttpHeaders.userAgentHeader, 'younum-app');
      request.followRedirects = true;

      final response = await request.close().timeout(timeout);
      if (response.statusCode == HttpStatus.notFound) {
        // 仓库还没有发过 Release：这不是错误，如实说「还没发布过版本」。
        await response.drain<void>();
        return const UpdateUnreadable('作者还没有发布过正式版本');
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return UpdateUnreadable('版本信息读不到（HTTP ${response.statusCode}）');
      }

      final body = await response.transform(utf8.decoder).join().timeout(timeout);
      final decoded = jsonDecode(body);
      return UpdateRules.readLatest(decoded);
    } on TimeoutException {
      return const UpdateUnreadable('检查更新超时了，稍后再试');
    } on SocketException {
      // 断网、被墙、DNS 失败都走这里：**安静**，不弹任何东西。
      return const UpdateUnreadable('连不上网络，稍后再试');
    } on FormatException {
      return const UpdateUnreadable('版本信息的格式不对');
    } on Object catch (error) {
      return UpdateUnreadable('检查更新出错了：$error');
    }
  }

  /// 关掉连接池。应用退出时用不到（进程结束就没了），
  /// 但测试里需要它能释放，避免「测试跑完还有活动连接」的告警。
  void close() => _client.close(force: true);
}
