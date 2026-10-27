import 'dart:convert';

/// 阅读进度定位器：按格式判别的联合类型（docs/05 §3.3）。
///
/// 设计原则：记录**逻辑位置**（内容坐标），不记录物理页码/像素，
/// 天然免疫各端排版差异（docs/02 §D1.2-R2）。
///
/// 编码级恢复规则（docs/05 §3.3）：
/// 1. `tocFingerprint` 一致 → 按 locator 精确恢复；
/// 2. 指纹不一致或 `type` 本端不支持 → 降级用 `percent` 定位到最近章节开头；
/// 3. `percent` 定义见各 Handler 的 `percentOf`/`locate` 双向换算。
sealed class Locator {
  const Locator();

  /// 判别字段：`txt | epub | md | pdf | raw`。
  String get type;

  /// 从解码后的 JSON 对象构造。`type` 未知时降级为 [RawLocator]
  /// （向前兼容：旧客户端读到新格式的 locator 不得报错，docs/05 §6）。
  factory Locator.fromJson(Map<String, Object?> json) {
    switch (json['type']) {
      case 'txt':
        return TxtLocator(
          chapterIndex: _requireInt(json, 'chapterIndex'),
          charOffset: _requireInt(json, 'charOffset'),
        );
      case 'epub':
        return EpubLocator(
          spineIndex: _requireInt(json, 'spineIndex'),
          href: _requireString(json, 'href'),
          blockIndex: _requireInt(json, 'blockIndex'),
          charOffset: _requireInt(json, 'charOffset'),
        );
      case 'md':
        return MdLocator(
          headingIndex: _requireInt(json, 'headingIndex'),
          blockIndex: _requireInt(json, 'blockIndex'),
          charOffset: _requireInt(json, 'charOffset'),
        );
      case 'pdf':
        return PdfLocator(
          pageIndex: _requireInt(json, 'pageIndex'),
          yRatio: _requireDouble(json, 'yRatio'),
          readingDir: (json['readingDir'] as String?) ?? 'ltr',
        );
      case 'raw':
        return RawLocator(ratio: _requireDouble(json, 'ratio'));
      default:
        // 未知 type：按整本比例兜底（docs/02 §D2.5 第 4 条）。
        final ratio = json['ratio'];
        return RawLocator(ratio: ratio is num ? ratio.toDouble() : 0);
    }
  }

  factory Locator.fromJsonString(String source) =>
      Locator.fromJson((jsonDecode(source) as Map).cast<String, Object?>());

  Map<String, Object?> toJson();

  @override
  String toString() => jsonEncode(toJson());
}

/// txt：章节 + 章内字符偏移。
final class TxtLocator extends Locator {
  const TxtLocator({required this.chapterIndex, required this.charOffset});

  @override
  String get type => 'txt';

  final int chapterIndex;
  final int charOffset;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'chapterIndex': chapterIndex,
    'charOffset': charOffset,
  };
}

/// epub：spine 序号 + 文件 href + 块序号 + 块内字符偏移。
final class EpubLocator extends Locator {
  const EpubLocator({
    required this.spineIndex,
    required this.href,
    required this.blockIndex,
    required this.charOffset,
  });

  @override
  String get type => 'epub';

  final int spineIndex;
  final String href;
  final int blockIndex;
  final int charOffset;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'spineIndex': spineIndex,
    'href': href,
    'blockIndex': blockIndex,
    'charOffset': charOffset,
  };
}

/// md：标题块（章节）+ 块内字符偏移（相对该块源文本）。
final class MdLocator extends Locator {
  const MdLocator({
    required this.headingIndex,
    required this.blockIndex,
    required this.charOffset,
  });

  @override
  String get type => 'md';

  final int headingIndex;
  final int blockIndex;
  final int charOffset;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'headingIndex': headingIndex,
    'blockIndex': blockIndex,
    'charOffset': charOffset,
  };
}

/// pdf：页码(0-based) + 页内纵向比例 + 阅读方向提示。
final class PdfLocator extends Locator {
  const PdfLocator({
    required this.pageIndex,
    required this.yRatio,
    this.readingDir = 'ltr',
  });

  @override
  String get type => 'pdf';

  final int pageIndex;
  final double yRatio;
  final String readingDir;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'pageIndex': pageIndex,
    'yRatio': yRatio,
    'readingDir': readingDir,
  };
}

/// raw：无法结构化定位（含未来未知格式）的兜底。
final class RawLocator extends Locator {
  const RawLocator({required this.ratio});

  @override
  String get type => 'raw';

  final double ratio;

  @override
  Map<String, Object?> toJson() => {'type': type, 'ratio': ratio};
}

int _requireInt(Map<String, Object?> json, String key) {
  final v = json[key];
  if (v is int) return v;
  throw FormatException('locator.$key 必须为 int，实际: $v');
}

double _requireDouble(Map<String, Object?> json, String key) {
  final v = json[key];
  if (v is num) return v.toDouble();
  throw FormatException('locator.$key 必须为 num，实际: $v');
}

String _requireString(Map<String, Object?> json, String key) {
  final v = json[key];
  if (v is String) return v;
  throw FormatException('locator.$key 必须为 String，实际: $v');
}
