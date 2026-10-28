/// DAO 层单元测试：内存库（NativeDatabase.memory）覆盖
/// CRUD / 去重查询 / 排序搜索 / 软删除 / 进度脏标记 / 队列 FIFO。
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/db/daos/books_dao.dart';

void main() {
  late AppDatabase db;

  /// 造一本书的 BooksCompanion（字段可覆盖）。
  BooksCompanion bookRow(
    String id, {
    String title = '书',
    String author = '',
    String format = 'txt',
    String contentHash = 'sha256:aa',
    int addedAt = 1000,
    int? lastReadAt,
    String? localPath = '/tmp/x',
  }) => BooksCompanion.insert(
    bookId: id,
    title: title,
    format: format,
    fileName: '$id.$format',
    contentHash: contentHash,
    sizeBytes: 10,
    tocFingerprint: 'tfp:0000000000000000',
    addedAt: addedAt,
    localPath: Value(localPath),
    lastReadAt: Value(lastReadAt),
    author: Value(author),
  );

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // 立即触发 beforeOpen（pragma 执行路径）。
    await db.customSelect('SELECT 1').getSingle();
  });

  tearDown(() async => db.close());

  group('BooksDao', () {
    test('upsert + getById 往返', () async {
      await db.booksDao.upsertCompanion(
        bookRow('01A', title: '三体', author: '刘慈欣'),
      );
      final book = await db.booksDao.getById('01A');
      expect(book, isNotNull);
      expect(book!.title, '三体');
      expect(book.author, '刘慈欣');
      expect(book.totalSeconds, 0);
      // 再 upsert 同 id = 覆盖。
      await db.booksDao.upsertCompanion(
        bookRow('01A', title: '三体（修订版）', addedAt: 1000),
      );
      expect((await db.booksDao.getById('01A'))!.title, '三体（修订版）');
      final all = await db.select(db.books).get();
      expect(all, hasLength(1));
    });

    test('getByContentHash 去重查询（FR-101）', () async {
      await db.booksDao.upsertCompanion(
        bookRow('01A', contentHash: 'sha256:x1'),
      );
      await db.booksDao.upsertCompanion(
        bookRow('01B', contentHash: 'sha256:x2'),
      );
      final hit = await db.booksDao.getByContentHash('sha256:x1');
      expect(hit, isNotNull);
      expect(hit!.bookId, '01A');
      expect(await db.booksDao.getByContentHash('sha256:不存在'), isNull);
    });

    test('watchBooks 四种排序（FR-105）', () async {
      Future<void> seed() async {
        await db.booksDao.upsertCompanion(
          bookRow(
            '01A',
            title: '三体',
            author: '刘慈欣',
            addedAt: 100,
            lastReadAt: 900,
          ),
        );
        await db.booksDao.upsertCompanion(
          bookRow(
            '01B',
            title: '球状闪电',
            author: '刘慈欣',
            addedAt: 200,
            lastReadAt: 800,
          ),
        );
        await db.booksDao.upsertCompanion(
          bookRow(
            '01C',
            title: '活着',
            author: '余华',
            addedAt: 300,
            lastReadAt: null,
          ),
        );
      }

      await seed();
      // 最近阅读：读过的按 lastReadAt 倒序，从未读的垫底。
      expect(
        (await db.booksDao.watchBooks(sort: BookSort.lastRead).first)
            .map((b) => b.bookId)
            .toList(),
        ['01A', '01B', '01C'],
      );
      // 书名升序（SQLite BINARY：按 UTF-8 码点，三<活<球）。
      expect(
        (await db.booksDao.watchBooks(sort: BookSort.title).first)
            .map((b) => b.bookId)
            .toList(),
        ['01A', '01C', '01B'], // 三体 / 活着 / 球状闪电
      );
      // 作者升序（同作者按书名升序；"余"码点 < "刘"）。
      expect(
        (await db.booksDao.watchBooks(sort: BookSort.author).first)
            .map((b) => b.bookId)
            .toList(),
        ['01C', '01A', '01B'], // 余华 → 刘慈欣×2（三体<球状闪电）
      );
      // 添加时间倒序。
      expect(
        (await db.booksDao.watchBooks(sort: BookSort.addedAt).first)
            .map((b) => b.bookId)
            .toList(),
        ['01C', '01B', '01A'],
      );
    });

    test('watchBooks 书名/作者模糊搜索（FR-106）', () async {
      await db.booksDao.upsertCompanion(
        bookRow('01A', title: '三体', author: '刘慈欣'),
      );
      await db.booksDao.upsertCompanion(
        bookRow('01B', title: '球状闪电', author: '刘慈欣'),
      );
      // 书名命中。
      expect(
        (await db.booksDao.watchBooks(query: '三体').first).single.bookId,
        '01A',
      );
      // 作者命中两本。
      expect((await db.booksDao.watchBooks(query: '刘慈欣').first).length, 2);
      // 空白搜索 = 不过滤。
      expect((await db.booksDao.watchBooks(query: '  ').first).length, 2);
      // 无命中。
      expect((await db.booksDao.watchBooks(query: '不存在').first), isEmpty);
    });

    test('watchBooks 分组过滤 + setGroup（FR-107）', () async {
      final g1 = await db.bookGroupsDao.createGroup('技术');
      final g2 = await db.bookGroupsDao.createGroup('小说');
      // addedAt 各不相同：默认 lastRead 排序（都未读）退化为 addedAt 倒序，
      // 断言顺序才稳定。
      await db.booksDao.upsertCompanion(
        bookRow('01A', title: '三体', addedAt: 300),
      );
      await db.booksDao.upsertCompanion(
        bookRow('01B', title: '球状闪电', addedAt: 200),
      );
      await db.booksDao.upsertCompanion(
        bookRow('01C', title: '活着', addedAt: 100),
      );
      await db.booksDao.setGroup('01A', g1.groupId);
      await db.booksDao.setGroup('01B', g1.groupId);
      await db.booksDao.setGroup('01C', g2.groupId);

      // 指定分组：只保留该组的书。
      expect(
        (await db.booksDao.watchBooks(groupFilterId: g1.groupId).first)
            .map((b) => b.bookId)
            .toList(),
        ['01A', '01B'],
      );
      // 未分组视图：无书命中。
      expect(await db.booksDao.watchBooks(ungroupedOnly: true).first, isEmpty);
      // 移出分组（null = 未分组）后进入未分组视图。
      await db.booksDao.setGroup('01B', null);
      expect(
        (await db.booksDao.watchBooks(ungroupedOnly: true).first)
            .map((b) => b.bookId)
            .toList(),
        ['01B'],
      );
      // 分组过滤可与搜索叠加。
      expect(
        (await db.booksDao
                .watchBooks(groupFilterId: g1.groupId, query: '三体')
                .first)
            .single
            .bookId,
        '01A',
      );
      // 两者同时传入以 ungroupedOnly 为准（互斥视图，文档化语义）。
      expect(
        (await db.booksDao
                .watchBooks(groupFilterId: g1.groupId, ungroupedOnly: true)
                .first)
            .map((b) => b.bookId)
            .toList(),
        ['01B'],
      );
      // 不传 = 不过滤（向后兼容）。
      expect((await db.booksDao.watchBooks().first), hasLength(3));
    });

    test('updateProgressInfo 覆盖与累加', () async {
      await db.booksDao.upsertCompanion(bookRow('01A', addedAt: 1));
      await db.booksDao.updateProgressInfo(
        '01A',
        lastReadAt: DateTime.fromMillisecondsSinceEpoch(1234),
      );
      var book = await db.booksDao.getById('01A');
      expect(book!.lastReadAt, 1234);
      await db.booksDao.updateProgressInfo('01A', addTotalSeconds: 30);
      await db.booksDao.updateProgressInfo('01A', addTotalSeconds: 12);
      book = await db.booksDao.getById('01A');
      expect(book!.totalSeconds, 42);
      await db.booksDao.updateProgressInfo('01A', totalSeconds: 7);
      expect((await db.booksDao.getById('01A'))!.totalSeconds, 7);
    });

    test('softDelete：写 tombstone 账本 + books 移除 + 进度级联清除', () async {
      await db.booksDao.upsertCompanion(
        bookRow('01A', contentHash: 'sha256:del'),
      );
      await db.progressDao.upsert(
        bookId: '01A',
        locatorJson: '{"type":"raw","ratio":0.5}',
        percent: 0.5,
      );
      await db.booksDao.softDelete('01A');
      expect(await db.booksDao.getById('01A'), isNull);
      expect(await db.progressDao.getByBookId('01A'), isNull);
      final tombstone = await db.select(db.deletedBooks).getSingle();
      expect(tombstone.bookId, '01A');
      expect(tombstone.contentHash, 'sha256:del');
      expect(tombstone.pushed, isFalse);
      // 重复软删除同一本不炸（幂等）。
      await db.booksDao.softDelete('01A');
    });
  });

  group('ProgressDao', () {
    test('upsert / get / markClean / watchDirty', () async {
      // 外键约束：进度行必须挂在实际存在的书上。
      await db.booksDao.upsertCompanion(bookRow('01A'));
      await db.booksDao.upsertCompanion(bookRow('01B'));
      expect(await db.progressDao.getByBookId('01A'), isNull);
      await db.progressDao.upsert(
        bookId: '01A',
        locatorJson: '{"type":"txt","chapterIndex":1,"charOffset":2}',
        percent: 0.25,
      );
      final p = await db.progressDao.getByBookId('01A');
      expect(p!.dirty, isTrue);
      expect(p.percent, 0.25);
      // 再写一次 = 覆盖。
      await db.progressDao.upsert(
        bookId: '01A',
        locatorJson: '{"type":"txt","chapterIndex":2}',
        percent: 0.5,
        dirty: false, // 同步层拉取远端进度时不会脏
      );
      expect((await db.progressDao.getByBookId('01A'))!.dirty, isFalse);
      // watchDirty 只含脏行。
      await db.progressDao.upsert(
        bookId: '01B',
        locatorJson: '{}',
        percent: 0.1,
      );
      final dirtyIds = (await db.progressDao.watchDirty().first)
          .map((e) => e.bookId)
          .toList();
      expect(dirtyIds, ['01B']);
      // markClean。
      await db.progressDao.markClean('01B');
      expect(await db.progressDao.watchDirty().first, isEmpty);
    });
  });

  group('ReaderSettingsDao', () {
    test('get/set 往返与覆盖', () async {
      expect(await db.readerSettingsDao.getValue('reader_settings'), isNull);
      await db.readerSettingsDao.setValue('reader_settings', '{"fontSize":20}');
      expect(
        await db.readerSettingsDao.getValue('reader_settings'),
        '{"fontSize":20}',
      );
      await db.readerSettingsDao.setValue('reader_settings', '{"fontSize":22}');
      expect(
        await db.readerSettingsDao.getValue('reader_settings'),
        '{"fontSize":22}',
      );
    });
  });

  group('SyncQueueDao', () {
    test('enqueue FIFO / list / remove', () async {
      await db.syncQueueDao.enqueue(bookId: '01A', op: 'meta');
      await db.syncQueueDao.enqueue(bookId: '01B', op: 'book_upload');
      final list = await db.syncQueueDao.list();
      expect(list.map((e) => e.bookId).toList(), ['01A', '01B']);
      expect(list.first.attempts, 0);
      expect(list.first.enqueuedAt, greaterThan(0));
      // limit。
      expect((await db.syncQueueDao.list(limit: 1)).single.bookId, '01A');
      // remove。
      await db.syncQueueDao.remove(list.first.id);
      expect((await db.syncQueueDao.list()).map((e) => e.bookId).toList(), [
        '01B',
      ]);
    });
  });

  test(
    'schemaVersion == 2（docs/05 §6，M4 只增不删）',
    () => expect(db.schemaVersion, 2),
  );
}
