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

  /// 列表接口。只在「一条正式发布都没有」时用得上（见 [fetchLatest]）。
  Uri get releaseListUri =>
      Uri.https('api.github.com', '/repos/$owner/$repo/releases', {
        'per_page': '10',
      });

  @override
  Future<UpdateReadResult> fetchLatest() async {
    try {
      final latest = await _get(latestReleaseUri);
      switch (latest) {
        case _HttpBody(:final decoded):
          return UpdateRules.readLatest(decoded);
        case _HttpStatus(:final code) when code == HttpStatus.notFound:
          // `releases/latest` 不返回**预发布**：仓库里只发过预发布时它也是 404。
          // 所以退回列表看一眼 —— 否则这一阶段整条升级路径都走不通。
          return await _readFromList();
        case _HttpStatus(:final code):
          return UpdateUnreadable('版本信息读不到（HTTP $code）');
        case _:
          return const UpdateUnreadable('版本信息的格式不对');
      }
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

  Future<UpdateReadResult> _readFromList() async {
    final listed = await _get(releaseListUri);
    switch (listed) {
      case _HttpBody(:final decoded):
        return UpdateRules.readFromList(decoded);
      case _HttpStatus(:final code) when code == HttpStatus.notFound:
        return const UpdateUnreadable('作者还没有发布过版本');
      case _HttpStatus(:final code):
        return UpdateUnreadable('版本信息读不到（HTTP $code）');
      case _:
        return const UpdateUnreadable('版本信息的格式不对');
    }
  }

  /// 发一个 GET，把「响应体」与「状态码」分开返回。
  Future<Object> _get(Uri uri) async {
    final request = await _client.getUrl(uri).timeout(timeout);
    request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    // GitHub 要求带 User-Agent，否则直接 403。
    request.headers.set(HttpHeaders.userAgentHeader, 'younum-app');
    request.followRedirects = true;

    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      return _HttpStatus(response.statusCode);
    }
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    return _HttpBody(jsonDecode(body));
  }

  /// 关掉连接池。应用退出时用不到（进程结束就没了），
  /// 但测试里需要它能释放，避免「测试跑完还有活动连接」的告警。
  void close() => _client.close(force: true);
}

/// 拿到了响应体。
final class _HttpBody {
  const _HttpBody(this.decoded);

  final Object? decoded;
}

/// 状态码不是 200（404 也要区分对待，所以不能只当成错误）。
final class _HttpStatus {
  const _HttpStatus(this.code);

  final int code;
}
