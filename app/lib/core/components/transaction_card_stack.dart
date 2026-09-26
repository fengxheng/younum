import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';

import '../designsystem/younum_colors.dart';
import '../designsystem/younum_dimens.dart';
import '../designsystem/younum_text.dart';

/// 卡片手势阶段。
///
/// 与指南 14.2 的 `Idle / Dragging / Committing / Settling` 一一对应。
/// 达到阈值只是「请求提交」，事务成功之前不能把状态当作已完成。
enum CardGesturePhase { idle, dragging, committing, settling }

/// 拖动方向。
enum CardSwipeDirection { defer, confirm }

/// 堆叠卡片容器。
///
/// 手势语义（指南 14.1，**不得**改成翻页或删除）：
/// * 左滑超过阈值并松手 → 稍后处理，不增加完成数；
/// * 已选分类后右滑超过阈值 → 确认用途；
/// * 未选分类时右滑 → 回弹并提示，记录不变；
/// * 未达阈值 / 竖向滚动 / 触摸取消 → 回弹，不执行业务操作。
///
/// 提交顺序（指南 14.2）：**先完成数据事务，再完成移出与下一张展示**；
/// 失败则回到原卡并保留用户选择。
class TransactionCardStack extends StatefulWidget {
  const TransactionCardStack({
    super.key,
    required this.transactionId,
    required this.card,
    required this.selectedCategory,
    required this.onConfirm,
    required this.onDefer,
    required this.onCommitted,
    this.onRejected,
    this.enabled = true,
    this.backLayerCount = 2,
  });

  /// 当前交易的稳定 ID。手势与提交都绑定它，而不是列表下标。
  final String transactionId;

  /// 前层卡片内容。
  final Widget card;

  /// 当前已选用途。为 null 时右滑不会提交。
  final String? selectedCategory;

  /// 执行「确认用途」的数据事务，返回是否成功。
  final Future<bool> Function() onConfirm;

  /// 执行「稍后处理」的数据事务，返回是否成功。
  final Future<bool> Function() onDefer;

  /// 事务成功后推进队列（移出当前卡、露出下一张）。
  final VoidCallback onCommitted;

  /// 事务没成功时回调，调用方用来说出原因（[reason] 为 null 表示用调用方自己的原因）。
  ///
  /// **不能只回弹了事**：回弹是「什么都没发生」的样子，而用户刚才确实做了一次
  /// 操作。真机上报过「右滑没法确认」，查下去是选中的用途换不成分类 ID
  /// （见 `DECISIONS.md` 78 节）—— 那种时候必须说出原因，而不是让手势背锅。
  final void Function(String? reason)? onRejected;

  /// 队列为空时禁用。
  final bool enabled;

  /// 卡片**至少**多高：设计稿量出来的高度。
  ///
  /// 这里只给下限，不给固定高度。以前是把 236 写死，于是字号一大，卡片里的
  /// 文字就被挤出去（`RenderFlex overflowed`）—— 当时的应对是把整个 App 的
  /// 字号上限压到 1.6，等于让用户替容器的限制买单。指南 6.3 要的是
  /// 「不固定屏幕总高度，大字号时允许滚动」。
  ///
  /// 现在卡片自己撑高：设计高度当垫底，装不下就往上长（见 `build` 里的
  /// `IntrinsicHeight`），页面该滚就滚。
  static const double minCardHeight = YounumDimens.transactionCardHeight;

  /// 后层视觉卡片的数量。后层只做视觉提示，不接收输入、不参与朗读（指南 6.1）。
  final int backLayerCount;

  @override
  State<TransactionCardStack> createState() => _TransactionCardStackState();
}

class _TransactionCardStackState extends State<TransactionCardStack>
    with SingleTickerProviderStateMixin {
  /// 提交距离下限（dp）。指南 14.2：卡片宽度的 28%，限制在 72–120dp。
  static const double _minThreshold = 72;
  static const double _maxThreshold = 120;

  /// 水平 / 垂直位移比。仅当水平明显占优才锁定水平轴。
  static const double _axisRatio = 1.3;

  /// 最大旋转角。
  static const double _maxRotationDegrees = 12;

  /// 屏幕边缘避让区，留给系统返回手势。
  static const double _edgeAvoid = 20;

  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 180));

  /// 当前位移。
  ///
  /// 刻意不用 `setState`：拖动时每帧 `setState` 会重建整个 Stack 子树，
  /// 而用 [ValueNotifier] 只重建一个 `Transform`，卡片内容完全不参与 rebuild。
  /// 这是卡片拖动不掉帧的关键。
  final ValueNotifier<double> _offset = ValueNotifier<double>(0);

  /// 当前手势阶段。只有方向提示订阅它。
  final ValueNotifier<CardGesturePhase> _phase =
      ValueNotifier<CardGesturePhase>(CardGesturePhase.idle);

  double _pointerStartY = 0;
  double _startedAtX = 0;
  bool _horizontalLocked = false;

  /// 卡片区域宽度（逻辑像素）。拖动开始时量一次，
  /// 不再用 `LayoutBuilder` 在每次布局时测量。
  double _cardWidth = 0;

  /// 提交期间冻结的卡片内容。
  ///
  /// 数据事务成功后父级可能立刻换到下一张，但按指南 14.2 必须先播完移出动画。
  /// 因此这里握住「提交那一刻」的卡片，避免动画播到一半内容被替换成下一笔。
  Widget? _frozenCard;

  double get _dx => _offset.value;

  /// 卡片宽度；量不到时用一个典型值兜底（412dp 屏宽减去两侧页面留白）。
  double get _effectiveCardWidth => _cardWidth > 0 ? _cardWidth : 348;

  bool get _busy =>
      _phase.value == CardGesturePhase.committing ||
      _phase.value == CardGesturePhase.settling;

  @override
  void didUpdateWidget(TransactionCardStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换到下一张卡时清空位移，避免把上一张的手势状态带过来。
    // 提交中（_frozenCard 非空）不动，让移出动画先播完。
    if (oldWidget.transactionId != widget.transactionId &&
        _frozenCard == null &&
        !_busy) {
      _controller.stop();
      _offset.value = 0;
      _phase.value = CardGesturePhase.idle;
      _horizontalLocked = false;
    }
  }

  @override
  void dispose() {
    _offset.dispose();
    _phase.dispose();
    _controller.dispose();
    super.dispose();
  }

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  /// 有效提交距离：卡片宽度的 28%，限制在 72–120dp（指南 14.2）。
  double get _threshold =>
      (_effectiveCardWidth * 0.28).clamp(_minThreshold, _maxThreshold);

  /// 触摸被系统接管、页面切换、进入后台、多指冲突时取消未提交的手势。
  void _cancelGesture() {
    if (!mounted || _busy) return;
    _horizontalLocked = false;
    if (_dx == 0) {
      _phase.value = CardGesturePhase.idle;
      return;
    }
    _springBack();
  }

  void _onDragStart(DragStartDetails details) {
    if (_busy || !widget.enabled) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final localX = box.globalToLocal(details.globalPosition).dx;
    // 系统边缘返回优先，避让区不启动滑卡。
    if (localX < _edgeAvoid || localX > box.size.width - _edgeAvoid) return;

    _cardWidth = box.size.width;
    _pointerStartY = details.globalPosition.dy;
    _startedAtX = details.globalPosition.dx;
    _horizontalLocked = false;
    _phase.value = CardGesturePhase.dragging;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_phase.value != CardGesturePhase.dragging) return;
    if (!_horizontalLocked) {
      // 纵向位移明显更大时放弃本次手势，交回父级滚动。
      final vertical = (details.globalPosition.dy - _pointerStartY).abs();
      final horizontal = (details.globalPosition.dx - _startedAtX).abs();
      if (vertical > 0 &&
          vertical > horizontal / _axisRatio &&
          vertical > kTouchSlop) {
        _cancelGesture();
        return;
      }
      if (horizontal < kTouchSlop) return;
      _horizontalLocked = true;
    }
    // 只写 ValueNotifier：不触发本 State 的 rebuild。
    _offset.value += details.delta.dx;
  }

  void _onDragEnd(DragEndDetails details) {
    if (_phase.value != CardGesturePhase.dragging) return;
    // 首版不用瞬时速度单独触发，只按距离判定（指南 14.2）。
    if (_dx.abs() < _threshold) {
      _springBack();
      return;
    }
    _requestCommit(
      _dx < 0 ? CardSwipeDirection.defer : CardSwipeDirection.confirm,
    );
  }

  Future<void> _animateTo(double target) async {
    if (!mounted) return;
    if (_reduceMotion) {
      // 减少动画时业务顺序不变，只是不做过渡（指南 14.2）。
      _offset.value = target;
      return;
    }
    final tween = Tween<double>(begin: _dx, end: target).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    // 直接把值推给 ValueNotifier，不触发 setState。
    void onTick() => _offset.value = tween.value;
    tween.addListener(onTick);
    try {
      await _controller.forward(from: 0);
    } finally {
      tween.removeListener(onTick);
    }
  }

  Future<void> _springBack() async {
    _phase.value = CardGesturePhase.settling;
    await _animateTo(0);
    if (!mounted) return;
    _offset.value = 0;
    _phase.value = CardGesturePhase.idle;
  }

  /// 请求提交。达到阈值仅代表请求，真正的成功来自数据事务。
  Future<void> _requestCommit(CardSwipeDirection direction) async {
    if (_busy || !widget.enabled) return;
    final transactionId = widget.transactionId;

    if (direction == CardSwipeDirection.confirm && widget.selectedCategory == null) {
      await _springBack();
      // 文档里写的就是「回弹**并提示**」：没选用途时右滑不是错误，
      // 但什么也不说会让人以为手势坏了。
      widget.onRejected?.call('先选一个用途，再右滑确认');
      return;
    }
    _phase.value = CardGesturePhase.committing;
    // 冻结当前卡片：事务成功后父级会立刻换数据，但动画必须先把这一张移出去。
    // `_frozenCard` 是普通字段，变化后需要一次重建 —— 只在提交时发生，不是每帧。
    _frozenCard = widget.card;
    setState(() {});

    bool ok;
    try {
      ok = direction == CardSwipeDirection.defer
          ? await widget.onDefer()
          : await widget.onConfirm();
    } catch (_) {
      ok = false;
    }

    if (!mounted || widget.transactionId != transactionId) {
      _frozenCard = null;
      return;
    }

    if (!ok) {
      // 保存失败：卡片回到原位，用户已选的用途保持不变，可重试。
      _frozenCard = null;
      setState(() {});
      await _springBack();
      // 回弹之后再说原因 —— 先说完原因再回弹会显得界面没跟上手势。
      widget.onRejected?.call(null);
      return;
    }

    // 事务已成功，此时才做移出动画。
    _phase.value = CardGesturePhase.settling;
    final offscreen = (_effectiveCardWidth + 80) *
        (direction == CardSwipeDirection.confirm ? 1 : -1) *
        2;
    await _animateTo(offscreen);
    if (!mounted) return;
    // 动画结束才允许清空位移并推进队列。
    _frozenCard = null;
    _offset.value = 0;
    _phase.value = CardGesturePhase.idle;
    setState(() {});
    widget.onCommitted();
  }

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    const reserve = YounumDimens.stackSwingReserve;
    const farInset = YounumDimens.stackBackLayerInsetFar;
    const nearInset = YounumDimens.stackBackLayerInsetNear;
    const farAngle =
        -YounumDimens.stackBackLayerAngleFar * 3.141592653589793 / 180;
    const nearAngle =
        YounumDimens.stackBackLayerAngleNear * 3.141592653589793 / 180;

    return Padding(
      // 上下各留 reserve：后层卡片旋转后包围盒会变高，
      // 不留出这段空间它就会向上压到整理进度条上。
      padding: const EdgeInsets.symmetric(vertical: reserve),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _onDragStart,
        onHorizontalDragUpdate: _onDragUpdate,
        onHorizontalDragEnd: _onDragEnd,
        onHorizontalDragCancel: _cancelGesture,
        child: Stack(
          children: <Widget>[
            // 后层卡片：纯装饰，不接收输入、不进无障碍树。
            //
            // 用 `Positioned.fill` 而不是写死高度：层高由前层卡片决定，
            // 字号放大时后层跟着一起长，不会露出半截。
            if (widget.backLayerCount > 1)
              Positioned.fill(
                left: farInset,
                right: farInset,
                child: ExcludeSemantics(
                  child: IgnorePointer(
                    child: Transform.rotate(
                      angle: farAngle,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.tintColor,
                          border: Border.all(color: colors.borderColor),
                          borderRadius:
                              BorderRadius.circular(YounumDimens.radiusCard),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (widget.backLayerCount > 0)
              Positioned.fill(
                left: nearInset,
                right: nearInset,
                child: ExcludeSemantics(
                  child: IgnorePointer(
                    child: Transform.rotate(
                      angle: nearAngle,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.softColor,
                          border: Border.all(color: colors.borderColor),
                          borderRadius:
                              BorderRadius.circular(YounumDimens.radiusCard),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            // 前层卡片：只有它接收输入，也**由它决定整个栈的高度**。
            //
            // `IntrinsicHeight` 先问卡片「装下这些内容最少要多高」，再把
            // 它当**下限**（设计高度也在下限里，见 `minCardHeight`）——
            // 卡片内部的弹性空白负责把分隔线与页脚推到卡片底部，与设计稿
            // 一致；字号放大到装不下时卡片就往上长，页面该滚就滚。
            //
            // 这一层不能省：它是「字号上限」和「固定高度容器」之间唯一的
            // 解 —— 有了它才敢把 `maxScaleFactor` 拿掉。
            IntrinsicHeight(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: TransactionCardStack.minCardHeight,
                ),
                child: ValueListenableBuilder<double>(
                  valueListenable: _offset,
                  // 常量 child：拖动时它完全不重建，只有外层 Transform 更新。
                  child: Stack(
                    children: <Widget>[
                      // RepaintBoundary 让卡片内容单独成层：拖动只更新变换矩阵，
                      // 不必重新栅格化卡片本身（文字、虚线、描边）。
                      RepaintBoundary(child: _frozenCard ?? widget.card),
                      Positioned(
                        top: 10,
                        left: 12,
                        right: 12,
                        child: ValueListenableBuilder<CardGesturePhase>(
                          valueListenable: _phase,
                          builder: (context, phase, _) {
                            if (phase != CardGesturePhase.dragging) {
                              return const SizedBox.shrink();
                            }
                            return ValueListenableBuilder<double>(
                              valueListenable: _offset,
                              builder: (context, dx, _) => _SwipeFeedback(
                                direction: dx < 0
                                    ? CardSwipeDirection.defer
                                    : CardSwipeDirection.confirm,
                                selectedCategory: widget.selectedCategory,
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                  builder: (context, dx, child) => Transform.translate(
                    offset: Offset(dx, 0),
                    child: Transform.rotate(
                      angle: (dx / 18).clamp(
                            -_maxRotationDegrees,
                            _maxRotationDegrees,
                          ) *
                          3.141592653589793 /
                          180,
                      child: child,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 拖动过程中的方向提示。
class _SwipeFeedback extends StatelessWidget {
  const _SwipeFeedback({required this.direction, required this.selectedCategory});

  final CardSwipeDirection direction;
  final String? selectedCategory;

  @override
  Widget build(BuildContext context) {
    final colors = YounumColors.of(context);
    final text = YounumText.of(context);
    final (String label, Color background) = switch (direction) {
      CardSwipeDirection.defer => ('← 稍后处理', const Color(0xFF806344)),
      CardSwipeDirection.confirm => (
          selectedCategory == null ? '先选择分类' : '确认 · $selectedCategory →',
          colors.primaryColor,
        ),
    };

    return ExcludeSemantics(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: text.body.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: colors.onPrimaryColor,
          ),
        ),
      ),
    );
  }
}

/// 卡片下方的固定手势说明。
///
/// 实现指南 14.1 要求「卡片下方**始终**显示这行提示」。阶段 1 走查时需求方要求
/// 不展示，优先级高于文档规则，因此当前**未挂载**到卡片页。
///
/// 保留该组件而不是删掉：手势提示属于可随时恢复的设计元素，
/// 恢复方式是在 `CardsScreen` 里把 `const SwipeGuideRow(),` 加回卡片堆叠下方。
/// 拖动过程中卡片顶部仍有实时方向反馈，按钮入口也一直存在。
class SwipeGuideRow extends StatelessWidget {
  const SwipeGuideRow({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Row(
        children: const <Widget>[
          Expanded(child: SwipeGuideText('← 左滑：稍后处理')),
          Expanded(child: SwipeGuideText('右滑：确认已选分类 →', align: TextAlign.right)),
        ],
      ),
    );
  }
}

/// 手势说明里的一小段文字，使用次级色。
class SwipeGuideText extends StatelessWidget {
  const SwipeGuideText(this.text, {super.key, this.align = TextAlign.left});

  final String text;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: align,
      style: YounumText.of(context).caption,
    );
  }
}
