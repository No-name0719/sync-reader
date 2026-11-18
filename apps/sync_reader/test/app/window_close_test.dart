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

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
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

  group('窗口状态：最小化矩形不得被存下/读回（v1.4.5）', () {
    // 实测（用户「打开软件没显示」）：窗口最小化后关闭，Windows 报的 bounds
    // 是「最小化矩形」159×37 @ (-25600, -25600)；它被原样存进
    // window_state.json → 下次启动窗口恢复到屏幕外 → 界面看不见。
    const minimizedRect = WindowState(
      width: 159.2,
      height: 37.6,
      left: -25600,
      top: -25600,
    );

    test('最小化时：不持久化（保留上一次存下的好状态）', () {
      expect(
        shouldPersistWindowState(minimizedRect, isMinimized: true),
        isFalse,
        reason: '最小化矩形存下去＝下次启动窗口在屏幕外',
      );
    });

    test('最小化矩形即便没标记最小化也不可用（尺寸小于最小尺寸）', () {
      expect(minimizedRect.isUsable, isFalse);
      expect(
        shouldPersistWindowState(minimizedRect, isMinimized: false),
        isFalse,
      );
    });

    test('正常窗口：可持久化、可用', () {
      const normal = WindowState(
        width: 1200,
        height: 800,
        left: 100,
        top: 80,
      );
      expect(normal.isUsable, isTrue);
      expect(shouldPersistWindowState(normal, isMinimized: false), isTrue);
    });

    test('负坐标的合法窗口（副屏在左侧）仍可用——位置不作废据', () {
      const offLeft = WindowState(
        width: 1200,
        height: 800,
        left: -1920,
        top: 100,
      );
      expect(
        offLeft.isUsable,
        isTrue,
        reason: '多屏布局里窗口合法落在负坐标，不能一刀切作废',
      );
    });

    test('从 JSON 读回：最小化矩形被识别为不可用', () {
      final state = WindowState.fromJson(const {
        'width': 159.20000000000073,
        'height': 37.599999999998545,
        'left': -25600.0,
        'top': -25600.0,
      });
      expect(state, isNotNull);
      expect(state!.isUsable, isFalse);
    });

    test('落盘：最小化时不写文件（保留上一次存下的好状态）', () async {
      final dir = await Directory.systemTemp.createTemp('sr_window_state');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {
          // 清理失败不阻塞测试
        }
      });
      final file = File(p.join(dir.path, 'window_state.json'));
      const good = '{"width":1200.0,"height":800.0,"left":424.0,"top":176.0}';
      await file.writeAsString(good);

      final written = await writeWindowState(
        file: file,
        state: minimizedRect,
        isMinimized: true,
      );

      expect(written, isFalse, reason: '最小化矩形不得被写下去');
      expect(
        await file.readAsString(),
        good,
        reason: '不写时必须保留原内容（不能清空成空文件）',
      );
    });

    test('落盘：正常窗口写入新状态', () async {
      final dir = await Directory.systemTemp.createTemp('sr_window_state');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {
          // 清理失败不阻塞测试
        }
      });
      final file = File(p.join(dir.path, 'window_state.json'));
      const normal = WindowState(
        width: 1200,
        height: 800,
        left: 424,
        top: 176,
      );

      final written = await writeWindowState(
        file: file,
        state: normal,
        isMinimized: false,
      );

      expect(written, isTrue);
      final back = WindowState.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, Object?>,
      );
      expect(back!.width, 1200);
      expect(back.left, 424);
    });
  });
}
