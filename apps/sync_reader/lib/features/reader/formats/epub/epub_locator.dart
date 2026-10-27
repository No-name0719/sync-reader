/// epub 进度定位（docs/05 §3.3 type=epub）：
///
/// locator 判别联合：`{"type":"epub","spineIndex":N,"href":S,"blockIndex":N,"charOffset":N}`
/// - `spineIndex`/`href`：spine 条目（href 为 manifest 原样形态，OPF 相对路径；
///   跨端比较须经 [EpubPositionMath.normalizeHref] 归一化）；
/// - `blockIndex`：该 spine 内容文件内的块序号（0 起，XHTML 块化解析结果）；
/// - `charOffset`：块内字符偏移（相对块的纯文本，UTF-16 码元）。
///
/// percent 定义（文本类）：该块之前累计字符数 + 块内偏移，除以全书总字符数。
/// 纯 Dart 实现，无 Flutter 依赖。
library;

import 'dart:convert';

/// epub 目录锚点（TocEntry.anchor；目录指纹序列化的一部分——
/// `toString()` 形态冻结：`epub:spine:$spineIndex:$href`，勿改动）。
class EpubSpineAnchor {
  const EpubSpineAnchor({required this.spineIndex, required this.href});

  /// spine 序号（0 起）。
  final int spineIndex;

  /// 内容文件 href（相对 OPF 目录，可含 fragment）。
  final String href;

  /// 稳定序列化（目录指纹的一部分，勿改动格式）。
  @override
  String toString() => 'epub:spine:$spineIndex:$href';

  /// 值相等（同序号同 href 即相等；TocEntry 比对与测试断言依赖）。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EpubSpineAnchor &&
          spineIndex == other.spineIndex &&
          href == other.href;

  @override
  int get hashCode => Object.hash(spineIndex, href);

  /// 从 [toString] 形式解析（href 可含冒号）；格式不符返回 null。
  static EpubSpineAnchor? tryParse(String value) {
    final m = RegExp(
      r'^epub:spine:(\d+):(.*)$',
      dotAll: true,
    ).firstMatch(value);
    if (m == null) return null;
    return EpubSpineAnchor(
      spineIndex: int.parse(m.group(1)!),
      href: m.group(2)!,
    );
  }
}

/// 解码后的 epub locator。
class EpubLocatorData {
  const EpubLocatorData({
    required this.spineIndex,
    required this.href,
    required this.blockIndex,
    required this.charOffset,
  });

  /// spine 序号（0 起）。
  final int spineIndex;

  /// 内容文件 href（manifest 原样形态，OPF 相对路径）。
  final String href;

  /// spine 内容文件内的块序号（0 起）。
  final int blockIndex;

  /// 块内字符偏移。
  final int charOffset;

  @override
  String toString() =>
      'EpubLocatorData(spine=$spineIndex, href=$href, '
      'block=$blockIndex, off=$charOffset)';
}

/// epub locator 编解码器。
final class EpubLocatorCodec {
  EpubLocatorCodec._();

  /// locator 判别联合的 type 值。
  static const String type = 'epub';

  /// 编码为 locator JSON 原文（字段名与 sync_core 的 EpubLocator.toJson 一致）。
  static String encode({
    required int spineIndex,
    required String href,
    required int blockIndex,
    required int charOffset,
  }) => jsonEncode(<String, Object?>{
    'type': type,
    'spineIndex': spineIndex,
    'href': href,
    'blockIndex': blockIndex,
    'charOffset': charOffset,
  });

  /// 解码 locator JSON；非法（JSON 损坏 / type 不是 epub / 字段缺失或
  /// 非非负整数 / href 为空）返回 null，调用方走 percent 降级。
  static EpubLocatorData? tryDecode(String? locatorJson) {
    if (locatorJson == null || locatorJson.isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(locatorJson);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, Object?>) return null;
    if (decoded['type'] != type) return null;
    final spine = _asNonNegativeInt(decoded['spineIndex']);
    final href = decoded['href'];
    final block = _asNonNegativeInt(decoded['blockIndex']);
    final offset = _asNonNegativeInt(decoded['charOffset']);
    if (spine == null || href is! String || href.isEmpty) return null;
    if (block == null || offset == null) return null;
    return EpubLocatorData(
      spineIndex: spine,
      href: href,
      blockIndex: block,
      charOffset: offset,
    );
  }

  static int? _asNonNegativeInt(Object? value) =>
      value is int && value >= 0 ? value : null;
}

/// href 归一化与位置换算数学（纯函数）。
final class EpubPositionMath {
  EpubPositionMath._();

  /// href 归一化：去 fragment/query、URL 解码、折叠 `.`/`..` 与空段。
  ///
  /// 解析期存储形态（spine href）与恢复期比较（locator href）共用本函数，
  /// 保证 URL 编码差异（`chapter%201.xhtml` vs `chapter 1.xhtml`）与
  /// fragment 差异不影响匹配。
  static String normalizeHref(String href) {
    var h = href.trim().replaceAll('\\', '/');
    final hash = h.indexOf('#');
    if (hash >= 0) h = h.substring(0, hash);
    final query = h.indexOf('?');
    if (query >= 0) h = h.substring(0, query);
    final decoded = _tryDecodeUri(h);
    final parts = <String>[];
    for (final seg in decoded.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (parts.isNotEmpty) parts.removeLast();
        continue;
      }
      parts.add(seg);
    }
    return parts.join('/');
  }

  /// 全局字符偏移 → 块前缀和数组中的块下标（prefix[i] ≤ offset 的最后一个）。
  /// 空数组返回 -1；offset 小于首块前缀时钳位到 0。
  static int flatIndexAtCharOffset(List<int> prefixChars, int charOffset) {
    if (prefixChars.isEmpty) return -1;
    var lo = 0;
    var hi = prefixChars.length - 1;
    var result = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (prefixChars[mid] <= charOffset) {
        result = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return result;
  }

  static String _tryDecodeUri(String value) {
    try {
      return Uri.decodeFull(value);
    } on ArgumentError {
      return value;
    }
  }
}
