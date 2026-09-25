/// 数据库口令的来源（加密用）。
///
/// 与选文件、保存、提醒同一套做法：**能做这件事的东西**从外面注入，
/// 存储层只拿一个字符串，不关心它从哪来、由谁保管。于是：
///
/// * 真机上由 Android Keystore 供给（`SystemDatabaseSecret`）；
/// * 桌面、Web、测试环境没有这个能力，返回 null ——
///   存储层拿到 null 就按「不加密」打开，行为与加密之前完全一样。
///
/// ⚠️ 拿到的是**口令本身**：不要写日志、不要持久化、不要发到别处。
library;

/// 去哪里拿数据库口令。
abstract interface class DatabaseSecret {
  /// 取口令。
  ///
  /// 返回 null 表示「这个环境不做加密」（而不是「加密失败」）。
  /// 取不出来（密钥没了、文件坏了）应当**抛异常**，由调用方决定怎么降级 ——
  /// 绝不能悄悄换一把新口令，那会让用户在毫无察觉的情况下看到空账本。
  Future<String?> databasePassphrase();
}

/// 桌面、Web、测试环境：不加密。
class UnsupportedDatabaseSecret implements DatabaseSecret {
  const UnsupportedDatabaseSecret();

  @override
  Future<String?> databasePassphrase() async => null;
}

/// 口令取不出来。
///
/// 与「这个环境不加密」是两件完全不同的事：前者是**这台设备上的数据已经
/// 读不出来**，必须明确告诉用户；后者只是桌面环境没这个能力。
class DatabaseSecretUnavailable implements Exception {
  const DatabaseSecretUnavailable(this.message);

  /// 可以直接给用户看的话。
  final String message;

  @override
  String toString() => 'DatabaseSecretUnavailable($message)';
}
