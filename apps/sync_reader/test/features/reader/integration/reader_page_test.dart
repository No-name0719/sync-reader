/// ReaderPage 集成骨架测试（FR-201/206/207/208 与 FR-108 抽屉）：
/// 注入内存库 + 假 handler/渲染器（做法参考 test/library/fake_handler.dart），
/// 验证打开链路（restore 被调用）、目录抽屉（渲染条目 + 触发 jumpTo）、
/// 占位书提示页、错误页 + 重试、设置热应用、书不存在自动返回。
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/features/reader/contract/format_registry.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/contract/toc_entry.dart';
import 'package:sync_reader/features/reader/reader_page.dart';

import 'fakes.dart';

/// 造一本书行（字段可覆盖）。
///
/// [tocFingerprint] 默认与 fakes.dart 假 handler 的解析指纹不一致；
/// 需要验证"指纹一致时原锚点直传 restore"的用例应传入
/// 'tfp:0123456789abcdef'（指纹门 docs/05 §3.3 恢复规则 1）。
BooksCompanion bookRow(
  String id, {
  String title = '假书名',
  String format = 'txt',
  String? localPath = '/books/x.txt',
  String tocFingerprint = 'tfp:0000000000000000',
}) => BooksCompanion.insert(
  bookId: id,
  title: title,
  format: format,
  fileName: '$id.$format',
  contentHash: 'sha256:$id',
  sizeBytes: 128,
  tocFingerprint: tocFingerprint,
  addedAt: 1000,
  localPath: Value(localPath),
);

void main() {
  AppDatabase? db;
  ProviderContainer? container;

  /// 建内存库 + 带 registry 覆写的容器（handler 由用例提供）。
  Future<void> makeEnv(FakeHandler handler) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    await database.customSelect('SELECT 1').getSingle();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        formatRegistryProvider.overrideWithValue(
          FormatRegistry()..register(handler),
        ),
      ],
    );
    db = database;
  }

  tearDown(() async {
    container?.dispose();
    container = null;
    await db?.close();
    db = null;
  });

  /// 打开成功路径的公共准备：建库、写书行（可选写进度）、挂载阅读页。
  Future<FakeRenderer> pumpReady(
    WidgetTester tester, {
    List<TocEntry> toc = const [],
    BookProgress? seedProgress,
    String bookId = 'b1',
  }) async {
    final renderer = FakeRenderer();
    final handler = FakeHandler(toc: toc, renderer: renderer);
    await makeEnv(handler);
    await db!.booksDao.upsertCompanion(bookRow(bookId));
    if (seedProgress != null) {
      await db!.progressDao.upsert(
        bookId: bookId,
        locatorJson: seedProgress.locatorJson,
        percent: seedProgress.percent,
        dirty: seedProgress.dirty,
      );
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container!,
        child: MaterialApp(home: ReaderPage(bookId: bookId)),
      ),
    );
    // 两帧：首帧挂载 + microtask 排空（drift 查询 → 打开链路完成）。
    await tester.pump();
    await tester.pump();
    return renderer;
  }

  testWidgets('打开链路：restore 被调用且传入已存进度，AppBar 显示书名', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    final renderer = await pumpReady(
      tester,
      seedProgress: BookProgress(
        bookId: 'b1',
        locatorJson: '{"type":"fake","pos":3}',
        percent: 0.25,
        updatedAt: 1,
        dirty: true,
      ),
    );
    // 本用例验证"restore 传入已存进度"：pumpReady 的假 handler 默认 toc 为空
    // （解析失败降级形态），指纹门跳过比对，原锚点原样传入 restore。
    // 指纹不一致时的降级行为见 test/reader/epub/epub_fingerprint_gate_test.dart。

    expect(renderer.controller.restoreCalls, hasLength(1));
    expect(
      renderer.controller.restoreCalls.single.locatorJson,
      '{"type":"fake","pos":3}',
    );
    expect(renderer.controller.restoreCalls.single.percent, 0.25);
    // 正文区为渲染器视图，AppBar 标题为书名。
    expect(find.byKey(const ValueKey('fake-renderer-view')), findsOneWidget);
    expect(find.text('假书名'), findsOneWidget);
  });

  testWidgets('目录抽屉：渲染 toc 条目，点击触发 jumpTo 并关闭抽屉', (tester) async {
    final renderer = await pumpReady(
      tester,
      toc: const [
        TocEntry(title: '第一章 起点', level: 0, anchor: 0),
        TocEntry(title: '第二章 转折', level: 0, anchor: 1),
        TocEntry(title: '小结', level: 1, anchor: 2),
      ],
    );

    // toc 非空才显示目录按钮。
    await tester.tap(find.byKey(const ValueKey('reader-toc-button')));
    await tester.pumpAndSettle();
    expect(find.text('第一章 起点'), findsOneWidget);
    expect(find.text('第二章 转折'), findsOneWidget);
    expect(find.text('小结'), findsOneWidget);

    await tester.tap(find.text('第二章 转折'));
    await tester.pumpAndSettle();

    expect(renderer.controller.jumpCalls.single.title, '第二章 转折');
    // 抽屉已关闭（条目不再可见）。
    expect(find.text('第一章 起点'), findsNothing);
  });

  testWidgets('无 toc：不显示目录按钮', (tester) async {
    await pumpReady(tester);
    expect(find.byKey(const ValueKey('reader-toc-button')), findsNothing);
    // 设置按钮常显。
    expect(
      find.byKey(const ValueKey('reader-settings-button')),
      findsOneWidget,
    );
  });

  testWidgets('占位书（localPath 为 null）：显示正文未下载提示页', (tester) async {
    final renderer = FakeRenderer();
    final handler = FakeHandler(renderer: renderer);
    await makeEnv(handler);
    await db!.booksDao.upsertCompanion(bookRow('b1', localPath: null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container!,
        child: const MaterialApp(home: ReaderPage(bookId: 'b1')),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('正文尚未下载'), findsOneWidget);
    // FR-402：占位页提供"下载正文"入口（Phase C 同步已上线）。
    expect(
      find.byKey(const ValueKey('reader-download-button')),
      findsOneWidget,
    );
    // 未创建渲染器。
    expect(renderer.controller.restoreCalls, isEmpty);
  });

  testWidgets('渲染器创建失败：错误页 + 重试按钮', (tester) async {
    final handler = FakeHandler(createRendererError: StateError('渲染器坏了'));
    await makeEnv(handler);
    await db!.booksDao.upsertCompanion(bookRow('b1'));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container!,
        child: MaterialApp(home: ReaderPage(bookId: 'b1')),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('无法打开本书'), findsOneWidget);
    expect(find.textContaining('渲染器坏了'), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-retry-button')), findsOneWidget);
  });

  testWidgets('书不存在：自动 pop 返回', (tester) async {
    await makeEnv(FakeHandler());
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container!,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ReaderPage(bookId: 'missing'),
                    ),
                  ),
                  child: const Text('打开阅读'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开阅读'));
    await tester.pump(); // 路由压入 + 打开链路启动
    await tester.pump(); // 书不存在状态 + postFrame 自动 pop
    await tester.pump(); // pop 动画启动
    await tester.pumpAndSettle();
    // 已自动返回书库页。
    expect(find.text('打开阅读'), findsOneWidget);
  });

  testWidgets('设置热应用：仓库 save 广播 → 渲染器 applySettings 被调用', (tester) async {
    final renderer = await pumpReady(tester);

    await container!
        .read(readerSettingsRepositoryProvider)
        .save(const ReaderSettings(fontSize: 26, theme: ReaderTheme.paper));
    await tester.pump();

    expect(renderer.applySettingsCount, 1);
    expect(renderer.lastApplied?.fontSize, 26);
    expect(renderer.lastApplied?.theme, ReaderTheme.paper);
  });
}
