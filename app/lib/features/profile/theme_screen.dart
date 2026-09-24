import 'package:flutter/material.dart';

import '../../app/app_routes.dart';
import '../../core/components/amount_text.dart';
import '../../core/components/buttons.dart';
import '../../core/components/fields.dart';
import '../../core/components/primitives.dart';
import '../../core/components/progress.dart';
import '../../core/components/screen_scaffold.dart';
import '../../core/designsystem/color_math.dart';
import '../../core/designsystem/theme_presets.dart';
import '../../core/designsystem/younum_colors.dart';
import '../../core/designsystem/younum_dimens.dart';
import '../../core/designsystem/younum_icons.dart';
import '../../core/designsystem/younum_text.dart';
import '../../core/preferences/theme_controller.dart';
import '../../data/sample/sample_data.dart';

/// 主题与配色。
///
/// 行为要求（指南 7.2）：
/// * 预设点选**立即全局生效并保存**，不是单页局部变量；
/// * 取色器拖动即时预览，手势结束才提交，避免每帧写盘；
/// * 写入失败要明确显示「已预览但保存失败」，并允许重试；
/// * 非法 HEX 保持上一次有效主题，不崩溃也不跳回默认；
/// * 恢复默认只影响主题，不动账单、分类、提醒。
class ThemeScreen extends StatefulWidget {
  const ThemeScreen({super.key});

  @override
  State<ThemeScreen> createState() => _ThemeScreenState();
}

class _ThemeScreenState extends State<ThemeScreen> {
  late final TextEditingController _hexController;
  final FocusNode _hexFocus = FocusNode();

  String? _hexError;
  String _status = '选择喜欢的配色，自动保存到此设备';

  @override
  void initState() {
    super.initState();
    _hexController = TextEditingController(text: ThemeScope.read(context).hex);
  }

  @override
  void dispose() {
    _hexController.dispose();
    _hexFocus.dispose();
    super.dispose();
  }

  ThemeController get _controller => ThemeScope.of(context);

  /// 把外部变化同步回输入框，但**不覆盖**用户正在输入的内容。
  ///
  /// 必须在帧结束后再改 `TextEditingController.text`：build 阶段修改控制器会
  /// 触发 TextField 的 setState，导致「setState called during build」。
  void _scheduleHexFieldSync(ThemeController controller) {
    if (_hexFocus.hasFocus) return;
    final hex = controller.hex;
    if (_hexController.text.toUpperCase() == hex) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _hexFocus.hasFocus) return;
      if (_hexController.text.toUpperCase() == hex) return;
      _hexController.text = hex;
    });
  }

  Future<void> _applyPreset(ThemePreset preset) async {
    final outcome = await _controller.apply(preset.color);
    if (!mounted) return;
    setState(() {
      _hexError = null;
      _status = outcome == ThemeSaveOutcome.saved
          ? '已应用「${preset.name}」，并保存到此设备'
          : '已应用「${preset.name}」，但本次无法保存到设备';
    });
  }

  Future<void> _applyHex() async {
    final parsed = ColorMath.tryParseHex(_hexController.text);
    if (parsed == null) {
      // 非法值就地报错，保持上一次有效主题。
      setState(() => _hexError = '请输入完整的 #RRGGBB，例如 #315F4F');
      return;
    }
    _hexFocus.unfocus();
    final outcome = await _controller.apply(parsed);
    if (!mounted) return;
    setState(() {
      _hexError = null;
      _hexController.text = ColorMath.toHex(parsed);
      _status = outcome == ThemeSaveOutcome.saved
          ? '配色已应用并保存'
          : '已预览但保存失败，请重试';
    });
  }

  Future<void> _restoreDefault() async {
    final outcome = await _controller.restoreDefault();
    if (!mounted) return;
    setState(() {
      _hexError = null;
      _hexController.text = ThemePresets.defaultPreset.hex;
      _status = outcome == ThemeSaveOutcome.saved
          ? '已恢复默认森林绿'
          : '已恢复默认，但本次无法保存到设备';
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final text = YounumText.of(context);
    final colors = YounumColors.of(context);
    _scheduleHexFieldSync(controller);

    return YounumScreen(
      title: '主题与配色',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('选一种，喜欢的颜色。', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText('让每一次打开，都更像你。'),

          // 预览卡
          YounumPanel(
            tone: YounumPanelTone.soft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(child: YounumMutedText('我的 9 月消费手记')),
                    YounumBadge(controller.displayName),
                  ],
                ),
                const SizedBox(height: YounumDimens.gapSm),
                AmountText(
                  cents: SampleData.month.totalCents,
                  scale: AmountScale.panel,
                ),
                YounumProgressTrack(
                  value: SampleData.month.progress,
                  semanticLabel: '预览用进度',
                ),
                const SizedBox(height: YounumDimens.gapSm),
                PrimaryAction(
                  label: '看看卡片效果',
                  trailingArrow: true,
                  onPressed: () => context.selectTab(1),
                ),
              ],
            ),
          ),

          YounumSectionHeader(
            title: '精选主题',
            trailing: YounumCaptionText('即时生效'),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              const spacing = 10.0;
              final width = (constraints.maxWidth - spacing) / 2;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: ThemePresets.all
                    .map(
                      (preset) => SizedBox(
                        width: width,
                        child: ThemeSwatch(
                          preset: preset,
                          chosen: controller.rawColor == preset.color,
                          onTap: () => _applyPreset(preset),
                        ),
                      ),
                    )
                    .toList(growable: false),
              );
            },
          ),

          YounumSectionHeader(
            title: '自定义主色',
            trailing: YounumCaptionText(controller.hex),
          ),
          YounumColorPicker(
            color: controller.rawColor,
            // 拖动只改内存，不写盘。
            onPreview: controller.preview,
            // 手势结束才提交。
            onCommit: (value) async {
              final outcome = await _controller.apply(value);
              if (!mounted) return;
              setState(() {
                _hexController.text = ColorMath.toHex(value);
                _status = outcome == ThemeSaveOutcome.saved
                    ? '配色已应用并保存'
                    : '已预览但保存失败，请重试';
              });
            },
          ),
          const SizedBox(height: YounumDimens.gap),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: YounumTextField(
                  controller: _hexController,
                  hintText: '#RRGGBB',
                  maxLength: 7,
                  errorText: _hexError,
                  suffixText: null,
                  onSubmitted: (_) => _applyHex(),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 90,
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: PrimaryAction(
                    label: '应用',
                    style: YounumActionStyle.secondary,
                    onPressed: _applyHex,
                  ),
                ),
              ),
            ],
          ),
          YounumCaptionText(
            controller.primaryAdjusted
                ? '已自动加深按钮与文字，确保浅色主题也清晰可读。'
                : '主色会同步应用于按钮、卡片、导航与回顾封面。',
          ),
          const SizedBox(height: YounumDimens.gapSm),
          if (controller.hasUnsavedPreview)
            Row(
              children: <Widget>[
                Expanded(
                  child: YounumCaptionText(
                    '已预览但保存失败：当前颜色可以用，但重启后会回到上一次保存的配色。',
                    style: TextStyle(color: colors.primaryColor),
                  ),
                ),
                YounumPressable(
                  onTap: () async {
                    final outcome = await _controller.retrySave();
                    if (!mounted) return;
                    setState(() {
                      _status = outcome == ThemeSaveOutcome.saved
                          ? '配色已保存'
                          : '仍然无法保存，请检查设备存储空间';
                    });
                  },
                  semanticLabel: '重试保存配色',
                  borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: Text(
                      '重试',
                      style: text.label.copyWith(color: colors.primaryColor),
                    ),
                  ),
                ),
              ],
            ),
          const SizedBox(height: YounumDimens.gapSm),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: text.caption.copyWith(color: colors.primaryColor),
            ),
          ),
          PrimaryAction(
            label: '恢复默认 · 森林绿',
            style: YounumActionStyle.plain,
            onPressed: controller.isDefault ? null : _restoreDefault,
          ),
          const YounumPillNote(
            '恢复默认只影响主题配色，不会清除账单、分类和提醒设置。',
          ),
        ],
      ),
    );
  }
}

/// 预设色卡。
class ThemeSwatch extends StatelessWidget {
  const ThemeSwatch({
    super.key,
    required this.preset,
    required this.chosen,
    required this.onTap,
  });

  final ThemePreset preset;
  final bool chosen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final text = YounumText.of(context);
    return Semantics(
      selected: chosen,
      button: true,
      label: '${preset.name}，${preset.mood}',
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(YounumDimens.radiusControl),
          child: Container(
            constraints: const BoxConstraints(minHeight: 68),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: chosen ? colors.washColor : const Color(YounumColors.surface),
              border: Border.all(
                color: chosen ? colors.primaryColor : colors.softColor,
                width: chosen ? 1.4 : 1,
              ),
              borderRadius: BorderRadius.circular(YounumDimens.radiusControl),
            ),
            child: Row(
              children: <Widget>[
                YounumColorSwatch(color: preset.color),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              preset.name,
                              overflow: TextOverflow.ellipsis,
                              style: text.listPrimary.copyWith(fontSize: 13),
                            ),
                          ),
                          if (chosen) ...<Widget>[
                            const SizedBox(width: 4),
                            ExcludeSemantics(
                              child: Icon(
                                YounumIcons.check,
                                size: 14,
                                color: colors.primaryColor,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        preset.mood,
                        overflow: TextOverflow.ellipsis,
                        style: text.micro,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// App 内的取色控件。
///
/// Android 没必要照搬 HTML 的原生颜色选择器（指南 7.2），
/// 因此这里用三个系统滑块分别控制色相 / 饱和度 / 明度，
/// 并使用系统手势与无障碍语义。
class YounumColorPicker extends StatelessWidget {
  const YounumColorPicker({
    super.key,
    required this.color,
    required this.onPreview,
    required this.onCommit,
  });

  /// 当前生效的原始色值。
  final int color;

  /// 拖动过程中调用，只改内存。
  final ValueChanged<int> onPreview;

  /// 手势结束时调用一次。
  final ValueChanged<int> onCommit;

  @override
  Widget build(BuildContext context) {
    final hsv = _RgbHsv.fromInt(color);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _PickerSlider(
          label: '色相',
          value: hsv.hue,
          max: 360,
          trackGradient: LinearGradient(
            colors: <Color>[
              for (var i = 0; i <= 6; i++)
                ColorMath.toColor(_hsvToRgb(i * 60.0, 1, 1)),
            ],
          ),
          onChanged: (value) =>
              onPreview(_hsvToRgb(value, hsv.saturation, hsv.value)),
          onChangeEnd: (value) =>
              onCommit(_hsvToRgb(value, hsv.saturation, hsv.value)),
        ),
        _PickerSlider(
          label: '饱和度',
          value: hsv.saturation * 100,
          max: 100,
          trackGradient: LinearGradient(
            colors: <Color>[
              ColorMath.toColor(_hsvToRgb(hsv.hue, 0, hsv.value)),
              ColorMath.toColor(_hsvToRgb(hsv.hue, 1, hsv.value)),
            ],
          ),
          onChanged: (value) =>
              onPreview(_hsvToRgb(hsv.hue, value / 100, hsv.value)),
          onChangeEnd: (value) =>
              onCommit(_hsvToRgb(hsv.hue, value / 100, hsv.value)),
        ),
        _PickerSlider(
          label: '明度',
          value: hsv.value * 100,
          max: 100,
          trackGradient: LinearGradient(
            colors: <Color>[
              ColorMath.toColor(_hsvToRgb(hsv.hue, hsv.saturation, 0.08)),
              ColorMath.toColor(_hsvToRgb(hsv.hue, hsv.saturation, 1)),
            ],
          ),
          onChanged: (value) =>
              onPreview(_hsvToRgb(hsv.hue, hsv.saturation, value / 100)),
          onChangeEnd: (value) =>
              onCommit(_hsvToRgb(hsv.hue, hsv.saturation, value / 100)),
        ),
      ],
    );
  }
}

class _PickerSlider extends StatelessWidget {
  const _PickerSlider({
    required this.label,
    required this.value,
    required this.max,
    required this.trackGradient,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String label;
  final double value;
  final double max;
  final Gradient trackGradient;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    return Row(
      children: <Widget>[
        SizedBox(width: 48, child: Text(label, style: text.caption)),
        Expanded(
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              Container(
                height: 10,
                margin: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  gradient: trackGradient,
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 10,
                  activeTrackColor: Colors.transparent,
                  inactiveTrackColor: Colors.transparent,
                  overlayShape: SliderComponentShape.noOverlay,
                ),
                child: Slider(
                  value: value.clamp(0, max),
                  max: max,
                  label: '$label ${value.round()}',
                  onChanged: onChanged,
                  onChangeEnd: onChangeEnd,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// HSV → `0xRRGGBB`。
///
/// 自己实现而不依赖 `HSVColor`，避免不同 Flutter 版本的颜色 API 差异。
int _hsvToRgb(double hue, double saturation, double value) {
  final h = (hue % 360) / 60;
  final s = saturation.clamp(0.0, 1.0);
  final v = value.clamp(0.0, 1.0);
  final sector = h.floor();
  final fraction = h - sector;
  final p = v * (1 - s);
  final q = v * (1 - s * fraction);
  final t = v * (1 - s * (1 - fraction));

  final (double r, double g, double b) = switch (sector) {
    0 => (v, t, p),
    1 => (q, v, p),
    2 => (p, v, t),
    3 => (p, q, v),
    4 => (t, p, v),
    _ => (v, p, q),
  };

  int channel(double component) => (component * 255).round().clamp(0, 255);
  return (channel(r) << 16) | (channel(g) << 8) | channel(b);
}

/// RGB → HSV 的可变包装。
class _RgbHsv {
  const _RgbHsv(this.hue, this.saturation, this.value);

  factory _RgbHsv.fromInt(int rgb) {
    final r = ((rgb >> 16) & 0xFF) / 255;
    final g = ((rgb >> 8) & 0xFF) / 255;
    final b = (rgb & 0xFF) / 255;
    final maxChannel = [r, g, b].reduce((a, b) => a > b ? a : b);
    final minChannel = [r, g, b].reduce((a, b) => a < b ? a : b);
    final delta = maxChannel - minChannel;

    double hue;
    if (delta == 0) {
      hue = 0;
    } else if (maxChannel == r) {
      hue = 60 * (((g - b) / delta) % 6);
    } else if (maxChannel == g) {
      hue = 60 * ((b - r) / delta + 2);
    } else {
      hue = 60 * ((r - g) / delta + 4);
    }
    if (hue < 0) hue += 360;

    return _RgbHsv(
      hue,
      maxChannel == 0 ? 0 : delta / maxChannel,
      maxChannel,
    );
  }

  final double hue;
  final double saturation;
  final double value;
}
