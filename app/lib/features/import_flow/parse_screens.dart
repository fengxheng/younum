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
import '../../core/time/statistics_time.dart';
import '../../domain/models/import_records.dart';
import '../../domain/models/year_month.dart';
import '../../domain/repositories/import_workflow.dart';
import '../../domain/rules/import_rules.dart';
import 'import_session.dart';

// -----------------------------------------------------------------------------
// parsing —— 文件识别中
// -----------------------------------------------------------------------------

/// 读取 / 校验状态。
///
/// 进度是**不定进度**，因为总量在解析完成前根本不知道 ——
/// 指南 4.2.9 明确要求不能用假百分比冒充。
///
/// 这一页自己不做事：读文件与解析由 `ImportSession.pickAndStage` 在后台跑，
/// 这里只是把它画出来，并在有结论之后**自动**往下走：
///
/// * 解析好 → 替换成核对页（不回头的前进，所以用 `replaceWith`）；
/// * 需要人工匹配列名 → 替换成字段映射页；
/// * 用户取消或失败 → `pop()` 回到选文件那一页。
///   失败不在这里展示，因为原因属于「选文件」这一步，页面栈上也该是同一页。
class ParsingScreen extends StatefulWidget {
  const ParsingScreen({super.key});

  @override
  State<ParsingScreen> createState() => _ParsingScreenState();
}

class _ParsingScreenState extends State<ParsingScreen> {
  ImportSession? _session;

  /// 已经往下走过一次就不再走：会话可能连续通知多次。
  bool _forwarded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = ImportSessionScope.of(context);
    if (identical(_session, session)) return;
    _session?.removeListener(_onSessionChanged);
    _session = session..addListener(_onSessionChanged);
    // 进来时可能已经有结论了（解析很快），所以立刻判一次。
    WidgetsBinding.instance.addPostFrameCallback((_) => _forward(session));
  }

  @override
  void dispose() {
    _session?.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() {
    final session = _session;
    if (session == null || _forwarded) return;
    // 还在选文件或还在解析就继续等。
    if (session.isBusy) {
      setState(() {});
      return;
    }
    _forward(session);
  }

  void _forward(ImportSession session) {
    if (!mounted || _forwarded) return;
    switch (session.phase) {
      case ImportPhase.ready:
      case ImportPhase.committed:
        _forwarded = true;
        context.replaceWith(AppRoutes.checkImport);
      case ImportPhase.needsMapping:
        _forwarded = true;
        context.replaceWith(AppRoutes.mapping);
      case ImportPhase.idle:
      case ImportPhase.picking:
      case ImportPhase.reading:
      case ImportPhase.committing:
        // 还在进行中，继续等下一次通知。
        setState(() {});
      case ImportPhase.failed:
      case ImportPhase.reverted:
        // 失败或取消都回到选文件那一页，由它把原因说清楚。
        _forwarded = true;
        Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final session = ImportSessionScope.of(context);
    final picking = session.phase == ImportPhase.picking;

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
          Text(
            '正在整理你的账单',
            textAlign: TextAlign.center,
            style: text.screenTitle,
          ),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText('从一行行数字里，找到生活的线索。', textAlign: TextAlign.center),
          const SizedBox(height: YounumDimens.gapXl),
          YounumPanel(
            child: Column(
              children: <Widget>[
                YounumLineInfo(
                  label: '选择文件',
                  value: picking ? '进行中 ···' : '已完成 ✓',
                ),
                YounumLineInfo(
                  label: '判断编码并读取',
                  value: picking ? '待开始' : '已完成 ✓',
                ),
                YounumLineInfo(
                  label: '解析日期与金额',
                  value: picking ? '待开始' : '进行中 ···',
                ),
                YounumProgressTrack(value: null, semanticLabel: '正在解析账单'),
              ],
            ),
          ),
          if (session.fileName != null)
            YounumCaptionText(
              '正在处理 ${session.fileName}',
              textAlign: TextAlign.center,
            ),
          const YounumPillNote('文件只在你的手机上解析，不会上传。'),
          // 取消的语义是「不读这份文件了」：读完之后就不能在这里取消了，
          // 那时候该走的是核对页上的「不导入」（丢弃批次）。
          if (session.isBusy)
            PrimaryAction(
              label: '取消',
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
  /// 「不导入此列」在下拉里用 -1 表示。
  static const int _none = -1;

  /// 字段 → 列下标（-1 表示不导入）。
  final Map<ImportField, int> _columns = <ImportField, int>{};

  /// 这份文件的第一行是不是表头。
  bool _hasHeader = true;

  /// 只在第一次进来时预填，之后不能覆盖用户改过的选择。
  bool _prefilled = false;

  /// 展示顺序：必填三项在最前，其余是可选信息。
  static const List<ImportField> _order = <ImportField>[
    ImportField.occurredAt,
    ImportField.amount,
    ImportField.merchant,
    ImportField.direction,
    ImportField.status,
    ImportField.orderId,
    ImportField.note,
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_prefilled) return;
    final info = ImportSessionScope.of(context).mapping;
    if (info == null) return;
    _prefilled = true;
    _hasHeader = true;
    _columns.addAll(info.guessedColumns);
  }

  ImportMappingRequired get _info => ImportSessionScope.of(context).mapping!;

  /// 当前认定的表头行号。识别不出来时默认第 0 行是表头，用户可以关掉。
  int get _headerRowIndex {
    if (!_hasHeader) return -1;
    final guessed = _info.guessedHeaderRowIndex;
    return guessed >= 0 ? guessed : 0;
  }

  List<String> get _headerRow {
    final index = _headerRowIndex;
    if (index < 0 || index >= _info.previewRows.length) return const <String>[];
    return _info.previewRows[index];
  }

  /// 数据行的起始位置。
  int get _firstDataRow => _headerRowIndex < 0 ? 0 : _headerRowIndex + 1;

  /// 某一列的一个真实取值，放在下拉里让用户一眼认出这是什么列。
  ///
  /// 只写「第 3 列」是不够的：用户要对着**文件里的内容**才能确认。
  String _sampleFor(int index) {
    for (var row = _firstDataRow; row < _info.previewRows.length; row++) {
      final cells = _info.previewRows[row];
      if (index >= cells.length) continue;
      final value = cells[index].trim();
      if (value.isEmpty) continue;
      return value.length <= 12 ? value : '${value.substring(0, 11)}…';
    }
    return '';
  }

  String _labelFor(int column) {
    if (column == _none) return '不导入此列';
    final parts = <String>['第 ${column + 1} 列'];
    if (column < _headerRow.length) {
      final header = _headerRow[column].trim();
      if (header.isNotEmpty) parts.add(header);
    }
    final sample = _sampleFor(column);
    if (sample.isNotEmpty) parts.add('例：$sample');
    return parts.join(' · ');
  }

  ImportFieldMapping get _mapping => ImportFieldMapping(
    headerRowIndex: _headerRowIndex,
    columns: <ImportField, int>{
      for (final entry in _columns.entries)
        if (entry.value != _none) entry.key: entry.value,
    },
  );

  /// 本地先判一次，好让按钮在明显不合法时就灰掉；
  /// 真正的判定仍在 `ImportRules.checkMapping`（与解析共用一份规则）。
  MappingCheck get _check =>
      ImportRules.checkMapping(_mapping, columnCount: _info.columnCount);

  Future<void> _confirm() async {
    final session = ImportSessionScope.read(context);
    await session.applyMapping(_mapping);
    if (!mounted) return;
    if (session.phase == ImportPhase.ready) {
      context.replaceWith(AppRoutes.checkImport);
    }
    // 还不行就留在本页：下面会把原因列出来。
  }

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final session = ImportSessionScope.of(context);
    final issues = session.mapping?.issues ?? const <String>[];

    return YounumScreen(
      title: '匹配表格字段',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('告诉我们每一列是什么', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText(
            '这份文件的表头认不出来，所以不能靠列的位置去猜 ——'
            '猜错的结果看起来会像「导入成功了」。',
          ),
          const SizedBox(height: YounumDimens.gapLg),

          const YounumFieldLabel('文件里的前几行'),
          _PreviewTable(
            rows: _info.previewRows,
            columnCount: _info.columnCount,
            headerRowIndex: _headerRowIndex,
          ),
          const SizedBox(height: YounumDimens.gapLg),

          YounumCheckRow(
            label: '第一行是表头（列名），不是数据',
            value: _hasHeader,
            onChanged: (value) => setState(() => _hasHeader = value),
          ),

          for (final field in _order) ...<Widget>[
            YounumFieldLabel(
              ImportField.required.contains(field)
                  ? '${field.label} *'
                  : '${field.label}（可留空）',
            ),
            YounumSelectField<int>(
              options: <int>[
                _none,
                ...List<int>.generate(_info.columnCount, (i) => i),
              ],
              labelBuilder: _labelFor,
              selected: _columns[field] ?? _none,
              semanticLabel: field.label,
              onSelected: (value) => setState(() => _columns[field] = value),
            ),
            const SizedBox(height: YounumDimens.gap),
          ],

          const YounumNotice(
            '金额请选人民币元的列。若这一列带正负号，负号表示支出、正号无法判断时，'
            '会在核对页上标出来让你确认，不会自己猜。',
          ),

          if (issues.isNotEmpty) YounumNotice(issues.join('\n')),

          PrimaryAction(
            label: '确认字段，预览账单',
            onPressed: _check.canContinue ? _confirm : null,
          ),
          if (!_check.canContinue && issues.isEmpty)
            YounumPillNote(_check.messages.join('；')),
        ],
      ),
    );
  }
}

/// 文件前几行的预览表。
///
/// 指南 4.2.7 要求「映射结果展示至少 3 行预览」：用户得看到**真实内容**
/// 才能确认哪一列是什么。
class _PreviewTable extends StatelessWidget {
  const _PreviewTable({
    required this.rows,
    required this.columnCount,
    required this.headerRowIndex,
  });

  final List<List<String>> rows;
  final int columnCount;
  final int headerRowIndex;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final text = YounumText.of(context);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (var index = 0; index < rows.length; index++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: <Widget>[
                  SizedBox(width: 34, child: YounumCaptionText('${index + 1}')),
                  for (var column = 0; column < columnCount; column++)
                    Container(
                      width: 96,
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: index == headerRowIndex
                            ? colors.softColor
                            : null,
                        borderRadius: BorderRadius.circular(
                          YounumDimens.radiusControlSmall,
                        ),
                      ),
                      child: Text(
                        column < rows[index].length ? rows[index][column] : '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.caption.copyWith(
                          fontWeight: index == headerRowIndex
                              ? FontWeight.w600
                              : null,
                        ),
                      ),
                    ),
                ],
              ),
            ),
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
/// 这一页上的每个数字都来自**暂存区**（`ImportSession`），与提交后会写进
/// 正式账的内容完全同源。所以「确认导入 N 笔」之后，首页上的金额就应该
/// 和这里显示的一致 —— 不一致就是有人在两种口径之间分叉了。
class CheckImportScreen extends StatelessWidget {
  const CheckImportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = ImportSessionScope.of(context);
    final text = YounumText.of(context);
    final preview = session.preview;

    if (session.phase == ImportPhase.committed ||
        session.phase == ImportPhase.reverted) {
      return _ImportedPanel(session: session);
    }

    if (preview == null) {
      // 没有暂存内容就说明是误入（例如从历史里点了返回）。
      return YounumScreen(
        title: '确认导入',
        child: YounumEmptyState(
          title: '还没有正在导入的账单',
          description: '先去选一份账单文件，这里会列出识别结果。',
          action: PrimaryAction(
            label: '去选择账单文件',
            trailingArrow: true,
            onPressed: () => context.replaceWith(AppRoutes.upload),
          ),
        ),
      );
    }

    final expenseRows = session.rowsToCommit
        .where((row) => row.direction == ImportDirection.expense)
        .toList();
    final incomeCount = session.rowsToCommit
        .where((row) => row.direction == ImportDirection.income)
        .length;
    final transferCount = session.rowsToCommit
        .where((row) => row.direction == ImportDirection.transfer)
        .length;
    final undecided = session.rowsToCommit
        .where((row) => row.direction == ImportDirection.unknown)
        .length;
    final expenseCents = expenseRows.fold(
      0,
      (sum, row) => sum + (row.amountCents ?? 0),
    );
    final month = _monthOf(preview.rangeStartMs);

    return YounumScreen(
      title: '确认导入',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            month == null ? '找到了这些记录' : '找到了你的 $month',
            style: text.screenTitle,
          ),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText('先核对一下，再开始整理。'),
          const SizedBox(height: YounumDimens.gapLg),

          YounumPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                YounumCaptionText('本次新增支出 · ${expenseRows.length} 笔'),
                const SizedBox(height: YounumDimens.gap),
                AmountText(cents: expenseCents, scale: AmountScale.panel),
                const YounumDivider(),
                YounumLineInfo(
                  label: '账单范围',
                  value: _rangeText(preview.rangeStartMs, preview.rangeEndMs),
                ),
                YounumLineInfo(
                  label: '识别记录',
                  value:
                      '${preview.totalRows} 行 · '
                      '可导入 ${session.commitCount} 笔',
                ),
                if (preview.encoding.isNotEmpty)
                  YounumLineInfo(label: '文件编码', value: preview.encoding),
              ],
            ),
          ),

          if (preview.suspectedCount > 0 || preview.duplicateCount > 0)
            YounumListRow(
              title: '疑似重复',
              subtitle: preview.suspectedCount > 0
                  ? '${preview.suspectedCount} 笔需要你确认是否同一笔'
                  : '${preview.duplicateCount} 笔已经导入过，默认不重复计入',
              iconKey: 'file',
              trailingText: session.hasUndecidedDuplicates
                  ? '待处理 ›'
                  : '已处理 ${session.decidedGroupCount}/${session.duplicateGroups.length} ›',
              onTap: () => context.open(AppRoutes.duplicates),
            ),

          if (incomeCount > 0 || transferCount > 0 || undecided > 0)
            YounumListRow(
              title: '非消费记录',
              subtitle: <String>[
                if (incomeCount > 0) '$incomeCount 笔收入',
                if (transferCount > 0) '$transferCount 笔转账',
                if (undecided > 0) '$undecided 笔方向待判断',
              ].join(' · '),
              icon: YounumIcons.split,
              iconTone: YounumTileTone.blue,
              trailingText: '不计入消费',
            ),

          if (preview.invalidCount > 0)
            YounumListRow(
              title: '需要检查的记录',
              subtitle: '${preview.invalidCount} 行没读进来，会单独列出来',
              icon: YounumIcons.alert,
              iconTone: YounumTileTone.purple,
              trailingText: '查看 ›',
              onTap: () => context.open(AppRoutes.importError),
            ),

          const YounumNotice(
            '仅将确认后的消费计入月度概况。退款将关联原消费，'
            '收入和账户间转账不计入消费。',
          ),

          if (session.phase == ImportPhase.committing) ...<Widget>[
            YounumMutedText('正在保存，请不要关闭应用…', textAlign: TextAlign.center),
            const SizedBox(height: YounumDimens.gapSm),
            const YounumProgressTrack(value: null, semanticLabel: '正在保存'),
          ] else ...<Widget>[
            PrimaryAction(
              label: '确认导入 ${session.commitCount} 笔',
              onPressed: session.canCommit ? session.commit : null,
            ),
            if (session.hasUndecidedDuplicates)
              const YounumPillNote('还有重复记录没确认，确认完才能导入。'),
            const SizedBox(height: YounumDimens.gapSm),
            PrimaryAction(
              label: '先不导入',
              style: YounumActionStyle.plain,
              onPressed: () async {
                await session.discard(preview.batchId);
                if (!context.mounted) return;
                context.replaceWith(AppRoutes.upload);
              },
            ),
          ],
        ],
      ),
    );
  }

  static String? _monthOf(int? epochMs) {
    if (epochMs == null) return null;
    final local = StatisticsTime.toLocal(epochMs);
    return YearMonth(local.year, local.month).label;
  }

  static String _rangeText(int? start, int? end) {
    if (start == null || end == null) return '文件里没有可用的日期';
    final first = StatisticsTime.toLocal(start);
    final last = StatisticsTime.toLocal(end);
    if (first.year == last.year &&
        first.month == last.month &&
        first.day == last.day) {
      return '${first.month}月${first.day}日';
    }
    return '${first.month}月${first.day}日 – ${last.month}月${last.day}日';
  }
}

/// 提交成功之后的样子。
///
/// 刻意**留在这一页**而不是直接跳首页：用户需要一个「刚刚发生了什么」的落点，
/// 也需要一个去导入记录的入口（撤回就在那里）。
class _ImportedPanel extends StatelessWidget {
  const _ImportedPanel({required this.session});

  final ImportSession session;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final committed = session.committed;
    final reverted = session.phase == ImportPhase.reverted;

    return YounumScreen(
      title: '确认导入',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SizedBox(height: YounumDimens.gapLg),
          Center(
            child: YounumCircleSymbol(
              icon: reverted ? YounumIcons.undo : YounumIcons.check,
              tone: reverted
                  ? YounumCircleTone.error
                  : YounumCircleTone.primary,
              diameter: 85,
            ),
          ),
          const SizedBox(height: YounumDimens.gapLg),
          Text(
            reverted ? '已经收回这次导入' : '账单已经进来了',
            textAlign: TextAlign.center,
            style: text.screenTitle,
          ),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText(
            reverted ? '这次导入的交易已经从账本里去掉。' : '接下来把它们一个一个归好类，就完成了。',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: YounumDimens.gapXl),
          if (committed != null && !reverted)
            YounumPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  YounumCaptionText('本次导入 · ${committed.count} 笔'),
                  const SizedBox(height: YounumDimens.gap),
                  AmountText(
                    cents: committed.amountCents,
                    scale: AmountScale.panel,
                  ),
                ],
              ),
            ),
          if (!reverted)
            PrimaryAction(
              label: '开始整理',
              trailingArrow: true,
              onPressed: () {
                TabScope.read(context).select(1);
                context.openAsRoot(AppRoutes.root);
              },
            ),
          const SizedBox(height: YounumDimens.gapSm),
          PrimaryAction(
            label: '查看导入记录',
            style: YounumActionStyle.secondary,
            onPressed: () => context.open(AppRoutes.importHistory),
          ),
          const SizedBox(height: YounumDimens.gapSm),
          PrimaryAction(
            label: '再导入一份账单',
            style: YounumActionStyle.plain,
            onPressed: () {
              session.reset();
              context.replaceWith(AppRoutes.upload);
            },
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
  /// 当前正在处理第几组。
  ///
  /// 只在这里保存位置，取舍本身存在 [ImportSession] 里 —— 这样从这一页
  /// 返回核对页再进来，已经做过的决定还在，不会让用户白做一遍。
  int _index = 0;

  /// 只在第一次进来时跳到没处理的那一组。
  bool _positioned = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_positioned) return;
    _positioned = true;
    final session = ImportSessionScope.of(context);
    final groups = session.duplicateGroups;
    final first = groups.indexWhere((group) => !session.isGroupDecided(group));
    _index = first >= 0 ? first : 0;
  }

  Future<void> _decide(ImportDuplicateGroup group, {required bool keep}) async {
    final session = ImportSessionScope.read(context);
    await session.decideDuplicateGroup(group, keep: keep);
    if (!mounted) return;

    final groups = session.duplicateGroups;
    if (!session.hasUndecidedDuplicates) {
      // ⚠️ 只有**全部**组都处理完才说完成。指南 4.3 明确禁止
      // 「只处理第一组却提示全部完成」。
      showYounumToast(context, '全部 ${groups.length} 组已处理');
      Navigator.of(context).maybePop();
      return;
    }
    setState(() => _index = _nextUndecidedIndex(session, groups));
  }

  /// 找下一组还没处理的。从当前组往后绕一圈，保证一定能找到。
  int _nextUndecidedIndex(
    ImportSession session,
    List<ImportDuplicateGroup> groups,
  ) {
    for (var step = 1; step <= groups.length; step++) {
      final candidate = (_index + step) % groups.length;
      if (!session.isGroupDecided(groups[candidate])) return candidate;
    }
    return _index;
  }

  @override
  Widget build(BuildContext context) {
    final session = ImportSessionScope.of(context);
    final text = YounumText.of(context);
    final groups = session.duplicateGroups;

    if (groups.isEmpty) {
      return YounumScreen(
        title: '核对重复记录',
        child: YounumEmptyState(
          title: '没有需要核对的重复记录',
          description: '这份账单里的记录都是新的。',
          action: PrimaryAction(
            label: '返回核对',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
      );
    }

    final index = _index.clamp(0, groups.length - 1);
    final group = groups[index];
    final isLast = index == groups.length - 1;

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
              '第 ${index + 1} 组 / 共 ${groups.length} 组',
              tone: YounumBadgeTone.warm,
            ),
          ),
          const SizedBox(height: YounumDimens.gap),
          YounumPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                YounumCaptionText(group.reason),
                const SizedBox(height: YounumDimens.gapSm),
                for (final row in group.rows)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            row.merchant ?? '未知商户',
                            style: text.body,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        AmountText(
                          cents: row.amountCents ?? 0,
                          scale: AmountScale.inline,
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 4),
                YounumCaptionText(
                  '第 ${group.rows.map((row) => row.rowNumber).join('、')} 行 · '
                  '共 ${group.totalCents ~/ 100}.'
                  '${(group.totalCents % 100).toString().padLeft(2, '0')} 元',
                ),
              ],
            ),
          ),

          for (var position = 0; position < group.rows.length; position++)
            _DuplicateCard(
              row: group.rows[position],
              label: position == 0 ? '保留这一笔' : '改为保留这一笔',
              selected: false,
              onTap: () => _decide(group, keep: false),
            ),

          if (group.isSameOrigin)
            // 同源重复没有「都保留」这个选项：交易单号一致就是同一笔，
            // 真插两条会撞唯一索引。给一个做不到的按钮比不给更糟。
            PrimaryAction(
              label: isLast ? '知道了，完成核对' : '知道了，看下一组',
              onPressed: () => _decide(group, keep: false),
            )
          else
            PrimaryAction(
              label: isLast ? '确实是两笔，完成核对' : '确实是两笔，看下一组',
              onPressed: () => _decide(group, keep: true),
            ),

          const SizedBox(height: YounumDimens.gapSm),
          PrimaryAction(
            label: group.isSameOrigin ? '这份账单已经导入过，跳过这一组' : '只保留一笔，跳过重复的那笔',
            style: YounumActionStyle.secondary,
            onPressed: () => _decide(group, keep: false),
          ),
          const YounumPillNote(
            '完整重复的记录可自动排除，疑似重复由你确认。'
            '没确认完的组不会让导入完成。',
          ),
        ],
      ),
    );
  }
}

class _DuplicateCard extends StatelessWidget {
  const _DuplicateCard({
    required this.row,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final ImportRow row;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final occurredAt = row.occurredAtMs;
    final timestamp = occurredAt == null
        ? '第 ${row.rowNumber} 行'
        : '第 ${row.rowNumber} 行 · ${StatisticsTime.formatShort(occurredAt)}';

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
              borderRadius: BorderRadius.circular(
                YounumDimens.radiusControlSmall,
              ),
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
          Text(row.merchant ?? '未知商户', style: text.sectionTitle),
          const SizedBox(height: 4),
          AmountText(cents: row.amountCents ?? 0, scale: AmountScale.inline),
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
/// 这一页只讲**部分行异常**：文件级失败（读不了、编码分不清）在选文件那一页
/// 就说清了，两者给用户的下一步完全不同（指南第 5 节 importerror）。
///
/// 每一行都给出**它自己**的原因，而不是「有 3 条记录需要检查」然后不说是哪 3 条 ——
/// 用户拿着这句话没法修文件。
class ImportErrorScreen extends StatelessWidget {
  const ImportErrorScreen({super.key});

  /// 一次最多列多少行。再多就让用户回原文件里找，界面上列一千行没有意义。
  static const int _maxListed = 50;

  @override
  Widget build(BuildContext context) {
    final session = ImportSessionScope.of(context);
    final text = YounumText.of(context);
    final invalid = session.invalidRows;
    final preview = session.preview;

    if (invalid.isEmpty) {
      return YounumScreen(
        title: '导入遇到问题',
        child: YounumEmptyState(
          title: '没有需要检查的记录',
          description: '这份账单里的每一行都读进来了。',
          action: PrimaryAction(
            label: '返回核对',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
      );
    }

    final listed = invalid.take(_maxListed).toList();
    final hidden = invalid.length - listed.length;

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
            '有 ${invalid.length} 行需要检查',
            textAlign: TextAlign.center,
            style: text.screenTitle,
          ),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText(
            '这份账单里可导入 ${session.commitCount} 笔，'
            '下面这些行没有加进来。',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: YounumDimens.gapLg),
          YounumPanel(
            child: Column(
              children: <Widget>[
                for (final row in listed)
                  YounumLineInfo(
                    label: '第 ${row.rowNumber} 行',
                    value: row.issue ?? '这一行没能读出来',
                  ),
              ],
            ),
          ),
          if (hidden > 0) YounumCaptionText('还有 $hidden 行没有列出来。'),
          if (preview != null)
            YounumNotice(
              '这份文件读到 ${preview.totalRows} 行，其中 '
              '${preview.invalidCount} 行没能读进来，'
              '${preview.duplicateCount} 行与已导入的记录重复。'
              '修正文件后可以重新导入，已导入记录会再次去重。',
            ),
          PrimaryAction(
            label: '先去核对能导入的记录',
            trailingArrow: true,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(height: YounumDimens.gapSm),
          PrimaryAction(
            label: '换一份文件',
            style: YounumActionStyle.secondary,
            onPressed: () {
              session.reset();
              context.replaceWith(AppRoutes.upload);
            },
          ),
        ],
      ),
    );
  }
}
