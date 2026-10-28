/// epub 图片引用解析（FR-203）：把内容文件内的 `<img src>` 相对路径归一化
/// 到 zip 内条目（经 OPF 目录），命中图片映射时返回
/// `data:<mime>;base64,<...>`（解析期替换，HtmlWidget 直接内嵌渲染）；
/// 未命中/外链/data URI 返回 null（保留原 src，渲染失败由错误占位兜底）。
///
/// 纯 Dart 实现，无 Flutter 依赖（便于单测）。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 按 src 解析 data URI。
///
/// - [src]：`<img src>` 属性原值（相对内容文件目录，可能 URL 编码、带 `../`）；
/// - [chapterHref]：该内容文件的 OPF 相对 href（决定相对路径基准目录）；
/// - [images]：zip 内图片条目（key = manifest href 原样形态）；
/// - [imageMimes]：同 key 的 media type（缺省时按扩展名推断）。
String? resolveEpubImageDataUri({
  required String src,
  required String chapterHref,
  required Map<String, Uint8List> images,
  required Map<String, String> imageMimes,
}) {
  final raw = src.trim();
  if (raw.isEmpty) return null;
  // data URI / 外链：保留原值（外链由渲染层自行加载，失败有错误占位）。
  if (raw.startsWith('data:')) return null;
  if (raw.startsWith('http://') || raw.startsWith('https://')) return null;

  final withoutFragment = raw.split('#').first.split('?').first;
  final decoded = _tryDecodeUri(withoutFragment);

  // 相对内容文件目录 → OPF 相对路径（折叠 `.`/`..`）。
  final baseDir = chapterHref.contains('/')
      ? chapterHref.substring(0, chapterHref.lastIndexOf('/') + 1)
      : '';
  final normalized = EpubImagePath.normalize(baseDir + decoded);

  // 命中一：key 与归一化路径/解码路径/原值直接相等。
  for (final key in {normalized, decoded, raw}) {
    final bytes = images[key];
    if (bytes != null) return _toDataUri(normalized, bytes, imageMimes[key]);
  }
  // 命中二：manifest href 带 URL 编码差异，逐条归一化后比对。
  for (final entry in images.entries) {
    if (EpubImagePath.normalize(_tryDecodeUri(entry.key)) == normalized) {
      return _toDataUri(normalized, entry.value, imageMimes[entry.key]);
    }
  }
  // 命中三：大小写不一致兜底（Windows 工具打包的 epub 中 src 与
  // manifest href 大小写常不匹配；zip 本身大小写敏感）。
  final lowerKey = normalized.toLowerCase();
  for (final entry in images.entries) {
    if (EpubImagePath.normalize(_tryDecodeUri(entry.key)).toLowerCase() ==
        lowerKey) {
      return _toDataUri(normalized, entry.value, imageMimes[entry.key]);
    }
  }
  return null;
}

/// 归一化路径工具（epub_images 与 href 归一化共用语义；路径形态专用，
/// 不做实体处理——[EpubPositionMath.normalizeHref] 面向完整 href）。
final class EpubImagePath {
  EpubImagePath._();

  /// 折叠 `.`/`..` 与空段；统一正斜杠。
  static String normalize(String path) {
    final parts = <String>[];
    for (final seg in path.replaceAll('\\', '/').split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (parts.isNotEmpty) parts.removeLast();
        continue;
      }
      parts.add(seg);
    }
    return parts.join('/');
  }
}

String? _toDataUri(String path, Uint8List bytes, String? mime) {
  if (bytes.isEmpty) return null;
  final type = (mime != null && mime.isNotEmpty) ? mime : _guessMime(path);
  return 'data:$type;base64,${base64Encode(bytes)}';
}

/// 扩展名 → mime 兜底（manifest 缺 mediaType 时）。
String _guessMime(String path) {
  final ext = path.contains('.')
      ? path.substring(path.lastIndexOf('.') + 1).toLowerCase()
      : '';
  return switch (ext) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'svg' => 'image/svg+xml',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    _ => 'application/octet-stream',
  };
}

String _tryDecodeUri(String value) {
  try {
    return Uri.decodeFull(value);
  } on ArgumentError {
    return value;
  }
}
