/// 游离文件扫描/删除单测（FR-408）：临时目录夹具 + 内存库 + 假 handler。
///
/// 覆盖三种真实游离形态（docs/04 §7.1）：
/// - orphans/ 区整书目录（本端删除 moveToOrphans 产物，`{bookId}-{时间戳}`）；
/// - books/{bookId}/ 分层目录残留（他端 tombstone 后正文保留）；
/// - books/{bookId}.{ext} 平铺残留。
/// 以及 books 表差集场景（全游离 / 全关联 / 混合 / 目录不存在）与
/// 彻底删除的容器+封面残留清理。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/features/library/orphan/orphan_book_file.dart';
import 'package:sync_reader/features/library/orphan/orphan_file_service.dart';
import 'package:sync_reader/features/reader/contract/format_registry.dart';

import '../fake_handler.dart';

void main() {
  late AppDatabase db;
  late Directory tmp;
  late BookFileStore store;
  late OrphanFileService service;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    tmp = await Directory.systemTemp.createTemp('orphan_service_test');
    store = BookFileStore(tmp);
    await store.ensureLayout();
    // txt / epub 两个假 handler（md / pdf 不注册 → 非正文格式场景）。
    service = OrphanFileService(
      booksDao: db.booksDao,
      registry: FormatRegistry()
        ..register(FakeHandler(formatId: 'txt', extensions: {'txt'}))
        ..register(FakeHandler(formatId: 'epub', extensions: {'epub'})),
      fileStore: Future.value(store),
    );
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) {
      await tmp.delete(recursive: true);
    }
  });

  /// 在 books/ 平铺目录写一个游离形态文件。
  Future<File> bookFile(String name, List<int> bytes) async {
    final file = File(p.join(store.booksDir.path, name));
    await file.writeAsBytes(bytes);
    return file;
  }

  /// 插入一本占位书（只为占住 bookId 集合）。
  Future<void> insertBook(String bookId) => db.booksDao.upsertCompanion(
    BooksCompanion.insert(
      bookId: bookId,
      title: '书-$bookId',
      format: 'txt',
      fileName: '$bookId.txt',
      contentHash: 'sha256:$bookId',
      sizeBytes: 1,
      tocFingerprint: 'tfp:0000000000000000',
      addedAt: 1000,
      localPath: const Value(null),
    ),
  );

  group('scan（列目录 × books 表差集，只读）', () {
    test('全游离：books 表为空 → 平铺正文全部列出（含字段与排序）', () async {
      await bookFile('甲.txt', [1, 2, 3]);
      await bookFile('乙.epub', [4, 5, 6, 7]);
      await bookFile('丙.TXT', [8]);

      final orphans = await service.scan();
      // 按文件名字典序（UTF-16 码元序：乙 < 甲 < 丙）；.TXT 大小写归一后识别为 txt。
      expect(orphans.map((o) => o.fileName), ['丙.TXT', '乙.epub', '甲.txt']);
      final jia = orphans[2];
      expect(jia.stem, '甲');
      expect(jia.ext, 'txt');
      expect(jia.sizeBytes, 3);
      expect(jia.formatId, 'txt');
      expect(jia.formatLabel, 'TXT');
      expect(jia.path, store.resolveFlatBookPath('甲', 'txt'));
      expect(orphans[1].formatId, 'epub');
    });

    test('全关联：主干全部命中 bookId 集合 → 空列表', () async {
      await bookFile('01A.txt', [1]);
      await bookFile('01B.epub', [2]);
      await insertBook('01A');
      await insertBook('01B');

      expect(await service.scan(), isEmpty);
    });

    test('混合：只有主干不在 bookId 集合的文件算游离', () async {
      await bookFile('01A.txt', [1]);
      await bookFile('孤儿.txt', [2]);
      await insertBook('01A');

      final orphans = await service.scan();
      expect(orphans, hasLength(1));
      expect(orphans.single.stem, '孤儿');
    });

    test('books 子目录不存在 → 空列表（不抛出）', () async {
      await Directory(p.join(store.booksDir.path)).delete(recursive: true);

      expect(await service.scan(), isEmpty);
    });

    test('非正文扩展名（无 handler）不进面板', () async {
      await bookFile('笔记.md', [1]); // md 未注册 handler
      await bookFile('垃圾.tmp', [2]); // 无 handler

      expect(await service.scan(), isEmpty);
    });

    test('分层目录残留：books/{bookId}/ 无书目 → 游离（书目缺失形态）', () async {
      final sub = Directory(p.join(store.booksDir.path, '01C'));
      await sub.create();
      await File(p.join(sub.path, 'source.txt')).writeAsBytes([1, 2, 3]);

      final orphans = await service.scan();
      expect(orphans, hasLength(1));
      final orphan = orphans.single;
      expect(orphan.stem, '01C');
      expect(orphan.shape, OrphanShape.layeredResidue);
      expect(orphan.shapeLabel, '书目缺失');
      expect(orphan.containerPath, sub.path);
      expect(orphan.path, p.join(sub.path, 'source.txt'));
      expect(orphan.sizeBytes, 3);
      expect(orphan.formatId, 'txt');
    });

    test('分层目录但书目仍在库 → 不算游离；目录内无正文文件 → 跳过', () async {
      await insertBook('01D');
      final linked = Directory(p.join(store.booksDir.path, '01D'));
      await linked.create();
      await File(p.join(linked.path, 'source.txt')).writeAsBytes([1]);
      final empty = Directory(p.join(store.booksDir.path, '01E'));
      await empty.create();
      await File(p.join(empty.path, 'notes.md')).writeAsBytes([2]); // 无 handler

      expect(await service.scan(), isEmpty);
    });

    test('orphans/ 区整书目录：剥时间戳后缀还原 bookId，本端删除形态', () async {
      final area = Directory(
        p.join(store.orphansDir.path, '01F-1698500000000'),
      );
      await area.create(recursive: true);
      await File(p.join(area.path, 'source.epub')).writeAsBytes([4, 5, 6, 7]);

      final orphans = await service.scan();
      expect(orphans, hasLength(1));
      final orphan = orphans.single;
      expect(orphan.stem, '01F');
      expect(orphan.shape, OrphanShape.orphanArea);
      expect(orphan.shapeLabel, '本端删除');
      expect(orphan.containerPath, area.path);
      expect(orphan.ext, 'epub');
      expect(orphan.formatId, 'epub');
      expect(orphan.sizeBytes, 4);
    });

    test('orphans/ 区：bookId 已在库 → 不算游离；非时间戳目录名 → 跳过', () async {
      await insertBook('01G');
      final linked = Directory(p.join(store.orphansDir.path, '01G-1000'));
      await linked.create();
      await File(p.join(linked.path, 'source.txt')).writeAsBytes([1]);
      final weird = Directory(p.join(store.orphansDir.path, '非时间戳目录'));
      await weird.create();
      await File(p.join(weird.path, 'source.txt')).writeAsBytes([2]);

      expect(await service.scan(), isEmpty);
    });

    test('orphans/ 区平铺文件（历史形态）也进面板；三形态混合排序稳定', () async {
      await bookFile('甲.txt', [1]); // 平铺
      final layered = Directory(p.join(store.booksDir.path, '01H'));
      await layered.create();
      await File(p.join(layered.path, 'source.txt')).writeAsBytes([2]); // 分层
      final area = Directory(p.join(store.orphansDir.path, '01I-42'));
      await area.create(recursive: true);
      await File(p.join(area.path, 'source.txt')).writeAsBytes([3]); // 游离区
      final areaFlat = File(p.join(store.orphansDir.path, '旧.txt'));
      await areaFlat.writeAsBytes([4]); // 游离区平铺（历史形态）

      final orphans = await service.scan();
      expect(orphans, hasLength(4));
      // 按展示名字典序（UTF-16 码元序：数字 < '旧' U+65E7 < '甲' U+7532）。
      expect(orphans.map((o) => o.fileName).toList(), [
        '01H',
        '01I-42',
        '旧.txt',
        '甲.txt',
      ]);
      expect(orphans.map((o) => o.shape).toSet(), {
        OrphanShape.layeredResidue,
        OrphanShape.orphanArea,
        OrphanShape.flat,
      });
    });
  });

  group('deleteOrphan（彻底删除，二次确认后由面板调用）', () {
    test('删除正文文件并顺带清理 covers/{stem}.png 残留', () async {
      final file = await bookFile('01A.txt', [1, 2, 3]);
      final cover = File(store.resolveCoverPath('01A'));
      await cover.writeAsBytes([9, 9]);

      await service.deleteOrphan(
        OrphanBookFile(
          path: file.path,
          fileName: '01A.txt',
          stem: '01A',
          ext: 'txt',
          sizeBytes: 3,
          formatId: 'txt',
        ),
      );

      expect(file.existsSync(), isFalse);
      expect(cover.existsSync(), isFalse);
    });

    test('无封面残留 / 文件已不存在时幂等通过', () async {
      final file = await bookFile('01A.txt', [1]);

      await service.deleteOrphan(
        OrphanBookFile(
          path: file.path,
          fileName: '01A.txt',
          stem: '01A',
          ext: 'txt',
          sizeBytes: 1,
          formatId: 'txt',
        ),
      );
      // 再删一次（文件已不在）：不抛出。
      await service.deleteOrphan(
        OrphanBookFile(
          path: file.path,
          fileName: '01A.txt',
          stem: '01A',
          ext: 'txt',
          sizeBytes: 1,
          formatId: 'txt',
        ),
      );
      expect(file.existsSync(), isFalse);
    });

    test('目录形态：递归删除容器目录 + 封面残留', () async {
      final area = Directory(p.join(store.orphansDir.path, '01J-7'));
      await area.create(recursive: true);
      final content = File(p.join(area.path, 'source.txt'));
      await content.writeAsBytes([1]);
      final cover = File(store.resolveCoverPath('01J'));
      await cover.writeAsBytes([9]);

      await service.deleteOrphan(
        OrphanBookFile(
          path: content.path,
          fileName: '01J-7',
          stem: '01J',
          ext: 'txt',
          sizeBytes: 1,
          formatId: 'txt',
          containerPath: area.path,
          shape: OrphanShape.orphanArea,
        ),
      );

      expect(area.existsSync(), isFalse);
      expect(cover.existsSync(), isFalse);
    });

    test('cleanupContainer：容器已空则移除；平铺形态无容器为 no-op', () async {
      final area = Directory(p.join(store.orphansDir.path, '01K-7'));
      await area.create(recursive: true);

      final orphan = OrphanBookFile(
        path: p.join(area.path, 'source.txt'),
        fileName: '01K-7',
        stem: '01K',
        ext: 'txt',
        sizeBytes: 1,
        formatId: 'txt',
        containerPath: area.path,
        shape: OrphanShape.orphanArea,
      );
      await service.cleanupContainer(orphan);
      expect(area.existsSync(), isFalse);
      // 再清一次（已不在）：不抛出。
      await service.cleanupContainer(orphan);

      // 平铺形态：无容器，no-op 不抛出。
      await service.cleanupContainer(
        OrphanBookFile(
          path: p.join(store.booksDir.path, 'x.txt'),
          fileName: 'x.txt',
          stem: 'x',
          ext: 'txt',
          sizeBytes: 1,
          formatId: 'txt',
        ),
      );
    });
  });
}
