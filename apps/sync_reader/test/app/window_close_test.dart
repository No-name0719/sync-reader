/// Windows 关闭流程测试（v1.3.2 性能优化：点关闭按钮要**立即**关窗）。
///
/// 缺陷背景（用户实测「windows 点击关闭按钮后需要 10–20s 页面才关闭」）：
/// 旧实现 `onWindowClose` 里 `await windowManager.destroy()`——而
/// window_manager 0.5.2 在 Windows 上的 `destroy` 只发 `PostQuitMessage(0)`、
/// **不销毁窗口**（`windows/window_manager.cpp:232`）→ 窗口要等整个引擎收尾
/// 才消失（实测 11–14s）。
///
/// 本测试钉死关闭序列的契约：
/// 1. 顺序：先落盘窗口状态 → 再解除 preventClose → 最后原生关窗；
/// 2. 落盘失败**也必须关窗**（不能把用户卡在「关不掉」）；
/// 3. 落盘失败要被上报（可诊断）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/app/window.dart';

void main() {
  test('关闭序列：先落盘 → 解除 preventClose → 原生关窗', () async {
    final steps = <String>[];

    await runCloseSequence(
      save: () async => steps.add('save'),
      clearPreventClose: () async => steps.add('clearPreventClose'),
      closeWindow: () async => steps.add('closeWindow'),
    );

    expect(steps, [
      'save',
      'clearPreventClose',
      'closeWindow',
    ], reason: '必须先落盘（窗口消失前拿到 bounds）再关窗');
  });

  test('关闭序列：落盘失败也要关窗（不能把用户卡死）', () async {
    final steps = <String>[];
    Object? reported;

    await runCloseSequence(
      save: () async => throw StateError('磁盘只读'),
      clearPreventClose: () async => steps.add('clearPreventClose'),
      closeWindow: () async => steps.add('closeWindow'),
      onError: (error, stackTrace) => reported = error,
    );

    expect(steps, ['clearPreventClose', 'closeWindow']);
    expect(reported, isA<StateError>(), reason: '落盘失败要被上报（可诊断）');
  });

  test('关闭序列：关窗本身抛错时异常向上抛（不吞）', () async {
    await expectLater(
      runCloseSequence(
        save: () async {},
        clearPreventClose: () async {},
        closeWindow: () async => throw StateError('close failed'),
      ),
      throwsA(isA<StateError>()),
    );
  });
}
