import 'dart:io';
import 'dart:math';

import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/flaky_adapter.dart';

/// docs/04 §8.4 重试策略全表逐行 + Range 续传 / 哈希校验 / 字节计量。
void main() {
  late Directory tempDir;
  late InMemoryAdapter memory;
  late FlakyAdapter adapter;
  late TransferQueue queue;
  final delays = <Duration>[];

  Future<(File, String)> uploadFixture(String bookId, List<int> bytes) async {
    memory.putContent(bookId, 'txt', bytes);
    final (file, hash) = await writeTempContent(tempDir, '$bookId.txt', bytes);
    return (file, hash);
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sync_core_transfer');
    addTearDown(() => tempDir.delete(recursive: true));
    memory = InMemoryAdapter();
    await memory.connect(
      const BackendConfig(kind: BackendKind.webdav, baseUrl: 'memory://'),
    );
    adapter = FlakyAdapter(memory);
    delays.clear();
    queue = TransferQueue(
      adapter: adapter,
      retryPolicy: const RetryPolicy(),
      jitterRandom: Random(42),
      delay: (d) async => delays.add(d),
    );
  });

  group('docs/04 §8.4 重试策略', () {
    test('网络失败：指数退避 1s→2s→4s，±20% 抖动容差', () async {
      final bytes = deterministicBytes(32, 3);
      final (file, hash) = await uploadFixture(bookIdOf(1), bytes);
      // 上传连续失败 3 次（网络类）后放行。
      adapter.uploadFailures.addAll([
        () => const BackendRequestException('连接超时'),
        () => const BackendRequestException('DNS 解析失败'),
        () => const BackendRequestException('连接被重置'),
      ]);
      await queue.uploadFile(
        bookIdOf(1),
        filePath: file.path,
        contentHash: hash,
      );

      expect(delays.length, 3);
      void inTolerance(Duration actual, Duration base) {
        final low = base * 0.8;
        final high = base * 1.2;
        expect(
          actual >= low && actual <= high,
          isTrue,
          reason: '期望 $base ±20%，实际 $actual',
        );
      }

      inTolerance(delays[0], const Duration(seconds: 1));
      inTolerance(delays[1], const Duration(seconds: 2));
      inTolerance(delays[2], const Duration(seconds: 4));
      expect(adapter.uploadAttempts, 4);
    });

    test('连续 5 次网络失败 → 本轮放弃，抛 NetworkUnreachable', () async {
      final (file, hash) = await uploadFixture(bookIdOf(1), [1]);
      adapter.uploadFailures.addAll([
        for (var i = 0; i < 6; i++)
          () => const BackendRequestException('网络不可达'),
      ]);
      await expectLater(
        queue.uploadFile(bookIdOf(1), filePath: file.path, contentHash: hash),
        throwsA(isA<NetworkUnreachable>()),
      );
      expect(adapter.uploadAttempts, 5, reason: '第 5 次失败即放弃');
      expect(delays.length, 4, reason: '放弃后不再退避');
    });

    test('HTTP 429 带 Retry-After：优先尊重该头（精确等待，无抖动）', () async {
      final (file, hash) = await uploadFixture(bookIdOf(1), [2]);
      adapter.uploadFailures.addAll([
        () => const BackendRequestException(
          '限流',
          statusCode: 429,
          retryAfter: Duration(seconds: 77),
        ),
      ]);
      await queue.uploadFile(
        bookIdOf(1),
        filePath: file.path,
        contentHash: hash,
      );
      expect(delays, [const Duration(seconds: 77)]);
    });

    test('HTTP 429 无 Retry-After 头 → 固定等待 60s', () async {
      final (file, hash) = await uploadFixture(bookIdOf(1), [3]);
      adapter.uploadFailures.addAll([
        () => const BackendRequestException('限流', statusCode: 429),
      ]);
      await queue.uploadFile(
        bookIdOf(1),
        filePath: file.path,
        contentHash: hash,
      );
      expect(delays, [const Duration(seconds: 60)]);
    });

    test('503 与 429 同策略：尊重 Retry-After / 无头 60s', () async {
      final (file, hash) = await uploadFixture(bookIdOf(1), [4]);
      adapter.uploadFailures.addAll([
        () => const BackendRequestException('维护中', statusCode: 503),
      ]);
      await queue.uploadFile(
        bookIdOf(1),
        filePath: file.path,
        contentHash: hash,
      );
      expect(delays, [const Duration(seconds: 60)]);
    });

    test('401 → AuthFailed 立即失败，不重试', () async {
      final (file, hash) = await uploadFixture(bookIdOf(1), [5]);
      adapter.uploadFailures.add(() => const AuthFailed('401 未授权'));
      await expectLater(
        queue.uploadFile(bookIdOf(1), filePath: file.path, contentHash: hash),
        throwsA(isA<AuthFailed>()),
      );
      expect(adapter.uploadAttempts, 1, reason: '不重试');
      expect(delays, isEmpty);
    });

    test('5xx → 指数退避且最多重试 3 次，随后抛 ServerError', () async {
      final (file, hash) = await uploadFixture(bookIdOf(1), [6]);
      adapter.uploadFailures.addAll([
        for (var i = 0; i < 5; i++)
          () => const BackendRequestException('内部错误', statusCode: 500),
      ]);
      await expectLater(
        queue.uploadFile(bookIdOf(1), filePath: file.path, contentHash: hash),
        throwsA(
          isA<ServerError>().having((e) => e.statusCode, 'statusCode', 500),
        ),
      );
      expect(adapter.uploadAttempts, 4, reason: '首次 + 3 次重试');
      expect(delays.length, 3);
    });

    test('409/412/428（RevConflict）不进重试队列，原样上抛由引擎合并', () async {
      final (file, hash) = await uploadFixture(bookIdOf(1), [7]);
      adapter.uploadFailures.add(() => RevConflict(bookIdOf(1), 2, null));
      await expectLater(
        queue.uploadFile(bookIdOf(1), filePath: file.path, contentHash: hash),
        throwsA(isA<RevConflict>()),
      );
      expect(adapter.uploadAttempts, 1, reason: '冲突不重试');
      expect(delays, isEmpty);
    });
  });

  group('Range 断点续传（docs/04 §5.4 / §8.2）', () {
    test('下载中断 → 从 .part 已有长度 Range 续传 → 内容完整', () async {
      final bytes = deterministicBytes(100, 11);
      memory.putContent(bookIdOf(2), 'txt', bytes);
      adapter.failDownloadAfterBytes = 40; // 第一次下载 40 字节后断网

      final target = '${tempDir.path}/out.txt';
      final part = '${tempDir.path}/out.txt.part';
      await queue.downloadToFile(
        bookIdOf(2),
        targetPath: target,
        partPath: part,
        expectedHash: contentHashOf(bytes),
        expectedSize: bytes.length,
      );

      expect(adapter.downloadStartBytes, [null, 40], reason: '第二次从已有 40 字节续传');
      expect(File(part).existsSync(), isFalse, reason: '转正后 .part 消失');
      expect(File(target).readAsBytesSync(), bytes);
      expect(delays.length, 1, reason: '断网失败按网络类重试一次');
    });

    test('哈希不符 → 删除 .part 从头重来 → 2 次重试后抛 Corruption', () async {
      final wrongBytes = deterministicBytes(50, 12);
      memory.putContent(bookIdOf(3), 'txt', wrongBytes); // 云端内容始终与期望不符
      final expectedHash = contentHashOf(deterministicBytes(50, 99));

      final target = '${tempDir.path}/bad.txt';
      final part = '${tempDir.path}/bad.txt.part';
      await expectLater(
        queue.downloadToFile(
          bookIdOf(3),
          targetPath: target,
          partPath: part,
          expectedHash: expectedHash,
          expectedSize: 50,
        ),
        throwsA(isA<Corruption>()),
      );

      expect(adapter.downloadStartBytes, [
        null,
        null,
        null,
      ], reason: '每次校验失败都删 .part 从头下载（1 + 2 次重试）');
      expect(File(part).existsSync(), isFalse, reason: '失败后不留脏 .part');
      expect(File(target).existsSync(), isFalse, reason: '校验不过不转正');
    });

    test('尺寸不符 → 与哈希同策略：删除重来，重试耗尽 Corruption', () async {
      memory.putContent(bookIdOf(4), 'txt', [1, 2, 3]);
      final target = '${tempDir.path}/size.txt';
      await expectLater(
        queue.downloadToFile(
          bookIdOf(4),
          targetPath: target,
          partPath: '$target.part',
          expectedHash: contentHashOf([1, 2, 3]),
          expectedSize: 999, // 与实际尺寸不符
        ),
        throwsA(isA<Corruption>()),
      );
    });
  });

  group('并发与计量（docs/03 §4.3 / docs/04 §8.3）', () {
    test('下载并发上限 2：峰值不超过且能打满', () async {
      adapter.getMetaDelay = const Duration(milliseconds: 5);
      for (var i = 1; i <= 5; i++) {
        memory.putContent(bookIdOf(i), 'txt', deterministicBytes(16, i));
      }
      await Future.wait([
        for (var i = 1; i <= 5; i++)
          queue.downloadToFile(
            bookIdOf(i),
            targetPath: '${tempDir.path}/d$i.bin',
            partPath: '${tempDir.path}/d$i.bin.part',
          ),
      ]);
      expect(queue.peakDownloads, 2, reason: '下载并发打满且不超过 2');
    });

    test('上传并发上限 1', () async {
      for (var i = 1; i <= 3; i++) {
        await uploadFixture(bookIdOf(i), deterministicBytes(8, i + 20));
      }
      await Future.wait([
        for (var i = 1; i <= 3; i++)
          queue.uploadFile(
            bookIdOf(i),
            filePath: '${tempDir.path}/${bookIdOf(i)}.txt',
            contentHash: contentHashOf(deterministicBytes(8, i + 20)),
          ),
      ]);
      expect(queue.peakUploads, 1);
    });

    test('字节计量钩子：下载/上传各按实际字节累加', () async {
      final events = <(TransferDirection, int)>[];
      queue.onBytes = (dir, bytes) => events.add((dir, bytes));

      final bytes = deterministicBytes(64, 33);
      memory.putContent(bookIdOf(9), 'txt', bytes);
      await queue.downloadToFile(
        bookIdOf(9),
        targetPath: '${tempDir.path}/m.bin',
        partPath: '${tempDir.path}/m.bin.part',
      );
      final (file, hash) = await writeTempContent(tempDir, 'up.bin', bytes);
      await queue.uploadFile(
        bookIdOf(10),
        filePath: file.path,
        contentHash: hash,
      );

      final down = events
          .where((e) => e.$1 == TransferDirection.download)
          .fold<int>(0, (sum, e) => sum + e.$2);
      final up = events
          .where((e) => e.$1 == TransferDirection.upload)
          .fold<int>(0, (sum, e) => sum + e.$2);
      expect(down, 64);
      expect(up, 64);
      expect(queue.bytesByDirection[TransferDirection.download], 64);
      expect(queue.bytesByDirection[TransferDirection.upload], 64);
    });

    test('配额闸门拒绝 → 抛 QuotaExceeded 且不发起下载', () async {
      var allowed = 0;
      final gated = TransferQueue(
        adapter: adapter,
        retryPolicy: const RetryPolicy(),
        delay: (d) async {},
        quotaGate: (estimated) {
          allowed++;
          return false;
        },
      );
      memory.putContent(bookIdOf(1), 'txt', [1, 2, 3]);
      await expectLater(
        gated.downloadToFile(
          bookIdOf(1),
          targetPath: '${tempDir.path}/q.bin',
          partPath: '${tempDir.path}/q.bin.part',
          expectedSize: 3,
        ),
        throwsA(isA<QuotaExceeded>()),
      );
      expect(allowed, 1);
      expect(adapter.downloadStartBytes, isEmpty, reason: '闸门拒绝则不发起请求');
    });
  });
}
