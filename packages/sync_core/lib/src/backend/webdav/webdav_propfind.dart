import 'dart:io';

import 'package:xml/xml.dart';

/// PROPFIND 207 multistatus 中单个资源的摘要属性。
///
/// `etag` 保留服务器返回的**原文**（通常带双引号，如 `"9f2c..."`），
/// 直接回填 `If-None-Match`；条件比较时用 [etagEquals] 做归一化比较。
class DavEntry {
  const DavEntry({
    required this.name,
    required this.isDir,
    this.etag,
    this.size,
    this.modified,
  });

  /// 资源名（href 末段，已 percent-decode），如 `01BOOK....json`。
  final String name;

  /// 是否为集合（目录）。
  final bool isDir;

  /// `getetag` 原文；服务器未提供时为 null。
  final String? etag;

  /// `getcontentlength`（目录为 null）。
  final int? size;

  /// `getlastmodified`（RFC 1123）解析结果。
  final DateTime? modified;

  /// 合成 etag：`synthetic-{size}-{mtimeMs}`（docs/04 §8.1 无 ETag 回退，
  /// 契约见 backend_adapter.dart 的 [BackendCapabilities.supportsEtag] 注释）。
  ///
  /// PROPFIND（getcontentlength + getlastmodified）与 GET（Content-Length +
  /// Last-Modified）两条路径都用本函数合成，保证同一文件得到同一值。
  /// 注意 RFC 1123 只有秒级精度，mtimeMs 实际为秒 ×1000。
  static String synthetic(int? size, DateTime? modified) =>
      'synthetic-${size ?? 0}-${(modified?.millisecondsSinceEpoch ?? 0)}';
}

/// 构造 PROPFIND 请求体（只取同步所需的最小属性集）。
String buildPropfindBody() =>
    '<?xml version="1.0" encoding="utf-8"?>'
    '<d:propfind xmlns:d="DAV:"><d:prop>'
    '<d:resourcetype/><d:getetag/><d:getcontentlength/>'
    '<d:getlastmodified/><d:displayname/>'
    '</d:prop></d:propfind>';

/// 解析 207 multistatus XML。
///
/// 命名空间容错（R3 联调项：不同服务器的实际前缀不一）：一律按 **local name**
/// 匹配，`d:` / `D:` / 默认命名空间（无前缀）均可；属性散落在多个
/// `<propstat>` 块时合并取值。
List<DavEntry> parseMultistatus(String xml) {
  final doc = XmlDocument.parse(xml);
  final entries = <DavEntry>[];
  for (final response in doc.descendantElements) {
    if (response.name.local != 'response') continue;
    entries.add(_parseResponse(response));
  }
  return entries;
}

DavEntry _parseResponse(XmlElement response) {
  final href = _propText(response, 'href') ?? '';
  final name = _lastSegment(href);
  // resourcetype 含 <collection/> 子元素 → 目录。
  final isDir = response.descendantElements.any(
    (e) => e.name.local == 'collection',
  );
  final etagRaw = _propText(response, 'getetag');
  final etag = (etagRaw == null || etagRaw.isEmpty) ? null : etagRaw;
  final lengthRaw = _propText(response, 'getcontentlength');
  final size = lengthRaw == null ? null : int.tryParse(lengthRaw.trim());
  final modifiedRaw = _propText(response, 'getlastmodified');
  DateTime? modified;
  if (modifiedRaw != null && modifiedRaw.isNotEmpty) {
    try {
      modified = HttpDate.parse(modifiedRaw.trim()).toUtc();
    } on FormatException {
      modified = null; // 个别服务器格式不规范：mtime 缺失，合成 etag 退化为 size
    }
  }
  return DavEntry(
    name: name,
    isDir: isDir,
    etag: etag,
    size: size,
    modified: modified,
  );
}

/// 在 response 内按 local name 找属性文本：`href` 是 response 的直接子元素，
/// getetag 等属性在 `<propstat><d:prop>` 块内（可能多块），统一扫后代元素
/// 即可两者兼容（同名嵌套在 WebDAV multistatus 中不存在）。
String? _propText(XmlElement response, String localName) {
  for (final child in response.descendantElements) {
    if (child.name.local == localName) return child.innerText;
  }
  return null;
}

/// href 末段并 percent-decode（容忍完整 URL 或纯路径两种形态）。
String _lastSegment(String href) {
  if (href.isEmpty) return '';
  final trimmed = href.endsWith('/') && href.length > 1
      ? href.substring(0, href.length - 1)
      : href;
  final uri = Uri.tryParse(trimmed);
  final segments = uri?.pathSegments ?? trimmed.split('/');
  return segments.isEmpty ? '' : segments.last;
}
