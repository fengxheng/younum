import 'package:flutter/material.dart';

import '../../app/app_routes.dart';
import '../../app/route_args.dart';
import '../../core/components/buttons.dart';
import '../../core/components/list_row.dart';
import '../../core/components/primitives.dart';
import '../../core/components/screen_scaffold.dart';
import '../../core/designsystem/younum_colors.dart';
import '../../core/designsystem/younum_dimens.dart';
import '../../core/designsystem/younum_text.dart';
import '../organize/review_session.dart';
import '../report/report_screens.dart';

/// 设计状态走查（仅调试构建）。
///
/// 原型里的设计画廊、侧边目录、手机外框**不会**进入正式 App（指南 1.3）。
/// 但 33 个状态需要一个高效的核对入口，因此这里保留一个只在 `kDebugMode`
/// 下注册的清单页：Release 构建既不注册路由也不显示入口。
///
/// 它的作用是把「怎么走到这个状态」写清楚，而不是再造一个假界面 ——
/// 点进去的是真实页面。
class DesignReviewScreen extends StatelessWidget {
  const DesignReviewScreen({super.key});

  static const List<_ReviewGroup> _groups = <_ReviewGroup>[
    _ReviewGroup(
      title: '01 开始与本月',
      entries: <_ReviewEntry>[
        _ReviewEntry('welcome', '欢迎与产品引导', '首次进入；确认后不再重复出现', AppRoutes.welcome),
        _ReviewEntry('empty', '首页 · 首次使用', '空状态：导入入口 + 示例体验', AppRoutes.emptyHome),
        _ReviewEntry('home', '首页 · 本月整理进度', '金额、来源、待整理数（需在示例账本）', AppRoutes.home),
      ],
    ),
    _ReviewGroup(
      title: '02 账单导入',
      entries: <_ReviewEntry>[
        _ReviewEntry('import', '选择账单来源', '微信 / 支付宝 / 通用表格', AppRoutes.billImport),
        _ReviewEntry('guide', '账单导出指引', '平台切换会改变步骤', AppRoutes.exportGuide),
        _ReviewEntry('upload', '选择文件与月份', '需先选文件并勾选同意才能继续', AppRoutes.upload),
        _ReviewEntry('parsing', '文件识别中', '不定进度，不伪造百分比', AppRoutes.parsing),
        _ReviewEntry('mapping', '通用表格字段匹配', '必填项缺失或重复时不可继续', AppRoutes.mapping),
        _ReviewEntry('checkimport', '导入结果核对', '消费 / 非消费 / 重复 / 异常分行', AppRoutes.checkImport),
        _ReviewEntry('duplicates', '疑似重复记录', '逐组处理，可「都保留」', AppRoutes.duplicates),
        _ReviewEntry('importerror', '导入失败与异常行', '区分文件级与行级错误', AppRoutes.importError),
      ],
    ),
    _ReviewGroup(
      title: '03 卡片整理',
      entries: <_ReviewEntry>[
        _ReviewEntry('cards', '堆叠卡片 · 逐笔归类', '左滑稍后、右滑确认、未选分类右滑不提交', AppRoutes.cards),
        _ReviewEntry('allcats', '完整分类选择', '细分用途 + 我的分类', AppRoutes.allCategories),
        _ReviewEntry('categorymanage', '分类管理 · 图标设置', '内置与自定义分类均可改图标', AppRoutes.categoryManage),
        _ReviewEntry('newcat', '新建分类 / 编辑图标', '名称校验、预设图标、恢复默认', AppRoutes.categoryEditor),
        _ReviewEntry('detail', '交易详情与更多操作', '按实际交易 ID 展示', AppRoutes.transactionDetail),
        _ReviewEntry('split', '拆分一笔消费', '合计必须精确等于原金额', AppRoutes.splitTransaction),
        _ReviewEntry('nonexpense', '转账 / 退款 / 排除统计', '退款需关联，排除需填原因', AppRoutes.transactionNature),
        _ReviewEntry('pending', '稍后处理清单', '不增加完成数', AppRoutes.pendingQueue),
        _ReviewEntry('complete', '整理完成', '仅在无待整理记录时出现', AppRoutes.reviewComplete),
      ],
    ),
    _ReviewGroup(
      title: '04 月度回顾',
      entries: <_ReviewEntry>[
        _ReviewEntry('report', '月度消费概况', '范围未确认时标注「部分账单」', AppRoutes.report),
        _ReviewEntry('breakdown', '消费分类详情', '分类金额之和等于消费净额', AppRoutes.breakdown),
        _ReviewEntry('trends', '趋势与环比', '零分母与部分月份单独处理', AppRoutes.trends),
        _ReviewEntry('transactions', '明细检索', '搜索 + 整理状态筛选', AppRoutes.transactions),
        _ReviewEntry('share', '分享与导出', '每次进入默认隐藏金额', AppRoutes.share),
        _ReviewEntry('months', '月份切换与历史', '无记录的月份不显示金额', AppRoutes.months),
      ],
    ),
    _ReviewGroup(
      title: '05 我的与边界状态',
      entries: <_ReviewEntry>[
        _ReviewEntry('profile', '我的', '全部设置入口', AppRoutes.profile),
        _ReviewEntry('theme', '主题与配色', '六套预设 + 取色器 + HEX', AppRoutes.theme),
        _ReviewEntry('importhistory', '导入记录与撤回', '撤回前展示真实影响', AppRoutes.importHistory),
        _ReviewEntry('privacy', '隐私与数据', '本机处理，联网只用于检查更新', AppRoutes.privacy),
        _ReviewEntry('reminder', '每月整理提醒', '默认关闭，权限状态如实显示', AppRoutes.reminder),
        _ReviewEntry('deleteconfirm', '破坏性操作确认', '逐项说明清除与保留范围', AppRoutes.deleteConfirm),
        _ReviewEntry('offline', '已保存 / 恢复状态', '来自真实会话状态', AppRoutes.offlineStatus),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final session = ReviewSessionScope.of(context);

    return YounumScreen(
      title: '设计状态走查',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          YounumMutedText(
            '共 33 个设计状态。这里只是索引，点进去都是真实页面。'
            'Release 构建不包含本页。',
          ),
          // 互动演示用的开关：让下一次滑卡确认失败，检查「卡片恢复、选择保留」。
          YounumPanel(
            tone: YounumPanelTone.soft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('交互验证开关', style: text.sectionTitle),
                const SizedBox(height: YounumDimens.gapSm),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: YounumMutedText(
                        session.debugFailNextCommitEnabled
                            ? '下一次确认或稍后处理会失败：卡片应回到原位，已选用途保留。'
                            : '开启后，下一次卡片提交会模拟保存失败。',
                      ),
                    ),
                    Switch(
                      value: session.debugFailNextCommitEnabled,
                      onChanged: session.setDebugFailNextCommit,
                    ),
                  ],
                ),
              ],
            ),
          ),
          YounumPanel(
            tone: YounumPanelTone.soft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('额外状态', style: text.sectionTitle),
                const SizedBox(height: YounumDimens.gapSm),
                _ExtraStateButton(
                  label: '月报 · 无消费空状态',
                  description: '检查环形图不被除以零、不显示占比',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) => const ReportScreen(debugForceEmpty: true),
                    ),
                  ),
                ),
                _ExtraStateButton(
                  label: '分类选择 · 编辑详情用途',
                  description: '检查带调用目的进入后返回正确调用方',
                  onTap: () => context.open(
                    AppRoutes.allCategories,
                    arguments: const CategoryPickArgs(
                      purpose: CategoryPickPurpose.detail,
                    ),
                  ),
                ),
                _ExtraStateButton(
                  label: '分类选择 · 编辑拆分项',
                  description: '第三个调用目的',
                  onTap: () => context.open(
                    AppRoutes.allCategories,
                    arguments: const CategoryPickArgs(
                      purpose: CategoryPickPurpose.splitItem,
                    ),
                  ),
                ),
              ],
            ),
          ),
          for (final group in _groups) ...<Widget>[
            YounumSectionHeader(title: group.title),
            YounumPanel(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: <Widget>[
                  for (var index = 0; index < group.entries.length; index++)
                    YounumListRow(
                      title: group.entries[index].title,
                      subtitle:
                          '${group.entries[index].id} · ${group.entries[index].description}',
                      icon: null,
                      iconKey: null,
                      leading: SizedBox(
                        width: 26,
                        child: Text(
                          '${index + 1}'.padLeft(2, '0'),
                          style: text.caption,
                        ),
                      ),
                      showDivider: index != group.entries.length - 1,
                      onTap: () => _go(context, group.entries[index]),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _go(BuildContext context, _ReviewEntry entry) {
    switch (entry.route) {
      case AppRoutes.home:
        context.selectTab(0);
      case AppRoutes.cards:
        context.selectTab(1);
      case AppRoutes.report:
        context.selectTab(2);
      case AppRoutes.profile:
        context.selectTab(3);
      default:
        context.open(entry.route);
    }
  }
}

class _ExtraStateButton extends StatelessWidget {
  const _ExtraStateButton({
    required this.label,
    required this.description,
    required this.onTap,
  });

  final String label;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final colors = YounumColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: YounumPressable(
        onTap: onTap,
        semanticLabel: '$label，$description',
        borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(label, style: text.listPrimary.copyWith(fontSize: 13)),
                  const SizedBox(height: 3),
                  Text(description, style: text.micro),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: YounumDimens.iconMd,
              color: colors.mutedColor,
            ),
          ],
        ),
      ),
    );
  }
}

class _ReviewEntry {
  const _ReviewEntry(this.id, this.title, this.description, this.route);

  final String id;
  final String title;
  final String description;
  final String route;
}

class _ReviewGroup {
  const _ReviewGroup({required this.title, required this.entries});

  final String title;
  final List<_ReviewEntry> entries;
}
