/// 桌面端键盘翻页的判定（阅读页）。
///
/// 键位约定：↑/←/PageUp = 上一页，↓/→/PageDown/空格 = 下一页。
///
/// **自动重复不翻页**：按住方向键时系统会连发 [KeyRepeatEvent]，逐个翻页
/// 的表现是「按下后一直翻页停不下来」——一屏内飞速翻过几十页，插图页夹在
/// 中间根本停不住。现在重复事件被吃掉但不翻页：**按一次 = 翻一页**，松手
/// 即停。
///
/// 抽成独立函数是为了能脱离阅读页做单测（阅读页的按键处理是私有方法）。
library;

import 'package:flutter/services.dart';

/// 键盘事件对应的翻页动作。
enum ReaderKeyAction {
  /// 不是翻页键 → 交回默认行为（不消费）。
  ignore,

  /// 翻页键的**自动重复**事件 → 消费掉但不翻页（按住不放不再连翻）。
  swallow,

  /// 翻到下一页。
  turnNext,

  /// 翻到上一页。
  turnPrevious,
}

/// 键盘事件 → 翻页动作。
ReaderKeyAction readerKeyAction(KeyEvent event) {
  final int delta;
  switch (event.logicalKey) {
    case LogicalKeyboardKey.arrowDown:
    case LogicalKeyboardKey.arrowRight:
    case LogicalKeyboardKey.pageDown:
    case LogicalKeyboardKey.space:
      delta = 1;
    case LogicalKeyboardKey.arrowUp:
    case LogicalKeyboardKey.arrowLeft:
    case LogicalKeyboardKey.pageUp:
      delta = -1;
    default:
      return ReaderKeyAction.ignore;
  }
  // 自动重复：吃掉但不翻页（否则按住不放会一直翻）。
  if (event is KeyRepeatEvent) return ReaderKeyAction.swallow;
  return delta > 0 ? ReaderKeyAction.turnNext : ReaderKeyAction.turnPrevious;
}
