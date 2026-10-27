/// 封面生成/回填单测（云端书封面补齐）：
/// ① 下载完成后封面文件生成 + coverPath 登记（真实 epub 夹具走真实
///    EpubFormatHandler 的 parseMetadata 路径）；
/// ② 回填幂等（coverPath 已有不再生成；无封面格式跳过）；
/// ③ 防重入（同书并发只跑一次）与失败不重试（本进程内）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sync_reader/core/ulid.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/features/library/import/cover_generator.dart';
import 'package:sync_reader/features/reader/contract/book_file.dart';
import 'package:sync_reader/features/reader/contract/book_format_handler.dart';
import 'package:sync_reader/features/reader/contract/book_renderer.dart';
import 'package:sync_reader/features/reader/contract/format_registry.dart';
import 'package:sync_reader/features/reader/contract/parsed_book.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_format_handler.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_format_handler.dart';

import 'fake_handler.dart';
import 'support/minimal_epub.dart';

void main() {
  late AppDatabase db;
  late Directory tmp;
  late BookFileStore store;
  late FormatRegistry registry;
  late CoverGenerator generator;

  /// 落一行"已下载完成"形态的书（localPath 有值、coverPath 为空）。
  Future<String> seedBook(
    File contentFile, {
    String format = 'epub',
    String? coverPath,
    int? sizeBytes,
  }) async {
    final bookId = generateUlid();
    await db.booksDao.upsertCompanion(
      BooksCompanion.insert(
        bookId: bookId,
        title: '测试书',
        format: format,
        fileName: p.basename(contentFile.path),
        contentHash: 'sha256:deadbeef',
        sizeBytes: sizeBytes ?? await contentFile.length(),
        tocFingerprint: 'tfp:0000000000000000',
        addedAt: 1000,
        localPath: Value(contentFile.path),
      ).copyWith(coverPath: Value(coverPath)),
    );
    return bookId;
  }

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    tmp = await Directory.systemTemp.createTemp('cover_generator_test');
    store = BookFileStore(tmp);
    await store.ensureLayout();
    registry = FormatRegistry()
      ..register(TxtFormatHandler())
      ..register(EpubFormatHandler());
    generator = CoverGenerator(
      booksDao: db.booksDao,
      registry: registry,
      fileStore: Future.value(store),
    );
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) {
      await tmp.delete(recursive: true);
    }
  });

  group('下载完成后封面生成', () {
    test('epub：封面文件生成于 covers/{bookId}.png 并登记 coverPath', () async {
      final epubFile = File(p.join(tmp.path, 'book.epub'))
        ..writeAsBytesSync(buildMinimalEpub(coverBytes: tinyPng));
      final bookId = await seedBook(epubFile, format: 'epub');

      final ok = await generator.generateForBook(bookId);
      expect(ok, isTrue);

      final coverFile = File(store.resolveCoverPath(bookId));
      expect(coverFile.existsSync(), isTrue, reason: '封面文件已落盘');
      expect(coverFile.readAsBytesSync(), tinyPng);
      final row = await db.booksDao.getById(bookId);
      expect(row!.coverPath, store.resolveCoverPath(bookId));
    });

    test('txt（无封面）：跳过且不写文件', () async {
      final txtFile = File(p.join(tmp.path, 'book.txt'))
        ..writeAsStringSync('第一章\n正文');
      final bookId = await seedBook(txtFile, format: 'txt');

      final ok = await generator.generateForBook(bookId);
      expect(ok, isFalse);
      expect(File(store.resolveCoverPath(bookId)).existsSync(), isFalse);
      expect((await db.booksDao.getById(bookId))!.coverPath, isNull);
    });

    test('幂等：coverPath 已登记不再生成（既有文件字节不被覆盖）', () async {
      final epubFile = File(p.join(tmp.path, 'book.epub'))
        ..writeAsBytesSync(buildMinimalEpub(coverBytes: tinyPng));
      final coverPath = store.resolveCoverPath('any');
      final bookId = await seedBook(epubFile, coverPath: coverPath);
      final sentinel = [9, 9, 9];
      File(coverPath).parent.createSync(recursive: true);
      File(coverPath).writeAsBytesSync(sentinel);

      final ok = await generator.generateForBook(bookId);
      expect(ok, isFalse, reason: '已有封面不重复生成');
      expect(File(coverPath).readAsBytesSync(), sentinel, reason: '字节未被动过');
    });

    test('防重入：同一 bookId 并发只跑一次', () async {
      final gate = Completer<ParsedBook>();
      final slow = FormatRegistry();
      slow.register(_GatedHandler(gate: gate, coverBytes: tinyPng));
      final slowGenerator = CoverGenerator(
        booksDao: db.booksDao,
        registry: slow,
        fileStore: Future.value(store),
      );
      final epubFile = File(p.join(tmp.path, 'book.epub'))
        ..writeAsBytesSync(buildMinimalEpub(coverBytes: tinyPng));
      final bookId = await seedBook(epubFile, format: 'epub');

      final first = slowGenerator.generateForBook(bookId);
      final second = await slowGenerator.generateForBook(bookId);
      expect(second, isFalse, reason: '进行中不接受同书重复请求');
      gate.complete(
        ParsedBook(
          title: 't',
          author: '',
          toc: const [],
          tocFingerprint: 'tfp:0123456789abcdef',
          coverBytes: tinyPng,
        ),
      );
      expect(await first, isTrue);
    });

    test('失败不重试：文件缺失失败后，本进程内补上文件也不重试', () async {
      final missing = File(p.join(tmp.path, 'ghost.epub'));
      final bookId = await seedBook(missing, format: 'epub', sizeBytes: 123);
      expect(await generator.generateForBook(bookId), isFalse);

      // "下次重启"前文件补上了：仍不再重试（已尝试过的 bookId 记忆保留）。
      missing.writeAsBytesSync(buildMinimalEpub(coverBytes: tinyPng));
      expect(await generator.generateForBook(bookId), isFalse);
      expect(File(store.resolveCoverPath(bookId)).existsSync(), isFalse);
    });
  });

  group('存量回填', () {
    test('批量补生成：epub 登记封面，txt 跳过，重复回填幂等', () async {
      final epubFile = File(p.join(tmp.path, 'a.epub'))
        ..writeAsBytesSync(buildMinimalEpub(coverBytes: tinyPng));
      final txtFile = File(p.join(tmp.path, 'b.txt'))
        ..writeAsStringSync('第一章\n正文');
      final epubId = await seedBook(epubFile, format: 'epub');
      final txtId = await seedBook(txtFile, format: 'txt');

      await generator.backfillMissing();

      expect(
        (await db.booksDao.getById(epubId))!.coverPath,
        store.resolveCoverPath(epubId),
      );
      expect(File(store.resolveCoverPath(epubId)).readAsBytesSync(), tinyPng);
      expect((await db.booksDao.getById(txtId))!.coverPath, isNull);

      // 第二轮回填：已登记的跳过、无封面的记忆跳过，不抛不重复写。
      final mtimeBefore = File(store.resolveCoverPath(epubId))
          .lastModifiedSync();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await generator.backfillMissing();
      expect(
        File(store.resolveCoverPath(epubId)).lastModifiedSync(),
        mtimeBefore,
      );
    });

    test('占位书（正文未落盘）不参与回填', () async {
      final bookId = generateUlid();
      await db.booksDao.upsertCompanion(
        BooksCompanion.insert(
          bookId: bookId,
          title: '占位书',
          format: 'epub',
          fileName: '占位书.epub',
          contentHash: 'sha256:cafe',
          sizeBytes: 1,
          tocFingerprint: 'tfp:0000000000000000',
          addedAt: 1000,
        ),
      );
      await generator.backfillMissing();
      expect((await db.booksDao.getById(bookId))!.coverPath, isNull);
    });
  });
}

/// 解析时机可控的假 handler（防重入测试用）。
class _GatedHandler implements BookFormatHandler {
  _GatedHandler({required this.gate, this.coverBytes});

  final Completer<ParsedBook> gate;
  final Uint8List? coverBytes;

  @override
  String get formatId => 'epub';

  @override
  bool canHandle(String ext, Uint8List magicHeader) => ext == 'epub';

  @override
  Future<ParsedBook> parseMetadata(BookFile file) => gate.future;

  @override
  Future<BookRenderer> createRenderer(
    BookFile file,
    ReaderSettings settings,
    ProgressAnchor anchor,
  ) => throw UnimplementedError();
}
