import 'package:flutter/material.dart';

import '../../core/components/buttons.dart';
import '../../core/components/primitives.dart';
import '../../core/components/progress.dart';
import '../../core/components/screen_scaffold.dart';
import '../../core/designsystem/younum_dimens.dart';
import '../../core/designsystem/younum_text.dart';
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
