/// 桌面端键盘翻页判定测试（reader_key_action.dart）。
///
/// 契约：
/// 1. ↑/←/PageUp = 上一页，↓/→/PageDown/空格 = 下一页；
/// 2. **自动重复（[KeyRepeatEvent]）不翻页**——按住方向键时系统连发重复
///    事件，逐个翻页的表现是「按下后一直翻页停不下来」（实测一屏内翻过
///    几十页，插图页夹在中间根本停不住）；
/// 3. 非翻页键不消费（交回默认行为，如 Slider 的方向键调整）。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/reader_key_action.dart';

/// 构造一次按键按下事件。
KeyDownEvent down(LogicalKeyboardKey key) => KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: key,
      timeStamp: Duration.zero,
    );

/// 构造一次按键**自动重复**事件（按住不放时系统连发）。
KeyRepeatEvent repeat(LogicalKeyboardKey key) => KeyRepeatEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: key,
      timeStamp: Duration.zero,
    );

void main() {
  test('翻页键按下 → 翻一页', () {
    expect(
      readerKeyAction(down(LogicalKeyboardKey.arrowDown)),
      ReaderKeyAction.turnNext,
    );
    expect(
      readerKeyAction(down(LogicalKeyboardKey.arrowRight)),
      ReaderKeyAction.turnNext,
    );
    expect(
      readerKeyAction(down(LogicalKeyboardKey.pageDown)),
      ReaderKeyAction.turnNext,
    );
    expect(
      readerKeyAction(down(LogicalKeyboardKey.space)),
      ReaderKeyAction.turnNext,
    );
    expect(
      readerKeyAction(down(LogicalKeyboardKey.arrowUp)),
      ReaderKeyAction.turnPrevious,
    );
    expect(
      readerKeyAction(down(LogicalKeyboardKey.arrowLeft)),
      ReaderKeyAction.turnPrevious,
    );
    expect(
      readerKeyAction(down(LogicalKeyboardKey.pageUp)),
      ReaderKeyAction.turnPrevious,
    );
  });

  test('自动重复：吃掉但不翻页（按住不放不再连翻）', () {
    for (final key in [
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.pageDown,
      LogicalKeyboardKey.pageUp,
      LogicalKeyboardKey.space,
    ]) {
      expect(
        readerKeyAction(repeat(key)),
        ReaderKeyAction.swallow,
        reason: '$key 的自动重复不应再翻页',
      );
    }
  });

  test('非翻页键 → 不消费（交回默认行为）', () {
    expect(
      readerKeyAction(down(LogicalKeyboardKey.keyA)),
      ReaderKeyAction.ignore,
    );
    expect(
      readerKeyAction(down(LogicalKeyboardKey.escape)),
      ReaderKeyAction.ignore,
    );
    expect(
      readerKeyAction(down(LogicalKeyboardKey.tab)),
      ReaderKeyAction.ignore,
    );
  });
}
