/// 书籍详情页 widget 测试（FR-104/FR-408）：元数据/进度/时长展示、
/// 打开阅读器导航、删除确认对话框与 softDelete+游离语义、缺书空态。
/// 注入内存库 + 临时目录存储 + 假 handler 注册表。
///
/// 真实 IO（临时目录/种子文件）经 `tester.runAsync` 执行（fakeAsync 限制）。
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/features/library/book_detail_page.dart';
import 'package:sync_reader/features/reader/contract/format_registry.dart';
import 'package:sync_reader/shared/format_utils.dart';

import 'fake_handler.dart';

void main() {
  final addedAtMs = DateTime(2026, 10, 26, 8, 30).millisecondsSinceEpoch;
  const contentHash = 'sha256:0123456789abcdef0123456789abcdef';
  const bookId = '01ATESTBOOK0000000000000001';

  AppDatabase? db;
  Directory? tmp;
  BookFileStore? store;

  /// 建库 + 临时目录（真实 IO 经 runAsync）。
  Future<void> bootstrap(WidgetTester tester) async {
    await tester.runAsync(() async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      await database.customSelect('SELECT 1').getSingle();
      final dir = await Directory.systemTemp.createTemp('detail_page_test');
      final fileStore = BookFileStore(dir);
      await fileStore.ensureLayout();
      db = database;
      tmp = dir;
      store = fileStore;
    });
  }

  /// 造一本带正文文件的本地书 + 进度行（真实 IO 经 runAsync）。
  Future<void> seedBook(
    WidgetTester tester, {
    bool withLocalFile = true,
  }) async {
    await tester.runAsync(
      () => seedBookData(
        db: db!,
        store: store!,
        bookId: bookId,
        contentHash: contentHash,
        addedAtMs: addedAtMs,
        withLocalFile: withLocalFile,
      ),
    );
  }

  /// 让 fakeAsync 内由 widget 回调发起的真实 IO（目录解析读文件、
  /// 删除时的游离移动）完成，再 settle UI。
  Future<void> settleReal(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
  }

  /// 测试体收尾：先卸载 widget 树（取消 Riverpod/drift 流订阅），
  /// 再排空残余定时器，最后在真实区关闭库。直接 close 会因等待
  /// fake 定时器驱动的流清理而挂起；不关闭则触发 pending-timer invariant。
  Future<void> shutdown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 60));
    await tester.runAsync(() async {
      await db?.close();
      db = null;
    });
  }

  GoRouter buildRouter() => GoRouter(
    initialLocation: '/book/$bookId',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) =>
            const Scaffold(key: Key('library-stub'), body: Text('书库-stub')),
      ),
      GoRoute(
        path: '/book/:bookId',
        builder: (context, state) =>
            BookDetailPage(bookId: state.pathParameters['bookId']!),
      ),
      GoRoute(
        path: '/reader/:bookId',
        builder: (_, _) =>
            const Scaffold(key: Key('reader-stub'), body: Text('阅读器-stub')),
      ),
    ],
  );

  Future<void> pumpDetail(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db!),
          bookFileStoreProvider.overrideWith((ref) async => store!),
          formatRegistryProvider.overrideWith(
            (ref) => FormatRegistry()..register(FakeHandler()),
          ),
        ],
        child: MaterialApp.router(routerConfig: buildRouter()),
      ),
    );
    // 详情 + 进度 + 目录解析（真实文件读取在 runAsync 间隙完成）。
    await tester.pumpAndSettle();
    await settleReal(tester);
  }

  testWidgets('展示元数据/进度/时长/目录数量', (tester) async {
    await bootstrap(tester);
    await seedBook(tester);
    await pumpDetail(tester);

    expect(find.text('三体'), findsWidgets); // 封面 + 标题
    expect(find.text('刘慈欣'), findsWidgets);
    expect(find.text('TXT'), findsOneWidget);
    expect(find.text('1.21 KB'), findsOneWidget); // humanizeBytes(1234)
    expect(find.text(shortenHash(contentHash)), findsOneWidget);
    expect(find.text('2026-10-26 08:30'), findsOneWidget); // 添加时间
    expect(find.text('2026-10-26 09:30'), findsOneWidget); // 上次阅读
    expect(find.textContaining('42%'), findsOneWidget); // 阅读进度
    expect(find.text('1 分钟'), findsOneWidget); // 累计阅读 90 秒
    expect(find.textContaining('共 1 章'), findsOneWidget); // 假 handler 目录
    expect(find.text('继续阅读'), findsOneWidget); // 有进度
    await shutdown(tester);
  });

  testWidgets('打开按钮进入阅读器', (tester) async {
    await bootstrap(tester);
    await seedBook(tester);
    await pumpDetail(tester);
    await tester.tap(find.text('继续阅读'));
    await tester.pumpAndSettle();
    expect(find.text('阅读器-stub'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('占位书（仅云端）：角标 + 打开按钮禁用', (tester) async {
    await bootstrap(tester);
    await seedBook(tester, withLocalFile: false);
    await pumpDetail(tester);
    expect(find.text('仅云端'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.ancestor(of: find.text('继续阅读'), matching: find.byType(FilledButton)),
    );
    expect(button.onPressed, isNull);
    await shutdown(tester);
  });

  testWidgets('删除：确认对话框说明语义 → 软删 + 正文移游离 + 返回书库', (tester) async {
    await bootstrap(tester);
    await seedBook(tester);
    final localPath = p.join(store!.booksDir.path, bookId, 'source.txt');
    await pumpDetail(tester);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('删除《三体》？'), findsOneWidget);
    expect(find.textContaining('游离'), findsOneWidget); // 语义说明
    expect(find.textContaining('回收区'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await settleReal(tester);

    // 已返回书库路由。
    expect(find.text('书库-stub'), findsOneWidget);
    // 数据库：行删除 + tombstone 入账；正文文件移入游离区。
    await tester.runAsync(() async {
      expect(await db!.booksDao.getById(bookId), isNull);
      final tombstone = await db!.select(db!.deletedBooks).getSingle();
      expect(tombstone.bookId, bookId);
      expect(tombstone.contentHash, contentHash);
      expect(File(localPath).existsSync(), isFalse);
      final orphans = await store!.listOrphans();
      expect(orphans, hasLength(1));
    });
    await shutdown(tester);
  });

  testWidgets('取消删除不动数据', (tester) async {
    await bootstrap(tester);
    await seedBook(tester);
    final localPath = p.join(store!.booksDir.path, bookId, 'source.txt');
    await pumpDetail(tester);
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      expect(await db!.booksDao.getById(bookId), isNotNull);
      expect(File(localPath).existsSync(), isTrue);
      expect(await store!.listOrphans(), isEmpty);
    });
    await shutdown(tester);
  });

  testWidgets('书不存在 → 空态返回', (tester) async {
    await bootstrap(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db!),
          bookFileStoreProvider.overrideWith((ref) async => store!),
        ],
        child: MaterialApp.router(routerConfig: buildRouter()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('书籍不存在或已删除'), findsOneWidget);
    await shutdown(tester);
  });

  tearDown(() async {
    await db?.close();
    final dir = tmp;
    if (dir != null && dir.existsSync()) {
      await dir.delete(recursive: true);
    }
    db = null;
    tmp = null;
    store = null;
  });
}

/// 种子数据写入（在 tester.runAsync 的真实异步区执行）。
Future<void> seedBookData({
  required AppDatabase db,
  required BookFileStore store,
  required String bookId,
  required String contentHash,
  required int addedAtMs,
  required bool withLocalFile,
}) async {
  String? localPath;
  if (withLocalFile) {
    localPath = p.join(store.booksDir.path, bookId, 'source.txt');
    final file = File(localPath);
    await file.create(recursive: true);
    await file.writeAsString('正文内容');
  }
  await db.booksDao.upsert(
    Book(
      bookId: bookId,
      title: '三体',
      author: '刘慈欣',
      format: 'txt',
      fileName: '三体.txt',
      localPath: localPath,
      contentHash: contentHash,
      sizeBytes: 1234,
      coverPath: null,
      tocFingerprint: 'tfp:0123456789abcdef',
      addedAt: addedAtMs,
      lastReadAt: addedAtMs + 3600000,
      totalSeconds: 90,
    ),
  );
  await db.progressDao.upsert(
    bookId: bookId,
    locatorJson: '{}',
    percent: 0.42,
    dirty: false,
  );
}
