import 'package:flutter/services.dart';

import '../../domain/repositories/database_secret.dart';

/// 数据库口令的原生实现（Kotlin 侧见 `DatabaseKeyStore`）。
///
/// 口令由 Android Keystore 供给：随机生成一次，用一枚**永远导不出**的
/// AES 密钥包住之后落盘，之后每次启动取回来用。这条通道只回口令本身，
/// 不做别的 —— 它不出现在日志里。
class SystemDatabaseSecret implements DatabaseSecret {
  SystemDatabaseSecret({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// 与 `MainActivity.SECURITY_CHANNEL` 必须一致。
  static const String channelName = 'com.younum.app/security';

  final MethodChannel _channel;

  @override
  Future<String?> databasePassphrase() async {
    try {
      return await _channel.invokeMethod<String>('databasePassphrase');
    } on MissingPluginException {
      // 桌面或测试环境：没有这条通道，按「不加密」处理。
      return null;
    } on PlatformException catch (error) {
      // 取不出来是**要紧的事**：把原因翻译成能给用户看的话往上抛，
      // 让调用方去决定降级方式（而不是在这里静默返回 null 假装没这回事）。
      throw DatabaseSecretUnavailable(
        error.message ?? '取不到数据库口令',
      );
    }
  }
}
