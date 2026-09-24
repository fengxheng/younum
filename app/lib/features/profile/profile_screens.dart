import 'package:flutter/material.dart';

import '../../app/app_routes.dart';
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
import '../../core/preferences/theme_controller.dart';
import '../../core/time/younum_clock.dart';
import '../../data/sample/sample_data.dart';
import '../organize/review_session.dart';

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
                    borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
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
/// 撤回前必须计算并展示真实影响（独占记录数、仍被引用的记录数、关联退款、
/// 受影响月份），不能只说「确定撤回吗」（指南 4.4）。
class ImportHistoryScreen extends StatelessWidget {
  const ImportHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);

    return YounumScreen(
      title: '导入记录',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('每份账单，都有来处', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText('重新导入同一文件时，会自动检查重复。'),
          const YounumSectionHeader(title: '2026年9月'),
          for (var index = 0; index < SampleData.importBatches.length; index++)
            YounumPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          SampleData.importBatches[index].name,
                          style: text.listPrimary,
                        ),
                      ),
                      const YounumBadge('已导入'),
                    ],
                  ),
                  const SizedBox(height: YounumDimens.gapSm),
                  YounumMutedText(
                    '${SampleData.importBatches[index].newCount} 笔新增消费'
                    '${SampleData.importBatches[index].excludedDuplicateCount == 0 ? '' : ' · ${SampleData.importBatches[index].excludedDuplicateCount} 笔重复已排除'}',
                  ),
                  const SizedBox(height: 4),
                  YounumCaptionText(
                    '${SampleData.importBatches[index].importedAtText} · '
                    '${SampleData.importBatches[index].fileSizeText}',
                  ),
                  const YounumDivider(),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          SampleData.importBatches[index].amountText,
                          style: text.amountInline,
                        ),
                      ),
                      YounumPressable(
                        onTap: () => _withdraw(context, index),
                        semanticLabel: '撤回${SampleData.importBatches[index].name}',
                        borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                          child: Text(
                            '撤回导入',
                            style: text.label.copyWith(
                              color: YounumColors.of(context).primaryColor,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          PrimaryAction(
            label: '查看异常记录',
            style: YounumActionStyle.secondary,
            onPressed: () => context.open(AppRoutes.importError),
          ),
          const SizedBox(height: YounumDimens.gap),
          PrimaryAction(
            label: '导入新账单',
            onPressed: () => context.open(AppRoutes.billImport),
          ),
          const YounumDemoNote(
            '设计走查：撤回会展示真实影响范围。'
            '按来源引用关系删除（而不是按单个 batchId 批量删）在阶段 3 接入。',
          ),
        ],
      ),
    );
  }

  Future<void> _withdraw(BuildContext context, int index) async {
    final batch = SampleData.importBatches[index];
    final confirmed = await showConfirmSheet(
      context: context,
      title: '撤回「${batch.name}」？',
      description: '将移除 ${batch.newCount} 笔仅来自这份账单的记录，'
          '并重算 2026年9月 的消费概况。'
          '如果某些记录还被另一份账单引用，它们会被保留。'
          '此操作不删除其它文件的数据。',
      confirmLabel: '撤回这次导入',
      cancelLabel: '保留数据',
    );
    if (!context.mounted || !confirmed) return;
    showYounumToast(context, '已撤回「${batch.name}」');
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
          YounumMutedText(
            '默认本地保存。App 没有申请互联网权限，账单不会离开这台设备。',
          ),
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
                    Expanded(
                      child: Text('仅用于账单整理', style: text.sectionTitle),
                    ),
                  ],
                ),
                const SizedBox(height: YounumDimens.gapSm),
                const YounumMutedText(
                  '不索取支付密码，不访问你的支付账户。仅处理你主动选择的文件。',
                ),
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
            label: '导出我的数据',
            style: YounumActionStyle.secondary,
            onPressed: () => showYounumToast(
              context,
              'CSV 导出将在阶段 5 接入；导出的 CSV 不等同于完整备份',
            ),
          ),
          const SizedBox(height: YounumDimens.gap),
          PrimaryAction(
            label: '清除本地数据',
            style: YounumActionStyle.danger,
            onPressed: () => context.open(AppRoutes.deleteConfirm),
          ),
          const YounumPillNote('清除与撤回单次导入是两个不同的操作，影响范围也不一样。'),
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
/// 默认关闭；开启时需要说明用途。通知权限未开启时必须显示**实际**状态，
/// 不能显示「已开启」却发不出通知（指南 8.2）。
class ReminderScreen extends StatefulWidget {
  const ReminderScreen({super.key});

  @override
  State<ReminderScreen> createState() => _ReminderScreenState();
}

class _ReminderScreenState extends State<ReminderScreen> {
  static const List<String> _days = <String>[
    '每月 1 日 · 整理上月',
    '每月 5 日 · 整理上月',
    '每月 10 日 · 整理上月',
  ];

  static const List<String> _hours = <String>[
    '20:00',
    '12:00',
    '09:00',
  ];

  /// 默认关闭（指南 8.2）。
  bool _enabled = false;
  int _day = 0;
  int _hour = 0;

  /// 通知权限状态。阶段 6 会替换为真实权限查询结果，因此这里还不是可变状态。
  final bool _permissionGranted = false;

  int get _dayValue => const <int>[1, 5, 10][_day];

  int get _hourValue => const <int>[20, 12, 9][_hour];

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final next = YounumClock.nextMonthly(_dayValue, _hourValue);

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
                  description: _enabled
                      ? '到时会提醒你整理上一个月的账单。'
                      : '关闭时不会有任何通知。',
                  value: _enabled,
                  onChanged: (value) => setState(() => _enabled = value),
                ),
                if (_enabled) ...<Widget>[
                  const YounumFieldLabel('提醒日期'),
                  YounumSelectField<int>(
                    options: List<int>.generate(_days.length, (index) => index),
                    labelBuilder: (index) => _days[index],
                    selected: _day,
                    semanticLabel: '提醒日期',
                    onSelected: (value) => setState(() => _day = value),
                  ),
                  const SizedBox(height: YounumDimens.gap),
                  const YounumFieldLabel('提醒时间'),
                  YounumSelectField<int>(
                    options: List<int>.generate(_hours.length, (index) => index),
                    labelBuilder: (index) => _hours[index],
                    selected: _hour,
                    semanticLabel: '提醒时间',
                    onSelected: (value) => setState(() => _hour = value),
                  ),
                  const SizedBox(height: YounumDimens.gap),
                  YounumMutedText(
                    '下次提醒约在 ${next.year}年${next.month}月${next.day}日 '
                    '${_hourValue.toString().padLeft(2, '0')}:00'
                    '（还有 ${daysUntil(next)} 天）',
                  ),
                  YounumMutedText(
                    '按自然日历计算，不是固定 30 天；系统省电策略可能造成合理延迟。',
                  ),
                ],
              ],
            ),
          ),
          if (_enabled && !_permissionGranted)
            const YounumNotice(
              '通知权限尚未开启。未授权时不会显示「已开启」——'
              '需要在系统设置里允许通知，提醒才会真正发出。',
            ),
          PrimaryAction(
            label: '保存提醒设置',
            onPressed: () => showYounumToast(
              context,
              _enabled
                  ? (_permissionGranted
                      ? '提醒设置已保存'
                      : '设置已保存，但通知权限未开启，暂时收不到提醒')
                  : '已关闭提醒',
            ),
          ),
          if (_enabled && !_permissionGranted)
            PrimaryAction(
              label: '开启通知权限',
              style: YounumActionStyle.secondary,
              onPressed: () => showYounumToast(
                context,
                'Android 13 及以上需要 POST_NOTIFICATIONS 运行时权限，阶段 6 接入',
              ),
            ),
          const YounumDemoNote(
            '设计走查：日期与时间会真实推算下次触发时间。'
            'WorkManager 后台任务与权限申请在阶段 6 接入。',
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// deleteconfirm —— 破坏性操作二次确认
// -----------------------------------------------------------------------------

/// 清除本地数据。
///
/// 确认文案必须逐项说明清除范围与保留范围（指南 8.3）。
class DeleteConfirmScreen extends StatefulWidget {
  const DeleteConfirmScreen({super.key});

  @override
  State<DeleteConfirmScreen> createState() => _DeleteConfirmScreenState();
}

class _DeleteConfirmScreenState extends State<DeleteConfirmScreen> {
  bool _sheetShown = false;

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
      description: '会移除：真实与演示账本、导入暂存文件、导出缓存、'
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
      showYounumToast(context, '本地数据已清除');
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final session = ReviewSessionScope.of(context);

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
                  value: '${session.report?.dataset.transactions.length ?? 0} 笔',
                ),
                const YounumLineInfo(
                  // 导入批次表（import_batch）属于阶段 3，现在还没有数据可数。
                  // 这里如实留空，不用样例数字充数。
                  label: '导入批次',
                  value: '—',
                ),
                YounumLineInfo(
                  label: '有记录的月份',
                  value: '${session.recordedMonths.length} 个月',
                ),
              ],
            ),
          ),
          const YounumDemoNote(
            '清除操作会真实把账本切回空状态（首页回到「从一份账单开始」），'
            '并保留主题与引导状态。后台导入任务的取消协调在阶段 6 接入。',
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
          PrimaryAction(
            label: '继续整理',
            onPressed: () => context.selectTab(1),
          ),
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
