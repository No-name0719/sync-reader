/// 进度锚点：drift progress 表与渲染器之间传递进度的统一载体（docs/05 §3.3）。
library;

import 'dart:convert';

/// 阅读进度锚点。
///
/// [locatorJson] 是 docs/05 §3.3 判别联合的 JSON 原文
/// （如 `{"type":"txt","chapterIndex":87,"charOffset":1204}`），
/// 由各格式 handler/渲染器自行编解码；契约层不理解其内部结构。
class ProgressAnchor {
  /// [hasProgress] = false 表示从未读过（restore 时直接从开头开始）。
  const ProgressAnchor({
    required this.locatorJson,
    required this.percent,
    this.hasProgress = true,
  });

  /// 无进度常量。
  static const ProgressAnchor empty = ProgressAnchor(
    locatorJson: '{}',
    percent: 0,
    hasProgress: false,
  );

  /// locator 判别联合 JSON 原文（空对象 `{}` = 无结构化坐标）。
  final String locatorJson;

  /// 全书比例 0.0–1.0（降级恢复与跨格式展示用）。
  final double percent;

  /// 是否有已保存的进度。
  final bool hasProgress;

  /// 从 drift 的 locator_json + percent 列构造。
  factory ProgressAnchor.fromRaw(String? locatorJson, double percent) =>
      ProgressAnchor(
        locatorJson: (locatorJson == null || locatorJson.isEmpty)
            ? '{}'
            : locatorJson,
        percent: percent.clamp(0.0, 1.0),
        hasProgress: locatorJson != null && locatorJson.isNotEmpty,
      );

  /// 解码 locator JSON 为 Map（损坏时返回 null，调用方走 percent 降级）。
  Map<String, Object?>? decodeLocator() {
    try {
      final decoded = jsonDecode(locatorJson);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() => 'ProgressAnchor($locatorJson, $percent)';
}

/// 恢复模式（docs/05 §3.3 恢复规则编码级定义）。
enum ReaderRestoreMode {
  /// locator 精确恢复（tocFingerprint 一致且本端支持该 locator type）。
  exact,

  /// 指纹不一致 / locator 不支持 → 降级用 percent 定位到最近章节开头。
  degradedToPercent,

  /// 无历史进度，从头开始。
  noProgress,
}

/// [ReaderController.restore] 的返回：渲染器告知上层实际如何恢复了位置。
class ReaderRestoreResult {
  const ReaderRestoreResult({required this.mode, required this.applied});

  /// 恢复模式。
  final ReaderRestoreMode mode;

  /// 实际生效的锚点（降级时 percent 保持不变、locator 为空对象）。
  final ProgressAnchor applied;
}
