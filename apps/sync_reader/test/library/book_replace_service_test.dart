/// FR-410 文件替换服务单测（同格式覆盖 / 跨格式替换 / 解析失败降级 /
/// 进度行不动 / 失败折算）：内存库 + 临时目录 + 假 handler + 假推送，
/// 不依赖真实格式 handler 与同步引擎。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sync_core/sync_core.dart';
import 'package:sync_reader/core/content_hasher.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/data/sync/drift_local_library.dart';
import 'package:sync_reader/features/library/replace/book_replace_service.dart';
import 'package:sync_reader/features/reader/contract/book_file.dart';
import 'package:sync_reader/features/reader/contract/book_format_handler.dart';
import 'package:sync_reader/features/reader/contract/book_renderer.dart';
import 'package:sync_reader/features/reader/contract/format_registry.dart';
import 'package:sync_reader/features/reader/contract/parsed_book.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';

import 'fake_handler.dart';

/// 恒抛异常的违约 handler：服务必须防御（解析失败降级，不阻塞替换）。
class ThrowingHandler implements BookFormatHandler {
  @override
  String get formatId => 'txt';

  @override
  bool canHandle(String ext, Uint8List magicHeader) => ext == 'txt';

  @override
  Future<ParsedBook> parseMetadata(BookFile file) => throw StateError('解析爆炸');

  @override
  Future<BookRenderer> createRenderer(
    BookFile file,
    ReaderSettings settings,
    ProgressAnchor anchor,
  ) => throw UnimplementedError();
}

void main() {
  const bookId = '01AREPLACEBOOK00000000000001';
  const oldHash = 'sha256:11111111111111111111111111111111';

  late AppDatabase db;
  late Directory tmp;
  late BookFileStore store;
  late DriftLocalLibrary library;
  late BookReplaceService service;

  // 假推送：记录调用次数与推送发生时的行内 hash（断言"行更新先行"），
  // pushResult 控制返回 null（未配置）/ 成功报告 / 带错误的报告。
  var pushCalls = 0;
  String? hashAtPush;
  String pushResult = 'null';

  Future<SyncReport?> fakePush(String id) async {
    pushCalls++;
    hashAtPush = (await db.booksDao.getById(id))!.contentHash;
    switch (pushResult) {
      case 'success':
        return SyncReport(startedAt: DateTime.now());
      case 'network':
        return SyncReport(startedAt: DateTime.now())..add(
          BookSyncResult(
            bookId: id,
            ok: false,
            error: const NetworkUnreachable('网络不可达'),
          ),
        );
      default:
        return null;
    }
  }

  /// 在临时目录写一个待选新文件并返回路径。
  Future<String> source(String name, List<int> bytes) async {
    final file = File(p.join(tmp.path, name));
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// 造一本带本地正文 + 进度行的书（返回替换前的进度行快照）。
  Future<BookProgress> seedBook() async {
    final localPath = p.join(store.booksDir.path, bookId, 'source.txt');
    final file = File(localPath);
    await file.create(recursive: true);
    await file.writeAsString('旧正文');
    await db.booksDao.upsert(
      Book(
        bookId: bookId,
        title: '三体',
        author: '刘慈欣',
        format: 'txt',
        fileName: '三体.txt',
        localPath: localPath,
        contentHash: oldHash,
        sizeBytes: 1234,
        coverPath: null,
        tocFingerprint: 'tfp:oldoldoldoldo',
        addedAt: 1700000000000,
        lastReadAt: 1700003600000,
        totalSeconds: 90,
      ),
    );
    await db.progressDao.upsert(
      bookId: bookId,
      locatorJson: '{"type":"txt","chapterIndex":1,"charOffset":10}',
      percent: 0.42,
      dirty: false,
    );
    return (await db.progressDao.getByBookId(bookId))!;
  }

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    tmp = await Directory.systemTemp.createTemp('replace_service_test');
    store = BookFileStore(tmp);
    await store.ensureLayout();
    library = DriftLocalLibrary(db: db, fileStore: Future.value(store));
    pushCalls = 0;
    hashAtPush = null;
    pushResult = 'null';
    service = BookReplaceService(
      booksDao: db.booksDao,
      registry: FormatRegistry()
        ..register(
          FakeHandler(
            formatId: 'txt',
            extensions: const {'txt'},
            coverBytes: tinyPng,
          ),
        )
        ..register(
          FakeHandler(
            formatId: 'epub',
            extensions: const {'epub'},
            title: 'epub解析书名',
            author: 'epub作者',
            coverBytes: tinyPng,
          ),
        ),
      fileStore: Future.value(store),
      library: library,
      pushToCloud: fakePush,
    );
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) {
      await tmp.delete(recursive: true);
    }
  });

  test('同格式覆盖：原路径内容更新，文件指征列与元数据列全部更新，进度行不动', () async {
    final progressBefore = await seedBook();
    final newBytes = utf8.encode('新正文内容，比旧的更长一点');
    final path = await source('三体（新版）.txt', newBytes);
    final newHash = await ContentHasher.hashStream(Stream.value(newBytes));

    final result = await service.replaceFile(bookId: bookId, sourcePath: path);

    // 未配置同步（假推送返回 null）→ localOnly，本地替换已生效。
    expect(result.status, BookReplaceStatus.localOnly);
    expect(result.localReplaced, isTrue);
    expect(result.toMessage(), '本地文件已替换（未配置同步，云端未更新）');
    expect(pushCalls, 1);
    // 行更新先于推送：推送发生时行内已是新 hash。
    expect(hashAtPush, newHash);

    final book = (await db.booksDao.getById(bookId))!;
    final localPath = p.join(store.booksDir.path, bookId, 'source.txt');
    // 原路径覆盖：路径不变，内容为新文件。
    expect(book.localPath, localPath);
    expect(File(localPath).readAsBytesSync(), newBytes);
    // 文件指征列更新。
    expect(book.contentHash, newHash);
    expect(book.sizeBytes, newBytes.length);
    expect(book.fileName, '三体（新版）.txt');
    expect(book.format, 'txt');
    // 元数据列按重解析更新 + 封面落盘登记。
    expect(book.title, '解析书名');
    expect(book.author, '作者甲');
    expect(book.tocFingerprint, 'tfp:0123456789abcdef');
    expect(book.coverPath, store.resolveCoverPath(bookId));
    expect(File(book.coverPath!).readAsBytesSync(), tinyPng);
    // 进度行完全不动（percent/locator/updatedAt/dirty 全字段一致）。
    expect(await db.progressDao.getByBookId(bookId), progressBefore);
  });

  test('跨格式替换：新路径落盘 + 旧文件删除 + format/localPath 重探', () async {
    final progressBefore = await seedBook();
    final newBytes = [1, 2, 3, 4, 5, 6, 7, 8];
    final path = await source('新名字.epub', newBytes);
    final newHash = await ContentHasher.hashStream(Stream.value(newBytes));

    final result = await service.replaceFile(bookId: bookId, sourcePath: path);

    expect(result.status, BookReplaceStatus.localOnly);
    expect(pushCalls, 1);
    expect(hashAtPush, newHash);

    final newPath = store.resolveBookPath(bookId, 'epub');
    final oldPath = p.join(store.booksDir.path, bookId, 'source.txt');
    // 新格式文件落盘，旧格式文件已删除。
    expect(File(newPath).readAsBytesSync(), newBytes);
    expect(File(oldPath).existsSync(), isFalse);
    final book = (await db.booksDao.getById(bookId))!;
    expect(book.format, 'epub');
    expect(book.localPath, newPath);
    expect(book.fileName, '新名字.epub');
    expect(book.sizeBytes, newBytes.length);
    // 元数据列按 epub handler 重解析更新。
    expect(book.title, 'epub解析书名');
    expect(book.author, 'epub作者');
    // 进度行完全不动。
    expect(await db.progressDao.getByBookId(bookId), progressBefore);
  });

  test('解析失败降级：文件指征列更新，元数据列保留旧值', () async {
    await seedBook();
    final broken = BookReplaceService(
      booksDao: db.booksDao,
      registry: FormatRegistry()..register(ThrowingHandler()),
      fileStore: Future.value(store),
      library: library,
      pushToCloud: fakePush,
    );
    final newBytes = utf8.encode('违约 handler 场景的新正文');
    final path = await source('新名字.txt', newBytes);
    final newHash = await ContentHasher.hashStream(Stream.value(newBytes));

    final result = await broken.replaceFile(bookId: bookId, sourcePath: path);

    // 替换本身不因解析失败而阻塞。
    expect(result.status, BookReplaceStatus.localOnly);
    expect(pushCalls, 1);
    final book = (await db.booksDao.getById(bookId))!;
    // 文件指征列已更新。
    expect(book.contentHash, newHash);
    expect(book.sizeBytes, newBytes.length);
    expect(book.fileName, '新名字.txt');
    expect(book.localPath, p.join(store.booksDir.path, bookId, 'source.txt'));
    // 元数据列保留旧值（封面不登记）。
    expect(book.title, '三体');
    expect(book.author, '刘慈欣');
    expect(book.tocFingerprint, 'tfp:oldoldoldoldo');
    expect(book.coverPath, isNull);
  });

  test('占位书（无本地正文）不可替换', () async {
    await db.booksDao.upsert(
      Book(
        bookId: bookId,
        title: '占位书',
        author: '',
        format: 'epub',
        fileName: '占位书.epub',
        localPath: null,
        contentHash: oldHash,
        sizeBytes: 100,
        coverPath: null,
        tocFingerprint: 'tfp:oldoldoldoldo',
        addedAt: 1700000000000,
        lastReadAt: null,
        totalSeconds: 0,
      ),
    );
    final path = await source('新书.epub', [1, 2, 3]);

    final result = await service.replaceFile(bookId: bookId, sourcePath: path);

    expect(result.status, BookReplaceStatus.localFailed);
    expect(result.reason, contains('占位书'));
    expect(pushCalls, 0);
    // 行未动。
    final book = (await db.booksDao.getById(bookId))!;
    expect(book.contentHash, oldHash);
    expect(book.localPath, isNull);
  });

  test('不支持的格式：拒绝替换，行与文件未动', () async {
    await seedBook();
    final path = await source('坏文件.azw3', [1, 2, 3]);

    final result = await service.replaceFile(bookId: bookId, sourcePath: path);

    expect(result.status, BookReplaceStatus.localFailed);
    expect(result.reason, contains('azw3'));
    expect(pushCalls, 0);
    final book = (await db.booksDao.getById(bookId))!;
    expect(book.contentHash, oldHash);
    expect(book.fileName, '三体.txt');
    expect(File(book.localPath!).readAsStringSync(), '旧正文');
  });

  test('本地 IO 失败（源文件缺失）：折算 localFailed，一切未动', () async {
    await seedBook();
    final result = await service.replaceFile(
      bookId: bookId,
      sourcePath: p.join(tmp.path, '不存在.txt'),
    );

    expect(result.status, BookReplaceStatus.localFailed);
    expect(pushCalls, 0);
    final book = (await db.booksDao.getById(bookId))!;
    expect(book.contentHash, oldHash);
    expect(book.sizeBytes, 1234);
    expect(File(book.localPath!).readAsStringSync(), '旧正文');
  });

  test('云端推送失败：本地已替换（本地优先），结果带分类错误', () async {
    pushResult = 'network';
    await seedBook();
    final newBytes = utf8.encode('推送会失败的新正文');
    final path = await source('三体新版.txt', newBytes);
    final newHash = await ContentHasher.hashStream(Stream.value(newBytes));

    final result = await service.replaceFile(bookId: bookId, sourcePath: path);

    expect(result.status, BookReplaceStatus.cloudFailed);
    expect(result.localReplaced, isTrue);
    expect(result.reason, '网络不可达，请检查网络连接');
    expect(result.toMessage(), '本地已替换，云端推送失败（网络不可达，请检查网络连接），下次同步自动重试');
    // 本地优先：行与文件都已是新内容（引擎幂等，下次同步自动重试）。
    final book = (await db.booksDao.getById(bookId))!;
    expect(book.contentHash, newHash);
    expect(File(book.localPath!).readAsBytesSync(), newBytes);
  });

  test('云端推送成功：返回 success 与对应文案', () async {
    pushResult = 'success';
    await seedBook();
    final path = await source('三体新版.txt', utf8.encode('成功推送的新正文'));

    final result = await service.replaceFile(bookId: bookId, sourcePath: path);

    expect(result.status, BookReplaceStatus.success);
    expect(result.toMessage(), '正文已替换并开始同步');
  });

  test('书籍不存在：localFailed 且不推送', () async {
    final path = await source('孤儿.txt', [1]);
    final result = await service.replaceFile(
      bookId: '01NOTEXIST0000000000',
      sourcePath: path,
    );
    expect(result.status, BookReplaceStatus.localFailed);
    expect(pushCalls, 0);
  });
}
