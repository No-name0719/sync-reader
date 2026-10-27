/// epub handler（完整基线实现）：OPF 元数据 + 封面字节 + spine 序目录 + 指纹。
///
/// 解析基于 epub_pro（epubx 的活跃分叉）。渲染由 [EpubRenderer] 承担
/// （flutter_widget_from_html 块化 + 双翻页模式）；[EpubFormatHandler] 的
/// 公开接口与 [EpubSpineAnchor] 的 toString 形态属于冻结 API——指纹算法
/// 依赖锚点序列化稳定，升级渲染器不得改变它。
library;

import 'dart:typed_data';

import 'package:epub_pro/epub_pro.dart' as epub;

import '../../contract/book_file.dart';
import '../../contract/book_renderer.dart';
import '../../contract/progress_anchor.dart';
import '../../contract/reader_settings.dart';
import '../../contract/toc_entry.dart';
import '../handler_base.dart';
import 'epub_locator.dart';
import 'epub_renderer.dart';

/// epub 目录锚点定义在 epub_locator.dart（与 locator/位置换算同域）；
/// 此处转发导出，保持本文件的原有公开 API 不变。
export 'epub_locator.dart' show EpubSpineAnchor;

/// epub 格式处理器。
class EpubFormatHandler extends FormatHandlerBase {
  @override
  String get formatId => 'epub';

  @override
  Set<String> get extensions => {'epub'};

  @override
  Future<ParsedContent> parseContent(BookFile file) async {
    final bytes = await readBytes(file);
    final book = await epub.EpubReader.readBook(bytes);

    // ---- 元数据（OPF dc:*）----
    final authors = book.authors.nonNulls
        .map((a) => a.trim())
        .where((a) => a.isNotEmpty)
        .toList();
    final author = authors.isNotEmpty
        ? authors.join(', ')
        : (book.author?.trim() ?? '');
    final title = book.title?.trim();
    final languages = book.schema?.package?.metadata?.languages ?? const [];
    final language = languages.isEmpty ? null : languages.first;
    final coverBytes = _extractCoverBytes(book);

    // ---- 目录（spine 序；标题尽量取自 NCX/NAV 章节）----
    final titleByHref = _collectChapterTitles(book.chapters);
    final manifestItems =
        book.schema?.package?.manifest?.items ??
        const <epub.EpubManifestItem>[];
    final manifestById = {
      for (final item in manifestItems)
        if (item.id != null) item.id!: item,
    };
    final spineRefs =
        book.schema?.package?.spine?.items ?? const <epub.EpubSpineItemRef>[];
    final toc = <TocEntry>[];
    var spineIndex = 0;
    for (final ref in spineRefs) {
      final item = manifestById[ref.idRef];
      final href = item?.href;
      if (href == null) continue;
      final title =
          titleByHref[href] ??
          titleByHref[href.split('/').last] ??
          _fallbackTitle(href, spineIndex);
      toc.add(
        TocEntry(
          title: title,
          level: 0,
          anchor: EpubSpineAnchor(spineIndex: spineIndex, href: href),
        ),
      );
      spineIndex++;
    }

    return ParsedContent(
      title: (title == null || title.isEmpty) ? null : title,
      author: author,
      language: language,
      coverBytes: coverBytes,
      toc: toc,
    );
  }

  /// 封面字节提取（优先显式 cover 声明，取原始字节不做二次编解码）：
  /// 1. OPF `<meta name="cover" content="<manifest-id>"/>`（epub2 惯例）；
  /// 2. manifest item `properties` 含 `cover-image`（epub3）；
  /// 3. 兜底取第一张图片。
  Uint8List? _extractCoverBytes(epub.EpubBook book) {
    final images = book.content?.images;
    if (images == null || images.isEmpty) return null;
    final metadata = book.schema?.package?.metadata;
    final manifestItems = book.schema?.package?.manifest?.items;

    // 1. epub2：<meta name="cover" content="manifest-id">
    String? coverHref;
    if (metadata != null && manifestItems != null) {
      String? coverMetaContent;
      for (final m in metadata.metaItems) {
        if (m.name?.toLowerCase() == 'cover') {
          coverMetaContent = m.content;
          break;
        }
      }
      if (coverMetaContent != null) {
        for (final item in manifestItems) {
          if (item.id?.toLowerCase() == coverMetaContent.toLowerCase()) {
            coverHref = item.href;
            break;
          }
        }
      }
      // 2. epub3：properties 含 cover-image
      coverHref ??= () {
        for (final item in manifestItems) {
          if (item.properties?.split(' ').contains('cover-image') == true) {
            return item.href;
          }
        }
        return null;
      }();
    }

    // 3. 兜底第一张图片
    final coverFile =
        (coverHref != null ? images[coverHref] : null) ?? images.values.first;
    final content = coverFile.content;
    if (content == null || content.isEmpty) return null;
    return Uint8List.fromList(content);
  }

  /// 递归收集 NCX/NAV 章节：contentFileName（含其 base 名）→ 标题。
  Map<String, String> _collectChapterTitles(List<epub.EpubChapter> chapters) {
    final map = <String, String>{};
    void walk(List<epub.EpubChapter> list) {
      for (final chapter in list) {
        final name = chapter.contentFileName;
        final title = chapter.title?.trim();
        if (name != null && title != null && title.isNotEmpty) {
          map[name] = title;
          map[name.split('/').last] = title;
        }
        walk(chapter.subChapters);
      }
    }

    walk(chapters);
    return map;
  }

  /// 无章节标题时的兜底：文件主干名（如 ch01）或"第 N 节"。
  static String _fallbackTitle(String href, int spineIndex) {
    final base = href.split('/').last.split('#').first;
    final stem = base.contains('.')
        ? base.substring(0, base.lastIndexOf('.'))
        : base;
    return stem.trim().isEmpty ? '第 ${spineIndex + 1} 节' : stem;
  }

  @override
  Future<BookRenderer> createRenderer(
    BookFile file,
    ReaderSettings settings,
    ProgressAnchor anchor,
  ) => EpubRenderer.open(file: file, settings: settings);
}
