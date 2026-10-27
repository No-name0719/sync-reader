/// 坚果云"缺失目录 PROPFIND 返回 409"画像的适配器回归（R3 实测 2026-10-27：
/// 对不存在目录的 PROPFIND 回 409 Conflict 而非标准 404——connect 的根探测、
/// ensureLayout 的子目录探测与 listMetas 清单都必须容忍，见
/// `WebDavAdapter._isMissingStatus`）。
///
/// 用内存服务器 `propfindMissingStatus: 409` 复现画像，无需真实凭据。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

import '../support/memory_webdav_server.dart';

void main() {
  test(
    '坚果云画像（缺失目录 PROPFIND=409）：connect/ensureLayout/listMetas/上传全链路可用',
    () async {
      final server = await MemoryWebDavServer.start(propfindMissingStatus: 409);
      addTearDown(server.close);

      final adapter = WebDavAdapter();
      addTearDown(adapter.dispose);
      await adapter.connect(
        BackendConfig(
          kind: BackendKind.webdav,
          baseUrl: server.uri.toString(),
          username: server.username,
          password: server.password,
          rootPath: '/Apps/SyncReader',
        ),
      );
      // connect 的根探测：全新根 → PROPFIND 409 → 不算失败。
      await adapter.ensureLayout();
      final listing = await adapter.listMetas();
      expect(listing.stubs, isEmpty, reason: '409 视为缺失 → 空清单而非报错');

      // 409 画像下走一遍完整的写读删。
      final meta = _sampleMeta();
      await adapter.putMeta(meta, expectedRev: 0);
      expect((await adapter.getMeta(meta.bookId))!.rev, 1);
      expect((await adapter.listMetas()).stubs.keys, contains(meta.bookId));

      final dir = await Directory.systemTemp.createTemp('sync_core_409');
      addTearDown(() => dir.delete(recursive: true));
      final bytes = List<int>.generate(64, (i) => i);
      final file = File('${dir.path}/a.txt')..writeAsBytesSync(bytes);
      await adapter.uploadBook(
        meta.bookId,
        file,
        'sha256:${sha256.convert(bytes).toString()}',
      );
      final round = <int>[];
      await for (final chunk in adapter.downloadBook(meta.bookId)) {
        round.addAll(chunk);
      }
      expect(round, bytes);
      await adapter.deleteMeta(meta.bookId);
      expect(await adapter.getMeta(meta.bookId), isNull);
    },
  );
}

BookMeta _sampleMeta() {
  final now = DateTime.now().toUtc();
  return BookMeta(
    schemaVersion: kCurrentSchemaVersion,
    bookId:
        '01TEST409${now.microsecondsSinceEpoch.toRadixString(36).toUpperCase().padLeft(9, '0')}',
    rev: 1,
    deviceId: '01TEST409DEVICE0',
    deviceName: 'regression',
    createdAt: now,
    updatedAt: now,
    book: BookInfo(
      title: '409 回归书',
      author: '',
      format: 'txt',
      fileName: 'a.txt',
      contentHash:
          'sha256:${sha256.convert(List<int>.generate(64, (i) => i)).toString()}',
      sizeBytes: 64,
      tocFingerprint: 'tfp:409',
    ),
    reading: ReadingStats(totalSeconds: 0, lastReadAt: now),
  );
}
