import 'package:flutter/material.dart';

import '../../app/app_routes.dart';
import '../../core/components/amount_text.dart';
import '../../core/components/buttons.dart';
import '../../core/components/fields.dart';
import '../../core/components/list_row.dart';
import '../../core/components/primitives.dart';
import '../../core/components/screen_scaffold.dart';
import '../../core/components/sheets.dart';
import '../../core/designsystem/younum_colors.dart';
import '../../core/designsystem/younum_dimens.dart';
import '../../core/designsystem/younum_icons.dart';
import '../../core/designsystem/younum_text.dart';
import '../../core/preferences/app_state_store.dart';
import '../../core/preferences/reminder_controller.dart';
import '../../core/preferences/theme_controller.dart';
import '../../core/time/statistics_time.dart';
import '../../core/time/younum_clock.dart';
import '../../domain/models/import_records.dart';
import '../../domain/models/year_month.dart';
import '../../domain/repositories/document_saver.dart';
import '../../domain/rules/reminder_rules.dart';
import '../export/export_files.dart';
import '../export/export_scope.dart';
import '../import_flow/import_session.dart';
import '../organize/review_session.dart';

/// 导出**当前月份**的明细 CSV。
///
/// 走系统的「创建文档」流程；取消不提示成功，失败如实说明原因
/// （指南 8.1）。没有可导出的记录时也不假装存了一个空文件。
Future<void> _exportCurrentMonth(BuildContext context) async {
  final session = ReviewSessionScope.of(context);
  final overview = session.overview;
  final dataset = session.report?.dataset;
  if (overview == null || dataset == null) {
    showYounumToast(context, '还没有可以导出的记录');
    return;
  }

  final saver = ExportScope.of(context).documentSaver;
  if (!await saver.isAvailable()) {
    if (!context.mounted) return;
    showYounumToast(context, '这个平台上还不能保存文件');
    return;
  }

  final outcome = await saveDetailCsv(
    saver: saver,
    dataset: dataset,
    month: overview.month,
  );
  if (!context.mounted) return;

  switch (outcome) {
    case DocumentSaved(:final name):
      showYounumToast(context, '已保存：$name');
    case SaveCanceled():
      // 取消不是错误，也不是成功。
      break;
    case SaveFailed(:final message):
      showYounumToast(context, message);
  }
}

// -----------------------------------------------------------------------------
// profile —— 我的
// -----------------------------------------------------------------------------

/// 我的。
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final theme = ThemeScope.of(context);
    final session = ReviewSessionScope.of(context);

    return YounumScreen(
      bottomBar: const AppBottomBar(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text('我的有数', style: text.screenTitle)),
              const YounumBadge('本地使用'),
            ],
          ),
          const SizedBox(height: YounumDimens.gap),
          YounumPanel(
            tone: YounumPanelTone.soft,
            child: Row(
              children: <Widget>[
                ExcludeSemantics(
                  child: Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: YounumColors.of(context).tintColor,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      YounumIcons.categoryIcon('leaf'),
                      size: 24,
                      color: YounumColors.of(context).primaryColor,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('认真生活的你', style: text.listPrimary),
                      const SizedBox(height: 5),
                      YounumCaptionText(
                        '已经陪你回顾了 ${session.recordedMonths.length} 个月',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: YounumDimens.gapSm),
          YounumSettingRow(
            title: '主题与配色',
            subtitle: '${theme.displayName} · 换一种喜欢的颜色',
            icon: YounumIcons.palette,
            onTap: () => context.open(AppRoutes.theme),
          ),
          YounumSettingRow(
            title: '分类管理',
            subtitle: '分类用途与自定义图标',
            icon: YounumIcons.navCards,
            onTap: () => context.open(AppRoutes.categoryManage),
          ),
          YounumSettingRow(
            title: '导入记录',
            subtitle: '查看文件和导入结果',
            icon: YounumIcons.cards,
            onTap: () => context.open(AppRoutes.importHistory),
          ),
          YounumSettingRow(
            title: '隐私与数据',
            subtitle: '导出、备份和清除本地数据',
            icon: YounumIcons.shield,
            onTap: () => context.open(AppRoutes.privacy),
          ),
          YounumSettingRow(
            title: '整理提醒',
            subtitle: '每月温柔地提醒一次',
            icon: YounumIcons.bell,
            onTap: () => context.open(AppRoutes.reminder),
          ),
          YounumSettingRow(
            title: '整理进度与保存状态',
            subtitle: '看看进度是否已经保存',
            icon: YounumIcons.clock,
            onTap: () => context.open(AppRoutes.offlineStatus),
          ),
          YounumSettingRow(
            title: '使用帮助',
            subtitle: '账单导出与常见问题',
            icon: YounumIcons.description,
            onTap: () => context.open(AppRoutes.exportGuide),
          ),
          const SizedBox(height: YounumDimens.sectionGap),
          Center(
            child: Column(
              children: <Widget>[
                Text(
                  '∷ 有数',
                  style: text.body.copyWith(
                    fontSize: 18,
                    color: YounumColors.of(context).mutedColor,
                  ),
                ),
                const SizedBox(height: 6),
                const YounumCaptionText(
                  '把注意力还给生活。\nVersion 1.0 · 设计走查构建',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: YounumDimens.gap),
                // 调试构建下的设计走查入口。Release 不注册该路由，点击无副作用。
                if (AppRoutes.isDesignReviewEnabled)
                  YounumPressable(
                    onTap: () => context.open(AppRoutes.designReview),
                    semanticLabel: '打开设计状态走查',
                    borderRadius: BorderRadius.circular(
                      YounumDimens.radiusControlSmall,
                    ),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 44),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      alignment: Alignment.center,
                      child: Text(
                        '设计状态走查（仅调试构建）',
                        style: text.label.copyWith(
                          color: YounumColors.of(context).primaryColor,
                        ),
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
// importhistory —— 导入记录与撤回
// -----------------------------------------------------------------------------

/// 导入记录。
///
/// 每一行都是数据库里真实存在的批次。撤回前先算一遍**真实影响**
/// （独占记录、仍被别的批次引用、用户已经整理过的），
/// 只说「确定撤回吗」是在让用户闭着眼睛做决定（指南 4.4）。
class ImportHistoryScreen extends StatefulWidget {
  const ImportHistoryScreen({super.key});

  @override
  State<ImportHistoryScreen> createState() => _ImportHistoryScreenState();
}

class _ImportHistoryScreenState extends State<ImportHistoryScreen> {
  @override
  void initState() {
    super.initState();
    // 读真实批次。这一页可能是从别处（首页、我的）直接进来的，
    // 不能假设导入会话里已经有历史。
    //
    // 放在 initState 里并推迟到首帧之后：直接在 build 期间改会话状态
    // 会触发「setState() called during build」。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ImportSessionScope.read(context).loadHistory();
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ImportSessionScope.of(context);
    final text = YounumText.of(context);
    final batches = session.history;

    return YounumScreen(
      title: '导入记录',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('每份账单，都有来处', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText('重新导入同一文件时，会自动检查重复。'),
          const SizedBox(height: YounumDimens.gap),

          if (batches.isEmpty)
            YounumEmptyState(
              title: '还没有导入过账单',
              description: '导入一份账单之后，这里会记下来源、笔数与金额。',
              action: PrimaryAction(
                label: '导入账单',
                trailingArrow: true,
                onPressed: () => context.open(AppRoutes.billImport),
              ),
            )
          else
            for (final batch in batches) ...<Widget>[
              _BatchPanel(batch: batch, onRevert: () => _revert(batch)),
              const SizedBox(height: YounumDimens.gapSm),
            ],

          const SizedBox(height: YounumDimens.gap),
          PrimaryAction(
            label: '导入新账单',
            onPressed: () => context.open(AppRoutes.billImport),
          ),
        ],
      ),
    );
  }

  Future<void> _revert(ImportBatch batch) async {
    final session = ImportSessionScope.read(context);

    // 先算一遍：删几笔、留几笔、为什么留。算不出来就不让撤。
    final impact = await session.previewRevert(batch.id);
    if (!mounted || impact == null) return;

    final lines = <String>[
      if (impact.deletedCount > 0) '移除 ${impact.deletedCount} 笔这次导入的记录',
      if (impact.unlinkedRefundCount > 0)
        '${impact.unlinkedRefundCount} 笔退款会解除关联并回到待整理'
            '（退款本身不会被删掉）',
      if (impact.sharedTransactionIds.isNotEmpty)
        '保留 ${impact.sharedTransactionIds.length} 笔 —— 另一份账单也需要它们',
      if (impact.editedTransactionIds.isNotEmpty)
        '保留 ${impact.editedTransactionIds.length} 笔 —— 你已经给它们分过类',
      if (impact.deletedCount == 0 &&
          impact.sharedTransactionIds.isEmpty &&
          impact.editedTransactionIds.isEmpty)
        '这次导入的记录在账本里已经找不到了',
    ];

    final confirmed = await showConfirmSheet(
      context: context,
      title: '撤回「${batch.fileName}」？',
      description: '${lines.join('；')}。\n受影响月份的统计会重新算一遍。',
      confirmLabel: '撤回这次导入',
      cancelLabel: '保留数据',
    );
    if (!mounted || !confirmed) return;

    final result = await session.revert(batch.id);
    if (!mounted || result == null) return;
    showYounumToast(
      context,
      result.deletedCount == 0
          ? '已撤回，没有记录需要移除'
          : '已撤回，移除 ${result.deletedCount} 笔'
                '${result.keptCount > 0 ? '，保留 ${result.keptCount} 笔' : ''}'
                '${result.unlinkedRefundCount > 0 ? '，${result.unlinkedRefundCount} 笔退款回到待整理' : ''}',
    );
  }
}

/// 一个导入批次的卡片。
class _BatchPanel extends StatelessWidget {
  const _BatchPanel({required this.batch, required this.onRevert});

  final ImportBatch batch;
  final VoidCallback onRevert;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final colors = YounumColors.of(context);
    final reverted = batch.isReverted;

    return YounumPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  batch.fileName,
                  style: text.listPrimary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              YounumBadge(
                reverted ? '已撤回' : '已导入',
                tone: reverted ? YounumBadgeTone.warm : YounumBadgeTone.primary,
              ),
            ],
          ),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText(
            <String>[
              '${batch.newCount} 笔新增',
              if (batch.duplicateCount > 0) '${batch.duplicateCount} 笔重复已排除',
              if (batch.invalidCount > 0) '${batch.invalidCount} 行没读进来',
            ].join(' · '),
          ),
          const SizedBox(height: 4),
          YounumCaptionText(
            <String>[
              if (batch.committedAtMs != null)
                StatisticsTime.formatShort(batch.committedAtMs!),
              batch.encoding,
              _monthText(),
            ].join(' · '),
          ),
          const YounumDivider(),
          Row(
            children: <Widget>[
              Expanded(
                child: AmountText(
                  cents: batch.amountCents,
                  scale: AmountScale.inline,
                ),
              ),
              if (batch.canRevert)
                YounumPressable(
                  onTap: onRevert,
                  semanticLabel: '撤回${batch.fileName}',
                  borderRadius: BorderRadius.circular(
                    YounumDimens.radiusControlSmall,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                    child: Text(
                      '撤回导入',
                      style: text.label.copyWith(color: colors.primaryColor),
                    ),
                  ),
                )
              else
                YounumCaptionText(reverted ? '已撤回' : '无可撤回记录'),
            ],
          ),
        ],
      ),
    );
  }

  /// 账单覆盖的月份。
  ///
  /// 来源文件已经不可追溯时如实说「月份未知」，
  /// 不拿导入时间去假装账单月份 —— 那会让用户以为账单就是这个月的。
  String _monthText() {
    final start = batch.rangeStartMs;
    final end = batch.rangeEndMs;
    if (start == null || end == null) return '账单月份未知';
    final first = StatisticsTime.toLocal(start);
    final last = StatisticsTime.toLocal(end);
    if (first.year == last.year && first.month == last.month) {
      return YearMonth(first.year, first.month).label;
    }
    return '${YearMonth(first.year, first.month).shortLabel} – '
        '${YearMonth(last.year, last.month).shortLabel}';
  }
}

// -----------------------------------------------------------------------------
// privacy —— 隐私与数据管理
// -----------------------------------------------------------------------------

/// 隐私与数据。
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);

    return YounumScreen(
      title: '隐私与数据',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('你的生活，\n由你掌握。', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText('默认本地保存。App 没有申请互联网权限，账单不会离开这台设备。'),
          const SizedBox(height: YounumDimens.gap),
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
                    Expanded(child: Text('仅用于账单整理', style: text.sectionTitle)),
                  ],
                ),
                const SizedBox(height: YounumDimens.gapSm),
                const YounumMutedText('不索取支付密码，不访问你的支付账户。仅处理你主动选择的文件。'),
              ],
            ),
          ),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText(
            '账单包含交易时间、金额、商户与用途，保存在设备内。\n'
            '导出文件可能包含敏感信息，请保存在自己信任的位置。\n'
            '应用私有存储不等于数据库已加密，本版没有实现加密能力。',
          ),
          const SizedBox(height: YounumDimens.gapLg),
          PrimaryAction(
            label: '导出本月明细 CSV',
            style: YounumActionStyle.secondary,
            onPressed: () => _exportCurrentMonth(context),
          ),
          const SizedBox(height: YounumDimens.gap),
          PrimaryAction(
            label: '清除本地数据',
            style: YounumActionStyle.danger,
            onPressed: () => context.open(AppRoutes.deleteConfirm),
          ),
          const YounumPillNote('清除与撤回单次导入是两个不同的操作，影响范围也不一样。'),
          const YounumPillNote('导出的 CSV 是数据导出，不等同于完整备份：它不能用来还原应用。'),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// reminder —— 每月整理提醒
// -----------------------------------------------------------------------------

/// 提醒设置。
///
/// 指南 8.2 的几条要求落在这里：
///
/// * 默认关闭，用户主动打开时才申请通知权限；
/// * **显示实际状态**：权限没给、或系统里通知被关，都不显示「已开启」却收不到；
/// * 文案写「约」，因为系统省电策略允许合理延迟（我们没有申请精确闹钟权限）；
/// * 改日期或时间立刻生效并替换旧任务，不需要再点一次保存。
class ReminderScreen extends StatelessWidget {
  const ReminderScreen({super.key, required this.controller});

  final ReminderController controller;

  /// 可选的小时（6 点到 23 点）。
  static const List<int> hourOptions = <int>[
    6,
    7,
    8,
    9,
    10,
    11,
    12,
    13,
    14,
    15,
    16,
    17,
    18,
    19,
    20,
    21,
    22,
    23,
  ];

  /// 分钟：0 到 59 全给。
  ///
  /// 只给整点会很难用（想设 20:30 就设不了），也不好验证 ——
  /// 想确认一次通知真能发出来，得等到下一个整点。
  static List<int> get minuteOptions => List<int>.generate(60, (index) => index);

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final settings = controller.settings;
        final capability = controller.capability;
        final enabled = settings.enabled;
        final next = controller.nextRun;
        final now = DateTime.now();

        return YounumScreen(
          title: '整理提醒',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('每月，留一点时间给自己', style: text.screenTitle),
              const SizedBox(height: YounumDimens.gapSm),
              YounumMutedText('整理不必每天发生，一月一次就很好。'),
              const SizedBox(height: YounumDimens.gap),
              YounumPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    YounumSwitchRow(
                      label: '每月提醒我整理账单',
                      description: _switchDescription(controller),
                      value: enabled,
                      onChanged: controller.isSupported && !controller.isBusy
                          ? controller.setEnabled
                          : null,
                    ),
                    if (enabled && controller.isSupported) ...<Widget>[
                      const SizedBox(height: YounumDimens.gap),
                      const YounumFieldLabel('提醒日期'),
                      YounumSelectField<int>(
                        options: List<int>.generate(31, (index) => index + 1),
                        labelBuilder: (day) => '每月 $day 日',
                        selected: settings.day,
                        semanticLabel: '提醒日期',
                        onSelected: controller.setDay,
                      ),
                      const SizedBox(height: YounumDimens.gap),
                      const YounumFieldLabel('提醒时间 · 小时'),
                      YounumSelectField<int>(
                        options: hourOptions,
                        labelBuilder: (hour) => '$hour 点',
                        selected: settings.hour,
                        semanticLabel: '提醒小时',
                        onSelected: (hour) => controller.setTime(
                          hour: hour,
                          minute: settings.minute,
                        ),
                      ),
                      const SizedBox(height: YounumDimens.gap),
                      const YounumFieldLabel('提醒时间 · 分钟'),
                      YounumSelectField<int>(
                        options: minuteOptions,
                        labelBuilder: (minute) => '$minute 分',
                        selected: settings.minute,
                        semanticLabel: '提醒分钟',
                        onSelected: (minute) => controller.setTime(
                          hour: settings.hour,
                          minute: minute,
                        ),
                      ),
                      const SizedBox(height: YounumDimens.gap),
                      YounumMutedText(
                        next == null
                            ? '还没算好下次提醒时间。'
                            : '下次提醒约在 ${ReminderRules.describe(next)}'
                                  '（${ReminderRules.remainingLabel(next, now: now)}）',
                      ),
                      YounumMutedText(
                        '按自然日历计算，不是固定 30 天；选 29 / 30 / 31 日时，'
                        '短月顺延到当月最后一天。系统省电策略可能造成合理延迟，'
                        '所以写的是「约」。',
                      ),
                    ],
                  ],
                ),
              ),
              if (!controller.isSupported)
                const YounumNotice('这个平台上还不能发通知，所以提醒暂时用不了。')
              else if (enabled && !capability.canDeliver)
                YounumNotice(
                  capability.permissionGranted
                      ? '系统里没有允许「有数」发通知，提醒现在发不出去。'
                            '到「设置 → 应用 → 有数 → 通知」里打开后，开关照旧生效。'
                      : '通知权限还没给，提醒不会真的发出。',
                ),
              if (controller.lastFailure != null)
                YounumNotice(controller.lastFailure!),
              PrimaryAction(
                label: '完成',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _switchDescription(ReminderController controller) {
    if (!controller.isSupported) return '这个平台上还没有这个能力。';
    if (!controller.settings.enabled) return '关闭时不会有任何通知。';
    if (!controller.capability.permissionGranted) {
      return '通知权限还没给，提醒发不出来。';
    }
    if (!controller.capability.notificationsEnabled) {
      return '系统里把通知关掉了，提醒发不出来。';
    }
    return '到时会提醒你整理上一个月的账单（约在此时间，可能稍有延迟）。';
  }
}

// -----------------------------------------------------------------------------
// deleteconfirm —— 破坏性操作二次确认
// -----------------------------------------------------------------------------

/// 清除本地数据。
///
/// 确认文案必须逐项说明清除范围与保留范围（指南 8.3）。
class DeleteConfirmScreen extends StatefulWidget {
  const DeleteConfirmScreen({super.key, required this.reminder});

  /// 清除本地数据要连带取消提醒（指南 8.3）。
  final ReminderController reminder;

  @override
  State<DeleteConfirmScreen> createState() => _DeleteConfirmScreenState();
}

class _DeleteConfirmScreenState extends State<DeleteConfirmScreen> {
  bool _sheetShown = false;

  /// 是否已经请过导入会话去读批次历史。
  ///
  /// 只用来避免每帧重复请求，不是缓存 —— 真实数据在 `ImportSession` 里。
  bool _historyRequested = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sheetShown) return;
    _sheetShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _showSheet());
  }

  Future<void> _showSheet() async {
    if (!mounted) return;
    final confirmed = await showConfirmSheet(
      context: context,
      title: '清除本地数据？',
      description:
          '会移除：真实与演示账本、导入暂存文件、导出缓存、'
          '个人分类及其图标图片、整理操作日志，并取消已设置的提醒。\n\n'
          '会保留：主题配色偏好、已看过的引导状态。',
      confirmLabel: '确认清除',
      cancelLabel: '保留数据',
    );
    if (!mounted) return;
    if (confirmed) {
      await AppStateScope.read(context).clearLedger();
      if (!mounted) return;
      // 真实清空本地数据库，然后把会话状态跟着归零。
      await ReviewSessionScope.read(context).clearAllData();
      if (!mounted) return;
      // 提醒也要取消：账都清了，就不该再收到「该整理上个月的账单」。
      await widget.reminder.cancelReminder();
      if (!mounted) return;
      showYounumToast(context, '本地数据已清除');
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final session = ReviewSessionScope.of(context);
    // 「导入批次」要显示真实数量，所以进页就把历史读一遍 ——
    // 这里与「导入记录」页读的是同一个仓库方法，不会出现两处数字对不上。
    final importSession = ImportSessionScope.of(context);
    if (!_historyRequested) {
      _historyRequested = true;
      // 在 build 期间直接 await 是不行的：靠一帧后的回调去加载，
      // 加载完 `notifyListeners` 会把这一页重新构建一遍。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) importSession.loadHistory();
      });
    }

    return YounumScreen(
      title: '数据管理',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('管理我的账单', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gap),
          YounumPanel(
            child: Column(
              children: <Widget>[
                YounumLineInfo(
                  label: '本地消费记录',
                  value:
                      '${session.report?.dataset.transactions.length ?? 0} 笔',
                ),
                YounumLineInfo(
                  label: '导入批次',
                  // 真实数量，不是占位符：批次表从阶段 3 起就在用，这里的数字
                  // 与「导入记录」页看到的是同一份数据。
                  value: '${importSession.history.length} 批',
                ),
                YounumLineInfo(
                  label: '有记录的月份',
                  value: '${session.recordedMonths.length} 个月',
                ),
              ],
            ),
          ),
          const YounumNotice(
            '清除操作会把账本切回空状态（首页回到「从一份账单开始」），'
            '并保留主题配色与已看过的引导状态。',
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// offline —— 已保存 / 恢复状态
// -----------------------------------------------------------------------------

/// 已保存与恢复状态。
///
/// 必须从真实的持久化结果生成，不能虚报「已保存」（指南第 5 节 offline）。
/// 首版没有网络能力，因此离线是常态而不是降级。
class OfflineStatusScreen extends StatelessWidget {
  const OfflineStatusScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final session = ReviewSessionScope.of(context);
    final now = YounumClock.now();

    return YounumScreen(
      title: '整理进度',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SizedBox(height: YounumDimens.gapLg),
          const Center(
            child: YounumCircleSymbol(icon: YounumIcons.shield, diameter: 88),
          ),
          const SizedBox(height: YounumDimens.gapLg),
          Text(
            '已保存，下次接着来。',
            textAlign: TextAlign.center,
            style: text.screenTitle,
          ),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText(
            '应用不需要网络。已导入的账单一直可以继续整理，'
            '不会因为你关掉 App 而丢失。',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: YounumDimens.gapLg),
          YounumPanel(
            tone: YounumPanelTone.soft,
            child: Column(
              children: <Widget>[
                YounumLineInfo(
                  label: '已完成分类',
                  value: '${session.doneCount} / ${session.totalCount} 笔',
                ),
                YounumLineInfo(
                  label: '剩余待处理',
                  value: '${session.remainingCount} 笔',
                ),
                YounumLineInfo(
                  label: '稍后处理',
                  value: '${session.deferred.length} 笔',
                ),
                YounumLineInfo(
                  label: '本次打开',
                  value:
                      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
                ),
              ],
            ),
          ),
          const YounumNotice(
            '整理进度保存在这台设备上。清除 App 数据前，请先导出需要保留的内容。'
            '系统的云备份与设备迁移已按「仅本地」的承诺关闭。',
          ),
          PrimaryAction(label: '继续整理', onPressed: () => context.selectTab(1)),
          const SizedBox(height: YounumDimens.gap),
          PrimaryAction(
            label: '返回本月首页',
            style: YounumActionStyle.secondary,
            onPressed: () => context.selectTab(0),
          ),
        ],
      ),
    );
  }
}
