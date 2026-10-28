/// 启动性能打点（NFR-05，docs/01 §4：Android 中端机冷启动到书库可交互
/// ≤ 2.5s、Windows ≤ 3s）。
///
/// 打点口径：`processStart`（main 入口）→ `windowRestored`（桌面窗口恢复
/// 完成，仅 Windows 非零）→ `firstFrame`（首帧渲染完成，即书库可交互）。
/// 同步引擎首跑在冷启动 2s 后（docs/04 §3）、封面回填 fire-and-forget，
/// 均为旁路不进入关键路径；打点用于实测核验该口径未被破坏。
///
/// 输出经 [AppLogger]（info 级），超阈值升级 warn；FR-604 导出日志落地后
/// 打点记录可随日志带走。测试可注入 [now] 与 [threshold] 精确断言。
library;

import 'dart:io' show Platform;

import 'app_logger.dart';

/// 启动打点器：记录各阶段相对 `processStart` 的耗时。
final class StartupTimer {
  /// 创建打点器。[now] 可注入用于测试；[threshold] 为"NFR-05 达标线"，
  /// 缺省按当前平台取值（Android 2.5s，其余 3s）。起点在构造时即取时钟。
  StartupTimer({DateTime Function()? now, Duration? threshold})
      : _now = now ?? DateTime.now,
        threshold = threshold ?? _defaultThreshold(),
        _start = (now ?? DateTime.now)();

  final DateTime Function() _now;

  /// 冷启动达标线；`null` 表示不评估（如测试注入 null 关闭）。
  final Duration? threshold;

  final DateTime _start;
  final Map<String, Duration> _marks = {};

  /// 打点：记录当前时刻相对启动的耗时；同名点只保留首次（取最早值）。
  void mark(String name) {
    if (_marks.containsKey(name)) return;
    _marks[name] = _now().difference(_start);
  }

  /// 各打点耗时（只读视图，键为打点名）。
  Map<String, Duration> get marks => Map.unmodifiable(_marks);

  /// 首帧打点是否超过达标线（未打点或未设阈值时为 false）。
  bool get exceeded {
    final t = threshold;
    final firstFrame = _marks[kFirstFrame];
    if (t == null || firstFrame == null) return false;
    return firstFrame > t;
  }

  /// 汇总行（如 `启动打点: processStart=0ms → firstFrame=1234ms`）。
  String summary() {
    final parts = <String>[];
    for (final entry in _marks.entries) {
      parts.add('${entry.key}=${entry.value.inMilliseconds}ms');
    }
    return '启动打点(NFR-05): ${parts.join(' → ')}'
        '${threshold == null ? '' : ' (阈值 ${threshold!.inMilliseconds}ms, ${exceeded ? "超限" : "达标"})'}';
  }

  /// 输出汇总：达标 info，超限 warn。首帧未打点时不输出（避免半程噪声）。
  void report({AppLogger? logger}) {
    if (!_marks.containsKey(kFirstFrame)) return;
    final log = logger ?? AppLogger();
    if (exceeded) {
      log.warn(summary());
    } else {
      log.info(summary());
    }
  }

  static Duration _defaultThreshold() {
    // NFR-05：Android 中端机 ≤2.5s，Windows ≤3s；其余平台按 3s 兜底。
    return Platform.isAndroid
        ? const Duration(milliseconds: 2500)
        : const Duration(seconds: 3);
  }

  /// 打点名：main 入口。
  static const kProcessStart = 'processStart';

  /// 打点名：首帧渲染完成（= 书库可交互，NFR-05 口径）。
  static const kFirstFrame = 'firstFrame';
}

/// 应用全局打点器：main.dart / app.dart / 书库页共用一份。
final startupTimer = StartupTimer();
