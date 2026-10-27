import 'dart:io';

import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// BackendAdapter 契约测试套件类型（CLAUDE.md §4.4 / NFR-08）。
///
/// **同一套用例必须同时跑 WebDAV 与 REST 两个适配器**：M2 实现 WebDAV 适配器、
/// M3 实现 REST 适配器时，各自在 `test/contract/webdav_test.dart` /
/// `rest_test.dart` 中以工厂函数注入本套件，用例本身不得分叉。
///
/// 工厂返回的适配器应已完成 [BackendAdapter.connect]（CI 无网环境用
/// [InMemoryAdapter]）。
typedef AdapterFactory = Future<BackendAdapter> Function();

/// 执行契约套件（对齐 docs/04 §5/§7/§8 与 docs/06 §2 的 8 条用例清单 +
/// 2 条附加用例）。
void contractSuite(AdapterFactory make, {String tag = 'adapter'}) {
  group(tag, () {
    late BackendAdapter adapter;

    setUp(() async {
      adapter = await make();
    });

    test('1 ensureLayout 幂等：连跑两次，library.json 内容一致（docs/05 §1）', () async {
      await adapter.ensureLayout();
      final first = await adapter.readLibraryJson();
      await adapter.ensureLayout();
      final second = await adapter.readLibraryJson();
      expect(first, isNotNull);
      expect(second, same(first));
    });

    test('2 listMetas：空库返回空清单；写入 N 本后返回 N 条 stub（含 rev/etag）', () async {
      await adapter.ensureLayout();
      expect((await adapter.listMetas()).stubs, isEmpty);
      for (var i = 1; i <= 3; i++) {
        await adapter.putMeta(
          buildMeta(bookId: bookIdOf(i), rev: 1),
          expectedRev: 0,
        );
      }
      final listing = await adapter.listMetas();
      expect(listing.stubs.length, 3);
      for (final stub in listing.stubs.values) {
        expect(stub.rev, 1, reason: 'stub 必须携带 rev');
        expect(stub.etag, isNotNull, reason: 'stub 必须携带 etag');
      }
    });

    test('3 getMeta 条件请求：ifNoneMatch 命中返回 null（304 语义）', () async {
      await adapter.ensureLayout();
      await adapter.putMeta(
        buildMeta(bookId: bookIdOf(1), rev: 2),
        expectedRev: 0,
      );
      final etag = (await adapter.listMetas()).stubs[bookIdOf(1)]!.etag!;
      // 内容未变 → 304（null）。
      expect(await adapter.getMeta(bookIdOf(1), ifNoneMatch: etag), isNull);
      // 内容变更后同一 etag → 不再命中。
      await adapter.putMeta(
        buildMeta(bookId: bookIdOf(1), rev: 3),
        expectedRev: 2,
      );
      final got = await adapter.getMeta(bookIdOf(1), ifNoneMatch: etag);
      expect(got?.rev, 3);
    });

    test(
      '4 putMeta 乐观锁：expectedRev 落后时抛 RevConflict 且携带服务端副本（docs/06 §2.2）',
      () async {
        await adapter.ensureLayout();
        await adapter.putMeta(
          buildMeta(bookId: bookIdOf(1), rev: 1),
          expectedRev: 0,
        );
        await adapter.putMeta(
          buildMeta(bookId: bookIdOf(1), rev: 2),
          expectedRev: 1,
        );
        expect(
          () => adapter.putMeta(
            buildMeta(bookId: bookIdOf(1), rev: 3),
            expectedRev: 1,
          ),
          throwsA(
            isA<RevConflict>()
                .having((e) => e.remoteRev, 'remoteRev', 2)
                .having((e) => e.remoteMeta?.rev, 'remoteMeta.rev', 2),
          ),
        );
      },
    );

    test(
      '5 putTombstone：清单仍含该书且 getMeta 读回 deleted=true（docs/04 §7）',
      () async {
        await adapter.ensureLayout();
        final meta = buildMeta(bookId: bookIdOf(1), rev: 1);
        await adapter.putMeta(meta, expectedRev: 0);
        final tomb = meta.toTombstone(
          deletedAt: t0.add(const Duration(hours: 1)),
          deviceId: '01DEVA000000000000',
          deviceName: 'DeviceA',
        );
        await adapter.putTombstone(tomb, expectedRev: 1);
        // 双端公共真值：tombstone 对清单可见（bookId 不消失）、内容可读回。
        // RemoteMetaStub.deleted 仅在清单阶段即可确知的后端（内存/REST）为 true；
        // WebDAV 的 PROPFIND 无法感知内容级删除标记（恒 false），tombstone 的
        // 权威判定在 getMeta 内容，引擎以拉取阶段 + 本地账本兜底（docs/04 §7.3）。
        final listing = await adapter.listMetas();
        expect(listing.stubs.keys, contains(bookIdOf(1)));
        final read = await adapter.getMeta(bookIdOf(1));
        expect(read?.isTombstone, isTrue);
        expect(read?.deletedAt, isNotNull);
        // 对能确知的实现，摘要不撒谎（内存/REST=true；WebDAV 恒 false 也合法）。
        final stub = listing.stubs[bookIdOf(1)]!;
        if (stub.deleted) {
          expect(read?.deleted, isTrue);
        }
      },
    );

    test('6 uploadBook 幂等：同 hash 二次上传跳过；hash 不符报错（docs/04 §5.3）', () async {
      await adapter.ensureLayout();
      final dir = await Directory.systemTemp.createTemp('sync_core_contract');
      addTearDown(() => dir.delete(recursive: true));
      final bytes = deterministicBytes(64, 42);
      final (file, hash) = await writeTempContent(dir, 'a.txt', bytes);
      await adapter.uploadBook(bookIdOf(1), file, hash);
      // 同 hash 二次上传 → 幂等跳过（无异常）。
      await adapter.uploadBook(bookIdOf(1), file, hash);
      // 声明 hash 与内容不符 → 报错。
      final (badFile, _) = await writeTempContent(dir, 'b.txt', [9, 9, 9]);
      expect(
        () => adapter.uploadBook(bookIdOf(1), badFile, hash),
        throwsA(isA<ContentHashMismatch>()),
      );
      // 远端已存在不同版本内容 → 报错。
      final (other, otherHash) = await writeTempContent(dir, 'c.txt', [
        7,
        7,
        7,
      ]);
      expect(
        () => adapter.uploadBook(bookIdOf(1), other, otherHash),
        throwsA(isA<ContentHashMismatch>()),
      );
    });

    test(
      '7 downloadBook Range：startByte 续传字节流与原文件后缀一致（docs/04 §8.2）',
      () async {
        await adapter.ensureLayout();
        final dir = await Directory.systemTemp.createTemp('sync_core_contract');
        addTearDown(() => dir.delete(recursive: true));
        final bytes = deterministicBytes(100, 9);
        final (file, hash) = await writeTempContent(dir, 'book.txt', bytes);
        await adapter.uploadBook(bookIdOf(1), file, hash);

        final suffix = await adapter
            .downloadBook(bookIdOf(1), startByte: 40)
            .toList();
        final flat = suffix.expand((c) => c).toList();
        expect(flat, bytes.sublist(40), reason: 'Range 续传必须与原文件后缀一致');

        final whole = await adapter.downloadBook(bookIdOf(1)).toList();
        expect(whole.expand((c) => c).toList(), bytes);
      },
    );

    test('8 并发写不同书互不冲突（同书并发由调用方串行化）', () async {
      await adapter.ensureLayout();
      await Future.wait([
        for (var i = 1; i <= 4; i++)
          adapter.putMeta(
            buildMeta(bookId: bookIdOf(i), rev: 1),
            expectedRev: 0,
          ),
      ]);
      expect((await adapter.listMetas()).stubs.length, 4);
    });

    test('附加：ensureLayout 后 library.json 存在（readLibraryJson 非 null）', () async {
      expect(await adapter.readLibraryJson(), isNull);
      await adapter.ensureLayout();
      final lib = await adapter.readLibraryJson();
      expect(lib, isNotNull);
      expect(lib, contains('libraryId'));
    });

    test('附加：deleteMeta 后 listMetas 不再含该书（docs/04 §7.3 GC 专用）', () async {
      await adapter.ensureLayout();
      await adapter.putMeta(
        buildMeta(bookId: bookIdOf(1), rev: 1),
        expectedRev: 0,
      );
      expect(
        (await adapter.listMetas()).stubs,
        containsPair(bookIdOf(1), isNotNull),
      );
      await adapter.deleteMeta(bookIdOf(1));
      expect(
        (await adapter.listMetas()).stubs.keys,
        isNot(contains(bookIdOf(1))),
      );
    });

    test(
      '附加：listBookFiles 空清单 / uploadBook 后出现在清单（docs/04 §7.1 规则 4）',
      () async {
        await adapter.ensureLayout();
        expect(await adapter.listBookFiles(), isEmpty);

        final dir = await Directory.systemTemp.createTemp('sync_core_contract');
        addTearDown(() => dir.delete(recursive: true));
        final bytesA = deterministicBytes(32, 5);
        final (fileA, hashA) = await writeTempContent(dir, 'a.txt', bytesA);
        await adapter.uploadBook(bookIdOf(1), fileA, hashA);
        final bytesB = deterministicBytes(24, 6);
        final (fileB, hashB) = await writeTempContent(dir, 'b.epub', bytesB);
        await adapter.uploadBook(bookIdOf(2), fileB, hashB);

        final files = await adapter.listBookFiles();
        expect(files, hasLength(2));
        final byName = {for (final f in files) f.name: f};
        expect(byName['${bookIdOf(1)}.txt']?.sizeBytes, bytesA.length);
        expect(byName['${bookIdOf(2)}.epub']?.sizeBytes, bytesB.length);
      },
    );

    test('附加：deleteBookFile 删除生效且重复删除幂等（docs/04 §7.1 规则 4）', () async {
      await adapter.ensureLayout();
      final dir = await Directory.systemTemp.createTemp('sync_core_contract');
      addTearDown(() => dir.delete(recursive: true));
      final (file, hash) = await writeTempContent(dir, 'a.txt', [1, 2, 3]);
      await adapter.uploadBook(bookIdOf(1), file, hash);

      await adapter.deleteBookFile('${bookIdOf(1)}.txt');
      expect(await adapter.listBookFiles(), isEmpty, reason: '删除后清单为空');
      // 二次删除（404）：幂等成功，不抛异常。
      await adapter.deleteBookFile('${bookIdOf(1)}.txt');
    });

    test(
      '附加：uploadBook overwrite=true 覆盖远端不同版本；overwrite=false 保留既有报错语义（FR-410）',
      () async {
        await adapter.ensureLayout();
        final dir = await Directory.systemTemp.createTemp('sync_core_contract');
        addTearDown(() => dir.delete(recursive: true));
        final bytesA = deterministicBytes(32, 7);
        final (fileA, hashA) = await writeTempContent(dir, 'a.txt', bytesA);
        await adapter.uploadBook(bookIdOf(1), fileA, hashA);

        // overwrite=false（默认）：远端已有不同版本 → ContentHashMismatch（回归）。
        final bytesB = deterministicBytes(40, 8);
        final (fileB, hashB) = await writeTempContent(dir, 'b.txt', bytesB);
        expect(
          () => adapter.uploadBook(bookIdOf(1), fileB, hashB),
          throwsA(isA<ContentHashMismatch>()),
        );

        // overwrite=true：显式替换，直接覆盖远端文件。
        await adapter.uploadBook(bookIdOf(1), fileB, hashB, overwrite: true);
        final got = await adapter.downloadBook(bookIdOf(1)).toList();
        expect(got.expand((c) => c).toList(), bytesB, reason: '远端正文已变为新版本');
      },
    );
  });
}
