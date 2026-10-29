/// 导入流水线单测（FR-101/102）：内存库 + 临时目录 + 假 handler，
/// 不依赖真实格式 handler（避免被并行重写波及）；
/// 含「同时上传到云端」开关（docs/10 §4.7c）的标记落库行为。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sync_reader/core/content_hasher.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/features/library/import/book_import_service.dart';
import 'package:sync_reader/features/reader/contract/format_registry.dart';

import 'fake_handler.dart';

void main() {
  late AppDatabase db;
  late Directory tmp;
  late BookFileStore store;
  late BookImportService service;

  /// 在临时目录写一个源文件并返回路径。
  Future<String> source(String name, List<int> bytes) async {
    final file = File(p.join(tmp.path, name));
    await file.writeAsBytes(bytes);
    return file.path;
  }

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    tmp = await Directory.systemTemp.createTemp('import_service_test');
    store = BookFileStore(tmp);
    await store.ensureLayout();
    service = BookImportService(
      booksDao: db.booksDao,
      registry: FormatRegistry()..register(FakeHandler(coverBytes: tinyPng)),
      fileStore: Future.value(store),
    );
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) {
      await tmp.delete(recursive: true);
    }
  });

  test('新文件导入：行字段/正文复制/封面落盘全部就位', () async {
    final bytes = utf8.encode('你好，世界。');
    final path = await source('三体.txt', bytes);
    final withCover = await source('封面书.epub', [1, 2, 3, 4, 5]);

    final summary = await service.importFiles([path, withCover]);
    expect(summary.imported, hasLength(2));
    expect(summary.duplicates, isEmpty);
    expect(summary.failures, isEmpty);

    final book = summary.imported.first;
    expect(book.title, '解析书名');
    expect(book.author, '作者甲');
    expect(book.format, 'txt');
    expect(book.fileName, '三体.txt');
    expect(book.sizeBytes, bytes.length);
    expect(book.contentHash, startsWith('sha256:'));
    expect(
      book.contentHash,
      await ContentHasher.hashStream(Stream.value(bytes)),
    );
    expect(book.tocFingerprint, 'tfp:0123456789abcdef');
    // 正文已复制到书库目录。
    expect(book.localPath, store.resolveBookPath(book.bookId, 'txt'));
    expect(File(book.localPath!).existsSync(), isTrue);
    expect(File(book.localPath!).readAsBytesSync(), bytes);
    // 库内可查。
    expect((await db.booksDao.getById(book.bookId))!.title, '解析书名');

    // 两本都由假 handler 提供封面：封面文件字节一致。
    for (final imported in summary.imported) {
      expect(imported.coverPath, store.resolveCoverPath(imported.bookId));
      expect(File(imported.coverPath!).readAsBytesSync(), tinyPng);
    }
  });

  test('同批次内容相同 → 第二个复用条目（FR-101 批内去重）', () async {
    final a = await source('甲.txt', [1, 2, 3]);
    final b = await source('乙.txt', [1, 2, 3]);
    final summary = await service.importFiles([a, b]);
    expect(summary.imported, hasLength(1));
    expect(summary.duplicates, hasLength(1));
    expect(summary.toMessage(), contains('已存在'));
    // 库里只有一本。
    expect(await db.select(db.books).get(), hasLength(1));
  });

  test('跨批次重复导入 → 提示已存在并复用（FR-101）', () async {
    final path = await source('三体.txt', [9, 9, 9]);
    final first = await service.importFiles([path]);
    final again = await service.importFiles([path]);
    expect(again.imported, isEmpty);
    expect(again.duplicates['三体.txt'], first.imported.single.title);
    expect(await db.select(db.books).get(), hasLength(1));
  });

  test('单文件失败不中断整批', () async {
    final good = await source('好.txt', [4, 5, 6]);
    final summary = await service.importFiles([good, '${tmp.path}/不存在.txt']);
    expect(summary.imported, hasLength(1));
    expect(summary.failures, hasLength(1));
    expect(summary.failures.keys.single, contains('不存在.txt'));
  });

  test('不支持的扩展名计入失败', () async {
    final path = await source('奇怪.xyz', [7]);
    final summary = await service.importFiles([path]);
    expect(summary.imported, isEmpty);
    expect(summary.failures['奇怪.xyz'], contains('不支持的格式'));
  });

  test('onProgress 逐文件回调', () async {
    final paths = [
      await source('a.txt', [1]),
      await source('b.txt', [2]),
    ];
    final progresses = <ImportProgress>[];
    await service.importFiles(paths, onProgress: progresses.add);
    expect(progresses, hasLength(2));
    expect(progresses.last.completed, 2);
    expect(progresses.last.total, 2);
    expect(progresses.last.currentName, 'b.txt');
  });

  test('空批次', () async {
    final summary = await service.importFiles([]);
    expect(summary.total, 0);
    expect(summary.toMessage(), '没有选择任何文件');
  });

  group('「同时上传到云端」开关（docs/10 §4.7c / Q18）', () {
    /// 带仅本地标记 DAO 的服务（生产装配同款）。
    BookImportService buildService() => BookImportService(
      booksDao: db.booksDao,
      registry: FormatRegistry()..register(FakeHandler(coverBytes: tinyPng)),
      fileStore: Future.value(store),
      localOnlyDao: db.localOnlyBooksDao,
    );

    test('默认勾选（上传）：不写仅本地标记', () async {
      final path = await source('默认.txt', [1, 2, 3]);
      final summary = await buildService().importFiles([path]);
      expect(summary.imported, hasLength(1));
      expect(
        await db.localOnlyBooksDao.isLocalOnly(summary.imported.single.bookId),
        isFalse,
      );
    });

    test('取消勾选（不上传）：写入仅本地标记', () async {
      final path = await source('不上传.txt', [4, 5, 6]);
      final summary = await buildService().importFiles([
        path,
      ], uploadToCloud: false);
      expect(summary.imported, hasLength(1));
      final bookId = summary.imported.single.bookId;
      expect(await db.localOnlyBooksDao.isLocalOnly(bookId), isTrue);
      expect(await db.localOnlyBooksDao.localOnlyBookIds(), {bookId});
    });

    test('重复导入：勾选状态落到已有书上', () async {
      final path = await source('重复.txt', [7, 7, 7]);
      final svc = buildService();
      final first = await svc.importFiles([path], uploadToCloud: false);
      final bookId = first.imported.single.bookId;
      expect(await db.localOnlyBooksDao.isLocalOnly(bookId), isTrue);

      // 再导入同一文件且勾选「上传」→ 解除已有书的标记。
      final again = await svc.importFiles([path], uploadToCloud: true);
      expect(again.imported, isEmpty);
      expect(again.duplicates, hasLength(1));
      expect(await db.localOnlyBooksDao.isLocalOnly(bookId), isFalse);

      // 再导入且取消勾选 → 写回标记。
      await svc.importFiles([path], uploadToCloud: false);
      expect(await db.localOnlyBooksDao.isLocalOnly(bookId), isTrue);
    });
  });
}
