/// ReaderPage 集成骨架测试（FR-201/206/207/208 + FR-108 目录抽屉 +
/// v1.1 A8 沉浸态/热区/控制条/首次提示）：注入内存库 + 假 handler/渲染器
/// （做法参考 test/library/fake_handler.dart），验证打开链路（restore 被调用）、
/// 沉浸态与点击热区、目录抽屉（层级缩进 + 当前章高亮 + 触发 jumpTo）、
/// 占位书提示页、错误页 + 重试、设置热应用、书不存在自动返回。
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/core/design_tokens.dart';
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
  ///
  /// 尾部把首次提示的 2.6s 定时器泵完（不留悬挂 Timer）；需要观察提示
  /// 本身的用例自行挂载页面（见「首次进入轻提示」用例）。
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
    // 泵完轻提示的 2.6s 停留 + 300ms 淡出（清掉悬挂 Timer）。
    await tester.pump(const Duration(milliseconds: 2900));
    return renderer;
  }

  testWidgets('打开链路：restore 被调用且传入已存进度，书名在顶条可见', (tester) async {
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
    // 正文区为渲染器视图，顶条含书名（控制条默认隐藏但仍在树中）。
    expect(find.byKey(const ValueKey('fake-renderer-view')), findsOneWidget);
    expect(find.text('假书名'), findsOneWidget);
  });

  group('v1.1 A8 沉浸态与热区（Q10）', () {
    testWidgets('默认沉浸：无 AppBar、控制条隐藏（点目录按钮无效）', (tester) async {
      final renderer = await pumpReady(
        tester,
        toc: const [TocEntry(title: '第一章', level: 0, anchor: 0)],
      );

      // 无 AppBar（沉浸态，Q10）。
      expect(find.byType(AppBar), findsNothing);
      // 渲染器视图铺满正文。
      expect(find.byKey(const ValueKey('fake-renderer-view')), findsOneWidget);
      // 控制条在树中但被 IgnorePointer 拦截：点目录按钮打不开抽屉。
      await tester.tap(find.byKey(const ValueKey('reader-toc-button')));
      await tester.pump();
      expect(find.text('第一章'), findsNothing, reason: '沉浸态目录按钮不响应');
      expect(renderer.controller.jumpCalls, isEmpty);
    });

    testWidgets('点正文中部唤出控制条，再点收起', (tester) async {
      await pumpReady(
        tester,
        toc: const [TocEntry(title: '第一章', level: 0, anchor: 0)],
      );

      // 唤出：控制条滑入动画完成后目录按钮恢复响应。
      await tester.tap(find.byKey(const ValueKey('reader-hot-mid')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-toc-button')));
      await tester.pumpAndSettle();
      expect(find.text('第一章'), findsOneWidget, reason: '目录抽屉已打开');
      await tester.tap(find.byKey(const ValueKey('reader-toc-close')));
      await tester.pumpAndSettle();

      // 收起：再点中部，等滑出动画完成后目录按钮不再响应。
      await tester.tap(find.byKey(const ValueKey('reader-hot-mid')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-toc-button')));
      await tester.pump();
      expect(find.text('第一章'), findsNothing, reason: '控制条已收起');
    });

    testWidgets('移动端（窄视口）：点屏幕任意处唤出控制条，滑动才翻页',
        (tester) async {
      // 窄视口（≤460）= 手机形态：正文几乎铺满屏幕，没有可点的空白，
      // 因此点任意处都唤出控制条（含左右翼），翻页交给滑动。
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final renderer = await pumpReady(
        tester,
        toc: const [TocEntry(title: '第一章', level: 0, anchor: 0)],
      );

      // 点中区（哪怕点在正文上）→ 控制条出现（目录按钮恢复响应）。
      await tester.tap(find.byKey(const ValueKey('reader-hot-mid')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-toc-button')));
      await tester.pumpAndSettle();
      expect(find.text('第一章'), findsOneWidget, reason: '点中区即唤出控制条');
      await tester.tap(find.byKey(const ValueKey('reader-toc-close')));
      await tester.pumpAndSettle();

      // 再点中区 → 控制条收起。
      await tester.tap(find.byKey(const ValueKey('reader-hot-mid')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-toc-button')));
      await tester.pump();
      expect(find.text('第一章'), findsNothing, reason: '再点中区收起控制条');

      // 点左翼 → 同样唤出控制条，且**不**翻页。
      await tester.tap(find.byKey(const ValueKey('reader-hot-prev')));
      await tester.pumpAndSettle();
      expect(renderer.controller.turnCalls, isEmpty, reason: '移动端点按不翻页');
      await tester.tap(find.byKey(const ValueKey('reader-toc-button')));
      await tester.pumpAndSettle();
      expect(find.text('第一章'), findsOneWidget, reason: '点左翼也能唤出控制条');
    });

    testWidgets('移动端：滑动翻页不弹出控制条', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpReady(
        tester,
        toc: const [TocEntry(title: '第一章', level: 0, anchor: 0)],
      );

      // 在中区做一次纵向滑动（翻页手势）→ 控制条不应被唤出。
      await tester.drag(
        find.byKey(const ValueKey('reader-hot-mid')),
        const Offset(0, -220),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-toc-button')));
      await tester.pump();
      expect(
        find.text('第一章'),
        findsNothing,
        reason: '滑动后控制条仍是隐藏态（滑动不弹菜单）',
      );
    });

    testWidgets('左右翼区点击触发翻页（与 FR-209 音量键同一路径）', (tester) async {
      final renderer = await pumpReady(tester);

      await tester.tap(find.byKey(const ValueKey('reader-hot-next')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('reader-hot-next')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('reader-hot-prev')));
      await tester.pump();

      expect(renderer.controller.turnCalls, [1, 1, -1]);
    });

    testWidgets('首次进入轻提示：2.6s 后自动淡出', (tester) async {
      final renderer = FakeRenderer();
      final handler = FakeHandler(toc: const [], renderer: renderer);
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

      // 提示可见（Q10：进入阅读器即显示）。
      expect(find.text('滑动翻页'), findsOneWidget);
      double hintOpacity() => tester
          .widget<AnimatedOpacity>(
            find
                .ancestor(
                  of: find.text('滑动翻页'),
                  matching: find.byType(AnimatedOpacity),
                )
                .first,
          )
          .opacity;
      expect(hintOpacity(), 1, reason: '进入即显示（目标透明度 1）');
      // 2.6s 停留后定时器触发淡出（目标透明度翻转为 0，渲染值 300ms 收敛）。
      await tester.pump(const Duration(milliseconds: 2600));
      expect(hintOpacity(), 0, reason: '2.6s 自动淡出已触发');
      await tester.pump(const Duration(milliseconds: 400));
      expect(hintOpacity(), 0);
    });

    testWidgets('控制条与音量键翻页并存：控制条显隐不影响翻页路径', (tester) async {
      final renderer = await pumpReady(tester);
      // 沉浸态下音量键路径（controller.nextPage）照常可用。
      expect(await renderer.controller.nextPage(), isTrue);
      expect(renderer.controller.turnCalls, [1]);
      // 唤出控制条后再翻页，仍走同一路径。
      await tester.tap(find.byKey(const ValueKey('reader-hot-mid')));
      await tester.pump();
      expect(await renderer.controller.nextPage(), isTrue);
      expect(renderer.controller.turnCalls, [1, 1]);
    });
  });

  testWidgets('目录抽屉：渲染条目、层级缩进、当前章高亮，点击触发 jumpTo 并关闭', (tester) async {
    final renderer = await pumpReady(
      tester,
      toc: const [
        TocEntry(title: '第一章 起点', level: 0, anchor: 0),
        TocEntry(title: '第二章 转折', level: 0, anchor: 1),
        TocEntry(title: '小结', level: 1, anchor: 2),
      ],
    );
    renderer.currentTocTitle = '第二章 转折';
    await tester.pump();

    // 唤出控制条 → 打开目录抽屉。
    await tester.tap(find.byKey(const ValueKey('reader-hot-mid')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-toc-button')));
    await tester.pumpAndSettle();
    expect(find.text('第一章 起点'), findsOneWidget);
    expect(find.text('小结'), findsOneWidget);
    // 当前章出现三处：抽屉条目 + 顶条副标题 + 底条章节名（A8）。
    expect(find.text('第二章 转折'), findsNWidgets(3));
    // 当前章带「当前」标记（A8：isTocEntryCurrent 比对）。
    expect(find.text('当前'), findsOneWidget);
    // 头部章数徽标。
    expect(find.text('3 章'), findsOneWidget);
    // 层级缩进：level 1 条目左缩进 = 12 + 16×1 = 28（level 0 = 12）。
    double leftPaddingOf(String title) {
      final container = tester.widget<Container>(
        find
            .ancestor(of: find.text(title), matching: find.byType(Container))
            .first,
      );
      return (container.padding! as EdgeInsets).left;
    }

    expect(leftPaddingOf('第一章 起点'), 12.0);
    expect(leftPaddingOf('小结'), 28.0, reason: 'level 1 按级缩进');

    // 点击抽屉内的当前章条目（同名文本有 3 处，限定抽屉范围）。
    await tester.tap(
      find.descendant(of: find.byType(Drawer), matching: find.text('第二章 转折')),
    );
    await tester.pumpAndSettle();

    expect(renderer.controller.jumpCalls.single.title, '第二章 转折');
    // 抽屉已关闭（条目不再可见）。
    expect(find.text('第一章 起点'), findsNothing);
  });

  testWidgets('目录抽屉：应用外壳配色 + 统一抽屉宽度 + 品牌色当前项', (
    tester,
  ) async {
    final renderer = await pumpReady(
      tester,
      toc: const [
        TocEntry(title: '第一章 起点', level: 0, anchor: 0),
        TocEntry(title: '第二章 转折', level: 0, anchor: 1),
        TocEntry(title: '小结', level: 1, anchor: 2),
      ],
    );
    renderer.currentTocTitle = '第二章 转折';
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('reader-hot-mid')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-toc-button')));
    await tester.pumpAndSettle();

    final scheme = Theme.of(
      tester.element(find.descendant(of: find.byType(Drawer), matching: find.byType(Column)).first),
    ).colorScheme;

    // 宽度 = 桌面端阅读页右侧抽屉的统一宽度（目录与阅读设置共用）。
    expect(
      tester.widget<Drawer>(find.byType(Drawer)).width,
      AppLayout.readerDrawerWidth,
    );

    // 抽屉底色 = 应用外壳 surface（不是阅读主题底色）：由 Drawer 的
    // Material 承载（内层不铺底色，条目 hover 的 `--surface-3` 才能透出）。
    expect(tester.widget<Drawer>(find.byType(Drawer)).backgroundColor, scheme.surface);

    // 当前项：底色 = 品牌色 14% 透明、文字 = 品牌色、字重 600。
    final currentText = tester.widget<Text>(
      find.descendant(of: find.byType(Drawer), matching: find.text('第二章 转折')),
    );
    expect(currentText.style!.color, scheme.primary);
    expect(currentText.style!.fontWeight, FontWeight.w600);
    final currentRowBg = tester
        .widgetList<Container>(
          find.descendant(of: find.byType(Drawer), matching: find.byType(Container)),
        )
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .map((d) => d.color)
        .whereType<Color>()
        .toList();
    expect(
      currentRowBg,
      contains(scheme.primary.withValues(alpha: 0.14)),
      reason: '当前项底色为品牌色 14% 透明',
    );

    // 「当前」徽标：字号 10、底 = 品牌色 18% 透明、字 = 品牌色。
    final badge = tester.widget<Text>(
      find.descendant(of: find.byType(Drawer), matching: find.text('当前')),
    );
    expect(badge.style!.fontSize, 10);
    expect(badge.style!.color, scheme.primary);

    // 普通一级项：字号 13、文字 = onSurface 82% 透明度。
    final normalText = tester.widget<Text>(
      find.descendant(of: find.byType(Drawer), matching: find.text('第一章 起点')),
    );
    expect(normalText.style!.fontSize, 13);
    expect(normalText.style!.color, scheme.onSurface.withValues(alpha: 0.82));

    // 二级项：字号 12.5、文字 = onSurface 72% 透明度。
    final subText = tester.widget<Text>(
      find.descendant(of: find.byType(Drawer), matching: find.text('小结')),
    );
    expect(subText.style!.fontSize, 12.5);
    expect(subText.style!.color, scheme.onSurface.withValues(alpha: 0.72));
  });

  testWidgets('无 toc：不显示目录按钮（Aa 排版按钮常在）', (tester) async {
    await pumpReady(tester);
    expect(find.byKey(const ValueKey('reader-toc-button')), findsNothing);
    // Aa 排版按钮常显（在顶条中，控制条隐藏时也在树中）。
    expect(find.byKey(const ValueKey('reader-settings-button')), findsOneWidget);
  });

  testWidgets('Aa 面板双形态：桌面右侧抽屉 / 移动底部弹层（A9）', (tester) async {
    // 桌面宽度（>860）：右侧抽屉形态。
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpReady(tester);

    await tester.tap(find.byKey(const ValueKey('reader-hot-mid')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-settings-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-aa-drawer')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-aa-sheet')), findsNothing);
    expect(find.text('阅读设置'), findsOneWidget);
    // 阅读设置抽屉与目录抽屉同宽（两个右侧面板宽度一致）。
    expect(
      tester
          .widgetList<SizedBox>(
            find.descendant(
              of: find.byKey(const ValueKey('reader-aa-drawer')),
              matching: find.byType(SizedBox),
            ),
          )
          .first
          .width,
      AppLayout.readerDrawerWidth,
    );
    await tester.tap(find.byKey(const ValueKey('aa-close')));
    await tester.pumpAndSettle();

    // 移动宽度（≤860）：底部弹层形态。
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('reader-settings-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reader-aa-sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-aa-drawer')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('aa-close')));
    await tester.pumpAndSettle();
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
        .save(const ReaderSettings(fontSize: 26, theme: ReaderTheme.beige));
    await tester.pump();

    expect(renderer.applySettingsCount, 1);
    expect(renderer.lastApplied?.fontSize, 26);
    expect(renderer.lastApplied?.theme, ReaderTheme.beige);
  });

  group('v1.3.6：新打开的书必须用当前设置（不得回退出厂默认）', () {
    // 用户实测：「移动端无法切换滚动和分页模式」——切到滚动后换一本书，
    // 翻页模式又变回默认分页：打开链路取的是仓库 load() 的**首次快照**。
    testWidgets('改过设置后新开的书：渲染器按新设置创建', (tester) async {
      final handler = FakeHandler();
      await makeEnv(handler);
      await db!.booksDao.upsertCompanion(bookRow('b1'));
      await db!.booksDao.upsertCompanion(bookRow('b2'));

      // 先开第一本（触发仓库首次 load → 旧实现此后一直返回该快照）。
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container!,
          child: const MaterialApp(
            home: ReaderPage(key: ValueKey('b1'), bookId: 'b1'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // 用户把翻页模式切到滚动（等价于在 Aa 面板里切）。
      await container!
          .read(readerSettingsRepositoryProvider)
          .save(
            ReaderSettings.defaults.copyWith(
              pageMode: ReaderPageMode.scroll,
              fontSize: 24,
            ),
          );
      await tester.pump();

      // 再开第二本：渲染器创建时用的设置必须是**当前**设置。
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container!,
          child: const MaterialApp(
            home: ReaderPage(key: ValueKey('b2'), bookId: 'b2'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      // 打开链路（查书行 → 读设置 → 建渲染器）跨多个异步轮次：再泵几帧。
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        handler.createdSettings,
        isNotEmpty,
        reason: '第二本应创建渲染器',
      );
      expect(
        handler.createdSettings.last.pageMode,
        ReaderPageMode.scroll,
        reason: '换书后翻页模式不得回退默认分页',
      );
      expect(handler.createdSettings.last.fontSize, 24, reason: '字号也不得回退默认');
    });
  });
}
