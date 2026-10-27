/// md 进度定位（docs/05 §3.3 type=md）：
///
/// locator 判别联合：`{"type":"md","headingIndex":n,"blockIndex":n,"charOffset":n}`
/// - `headingIndex`：可见块之前最近的标题序号（0 起；全文无标题时为 0）；
/// - `blockIndex`：可见块在块列表中的下标（精确恢复的主键）；
/// - `charOffset`：可见块的源文本起始偏移（percent 换算的字符坐标）。
///
/// percent 定义（文本类）：已读字符数 / 全文字符数 = 可见块 sourceStart / 全文长度。
/// 纯 Dart 实现，无 Flutter 依赖。
library;

import 'dart:convert';

import 'md_block_parser.dart';

/// md 目录锚点（TocEntry.anchor；同时是目录指纹序列化的一部分——
/// `toString()` 必须稳定）。
class MdHeadingAnchor {
  const MdHeadingAnchor({required this.headingIndex, this.charOffset = 0});

  /// 标题块序号（0 起，按文档中出现顺序）。
  final int headingIndex;

  /// 该标题块的源文本起始偏移（全文字符坐标；标题锚点即块首）。
  final int charOffset;

  /// 稳定字符串形式（目录指纹依赖，勿改动格式）。
  @override
  String toString() => 'md:heading:$headingIndex:$charOffset';

  /// 值相等（同序号同偏移即相等；TocEntry 比对与测试断言依赖）。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MdHeadingAnchor &&
          headingIndex == other.headingIndex &&
          charOffset == other.charOffset;

  @override
  int get hashCode => Object.hash(headingIndex, charOffset);

  /// 从 [toString] 形式解析；格式不符返回 null。
  static MdHeadingAnchor? tryParse(String value) {
    final m = RegExp(r'^md:heading:(\d+):(\d+)$').firstMatch(value);
    if (m == null) return null;
    return MdHeadingAnchor(
      headingIndex: int.parse(m.group(1)!),
      charOffset: int.parse(m.group(2)!),
    );
  }
}

/// 解码后的 md locator。
class MdLocatorData {
  const MdLocatorData({
    required this.headingIndex,
    required this.blockIndex,
    required this.charOffset,
  });

  /// 最近标题序号。
  final int headingIndex;

  /// 可见块下标。
  final int blockIndex;

  /// 可见块源文本起始偏移。
  final int charOffset;

  @override
  String toString() =>
      'MdLocatorData(h=$headingIndex, b=$blockIndex, off=$charOffset)';
}

/// md locator 编解码器。
final class MdLocator {
  MdLocator._();

  /// locator 判别联合的 type 值。
  static const String type = 'md';

  /// 编码为 locator JSON 原文。
  static String encode({
    required int headingIndex,
    required int blockIndex,
    required int charOffset,
  }) => jsonEncode(<String, Object?>{
    'type': type,
    'headingIndex': headingIndex,
    'blockIndex': blockIndex,
    'charOffset': charOffset,
  });

  /// 解码 locator JSON；非法（JSON 损坏 / type 不是 md / 字段缺失或非非负整数）
  /// 返回 null，调用方走 percent 降级。
  static MdLocatorData? tryDecode(String? locatorJson) {
    if (locatorJson == null || locatorJson.isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(locatorJson);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    if (decoded['type'] != type) return null;
    final heading = _asNonNegativeInt(decoded['headingIndex']);
    final block = _asNonNegativeInt(decoded['blockIndex']);
    final offset = _asNonNegativeInt(decoded['charOffset']);
    if (heading == null || block == null || offset == null) return null;
    return MdLocatorData(
      headingIndex: heading,
      blockIndex: block,
      charOffset: offset,
    );
  }

  static int? _asNonNegativeInt(Object? value) =>
      value is int && value >= 0 ? value : null;
}

/// 位置换算数学（块列表 ↔ 字符偏移 ↔ percent ↔ 标题序号；纯函数）。
final class MdPositionMath {
  MdPositionMath._();

  /// 字符偏移 → 块下标：sourceStart ≤ [charOffset] 的最后一个块。
  ///
  /// blocks 为空返回 -1；[charOffset] 小于首块 sourceStart 时返回 0（钳位）。
  static int blockIndexAtCharOffset(List<MdBlock> blocks, int charOffset) {
    if (blocks.isEmpty) return -1;
    var lo = 0;
    var hi = blocks.length - 1;
    var result = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (blocks[mid].sourceStart <= charOffset) {
        result = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return result;
  }

  /// percent（0.0-1.0）→ 最近块下标；blocks 为空返回 -1。
  static int blockIndexForPercent(
    List<MdBlock> blocks,
    int documentLength,
    double percent,
  ) {
    if (blocks.isEmpty) return -1;
    final clamped = percent.clamp(0.0, 1.0);
    final offset = documentLength <= 0
        ? 0
        : (clamped * documentLength).round().clamp(0, documentLength);
    return blockIndexAtCharOffset(blocks, offset);
  }

  /// 可见块（含自身）之前最近的标题序号；全文无标题返回 0（locator 契约"无则 0"）。
  static int headingIndexUpTo(List<MdBlock> blocks, int blockIndex) {
    final ordinal = _headingOrdinalOf(blocks, blockIndex);
    return ordinal < 0 ? 0 : ordinal;
  }

  /// 第 [headingOrdinal] 个标题（0 起）所在块下标；不存在返回 -1。
  static int blockIndexForHeading(List<MdBlock> blocks, int headingOrdinal) {
    if (headingOrdinal < 0) return -1;
    var ordinal = 0;
    for (var i = 0; i < blocks.length; i++) {
      if (blocks[i].type != MdBlockType.heading) continue;
      if (ordinal == headingOrdinal) return i;
      ordinal++;
    }
    return -1;
  }

  /// 某块的标题序号：本身是标题块即其序号，否则是之前最近标题的序号；
  /// 之前无标题返回 -1（与 [headingIndexUpTo] 的 0 兜底区分）。
  static int _headingOrdinalOf(List<MdBlock> blocks, int blockIndex) {
    final upper = blockIndex.clamp(0, blocks.length - 1);
    var ordinal = -1;
    for (var i = 0; i <= upper && i < blocks.length; i++) {
      if (blocks[i].type == MdBlockType.heading) ordinal++;
    }
    return ordinal;
  }
}
