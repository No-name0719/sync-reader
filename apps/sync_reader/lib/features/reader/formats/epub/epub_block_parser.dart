/// epub XHTML → 块解析器（FR-203）：把 spine 内容文件解析为顺序块列表，
/// 供分块渲染（HtmlWidget 逐块）、进度定位（blockIndex/charOffset）共用。
///
/// 每块含：kind、内联 HTML 片段（交给 HtmlWidget 渲染）、plainText
/// （纯文本，字符偏移坐标基准）、headingLevel、degraded 标记、列表标记。
///
/// 支持范围（docs/01 FR-203：常规小说类 epub；复杂排版允许降级，docs/07-R2）：
/// - p / h1–h6 / strong、b、em、i、u 等内联 / img / blockquote / ul、ol、li
///   （嵌套拉平为条目序列）/ br / hr；
/// - div / span 按段落与内联处理；section/article/aside 等容器透明展开；
/// - `<head>`/`<style>`/`<script>` 忽略；
/// - **复杂表格与浮动布局降级**：table 折叠为顺序文本（保留单元格文字，
///   块标 degraded=true）；style 含 float 的元素剥除样式并标 degraded；
/// - 解析失败（非良构 XML 等）整体降级：去标签取纯文本，单块 degraded。
///
/// 图片：[parse] 的 `resolveImage` 回调在解析期把 `<img src>` 归一化替换
/// （见 epub_images.dart），解析器本身不感知 zip 结构。
/// 纯 Dart 实现，无 Flutter 依赖。
library;

import 'package:xml/xml.dart';

/// 块类型。
enum EpubBlockKind {
  /// 普通段落（含 div 内联内容、正文裸文本）。
  paragraph,

  /// 标题（h1–h6）。
  heading,

  /// 引用块（blockquote；内部块结构拉平保留在 html 片段里）。
  quote,

  /// 列表条目（ul/ol 的 li 拉平；marker 为可视标记）。
  listItem,

  /// 图片（`<img>`，src 已在解析期替换为可渲染 src）。
  image,

  /// 主题分隔线。
  hr,

  /// 未识别元素的原样保留（如 svg、自定义标签）。
  other,
}

/// XHTML 内容文件中的一个渲染块。
class EpubBlock {
  const EpubBlock({
    required this.kind,
    required this.html,
    required this.plainText,
    this.headingLevel = 0,
    this.degraded = false,
    this.listMarker = '',
  });

  /// 块类型。
  final EpubBlockKind kind;

  /// 内联 HTML 片段（交给 HtmlWidget 渲染；heading 含 hN 标签本身，
  /// paragraph/listItem/quote 为去标签内层片段，image 为 img 标签）。
  final String html;

  /// 块纯文本（空白折叠；块内字符偏移的坐标基准）。
  final String plainText;

  /// 标题级 1–6；非 heading 块为 0。
  final int headingLevel;

  /// 复杂排版降级标记（表格/浮动布局折叠、整体解析失败）。
  final bool degraded;

  /// 列表条目标记（`•` / `1.`）；非 listItem 块为空串。
  final String listMarker;

  /// 是否有可渲染内容（空段落不入块序列）。
  bool get hasContent =>
      kind == EpubBlockKind.image ||
      kind == EpubBlockKind.hr ||
      plainText.trim().isNotEmpty ||
      html.trim().isNotEmpty;

  @override
  String toString() =>
      'EpubBlock(${kind.name}, level=$headingLevel, degraded=$degraded, '
      'len=${plainText.length}, text="${plainText.trim()}")';
}

/// 块解析器（无状态，可 const 复用）。
class EpubBlockParser {
  const EpubBlockParser();

  /// 解析一个 XHTML 内容文件为块列表。
  ///
  /// [resolveImage] 把 `<img src>` 原值映射为可渲染 src（如 data URI）；
  /// 返回 null 保持原值。
  List<EpubBlock> parse(
    String source, {
    String? Function(String src)? resolveImage,
  }) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(
        source,
        entityMapping: const XmlDefaultEntityMapping.html5(),
      );
    } on XmlException {
      return _fallbackBlocks(source);
    }

    // 图片 src 解析期归一化替换（原树为解析器私有，可安全改写）。
    if (resolveImage != null) {
      for (final img in doc.findAllElements('img')) {
        final src = img.getAttribute('src');
        if (src == null) continue;
        final resolved = resolveImage(src);
        if (resolved != null) img.setAttribute('src', resolved);
      }
    }

    final body = _findBody(doc);
    final blocks = <EpubBlock>[];
    if (body == null) {
      // 无 body：把文档根当容器展开。
      _visitContainer(doc.rootElement, blocks);
    } else {
      _visitContainer(body, blocks);
    }
    return blocks;
  }

  // ---------------------------------------------------------------------------
  // 遍历
  // ---------------------------------------------------------------------------

  void _visitContainer(XmlElement container, List<EpubBlock> out) {
    for (final node in container.children) {
      if (node is XmlText || node is XmlCDATA) {
        _addTextParagraph(node.value ?? '', out); // 文本节点与 CDATA
      } else if (node is XmlElement) {
        _visitElement(node, out);
      }
      // 注释/处理指令：跳过。
    }
  }

  void _visitElement(XmlElement el, List<EpubBlock> out) {
    final name = el.name.local.toLowerCase();
    switch (name) {
      case 'head' || 'style' || 'script' || 'title' || 'link' || 'meta':
        return;
      case 'br':
        return; // 块级 br 无独立语义（内联 br 由 html 片段保留）
      case 'hr':
        out.add(
          const EpubBlock(kind: EpubBlockKind.hr, html: '', plainText: ''),
        );
        return;
      case 'p':
        _addInnerBlock(el, EpubBlockKind.paragraph, out);
        return;
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        final level = int.parse(name.substring(1));
        _addHeading(el, level, out);
        return;
      case 'blockquote':
        _addInnerBlock(el, EpubBlockKind.quote, out);
        return;
      case 'ul' || 'ol':
        _flattenList(el, ordered: name == 'ol', depth: 0, out: out);
        return;
      case 'img':
        _addImage(el, out);
        return;
      case 'table':
        _degradeTable(el, out);
        return;
      case 'div' || 'section' || 'article' || 'main' || 'aside' || 'center':
        if (_hasBlockChild(el)) {
          _visitContainer(el, out);
        } else {
          _addInnerBlock(el, EpubBlockKind.paragraph, out);
        }
        return;
      default:
        if (_isInlineName(name)) {
          // 块位置的游离内联元素（span/a/strong…）：按段落收拢。
          _addInnerBlock(el, EpubBlockKind.paragraph, out);
          return;
        }
        out.add(
          EpubBlock(
            kind: EpubBlockKind.other,
            html: el.toXmlString(),
            plainText: collapseWhitespace(textContentOf(el)),
            degraded: _hasFloatStyle(el),
          ),
        );
        return;
    }
  }

  /// 列表拉平：li → 条目块；li 内嵌套 ul/ol 递归拉平为后续条目。
  void _flattenList(
    XmlElement list, {
    required bool ordered,
    required int depth,
    required List<EpubBlock> out,
  }) {
    var counter = 1;
    for (final node in list.children) {
      if (node is! XmlElement) continue;
      final name = node.name.local.toLowerCase();
      if (name == 'li') {
        final marker = ordered ? '${counter++}.' : (depth == 0 ? '•' : '◦');
        final innerParts = <String>[];
        final nested = <XmlElement>[];
        var text = StringBuffer();
        for (final child in node.children) {
          if (child is XmlElement) {
            final childName = child.name.local.toLowerCase();
            if (childName == 'ul' || childName == 'ol') {
              nested.add(child); // 先记下，待本条目块入列后再拉平（保持文档序）
              continue;
            }
            innerParts.add(child.toXmlString());
            text.write(textContentOf(child));
          } else if (child is XmlText || child is XmlCDATA) {
            innerParts.add(child.toXmlString());
            text.write(child.value ?? '');
          }
        }
        final innerHtml = innerParts.join();
        final plain = collapseWhitespace(text.toString());
        if (plain.isNotEmpty || innerHtml.trim().isNotEmpty) {
          out.add(
            EpubBlock(
              kind: EpubBlockKind.listItem,
              html: innerHtml,
              plainText: plain,
              listMarker: marker,
            ),
          );
        }
        for (final list in nested) {
          _flattenList(
            list,
            ordered: list.name.local.toLowerCase() == 'ol',
            depth: depth + 1,
            out: out,
          );
        }
      } else if (name == 'ul' || name == 'ol') {
        _flattenList(node, ordered: name == 'ol', depth: depth + 1, out: out);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 块构造
  // ---------------------------------------------------------------------------

  void _addTextParagraph(String value, List<EpubBlock> out) {
    final plain = collapseWhitespace(value);
    if (plain.isEmpty) return;
    out.add(
      EpubBlock(kind: EpubBlockKind.paragraph, html: '', plainText: plain),
    );
  }

  /// 以元素内层片段为 html 构造块（不含元素标签本身；标签样式由渲染容器补）。
  void _addInnerBlock(XmlElement el, EpubBlockKind kind, List<EpubBlock> out) {
    final inner = _serializeChildren(el);
    final plain = collapseWhitespace(textContentOf(el));
    final hasImg = el.findAllElements('img').isNotEmpty;
    if (plain.isEmpty && !hasImg && inner.trim().isEmpty) return;
    out.add(
      EpubBlock(
        kind: kind,
        html: inner,
        plainText: plain,
        degraded: _hasFloatStyle(el),
      ),
    );
  }

  void _addHeading(XmlElement el, int level, List<EpubBlock> out) {
    final plain = collapseWhitespace(textContentOf(el));
    if (plain.isEmpty) return;
    out.add(
      EpubBlock(
        kind: EpubBlockKind.heading,
        html: el.toXmlString(), // 保留 hN 标签：HtmlWidget 自带标题缩放
        plainText: plain,
        headingLevel: level,
        degraded: _hasFloatStyle(el),
      ),
    );
  }

  void _addImage(XmlElement el, List<EpubBlock> out) {
    final alt = el.getAttribute('alt') ?? '';
    out.add(
      EpubBlock(
        kind: EpubBlockKind.image,
        html: el.toXmlString(),
        plainText: collapseWhitespace(alt), // 图片坐标基准 = alt 文本（可空）
      ),
    );
  }

  /// 复杂表格降级：行主序折叠为顺序文本（单元格保留文字），degraded=true。
  void _degradeTable(XmlElement el, List<EpubBlock> out) {
    final rows = <String>[];
    for (final tr in el.findAllElements('tr')) {
      final cells = <String>[];
      for (final cell in tr.children) {
        if (cell is! XmlElement) continue;
        final name = cell.name.local.toLowerCase();
        if (name != 'td' && name != 'th') continue;
        final text = collapseWhitespace(textContentOf(cell));
        if (text.isNotEmpty) cells.add(text);
      }
      if (cells.isNotEmpty) rows.add(cells.join(' / '));
    }
    final plain = collapseWhitespace(rows.join('；'));
    if (plain.isEmpty) return;
    out.add(
      EpubBlock(
        kind: EpubBlockKind.paragraph,
        html: _escapeHtml(plain),
        plainText: plain,
        degraded: true,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 工具
  // ---------------------------------------------------------------------------

  /// 块级子元素判定（决定 div 是容器还是段落）。
  static const _blockNames = {
    'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'div', 'ul', 'ol', 'li', //
    'table', 'tr', 'td', 'th', 'blockquote', 'hr', 'pre', 'section',
    'article', 'aside', 'main', 'figure', 'figcaption', 'dl', 'dt', 'dd',
    'form', 'fieldset',
  };

  static const _inlineNames = {
    'span',
    'a',
    'strong',
    'b',
    'em',
    'i',
    'u',
    's',
    'small',
    'sub',
    'sup',
    'code',
    'q',
    'cite',
    'abbr',
    'time',
    'mark',
    'ruby',
    'rt',
    'rp',
    'font',
    'big',
    'tt',
    'kbd',
    'samp',
    'var',
    'label',
    'img',
    'br',
  };

  static bool _isInlineName(String name) => _inlineNames.contains(name);

  static bool _hasBlockChild(XmlElement el) => el.children.any(
    (node) =>
        node is XmlElement &&
        _blockNames.contains(node.name.local.toLowerCase()),
  );

  /// 浮动布局探测：style 属性含 float（降级渲染，剥样式交给容器）。
  static bool _hasFloatStyle(XmlElement el) {
    final style = el.getAttribute('style')?.toLowerCase();
    return style != null && RegExp(r'float\s*:').hasMatch(style);
  }

  /// 元素内层片段序列化（不含元素标签；文本/子元素逐一序列化）。
  static String _serializeChildren(XmlElement el) =>
      el.children.map((node) => node.toXmlString()).join();

  /// 递归取元素文本（含内层所有文本节点）。
  static String textContentOf(XmlNode node) {
    final buffer = StringBuffer();
    void walk(XmlNode n) {
      if (n is XmlText || n is XmlCDATA) {
        buffer.write(n.value ?? '');
        return;
      }
      if (n is XmlElement) {
        for (final child in n.children) {
          walk(child);
        }
      }
    }

    walk(node);
    return buffer.toString();
  }

  /// 空白折叠（含换行/制表；nbsp 保留原字符参与偏移计数）。
  static String collapseWhitespace(String value) =>
      value.replaceAll(RegExp(r'[\t\n\r ]+'), ' ').trim();

  static String _escapeHtml(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// 找 body 元素（命名空间无关）。
  XmlElement? _findBody(XmlDocument doc) {
    for (final el in doc.descendantElements) {
      if (el.name.local.toLowerCase() == 'body') return el;
    }
    return null;
  }

  /// 解析失败兜底：去标签取纯文本，单块 degraded（书不至于打不开）。
  static List<EpubBlock> _fallbackBlocks(String source) {
    var text = source.replaceAll(RegExp(r'<[^>]*>'), ' ');
    text = _decodeBasicEntities(text);
    text = collapseWhitespace(text);
    if (text.isEmpty) return const [];
    return [
      EpubBlock(
        kind: EpubBlockKind.paragraph,
        html: _escapeHtml(text),
        plainText: text,
        degraded: true,
      ),
    ];
  }

  /// 基础实体解码（&amp;/&lt;/&gt;/&quot;/&apos;/&nbsp;/数字引用）。
  static String _decodeBasicEntities(String input) => input.replaceAllMapped(
    RegExp(r'&(amp|lt|gt|quot|apos|nbsp|#x?[0-9a-fA-F]+);'),
    (m) {
      final entity = m.group(1)!;
      switch (entity) {
        case 'amp':
          return '&';
        case 'lt':
          return '<';
        case 'gt':
          return '>';
        case 'quot':
          return '"';
        case 'apos':
          return "'";
        case 'nbsp':
          return ' ';
      }
      final code = entity.startsWith('#x') || entity.startsWith('#X')
          ? int.tryParse(entity.substring(2), radix: 16)
          : int.tryParse(entity.substring(1));
      return code == null ? m.group(0)! : String.fromCharCode(code);
    },
  );
}
