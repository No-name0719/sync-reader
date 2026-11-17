/// 阅读正文的滚动物理（滚动模式专用）。
///
/// **背景（移动端实测反馈）**：平台默认的惯性滚动在手机上「甩」一下能滑出
/// 好几屏——用户反馈「移动端直接滑动会一次性滚动很多，需要按住屏幕滑动
/// 才能控制」。阅读场景与信息流场景的需求相反：阅读要**可控**，一次甩动
/// 最多滑过一两屏，其余交给用户自己滑。
///
/// **做法**：不换仿真模型，只把**甩动速度**封顶——速度封顶后，平台自己的
/// 抛掷仿真（Android 的 spline 减速 / iOS 的回弹）算出的位移自然被限住，
/// 手感仍是平台原生的，只是「甩不远」。
///
/// 上限的换算按 Android 甩动模型（[ClampingScrollSimulation] 用的同一套
/// 公式）反解速度：位移 `d = v · 0.35 · (v / vRef)^0.7364`
/// （`vRef = friction · physicalCoeff / inflexion ≈ 2647.5`），
/// 反解得 `v = (d · vRef^k / 0.35)^(1/(1+k))`，`k = 1/(decelRate-1)`。
/// 公式与平台常量耦合——**位移上限由测试锁死**
/// （`reader_scroll_physics_test.dart`：实测甩动位移 ≤ 上限），
/// 平台模型若变，测试即红。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 阅读正文滚动物理：甩动位移封顶。
///
/// 用法：`ListView(physics: const ReaderScrollPhysics())`
/// （放在阅读正文的滚动视图上；不传则用平台默认物理）。
class ReaderScrollPhysics extends ScrollPhysics {
  const ReaderScrollPhysics({super.parent, this.maxFlingScreens = 1.2});

  /// 一次甩动最多滑过的**屏数**（1 = 一屏；视口高为基准）。
  ///
  /// 默认 1.2：一次甩动最多滑过约一屏多一点——既能「甩一下接着看」，
  /// 又不会一下飞出好几屏。
  final double maxFlingScreens;

  @override
  ReaderScrollPhysics applyTo(ScrollPhysics? ancestor) => ReaderScrollPhysics(
    parent: buildParent(ancestor),
    maxFlingScreens: maxFlingScreens,
  );

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final tolerance = toleranceFor(position);
    if (velocity.abs() < tolerance.velocity) return null;
    final capped = capFlingVelocity(
      velocity,
      maxDistance: position.viewportDimension * maxFlingScreens,
    );
    return super.createBallisticSimulation(position, capped);
  }

  /// 给定甩动速度与允许的最大位移，返回**封顶后**的速度。
  ///
  /// 按 Android 甩动模型反解（见文件头注释）：
  /// `d(v) = v · inflexion · (v / vRef)^k`——位移随速度单调递增，故可直接
  /// 反解（速度为负时按绝对值处理，方向不变）。
  static double capFlingVelocity(
    double velocity, {
    required double maxDistance,
  }) {
    if (maxDistance <= 0) return 0;
    final absVelocity = velocity.abs();
    final cappedAbs = _velocityForDistance(maxDistance);
    if (absVelocity <= cappedAbs) return velocity;
    return velocity.sign * cappedAbs;
  }

  /// Android 甩动模型的常量（与 [ClampingScrollSimulation] 同源）。
  static const double _friction = 0.015;

  /// 重力换算系数（9.80665 m/s² → 逻辑像素/秒²，含平台的 0.84 手感系数）。
  static const double _physicalCoeff = 9.80665 * 39.37 * 160.0 * 0.84;

  /// 拐点系数。
  static const double _inflexion = 0.35;

  /// 减速率（log(0.78)/log(0.9)）。
  static const double _decelerationRate = 2.358;

  /// 参考速度（`friction · physicalCoeff / inflexion`）。
  static const double _referenceVelocity =
      _friction * _physicalCoeff / _inflexion;

  /// 指数 k = 1 / (decelerationRate - 1)。
  static const double _k = 1.0 / (_decelerationRate - 1.0);

  /// 位移 `d` 对应的速度（Android 甩动模型反解）。
  static double _velocityForDistance(double distance) {
    // d = inflexion · v^(1+k) / vRef^k
    //   ⇒ v = (d · vRef^k / inflexion)^(1/(1+k))
    final inner = distance * math.pow(_referenceVelocity, _k) / _inflexion;
    return math.pow(inner, 1.0 / (1.0 + _k)).toDouble();
  }
}
