/// 阅读器 feature 公共出口（冻结 API 的一站式导入入口）。
///
/// 后续四个格式代理（txt/md/pdf/epub）与集成代理从这里导入契约；
/// 契约文件头的中文注释即为接口文档。
library;

// ---- 契约（冻结 API）----
export 'contract/book_file.dart';
export 'contract/book_format_handler.dart';
export 'contract/book_renderer.dart';
export 'contract/format_registry.dart';
export 'contract/parsed_book.dart';
export 'contract/progress_anchor.dart';
export 'contract/reader_controller.dart';
export 'contract/reader_settings.dart';
export 'contract/reader_settings_repository.dart';
export 'contract/toc_entry.dart';
export 'contract/toc_fingerprint.dart';

// ---- 公共实现 ----
export 'formats/common/file_name_parser.dart';
export 'formats/common/text_decoder.dart';
export 'formats/handler_base.dart';
export 'reading_day.dart';
export 'stub_renderer.dart';
export 'volume_key_page_turn.dart';

// ---- 四个基线 handler（后续代理整文件重写）----
export 'formats/epub/epub_format_handler.dart';
export 'formats/md/md_format_handler.dart';
export 'formats/pdf/pdf_format_handler.dart';
export 'formats/txt/txt_format_handler.dart';

// ---- 页面骨架 ----
export 'reader_page.dart';
