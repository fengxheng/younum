import 'package:flutter/material.dart';

import '../designsystem/younum_colors.dart';
import '../designsystem/younum_dimens.dart';
import '../designsystem/younum_icons.dart';
import '../designsystem/younum_text.dart';
import 'buttons.dart';
import 'primitives.dart';

/// 底部弹层容器：顶部抓手 + 圆角 24dp。
class YounumSheetSurface extends StatelessWidget {
  const YounumSheetSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    // 大屏上弹层也要居中限宽（指南 6.3）：不限制的话，确认弹层会长得
    // 跟平板一样宽，两行字之间拉出一大片空白，反而更难读。
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: YounumDimens.readingMaxWidth,
        ),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: colors.washColor,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(YounumDimens.radiusSheet),
            ),
          ),
          padding: YounumDimens.sheetPadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: Container(
                  width: 34,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 22),
                  decoration: BoxDecoration(
                    color: colors.borderColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// 二次确认内容。
///
/// 破坏性操作的文案必须随对象变化，并说明真实影响（指南 5 / 8.3），
/// 不能所有删除共用一句「确定要删除吗」。
class ConfirmSheet extends StatelessWidget {
  const ConfirmSheet({
    super.key,
    required this.title,
    required this.description,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.onConfirm,
    required this.onCancel,
    this.confirmEnabled = true,
  });

  final String title;
  final String description;
  final String confirmLabel;
  final String cancelLabel;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  final bool confirmEnabled;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    return YounumSheetSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Center(
            child: YounumCircleSymbol(
              icon: YounumIcons.alert,
              tone: YounumCircleTone.error,
              diameter: YounumDimens.circleSymbolSmall,
            ),
          ),
          const SizedBox(height: YounumDimens.gapLg),
          Text(title, textAlign: TextAlign.center, style: text.sheetTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText(description, textAlign: TextAlign.center),
          const SizedBox(height: YounumDimens.gapXl),
          PrimaryAction(
            label: confirmLabel,
            style: YounumActionStyle.danger,
            onPressed: confirmEnabled ? onConfirm : null,
          ),
          const SizedBox(height: YounumDimens.gap),
          PrimaryAction(
            label: cancelLabel,
            style: YounumActionStyle.secondary,
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

/// 弹出二次确认。
///
/// 返回 true 表示用户确认；取消或手势关闭返回 false，**不产生任何副作用**。
Future<bool> showConfirmSheet({
  required BuildContext context,
  required String title,
  required String description,
  required String confirmLabel,
  required String cancelLabel,
  bool isDismissible = true,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    showDragHandle: false,
    isDismissible: isDismissible,
    builder: (sheetContext) => ConfirmSheet(
      title: title,
      description: description,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      onConfirm: () => Navigator.of(sheetContext).pop(true),
      onCancel: () => Navigator.of(sheetContext).pop(false),
    ),
  );
  return result ?? false;
}

/// 只有一件事要告诉用户的提示层。
///
/// 与 [ConfirmSheet] 的区别：这里**没有选择**，所以只有一个按钮 —— 给用户
/// 两个都一样的选项等于骗他。用在「分享进来的一份文件没能导入」这种场合：
/// 必须说清原因，但用户在这一步也无处可去。
///
/// 为什么不用 toast：「这看起来不是账单」这种话要带上看懂了才做得对的下一步，
/// 两秒钟的浮条放不下，也很容易被划过去 —— 那用户就只会觉得「分享过来没反应」。
class NoticeSheet extends StatelessWidget {
  const NoticeSheet({
    super.key,
    required this.title,
    required this.description,
    this.confirmLabel = '知道了',
    this.tone = YounumCircleTone.error,
  });

  final String title;
  final String description;
  final String confirmLabel;
  final YounumCircleTone tone;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    return SingleChildScrollView(
      // ⚠️ 滚动要包在**整块弹层外面**：YounumSheetSurface 里那一层 Column
      // 给子节点的最大高度没有扣掉顶部抓手（22+4），子节点一旦吃满，
      // 表面自己就溢出。包在里面时实测溢出 0.273px —— 就是那几像素。
      child: YounumSheetSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Center(
              child: YounumCircleSymbol(
                icon: YounumIcons.alert,
                tone: tone,
                diameter: YounumDimens.circleSymbolSmall,
              ),
            ),
            const SizedBox(height: YounumDimens.gapLg),
            Text(title, textAlign: TextAlign.center, style: text.sheetTitle),
            const SizedBox(height: YounumDimens.gapSm),
            YounumMutedText(description, textAlign: TextAlign.center),
            const SizedBox(height: YounumDimens.gapXl),
            PrimaryAction(
              label: confirmLabel,
              style: YounumActionStyle.secondary,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

/// 弹出 [NoticeSheet]，等用户看完点掉。
Future<void> showNoticeSheet({
  required BuildContext context,
  required String title,
  required String description,
  String confirmLabel = '知道了',
  YounumCircleTone tone = YounumCircleTone.error,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    showDragHandle: false,
    builder: (_) => NoticeSheet(
      title: title,
      description: description,
      confirmLabel: confirmLabel,
      tone: tone,
    ),
  );
}

/// 轻量提示条。
///
/// 用于「已放入稍后处理」「先选择用途，再向右滑确认」这类即时反馈，
/// 不占用页面空间。文案不使用评价用户消费好坏的措辞（指南 6.1）。
void showYounumToast(BuildContext context, String message) {
  final colors = YounumColors.of(context);
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: colors.primaryColor,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        margin: const EdgeInsets.all(YounumDimens.pageHorizontal),
      ),
    );
}
