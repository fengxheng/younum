import 'package:flutter/material.dart';

import '../../app/app_routes.dart';
import '../../app/route_args.dart';
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
import 'import_session.dart';

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
                  onTap: () => context.open(
                    AppRoutes.upload,
                    arguments: const ImportSourceArgs(
                      sourceNamespace: 'wechat',
                      title: '微信支付',
                    ),
                  ),
                ),
                YounumListRow(
                  title: '支付宝',
                  subtitle: '导入支付宝导出的账单文件',
                  icon: YounumIcons.wallet,
                  iconTone: YounumTileTone.blue,
                  trailingWidget: const _RowChevron(),
                  onTap: () => context.open(
                    AppRoutes.upload,
                    arguments: const ImportSourceArgs(
                      sourceNamespace: 'alipay',
                      title: '支付宝',
                    ),
                  ),
                ),
                YounumListRow(
                  title: '通用表格',
                  // 支持的是三种后缀，但**判据是内容不是后缀**：老式 .xls
                  // （真正的 BIFF 格式）读不了，那时会明确让用户另存一份。
                  subtitle: 'CSV / XLS / XLSX，手动匹配列名',
                  icon: YounumIcons.settings,
                  iconTone: YounumTileTone.purple,
                  trailingWidget: const _RowChevron(),
                  showDivider: false,
                  // 不能直接跳到「匹配字段」页：那时还没有文件，
                  // 用户会到一个无列可匹配的死路上。先去选文件。
                  onTap: () => context.open(
                    AppRoutes.upload,
                    arguments: const ImportSourceArgs(
                      sourceNamespace: 'manual',
                      title: '通用表格',
                    ),
                  ),
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
            _GuideStep(
              index: index,
              title: _steps[index][0],
              description: _steps[index][1],
            ),
          const YounumNotice('具体入口随平台版本变化，以平台当前界面为准。请勿向任何人提供支付密码。'),
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
              decoration: BoxDecoration(
                color: colors.softColor,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                '0${index + 1}',
                style: text.micro.copyWith(color: colors.primaryColor),
              ),
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
/// 点「选择账单文件」会打开**系统文件选择器**（`ImportSession.pickAndStage`），
/// 拿到字节之后立刻解析，然后由 [ParsingScreen] 接手展示进度并往前走。
///
/// 已经解析好一份账单时（例如用户从核对页返回），这一页改为展示**真实**的
/// 文件信息与统计，并给一个「继续核对」的入口，而不是让用户再选一次。
class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key, this.args});

  /// 从「选择账单来源」页带过来的来源。
  final ImportSourceArgs? args;

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  /// 用户确认过「账单只用于本地统计」。
  ///
  /// 默认勾上：这是一个告知性的确认，不是一个需要用户费心才能通过的门槛。
  bool _consent = true;

  /// 来源只在**真正开始解析之前**应用。
  ///
  /// 不能在 `didChangeDependencies` 里做：`useSource` 换来源时会重置会话并
  /// 通知监听者，而那时框架正在 build（widget 测试会直接报
  /// 「setState() called during build」）。真正需要它准备好的一刻就是
  /// 点「选择账单文件」的时候。
  void _applySource() {
    final args = widget.args;
    if (args == null) return;
    // 来源会进入同源去重键，所以必须在解析之前设好。
    ImportSessionScope.read(context).useSource(args.sourceNamespace);
  }

  String? get _sourceTitle => widget.args?.title;

  Future<void> _pick() async {
    final session = ImportSessionScope.read(context);
    if (!session.canPick) return;
    _applySource();

    // 先切到解析页再开始读文件：读取与解析都在后台做（指南 4.2.9），
    // 用户不该在这一页干等；解析页会在有结论之后自己往下走。
    context.open(AppRoutes.parsing);
    await session.pickAndStage();
  }

  @override
  Widget build(BuildContext context) {
    final session = ImportSessionScope.of(context);
    final text = YounumText.of(context);
    final colors = YounumColors.of(context);
    final staged = session.preview;

    return YounumScreen(
      title: '选择账单文件',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('导入你的月账单', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText(
            _sourceTitle == null
                ? '一次支持一个文件，可多次追加导入。'
                : '来自「$_sourceTitle」。一次支持一个文件，可多次追加导入。',
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
                  YounumMutedText('CSV / XLS / XLSX · 最大 64 MB'),
                  const SizedBox(height: YounumDimens.gap),
                  PrimaryAction(
                    label: '选择账单文件',
                    style: YounumActionStyle.secondary,
                    onPressed: _consent && session.canPick ? _pick : null,
                  ),
                ],
              ),
            ),
          ),

          if (staged != null) ...<Widget>[
            const SizedBox(height: YounumDimens.gap),
            YounumPanel(
              child: Row(
                children: <Widget>[
                  ExcludeSemantics(
                    child: Icon(
                      YounumIcons.cards,
                      size: YounumDimens.iconLg,
                      color: colors.inkColor,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          session.fileName ?? '账单文件',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        YounumCaptionText(
                          '${staged.encoding} 编码 · '
                          '读到 ${staged.totalRows} 行 · '
                          '可导入 ${staged.freshCount} 笔',
                        ),
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
            const SizedBox(height: YounumDimens.gap),
            PrimaryAction(
              label: staged.needsReview ? '去核对这笔账单' : '去核对',
              trailingArrow: true,
              onPressed: () => context.open(AppRoutes.checkImport),
            ),
          ],

          if (session.phase == ImportPhase.failed) ...<Widget>[
            const SizedBox(height: YounumDimens.gap),
            YounumNotice(
              session.errorNeedsReselect
                  ? '${session.errorMessage}\n\n这份文件本身还在，重新选一次就好。'
                  : (session.errorMessage ?? '这份账单没读进来'),
            ),
          ],

          YounumCheckRow(
            label: '我已了解账单将用于本月整理和消费统计',
            value: _consent,
            onChanged: (value) => setState(() => _consent = value),
          ),
          // 不给「点了没反应的按钮」：文件选择与解析都已经接上真实实现，
          // 失败时上面那块提示会说清原因与下一步。
          const YounumPillNote('账单只在你的手机上解析与保存，不会上传。'),
        ],
      ),
    );
  }
}
