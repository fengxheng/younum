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
    return Container(
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
