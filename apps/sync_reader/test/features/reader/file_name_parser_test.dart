/// 文件名元数据解析测试（FR-102："书名 - 作者"模式）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/formats/common/file_name_parser.dart';

void main() {
  group('parseBookFileName', () {
    test('标准"书名 - 作者"模式', () {
      final meta = parseBookFileName('三体 - 刘慈欣.txt');
      expect(meta.title, '三体');
      expect(meta.author, '刘慈欣');
    });

    test('含扩展名变体（epub/pdf/md）', () {
      expect(parseBookFileName('活着 - 余华.epub').author, '余华');
      expect(parseBookFileName('白夜行 - 东野圭吾.PDF').title, '白夜行');
      expect(parseBookFileName('笔记.md').title, '笔记');
    });

    test('无作者 → 作者空串', () {
      final meta = parseBookFileName('无作者的书.txt');
      expect(meta.title, '无作者的书');
      expect(meta.author, '');
    });

    test('多个分隔符 → 首个切分，其余并入作者', () {
      final meta = parseBookFileName('冰与火之歌 - 乔治·R·R·马丁 - 卷一.epub');
      expect(meta.title, '冰与火之歌');
      expect(meta.author, '乔治·R·R·马丁 - 卷一');
    });

    test('长破折号/全角分隔变体', () {
      expect(parseBookFileName('三体 — 刘慈欣.txt').author, '刘慈欣');
      expect(parseBookFileName('三体–刘慈欣.txt').author, '刘慈欣');
      expect(parseBookFileName('三体—刘慈欣.txt').author, '刘慈欣');
    });

    test('首尾空白修剪', () {
      final meta = parseBookFileName('  三体  -  刘慈欣  .txt');
      expect(meta.title, '三体');
      expect(meta.author, '刘慈欣');
    });

    test('无分隔符的短横线不属于作者（如连字号词）', () {
      // " - " 两侧必须有空白；连写的连字符不切分。
      final meta = parseBookFileName('SPDX-License-Identifier.txt');
      expect(meta.title, 'SPDX-License-Identifier');
      expect(meta.author, '');
    });

    test('隐藏文件/无主干名的退化不抛异常', () {
      expect(parseBookFileName('.txt'), isNotNull);
      expect(parseBookFileName('').title, '');
    });
  });
}
