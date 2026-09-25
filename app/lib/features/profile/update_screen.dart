import 'package:flutter/material.dart';

import '../../core/components/buttons.dart';
import '../../core/components/primitives.dart';
import '../../core/components/progress.dart';
import '../../core/components/screen_scaffold.dart';
import '../../core/components/sheets.dart';
import '../../core/designsystem/younum_dimens.dart';
import '../../core/designsystem/younum_icons.dart';
import '../../core/designsystem/younum_text.dart';
import '../../domain/rules/update_rules.dart';
import 'update_controller.dart';

/// 检查更新（在线升级）。
///
/// 界面上要守住两件事：
///
/// 1. **不撒谎**：查不到就说查不到。断网、被墙、作者还没发过版本，
///    都不是「已是最新」—— 把没查到说成最新，用户会以为自己在用最新版。
/// 2. **不替用户做决定**：下载要用户点，安装要用户在系统界面点。
///    应用能做的是把「现在到哪一步了」说清楚。
class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key});

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  /// 这台设备允不允许安装应用。null 表示还没问到。
  bool? _canInstall;

  /// 上一次问设备权限是什么时候，用来避免每帧都问。
  bool _asked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_asked) return;
    _asked = true;
    _refreshInstallPermission();
  }

  Future<void> _refreshInstallPermission() async {
    final controller = UpdateScope.of(context);
    final allowed = await controller.canInstall();
    if (!mounted) return;
    setState(() => _canInstall = allowed);
  }

  @override
  Widget build(BuildContext context) {
    final controller = UpdateScope.of(context);
    final text = YounumText.of(context);
    final info = controller.available;
    final phase = controller.phase;

    return YounumScreen(
      title: '检查更新',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('当前版本', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  controller.currentVersionName.isEmpty
                      ? '未知版本'
                      : '有数 ${controller.currentVersionName}'
                      '（${controller.currentVersionCode}）',
                  style: text.listPrimary,
                ),
                const SizedBox(height: 6),
                const YounumCaptionText(
                  '新版本从项目的 GitHub Release 页面获取。检查更新只会'
                  '访问那一个公开的版本号文件，账单数据不会离开这台设备。',
                ),
              ],
            ),
          ),
          const SizedBox(height: YounumDimens.gapLg),

          if (phase == UpdatePhase.checking)
            const YounumProgressTrack(value: null, semanticLabel: '正在检查更新'),

          if (phase == UpdatePhase.upToDate) ...<Widget>[
            const YounumNotice('已经是最新版本。'),
          ],

          if (info != null) ...<Widget>[
            YounumPanel(
              tone: YounumPanelTone.soft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('有新版本 ${info.versionName}', style: text.listPrimary),
                  if (info.notes.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 6),
                    YounumCaptionText(info.notes),
                  ],
                ],
              ),
            ),
            if (phase == UpdatePhase.skipped)
              const YounumPillNote('你已经忽略过这个版本；装它随时可以。'),
            const SizedBox(height: YounumDimens.gapSm),
          ],

          // 下载进度。几十兆的东西转一分钟，屏幕上必须看得见在动。
          ValueListenableBuilder<int?>(
            valueListenable: controller.downloadProgress,
            builder: (context, percent, _) {
              if (percent == null) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  YounumProgressTrack(
                    value: percent / 100,
                    semanticLabel: '下载安装包',
                  ),
                  const SizedBox(height: 6),
                  YounumCaptionText(
                    percent >= 100 ? '下载完成，正在交给系统安装…' : '已下载 $percent%',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: YounumDimens.gapSm),
                ],
              );
            },
          ),

          // 「允许安装未知应用」这件事只有用户能在系统设置里做，
          // 所以不能替他点，只能把他带过去。
          if (_canInstall == false) ...<Widget>[
            const YounumNotice(
              '系统还没允许「有数」安装应用。点下面的按钮去打开它，'
              '打开之后回来再点一次安装。',
            ),
            const SizedBox(height: YounumDimens.gapSm),
            PrimaryAction(
              label: '去允许安装',
              style: YounumActionStyle.secondary,
              onPressed: () async {
                await controller.openInstallSettings();
                if (!mounted) return;
                await _refreshInstallPermission();
              },
            ),
          ],

          // ⚠️ 每个按钮前面都要留间距。
          //
          // 两个同色实底按钮如果贴在一起，圆角处会出现一条「蝴蝶结」接缝，
          // 看上去就像两块叠在一起（真机上就是这么被发现的：这一页在
          // 「系统没允许安装」时，上面那个次要按钮和下面的「检查更新」
          // 正好首尾相接）。间距不是装饰，是让两个可点区域在视觉上分开。
          const SizedBox(height: YounumDimens.gapSm),

          if (info != null) ...<Widget>[
            PrimaryAction(
              label: phase == UpdatePhase.installing ? '正在下载…' : '下载并安装',
              trailingArrow: true,
              onPressed: phase == UpdatePhase.installing
                  ? null
                  : () async {
                      await controller.install();
                      if (!mounted) return;
                      // 安装过程中用户可能刚去打开了开关，回来重新问一次。
                      await _refreshInstallPermission();
                    },
            ),
            const SizedBox(height: YounumDimens.gapSm),
            PrimaryAction(
              label: '忽略这个版本',
              style: YounumActionStyle.plain,
              onPressed: phase == UpdatePhase.installing
                  ? null
                  : () => controller.skipCurrent(),
            ),
            const SizedBox(height: YounumDimens.gapSm),
          ],

          PrimaryAction(
            label: phase == UpdatePhase.checking ? '正在检查…' : '检查更新',
            style: YounumActionStyle.secondary,
            onPressed: phase == UpdatePhase.checking
                ? null
                : () async {
                    await controller.check(byUser: true);
                    if (!mounted) return;
                    await _refreshInstallPermission();
                  },
          ),

          const SizedBox(height: YounumDimens.gapSm),

          if (controller.message != null && phase != UpdatePhase.installing)
            YounumPillNote(controller.message!),

          const YounumPillNote(
            '下载好的安装包会交给系统的安装界面，最后那一下「安装」由你点。',
          ),
          if (controller.currentVersionName.isEmpty)
            const YounumPillNote('这个平台上读不到版本号，所以无法检查更新。'),
        ],
      ),
    );
  }
}
/// 用户在启动提示里选了什么。
///
/// 「忽略这个版本」与「以后再说」是**两件不同的事**，所以不能合成一个按钮：
/// 前者写进偏好、同一个版本不再打扰（下一个版本还会提）；后者只是这次不装，
/// 下次启动还会问。合成一个的后果是：要么用户被反复打扰，要么他想下次再说
/// 却被永久静音。
enum UpdatePromptChoice {
  /// 去「检查更新」页下载并安装。
  update,

  /// 忽略这个版本：同一个版本不再提示，直到出现更高的版本。
  skip,

  /// 以后再说：什么都不记，下次启动还会提醒。
  later,
}

/// 启动时发现新版本的提示层。
///
/// 为什么用弹层而不是页面：用户是为了别的事打开应用的，把他直接推到
/// 「检查更新」页等于替他决定了这次要干什么。弹层只说「有新版本」，
/// 主动权还在他手上。
///
/// 返回 `null`（划掉弹层）与 [UpdatePromptChoice.later] 同义：什么都不做。
Future<UpdatePromptChoice?> showUpdatePromptSheet({
  required BuildContext context,
  required UpdateInfo info,
}) => showModalBottomSheet<UpdatePromptChoice>(
  context: context,
  backgroundColor: Colors.transparent,
  isScrollControlled: true,
  showDragHandle: false,
  builder: (sheetContext) {
    final text = YounumText.of(sheetContext);
    void choose(UpdatePromptChoice choice) =>
        Navigator.of(sheetContext).pop(choice);
    return SingleChildScrollView(
      // ⚠️ 滚动包在**整块弹层外面**：更新说明是 GitHub Release 正文的原文，
      // 写多长由发布的人决定。实测：按真实长度的一份说明，不可滚动时溢出
      // 293px，「以后再说」直接被挤出屏幕。包在里面还差表面抓手那几像素，
      // 所以范围要盖住整个 YounumSheetSurface（与 NoticeSheet 同一个处理）。
      child: YounumSheetSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Center(
              child: YounumCircleSymbol(
                icon: YounumIcons.download,
                diameter: YounumDimens.circleSymbolSmall,
              ),
            ),
            const SizedBox(height: YounumDimens.gapLg),
            Text(
              '有新版本 ${info.versionName}',
              textAlign: TextAlign.center,
              style: text.sheetTitle,
            ),
            const SizedBox(height: YounumDimens.gapSm),
            YounumMutedText(
              // 没写更新说明时不能空着 —— 那样用户不知道点「去更新」会得到什么。
              info.notes.isEmpty ? '新版本已经发布，装不装由你决定。' : info.notes,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: YounumDimens.gapXl),
            PrimaryAction(
              label: '去更新',
              trailingArrow: true,
              onPressed: () => choose(UpdatePromptChoice.update),
            ),
            const SizedBox(height: YounumDimens.gap),
            PrimaryAction(
              label: '忽略这个版本',
              style: YounumActionStyle.plain,
              onPressed: () => choose(UpdatePromptChoice.skip),
            ),
            const SizedBox(height: YounumDimens.gap),
            PrimaryAction(
              label: '以后再说',
              style: YounumActionStyle.secondary,
              onPressed: () => choose(UpdatePromptChoice.later),
            ),
          ],
        ),
      ),
    );
  },
);