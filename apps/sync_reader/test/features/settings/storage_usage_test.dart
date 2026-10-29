/// 存储占用统计与缓存清理的单元测试（真实临时目录 IO，普通 test 非 fakeAsync）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/features/settings/storage_usage.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('storage_usage_test');
  });

  tearDown(() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  group('StorageUsage.of', () {
    test('空目录布局全为 0（新建的 BookFileStore 未写入任何文件）', () async {
      final store = BookFileStore(root);
      await store.ensureLayout();
      final usage = await StorageUsage.of(store);
      expect(usage.booksBytes, 0);
      expect(usage.coversBytes, 0);
      expect(usage.tmpBytes, 0);
      expect(usage.totalBytes, 0);
    });

    test('分别统计 books / covers / tmp 的文件字节（含子目录递归）', () async {
      final store = BookFileStore(root);
      await store.ensureLayout();
      // books/{bookId}/source.txt（嵌套子目录）。
      final bookFile = File(p.join(store.booksDir.path, '01A', 'source.txt'));
      await bookFile.create(recursive: true);
      await bookFile.writeAsBytes(List.filled(100, 1));
      // covers/{bookId}.png。
      final cover = File(p.join(store.coversDir.path, '01A.png'));
      await cover.writeAsBytes(List.filled(50, 2));
      // tmp/ 两层。
      final tmpFile = File(p.join(store.tmpDir.path, 'part', 'a.bin'));
      await tmpFile.create(recursive: true);
      await tmpFile.writeAsBytes(List.filled(30, 3));

      final usage = await StorageUsage.of(store);
      expect(usage.booksBytes, 100);
      expect(usage.coversBytes, 50);
      expect(usage.tmpBytes, 30);
      expect(usage.totalBytes, 180);
    });

    test('目录不存在按 0 处理（ensureLayout 之前构造）', () async {
      final store = BookFileStore(root);
      final usage = await StorageUsage.of(store);
      expect(usage.totalBytes, 0);
    });
  });

  group('clearDirectoryContents', () {
    test('清空子文件与子目录，保留目录本身', () async {
      final dir = Directory(p.join(root.path, 'tmp'));
      await File(p.join(dir.path, 'a.txt')).create(recursive: true);
      await Directory(p.join(dir.path, 'sub')).create();
      await File(p.join(dir.path, 'sub', 'b.txt')).create();

      final removed = await clearDirectoryContents(dir);

      expect(removed, 2); // a.txt 与 sub/ 两个顶层条目。
      expect(dir.existsSync(), isTrue);
      expect(dir.listSync(), isEmpty);
    });

    test('目录不存在返回 0 不抛错', () async {
      final removed = await clearDirectoryContents(
        Directory(p.join(root.path, 'missing')),
      );
      expect(removed, 0);
    });
  });

  group('directorySize', () {
    test('不存在目录返回 0', () async {
      expect(await directorySize(Directory(p.join(root.path, 'missing'))), 0);
    });
  });
}
