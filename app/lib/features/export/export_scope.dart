/// 导出能力的注入点。
///
/// 海报渲染与文件保存都需要引擎 / 系统能力，没法纯函数化，所以做成端口注入：
/// 桌面与测试环境注入不支持实现，入口显灰或如实报错，而不是留一个点了没反应的
/// 按钮、也不是假装成功。
///
/// 和 `ThemeScope` / `ReviewSessionScope` 一样挂在 `MaterialApp` 之上，
/// 因此弹出的路由（分享页、隐私页）都能取到。
library;

import 'package:flutter/widgets.dart';

import '../../domain/repositories/document_saver.dart';
import '../../domain/repositories/poster_ports.dart';

/// 导出端口。
class ExportScope extends InheritedWidget {
  const ExportScope({
    super.key,
    required this.posterMaker,
    required this.documentSaver,
    required super.child,
  });

  final PosterMaker posterMaker;
  final DocumentSaver documentSaver;

  /// 取端口。没有注入时退回「不支持」实现 —— 与真实实现的行为差异只有
  /// 一句可读的中文提示，不会崩。
  static ExportScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ExportScope>() ??
      const ExportScope(
        posterMaker: UnsupportedPosterMaker(),
        documentSaver: UnsupportedDocumentSaver(),
        child: SizedBox.shrink(),
      );

  @override
  bool updateShouldNotify(ExportScope oldWidget) =>
      posterMaker != oldWidget.posterMaker ||
      documentSaver != oldWidget.documentSaver;
}
