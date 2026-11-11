/// 阅读页控制条尺寸常量与正文区留白计算（对齐原型 `ui_prototype/reader.css`）。
///
/// 数值来源（均为原型 DOM 实测值，**改动时同步**）：
/// - `.rd-top { height: 54px }` → [kReaderTopBarHeight]；
/// - `.rd-bottom { height: 58px }`，窄视口（≤460）下为 54px →
///   [kReaderBottomBarHeight] / [kReaderBottomBarHeightNarrow]；
/// - `.rd-stage { padding: 58px 24px 60px }` → 正文区的垂直留白由
///   [readerBodyInsets] 给出：上 = 顶条高（+ 系统状态栏），下 = 底条高
///   （+ 系统导航栏）。原型的 58 ≥ 顶条 54、60 ≥ 底条 58 是**结构性保证**：
///   正文永不被控制条遮挡（Flutter 端用同一思路实现）。
///
/// 断点 [kReaderNarrowBreakpoint]（460）与原型
/// `@container vp (max-width: 460px)` 一致。
library;

import 'package:flutter/material.dart';

/// 顶部控制条高度（原型 `.rd-top`：54px）。
const double kReaderTopBarHeight = 54;

/// 底部控制条高度（桌面；原型 `.rd-bottom`：58px）。
const double kReaderBottomBarHeight = 58;

/// 底部控制条高度（窄视口 ≤460；原型 `.rd-bottom` 在该断点下为 54px）。
const double kReaderBottomBarHeightNarrow = 54;

/// 窄视口断点（原型 `@container vp (max-width: 460px)`）。
const double kReaderNarrowBreakpoint = 460;

/// 正文区垂直内缩：保证正文不被顶条/底条/系统栏遮挡。
///
/// - 上 = 顶条高 + 系统状态栏高度；
/// - 下 = 底条高（窄视口 54 / 其余 58）+ 系统导航栏高度；
/// - 左右为 0（正文列宽由渲染器按页边距与最大列宽自行居中计算）。
EdgeInsets readerBodyInsets(BuildContext context) {
  final media = MediaQuery.of(context);
  final bottomBarHeight = media.size.width <= kReaderNarrowBreakpoint
      ? kReaderBottomBarHeightNarrow
      : kReaderBottomBarHeight;
  return EdgeInsets.only(
    top: kReaderTopBarHeight + media.padding.top,
    bottom: bottomBarHeight + media.padding.bottom,
  );
}
