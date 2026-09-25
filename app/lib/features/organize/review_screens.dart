import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_routes.dart';
import '../../app/route_args.dart';
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
import '../../core/money/money.dart';
import '../../core/time/statistics_time.dart';
import '../../domain/models/allocation.dart';
import '../../domain/models/category.dart';
import '../../domain/models/ledger_transaction.dart';
import 'category_registry.dart';
import 'refund_allocation_editor.dart';
import 'review_card.dart';
import 'review_session.dart';

/// 按 ID 解析交易。
///
/// 详情页必须依据**实际交易 ID** 展示与编辑，不能固定成某一笔
/// （指南第 5 节 detail）。找不到时返回 null，由调用方给出解释与返回入口。
///
/// 从会话的完整数据集里找，而不是只翻当前队列：明细、分类下钻、分享
/// 都可能指向已归类、收入、退款或别的月份的记录。
ReviewCard? _resolveTransaction(BuildContext context, String? id) {
  final session = ReviewSessionScope.of(context);
  final target = int.tryParse(id ?? '');
  if (target == null) return session.current;
  return session.cardFor(target);
}

/// 交易不存在时的解释页。
class _MissingTransaction extends StatelessWidget {
  const _MissingTransaction();

  @override
  Widget build(BuildContext context) {
    return YounumScreen(
      title: '账单详情',
      child: YounumEmptyState(
        icon: YounumIcons.search,
        title: '这笔记录已经不在了',
        description: '它可能已经被撤回导入，或者属于另一个月份。可以返回明细重新选择。',
        action: PrimaryAction(
          label: '返回明细',
          onPressed: () => context.openAsRoot(AppRoutes.root),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// detail —— 交易详情与更多操作
// -----------------------------------------------------------------------------

/// 账单详情。
class TransactionDetailScreen extends StatefulWidget {
  const TransactionDetailScreen({super.key, this.args = const TransactionDetailArgs()});

  final TransactionDetailArgs args;

  @override
  State<TransactionDetailScreen> createState() => _TransactionDetailScreenState();
}

class _TransactionDetailScreenState extends State<TransactionDetailScreen> {
  final TextEditingController _noteController = TextEditingController();

  /// 用户刚选的用途（**名字**，分类选择页返回的就是名字）。
  String? _pickedCategory;

  /// 进页时的备注与用途，用来判断「改过没有」。
  bool _initialized = false;
  String _initialNote = '';
  String? _initialCategory;

  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;

    final card = _resolveTransaction(context, widget.args.transactionId);
    if (card == null) return;
    // 已有备注要回填 —— 不回填的话，用户改一个错字会把整条备注弄丢。
    _initialNote = card.transaction.note ?? '';
    _noteController.text = _initialNote;
    _initialCategory = card.categoryName;
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  bool get _categoryChanged =>
      _pickedCategory != null && _pickedCategory != _initialCategory;

  bool get _dirty =>
      _categoryChanged || _noteController.text.trim() != _initialNote.trim();

  Future<void> _save(ReviewCard card) async {
    if (_saving || !_dirty) return;

    final session = ReviewSessionScope.of(context);
    // 分类选择页给的是名字，写库要 ID。
    final categoryId = _categoryChanged
        ? session.categoryIdNamed(_pickedCategory!)
        : null;
    if (_categoryChanged && categoryId == null) {
      showYounumToast(context, '这个用途找不到对应分类，请重新选择');
      return;
    }

    final savedNote = _noteController.text;
    setState(() => _saving = true);
    final ok = await session.saveDetails(
      transactionId: card.id,
      note: savedNote,
      categoryId: categoryId,
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) {
        // 存下来之后，当前值就是新的基准，按钮重新变灰。
        _initialNote = savedNote.trim();
        _initialCategory = _pickedCategory ?? _initialCategory;
      }
    });
    showYounumToast(
      context,
      ok ? '已保存' : session.lastFailure ?? '保存失败，可以重试',
    );
  }

  @override
  Widget build(BuildContext context) {
    final transaction = _resolveTransaction(context, widget.args.transactionId);
    if (transaction == null) return const _MissingTransaction();

    final text = YounumText.of(context);
    final registry = CategoryRegistryScope.of(context);
    final savedCategory = transaction.categoryName;
    final displayCategory = _pickedCategory ?? savedCategory ?? '待确认';
    final dirty = _dirty;

    return YounumScreen(
      title: '账单详情',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Center(
            child: Column(
              children: <Widget>[
                YounumTileIcon(
                  iconKey: registry.iconKeyOf(displayCategory) ??
                      YounumIcons.defaultCategoryIconKey,
                  size: 46,
                ),
                const SizedBox(height: YounumDimens.gap),
                AmountText(cents: transaction.amountCents, scale: AmountScale.panel),
                const SizedBox(height: YounumDimens.gapSm),
                Text(transaction.merchant, style: text.listPrimary),
                const SizedBox(height: YounumDimens.gapSm),
                YounumBadge(
                  displayCategory == '待确认'
                      ? '待确认用途'
                      : '已归类 · $displayCategory',
                  tone: displayCategory == '待确认'
                      ? YounumBadgeTone.warm
                      : YounumBadgeTone.primary,
                ),
              ],
            ),
          ),
          const SizedBox(height: YounumDimens.gapLg),
          YounumPanel(
            child: Column(
              children: <Widget>[
                YounumLineInfo(label: '交易时间', value: transaction.dateText),
                YounumLineInfo(label: '支付来源', value: transaction.source),
                const YounumLineInfo(label: '交易类型', value: '商户消费'),
                const YounumLineInfo(label: '原始单号', value: '•••• 0826'),
              ],
            ),
          ),
          YounumListRow(
            title: '修改用途',
            subtitle: '选择或重新归类',
            iconKey: displayCategory == '待整理' ? 'file' : null,
            icon: displayCategory == '待整理' ? null : YounumIcons.edit,
            trailingWidget: const _Chevron(),
            onTap: () async {
              // 用 dynamic 接收再自行收窄，避免命名路由的泛型不匹配。
              final picked = await Navigator.of(context).pushNamed<dynamic>(
                AppRoutes.allCategories,
                arguments: CategoryPickArgs(
                  purpose: CategoryPickPurpose.detail,
                  currentCategory: displayCategory,
                  transactionId: '${transaction.id}',
                ),
              );
              if (picked is String && mounted) {
                setState(() => _pickedCategory = picked);
              }
            },
          ),
          YounumListRow(
            title: '拆分这笔消费',
            subtitle: '一笔金额，多个用途',
            icon: YounumIcons.split,
            trailingWidget: const _Chevron(),
            onTap: () => context.open(
              AppRoutes.splitTransaction,
              arguments: SplitArgs(transactionId: transaction.id),
            ),
          ),
          YounumListRow(
            title: '设为转账 / 收入 / 不计入',
            subtitle: '从消费统计中单独处理',
            icon: YounumIcons.link,
            trailingWidget: const _Chevron(),
            showDivider: false,
            onTap: () => context.open(
              AppRoutes.transactionNature,
              arguments: NatureArgs(transactionId: transaction.id),
            ),
          ),
          const YounumFieldLabel('给这笔花费加个备注'),
          YounumTextField(
            controller: _noteController,
            hintText: '例如：午后和朋友喝咖啡',
            onChanged: (value) => setState(() {}),
          ),
          const SizedBox(height: YounumDimens.gapLg),
          PrimaryAction(
            label: _saving ? '正在保存…' : '保存修改',
            onPressed: dirty && !_saving ? () => _save(transaction) : null,
          ),
          if (dirty)
            const YounumPillNote('有还没保存的修改。')
          else
            const YounumPillNote(
              '金额、商户与交易时间来自账单原文，不在这里改 —— '
              '改了就对不上原始账单了。要排除这一笔，用上面的「不计入」。',
            ),
        ],
      ),
    );
  }
}

class _Chevron extends StatelessWidget {
  const _Chevron();

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
// split —— 拆分一笔消费
// -----------------------------------------------------------------------------

/// 拆分一笔消费。
///
/// 硬性校验（指南 3.5）：每项金额大于 0、合计**精确等于**原始金额、
/// 同一分类不能重复。校验不过时「确认拆分」保持不可点。
///
/// 数据全部来自真实交易：原始金额、现有分配（已拆过的照原样回填）、
/// 可选分类。写库走 `ReviewSession.splitTransaction`，与「重新归类」
/// 共用同一条带版本校验与撤销日志的写路径。
class SplitScreen extends StatefulWidget {
  const SplitScreen({super.key, required this.transactionId});

  final int transactionId;

  @override
  State<SplitScreen> createState() => _SplitScreenState();
}

class _SplitScreenState extends State<SplitScreen> {
  /// null 表示还没按真实数据初始化过。
  ///
  /// 只能在这里初始化：真实数据要从会话里取，而会话在 `initState` 时
  /// 还拿不到（`InheritedWidget` 只保证 `didChangeDependencies` 之后可用）。
  List<_SplitDraft>? _items;

  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _items ??= _initialItems();
  }

  @override
  void dispose() {
    for (final item in _items ?? const <_SplitDraft>[]) {
      item.controller.dispose();
    }
    super.dispose();
  }

  /// 默认摆出**现有分配**。
  ///
  /// 已经拆过的照原样回填（改一项不用从头再输一遍）；没拆过的就是
  /// 「现有用途 + 全额」一行，用户在此基础上加一项、再改金额。
  List<_SplitDraft> _initialItems() {
    final card = ReviewSessionScope.of(context).cardFor(widget.transactionId);
    if (card == null) return <_SplitDraft>[];
    if (card.allocations.isEmpty) {
      return <_SplitDraft>[
        _SplitDraft(
          categoryId: card.category?.id,
          amountCents: card.amountCents,
        ),
      ];
    }
    return <_SplitDraft>[
      for (final allocation in card.allocations)
        _SplitDraft(
          categoryId: allocation.categoryId,
          amountCents: allocation.amountCents,
        ),
    ];
  }

  /// 解析一项金额；返回 null 表示非法（含超过两位小数）。
  int? _centsOf(_SplitDraft item) {
    final (cents, error) = Money.parseYuan(item.controller.text);
    if (error != null) return null;
    return cents;
  }

  /// 已分配合计。出现非法项时返回 null，避免把错误金额算进合计。
  int? get _allocated {
    var total = 0;
    for (final item in _items ?? const <_SplitDraft>[]) {
      final cents = _centsOf(item);
      if (cents == null) return null;
      total += cents;
    }
    return total;
  }

  bool get _allPositive =>
      (_items ?? const <_SplitDraft>[]).isNotEmpty &&
      _items!.every((item) => (_centsOf(item) ?? 0) > 0);

  /// 每项都选了用途。没选的那项提交上去只会被服务端挡回来。
  bool get _allChosen =>
      (_items ?? const <_SplitDraft>[]).every((item) => item.categoryId != null);

  /// 只有「都选了用途」「全部大于 0」且「合计精确相等」才允许提交。
  bool get _canSubmit =>
      _allChosen &&
      _allPositive &&
      _allocated == _originalCentsOfCurrent;

  /// 当前这笔的原始金额。数据没准备好时用 0，让按钮处于不可点状态。
  int get _originalCentsOfCurrent =>
      ReviewSessionScope.of(context)
          .cardFor(widget.transactionId)
          ?.amountCents ??
      0;

  Future<void> _submit() async {
    final items = _items;
    if (items == null || !_canSubmit || _saving) return;

    final drafts = <AllocationDraft>[];
    for (final item in items) {
      final categoryId = item.categoryId;
      final cents = _centsOf(item);
      if (categoryId == null || cents == null) return;
      drafts.add(AllocationDraft(categoryId: categoryId, amountCents: cents));
    }

    final session = ReviewSessionScope.of(context);
    final navigator = Navigator.of(context);
    setState(() => _saving = true);
    final ok = await session.splitTransaction(
      transactionId: widget.transactionId,
      items: drafts,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    showYounumToast(
      context,
      ok
          ? '拆分已保存，统计时按用途汇总'
          : session.lastFailure ?? '拆分没有保存成功，可以重试',
    );
    if (ok) navigator.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final session = ReviewSessionScope.of(context);
    final card = session.cardFor(widget.transactionId);
    if (card == null) return const _MissingTransaction();

    // 会话晚到时兜底：此时还没构建过表单，补一次初始化不会丢用户输入。
    _items ??= _initialItems();

    // 拆分只对消费有意义：收入、转账、退款、排除统计都不参与消费统计。
    if (card.transaction.nature != TransactionNature.expense) {
      return YounumScreen(
        title: '拆分消费',
        child: YounumEmptyState(
          icon: YounumIcons.split,
          title: '这笔不是消费，不能拆分',
          description: '拆分用于把一笔消费分到多个用途。收入、转账、退款与'
              '「排除统计」的记录不计入消费统计，因此不需要拆分。',
        ),
      );
    }

    final text = YounumText.of(context);
    final colors = YounumColors.of(context);
    final items = _items!;
    final originalCents = card.amountCents;
    final allocated = _allocated;
    final remaining = allocated == null ? null : originalCents - allocated;

    // 可选用途用**全部分类**（含细分用途与自建），按稳定 ID 存。
    final categories = session.allCategories;
    final byId = <int, Category>{
      for (final category in categories) category.id: category,
    };

    return YounumScreen(
      title: '拆分消费',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('一笔花费，多种用途', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText('${card.merchant} · ${card.dateText}'),
          const SizedBox(height: YounumDimens.gap),
          YounumPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const YounumCaptionText('原始金额'),
                const SizedBox(height: 8),
                AmountText(cents: originalCents, scale: AmountScale.panel),
              ],
            ),
          ),
          for (var index = 0; index < items.length; index++) ...<Widget>[
            YounumFieldLabel(
              '用途${_indexLabel(index)}',
              trailing: items.length > 1
                  ? YounumPressable(
                      onTap: () => setState(() {
                        items.removeAt(index).controller.dispose();
                      }),
                      semanticLabel: '删除用途${_indexLabel(index)}',
                      borderRadius: BorderRadius.circular(YounumDimens.radiusControlSmall),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                        child: Text(
                          '删除',
                          style: text.label.copyWith(color: colors.mutedColor),
                        ),
                      ),
                    )
                  : null,
            ),
            YounumSelectField<int>(
              options: <int>[for (final category in categories) category.id],
              labelBuilder: (id) => _labelOf(byId, id),
              selected: items[index].categoryId,
              placeholder: '选择用途',
              semanticLabel: '用途${_indexLabel(index)}分类',
              onSelected: (value) => setState(() => items[index].categoryId = value),
            ),
            const SizedBox(height: YounumDimens.gapSm),
            YounumTextField(
              controller: items[index].controller,
              hintText: '0.00',
              suffixText: '元',
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              onChanged: (value) => setState(() {}),
            ),
            const SizedBox(height: YounumDimens.gap),
          ],
          PrimaryAction(
            label: '增加一项用途',
            style: YounumActionStyle.secondary,
            onPressed: () => setState(
              () => items.add(_SplitDraft(categoryId: null, amountCents: 0)),
            ),
          ),
          YounumPanel(
            tone: YounumPanelTone.soft,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: <InlineSpan>[
                        TextSpan(text: '已分配 ', style: text.body),
                        TextSpan(
                          text: allocated == null
                              ? '金额格式有误'
                              : '¥${Money.format(allocated)}',
                          style: text.body.copyWith(
                            fontWeight: FontWeight.w600,
                            color: allocated == null
                                ? const Color(YounumColors.danger)
                                : colors.primaryColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                YounumBadge(
                  remaining == null
                      ? '待修正'
                      : remaining == 0
                          ? '剩余 ¥0.00'
                          : '剩余 ¥${Money.format(remaining)}',
                  tone: remaining == 0
                      ? YounumBadgeTone.primary
                      : YounumBadgeTone.warm,
                ),
              ],
            ),
          ),
          PrimaryAction(
            label: _saving ? '正在保存…' : '确认拆分',
            onPressed: _canSubmit && !_saving ? _submit : null,
          ),
          const YounumPillNote(
            '保留原始交易，统计时按拆分后的用途汇总；'
            '每项金额必须大于 0，且合计精确等于原始金额。',
          ),
        ],
      ),
    );
  }

  /// 分类展示名。
  ///
  /// 子分类要带上母类，否则只看到一个「买菜」不知道它属于哪一类。
  static String _labelOf(Map<int, Category> byId, int id) {
    final category = byId[id];
    if (category == null) return '未知分类';
    final parentId = category.parentId;
    final parent = parentId == null ? null : byId[parentId];
    return parent == null ? category.name : '${parent.name} · ${category.name}';
  }

  /// 中文序号。超过 5 项时回退到数字，避免越界。
  static String _indexLabel(int index) => index < 5
      ? const <String>['一', '二', '三', '四', '五'][index]
      : '${index + 1}';
}

class _SplitDraft {
  _SplitDraft({this.categoryId, required int amountCents})
      : controller = TextEditingController(text: _editable(amountCents));

  /// 选中的分类 ID；null 表示还没选。
  int? categoryId;

  final TextEditingController controller;

  /// 金额的可编辑文本。
  ///
  /// 0 分当作「还没填」—— 留空才能露出输入框的 0.00 提示；
  /// 而且 0 分本来就不合法（每项必须大于 0）。
  static String _editable(int cents) => cents <= 0 ? '' : Money.format(cents);
}

// -----------------------------------------------------------------------------
// nonexpense —— 转账、退款与排除统计
// -----------------------------------------------------------------------------

/// 交易性质调整。
class TransactionNatureScreen extends StatefulWidget {
  const TransactionNatureScreen({super.key, required this.transactionId});

  final int transactionId;

  @override
  State<TransactionNatureScreen> createState() => _TransactionNatureScreenState();
}

class _TransactionNatureScreenState extends State<TransactionNatureScreen> {
  /// 可选的性质。
  ///
  /// 「收到退款」与其它几种不同：它必须**同时**说清抵扣哪一笔消费（指南 3.5），
  /// 所以选中它时要多一个原消费选择器，提交后走的是「关联 + 改性质」一次写完。
  static const List<TransactionNature> _choices = <TransactionNature>[
    TransactionNature.expense,
    TransactionNature.transfer,
    TransactionNature.income,
    TransactionNature.refund,
    TransactionNature.excluded,
  ];

  static const Map<TransactionNature, String> _labels =
      <TransactionNature, String>{
    TransactionNature.expense: '普通消费',
    TransactionNature.transfer: '账户间转账',
    TransactionNature.income: '收入',
    TransactionNature.refund: '收到退款',
    TransactionNature.excluded: '暂不计入统计',
  };

  /// null 表示还没选。
  ///
  /// 导入进来的记录大多还是 `unknown`，那时不该替用户预选一个性质 ——
  /// 预选「普通消费」会让人顺手确认下去，而它其实需要先选用途。
  TransactionNature? _nature;
  bool _initialized = false;
  bool _saving = false;

  /// 选中的原消费（退款用）。
  int? _originalId;

  /// 拆分消费的退款分配草稿（指南 3.5.5）。
  ///
  /// 原消费没拆过时是空的 —— 那种情况直接抵扣它唯一的那一项。
  List<RefundAllocationDraft> _refundAllocations =
      const <RefundAllocationDraft>[];

  /// 退款分配是否已经「合计等于退款金额、单项不超自己」。
  bool _refundBalanced = false;

  /// 这笔退款当前已经关联到的原消费。
  ///
  /// 非空时这一页不再是「选一个原消费」，而是「看看现在关联到了谁」：
  /// 选择器会被预填，确认按钮灰着并指向下面的「取消退款关联」。
  RefundLink? _link;
  LedgerTransaction? _linkedOriginal;

  final TextEditingController _reasonController = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    // 已经定过性质的记录（比如退回来重看）要把当前值摆出来。
    final current = ReviewSessionScope.of(
      context,
    ).cardFor(widget.transactionId)?.transaction.nature;
    if (current != null && _choices.contains(current)) _nature = current;
    _loadLink();
  }

  /// 把「这笔现在关联到了谁」读出来。
  ///
  /// 直查而不是从快照里找：快照里的退款连接跟着**原消费所在月份**，
  /// 跨月时在本月根本看不到。
  Future<void> _loadLink() async {
    final session = ReviewSessionScope.of(context);
    final link = await session.refundLinkOf(widget.transactionId);
    if (link == null) return;
    final original = await session.transactionById(link.originalTransactionId);
    if (!mounted) return;
    setState(() {
      _link = link;
      _linkedOriginal = original;
      // 预填而不是留一个空选择器：空选择器会让人以为「这笔还没关联」，
      // 然后顺手选一个原消费，被「已经关联过」挡回来。
      _originalId = link.originalTransactionId;
    });
  }

  String get _linkedLabel {
    final original = _linkedOriginal;
    if (original == null) return '原消费';
    return '${original.merchant} · '
        '${StatisticsTime.formatShort(original.occurredAtMs)} · '
        '¥${Money.format(original.amountCents)}';
  }

  /// 选择器的候选：本月的消费，加上「当前关联的那一笔」。
  ///
  /// 跨月退款的原消费不在本月的消费列表里，不特意加上去的话，
  /// 预填的值会显示成「未知记录」。
  List<int> _optionsFor(List<ReviewCard> originals) {
    final ids = <int>[for (final card in originals) card.id];
    final linkedId = _link?.originalTransactionId;
    if (linkedId != null && !ids.contains(linkedId)) ids.insert(0, linkedId);
    return ids;
  }

  Future<void> _unlink() async {
    final session = ReviewSessionScope.of(context);
    final navigator = Navigator.of(context);

    final confirmed = await showConfirmSheet(
      context: context,
      title: '取消退款关联？',
      description:
          '这笔记录会回到待整理，$_linkedLabel 的月报净消费会变回去，'
          '退款金额不会再被抵扣。',
      confirmLabel: '取消关联',
      cancelLabel: '先不改',
    );
    if (!mounted || !confirmed) return;

    setState(() => _saving = true);
    final ok = await session.unlinkRefund(widget.transactionId);
    if (!mounted) return;
    setState(() => _saving = false);
    showYounumToast(
      context,
      ok ? '已取消关联，这笔回到待整理' : session.lastFailure ?? '没有取消成功，可以重试',
    );
    if (ok) navigator.maybePop();
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  /// 不能提交的原因。
  ///
  /// 与仓库层的校验是同一套规则：这里先说清楚，免得用户点了才被拒。
  String? _blockingReason(ReviewCard card) {
    final nature = _nature;
    if (nature == null) return '先选一个交易性质，再确认调整。';
    if (nature == TransactionNature.excluded &&
        _reasonController.text.trim().isEmpty) {
      return '排除统计需要写明原因，否则以后回看时不知道为什么不算。';
    }
    if (nature == TransactionNature.refund) {
      if (_originalId == null) {
        return '退款要关联到原消费，抵扣才算得对；确实找不到原消费时，请选「暂不计入统计」并写明原因。';
      }
      if (_link != null && _originalId == _link!.originalTransactionId) {
        return '这笔退款已经关联到「$_linkedLabel」。要改成别的原消费，请先按下面的「取消退款关联」。';
      }
      final original = ReviewSessionScope.of(context).cardFor(_originalId!);
      if (original != null && original.allocations.isEmpty) {
        return '这笔消费还没有用途，退款抵扣不到东西 —— 先给它定一个用途再关联。';
      }
      if (original != null &&
          original.allocations.length > 1 &&
          !_refundBalanced) {
        return '这笔消费拆成了多项，请说明退款分别抵扣哪几项，合计要精确等于退款金额。';
      }
    }
    if (nature == TransactionNature.expense && card.allocations.isEmpty) {
      return '作为消费统计就需要一个用途，请先用「修改用途」或「拆分」把它定下来。';
    }
    return null;
  }

  Future<void> _submit() async {
    final nature = _nature;
    if (nature == null || _saving) return;

    final session = ReviewSessionScope.of(context);
    final navigator = Navigator.of(context);
    final originalId = _originalId;
    setState(() => _saving = true);

    // 退款走的是「关联 + 改性质」一次写完，不能拆成两步。
    // 拆分过的原消费还要带上退款分配（指南 3.5.5）。
    final ok = nature == TransactionNature.refund && originalId != null
        ? await session.linkRefundAndResolve(
            refundTransactionId: widget.transactionId,
            originalTransactionId: originalId,
            allocations: _refundAllocations,
          )
        : await session.setNature(
            transactionId: widget.transactionId,
            nature: nature,
            excludeReason: nature == TransactionNature.excluded
                ? _reasonController.text
                : null,
          );

    if (!mounted) return;
    setState(() => _saving = false);
    showYounumToast(
      context,
      ok
          ? '已按「${_labels[nature]}」处理'
          : session.lastFailure ?? '没有保存成功，可以重试',
    );
    if (ok) navigator.maybePop();
  }

  /// 原消费的展示名，形如 `优衣库 · 09.23 · 14:26 · ¥299.00`。
  ///
  /// 候选里没有就是 null（跨月关联的原消费不在本月的消费列表里）。
  static String? _originalLabel(List<ReviewCard> cards, int id) {
    for (final card in cards) {
      if (card.id != id) continue;
      return '${card.merchant} · ${card.dateText} · '
          '¥${Money.format(card.amountCents)}';
    }
    return null;
  }

  /// 标签：本月候选里能查到就用卡片，查不到就用直查到的原消费，
  /// 都查不到才说「未知记录」。
  String _labelFor(List<ReviewCard> cards, int id) =>
      _originalLabel(cards, id) ??
      (_linkedOriginal?.id == id ? _linkedLabel : '未知记录');

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final session = ReviewSessionScope.of(context);
    final card = session.cardFor(widget.transactionId);
    if (card == null) return const _MissingTransaction();

    final blocking = _blockingReason(card);

    // 可作原消费的记录：本月的消费，除了这笔本身。
    final originals = <ReviewCard>[
      for (final candidate in session.refundableOriginals)
        if (candidate.id != widget.transactionId) candidate,
    ];

    // 选中的原消费那张卡：拆分消费要用它的拆分项来填退款分配。
    final originalId = _originalId;
    final originalCard = originalId == null ? null : session.cardFor(originalId);

    return YounumScreen(
      title: '调整交易性质',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('它不一定是一笔消费', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText('确认交易性质，让月报更准确。'),
          const SizedBox(height: YounumDimens.gapLg),
          YounumPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(card.merchant, style: text.listPrimary),
                const SizedBox(height: 6),
                YounumCaptionText(
                  '${card.dateText} · ¥${Money.format(card.amountCents)}',
                ),
              ],
            ),
          ),
          YounumPanel(
            child: YounumRadioGroup<TransactionNature>(
              options: _choices,
              selected: _nature,
              labelBuilder: (nature) => _labels[nature] ?? '—',
              groupLabel: '交易性质',
              onSelected: (value) => setState(() => _nature = value),
            ),
          ),
          if (_nature == TransactionNature.refund) ...<Widget>[
            const YounumFieldLabel('抵扣哪一笔消费'),
            YounumSelectField<int>(
              options: _optionsFor(originals),
              labelBuilder: (id) => _labelFor(originals, id),
              selected: _originalId,
              placeholder: '选择原消费',
              semanticLabel: '原消费',
              onSelected: (value) => setState(() {
                _originalId = value;
                // 草稿属于之前那一笔的拆分项，换一笔就要重新填。
                _refundAllocations = const <RefundAllocationDraft>[];
                _refundBalanced = false;
              }),
            ),
            if (originals.isEmpty)
              const YounumPillNote(
                '这个月还没有能作为原消费的记录。找不到原消费时，'
                '请选「暂不计入统计」并写明原因。',
              ),
            // 拆分过的消费：退款要说明抵扣到哪几项（指南 3.5.5）。
            if (originalCard != null && originalCard.allocations.length > 1)
              ...<Widget>[
                const SizedBox(height: YounumDimens.gapSm),
                RefundAllocationEditor(
                  key: ValueKey<int>(originalCard.id),
                  card: originalCard,
                  refundCents: card.amountCents,
                  onChanged: (drafts, balanced) => setState(() {
                    _refundAllocations = drafts;
                    _refundBalanced = balanced;
                  }),
                ),
              ],
            if (_link != null) ...<Widget>[
              const SizedBox(height: YounumDimens.gapSm),
              YounumPanel(
                padding: EdgeInsets.zero,
                child: YounumListRow(
                  title: '取消退款关联',
                  subtitle: '这笔回到待整理，原消费的月报净消费变回去',
                  icon: YounumIcons.link,
                  trailingWidget: const _Chevron(),
                  onTap: _unlink,
                ),
              ),
            ],
          ],
          if (_nature == TransactionNature.excluded) ...<Widget>[
            const YounumFieldLabel('不计入统计的原因'),
            YounumTextField(
              controller: _reasonController,
              hintText: '例如：这是朋友还我的钱',
              onChanged: (value) => setState(() {}),
            ),
          ],
          const YounumNotice(
            '标成转账或收入后，这笔不再计入消费，也不出现在分类占比里。\n'
            '退款会抵扣你选中的那一笔消费，月度净消费相应减少。',
          ),
          if (blocking != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: YounumCaptionText(
                blocking,
                style: TextStyle(color: YounumColors.of(context).primaryColor),
              ),
            ),
          PrimaryAction(
            label: _saving ? '正在保存…' : '确认调整',
            onPressed: blocking == null && !_saving ? _submit : null,
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// pending —— 稍后处理 · 待确认清单
// -----------------------------------------------------------------------------

/// 稍后队列。
class PendingQueueScreen extends StatelessWidget {
  const PendingQueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final session = ReviewSessionScope.of(context);
    final items = session.deferred;

    return YounumScreen(
      title: '稍后处理',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text('不着急，再想一想', style: text.screenTitle),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText(
            items.isEmpty
                ? '当前没有放在稍后处理的记录。'
                : '${items.length} 笔花费还没有找到归属。',
          ),
          const SizedBox(height: YounumDimens.gap),
          if (items.isEmpty)
            const YounumEmptyState(
              icon: YounumIcons.clock,
              title: '稍后队列是空的',
              description: '在卡片上左滑，或点「稍后处理」，记录会来到这个清单。',
            )
          else
            YounumPanel(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: <Widget>[
                  for (var index = 0; index < items.length; index++)
                    YounumListRow(
                      title: items[index].merchant,
                      subtitle: items[index].dateText,
                      iconKey: 'clock',
                      trailingText:
                          '¥${Money.format(items[index].amountCents, grouped: true)}',
                      showDivider: index != items.length - 1,
                    ),
                ],
              ),
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
                        YounumIcons.categoryIcon('leaf'),
                        size: YounumDimens.iconMd,
                        color: YounumColors.of(context).primaryColor,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text('给记忆一点提示', style: text.sectionTitle)),
                  ],
                ),
                const SizedBox(height: YounumDimens.gapSm),
                const YounumMutedText(
                  '回看交易时间、商户名称或原平台记录。确实想不起来，'
                  '可以在卡片上主动选择「其他」，系统不会替你决定。',
                ),
              ],
            ),
          ),
          if (items.isNotEmpty)
            PrimaryAction(
              label: '重新整理这些账单',
              onPressed: () {
                session.resumeDeferred();
                context.selectTab(1);
                showYounumToast(context, '已放回整理队列');
              },
            ),
          const SizedBox(height: YounumDimens.gap),
          PrimaryAction(
            label: '先保存，稍后再来',
            style: YounumActionStyle.secondary,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// complete —— 整理完成
// -----------------------------------------------------------------------------

/// 整理完成。
///
/// 只在**没有待处理记录**时出现，并且必须说明范围是否完整（指南 3.4 / 5）。
/// 还有待整理时不会展示完成态。
class ReviewCompleteScreen extends StatefulWidget {
  const ReviewCompleteScreen({super.key});

  @override
  State<ReviewCompleteScreen> createState() => _ReviewCompleteScreenState();
}

class _ReviewCompleteScreenState extends State<ReviewCompleteScreen> {
  @override
  Widget build(BuildContext context) {
    final text = YounumText.of(context);
    final session = ReviewSessionScope.of(context);

    if (!session.isComplete) {      return YounumScreen(
        title: '整理完成',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            YounumPanel(
              tone: YounumPanelTone.soft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('还不能生成完整月报', style: text.screenTitle),
                  const SizedBox(height: YounumDimens.gapSm),
                  YounumMutedText(
                    '还有 ${session.remainingCount} 笔记录没有处理完。'
                    '跳过不代表完成，全部确认后才会出现完整概况。',
                  ),
                  const SizedBox(height: YounumDimens.gap),
                  PrimaryAction(
                    label: '继续整理',
                    trailingArrow: true,
                    onPressed: () => context.selectTab(1),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final categoryCount =
        session.done.map((entry) => entry.category).toSet().length;

    return YounumScreen(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SizedBox(height: YounumDimens.gapXl),
          const Center(
            child: YounumCircleSymbol(
              icon: Icons.check,
              diameter: 104,
              borderWidth: 9,
            ),
          ),
          const SizedBox(height: YounumDimens.gapXl),
          Text(
            'EVERY PENNY HAS A PLACE',
            textAlign: TextAlign.center,
            style: text.eyebrow,
          ),
          const SizedBox(height: YounumDimens.gap),
          Text(
            '这个月，理清了。',
            textAlign: TextAlign.center,
            style: text.screenTitle.copyWith(fontSize: 28),
          ),
          const SizedBox(height: YounumDimens.gapSm),
          YounumMutedText(
            '${session.doneCount} 笔花费，都有了自己的位置。\n谢谢你，认真对待每一份生活。',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: YounumDimens.gapLg),
          YounumPanel(
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    children: <Widget>[
                      YounumCaptionText('已整理'),
                      const SizedBox(height: 6),
                      Text('${session.doneCount} 笔', style: text.statNumber),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    children: <Widget>[
                      YounumCaptionText('消费用途'),
                      const SizedBox(height: 6),
                      Text('$categoryCount 类', style: text.statNumber),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // 范围完整性由用户确认，不自动判定。
          //
          // 月份必须取自会话，不能写死：用户可以切到别的月份再来完成页，
          // 写死「9 月」会让这句确认词与实际确认的月份对不上。
          YounumCheckRow(
            label: '我确认${session.month?.shortLabel ?? '当月'}账单范围完整'
                '（含月初到月末的全部记录）',
            value: session.coverageConfirmed,
            onChanged: session.confirmCoverage,
          ),
          const YounumPillNote(
            '未确认范围完整时，概况页会标注「截至某日 / 部分账单」，'
            '不会冒充完整月报。',
          ),
          PrimaryAction(
            label: '看看我的月度消费',
            trailingArrow: true,
            onPressed: () => context.selectTab(2),
          ),
          const SizedBox(height: YounumDimens.gap),
          PrimaryAction(
            label: '先检查一下账单',
            style: YounumActionStyle.plain,
            onPressed: () => context.open(AppRoutes.transactions),
          ),
        ],
      ),
    );
  }
}
