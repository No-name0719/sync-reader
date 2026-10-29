/// 同步设置页「未上传的书」卡与「云端书库」卡 widget 测试（A12/Q17）：
///
/// 1. 注入 1 本仅本地书 + 1 个游离文件 → 两行都出现（分组「仅本地的书」
///    /「游离文件」）；
/// 2. 点仅本地行「上传到云端」→ 真实门面 `uploadToCloud` 被调（真实门面 +
///    已配置凭据 + InMemoryAdapter，批 3 做法）：行消失 + 云端有 meta；
/// 3. 点游离文件行「上传到云端」→ contentHash 挂回书库（FR-408）+ 全量同步
///    上架：云端出现新书，游离行消失；
/// 4. 「全部上传」逐本上传后汇总提示；
/// 5. 云端书库卡：配置 + 内存适配器 2 本 → 显示 2。
///
/// 真实 IO 分区约定（同 placeholder_download_cover_test / orphan_files_page_test）：
/// fixture 准备与「条件等待」包在 `tester.runAsync` 窗口（真实事件循环处理
/// IO 完成），窗口内的假区续体由 `tester.pump()` 排空——[waitUntil] 交替
/// 执行两者；收尾先排空 drift 定时器再在真实区关库（页面 watch 了 drift 流，
/// 直接 close 会挂起）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_core/sync_core.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/core/design_tokens.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/features/library/orphan/orphan_book_file.dart';
import 'package:sync_reader/features/library/orphan/orphan_file_service.dart';
import 'package:sync_reader/features/library/orphan/orphan_panel_controller.dart';
import 'package:sync_reader/features/sync/pages/sync_settings_page.dart';
import 'package:sync_reader/features/sync/sync_status.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';

void main() {
  AppDatabase? db;
  InMemoryCredentialStore? credentials;
  InMemoryAdapter? adapter;
  Directory? tmpDir;
  BookFileStore? fileStore;

  /// 建库 + 凭据 + 内存适配器 + 临时文件目录。
  ///
  /// drift 库必须在假区创建：其查询执行队列绑定创建时的 zone，混区使用
  /// （假区建库 + 真实区查询，或反之）会让续体落进对方 zone 的队列，
  /// 只能靠 pump/窗口交替偶发排空（同步设置页测试的既有做法一致）。
  /// 只有真实文件 IO（临时目录/布局/文件读写）进 runAsync。
  Future<void> bootstrap(WidgetTester tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    await database.customSelect('SELECT 1').getSingle();
    db = database;
    final creds = InMemoryCredentialStore();
    await creds.save(SecureKeys.webdavAccount, 'u@example.com');
    await creds.save(SecureKeys.webdavPassword, 'app-secret');
    credentials = creds;
    adapter = InMemoryAdapter();
    await tester.runAsync(() async {
      tmpDir = await Directory.systemTemp.createTemp('sync_settings_cards');
      final store = BookFileStore(tmpDir!);
      await store.ensureLayout();
      fileStore = store;
    });
    // addTearDown LIFO：关库收尾先注册（最后执行），让 provider 容器先
    // dispose（取消 drift 流订阅），再排空定时器、真实区关库/清目录。
    addTearDown(() async {
      await tester.pump(const Duration(minutes: 1));
      await tester.runAsync(() async {
        await db?.close();
        db = null;
        final dir = tmpDir;
        if (dir != null && dir.existsSync()) {
          await dir.delete(recursive: true);
        }
        tmpDir = null;
      });
    });
  }

  /// 交替 pump/runAsync 等待条件（真实 IO 事件在 runAsync 窗口到达，
  /// 假区续体由 pump 排空；2000 轮 × 25ms ≈ 50s 上限，覆盖两本连传）。
  Future<void> waitUntil(
    WidgetTester tester,
    bool Function() done, {
    String reason = '条件未在时限内满足',
  }) async {
    for (var i = 0; i < 2000; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      // pump 必须带时长：零时长不推进假时钟，链路里落在 Timer.run
      // （零时长定时器）上的续体将永远不被排空。
      await tester.pump(const Duration(milliseconds: 25));
      if (done()) return;
    }
    fail(reason);
  }

  /// 造一本本地书（真实正文文件落在 store 布局内；文件 IO 经 runAsync）。
  Future<String> seedBook(
    WidgetTester tester, {
    required String bookId,
    required String title,
    String content = 'hello local only',
    bool localOnly = false,
    bool withFile = true,
  }) async {
    final store = fileStore!;
    final database = db!;
    // 文件 IO 进 runAsync；drift 写入留在假区（查询队列绑定假区，见 bootstrap）。
    final path = store.resolveBookPath(bookId, 'txt');
    if (withFile) {
      await tester.runAsync(() async {
        final file = File(path);
        await file.create(recursive: true);
        await file.writeAsString(content, flush: true);
      });
    }
    await database.booksDao.upsertCompanion(
      BooksCompanion.insert(
        bookId: bookId,
        title: title,
        format: 'txt',
        fileName: '$title.txt',
        contentHash:
            'sha256:${sha256.convert(utf8.encode(content)).toString()}',
        sizeBytes: content.length,
        tocFingerprint: 'tfp:0000000000000000',
        addedAt: 1000,
        localPath: Value<String?>(withFile ? path : null),
      ),
    );
    if (localOnly) {
      await database.localOnlyBooksDao.markLocalOnly(bookId);
    }
    return bookId;
  }

  /// 造一个游离文件（books/ 平铺，主干不在 books 表；文件 IO 经 runAsync）。
  Future<void> seedOrphanFile(
    WidgetTester tester,
    String name,
    String content,
  ) async {
    await tester.runAsync(() async {
      final file = File('${fileStore!.booksDir.path}/$name');
      await file.create(recursive: true);
      await file.writeAsString(content, flush: true);
    });
  }

  /// 泵设置页（高表面让全部卡片可见，省去滚动定位）。
  Future<ProviderContainer> pumpPage(
    WidgetTester tester, {
    OrphanFileService? orphanService,
  }) async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db!),
        secureCredentialStoreProvider.overrideWithValue(credentials!),
        syncAdapterProvider.overrideWithValue(_FixedAdapterProvider(adapter!)),
        bookFileStoreProvider.overrideWith((ref) async => fileStore!),
        if (orphanService != null)
          orphanFileServiceProvider.overrideWithValue(orphanService),
      ],
    );
    addTearDown(container.dispose);
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(AppAccent.terracotta),
          home: const SyncSettingsPage(),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  testWidgets('注入 1 本仅本地书 + 1 个游离文件 → 两行都出现（分组渲染）', (tester) async {
    await bootstrap(tester);
    await seedBook(
      tester,
      bookId: '01LOCALONLYA',
      title: '仅本地书甲',
      localOnly: true,
    );
    await pumpPage(
      tester,
      orphanService: _FakeOrphanService([
        OrphanBookFile(
          path: '${fileStore!.booksDir.path}/orphan-a.txt',
          fileName: 'orphan-a.txt',
          stem: 'orphan-a',
          ext: 'txt',
          sizeBytes: 14,
          formatId: 'txt',
          shape: OrphanShape.flat,
        ),
      ]),
    );
    await tester.pumpAndSettle();

    // 分组标题两类都出现。
    expect(find.text('仅本地的书'), findsOneWidget);
    expect(find.text('游离文件'), findsOneWidget);
    // 两行内容（书名行 + 文件名行）+ 计数胶囊。
    expect(find.text('仅本地书甲'), findsOneWidget);
    expect(find.text('orphan-a.txt'), findsOneWidget);
    expect(find.text('2 本'), findsOneWidget);
    // 行动作按钮。
    expect(find.widgetWithText(OutlinedButton, '上传到云端'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('仅本地行「上传到云端」：uploadToCloud 被调，行消失且云端有 meta', (tester) async {
    await bootstrap(tester);
    final bookId = await seedBook(
      tester,
      bookId: '01LOCALONLYB',
      title: '仅本地书乙',
      content: 'upload me',
      localOnly: true,
    );
    final container = await pumpPage(tester);
    await tester.pumpAndSettle();
    expect(find.text('仅本地书乙'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, '上传到云端'));
    // tap 后链路在假区启动；真实 IO（读正文/上传）经 runAsync 窗口完成、
    // 假区续体由 pump 排空。完成判定 = 云端出现该书 meta **且**整轮同步
    // 收尾（内存状态离开 syncing，否则 spinner 常转、pumpAndSettle 不收敛）。
    await waitUntil(
      tester,
      () =>
          adapter!.metas.containsKey(bookId) &&
          container.read(syncMemoryStatusProvider).id != SyncStateId.syncing,
      reason: 'uploadToCloud 未把仅本地的书推上云端（或同步未收尾）',
    );
    await tester.pumpAndSettle();

    // 行消失（仅本地标记已解除，drift 流驱动），空态显示「全部已同步」。
    expect(find.text('仅本地书乙'), findsNothing);
    expect(find.text('全部已同步'), findsOneWidget);
    // 云端 meta 与正文都已上架。
    expect(adapter!.metas.containsKey(bookId), isTrue);
    expect(adapter!.books.containsKey('$bookId.txt'), isTrue);
    // 成功提示。
    expect(find.textContaining('已上传到云端'), findsOneWidget);
  });

  testWidgets('游离文件行「上传到云端」：contentHash 挂回书库 + 全量同步上架', (tester) async {
    await bootstrap(tester);
    final container = await pumpPage(tester);
    // 游离文件在泵后写入；扫描（真实 IO）在 runAsync 窗口完成。
    await seedOrphanFile(tester, 'orphan-b.txt', 'adopt me by hash');
    await waitUntil(
      tester,
      () => container.read(orphanPanelControllerProvider).orphans.isNotEmpty,
      reason: '游离文件扫描未完成',
    );
    await tester.pumpAndSettle();
    expect(find.text('orphan-b.txt'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, '上传到云端'));
    // 完成条件：云端出现新书 + 上传动作末尾的重扫已把游离清单清空。
    await waitUntil(
      tester,
      () =>
          adapter!.metas.isNotEmpty &&
          container.read(syncMemoryStatusProvider).id != SyncStateId.syncing &&
          container.read(orphanPanelControllerProvider).orphans.isEmpty,
      reason: '游离文件挂回后未被全量同步上架（或同步未收尾/重扫未完成）',
    );
    await tester.pumpAndSettle();

    // 云端出现挂回的新书（meta + 正文），行消失，成功提示可见。
    expect(adapter!.metas, hasLength(1));
    expect(adapter!.books, hasLength(1));
    expect(find.text('orphan-b.txt'), findsNothing);
    expect(find.textContaining('已挂回书库并上传到云端'), findsOneWidget);
    // 挂回的书登记进 books 表（contentHash 对应游离文件内容）。
    final expectedHash =
        'sha256:${sha256.convert(utf8.encode('adopt me by hash')).toString()}';
    final adopted = await db!.booksDao.getByContentHash(expectedHash);
    expect(adopted, isNotNull, reason: '游离文件应按 contentHash 挂回书库');
  });

  testWidgets('游离文件与库内书同内容（同 hash）→ 行内灰字「无法自动上传」', (tester) async {
    await bootstrap(tester);
    const content = 'duplicate content';
    await seedBook(
      tester,
      bookId: '01DUPBOOK00001',
      title: '同内容书',
      content: content,
    );
    // 游离文件与库内书内容一致（contentHash 相同 → adopt 命中 duplicate，
    // 云端也没有可独立上传的正文）。
    await seedOrphanFile(tester, 'dup-orphan.txt', content);
    final container = await pumpPage(tester);
    await waitUntil(
      tester,
      () => container.read(orphanPanelControllerProvider).orphans.isNotEmpty,
      reason: '游离文件扫描未完成',
    );

    await tester.tap(find.widgetWithText(OutlinedButton, '上传到云端'));
    // duplicate 分支不触发同步；等待行内灰字说明出现且重扫收敛
    // （扫描含真实 IO，pumpAndSettle 单独无法排空，约定同 waitUntil）。
    await waitUntil(
      tester,
      () =>
          find.textContaining('无法自动上传').evaluate().isNotEmpty &&
          !container.read(orphanPanelControllerProvider).scanning,
      reason: 'duplicate 分支的行内说明未出现',
    );
    await tester.pump(const Duration(milliseconds: 100));

    // duplicate：不触发上传（云端无新增），行内出现灰字说明，行按钮消失。
    expect(adapter!.metas, isEmpty);
    expect(find.textContaining('无法自动上传：库内已有同内容书'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '上传到云端'), findsNothing);
  });

  testWidgets('「全部上传」：逐本上传仅本地书并汇总提示', (tester) async {
    await bootstrap(tester);
    final a = await seedBook(
      tester,
      bookId: '01ALLUPLOADA',
      title: '全部上传甲',
      content: 'all upload a',
      localOnly: true,
    );
    final b = await seedBook(
      tester,
      bookId: '01ALLUPLOADB',
      title: '全部上传乙',
      content: 'all upload b',
      localOnly: true,
    );
    final container = await pumpPage(tester);
    await tester.pumpAndSettle();
    expect(find.text('2 本'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '全部上传'));
    await waitUntil(
      tester,
      () =>
          adapter!.metas.containsKey(a) &&
          adapter!.metas.containsKey(b) &&
          container.read(syncMemoryStatusProvider).id != SyncStateId.syncing,
      reason: '全部上传未完成（或同步未收尾）',
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('全部上传完成：成功 2 本'), findsOneWidget);
    expect(find.text('全部已同步'), findsOneWidget);
  });

  testWidgets('云端书库卡：配置 + 内存适配器有 2 本 → 显示 2', (tester) async {
    await bootstrap(tester);
    await seedBook(tester, bookId: '01CLOUDCNTA', title: '云端计数甲', content: 'a');
    await seedBook(tester, bookId: '01CLOUDCNTB', title: '云端计数乙', content: 'b');
    final container = await pumpPage(tester);
    await tester.pumpAndSettle();

    // 点「立即同步」把两本书推上云（tap 后链路在假区启动，经 runAsync 窗口
    // 推进——真实区直接 await fullSync 会死锁，约定见 waitUntil）。
    await tester.tap(find.widgetWithText(FilledButton, '立即同步'));
    await waitUntil(
      tester,
      () =>
          adapter!.metas.length == 2 &&
          container.read(syncMemoryStatusProvider).id != SyncStateId.syncing,
      reason: '立即同步未把两本书推上云端（或同步未收尾）',
    );
    container.invalidate(cloudBookCountProvider);
    await tester.pumpAndSettle();

    expect(adapter!.metas, hasLength(2));
    expect(find.textContaining('2 本'), findsOneWidget);
    expect(find.text('管理云端书籍'), findsOneWidget);
    expect(find.text('进入管理'), findsOneWidget);
  });
}

/// 固定适配器供应点（批 3 做法：测试持有同一 InMemoryAdapter 实例断言云端态）。
class _FixedAdapterProvider implements SyncAdapterProvider {
  const _FixedAdapterProvider(this.adapter);

  final BackendAdapter adapter;

  @override
  BackendAdapter create(BackendConfig config) => adapter;
}

/// 游离文件服务假实现（渲染测试注入，避免 testWidgets 假区真实 IO）。
class _FakeOrphanService implements OrphanFileService {
  _FakeOrphanService(this.files);

  final List<OrphanBookFile> files;

  @override
  Future<List<OrphanBookFile>> scan() async => files;

  @override
  Future<void> deleteOrphan(OrphanBookFile orphan) async {}

  @override
  Future<void> cleanupContainer(OrphanBookFile orphan) async {}
}
