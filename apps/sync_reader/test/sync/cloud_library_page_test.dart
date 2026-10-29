/// 云端书库管理页 widget 测试（docs/10 §4.8 / Q16 / Q19）：
/// 未配置引导态、空态、云端两本书的清单渲染（本地状态胶囊 1 下载 / 1 仅云端）、
/// 行内「从云端移除」走 removeFromCloud（deleteMeta，不写 tombstone、
/// books 表行保留）、批量移除操作条、tombstone 桩排除、三档宽度冒烟。
///
/// 真实门面 + InMemoryAdapter + drift 内存库驱动（sync_facade_test 同款装配）。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sync_core/sync_core.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/core/design_tokens.dart';
import 'package:sync_reader/core/ulid.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/features/sync/pages/cloud_library_page.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';

void main() {
  late AppDatabase db;
  late InMemoryCredentialStore credentials;
  late InMemoryAdapter adapter;
  late Directory tmp;

  Future<ProviderContainer> pumpPage(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        secureCredentialStoreProvider.overrideWithValue(credentials),
        syncAdapterProvider.overrideWithValue(_FixedAdapterProvider(adapter)),
        bookFileStoreProvider.overrideWith((ref) async => BookFileStore(tmp)),
      ],
    );
    // 页面 watch 了 drift 流（books 表）：关库收尾需先注册（LIFO）。
    addTearDown(() async {
      await tester.pump(const Duration(minutes: 1));
      await tester.runAsync(db.close);
    });
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.light(AppAccent.terracotta),
          routerConfig: _buildRouter(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return container;
  }

  Future<void> seedCredentials() async {
    await credentials.save(SecureKeys.webdavAccount, 'user@example.com');
    await credentials.save(SecureKeys.webdavPassword, 'app-secret');
    await credentials.save(
      SecureKeys.webdavBaseUrl,
      'https://dav.example.com/',
    );
    await credentials.save(SecureKeys.webdavRootPath, '/Apps/SyncReader');
  }

  /// 投喂一本云端书（他端上架形态：meta 桩 + 内容）。
  Future<String> seedCloudBook({
    required String title,
    int sizeBytes = 13,
    String format = 'txt',
  }) async {
    final bookId = generateUlid();
    final meta = _metaOf(
      bookId: bookId,
      title: title,
      sizeBytes: sizeBytes,
      format: format,
    );
    await adapter.putMeta(meta, expectedRev: 0);
    return bookId;
  }

  /// 预置本地已下载行（localPath 非空 → 「本地已下载」胶囊）。
  Future<void> seedLocalBook(String bookId, String title) async {
    await db.booksDao.upsertCompanion(
      BooksCompanion.insert(
        bookId: bookId,
        title: title,
        format: 'txt',
        fileName: '$title.txt',
        contentHash: 'sha256:$bookId',
        sizeBytes: 13,
        tocFingerprint: 'tfp:0000000000000000',
        addedAt: 1,
        localPath: Value('/books/$bookId.txt'),
      ),
    );
  }

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    credentials = InMemoryCredentialStore();
    adapter = InMemoryAdapter();
    tmp = await Directory.systemTemp.createTemp('cloudlib_page_test');
  });

  tearDown(() async {
    if (tmp.existsSync()) {
      await tmp.delete(recursive: true);
    }
  });

  testWidgets('未配置同步：引导态 + 「去配置」跳转配置向导', (tester) async {
    await pumpPage(tester);
    await tester.pumpAndSettle();

    expect(find.text('尚未配置同步'), findsOneWidget);
    expect(find.text('去配置'), findsOneWidget);
    // 清单卡与说明条都不出现。
    expect(find.text('云端书库为空'), findsNothing);

    await tester.tap(find.text('去配置'));
    await tester.pumpAndSettle();
    expect(find.text('配置向导-stub'), findsOneWidget);
  });

  testWidgets('云端书库为空：空态', (tester) async {
    await seedCredentials();
    await pumpPage(tester);
    await tester.pumpAndSettle();

    expect(find.text('云端书库为空'), findsOneWidget);
    expect(find.text('从云端移除'), findsNothing);
  });

  testWidgets('两本云端书：两行 + 本地状态胶囊（1 本地已下载 / 1 仅云端）+ 汇总胶囊', (tester) async {
    await seedCredentials();
    final localId = await seedCloudBook(title: '甲书', sizeBytes: 13);
    await seedCloudBook(title: '乙书', sizeBytes: 4096);
    await seedLocalBook(localId, '甲书');
    await pumpPage(tester);
    await tester.pumpAndSettle();

    // 两行都在（书名 + 格式 · 大小）。
    expect(find.text('甲书'), findsOneWidget);
    expect(find.text('乙书'), findsOneWidget);
    expect(find.text('TXT · 13 B'), findsOneWidget);
    expect(find.text('TXT · 4.00 KB'), findsOneWidget);
    // 本地状态胶囊：一本已下载、一本仅云端。
    expect(find.text('本地已下载'), findsOneWidget);
    expect(find.text('仅云端'), findsOneWidget);
    // 汇总胶囊：N 本 · 总大小。
    expect(find.textContaining('2 本 · '), findsOneWidget);
    // 顶部 info 说明条（§4.8 文案）。
    expect(find.textContaining('「从云端移除」只删掉云端副本'), findsOneWidget);
  });

  testWidgets('tombstone 桩排除：已删除的云端 meta 不进清单', (tester) async {
    await seedCredentials();
    final deadId = generateUlid();
    final liveMeta = _metaOf(
      bookId: generateUlid(),
      title: '活书',
      sizeBytes: 13,
    );
    final deadMeta = _metaOf(bookId: deadId, title: '死书', sizeBytes: 13);
    await adapter.putMeta(deadMeta, expectedRev: 0);
    await adapter.putTombstone(
      deadMeta.toTombstone(
        deletedAt: DateTime.fromMillisecondsSinceEpoch(3000),
        deviceId: 'other-device',
        deviceName: '其他设备',
      ),
      expectedRev: 1,
    );
    await adapter.putMeta(liveMeta, expectedRev: 0);
    await pumpPage(tester);
    await tester.pumpAndSettle();

    expect(find.text('活书'), findsOneWidget);
    expect(find.text('死书'), findsNothing);
    expect(find.textContaining('1 本 · '), findsOneWidget);
  });

  testWidgets(
    '行内「从云端移除」：调 removeFromCloud（deleteMeta，不写 tombstone），books 行保留',
    (tester) async {
      await seedCredentials();
      final localId = await seedCloudBook(title: '甲书', sizeBytes: 13);
      final cloudOnlyId = await seedCloudBook(title: '乙书', sizeBytes: 13);
      await seedLocalBook(localId, '甲书');
      await pumpPage(tester);
      await tester.pumpAndSettle();

      // 点「乙书」行的行内移除按钮（行内为 OutlinedButton，底部操作条是
      // FilledButton，二者不混淆）。
      await tester.tap(find.widgetWithText(OutlinedButton, '从云端移除').first);
      await tester.pumpAndSettle();

      // 轻提示说清「本地保留、不会自动再传回」。
      expect(find.textContaining('已从云端移除'), findsOneWidget);
      expect(find.textContaining('本地副本保留'), findsOneWidget);

      // 云端 meta 消失（若走 deleteBook 会留下 deleted=true 的墓碑 meta）。
      expect(adapter.metas.containsKey(cloudOnlyId), isFalse);
      expect(adapter.deleteMetaCalls, 1);
      // books 表行保留（本地不删）。
      await tester.runAsync(() async {
        final row = await db.booksDao.getById(localId);
        expect(row, isNotNull);
        expect(row!.localPath, isNotNull);
      });

      // 清单刷新：只剩一本。
      await tester.pumpAndSettle();
      expect(find.text('乙书'), findsNothing);
      expect(find.text('甲书'), findsOneWidget);
    },
  );

  testWidgets('批量移除：勾选两本 → 底部操作条计数 + 危险色按钮 → 逐本移除出汇总', (tester) async {
    await seedCredentials();
    final idA = await seedCloudBook(title: '甲书', sizeBytes: 13);
    final idB = await seedCloudBook(title: '乙书', sizeBytes: 13);
    await seedLocalBook(idA, '甲书');
    await pumpPage(tester);
    await tester.pumpAndSettle();

    // 底部按钮初始禁用。
    final removeBtn = find.widgetWithText(FilledButton, '从云端移除');
    expect(
      tester.widget<FilledButton>(removeBtn).onPressed,
      isNull,
      reason: '0 勾选时批量移除按钮禁用',
    );

    // 全选 → 已选 2 项。
    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(find.text('已选 2 项'), findsOneWidget);

    await tester.tap(removeBtn);
    await tester.pumpAndSettle();

    // 汇总 + 云端清空 + books 行保留。
    expect(find.textContaining('已从云端移除 2 本'), findsOneWidget);
    expect(adapter.metas.containsKey(idA), isFalse);
    expect(adapter.metas.containsKey(idB), isFalse);
    expect(adapter.deleteMetaCalls, 2);
    await tester.runAsync(() async {
      expect(await db.booksDao.getById(idA), isNotNull);
    });
    await tester.pumpAndSettle();
    expect(find.text('云端书库为空'), findsOneWidget);
  });

  testWidgets('响应式冒烟：1440 / 860 / 390 无溢出', (tester) async {
    await seedCredentials();
    final localId = await seedCloudBook(title: '甲书甲书甲书甲书甲书甲书甲书', sizeBytes: 13);
    await seedCloudBook(title: '乙书', sizeBytes: 4096);
    await seedLocalBook(localId, '甲书甲书甲书甲书甲书甲书甲书');
    // 单容器跨三档宽度重建：每个容器持有活跃的 drift 流订阅，db.close
    // 注册顺序即收尾顺序的倒序：LIFO 先执行 db.close 之前必须先 dispose
    // 容器取消 drift 流订阅，故「先注册关库、后注册 dispose」（与
    // pumpPage 一致；顺序颠倒 db.close 会等活跃流而挂起）。
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        secureCredentialStoreProvider.overrideWithValue(credentials),
        syncAdapterProvider.overrideWithValue(_FixedAdapterProvider(adapter)),
        bookFileStoreProvider.overrideWith((ref) async => BookFileStore(tmp)),
      ],
    );
    addTearDown(() async {
      await tester.pump(const Duration(minutes: 1));
      await tester.runAsync(db.close);
    });
    addTearDown(container.dispose);
    final scope = UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: AppTheme.light(AppAccent.terracotta),
        routerConfig: _buildRouter(),
      ),
    );
    for (final size in [
      const Size(1440, 900),
      const Size(860, 900),
      const Size(390, 844),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(scope);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '宽度 ${size.width}');
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

BookMeta _metaOf({
  required String bookId,
  required String title,
  required int sizeBytes,
  String format = 'txt',
}) => BookMeta(
  schemaVersion: kCurrentSchemaVersion,
  bookId: bookId,
  rev: 1,
  deviceId: 'other-device',
  deviceName: '其他设备',
  createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(2000),
  book: BookInfo(
    title: title,
    author: '',
    format: format,
    fileName: '$title.txt',
    contentHash: 'sha256:$bookId',
    sizeBytes: sizeBytes,
    tocFingerprint: 'tfp:0000000000000000',
  ),
  reading: ReadingStats(
    totalSeconds: 0,
    lastReadAt: DateTime.fromMillisecondsSinceEpoch(2000),
  ),
);

/// 固定适配器供应（测试注入 InMemoryAdapter）。
class _FixedAdapterProvider implements SyncAdapterProvider {
  const _FixedAdapterProvider(this.adapter);

  final BackendAdapter adapter;

  @override
  BackendAdapter create(BackendConfig config) => adapter;
}

/// 最小路由：云端书库页 + 配置向导 stub（「去配置」落点断言用）。
GoRouter _buildRouter() => GoRouter(
  initialLocation: '/sync/cloudlib',
  routes: [
    GoRoute(
      path: '/sync/cloudlib',
      builder: (_, _) => const CloudLibraryPage(),
    ),
    GoRoute(
      path: '/sync/guide',
      builder: (_, _) =>
          const Scaffold(key: Key('guide-stub'), body: Text('配置向导-stub')),
    ),
  ],
);
