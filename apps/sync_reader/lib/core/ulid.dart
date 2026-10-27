/// ULID 生成工具（docs/05 §4.1）。
///
/// bookId / deviceId 均使用 ULID（时间有序、字典序可排序）。
/// 底层实现使用 `ulid` 包（Random.secure）；本文件是唯一入口，
/// 后续如替换实现不影响调用方。
library;

import 'package:ulid/ulid.dart';

/// 生成一个规范形式的 ULID 字符串（26 位大写 Crockford Base32，docs/05 示例形态）。
///
/// 用途：导入书籍时生成 bookId、首次启动生成 deviceId（docs/05 §4.1）。
String generateUlid() => Ulid().toBase32();

/// ULID 字符串的合法形态校验（26 位 Crockford Base32 大写）。
bool isValidUlid(String value) =>
    RegExp(r'^[0-9A-HJKMNP-TV-Z]{26}$').hasMatch(value);
