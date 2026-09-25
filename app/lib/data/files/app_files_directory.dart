/// 应用私有目录的查询（Android）。
///
/// 分类图片必须落在**应用自己拥有**的目录里（指南 14.4.2）：选择器给的
/// `content://` 授权随时可能失效，原照片被用户删掉时图标也就跟着废了。
///
/// 为什么不用 `path_provider`：这个工程一直在避免为了一件事引入一个插件
/// （文件选择就是自写通道），而这里只是问一句 `filesDir` ——
/// 一条 `MethodChannel` 调用就够，而且顺带保证「问到的目录」与
/// 原生侧实际写文件的地方是同一个。
library;

import 'package:flutter/services.dart';

import 'system_file_source.dart';

/// 拿应用私有目录的绝对路径。
///
/// 失败时抛 `PlatformException`：调用方（启动装配）在拿不到目录时
/// 应当退到「不支持图片图标」，而不是猜一个目录写进去。
Future<String> systemFilesDirectory() async {
  const channel = MethodChannel(SystemFileSource.channelName);
  final path = await channel.invokeMethod<String>('filesDir');
  if (path == null || path.isEmpty) {
    throw PlatformException(
      code: 'no_files_dir',
      message: '系统没有给出应用私有目录',
    );
  }
  return path;
}
