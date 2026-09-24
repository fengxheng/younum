import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../designsystem/younum_colors.dart';
import '../designsystem/younum_dimens.dart';
import '../designsystem/younum_icons.dart';
import '../designsystem/younum_text.dart';
import 'buttons.dart';

/// 表单分组标题。
class YounumFieldLabel extends StatelessWidget {
  const YounumFieldLabel(this.label, {super.key, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 6),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: YounumText.of(context).label)),
          ?trailing,
        ],
      ),
    );
  }
}

/// 文本输入。
class YounumTextField extends StatelessWidget {
  const YounumTextField({
    super.key,
    required this.controller,
    this.hintText,
    this.maxLength,
    this.keyboardType,
    this.inputFormatters,
    this.readOnly = false,
    this.errorText,
    this.onSubmitted,
    this.onChanged,
    this.suffixText,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String? hintText;
  final int? maxLength;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final bool readOnly;
  final String? errorText;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final String? suffixText;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    return TextField(
      controller: controller,
      readOnly: readOnly,
      autofocus: autofocus,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      style: YounumText.of(context).input,
      cursorColor: colors.primaryColor,
      decoration: InputDecoration(
        hintText: hintText,
        errorText: errorText,
        suffixText: suffixText,
      ),
    );
  }
}

/// 下拉选择。
///
/// 不用 Material 的 [DropdownButton]：它在浅色设计里会带出阴影与弹出菜单样式，
/// 与设计稿的底部弹层选择方式不一致。这里统一走底部弹层。
class YounumSelectField<T> extends StatelessWidget {
  const YounumSelectField({
    super.key,
    required this.options,
    required this.labelBuilder,
    required this.selected,
    required this.onSelected,
    this.placeholder = '请选择',
    this.semanticLabel,
  });

  final List<T> options;
  final String Function(T option) labelBuilder;
  final T? selected;
  final ValueChanged<T> onSelected;
  final String placeholder;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final text = YounumText.of(context);
    final hasValue = selected != null;

    return YounumPressable(
      onTap: () async {
        final picked = await showYounumOptionsSheet<T>(
          context: context,
          title: semanticLabel ?? placeholder,
          options: options,
          labelBuilder: labelBuilder,
          selected: selected,
        );
        if (picked != null) onSelected(picked);
      },
      semanticLabel: '${semanticLabel ?? placeholder}，当前 ${hasValue ? labelBuilder(selected as T) : placeholder}',
      borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
      child: Container(
        constraints: const BoxConstraints(minHeight: YounumDimens.fieldHeight),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: const Color(YounumColors.surface),
          border: Border.all(color: const Color(YounumColors.inputBorder)),
          borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                hasValue ? labelBuilder(selected as T) : placeholder,
                overflow: TextOverflow.ellipsis,
                style: hasValue
                    ? text.input
                    : text.input.copyWith(color: colors.mutedColor),
              ),
            ),
            ExcludeSemantics(
              child: Icon(
                YounumIcons.expandMore,
                size: YounumDimens.iconMd,
                color: colors.mutedColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 底部选项弹层。返回 null 表示用户取消（取消不产生副作用）。
Future<T?> showYounumOptionsSheet<T>({
  required BuildContext context,
  required String title,
  required List<T> options,
  required String Function(T option) labelBuilder,
  T? selected,
}) {
  final colors = YounumColors.of(context);
  final text = YounumText.of(context);
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: colors.washColor,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                YounumDimens.pageHorizontal,
                0,
                YounumDimens.pageHorizontal,
                8,
              ),
              child: Text(title, style: text.sheetTitle),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final option = options[index];
                  final isSelected = selected == option;
                  return YounumPressable(
                    onTap: () => Navigator.of(sheetContext).pop(option),
                    semanticLabel: labelBuilder(option),
                    borderRadius: BorderRadius.zero,
                    child: Container(
                      constraints: const BoxConstraints(minHeight: YounumDimens.minTouchTarget),
                      padding: const EdgeInsets.symmetric(
                        horizontal: YounumDimens.pageHorizontal,
                        vertical: 12,
                      ),
                      color: isSelected ? colors.softColor : null,
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              labelBuilder(option),
                              style: text.body.copyWith(
                                color: isSelected ? colors.primaryColor : colors.inkColor,
                                fontWeight:
                                    isSelected ? FontWeight.w600 : FontWeight.w400,
                              ),
                            ),
                          ),
                          if (isSelected)
                            ExcludeSemantics(
                              child: Icon(
                                YounumIcons.check,
                                size: YounumDimens.iconMd,
                                color: colors.primaryColor,
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    ),
  );
}

/// 开关行。
class YounumSwitchRow extends StatelessWidget {
  const YounumSwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.description,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    return Semantics(
      toggled: value,
      label: label,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(label, style: text.body),
                  if (description != null) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(description!, style: text.caption),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Switch(
              value: value,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}

/// 复选行。
class YounumCheckRow extends StatelessWidget {
  const YounumCheckRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    return YounumPressable(
      onTap: enabled && onChanged != null ? () => onChanged!(!value) : null,
      semanticLabel: label,
      borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
      child: Container(
        constraints: const BoxConstraints(minHeight: YounumDimens.minTouchTarget),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: <Widget>[
            ExcludeSemantics(
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: value ? colors.primaryColor : Colors.transparent,
                  border: Border.all(
                    color: value ? colors.primaryColor : const Color(YounumColors.inputBorder),
                    width: 1.4,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: value
                    ? Icon(Icons.check, size: 15, color: colors.onPrimaryColor)
                    : null,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: YounumText.of(context).caption.copyWith(
                      color: enabled
                          ? YounumText.of(context).caption.color
                          : colors.mutedColor.withValues(alpha: 0.6),
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单选列表（交易性质调整）。
class YounumRadioGroup<T> extends StatelessWidget {
  const YounumRadioGroup({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    required this.labelBuilder,
    this.groupLabel = '请选择一项',
  });

  final List<T> options;
  final T? selected;
  final ValueChanged<T> onSelected;
  final String Function(T option) labelBuilder;
  final String groupLabel;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final text = YounumText.of(context);
    return Semantics(
      label: groupLabel,
      child: Column(
        children: options
            .map(
              (option) => YounumPressable(
                onTap: () => onSelected(option),
                semanticLabel: labelBuilder(option),
                borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: <Widget>[
                      ExcludeSemantics(
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selected == option
                                  ? colors.primaryColor
                                  : const Color(YounumColors.inputBorder),
                              width: selected == option ? 5.5 : 1.4,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          labelBuilder(option),
                          style: text.body.copyWith(
                            fontWeight: selected == option
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
            .toList(growable: false),
      ),
    );
  }
}
