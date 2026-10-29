/// 书籍详情页 widget 测试（FR-104/FR-408/FR-410/v1.1 A7）：Hero 区（进度条
/// 与百分比文案）、阅读数据卡（4 统计块 + 近 7 天柱状图）、文件信息卡
/// （定义列表）、目录预览卡（解析/降级/截断/当前章高亮），以及打开阅读器
/// 导航、删除确认对话框与新删除语义（删正文留元数据，docs/10 §4.7b）、
/// 文件替换入口（按钮可见性/确认文案/替换成功反馈与刷新）、缺书空态、
/// 三档宽度溢出冒烟。
/// 注入内存库 + 临时目录存储 + 假 handler 注册表 + 假文件选择器。
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
import 'package:sync_core/sync_core.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/core/content_hasher.dart';
import 'package:sync_reader/core/design_tokens.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';
import 'package:sync_reader/features/library/book_detail_page.dart';
import 'package:sync_reader/features/library/replace/book_replace_service.dart';
import 'package:sync_reader/features/reader/contract/format_registry.dart';
import 'package:sync_reader/features/reader/contract/toc_entry.dart';
import 'package:sync_reader/shared/format_utils.dart';

import 'fake_handler.dart';

void main() {
  final addedAtMs = DateTime(2026, 10, 26, 8, 30).millisecondsSinceEpoch;
  const contentHash = 'sha256:0123456789abcdef0123456789abcdef';
  const bookId = '01ATESTBOOK0000000000000001';
  // 浅色赭石令牌（与测试骨架挂载的主题一致），柱状图颜色断言用。
  final tokens = AppDesignTokens.light(AppAccent.terracotta);

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
    bool withProgress = true,
  }) async {
    await tester.runAsync(
      () => seedBookData(
        db: db!,
        store: store!,
        bookId: bookId,
        contentHash: contentHash,
        addedAtMs: addedAtMs,
        withLocalFile: withLocalFile,
        withProgress: withProgress,
      ),
    );
  }

  /// 让 fakeAsync 内由 widget 回调发起的真实 IO 完成，再 settle UI。
  /// 真实 IO 的完成事件经真实事件循环投递：每进一次 runAsync 窗口推进
  /// 串行链的一环（删除的移动/替换的复制+哈希链），故用多窗口循环。
  Future<void> settleReal(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
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

  Future<void> pumpDetail(
    WidgetTester tester, {
    ReplaceFilePicker? picker,
    Future<SyncReport?> Function(String bookId)? pushToCloud,
    FakeHandler? handler,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db!),
          bookFileStoreProvider.overrideWith((ref) async => store!),
          formatRegistryProvider.overrideWith(
            // 目录预览与章节数都走 handler.parseMetadata（复用阅读器解析管线）。
            (ref) => FormatRegistry()..register(handler ?? FakeHandler()),
          ),
          // 占位书"下载正文"按钮（FR-402）与替换确认对话框（FR-410）会触碰
          // 同步门面：注入内存凭据存储（未存凭据 → readConfig 返回 null →
          // 按未配置处理，不触碰平台通道）。
          secureCredentialStoreProvider.overrideWithValue(
            InMemoryCredentialStore(),
          ),
          // 文件替换（FR-410）替身：假选择器 + 可选假云端推送（行更新
          // 顺序经推送发生时的行内 hash 断言，见各测试体）。
          if (picker != null)
            replaceFilePickerProvider.overrideWithValue(picker),
          if (pushToCloud != null)
            bookReplaceServiceProvider.overrideWith(
              (ref) => BookReplaceService(
                booksDao: ref.watch(booksDaoProvider),
                registry: ref.watch(formatRegistryProvider),
                fileStore: ref.watch(bookFileStoreProvider.future),
                library: ref.watch(driftLocalLibraryProvider),
                pushToCloud: pushToCloud,
              ),
            ),
        ],
        // 详情页消费设计令牌（A7）：测试骨架必须挂 AppTheme。
        child: MaterialApp.router(
          routerConfig: buildRouter(),
          theme: AppTheme.light(AppAccent.terracotta),
        ),
      ),
    );
    // 详情 + 进度 + 目录解析（真实文件读取在 runAsync 间隙完成）。
    await tester.pumpAndSettle();
    await settleReal(tester);
  }

  /// 加高测试视口：v1.1 四卡布局比旧版长（Hero 252px 封面 + 三张卡），
  /// 折叠线下的内容（目录卡/下方统计块）在默认 600px 视口里不进树
  /// （ListView 惰性构建）；涉及折叠线下内容的用例须先调用。
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('展示元数据/进度/时长/目录数量', (tester) async {
    useTallViewport(tester);
    await bootstrap(tester);
    await seedBook(tester);
    await pumpDetail(tester);

    expect(find.text('三体'), findsWidgets); // 封面 + 标题
    expect(find.text('刘慈欣'), findsWidgets);
    expect(find.text('TXT'), findsOneWidget); // 格式胶囊
    expect(find.text('1.21 KB'), findsOneWidget); // 文件信息卡 humanizeBytes(1234)
    expect(find.text(shortenHash(contentHash)), findsOneWidget); // 哈希截断
    expect(find.text('2026-10-26 08:30'), findsOneWidget); // 添加时间
    expect(find.text('2026-10-26 09:30'), findsOneWidget); // 上次阅读（统计块）
    // 42% 出现两处：Hero 进度行 + 「阅读进度」统计块（原型两处都有）。
    expect(find.textContaining('42%'), findsWidgets);
    expect(find.text('1 分钟'), findsOneWidget); // 累计阅读 90 秒
    expect(find.textContaining('共 1 章'), findsOneWidget); // 目录卡头部胶囊
    expect(find.text('继续阅读'), findsOneWidget); // 有进度
    await shutdown(tester);
  });

  testWidgets('Hero 进度：locator 带章节坐标 → 「62% · 第 128 章」+ 填充宽度', (tester) async {
    useTallViewport(tester);
    await bootstrap(tester);
    await seedBook(tester);
    // 覆写进度：txt locator chapterIndex 127 → 第 128 章。
    await tester.runAsync(() async {
      await db!.progressDao.upsert(
        bookId: bookId,
        locatorJson: '{"type":"txt","chapterIndex":127,"charOffset":1204}',
        percent: 0.62,
        dirty: false,
      );
    });
    await pumpDetail(tester);

    expect(find.text('62% · 第 128 章'), findsOneWidget);
    final fill = tester.widget<FractionallySizedBox>(
      find.byKey(const Key('detail_progress_fill')),
    );
    expect(fill.widthFactor, closeTo(0.62, 0.001));
    await shutdown(tester);
  });

  testWidgets('Hero 进度：无进度 → 「尚未开始」+ 零宽进度条', (tester) async {
    useTallViewport(tester);
    await bootstrap(tester);
    await seedBook(tester, withProgress: false);
    await pumpDetail(tester);

    expect(find.text('尚未开始'), findsOneWidget);
    final fill = tester.widget<FractionallySizedBox>(
      find.byKey(const Key('detail_progress_fill')),
    );
    expect(fill.widthFactor, 0);
    // 主按钮为「开始阅读」（无进度）。
    expect(find.text('开始阅读'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('Hero 进度：locator 无章节坐标（pdf/空对象）→ 只显示百分比', (tester) async {
    useTallViewport(tester);
    await bootstrap(tester);
    await seedBook(tester);
    await tester.runAsync(() async {
      await db!.progressDao.upsert(
        bookId: bookId,
        locatorJson: '{"type":"pdf","pageIndex":3,"yRatio":0.5}',
        percent: 0.42,
        dirty: false,
      );
    });
    await pumpDetail(tester);

    // Hero 进度行是精确的「42%」（无「· 第 N 章」后缀）。
    final progressText = tester.widget<Text>(
      find.byKey(const Key('detail_progress_text')),
    );
    expect(progressText.data, '42%');
    await shutdown(tester);
  });

  testWidgets('阅读数据卡：近 7 天柱状图（7 柱、缺口零柱、最高柱高亮）', (tester) async {
    useTallViewport(tester);
    await bootstrap(tester);
    await seedBook(tester);
    // 种 6 天（2026-10-24 缺 = 零高柱）：窗口终点取最近记录日 10-27，
    // 窗口 = 10-21..10-27。10-22 的 120 秒为最高柱。
    await tester.runAsync(() async {
      final dao = db!.readingDaysDao;
      await dao.addSeconds(bookId, '2026-10-21', 60);
      await dao.addSeconds(bookId, '2026-10-22', 120);
      await dao.addSeconds(bookId, '2026-10-23', 30);
      await dao.addSeconds(bookId, '2026-10-25', 90);
      await dao.addSeconds(bookId, '2026-10-26', 45);
      await dao.addSeconds(bookId, '2026-10-27', 75);
    });
    await pumpDetail(tester);

    const days = [
      '2026-10-21',
      '2026-10-22',
      '2026-10-23',
      '2026-10-24',
      '2026-10-25',
      '2026-10-26',
      '2026-10-27',
    ];
    // 柱数：7 根（含缺口日的零柱）。
    for (final day in days) {
      expect(
        find.byKey(Key('detail_spark_bar_$day')),
        findsOneWidget,
        reason: day,
      );
    }
    Color barColor(String day) =>
        (tester
                    .widget<Container>(find.byKey(Key('detail_spark_bar_$day')))
                    .decoration!
                as BoxDecoration)
            .color!;
    double barHeight(String day) => tester
        .widget<Container>(find.byKey(Key('detail_spark_bar_$day')))
        .constraints!
        .minHeight;
    // 最高柱品牌色高亮，其余品牌浅底。
    expect(barColor('2026-10-22'), tokens.brand);
    expect(barColor('2026-10-21'), tokens.brandSoft2);
    expect(barColor('2026-10-27'), tokens.brandSoft2);
    // 高度：最高柱顶满 56；90/120 → 42；缺口日零柱 = 3px 最小可见高度。
    expect(barHeight('2026-10-22'), 56.0);
    expect(barHeight('2026-10-25'), closeTo(42, 0.01));
    expect(barHeight('2026-10-24'), 3.0);
    // 横轴标签 MM-DD。
    expect(find.text('10-21'), findsOneWidget);
    expect(find.text('10-27'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('阅读数据卡：无按天记录显示空态文案，页面其余部分不受影响', (tester) async {
    useTallViewport(tester);
    await bootstrap(tester);
    await seedBook(tester); // 不种 reading_days（新装/老库升级常态）。
    await pumpDetail(tester);

    expect(find.text('暂无按天记录'), findsOneWidget);
    expect(find.text('最近 7 天'), findsOneWidget);
    expect(find.text('1 分钟'), findsOneWidget); // 累计阅读块不受影响
    expect(find.textContaining('共 1 章'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('目录预览（A7）：渲染 handler 解析的目录条目并按层级缩进', (tester) async {
    useTallViewport(tester);
    await bootstrap(tester);
    await seedBook(tester);
    await pumpDetail(
      tester,
      handler: FakeHandler(
        toc: [
          TocEntry(title: '第一卷 · 江湖', level: 0, anchor: 0),
          TocEntry(title: '第一章 风起青萍', level: 1, anchor: 1),
          TocEntry(title: '第二章 落雁堡', level: 1, anchor: 2),
        ],
      ),
    );

    expect(find.textContaining('共 3 章'), findsOneWidget);
    expect(find.text('第一卷 · 江湖'), findsOneWidget);
    expect(find.text('第一章 风起青萍'), findsOneWidget);
    expect(find.text('第二章 落雁堡'), findsOneWidget);
    // 层级缩进：lv0 → s3，lv1 → s5（原型 .toc-item / .lv1）。
    EdgeInsets itemPad(String key) =>
        tester.widget<Container>(find.byKey(Key(key))).padding! as EdgeInsets;
    expect(itemPad('detail_toc_item_0').left, AppSpacing.s3);
    expect(itemPad('detail_toc_item_1').left, AppSpacing.s5);
    expect(itemPad('detail_toc_item_2').left, AppSpacing.s5);
    await shutdown(tester);
  });

  testWidgets('目录预览（A7）：locator 命中章 → 该条目高亮 + 「当前」胶囊', (tester) async {
    useTallViewport(tester);
    await bootstrap(tester);
    await seedBook(tester);
    await tester.runAsync(() async {
      await db!.progressDao.upsert(
        bookId: bookId,
        locatorJson: '{"type":"txt","chapterIndex":1,"charOffset":0}',
        percent: 0.5,
      );
    });
    await pumpDetail(
      tester,
      handler: FakeHandler(
        toc: [
          TocEntry(title: '第一章', level: 0, anchor: 0),
          TocEntry(title: '第二章', level: 0, anchor: 1),
          TocEntry(title: '第三章', level: 0, anchor: 2),
        ],
      ),
    );

    expect(find.text('当前'), findsOneWidget);
    // 高亮落在第二章（locator chapterIndex 1 → 目录序 1）。
    final current =
        tester
                .widget<Container>(find.byKey(const Key('detail_toc_item_1')))
                .decoration!
            as BoxDecoration;
    expect(current.color, tokens.brandSoft);
    final other =
        tester
                .widget<Container>(find.byKey(const Key('detail_toc_item_0')))
                .decoration!
            as BoxDecoration;
    expect(other.color, isNull);
    await shutdown(tester);
  });

  testWidgets('目录预览（A7）：超 20 条截断并提示在阅读器内查看', (tester) async {
    useTallViewport(tester);
    await bootstrap(tester);
    await seedBook(tester);
    await pumpDetail(
      tester,
      handler: FakeHandler(
        toc: [
          for (var i = 0; i < 25; i++)
            TocEntry(title: '第${i + 1}章', level: 0, anchor: i),
        ],
      ),
    );

    expect(find.textContaining('共 25 章'), findsOneWidget);
    expect(find.byKey(const Key('detail_toc_item_19')), findsOneWidget);
    expect(find.byKey(const Key('detail_toc_item_20')), findsNothing);
    expect(find.text('在阅读器内查看完整目录'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('目录预览（A7）：占位书优雅降级为「暂不可得」', (tester) async {
    useTallViewport(tester);
    await bootstrap(tester);
    await seedBook(tester, withLocalFile: false);
    await pumpDetail(tester);

    expect(find.text('暂不可得（占位书或文件缺失）'), findsOneWidget);
    expect(find.textContaining('共'), findsNothing); // 头部无章数胶囊
    await shutdown(tester);
  });

  testWidgets('目录预览（A7）：无目录结构（txt 章节切分失败等）优雅降级', (tester) async {
    useTallViewport(tester);
    await bootstrap(tester);
    await seedBook(tester);
    await pumpDetail(tester, handler: FakeHandler(toc: const []));

    expect(find.text('无目录信息'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('打开按钮进入阅读器', (tester) async {
    useTallViewport(tester);
    await bootstrap(tester);
    await seedBook(tester);
    await pumpDetail(tester);
    await tester.tap(find.text('继续阅读'));
    await tester.pumpAndSettle();
    expect(find.text('阅读器-stub'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('占位书（仅云端）：角标 + 主按钮分流为"下载正文"（FR-402）', (tester) async {
    useTallViewport(tester);
    await bootstrap(tester);
    await seedBook(tester, withLocalFile: false);
    await pumpDetail(tester);
    expect(find.text('仅云端'), findsOneWidget);
    // 主按钮不再是禁用的"继续阅读"，而是可点的"下载正文"。
    final button = tester.widget<FilledButton>(
      find.ancestor(of: find.text('下载正文'), matching: find.byType(FilledButton)),
    );
    expect(button.onPressed, isNotNull);
    // 未配置同步账号时点击：提示配置，不导航（仍在详情页）。
    await tester.tap(find.text('下载正文'));
    await tester.pumpAndSettle();
    expect(find.text('尚未配置同步账号，请先在"同步设置"中完成配置'), findsOneWidget);
    expect(find.text('下载正文'), findsOneWidget, reason: '保持占位可重试');
    await shutdown(tester);
  });

  testWidgets('删除：确认对话框说明语义 → 软删（删正文留元数据）+ 返回书库', (tester) async {
    await bootstrap(tester);
    await seedBook(tester);
    final localPath = p.join(store!.booksDir.path, bookId, 'source.txt');
    final coverPath = store!.resolveCoverPath(bookId);
    // 补一个封面文件：新删除语义要求正文与封面一并删除。
    await tester.runAsync(() async {
      await File(coverPath).writeAsBytes(tinyPng, flush: true);
      await db!.booksDao.updateCoverPath(bookId, coverPath);
    });
    await pumpDetail(tester);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('删除《三体》？'), findsOneWidget);
    expect(find.textContaining('立即删除'), findsOneWidget); // 语义说明
    expect(find.textContaining('未下载'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await settleReal(tester);

    // 已返回书库路由。
    expect(find.text('书库-stub'), findsOneWidget);
    // 新删除语义（docs/10 §4.7b）：books 行保留（localPath 置 NULL）+ 墓碑
    // 入账 + 正文/封面文件真删盘（不进游离区）。
    await tester.runAsync(() async {
      final book = await db!.booksDao.getById(bookId);
      expect(book, isNotNull);
      expect(book!.localPath, isNull);
      expect(book.coverPath, isNull);
      expect(book.title, '三体');
      final tombstone = await db!.select(db!.deletedBooks).getSingle();
      expect(tombstone.bookId, bookId);
      expect(tombstone.contentHash, contentHash);
      // 进度行保留（同文件重新导入后可恢复位置）。
      expect(await db!.progressDao.getByBookId(bookId), isNotNull);
      // 正文与封面文件都不在磁盘上，且没有进游离区。
      expect(File(localPath).existsSync(), isFalse);
      expect(File(coverPath).existsSync(), isFalse);
      expect(await store!.listOrphans(), isEmpty);
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
      expect(await db!.select(db!.deletedBooks).get(), isEmpty);
    });
    await shutdown(tester);
  });

  testWidgets('文件替换（FR-410）：按钮仅本地书显示，占位书不显示', (tester) async {
    useTallViewport(tester);
    await bootstrap(tester);
    await seedBook(tester);
    await pumpDetail(tester);
    final button = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('重新选择文件'),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(button.onPressed, isNotNull);
    await shutdown(tester);

    await bootstrap(tester);
    await seedBook(tester, withLocalFile: false);
    await pumpDetail(tester);
    expect(find.text('重新选择文件'), findsNothing); // 占位书无本地文件不可替换。
    expect(find.text('仅云端'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('文件替换：确认对话框警示文案（含未配置说明），取消不动数据', (tester) async {
    useTallViewport(tester);
    await bootstrap(tester);
    await seedBook(tester);
    final localPath = p.join(store!.booksDir.path, bookId, 'source.txt');
    final picker = FakeReplacePicker(null);
    await pumpDetail(tester, picker: picker);

    await tester.tap(find.text('重新选择文件'));
    await tester.pumpAndSettle();
    // 语义警示 + 进度保留说明 + 未配置同步说明（内存凭据为空 → 未配置）。
    expect(find.text('替换《三体》的正文文件？'), findsOneWidget);
    expect(find.textContaining('下次同步后更新'), findsOneWidget);
    expect(find.textContaining('大致位置（百分比）恢复'), findsOneWidget);
    expect(find.textContaining('当前未配置同步，仅替换本地文件'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('替换《三体》的正文文件？'), findsNothing);
    // 未进入选文件环节，数据未动。
    expect(picker.callCount, 0);
    expect(find.textContaining('正在替换'), findsNothing);
    await tester.runAsync(() async {
      expect(File(localPath).readAsStringSync(), '正文内容');
      expect((await db!.booksDao.getById(bookId))!.fileName, '三体.txt');
    });
    await shutdown(tester);
  });

  testWidgets('文件替换：确认后选文件 → 替换成功 → 提示 + 详情刷新', (tester) async {
    useTallViewport(tester);
    await bootstrap(tester);
    await seedBook(tester);
    // 待选新文件（真实 IO 先于 UI 流程落盘）。
    final newBytes = (await tester.runAsync(() async {
      final file = File(p.join(tmp!.path, '三体新版.txt'));
      await file.writeAsString('替换后的新正文');
      return file.readAsBytesSync();
    }))!;
    final newPath = p.join(tmp!.path, '三体新版.txt');
    final localPath = p.join(store!.booksDir.path, bookId, 'source.txt');
    final picker = FakeReplacePicker(newPath);
    var pushCalls = 0;
    String? hashAtPush;
    await pumpDetail(
      tester,
      picker: picker,
      pushToCloud: (id) async {
        pushCalls++;
        hashAtPush = (await db!.booksDao.getById(id))!.contentHash;
        return SyncReport(startedAt: DateTime.now()); // 假门面：成功报告。
      },
    );

    await tester.tap(find.text('重新选择文件'));
    await tester.pumpAndSettle();
    expect(picker.callCount, 0); // 对话框先于选文件。
    await tester.tap(find.text('选择新文件'));
    await settleReal(tester);

    expect(picker.callCount, 1);
    expect(find.text('正文已替换并开始同步'), findsOneWidget);
    // 详情已刷新：文件名/标题为替换后的值。
    expect(find.text('三体新版.txt'), findsOneWidget);
    expect(find.text('三体.txt'), findsNothing);
    expect(find.text('解析书名'), findsWidgets);

    await tester.runAsync(() async {
      // 原路径覆盖 + 行内文件指征列更新。
      expect(File(localPath).readAsBytesSync(), newBytes);
      final book = (await db!.booksDao.getById(bookId))!;
      expect(book.fileName, '三体新版.txt');
      final newHash = await ContentHasher.hashStream(Stream.value(newBytes));
      expect(book.contentHash, newHash);
      expect(book.sizeBytes, newBytes.length);
      expect(book.title, '解析书名'); // 假 handler 重解析结果。
      // 行更新先于云端推送。
      expect(pushCalls, 1);
      expect(hashAtPush, newHash);
      // 进度行不动。
      final progress = await (db!.select(
        db!.progress,
      )..where((r) => r.bookId.equals(bookId))).getSingle();
      expect(progress.percent, 0.42);
      expect(progress.dirty, isFalse);
    });
    await shutdown(tester);
  });

  testWidgets('文件替换：未配置同步走真实门面 → 本地已替换并提示', (tester) async {
    useTallViewport(tester);
    await bootstrap(tester);
    await seedBook(tester);
    final newBytes = (await tester.runAsync(() async {
      final file = File(p.join(tmp!.path, '三体新版.txt'));
      await file.writeAsString('仅本地替换的新正文');
      return file.readAsBytesSync();
    }))!;
    final localPath = p.join(store!.booksDir.path, bookId, 'source.txt');
    await pumpDetail(
      tester,
      // 真实替换服务 + 真实门面（内存凭据为空 → replaceBookContent 返回 null）。
      picker: FakeReplacePicker(p.join(tmp!.path, '三体新版.txt')),
    );

    await tester.tap(find.text('重新选择文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择新文件'));
    await settleReal(tester);

    expect(find.text('本地文件已替换（未配置同步，云端未更新）'), findsOneWidget);
    await tester.runAsync(() async {
      expect(File(localPath).readAsBytesSync(), newBytes);
      final book = (await db!.booksDao.getById(bookId))!;
      expect(book.fileName, '三体新版.txt');
    });
    await shutdown(tester);
  });

  testWidgets('文件替换：取消选择文件 → 静默返回，按钮恢复可用', (tester) async {
    useTallViewport(tester);
    await bootstrap(tester);
    await seedBook(tester);
    final picker = FakeReplacePicker(null);
    await pumpDetail(tester, picker: picker);

    await tester.tap(find.text('重新选择文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择新文件'));
    await settleReal(tester);

    expect(picker.callCount, 1);
    expect(find.textContaining('正在替换'), findsNothing);
    expect(find.textContaining('替换失败'), findsNothing);
    final button = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('重新选择文件'),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(button.onPressed, isNotNull);
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
        child: MaterialApp.router(
          routerConfig: buildRouter(),
          theme: AppTheme.light(AppAccent.terracotta),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('书籍不存在或已删除'), findsOneWidget);
    await shutdown(tester);
  });

  group('三档宽度无溢出冒烟（v1.1 A7 布局）', () {
    for (final (width, height) in const [
      (1440.0, 900.0),
      (860.0, 900.0),
      (390.0, 844.0),
    ]) {
      testWidgets('宽度 $width', (tester) async {
        tester.view.physicalSize = Size(width, height);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await bootstrap(tester);
        await seedBook(tester);
        await pumpDetail(tester);
        expect(tester.takeException(), isNull);
        await shutdown(tester);
      });
    }
  });

  test('locatorChapterNumber：txt/md/epub 坐标取章序（1 起），pdf/空/损坏取不到', () {
    expect(
      locatorChapterNumber('{"type":"txt","chapterIndex":127,"charOffset":0}'),
      128,
    );
    expect(
      locatorChapterNumber(
        '{"type":"md","headingIndex":0,"blockIndex":0,"charOffset":0}',
      ),
      1,
    );
    expect(
      locatorChapterNumber(
        '{"type":"epub","spineIndex":11,"href":"c12.xhtml","blockIndex":0,"charOffset":0}',
      ),
      12,
    );
    expect(
      locatorChapterNumber('{"type":"pdf","pageIndex":3,"yRatio":0.5}'),
      isNull,
    );
    expect(locatorChapterNumber('{}'), isNull);
    expect(locatorChapterNumber(null), isNull);
    expect(locatorChapterNumber(''), isNull);
    expect(locatorChapterNumber('not-json'), isNull);
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
  bool withProgress = true,
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
  if (withProgress) {
    await db.progressDao.upsert(
      bookId: bookId,
      locatorJson: '{}',
      percent: 0.42,
      dirty: false,
    );
  }
}

/// 假文件选择器（FR-410）：返回预置路径（null = 模拟用户取消），
/// 记录调用次数供"对话框先于选文件 / 取消静默返回"断言。
class FakeReplacePicker implements ReplaceFilePicker {
  FakeReplacePicker(this.path);

  /// 预置返回的文件路径；null = 用户取消。
  final String? path;

  int callCount = 0;

  @override
  Future<String?> pickBookFile() async {
    callCount++;
    return path;
  }
}
