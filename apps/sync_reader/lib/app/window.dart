/// Windows 桌面窗口初始化：记忆窗口尺寸与位置（docs/03 §5 平台适配表）。
///
/// 仅 Windows 生效；状态存于应用支持目录 `window_state.json`。
/// 关闭窗口前保存当前 bounds（setPreventClose → onWindowClose → 原生关窗）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_logger.dart';

/// 窗口状态（尺寸 + 位置）。
class WindowState {
  const WindowState({
    required this.width,
    required this.height,
    required this.left,
    required this.top,
  });

  /// 从 JSON 反序列化；字段缺失/类型错误返回 null。
  static WindowState? fromJson(Map<String, Object?> json) {
    final width = json['width'];
    final height = json['height'];
    final left = json['left'];
    final top = json['top'];
    if (width is! num || height is! num || left is! num || top is! num) {
      return null;
    }
    return WindowState(
      width: width.toDouble(),
      height: height.toDouble(),
      left: left.toDouble(),
      top: top.toDouble(),
    );
  }

  final double width;
  final double height;
  final double left;
  final double top;

  Map<String, Object?> toJson() => {
    'width': width,
    'height': height,
    'left': left,
    'top': top,
  };
}

/// 初始化桌面窗口（非 Windows 直接返回）。
Future<void> initDesktopWindow() async {
  if (!Platform.isWindows) return;
  final log = AppLogger();
  try {
    await windowManager.ensureInitialized();
    final saved = await _load();
    final options = WindowOptions(
      size: Size(saved?.width ?? 1200, saved?.height ?? 800),
      center: saved == null,
      minimumSize: const Size(420, 420),
      title: 'SyncReader',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      // 恢复上次的窗口位置（WindowOptions 无 position 参数）。
      if (saved != null) {
        await windowManager.setPosition(Offset(saved.left, saved.top));
      }
      await windowManager.show();
      await windowManager.setPreventClose(true);
      windowManager.addListener(_WindowCloseSaver());
    });
  } catch (e, s) {
    log.warn('窗口初始化失败（忽略并继续启动）');
    log.error('window_manager 异常', e, s);
  }
}

Future<WindowState?> _load() async {
  try {
    final file = await _stateFile();
    if (!file.existsSync()) return null;
    final json = jsonDecode(await file.readAsString());
    return json is Map<String, Object?> ? WindowState.fromJson(json) : null;
  } catch (_) {
    return null;
  }
}

Future<File> _stateFile() async {
  final support = await getApplicationSupportDirectory();
  return File(p.join(support.path, 'window_state.json'));
}

Future<void> _save() async {
  try {
    final bounds = await windowManager.getBounds();
    final file = await _stateFile();
    await file.writeAsString(
      jsonEncode(
        WindowState(
          width: bounds.width,
          height: bounds.height,
          left: bounds.left,
          top: bounds.top,
        ).toJson(),
      ),
    );
  } catch (e) {
    debugPrint('[WARN] 保存窗口状态失败：$e');
  }
}

/// 关闭序列（**可单测**）：先落盘窗口状态 → 解除「阻止关闭」→ 原生关窗。
///
/// 顺序与语义（v1.3.2 性能优化；实测依据见 docs/10 §9.8）：
/// - **落盘在前**：窗口状态要在窗口消失前拿到（实测 ~16ms，亚秒级）；
/// - **落盘失败也要关窗**：保存失败只记日志，绝不能把用户卡在「关不掉」；
/// - **关窗走原生 close，不用 destroy**：`windowManager.destroy()` 在 Windows
///   上只发 `PostQuitMessage(0)`、**不销毁窗口**（window_manager 0.5.2
///   `windows/window_manager.cpp:232`）→ 窗口要等整个引擎收尾才消失，实测
///   11–14s（用户看到的「点了关闭按钮，窗口半天不关」）。改成解除 preventClose
///   后走原生关窗（`WM_SYSCOMMAND/SC_CLOSE`）→ 实测**窗口 136ms 消失、
///   进程 263ms 退出**。
Future<void> runCloseSequence({
  required Future<void> Function() save,
  required Future<void> Function() clearPreventClose,
  required Future<void> Function() closeWindow,
  void Function(Object error, StackTrace stackTrace)? onError,
}) async {
  try {
    await save();
  } on Object catch (error, stackTrace) {
    // 落盘失败不阻塞退出（否则用户会以为应用卡死、反复点关闭）。
    onError?.call(error, stackTrace);
  }
  await clearPreventClose();
  await closeWindow();
}

/// 关闭前保存窗口状态，然后原生关窗。
class _WindowCloseSaver with WindowListener {
  /// 防重入：原生关窗会再触发一次 WM_CLOSE（此时 preventClose 已解除）。
  bool _closing = false;

  @override
  void onWindowClose() async {
    if (_closing) return;
    _closing = true;
    final log = AppLogger();
    await runCloseSequence(
      save: _save,
      clearPreventClose: () => windowManager.setPreventClose(false),
      closeWindow: () => windowManager.close(),
      onError: (error, stackTrace) {
        log.warn('保存窗口状态失败（继续关窗）');
        log.error('window 关闭流程异常', error, stackTrace);
      },
    );
  }
}
