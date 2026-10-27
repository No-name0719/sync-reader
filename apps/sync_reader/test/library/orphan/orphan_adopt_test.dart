/// 游离文件挂回单测（FR-408 / docs/04 §7.1.3）：恢复 = hash 去重分流 →
/// 同盘 move 到平铺书库路径 → 既有导入管线登记（元数据/封面/入库）。
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sync_reader/core/content_hasher.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/features/library/import/book_import_service.dart';
import 'package:sync_reader/features/reader/contract/format_registry.dart';

import '../fake_handler.dart';

void main() {
  late AppDatabase db;
  late Directory tmp;
  late BookFileStore store;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    tmp = await Directory.systemTemp.createTemp('orphan_adopt_test');
    store = BookFileStore(tmp);
    await store.ensureLayout();
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) {
      await tmp.delete(recursive: true);
    }
  });

  BookImportService buildService({FakeHandler? handler}) => BookImportService(
    booksDao: db.booksDao,
    registry: FormatRegistry()
      ..register(handler ?? FakeHandler(coverBytes: tinyPng)),
    fileStore: Future.value(store),
  );

  /// 在 books/ 平铺目录写一个游离形态文件（主干是"旧 bookId"形态的串）。
  Future<File> orphanFile(String name, List<int> bytes) async {
    final file = File(p.join(store.booksDir.path, name));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return file;
  }

  group('adoptExistingFile（恢复挂回）', () {
    test('挂回成功：move 到新 bookId 平铺路径 + 行登记齐全 + 原路径消失', () async {
      final bytes = [1, 2, 3, 4, 5];
      final old = await orphanFile('01ARZ3NDEKTSV4RRFFQ69G5FAV.txt', bytes);
      final result = await buildService().adoptExistingFile(filePath: old.path);

      expect(result.adopted, isTrue);
      expect(result.isDuplicate, isFalse);
      final book = result.book!;
      // 新 ULID 主键，行字段复用导入管线语义。
      expect(book.bookId, hasLength(26));
      expect(book.title, '解析书名');
      expect(book.author, '作者甲');
      expect(book.format, 'txt');
      expect(book.fileName, '01ARZ3NDEKTSV4RRFFQ69G5FAV.txt');
      expect(
        book.contentHash,
        await ContentHasher.hashStream(Stream.value(bytes)),
      );
      expect(book.sizeBytes, bytes.length);
      // 正文 move（非 copy）：新路径在、原路径无、字节不变。
      expect(book.localPath, store.resolveFlatBookPath(book.bookId, 'txt'));
      expect(File(book.localPath!).existsSync(), isTrue);
      expect(File(book.localPath!).readAsBytesSync(), bytes);
      expect(old.existsSync(), isFalse);
      // 封面按新 bookId 落盘并登记。
      expect(book.coverPath, store.resolveCoverPath(book.bookId));
      expect(File(book.coverPath!).readAsBytesSync(), tinyPng);
      // 库内可查。
      expect((await db.booksDao.getById(book.bookId))!.title, '解析书名');
    });

    test('hash 去重分支：库内已有同 hash 书 → 不挂回（原文件原地保留）', () async {
      final bytes = [9, 9, 9];
      // 先经既有导入管线入库一本书（源文件放 tmp 根，避免混入 books/）。
      final source = File(p.join(tmp.path, '源.txt'));
      await source.writeAsBytes(bytes);
      final imported = await buildService().importFiles([source.path]);
      expect(imported.imported, hasLength(1));

      final orphan = await orphanFile('01ARZ3NDEKTSV4RRFFQ69G5FAV.txt', bytes);
      final result = await buildService().adoptExistingFile(
        filePath: orphan.path,
      );

      expect(result.isDuplicate, isTrue);
      expect(result.duplicateOf, imported.imported.single.title);
      expect(result.book, isNull);
      // 游离文件未被移动：原路径仍在，库内不新增行。
      expect(orphan.existsSync(), isTrue);
      expect(await db.select(db.books).get(), hasLength(1));
    });

    test('不支持的扩展名 → 抛 FormatException（防御性兜底）', () async {
      final orphan = await orphanFile('01ARZ3NDEKTSV4RRFFQ69G5FAV.xyz', [1]);
      expect(
        () => buildService().adoptExistingFile(filePath: orphan.path),
        throwsFormatException,
      );
      // 文件未被移动。
      expect(orphan.existsSync(), isTrue);
    });

    test('解析书名为空白 → 兜底文件名主干', () async {
      final orphan = await orphanFile('01ARZ3NDEKTSV4RRFFQ69G5FAV.txt', [1]);
      final result = await buildService(handler: FakeHandler(title: '   '))
          .adoptExistingFile(filePath: orphan.path);
      expect(result.book!.title, '01ARZ3NDEKTSV4RRFFQ69G5FAV');
    });
  });
}
