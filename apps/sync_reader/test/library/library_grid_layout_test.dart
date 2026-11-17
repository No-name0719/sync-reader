/// 书架网格布局测试（v1.3.4 移动端书架密度整改）。
///
/// 口径（用户诉求「移动端书架一屏 3*3 - 3*4 本」）：
/// - 手机视口（360/390/412/430 宽）：**首屏完整可见的卡片 ≥ 9 张**（3 列 ×
///   ≥3 行，被截断的半张卡不计），且书名在首屏内可见、无渲染溢出；
/// - 桌面视口（1440 / 860）：列数与卡宽与改造前一致（7 列 / 5 列），观感
///   不退化。
///
/// 页面用 `Scaffold(bottomNavigationBar: 高 58)` 模拟应用外壳的移动底栏，
/// 让测得的「一屏」与真机一致。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/core/design_tokens.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/features/library/library_page.dart';
import 'package:sync_reader/features/library/library_grid_metrics.dart';
import 'package:sync_reader/features/library/widgets/book_cards.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';

/// 应用外壳移动底栏高度（原型 `.mobile-nav`）。
const double _mobileBottomBar = 58;

/// 代表性手机视口（宽 × 高）。
const _phones = <String, Size>{
  '360×640': Size(360, 640),
  '390×844': Size(390, 844),
  '412×915': Size(412, 915),
  '430×932': Size(430, 932),
};

void main() {
  AppDatabase? db;
  Directory? tmp;

  /// 建库 + 临时目录（真实 IO 必须经 runAsync）。
  Future<void> bootstrap(WidgetTester tester) async {
    await tester.runAsync(() async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      await database.customSelect('SELECT 1').getSingle();
      db = database;
      tmp = await Directory.systemTemp.createTemp('grid_layout_test');
      for (var i = 0; i < 24; i++) {
        await database.booksDao.upsertCompanion(
          BooksCompanion.insert(
            bookId: 'b$i',
            title: '书名 $i',
            author: const Value('某作者'),
            format: 'txt',
            fileName: 'b$i.txt',
            contentHash: 'sha256:${i.toString().padLeft(8, '0')}',
            sizeBytes: 1024,
            tocFingerprint: 'tfp:0000000000000000',
            addedAt: 1000,
            localPath: const Value('/books/x'),
          ),
        );
      }
    });
  }

  /// 测试体收尾：卸树 → 排空定时器 → 真实区关库（否则 drift 定时器挂起）。
  Future<void> shutdown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 60));
    await tester.runAsync(() async {
      await db?.close();
      db = null;
    });
  }

  /// 泵书库页（外层 Scaffold 模拟应用外壳的移动底栏）。
  Future<void> pumpLibrary(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db!),
          bookFileStoreProvider.overrideWith(
            (ref) async => BookFileStore(tmp!),
          ),
          secureCredentialStoreProvider.overrideWithValue(
            InMemoryCredentialStore(),
          ),
          syncAdapterProvider.overrideWithValue(
            const InMemorySyncAdapterProvider(),
          ),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light(AppAccent.terracotta),
          routerConfig: GoRouter(
            initialLocation: '/',
            routes: [
              GoRoute(
                path: '/',
                builder: (_, _) => const Scaffold(
                  body: LibraryPage(),
                  bottomNavigationBar: SizedBox(height: _mobileBottomBar),
                ),
              ),
              GoRoute(
                path: '/book/:bookId',
                builder: (_, _) => const Scaffold(body: Text('详情页-stub')),
              ),
              GoRoute(
                path: '/reader/:bookId',
                builder: (_, _) => const Scaffold(body: Text('阅读页-stub')),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('移动端书架密度', () {
    for (final entry in _phones.entries) {
      testWidgets('${entry.key}：首屏完整可见 ≥9 张卡（3 列 × ≥3 行）', (tester) async {
        await bootstrap(tester);
        await pumpLibrary(tester, entry.value);

        final grid = tester.renderObject<RenderBox>(find.byType(GridView));
        final gridRect = grid.localToGlobal(Offset.zero) & grid.size;

        final cards = find.byType(BookGridCard);
        expect(cards, findsWidgets);

        // 首屏「完整可见」的卡片：整张卡都在网格视口内（半张卡不计）。
        final visible = <int>[];
        final tops = <double, int>{}; // 首行各列的 x 起点
        for (var i = 0; i < tester.widgetList(cards).length; i++) {
          final finder = cards.at(i);
          final box = tester.renderObject<RenderBox>(finder);
          final rect = box.localToGlobal(Offset.zero) & box.size;
          if (rect.top >= gridRect.top - 0.5 &&
              rect.bottom <= gridRect.bottom + 0.5 &&
              rect.left >= gridRect.left - 0.5 &&
              rect.right <= gridRect.right + 0.5) {
            visible.add(i);
          }
          tops[rect.left] = (tops[rect.left] ?? 0) + 1;
        }

        expect(
          visible.length,
          greaterThanOrEqualTo(9),
          reason: '${entry.key}：首屏完整可见 ${visible.length} 张，应 ≥9 张',
        );

        // 首行 3 列：取 y 最小的一行，其 x 起点互不相同且恰好 3 个。
        final firstRowTops = <double>[];
        for (var i = 0; i < tester.widgetList(cards).length; i++) {
          final box = tester.renderObject<RenderBox>(cards.at(i));
          final origin = box.localToGlobal(Offset.zero);
          firstRowTops.add(origin.dy);
        }
        final minDy = firstRowTops.reduce((a, b) => a < b ? a : b);
        final firstRowXs = <double>{};
        for (var i = 0; i < tester.widgetList(cards).length; i++) {
          final box = tester.renderObject<RenderBox>(cards.at(i));
          final origin = box.localToGlobal(Offset.zero);
          if ((origin.dy - minDy).abs() < 0.5) firstRowXs.add(origin.dx);
        }
        expect(firstRowXs.length, 3, reason: '${entry.key}：应为 3 列');

        // 书名在首屏内可见（紧凑卡的书名叠在封面底部，仍须落在网格视口内）。
        final firstVisible = visible.first;
        final cardWidget = tester.widget<BookGridCard>(cards.at(firstVisible));
        final titleFinder = find.descendant(
          of: cards.at(firstVisible),
          matching: find.text(cardWidget.book.title),
        );
        expect(titleFinder, findsOneWidget);
        final titleBox = tester.renderObject<RenderBox>(titleFinder);
        final titleRect = titleBox.localToGlobal(Offset.zero) & titleBox.size;
        expect(
          titleRect.bottom <= gridRect.bottom + 0.5,
          isTrue,
          reason: '${entry.key}：书名应落在首屏内',
        );

        // 渲染期不得有溢出异常。
        expect(tester.takeException(), isNull, reason: '${entry.key}：渲染溢出');

        await shutdown(tester);
      });
    }

    testWidgets('紧凑卡：卡高 = 封面高（书名不占额外行高）', (tester) async {
      await bootstrap(tester);
      await pumpLibrary(tester, const Size(390, 844));
      final card = tester.widget<BookGridCard>(find.byType(BookGridCard).first);
      expect(card.compact, isTrue);
      // 紧凑档封面比例自适应但不低于 1:1、不高于 2:3。
      expect(card.coverAspectRatio, greaterThanOrEqualTo(1 / 1.5 - 1e-9));
      expect(card.coverAspectRatio, lessThanOrEqualTo(1.0 + 1e-9));

      final grid = tester.renderObject<RenderBox>(find.byType(GridView));
      final cardBox = tester.renderObject<RenderBox>(
        find.byType(BookGridCard).first,
      );
      // 卡片实际高度 == 封面高度（无文字区）→ 网格格子与内容严丝合缝。
      expect(
        cardBox.size.height,
        closeTo(cardBox.size.width / card.coverAspectRatio, 0.5),
      );
      expect(grid.size.height, greaterThan(0));
      await shutdown(tester);
    });
  });

  group('桌面端不退化', () {
    testWidgets('1440：仍是 7 列，卡宽与封面比例不变', (tester) async {
      await bootstrap(tester);
      await pumpLibrary(tester, const Size(1440, 900));

      final cards = find.byType(BookGridCard);
      final card = tester.widget<BookGridCard>(cards.first);
      expect(card.compact, isFalse, reason: '桌面不该走紧凑卡');
      expect(card.coverAspectRatio, closeTo(2 / 3, 1e-9));

      final box = tester.renderObject<RenderBox>(cards.first);
      expect(box.size.width, closeTo((1208 - 96) / 7, 0.5));

      // 首行 7 列。
      final xs = <double>{};
      for (var i = 0; i < tester.widgetList(cards).length; i++) {
        final b = tester.renderObject<RenderBox>(cards.at(i));
        final origin = b.localToGlobal(Offset.zero);
        if (origin.dy < 200) xs.add(origin.dx);
      }
      expect(xs.length, 7);
      expect(tester.takeException(), isNull);
      await shutdown(tester);
    });

    testWidgets('860：仍是 5 列', (tester) async {
      await bootstrap(tester);
      await pumpLibrary(tester, const Size(860, 900));

      final cards = find.byType(BookGridCard);
      final card = tester.widget<BookGridCard>(cards.first);
      expect(card.compact, isFalse);

      final xs = <double>{};
      for (var i = 0; i < tester.widgetList(cards).length; i++) {
        final b = tester.renderObject<RenderBox>(cards.at(i));
        final origin = b.localToGlobal(Offset.zero);
        if (origin.dy < 200) xs.add(origin.dx);
      }
      expect(xs.length, 5);
      expect(tester.takeException(), isNull);
      await shutdown(tester);
    });

    testWidgets('度量与实际渲染一致（列数 / 卡宽 / 一屏行数）', (tester) async {
      await bootstrap(tester);
      await pumpLibrary(tester, const Size(1440, 900));

      final grid = tester.renderObject<RenderBox>(find.byType(GridView));
      final metrics = computeLibraryGridMetrics(
        viewportWidth: grid.size.width,
        viewportHeight: grid.size.height,
        spec: libraryGridSpecForWidth(grid.size.width),
      );
      expect(metrics.columns, 7);

      final cards = find.byType(BookGridCard);
      final box = tester.renderObject<RenderBox>(cards.first);
      expect(box.size.width, closeTo(metrics.cardWidth, 0.5));
      expect(box.size.height, closeTo(metrics.cardHeight, 0.5));
      await shutdown(tester);
    });
  });

  tearDown(() async {
    await db?.close();
    db = null;
    final dir = tmp;
    if (dir != null && dir.existsSync()) {
      await dir.delete(recursive: true);
    }
    tmp = null;
  });
}
