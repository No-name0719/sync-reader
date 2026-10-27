/// 格式扩展点（冻结 API，docs/03 §4.2 逐字对齐）：新格式 = 实现本接口 + 注册进
/// [FormatRegistry]。同步层只消费 formatId 字符串，与格式无关。
library;

import 'dart:typed_data';

import 'book_file.dart';
import 'book_renderer.dart';
import 'parsed_book.dart';
import 'progress_anchor.dart';
import 'reader_settings.dart';

/// 电子书格式处理器。
abstract interface class BookFormatHandler {
  /// 格式标识：'txt' | 'epub' | 'md' | 'pdf' | 未来 'mobi'...
  /// 与 books.format 列、locator 判别联合的 `type` 前缀一致。
  String get formatId;

  /// 是否能处理该扩展名。[magicHeader] 为文件头部字节（基线仅按 [ext] 判断；
  /// 留参以便未来做魔数嗅探，传入空字节时不得误判为不支持）。
  bool canHandle(String ext, Uint8List magicHeader);

  /// 解析书籍静态元数据：书名/作者/TOC/语言/封面（FR-102）。
  ///
  /// 实现约定：**解析失败不得抛出**——降级为文件名元数据 + 空 toc，
  /// 保证导入流程永不因单本损坏文件中断（由基类 FormatHandlerBase 统一实现）。
  Future<ParsedBook> parseMetadata(BookFile file);

  /// 打开阅读页时创建渲染器。
  ///
  /// [anchor] 为已保存进度（可能为空进度）；恢复逻辑在 [BookRenderer.controller]
  /// 的 restore 中执行（或渲染器创建时隐式执行）。
  Future<BookRenderer> createRenderer(
    BookFile file,
    ReaderSettings settings,
    ProgressAnchor anchor,
  );
}
