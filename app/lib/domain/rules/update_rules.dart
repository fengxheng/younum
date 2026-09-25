/// 在线升级的判定规则（纯函数，不碰网络、不碰系统）。
///
/// 分成三件事，各自都能单独测：
///
/// 1. 从 GitHub Releases 的 JSON 里**读出**「最新版本是什么」；
/// 2. 判断「这个版本比我现在的新吗」；
/// 3. 判断「该不该提示用户」—— 用户点过「忽略这个版本」就不再提，
///    除非出现了**更高**的版本。
library;

/// 一个可安装的新版本。
class UpdateInfo {
  const UpdateInfo({
    required this.versionCode,
    required this.versionName,
    required this.apkUrl,
    required this.releaseUrl,
    this.notes = '',
  });

  /// 版本序号。**比较新旧只看它**：`versionName` 是给人看的，可能回退或改名。
  final int versionCode;

  /// 给人看的版本号，例如 `1.1.0`。
  final String versionName;

  /// APK 的下载地址。
  final String apkUrl;

  /// Release 页面地址：下载失败或用户想看看说明时用得上。
  final String releaseUrl;

  /// 更新说明（Release 正文）。可能为空。
  final String notes;

  @override
  String toString() => 'UpdateInfo($versionName+$versionCode)';
}

/// 读版本信息的结果。
sealed class UpdateReadResult {
  const UpdateReadResult();
}

/// 读到了。
final class UpdateFound extends UpdateReadResult {
  const UpdateFound(this.info);

  final UpdateInfo info;
}

/// 没读到。原因要能直接说给用户听，但**默认不打扰用户**（见调用方）。
final class UpdateUnreadable extends UpdateReadResult {
  const UpdateUnreadable(this.reason);

  final String reason;
}

/// 升级判定。
abstract final class UpdateRules {
  /// 从 `releases` **列表**里挑一条可用的版本。
  ///
  /// 为什么需要它：GitHub 的 `releases/latest` **不返回预发布**，而发布的人
  /// 勾一下「pre-release」是很容易的事（这个项目上就发生过）。仓库里只有
  /// 预发布时，接口会 404，于是「作者还没有发布过正式版本」把整条升级路径
  /// 堵死 —— 而实际上用户想要的就是那个版本。
  ///
  /// 调用方的顺序是「先问 latest，拿不到再退回列表」：一旦有了正式发布，
  /// 预发布就不会再打扰用户，而只有预发布的阶段也能继续用。
  ///
  /// 挑选规则：跳过草稿与读不出来的条目，取 **build number 最大**的那条
  /// （不是「列表里的第一条」——列表顺序不是按版本排的）。
  static UpdateReadResult readFromList(Object? json) {
    if (json is! List) return const UpdateUnreadable('版本信息的格式不对');

    UpdateFound? best;
    for (final item in json) {
      if (item is! Map<String, Object?>) continue;
      // 草稿只对作者可见，不该拿它去提示用户。
      if (item['draft'] == true) continue;

      final result = readLatest(item);
      if (result is! UpdateFound) continue;
      if (best == null || result.info.versionCode > best.info.versionCode) {
        best = result;
      }
    }
    if (best == null) return const UpdateUnreadable('作者还没有发布过版本');
    return best;
  }

  /// 从 GitHub `releases/latest` 的响应体里读出最新版本。
  ///
  /// 只认一种「可用」：**带 `.apk` 资源的 release**。没有 APK 的 release
  /// （比如只发了源码 zip）对用户没有任何用，如实返回读不到，
  /// 而不是给一个点了会失败的下载按钮。
  static UpdateReadResult readLatest(Object? json) {
    if (json is! Map<String, Object?>) {
      return const UpdateUnreadable('版本信息的格式不对');
    }

    final tag = json['tag_name'];
    if (tag is! String || tag.trim().isEmpty) {
      return const UpdateUnreadable('这个版本没有版本号');
    }

    final assets = json['assets'];
    if (assets is! List) {
      return const UpdateUnreadable('这个版本没有可下载的文件');
    }

    String? apkUrl;
    for (final asset in assets) {
      if (asset is! Map<String, Object?>) continue;
      final name = asset['name'];
      final url = asset['browser_download_url'];
      if (name is String &&
          name.toLowerCase().endsWith('.apk') &&
          url is String &&
          url.isNotEmpty) {
        apkUrl = url;
        break;
      }
    }
    if (apkUrl == null) {
      return const UpdateUnreadable('这个版本没有可下载的安装包');
    }

    final code = versionCodeOf(tag);
    if (code == null) {
      // 版本号里必须带 build number：没有它就没法可靠地判断新旧。
      return const UpdateUnreadable('这个版本的编号看不懂，去 Release 页面看看');
    }

    final releaseUrl = json['html_url'];
    final body = json['body'];

    return UpdateFound(
      UpdateInfo(
        versionCode: code,
        versionName: versionNameOf(tag),
        apkUrl: apkUrl,
        releaseUrl: releaseUrl is String ? releaseUrl : '',
        notes: body is String ? body.trim() : '',
      ),
    );
  }

  /// 从 tag 里取 build number（`v1.1.0+2` / `1.1.0-2` / `v1.0.0 (13)` 都认）。
  ///
  /// 取的是**最后一个数字**：build number 总是写在最后。后面只允许跟非数字
  /// （例如 `)`），不允许跟别的数字，否则 `latest2` 这种也会被认成版本号。
  ///
  /// 认不出来返回 null —— 宁可说「看不懂」，也不猜一个数字出来：
  /// 猜错的后果是给用户推一个比当前更旧的版本。
  static int? versionCodeOf(String tag) {
    final match = RegExp(r'(\d+)\D*$').firstMatch(tag.trim());
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  /// 从 tag 里取给人看的版本号（`v1.1.0+2` → `1.1.0`）。
  static String versionNameOf(String tag) {
    final trimmed = tag.trim();
    final withoutV = trimmed.startsWith('v') || trimmed.startsWith('V')
        ? trimmed.substring(1)
        : trimmed;
    final cut = withoutV.indexOf(RegExp(r'[+\-(\s]'));
    final name = cut < 0 ? withoutV : withoutV.substring(0, cut);
    return name.isEmpty ? withoutV : name;
  }

  /// 这个版本比当前的新吗。
  static bool isNewer({required int currentCode, required int candidateCode}) =>
      candidateCode > currentCode;

  /// 该不该提示用户。
  ///
  /// 用户点过「忽略这个版本」之后，同一个版本不再打扰他；但只要出现
  /// **更高**的版本就必须再说一次 —— 忽略的语义是「这一版我先不装」，
  /// 不是「以后别告诉我」。
  static bool shouldPrompt({
    required int currentCode,
    required int candidateCode,
    int? skippedCode,
  }) {
    if (!isNewer(currentCode: currentCode, candidateCode: candidateCode)) {
      return false;
    }
    if (skippedCode == null) return true;
    return candidateCode > skippedCode;
  }

  /// 忽略记录还要不要留着。
  ///
  /// 装上更新之后，那条「忽略」记录就没有意义了 —— 顺手清掉，
  /// 免得它一直躺在偏好里，下次还要靠「候选更高」这条规则兜着。
  static bool shouldKeepSkipped({
    required int currentCode,
    required int? skippedCode,
  }) {
    if (skippedCode == null) return false;
    return skippedCode >= currentCode;
  }
}
