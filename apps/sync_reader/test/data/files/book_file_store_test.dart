/// BookFileStore 测试：临时目录往返（导入复制 / 路径解析 / 游离区 / 删除）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sync_reader/data/files/book_file_store.dart';

void main() {
  late Directory tempDir;
  late BookFileStore store;

  /// 造一个临时源文件。
  File makeSource(String name, String content) =>
      File(p.join(tempDir.path, name))
        ..writeAsStringSync(content, encoding: utf8);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sync_reader_test_');
    store = BookFileStore(tempDir);
    await store.ensureLayout();
  });

  tearDown(() async => tempDir.delete(recursive: true));

  test('ensureLayout 建齐四个子目录', () async {
    expect(store.booksDir.existsSync(), isTrue);
    expect(store.coversDir.existsSync(), isTrue);
    expect(store.orphansDir.existsSync(), isTrue);
    expect(store.tmpDir.existsSync(), isTrue);
    // 幂等。
    await store.ensureLayout();
  });

  test('resolveBookPath / resolveCoverPath 符合布局约定', () {
    expect(
      store.resolveBookPath('01A', 'EPUB'),
      p.join(tempDir.path, 'books', '01A', 'source.epub'),
    );
    expect(
      store.resolveBookPath('01A', '.txt'),
      p.join(tempDir.path, 'books', '01A', 'source.txt'),
    );
    expect(
      store.resolveCoverPath('01A'),
      p.join(tempDir.path, 'covers', '01A.png'),
    );
  });

  test('importCopy：复制源文件并返回落库路径', () async {
    final src = makeSource('原始文件.txt', '正文内容');
    final copied = await store.importCopy(
      bookId: '01A',
      ext: 'txt',
      source: src,
    );
    final target = File(store.resolveBookPath('01A', 'txt'));
    expect(copied, target.path);
    expect(target.existsSync(), isTrue);
    expect(target.readAsStringSync(encoding: utf8), '正文内容');
    // 源文件保留（FR-101：复制而非移动）。
    expect(src.existsSync(), isTrue);
  });

  test('moveToOrphans：书目录移入游离区，缺失书返回 null', () async {
    await store.importCopy(
      bookId: '01A',
      ext: 'txt',
      source: makeSource('a.txt', 'x'),
    );
    final orphanPath = await store.moveToOrphans('01A');
    expect(orphanPath, isNotNull);
    expect(Directory(orphanPath!).existsSync(), isTrue);
    expect(File(p.join(orphanPath, 'source.txt')).existsSync(), isTrue);
    expect(store.booksDir.listSync(), isEmpty);
    expect((await store.listOrphans()).length, 1);
    // 不存在的书 → null。
    expect(await store.moveToOrphans('不存在'), isNull);
  });

  test('deleteBookFiles：正文目录与封面一并清除（幂等）', () async {
    await store.importCopy(
      bookId: '01A',
      ext: 'txt',
      source: makeSource('a.txt', 'x'),
    );
    File(store.resolveCoverPath('01A')).writeAsBytesSync([1, 2, 3]);
    await store.deleteBookFiles('01A');
    expect(Directory(p.join(store.booksDir.path, '01A')).existsSync(), isFalse);
    expect(File(store.resolveCoverPath('01A')).existsSync(), isFalse);
    // 对不存在的书调用不抛异常。
    await store.deleteBookFiles('01A');
  });
}
