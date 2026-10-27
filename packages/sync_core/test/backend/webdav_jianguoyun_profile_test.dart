/// 坚果云真实环境画像 + 双端收敛 FR-404 预演（R3 联调专项）。
///
/// 凭据从仓库根 `.secrets/jianguoyun.txt`（三行：baseUrl/账号/应用密码，
/// git-ignore）或 `SYNC_WEBDAV_*` 环境变量读取；缺失时跳过（CI 无凭据）。
/// 本地执行：
/// ```
/// cd packages/sync_core && dart run tool/jianguoyun_probe.dart   # 画像摘要
/// dart test test/backend/webdav_jianguoyun_profile_test.dart     # 本测试
/// ```
///
/// 断言值来自 2026-10-27 对坚果云 WebDAV（dav.jianguoyun.com）的实测画像：
/// - ETag：22 位类 base64 无引号（样本 `-HlIbSSX99X6T8eQBV8Xuw`），**非
///   MD5 hex**——上传查重的"etag=32hex 免下载"快速路径不触发，走
///   尺寸比对/下载比对收尾（已有用例覆盖）；
/// - **PUT 不回带 ETag**：两级清单的 etag→rev 缓存写后无法从 PUT 回填，
///   该书的下次清单补拉一次 meta（KB 级，可接受）；
/// - If-None-Match 命中 → 304；MOVE → 201；Range → 206 + Content-Range；
/// - **MKCOL 既有目录 → 201**（非标准 405；幂等语义不变）；
/// - **PROPFIND 缺失目录 → 409**（非 404；见
///   `webdav_missing_dir_409_test.dart` 的离线回归）；
/// - PROPFIND 用小写 `d:` 前缀；gzip 未启用（恒明文）。
///
/// 第二个 group 用两套独立引擎（各自 store/library/adapter）共享真实云端，
/// 预演 FR-404：A 导入 → 同步 → B 占位 → B 离线读 75% / A 读 65% →
/// 恢复后收敛到 75% 且 totalSeconds 求和特例正确；结束清理云端探针产物。
library;

import 'dart:convert';
import 'dart:io';

import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../../tool/jianguoyun_probe.dart';

void main() {
  final credentials = WebDavCredentials.load();
  if (credentials == null) {
    test('坚果云画像（需凭据）', () {
      markTestSkipped(
        '需 `.secrets/jianguoyun.txt` 或 SYNC_WEBDAV_* 环境变量（R3 联调）',
      );
    });
    return;
  }

  group('坚果云画像（v1 实测基线 2026-10-27）', () {
    test('能力与响应特征', () async {
      final summary = await runJianguoyunProbe(credentials);

      expect(summary.checks['connect'], contains('OK'));
      expect(summary.checks['ensureLayout'], contains('OK'));
      // ETag：有、形态为坚果云特征（非引号强 ETag、非 rclone 风格）。
      expect(summary.etagHeader, isNotNull);
      expect(summary.etagFormat, isNot(contains('MD5')));
      // 条件请求与原子提交。
      expect(summary.supports304, isTrue, reason: 'If-None-Match 应命中 304');
      expect(summary.supportsMove, isTrue, reason: 'MOVE 应成功（tmp→MOVE 上传）');
      expect(summary.moveStatus, inInclusiveRange(200, 299));
      // 断点续传。
      expect(summary.supportsRange, isTrue);
      expect(summary.contentRangeSample, matches(RegExp(r'^bytes 0-0/\d+$')));
      // 坚果云特征：PUT 不回带 ETag；MKCOL 既有 = 201；PROPFIND 小写 d:。
      expect(summary.putEtagHeader, isNull);
      expect(summary.mkcolExistingStatus, anyOf(201, 405));
      expect(summary.propfindPrefixStyle, contains('d:'));
      // 适配器自探测：三能力全开。
      expect(summary.capabilities.supportsMove, isTrue);
      expect(summary.capabilities.supportsEtag, isTrue);
      expect(summary.capabilities.supportsRange, isTrue);
      // 功能面无失败（探针内部逐项校验）。
      expect(summary.checks['GET meta'], contains('OK'));
      expect(summary.checks['tmp→MOVE 上传'], contains('OK'));
      expect(summary.checks['Range 续传（适配器）'], contains('OK'));
      expect(summary.checks['DELETE'], contains('OK'));
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('双端收敛 FR-404（真实坚果云预演）', () {
    late WebDavAdapter adapterA;
    late WebDavAdapter adapterB;
    late InMemorySyncStore storeA;
    late InMemorySyncStore storeB;
    late InMemoryLocalLibrary libraryA;
    late InMemoryLocalLibrary libraryB;
    late SyncEngine engineA;
    late SyncEngine engineB;
    late Directory tmpA;
    late Directory tmpB;
    final bookId =
        '01JGYCONV${DateTime.now().microsecondsSinceEpoch.toRadixString(36).toUpperCase().padLeft(9, '0')}';

    setUp(() async {
      tmpA = await Directory.systemTemp.createTemp('syncr_jgy_dev_a');
      tmpB = await Directory.systemTemp.createTemp('syncr_jgy_dev_b');
      BackendConfig config() => BackendConfig(
        kind: BackendKind.webdav,
        baseUrl: credentials.baseUrl,
        username: credentials.account,
        password: credentials.password,
        rootPath: '/Apps/SyncReader',
      );
      adapterA = WebDavAdapter();
      adapterB = WebDavAdapter();
      await adapterA.connect(config());
      await adapterB.connect(config());
      storeA = InMemorySyncStore();
      storeB = InMemorySyncStore();
      libraryA = InMemoryLocalLibrary(tmpA);
      libraryB = InMemoryLocalLibrary(tmpB);
      SyncEngine make(
        BackendAdapter adapter,
        SyncStore store,
        LocalLibrary library,
        String id,
        String name,
      ) => SyncEngine(
        adapter: adapter,
        store: store,
        library: library,
        transfer: TransferQueue(
          adapter: adapter,
          retryPolicy: const RetryPolicy(),
        ),
        now: DateTime.now,
        identity: () async => (deviceId: id, deviceName: name),
        backendKey: 'webdav',
      );
      engineA = make(adapterA, storeA, libraryA, '01JGYDEVA00000000000', '设备A');
      engineB = make(adapterB, storeB, libraryB, '01JGYDEVB00000000000', '设备B');
    });

    tearDown(() async {
      // 清理云端探针产物（tombstone meta + 正文 + 正文孤儿）。
      try {
        await adapterA.deleteMeta(bookId);
        final resp = await HttpClient().openUrl(
          'DELETE',
          Uri.parse('${credentials.baseUrl}/Apps/SyncReader/books/$bookId.txt'),
        );
        final auth = base64Encode(
          utf8.encode('${credentials.account}:${credentials.password}'),
        );
        resp.headers.set(HttpHeaders.authorizationHeader, 'Basic $auth');
        await resp.close();
      } on Exception {
        // 尽力清理。
      }
      await tmpA.delete(recursive: true).catchError((Object _) => tmpA);
      await tmpB.delete(recursive: true).catchError((Object _) => tmpB);
    });

    test('A 导入 → B 占位 → 双端离线分叉 65%/75% → 收敛到 75%', () async {
      // A 导入并上架。
      final content = List<int>.generate(2048, (i) => i % 251);
      final (file, hash) = await writeTempContent(tmpA, '$bookId.src', content);
      await libraryA.importLocalBook(
        bookId: bookId,
        title: '收敛预演书',
        format: 'txt',
        contentHash: hash,
        sizeBytes: content.length,
        sourceFile: file,
      );
      await libraryA.updateProgress(
        bookId,
        progress: ReadingProgress(
          locator: const TxtLocator(chapterIndex: 3, charOffset: 120),
          percent: 0.40,
          updatedAt: DateTime.now(),
        ),
        totalSeconds: 150,
        lastReadAt: DateTime.now(),
      );
      final reportA1 = await engineA.fullSync();
      expect(reportA1.success, isTrue, reason: '${reportA1.results}');

      // B 拉到占位书。
      final reportB1 = await engineB.fullSync();
      expect(reportB1.success, isTrue, reason: '${reportB1.results}');
      final placeholder = await libraryB.book(bookId);
      expect(placeholder, isNotNull);
      expect(placeholder!.hasLocalContent, isFalse, reason: '应为占位');

      // B 下载正文后离线读到 75%。
      await engineB.downloadContent(bookId);
      await libraryB.updateProgress(
        bookId,
        progress: ReadingProgress(
          locator: const TxtLocator(chapterIndex: 7, charOffset: 900),
          percent: 0.75,
          updatedAt: DateTime.now(),
        ),
        totalSeconds: 180,
        lastReadAt: DateTime.now(),
      );

      // A（不知 B 的存在）读到 65%。
      await libraryA.updateProgress(
        bookId,
        progress: ReadingProgress(
          locator: const TxtLocator(chapterIndex: 5, charOffset: 500),
          percent: 0.65,
          updatedAt: DateTime.now(),
        ),
        totalSeconds: 170,
        lastReadAt: DateTime.now(),
      );

      // 恢复"网络"（真实网络一直在线；语义上模拟双方先后同步）。
      final reportB2 = await engineB.fullSync(); // B 先推 75%
      expect(reportB2.success, isTrue, reason: '${reportB2.results}');
      final reportA2 = await engineA.fullSync(); // A 拉远端 75% → 合并
      expect(reportA2.success, isTrue, reason: '${reportA2.results}');
      final reportA3 = await engineA.fullSync(); // A 推合并结果
      expect(reportA3.success, isTrue, reason: '${reportA3.results}');
      final reportB3 = await engineB.fullSync(); // B 拉合并结果 → 收敛
      expect(reportB3.success, isTrue, reason: '${reportB3.results}');

      // 两端收敛到同一进度（75%），时长求和特例（150+130−公共祖先 150=130？
      // 公共祖先是 B 拉取时的 150 → B 合并后 130+150−150=130，A 合并同理）。
      final aMeta = await libraryA.book(bookId);
      final bMeta = await libraryB.book(bookId);
      expect(aMeta, isNotNull);
      expect(bMeta, isNotNull);
      expect(aMeta!.meta!.progress!.percent, 0.75, reason: 'A 收敛到 B 的 75%');
      expect(bMeta!.meta!.progress!.percent, 0.75);
      expect(
        aMeta.meta!.reading.totalSeconds,
        bMeta.meta!.reading.totalSeconds,
        reason: '两端时长一致',
      );
      // 最终一致：再各跑一轮全量，无新动作。
      final aFinal = await engineA.fullSync();
      final bFinal = await engineB.fullSync();
      expect(aFinal.success, isTrue);
      expect(bFinal.success, isTrue);
    }, timeout: const Timeout(Duration(minutes: 8)));
  });
}
