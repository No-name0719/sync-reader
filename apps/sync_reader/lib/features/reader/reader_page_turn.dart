import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 分页翻页动画的**唯一规格来源**。
///
/// v1.4.4（docs/10 §9.21）：四种格式（txt / epub / md / pdf）的分页翻页
/// 必须共用同一套时长、缓动、阈值与边界反馈——「换一本书像换了个阅读器」
/// 是本轮要消灭的体验分裂。
///
/// 本文件只放**纯逻辑**（常量 + 拖拽判定）与一个边界回弹控件，不含任何
/// 格式相关代码，便于单测逐条钉死。
class ReaderPageTurnSpec {
  const ReaderPageTurnSpec._();

  /// 翻页动画时长（键盘/热区触发的整页翻、拖拽松手后的补完动画）。
  static const Duration duration = Duration(milliseconds: 280);

  /// 翻页动画缓动（整页翻与补完动画共用）。
  static const Curve curve = Curves.easeOutCubic;

  /// 跟手滑动的过阈值比例（相对视口宽度）。
  static const double thresholdRatio = 0.25;

  /// 过阈值的最小像素位移（窄视口时比例不够用）。
  static const double minThreshold = 56;

  /// 过阈值的最大像素位移（宽视口时比例过大导致难翻）。
  static const double maxThreshold = 120;

  /// 越界（首/末页继续拖）时的阻尼系数：越界位移只走 40%。
  static const double resistance = 0.4;

  /// 边界回弹的位移幅度（px）。
  static const double overscroll = 24;

  /// 一次拖拽的过阈值距离（视口宽 → 像素）。
  static double threshold(double viewportWidth) {
    final ratio = viewportWidth * thresholdRatio;
    return ratio.clamp(minThreshold, maxThreshold);
  }

  /// 越界阻尼后的有效位移（px，向右滑为正）。
  ///
  /// 越过 ±视口宽的部分按 [resistance] 衰减，并再被 [overscroll] 封顶——
  /// 拖过头也只多走一点点，不会把正文甩出去。
  static double resistedTravel(double dx, double viewportWidth) {
    if (viewportWidth <= 0) return 0;
    final limit = viewportWidth;
    final overshoot = (dx.abs() - limit).clamp(0, double.infinity);
    final damped = overshoot * resistance;
    final capped = math.min(damped, overscroll);
    final sign = dx.isNegative ? -1.0 : 1.0;
    final base = dx.abs() <= limit ? dx.abs() : limit;
    return sign * (base + capped);
  }
}

/// 一次拖拽松手后的归宿。
enum ReaderPageTurnOutcome {
  /// 未过阈值：弹回原页。
  cancel,

  /// 过阈值且向左滑：翻到下一页。
  next,

  /// 过阈值且向右滑：翻到上一页。
  previous,
}

/// 分页推移的**跟手模型**（纯逻辑，无 Widget 依赖）。
///
/// 约定：
/// - `dx` 为累计水平位移，**向右为正**（手指左滑 → dx 为负）；
/// - `progress` 为翻页进度：0 = 当前页在位，1 = 下一页完全推入，
///   -1 = 上一页完全推入；越界部分按 [ReaderPageTurnSpec.resistance] 衰减。
class ReaderPageTurnDrag {
  double _dx = 0;

  /// 累计水平位移（向右为正）。
  double get dx => _dx;

  /// 翻页进度（见类注释）。
  double progress(double viewportWidth) {
    if (viewportWidth <= 0) return 0;
    return -ReaderPageTurnSpec.resistedTravel(_dx, viewportWidth) /
        viewportWidth;
  }

  /// 重置（拖拽开始 / 翻页结束）。
  void reset() => _dx = 0;

  /// 累加一段位移。
  void update(double delta) => _dx += delta;

  /// 松手判定：按过阈值距离决定翻页方向。
  ReaderPageTurnOutcome decide(double viewportWidth) {
    final limit = ReaderPageTurnSpec.threshold(viewportWidth);
    if (_dx <= -limit) return ReaderPageTurnOutcome.next;
    if (_dx >= limit) return ReaderPageTurnOutcome.previous;
    return ReaderPageTurnOutcome.cancel;
  }
}

/// 边界回弹：翻页被首/末页挡住时的**统一反馈**。
///
/// 目标（docs/10 §9.21 §3.1）：能翻就翻，不能翻就**原地轻微回弹**，
/// 而不是无声吞掉——四种格式同一套反馈，由宿主统一播放。
///
/// 回弹曲线用半正弦（0 → 峰值 → 0），起止速度为 0，看起来像「顶住了
/// 又弹回来」而不是被弹飞。
class ReaderBoundaryBounce extends StatefulWidget {
  const ReaderBoundaryBounce({super.key, required this.child});

  final Widget child;

  @override
  State<ReaderBoundaryBounce> createState() => ReaderBoundaryBounceState();
}

class ReaderBoundaryBounceState extends State<ReaderBoundaryBounce>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: ReaderPageTurnSpec.duration,
  );

  /// 播放一次回弹。
  ///
  /// [direction] = -1 内容向左顶一下再回来（翻下一页被挡），
  /// +1 向右顶一下（翻上一页被挡）。
  void play(double direction) {
    if (direction == 0) return;
    _direction = direction;
    _controller
      ..value = 0
      ..forward();
  }

  double _direction = -1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        final offset =
            _direction * ReaderPageTurnSpec.overscroll * math.sin(math.pi * t);
        return Transform.translate(offset: Offset(offset, 0), child: child);
      },
      child: widget.child,
    );
  }
}
