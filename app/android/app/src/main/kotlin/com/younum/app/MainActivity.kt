package com.younum.app

import io.flutter.embedding.android.FlutterActivity

/**
 * 单 Activity 入口。
 *
 * 目前不需要自定义平台通道；分类图片裁剪、文件选择等能力由 Flutter 插件承担。
 * 若后续必须写 Kotlin（例如平台特有的 XLSX 解析或精确闹钟），在此注册 MethodChannel。
 */
class MainActivity : FlutterActivity()

