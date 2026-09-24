import 'package:flutter/material.dart';

import '../../app/app_routes.dart';
import '../../core/components/amount_text.dart';
import '../../core/components/buttons.dart';
import '../../core/components/fields.dart';
import '../../core/components/list_row.dart';
import '../../core/components/primitives.dart';
import '../../core/components/progress.dart';
import '../../core/components/screen_scaffold.dart';
import '../../core/components/sheets.dart';
import '../../core/designsystem/younum_colors.dart';
import '../../core/designsystem/younum_dimens.dart';
import '../../core/designsystem/younum_icons.dart';
import '../../core/designsystem/younum_text.dart';
import '../../core/preferences/app_state_store.dart';
import '../../data/sample/sample_data.dart';

// -----------------------------------------------------------------------------
// parsing —— 文件识别中
// -----------------------------------------------------------------------------

/// 读取 / 校验状态。
///
/// 设计稿要求「真实进度、取消、失败恢复」。当前阶段只呈现设计状态，
/// 因此页面上的进度是**不定进度**并明确标注尚未接入真实解析，
/// 不用假百分比冒充（指南 4.2.9）。
class ParsingScreen extends StatelessWidget {
  const ParsingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);

    return YounumScreen(
      title: '正在识别',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SizedBox(height: YounumDimens.gapLg),
          Center(
            child: YounumCircleSymbol(
              icon: YounumIcons.cards,
              tone: YounumCircleTone.primary,
              diameter: 85,
            ),
          ),
          const SizedBox(height: YounumDimens.gapLg),
          Text('正在整理你的账单', textAlign: TextAlign.center, style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText('从一行行数字里，找到生活的线索。', textAlign: TextAlign.center),
          const SizedBox(height: YounumDimens.gapXl),
          YounumPanel(
            child: Column(
              children: <Widget>[
                const YounumLineInfo(label: '读取文件', value: '已完成 ✓'),
                const YounumLineInfo(label: '检查日期与金额', value: '已完成 ✓'),
                const YounumLineInfo(label: '核对重复记录', value: '进行中 ···'),
                YounumProgressTrack(
                  value: null,
                  semanticLabel: '核对重复记录',
                ),
              ],
            ),
          ),
          const YounumPillNote('真实解析将在阶段 3 接入：进度来自真实的阶段与行数，\n未知总量时保持不定进度，不会伪造百分比。'),
          PrimaryAction(
            label: '查看识别结果',
            onPressed: () => context.open(AppRoutes.checkImport),
          ),
          const SizedBox(height: YounumDimens.gap),
          PrimaryAction(
            label: '取消导入',
            style: YounumActionStyle.plain,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// mapping —— 通用表格字段匹配
// -----------------------------------------------------------------------------

/// 手动字段映射。
///
/// 表头未知时进入这里，而不是按固定列下标猜测（指南 4.2.7）。
/// 必填项缺失或重复映射时不能继续。
class MappingScreen extends StatefulWidget {
  const MappingScreen({super.key});

  @override
  State<MappingScreen> createState() => _MappingScreenState();
}

class _MappingScreenState extends State<MappingScreen> {
  static const List<String> _columns = <String>[
    '交易日期',
    '金额（元）',
    '交易对方',
    '收/支',
    '不导入此列',
  ];

  /// 四行的当前选择。必填项用 `required` 标记。
  final List<int> _selected = <int>[0, 1, 2, 3];
  bool _negativeIsExpense = true;

  List<String> get _fields => const <String>[
        '交易时间 *',
        '交易金额 *',
        '商户 / 交易说明',
        '收支方向 *',
      ];

  /// 必填项是否都已映射到实际列（而不是「不导入此列」）。
  bool get _requiredMapped {
    const requiredIndexes = <int>[0, 1, 3];
    final used = <String>{};
    for (final index in requiredIndexes) {
      final column = _columns[_selected[index]];
      if (column == '不导入此列') return false;
      if (!used.add(column)) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);

    return YounumScreen(
      title: '匹配表格字段',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('告诉我们每一列是什么', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText('已找到表头，请确认对应关系。'),
          const SizedBox(height: YounumDimens.gapLg),
          for (var index = 0; index < _fields.length; index++) ...<Widget>[
            YounumFieldLabel(_fields[index]),
            YounumSelectField<int>(
              options: List<int>.generate(_columns.length, (i) => i),
              labelBuilder: (i) => _columns[i],
              selected: _selected[index],
              semanticLabel: _fields[index],
              onSelected: (value) => setState(() => _selected[index] = value),
            ),
            const SizedBox(height: YounumDimens.gap),
          ],
          const YounumNotice(
            '金额应为人民币元。若金额含正负号，请确认「负数为支出」；'
            '外币记录需单独确认汇率。',
          ),
          YounumCheckRow(
            label: '负数为支出，正数为收入',
            value: _negativeIsExpense,
            onChanged: (value) => setState(() => _negativeIsExpense = value),
          ),
          PrimaryAction(
            label: '确认字段，预览账单',
            onPressed: _requiredMapped
                ? () => context.open(AppRoutes.checkImport)
                : null,
          ),
          if (!_requiredMapped)
            const YounumPillNote('必填项必须映射到实际列，且不能重复映射同一列。'),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// checkimport —— 导入预览与核对
// -----------------------------------------------------------------------------

/// 导入结果核对。
///
/// 必须正确区分消费、非消费、重复、异常及跨月行（指南第 5 节）。
class CheckImportScreen extends StatelessWidget {
  const CheckImportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);

    return YounumScreen(
      title: '确认导入',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('找到了你的 9 月', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText('先核对一下，再开始整理。'),
          const SizedBox(height: YounumDimens.gapLg),
          YounumPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                YounumCaptionText('本次新增支出 · ${SampleData.importNewExpenseCount} 笔'),
                const SizedBox(height: YounumDimens.gap),
                const AmountText(cents: 843260, scale: AmountScale.panel),
                const YounumDivider(),
                const YounumLineInfo(
                  label: '账单范围',
                  value: SampleData.importRangeText,
                ),
                YounumLineInfo(
                  label: '识别记录',
                  value: '${SampleData.importedRecordCount} 笔',
                ),
              ],
            ),
          ),
          YounumListRow(
            title: '疑似重复',
            subtitle:
                '${SampleData.duplicateGroupCount} 笔暂不计入，请核对',
            iconKey: 'file',
            trailingText: '查看 ›',
            onTap: () => context.open(AppRoutes.duplicates),
          ),
          YounumListRow(
            title: '非消费记录',
            subtitle:
                '${SampleData.incomeRecordCount} 笔收入 · ${SampleData.transferRecordCount} 笔转账',
            icon: YounumIcons.split,
            iconTone: YounumTileTone.blue,
            trailingText: '已单独记录',
            onTap: () => context.open(AppRoutes.transactionNature),
          ),
          const YounumNotice(
            '仅将确认后的消费计入月度概况。退款将关联原消费，'
            '收入和账户间转账不计入消费。',
          ),
          PrimaryAction(
            label: '确认导入 ${SampleData.importNewExpenseCount} 笔',
            onPressed: () async {
              // 走查说明：阶段 3 会在这里执行真实事务（先落暂存区、再事务写入正式交易）。
              // 当前先把账本切到示例账本，让整理与月报两个一级入口有内容可看。
              await AppStateScope.read(context).enterDemoLedger();
              if (!context.mounted) return;
              TabScope.read(context).select(1);
              context.openAsRoot(AppRoutes.root);
            },
          ),
          const YounumDemoNote(
            '设计走查：本页数字来自设计稿样例。阶段 3 接入后，'
            '「确认导入」会先写暂存区，再用事务写入正式交易，成功后才会跳转。',
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// duplicates —— 疑似重复记录
// -----------------------------------------------------------------------------

/// 重复组逐组处理。
///
/// 疑似重复必须逐组明确处理，不能只处理第一组却提示全部完成（指南 4.3）。
class DuplicatesScreen extends StatefulWidget {
  const DuplicatesScreen({super.key});

  @override
  State<DuplicatesScreen> createState() => _DuplicatesScreenState();
}

class _DuplicatesScreenState extends State<DuplicatesScreen> {
  /// 两条候选记录的说明与时间。
  static const List<(String, String)> _duplicateCandidates = <(String, String)>[
    ('保留 · 微信支付', '2026.09.23 14:26:03 · 已导入'),
    ('改为保留 · 银行卡流水', '2026.09.23 14:26:05 · 本次导入'),
  ];

  /// 当前组保留其中哪一条。
  int _keep = 0;
  int _group = 1;

  bool get _isLastGroup => _group >= SampleData.duplicateGroupCount;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);

    return YounumScreen(
      title: '核对重复记录',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('这两笔，可能是同一笔', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText('相同商户、金额及相近时间，不会直接重复计入。'),
          const SizedBox(height: YounumDimens.gap),
          Align(
            alignment: Alignment.centerLeft,
            child: YounumBadge(
              '第 $_group 组 / 共 ${SampleData.duplicateGroupCount} 组',
              tone: YounumBadgeTone.warm,
            ),
          ),
          const SizedBox(height: YounumDimens.gap),
          for (var index = 0; index < _duplicateCandidates.length; index++)
            _DuplicateCard(
              label: _duplicateCandidates[index].$1,
              timestamp: _duplicateCandidates[index].$2,
              selected: _keep == index,
              onTap: () => setState(() => _keep = index),
            ),
          PrimaryAction(
            label: _isLastGroup ? '完成重复核对' : '确认并查看下一组',
            onPressed: () {
              if (_isLastGroup) {
                showYounumToast(context, '全部 ${SampleData.duplicateGroupCount} 组已处理');
                Navigator.of(context).maybePop();
                return;
              }
              setState(() => _group += 1);
            },
          ),
          const SizedBox(height: YounumDimens.gap),
          PrimaryAction(
            label: '确实是两笔，都保留',
            style: YounumActionStyle.secondary,
            onPressed: () => setState(() {
              _keep = 0;
              if (!_isLastGroup) _group += 1;
            }),
          ),
          const YounumPillNote('完整重复的记录可自动排除，疑似重复由你确认'),
        ],
      ),
    );
  }
}

class _DuplicateCard extends StatelessWidget {
  const _DuplicateCard({
    required this.label,
    required this.timestamp,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String timestamp;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    return YounumPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Semantics(
            selected: selected,
            button: true,
            label: label,
            excludeSemantics: true,
            child: YounumPressable(
              onTap: onTap,
              borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
              child: Row(
                children: <Widget>[
                  ExcludeSemantics(
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected
                              ? YounumColors.of(context).primaryColor
                              : const Color(YounumColors.inputBorder),
                          width: selected ? 5.5 : 1.4,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(label, style: text.body)),
                ],
              ),
            ),
          ),
          const SizedBox(height: YounumDimens.gapSm),
          Text('MANNER COFFEE', style: text.sectionTitle),
          const SizedBox(height: 4),
          const AmountText(cents: 2800, scale: AmountScale.inline),
          const SizedBox(height: 4),
          YounumCaptionText(timestamp),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// importerror —— 文件 / 行级错误
// -----------------------------------------------------------------------------

/// 导入异常。
///
/// 必须提供可执行的恢复路径，并区分「文件级失败」与「部分行异常」
/// （指南第 5 节 importerror）。
class ImportErrorScreen extends StatelessWidget {
  const ImportErrorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);

    return YounumScreen(
      title: '导入遇到问题',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Center(
            child: YounumCircleSymbol(
              icon: YounumIcons.alert,
              tone: YounumCircleTone.error,
              diameter: 85,
            ),
          ),
          const SizedBox(height: YounumDimens.gapLg),
          Text(
            '有 ${SampleData.invalidRowCount} 条记录需要检查',
            textAlign: TextAlign.center,
            style: text.screenTitle,
          ),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText(
            '其他 125 条记录已识别成功。\n这些记录暂未加入账单。',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: YounumDimens.gapLg),
          const YounumPanel(
            child: Column(
              children: <Widget>[
                YounumLineInfo(label: '第 18 行', value: '日期无法识别'),
                YounumLineInfo(label: '第 43 行', value: '缺少交易金额'),
                YounumLineInfo(label: '第 96 行', value: '币种不是人民币'),
              ],
            ),
          ),
          const YounumNotice(
            '修正文件后可以重新导入，已导入记录将再次进行去重检查。'
            '异常明细可以导出，确认后才能只导入有效行。',
          ),
          PrimaryAction(
            label: '先核对可导入的记录',
            onPressed: () => context.open(AppRoutes.checkImport),
          ),
          const SizedBox(height: YounumDimens.gap),
          PrimaryAction(
            label: '重新选择文件',
            style: YounumActionStyle.secondary,
            onPressed: () => context.open(AppRoutes.upload),
          ),
          const SizedBox(height: YounumDimens.gap),
          PrimaryAction(
            label: '导出异常明细',
            style: YounumActionStyle.plain,
            onPressed: () => showYounumToast(
              context,
              '导出异常明细将在阶段 3 接入文件导出后可用',
            ),
          ),
        ],
      ),
    );
  }
}
