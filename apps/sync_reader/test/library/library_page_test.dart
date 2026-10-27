/// 书库首页 widget 测试（FR-105/106）：网格/列表切换与持久化、排序、
/// 防抖搜索、空态、去详情导航、错误态。注入内存库 + 临时目录存储。
///
/// 注意：testWidgets 的 fakeAsync 中真实 IO（临时目录/文件）必须经
/// `tester.runAsync` 执行；widget 内的 drift 流（假定时器驱动）由
/// pumpAndSettle 正常驱动。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/features/library/library_page.dart';
import 'package:sync_reader/features/library/library_providers.dart';

void main() {
  AppDatabase? db;
  Directory? tmp;

  /// 建库 + 临时目录（真实 IO 经 runAsync）。
  Future<void> bootstrap(WidgetTester tester) async {
    await tester.runAsync(() async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      await database.customSelect('SELECT 1').getSingle();
      db = database;
      tmp = await Directory.systemTemp.createTemp('library_page_test');
    });
  }

  /// 断言失败时也保证关闭库（否则残留的 drift 定时器让后续测试级联挂起）。
  Future<void> bootstrapSafely(WidgetTester tester) async {
    await bootstrap(tester);
    addTearDown(() async {
      if (db != null) {
        await tester.pump(const Duration(seconds: 60));
        await tester.runAsync(() async => db?.close());
        db = null;
      }
    });
  }

  /// 测试体收尾：排空 drift 流查询的更新定时器后在真实区关闭库。
  /// 不排空则 close 等待 fake 定时器驱动的清理而挂起；不关闭则
  /// "Timer is still pending" invariant 失败。
  Future<void> shutdown(WidgetTester tester) async {
    // 先卸载整个 widget 树：Riverpod 容器销毁 → drift 流订阅取消，
    // 使 close 无需等待流清理；再排空残余定时器，最后在真实区关闭库。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 60));
    await tester.runAsync(() async {
      await db?.close();
      db = null;
    });
  }

  BooksCompanion bookRow(
    String id, {
    String title = '书',
    String author = '',
    String format = 'txt',
    int addedAt = 1000,
    int? lastReadAt,
    String? localPath = '/books/x',
  }) => BooksCompanion.insert(
    bookId: id,
    title: title,
    author: Value(author),
    format: format,
    fileName: '$id.$format',
    contentHash: 'sha256:$id',
    sizeBytes: 1024,
    tocFingerprint: 'tfp:0000000000000000',
    addedAt: addedAt,
    localPath: Value(localPath),
    lastReadAt: Value(lastReadAt),
  );

  GoRouter buildRouter() => GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, _) => const LibraryPage()),
      GoRoute(
        path: '/book/:bookId',
        builder: (_, _) =>
            const Scaffold(key: Key('detail-stub'), body: Text('详情页-stub')),
      ),
    ],
  );

  Future<void> pumpLibrary(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db!),
          bookFileStoreProvider.overrideWith(
            (ref) async => BookFileStore(tmp!),
          ),
        ],
        child: MaterialApp.router(routerConfig: buildRouter()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('空书库显示空态', (tester) async {
    await bootstrapSafely(tester);
    await pumpLibrary(tester);
    expect(find.text('书库为空'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget); // 导入入口
    await shutdown(tester);
  });

  testWidgets('网格显示书名/进度/时长/仅云端角标', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(() async {
      final database = db!;
      await database.booksDao.upsertCompanion(
        bookRow('01A', title: 'AAA', lastReadAt: 900),
      );
      await database.booksDao.upsertCompanion(
        bookRow('01B', title: 'BBB', localPath: null),
      );
      await database.progressDao.upsert(
        bookId: '01A',
        locatorJson: '{}',
        percent: 0.42,
      );
      await database.booksDao.updateProgressInfo('01A', totalSeconds: 1800);
    });
    await pumpLibrary(tester);

    expect(find.text('AAA'), findsWidgets); // 封面小字 + 卡片标题
    expect(find.text('42%'), findsOneWidget);
    expect(find.text('30 分钟'), findsOneWidget);
    expect(find.text('仅云端'), findsOneWidget); // 占位书角标
    await shutdown(tester);
  });

  testWidgets('网格/列表切换并持久化（reader_settings.library_view）', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(
      () => db!.booksDao.upsertCompanion(bookRow('01A', title: 'AAA')),
    );
    await pumpLibrary(tester);

    expect(find.byType(ListTile), findsNothing);
    await tester.tap(find.byIcon(Icons.view_list));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsOneWidget);
    // 值落库（JSON 字符串 "list"）。
    await tester.runAsync(() async {
      expect(await db!.readerSettingsDao.getValue('library_view'), '"list"');
    });

    // 新容器重建 → 从库里恢复列表模式。
    // 注意：同位置的 ProviderScope 重新 pump 时 override 数量必须一致
    //（riverpod 调试断言），否则新树构建即抛异常。
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db!),
          bookFileStoreProvider.overrideWith(
            (ref) async => BookFileStore(tmp!),
          ),
        ],
        child: MaterialApp.router(routerConfig: buildRouter()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('排序切换即时生效（默认最近阅读 → 书名）', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(() async {
      await db!.booksDao.upsertCompanion(
        bookRow('01A', title: 'AAA', lastReadAt: 800),
      );
      await db!.booksDao.upsertCompanion(
        bookRow('01B', title: 'BBB', lastReadAt: 900),
      );
    });
    await pumpLibrary(tester);
    // 切列表便于断言顺序。
    await tester.tap(find.byIcon(Icons.view_list));
    await tester.pumpAndSettle();
    List<ListTile> tiles() =>
        tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect((tiles().first.title as Text).data, 'BBB');

    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text('书名'));
    await tester.pumpAndSettle();
    expect((tiles().first.title as Text).data, 'AAA');
    await shutdown(tester);
  });

  testWidgets('搜索 300ms 防抖后过滤（FR-106）', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(() async {
      await db!.booksDao.upsertCompanion(bookRow('01A', title: 'AAA'));
      await db!.booksDao.upsertCompanion(bookRow('01B', title: 'BBB'));
    });
    await pumpLibrary(tester);

    await tester.enterText(find.byType(TextField), 'AA');
    // 防抖窗口内：还未过滤。
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('BBB'), findsWidgets);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('BBB'), findsNothing);
    expect(find.text('AAA'), findsWidgets);

    // 清空恢复。
    await tester.enterText(find.byType(TextField), '');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('BBB'), findsWidgets);
    await shutdown(tester);
  });

  testWidgets('点击卡片进入详情路由', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(
      () => db!.booksDao.upsertCompanion(bookRow('01A', title: 'AAA')),
    );
    final router = buildRouter();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db!),
          bookFileStoreProvider.overrideWith(
            (ref) async => BookFileStore(tmp!),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('AAA').first);
    await tester.pumpAndSettle();
    expect(find.text('详情页-stub'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('书库流错误 → 空态标题 + 错误提示', (tester) async {
    await bootstrapSafely(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db!),
          booksStreamProvider.overrideWith(
            (ref) => Stream.error(Exception('db boom')),
          ),
        ],
        child: MaterialApp.router(routerConfig: buildRouter()),
      ),
    );
    // 错误流经 Riverpod 的定时/微任务链送达，需要显式时间泵推进
    //（静态 loading 占位不产生持续帧，pumpAndSettle 会立即返回）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));
    for (final t in tester.widgetList<Text>(find.byType(Text))) {
      // ignore: avoid_print
      print('TXT[${t.data}]');
    }
    expect(find.text('书库为空'), findsOneWidget);
    expect(find.textContaining('书库加载失败'), findsOneWidget);
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
  });
}
