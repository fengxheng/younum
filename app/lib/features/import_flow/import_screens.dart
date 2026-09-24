import 'package:flutter/material.dart';

import '../../app/app_routes.dart';
import '../../core/components/buttons.dart';
import '../../core/components/category_grid.dart';
import '../../core/components/fields.dart';
import '../../core/components/list_row.dart';
import '../../core/components/primitives.dart';
import '../../core/components/screen_scaffold.dart';
import '../../core/designsystem/younum_colors.dart';
import '../../core/designsystem/younum_dimens.dart';
import '../../core/designsystem/younum_icons.dart';
import '../../core/designsystem/younum_text.dart';

// -----------------------------------------------------------------------------
// import —— 选择账单来源
// -----------------------------------------------------------------------------

/// 账单来源选择。
///
/// 三个入口分别对应平台适配器与通用映射流程；「暂不支持」的范围必须写明，
/// 不能让用户以为截图/PDF 也能导入（指南 4.1）。
class ImportSourceScreen extends StatelessWidget {
  const ImportSourceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);

    return YounumScreen(
      title: '导入账单',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('让这个月的花费，\n在这里相遇。', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gap),
          YounumMutedText('选择账单来源，导入后我们会帮你整理。'),
          const SizedBox(height: YounumDimens.gapXl),
          YounumPanel(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: <Widget>[
                YounumListRow(
                  title: '微信支付',
                  subtitle: '导入微信导出的账单文件',
                  icon: YounumIcons.wallet,
                  trailingWidget: const _RowChevron(),
                  onTap: () => context.open(AppRoutes.upload),
                ),
                YounumListRow(
                  title: '支付宝',
                  subtitle: '导入支付宝导出的账单文件',
                  icon: YounumIcons.wallet,
                  iconTone: YounumTileTone.blue,
                  trailingWidget: const _RowChevron(),
                  onTap: () => context.open(AppRoutes.upload),
                ),
                YounumListRow(
                  title: '通用表格',
                  subtitle: 'CSV / XLSX，手动匹配列名',
                  icon: YounumIcons.settings,
                  iconTone: YounumTileTone.purple,
                  trailingWidget: const _RowChevron(),
                  showDivider: false,
                  onTap: () => context.open(AppRoutes.mapping),
                ),
              ],
            ),
          ),
          const SizedBox(height: YounumDimens.gap),
          PrimaryAction(
            label: '不知道如何导出账单？查看指引',
            style: YounumActionStyle.secondary,
            onPressed: () => context.open(AppRoutes.exportGuide),
          ),
          YounumPanel(
            tone: YounumPanelTone.soft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    ExcludeSemantics(
                      child: Icon(
                        YounumIcons.shield,
                        size: YounumDimens.iconMd,
                        color: YounumColors.of(context).primaryColor,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('每次导入，都由你确认', style: text.sectionTitle),
                    ),
                  ],
                ),
                const SizedBox(height: YounumDimens.gapSm),
                YounumMutedText('导入前预览笔数与月份。跨来源重复记录会单独列出，确认后再计入。'),
              ],
            ),
          ),
          const YounumPillNote('暂不支持截图和 PDF 账单'),
        ],
      ),
    );
  }
}

class _RowChevron extends StatelessWidget {
  const _RowChevron();

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Icon(
          YounumIcons.chevronRight,
          size: YounumDimens.iconMd,
          color: YounumColors.of(context).mutedColor,
        ),
      );
}

// -----------------------------------------------------------------------------
// guide —— 账单导出指引
// -----------------------------------------------------------------------------

/// 导出指引。
///
/// 明确写出「具体入口随平台版本变化」，并提示不要提供支付密码
/// （指南 4.1：不能提示用户输入支付密码）。
class ExportGuideScreen extends StatefulWidget {
  const ExportGuideScreen({super.key});

  @override
  State<ExportGuideScreen> createState() => _ExportGuideScreenState();
}

class _ExportGuideScreenState extends State<ExportGuideScreen> {
  static const List<String> _platforms = <String>['微信支付', '支付宝'];
  int _platform = 0;

  static const List<List<String>> _steps = <List<String>>[
    <String>['进入账单页面', '打开支付平台，找到交易账单。'],
    <String>['选择导出账单', '选择用于个人对账的明细文件。'],
    <String>['选择完整月份', '建议选择 9月1日—9月30日。'],
    <String>['下载并解压文件', '如有压缩包或密码，请先在本机解压。'],
  ];

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final platform = _platforms[_platform];

    return YounumScreen(
      title: '如何导出账单',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          YounumToggleGroup(
            options: _platforms,
            selectedIndex: _platform,
            onSelected: (index) => setState(() => _platform = index),
          ),
          const SizedBox(height: YounumDimens.gapLg),
          Text('准备好你的$platform账单', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText('在支付平台获取账单文件，再回来导入。'),
          const SizedBox(height: YounumDimens.gapXl),
          for (var index = 0; index < _steps.length; index++)
            _GuideStep(index: index, title: _steps[index][0], description: _steps[index][1]),
          const YounumNotice(
            '具体入口随平台版本变化，以平台当前界面为准。请勿向任何人提供支付密码。',
          ),
          PrimaryAction(
            label: '已经准备好了，去导入',
            onPressed: () => context.open(AppRoutes.upload),
          ),
        ],
      ),
    );
  }
}

class _GuideStep extends StatelessWidget {
  const _GuideStep({
    required this.index,
    required this.title,
    required this.description,
  });

  final int index;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final text = YounumText.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ExcludeSemantics(
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(color: colors.softColor, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Text('0${index + 1}', style: text.micro.copyWith(color: colors.primaryColor)),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: text.listPrimary),
                const SizedBox(height: 4),
                Text(description, style: text.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// upload —— 选择文件与目标月份
// -----------------------------------------------------------------------------

/// 文件与月份选择。
///
/// ⚠️ 这一步**尚未**接入系统文件选择器（阶段 3 才做）。因此按钮文案如实说明
/// 「只演示后续流程」，不伪装成已经读到了真实文件（指南 1.3 / 12）。
class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  static const List<String> _months = <String>[
    '2026年9月',
    '2026年8月',
    '2026年7月',
  ];

  int _month = 0;
  bool _filePicked = false;
  bool _consent = true;

  bool get _canContinue => _filePicked && _consent;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final colors = YounumColors.of(context);

    return YounumScreen(
      title: '选择账单文件',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('导入你的月账单', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText('一次支持一个文件，可多次追加导入。'),
          const SizedBox(height: YounumDimens.gapLg),
          const YounumFieldLabel('账单月份'),
          YounumSelectField<int>(
            options: List<int>.generate(_months.length, (index) => index),
            labelBuilder: (index) => _months[index],
            selected: _month,
            semanticLabel: '账单月份',
            onSelected: (index) => setState(() => _month = index),
          ),
          const SizedBox(height: YounumDimens.gapLg),
          Container(
            decoration: BoxDecoration(
              color: colors.softColor,
              borderRadius: BorderRadius.circular(YounumDimens.radiusPanel),
            ),
            child: YounumDashedBox(
              color: colors.borderColor,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 30),
              child: Column(
                children: <Widget>[
                  ExcludeSemantics(
                    child: Icon(
                      YounumIcons.upload,
                      size: 34,
                      color: colors.primaryColor,
                    ),
                  ),
                  const SizedBox(height: YounumDimens.gap),
                  Text('把账单带到这里', style: text.sectionTitle),
                  const SizedBox(height: 4),
                  YounumMutedText('CSV / XLSX · 最大 20 MB'),
                  const SizedBox(height: YounumDimens.gap),
                  PrimaryAction(
                    label: '选择账单文件',
                    style: YounumActionStyle.secondary,
                    onPressed: () => setState(() => _filePicked = true),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: YounumDimens.gap),
          if (_filePicked)
            YounumPanel(
              child: Row(
                children: <Widget>[
                  ExcludeSemantics(
                    child: Icon(YounumIcons.cards, size: YounumDimens.iconLg, color: colors.inkColor),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text('微信支付账单_202609.csv'),
                        const SizedBox(height: 4),
                        YounumCaptionText('示例文件 · 32 KB'),
                      ],
                    ),
                  ),
                  ExcludeSemantics(
                    child: Icon(
                      YounumIcons.check,
                      size: YounumDimens.iconLg,
                      color: colors.primaryColor,
                    ),
                  ),
                ],
              ),
            ),
          YounumCheckRow(
            label: '我已了解账单将用于本月整理和消费统计',
            value: _consent,
            onChanged: (value) => setState(() => _consent = value),
          ),
          PrimaryAction(
            label: '识别账单',
            trailingArrow: true,
            onPressed: _canContinue ? () => context.open(AppRoutes.parsing) : null,
          ),
          const YounumPillNote(
            '当前阶段尚未接入系统文件选择器与真实解析：\n'
            '点「选择账单文件」只标记示例文件，点「识别账单」只演示后续流程。',
          ),
        ],
      ),
    );
  }
}
