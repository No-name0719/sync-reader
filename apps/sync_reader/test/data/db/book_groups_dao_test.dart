/// BookGroupsDao 单元测试（FR-107）：建组排序 / 重命名 / 删除置回未分组 / 重名校验。
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/core/ulid.dart';
import 'package:sync_reader/data/db/app_database.dart';

void main() {
  late AppDatabase db;

  /// 造一本书（仅必填列）。
  Future<void> seedBook(String id) => db.booksDao.upsertCompanion(
    BooksCompanion.insert(
      bookId: id,
      title: '书$id',
      format: 'txt',
      fileName: '$id.txt',
      contentHash: 'sha256:$id',
      sizeBytes: 10,
      tocFingerprint: 'tfp:0000000000000000',
      addedAt: 1,
      localPath: Value('/tmp/$id'),
    ),
  );

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // 立即触发 beforeOpen（外键 PRAGMA，删除分组 setNull 依赖它）。
    await db.customSelect('SELECT 1').getSingle();
  });

  tearDown(() async => db.close());

  group('BookGroupsDao', () {
    test('createGroup：sortOrder 从 0 递增、ULID 主键、名字 trim', () async {
      final g1 = await db.bookGroupsDao.createGroup('技术');
      final g2 = await db.bookGroupsDao.createGroup('小说');
      expect(g1.sortOrder, 0);
      expect(g2.sortOrder, 1);
      expect(isValidUlid(g1.groupId), isTrue);
      expect(isValidUlid(g2.groupId), isTrue);
      expect(g1.createdAt, greaterThan(0));
      // 名字去首尾空白。
      final g3 = await db.bookGroupsDao.createGroup('  历史  ');
      expect(g3.name, '历史');
    });

    test('createGroup 空白名抛 ArgumentError', () async {
      expect(() => db.bookGroupsDao.createGroup('   '), throwsArgumentError);
      expect(() => db.bookGroupsDao.createGroup(''), throwsArgumentError);
      expect(await db.bookGroupsDao.allGroups(), isEmpty);
    });

    test('renameGroup：重命名生效，sortOrder 不变', () async {
      final g = await db.bookGroupsDao.createGroup('旧名');
      await db.bookGroupsDao.renameGroup(g.groupId, ' 新名 ');
      final all = await db.bookGroupsDao.allGroups();
      expect(all.single.name, '新名');
      expect(all.single.sortOrder, 0);
    });

    test('renameGroup 空白名抛 ArgumentError', () async {
      final g = await db.bookGroupsDao.createGroup('原名');
      expect(
        () => db.bookGroupsDao.renameGroup(g.groupId, '  '),
        throwsArgumentError,
      );
      expect((await db.bookGroupsDao.allGroups()).single.name, '原名');
    });

    test('deleteGroup：书籍 group_id 由外键置 NULL（setNull 生效）', () async {
      final g = await db.bookGroupsDao.createGroup('技术');
      await seedBook('01A');
      await db.booksDao.setGroup('01A', g.groupId);
      expect((await db.booksDao.getById('01A'))!.groupId, g.groupId);
      await db.bookGroupsDao.deleteGroup(g.groupId);
      expect(await db.bookGroupsDao.allGroups(), isEmpty);
      // 外键 ON DELETE SET NULL：书还在，回到未分组。
      final book = await db.booksDao.getById('01A');
      expect(book, isNotNull);
      expect(book!.groupId, isNull);
    });

    test('allGroups 排序：sortOrder ASC、同权重按 createdAt ASC', () async {
      final g1 = await db.bookGroupsDao.createGroup('甲');
      final g2 = await db.bookGroupsDao.createGroup('乙');
      final g3 = await db.bookGroupsDao.createGroup('丙');
      expect(
        (await db.bookGroupsDao.allGroups()).map((g) => g.groupId).toList(),
        [g1.groupId, g2.groupId, g3.groupId],
      );
    });

    test('nameExists：trim 后精确匹配', () async {
      await db.bookGroupsDao.createGroup('技术');
      expect(await db.bookGroupsDao.nameExists('技术'), isTrue);
      expect(await db.bookGroupsDao.nameExists('  技术  '), isTrue);
      // 精确匹配：子串不算。
      expect(await db.bookGroupsDao.nameExists('技术书'), isFalse);
      expect(await db.bookGroupsDao.nameExists('不存在'), isFalse);
      // 空白名不视为存在。
      expect(await db.bookGroupsDao.nameExists('  '), isFalse);
    });
  });
}
