import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:younum/domain/rules/update_rules.dart';

/// 在线升级的判定规则。
///
/// 这一组锁住的是**不被数据骗**：GitHub 的响应可能缺少字段、可能没有 APK、
/// 版本号可能写得千奇百怪。判断错一次的后果很具体 —— 给用户推一个更旧的版本，
/// 或者把「没查到」说成「已是最新」。
void main() {
  /// 一份像真的响应：只保留用得上的字段。
  Map<String, Object?> releaseJson({
    String tag = 'v1.1.0+2',
    List<Map<String, Object?>>? assets,
    String body = '',
  }) => <String, Object?>{
    'tag_name': tag,
    'html_url': 'https://github.com/fengxheng/younum/releases/tag/$tag',
    'body': body,
    'assets': assets ??
        <Map<String, Object?>>[
          <String, Object?>{
            'name': 'younum-1.1.0-2.apk',
            'browser_download_url':
                'https://github.com/fengxheng/younum/releases/download/$tag/younum.apk',
          },
        ],
  };

  group('读版本信息', () {
    test('正常响应：版本号、APK 地址、Release 地址都读出来', () {
      final result = UpdateRules.readLatest(releaseJson());

      expect(result, isA<UpdateFound>());
      final info = (result as UpdateFound).info;
      expect(info.versionCode, 2);
      expect(info.versionName, '1.1.0');
      expect(info.apkUrl, endsWith('younum.apk'));
      expect(info.releaseUrl, contains('/releases/tag/'));
    });

    test('没有 APK 的 release 当作读不到，而不是给一个点了会失败的按钮', () {
      final result = UpdateRules.readLatest(
        releaseJson(assets: <Map<String, Object?>>[]),
      );

      expect(result, isA<UpdateUnreadable>());
      expect((result as UpdateUnreadable).reason, contains('安装包'));
    });

    test('源码 zip 不算安装包', () {
      final result = UpdateRules.readLatest(
        releaseJson(
          assets: <Map<String, Object?>>[
            <String, Object?>{
              'name': 'Source code (zip)',
              'browser_download_url': 'https://github.com/x.zip',
            },
          ],
        ),
      );
      expect(result, isA<UpdateUnreadable>());
    });

    test('版本号里没有 build number 就不猜，如实说看不懂', () {
      // 猜一个数字出来的后果是给用户推错版本。
      final result = UpdateRules.readLatest(releaseJson(tag: 'latest'));
      expect(result, isA<UpdateUnreadable>());
    });

    test('响应不是对象、缺字段都当作读不到，不抛异常', () {
      expect(UpdateRules.readLatest(null), isA<UpdateUnreadable>());
      expect(UpdateRules.readLatest(<Object?>[]), isA<UpdateUnreadable>());
      expect(
        UpdateRules.readLatest(<String, Object?>{'tag_name': 'v1+1'}),
        isA<UpdateUnreadable>(),
      );
    });

    test('真的 JSON 字符串也能走通（端到端的一小步）', () {
      final decoded = jsonDecode(jsonEncode(releaseJson(tag: 'v2.0.0+7')));
      final result = UpdateRules.readLatest(decoded);
      expect(result, isA<UpdateFound>());
      expect((result as UpdateFound).info.versionCode, 7);
      expect(result.info.versionName, '2.0.0');
    });
  });

  group('版本号解析', () {
    test('tag 的几种常见写法都能认出来', () {
      expect(UpdateRules.versionCodeOf('v1.1.0+2'), 2);
      expect(UpdateRules.versionCodeOf('1.4'), 4);
      expect(UpdateRules.versionCodeOf('release-12'), 12);
      expect(UpdateRules.versionCodeOf('v1.0.0 (13)'), 13);
      expect(UpdateRules.versionCodeOf('latest'), isNull);
    });

    test('给人看的版本号去掉 v 与 build number', () {
      expect(UpdateRules.versionNameOf('v1.1.0+2'), '1.1.0');
      expect(UpdateRules.versionNameOf('1.1.0-2'), '1.1.0');
      expect(UpdateRules.versionNameOf('v2.0'), '2.0');
    });
  });

  group('该不该提示', () {
    test('候选更高才提示', () {
      expect(UpdateRules.shouldPrompt(currentCode: 1, candidateCode: 2), isTrue);
      expect(UpdateRules.shouldPrompt(currentCode: 2, candidateCode: 2), isFalse);
      expect(UpdateRules.shouldPrompt(currentCode: 3, candidateCode: 2), isFalse);
    });

    test('忽略过的版本不再提示，但更高的版本照旧提示', () {
      // 忽略的语义是「这一版我先不装」，不是「以后别告诉我」。
      expect(
        UpdateRules.shouldPrompt(currentCode: 1, candidateCode: 2, skippedCode: 2),
        isFalse,
      );
      expect(
        UpdateRules.shouldPrompt(currentCode: 1, candidateCode: 3, skippedCode: 2),
        isTrue,
      );
    });

    test('装上更新之后，过期的忽略记录会被清掉', () {
      expect(
        UpdateRules.shouldKeepSkipped(currentCode: 3, skippedCode: 2),
        isFalse,
        reason: '已经装上更新的那一版了，忽略记录没有意义',
      );
      expect(UpdateRules.shouldKeepSkipped(currentCode: 2, skippedCode: 2), isTrue);
      expect(UpdateRules.shouldKeepSkipped(currentCode: 1, skippedCode: null), isFalse);
    });
  });
}
