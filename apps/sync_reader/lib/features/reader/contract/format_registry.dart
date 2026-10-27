/// 格式注册表：运行时唯一的 handler 查找入口（docs/03 §4.2）。
library;

import 'dart:typed_data';

import 'book_format_handler.dart';

/// 已注册格式的注册器。同 formatId 重复注册视为"升级覆盖"（后者生效），
/// 便于后续代理整文件重写 handler 后无缝替换。
class FormatRegistry {
  final Map<String, BookFormatHandler> _byFormatId = {};

  /// 注册（或覆盖同 formatId 的）handler。
  void register(BookFormatHandler handler) =>
      _byFormatId[handler.formatId] = handler;

  /// 全部已注册 handler（注册序，只读视图）。
  List<BookFormatHandler> get handlers => List.unmodifiable(_byFormatId.values);

  /// 按格式标识查找（books.format 列 → handler）。
  BookFormatHandler? byFormatId(String formatId) => _byFormatId[formatId];

  /// 按扩展名查找（导入时用；[magicHeader] 透传给 canHandle）。
  BookFormatHandler? byExtension(String ext, {Uint8List? magicHeader}) {
    for (final handler in _byFormatId.values) {
      if (handler.canHandle(ext.toLowerCase(), magicHeader ?? Uint8List(0))) {
        return handler;
      }
    }
    return null;
  }
}
