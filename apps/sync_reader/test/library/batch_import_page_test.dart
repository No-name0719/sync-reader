/// 批量导入页 widget 测试（FR-109 + docs/10 §4.2/§4.8 重设计，A13/A16）：
/// 首屏选择文件夹、清单渲染与勾选、「同时上传到云端」开关（Q18 默认开 +
/// 关上提示行）、导入进度与完成汇总、上传开关落到 local_only 标记、
/// 「完成」返回书库。清单交互用假控制器；端到端管线用临时目录夹具文件
/// 驱动真实 scanner + service（真实 IO 经 tester.runAsync）。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/core/design_tokens.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/features/library/import/batch_import_controller.dart';
import 'package:sync_reader/features/library/import/batch_import_page.dart';
import 'package:sync_reader/features/library/import/book_import_service.dart';
import 'package:sync_reader/features/library/import/book_scanner.dart';
import 'package:sync_reader/features/library/library_providers.dart';
import 'package:sync_reader/features/reader/contract/format_registry.dart';

import 'fake_handler.dart';

void main() {
  AppDatabase? db;
  Directory? tmp;
  Directory? scanDir;
  Directory? storeDir;

  Future<void> bootstrap(WidgetTester tester) async {
    await tester.runAsync(() async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      await database.customSelect('SELECT 1').getSingle();
      db = database;
      final tmpDir = await Directory.systemTemp.createTemp('batch_page_test');
      tmp = tmpDir;
      final scan = Directory(p.join(tmpDir.path, 'scan'));
      final store = Directory(p.join(tmpDir.path, 'store'));
      scanDir = scan;
      storeDir = store;
      await scan.create();
      final bookStore = BookFileStore(store);
      await bookStore.ensureLayout();
    });
    addTearDown(() async {
      await tester.pump(const Duration(seconds: 60));
      await tester.runAsync(() async {
        await db?.close();
        db = null;
        if (tmp != null && tmp!.existsSync()) {
          await tmp!.delete(recursive: true);
        }
        tmp = null;
      });
    });
  }

  /// 在扫描目录写一个候选文件（真实 IO 必须在 runAsync 窗口内完成，
  /// 否则 future 在 fakeAsync 区永不交付）。
  Future<File> candidate(
    WidgetTester tester,
    String name,
    List<int> bytes,
  ) async {
    final file = await tester.runAsync(() async {
      final target = File(p.join(scanDir!.path, name));
      await target.writeAsBytes(bytes);
      return target;
    });
    return file!;
  }

  /// 预置一本库内已有书（正文哈希与指定字节一致，驱动「库内已有」标注）。
  Future<void> seedExistingBook({
    required String title,
    required List<int> bytes,
  }) async {
    final hash = 'sha256:${sha256.convert(bytes).toString()}';
    await db!.booksDao.upsertCompanion(
      BooksCompanion.insert(
        bookId: 'EXIST01',
        title: title,
        format: 'txt',
        fileName: 'existing.txt',
        contentHash: hash,
        sizeBytes: bytes.length,
        tocFingerprint: 'tfp:0000000000000000',
        addedAt: 1,
      ),
    );
  }

  /// 泵入页面：真控制器 + 真 scanner/service（夹具文件驱动）+ 假目录选择器。
  Future<ProviderContainer> pumpReal(
    WidgetTester tester,
    _FakePicker picker,
  ) async {
    final store = BookFileStore(storeDir!);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db!),
        formatRegistryProvider.overrideWithValue(
          FormatRegistry()..register(FakeHandler()),
        ),
        directoryPickerProvider.overrideWithValue(picker),
        bookImportServiceProvider.overrideWithValue(
          BookImportService(
            booksDao: db!.booksDao,
            registry: FormatRegistry()..register(FakeHandler()),
            fileStore: Future.value(store),
            // 「同时上传到云端」开关的落点（docs/10 §4.7c）。
            localOnlyDao: db!.localOnlyBooksDao,
          ),
        ),
      ],
    );
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
    return container;
  }

  /// 轮询控制器状态直到满足条件。扫描/导入链路是「真实 IO（仅在 runAsync
  /// 窗口内推进）+ drift 微任务（仅 pump 推进）」的混合，必须交替开窗；
  /// 超时即 fail（避免后续 pumpAndSettle 挂在不确定动画上拖满 10 分钟）。
  Future<void> waitUntil(
    WidgetTester tester,
    ProviderContainer container,
    bool Function(BatchImportState) done,
  ) async {
    for (var i = 0; i < 300; i++) {
      if (done(container.read(batchImportControllerProvider))) return;
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    final state = container.read(batchImportControllerProvider);
    fail('waitUntil 超时：phase=${state.phase} error=${state.errorMessage}');
  }

  testWidgets('首屏：说明 + 选择文件夹按钮；点按钮调目录选择器并开始扫描', (tester) async {
    await bootstrap(tester);
    final picker = _FakePicker(scanDir!.path);
    await candidate(tester, '甲.txt', [1, 2, 3]);
    final container = await pumpReal(tester, picker);

    expect(find.text('批量导入（文件夹）'), findsOneWidget);
    expect(find.text('选择文件夹'), findsOneWidget);
    expect(picker.calls, 0);

    await tester.tap(find.byKey(const ValueKey('batch-pick-folder')));
    await tester.pump();
    expect(picker.calls, 1);
    // 扫描经真实 IO：轮询到 ready 再断言清单。
    await waitUntil(
      tester,
      container,
      (s) => s.phase == BatchImportPhase.ready,
    );
    await tester.pumpAndSettle();
    expect(find.text('甲.txt'), findsOneWidget);
    expect(find.textContaining('1 个文件'), findsOneWidget);
  });

  testWidgets('端到端：清单渲染（格式徽标 / 大小 / 库内已有标注 / 默认勾选）→ 导入 → 汇总 → 完成', (
    tester,
  ) async {
    await bootstrap(tester);
    await candidate(tester, '甲.txt', [1, 2, 3]);
    await candidate(tester, '乙.epub', [4, 5, 6]);
    await candidate(tester, '旧书.md', [9, 9, 9]);
    await seedExistingBook(title: '库内书名', bytes: [9, 9, 9]);
    final container = await pumpReal(tester, _FakePicker(scanDir!.path));

    await tester.tap(find.byKey(const ValueKey('batch-pick-folder')));
    await waitUntil(
      tester,
      container,
      (s) => s.phase == BatchImportPhase.ready,
    );
    await tester.pumpAndSettle();

    // 清单行：文件名 + 格式 · 大小；重复项标注「库内已有」且默认不勾。
    // （扫描器按相对路径字典序排序：乙 < 旧 < 甲。）
    expect(find.text('甲.txt'), findsOneWidget);
    expect(find.text('乙.epub'), findsOneWidget);
    expect(find.text('旧书.md'), findsOneWidget);
    expect(find.text('TXT'), findsOneWidget);
    expect(find.text('EPUB'), findsOneWidget);
    expect(find.text('MD'), findsOneWidget);
    expect(find.textContaining('库内已有《库内书名》'), findsOneWidget);
    Checkbox checkboxAt(int i) =>
        tester.widget<Checkbox>(find.byType(Checkbox).at(i));
    expect(checkboxAt(0).value, isTrue, reason: '乙.epub 新书默认勾选');
    expect(checkboxAt(1).value, isFalse, reason: '旧书.md 重复项默认不勾（FR-109）');
    expect(checkboxAt(2).value, isTrue, reason: '甲.txt 新书默认勾选');
    expect(find.textContaining('已选 2 / 3 本'), findsOneWidget);

    // 勾选联动。
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pump();
    expect(find.textContaining('已选 3 / 3 本'), findsOneWidget);

    // 导入 → 常驻进度（真实 IO 很快，轮询到 done 再断言汇总）。
    await tester.tap(find.byKey(const ValueKey('batch-import-start')));
    await waitUntil(tester, container, (s) => s.phase == BatchImportPhase.done);
    await tester.pumpAndSettle();

    expect(find.text('批量导入完成'), findsOneWidget);
    expect(find.textContaining('成功 2 本'), findsOneWidget);
    expect(find.textContaining('跳过重复 1 本'), findsOneWidget);
    expect(find.textContaining('《库内书名》已存在'), findsOneWidget);
    expect(find.textContaining('导入失败'), findsNothing);
    // 「完成」按钮 → 返回书库首页（stub）。
    await tester.tap(find.byKey(const ValueKey('batch-done')));
    await tester.pumpAndSettle();
    expect(find.text('书库首页-stub'), findsOneWidget);

    // 端到端兜底：书已入库（2 新增 + 1 已有）。
    await tester.runAsync(() async {
      final books = await db!.booksDao.readAllBookIds();
      expect(books.length, 3);
    });
  });

  testWidgets('「同时上传到云端」开关：默认开；关上出现不上传提示行；关闭导入落仅本地标记', (tester) async {
    await bootstrap(tester);
    await candidate(tester, '甲.txt', [1, 2, 3]);
    await candidate(tester, '旧书.md', [9, 9, 9]);
    await seedExistingBook(title: '库内书名', bytes: [9, 9, 9]);
    final container = await pumpReal(tester, _FakePicker(scanDir!.path));

    await tester.tap(find.byKey(const ValueKey('batch-pick-folder')));
    await waitUntil(
      tester,
      container,
      (s) => s.phase == BatchImportPhase.ready,
    );
    await tester.pumpAndSettle();

    // Q18：默认开（无提示行）。
    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches, hasLength(1));
    expect(switches.single.value, isTrue);
    expect(find.textContaining('不上传：不消耗上行流量'), findsNothing);

    // 关上 → 提示行出现。
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(find.text('不上传：不消耗上行流量，其它设备看不到这几本书'), findsOneWidget);

    // 关上导入：新书 + 被勾选的重复书都落仅本地标记（勾选状态落到已有书上）。
    // （排序：乙 < 旧 < 甲 → 行 0 = 旧书.md 重复项，行 1 = 甲.txt 新书。）
    await tester.tap(find.byType(Checkbox).at(0));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('batch-import-start')));
    await waitUntil(tester, container, (s) => s.phase == BatchImportPhase.done);
    await tester.pumpAndSettle();
    expect(find.textContaining('成功 1 本'), findsOneWidget);
    expect(find.textContaining('跳过重复 1 本'), findsOneWidget);
    await tester.runAsync(() async {
      final books = await db!.booksDao.readAllBookIds();
      for (final id in books) {
        expect(
          await db!.localOnlyBooksDao.isLocalOnly(id),
          isTrue,
          reason: '关闭上传后所有涉及的书（含复用的已有书）都应标记仅本地',
        );
      }
    });
  });

  testWidgets('默认开导入：不写仅本地标记（照常参与同步）', (tester) async {
    await bootstrap(tester);
    await candidate(tester, '甲.txt', [1, 2, 3]);
    final container = await pumpReal(tester, _FakePicker(scanDir!.path));

    await tester.tap(find.byKey(const ValueKey('batch-pick-folder')));
    await waitUntil(
      tester,
      container,
      (s) => s.phase == BatchImportPhase.ready,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('batch-import-start')));
    await waitUntil(tester, container, (s) => s.phase == BatchImportPhase.done);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final books = await db!.booksDao.readAllBookIds();
      expect(books, hasLength(1));
      expect(await db!.localOnlyBooksDao.isLocalOnly(books.single), isFalse);
    });
  });

  // ---- 假控制器分支（清单交互 / 进度冻结 / 汇总口径，无真实 IO）----
  // 清单夹具与假控制器见文件末尾顶层定义（fakeFile / readyState）。

  Future<ProviderContainer> pumpFake(
    WidgetTester tester, {
    _FakeController? controller,
    GoRouter? router,
    Size? size,
  }) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    final container = ProviderContainer(
      overrides: [
        batchImportControllerProvider.overrideWith(
          () => controller ?? _FakeController(readyState),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.light(AppAccent.terracotta),
          routerConfig: router ?? _buildRouter(),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  testWidgets('假控制器：清单渲染 / 勾选联动 / 全选反选', (tester) async {
    await pumpFake(tester);

    expect(find.text('三体.txt'), findsOneWidget);
    expect(find.textContaining('库内已有《库内书名》'), findsOneWidget);
    expect(find.textContaining('TXT · 1.00 KB'), findsOneWidget);
    expect(find.textContaining('已选 2 / 3 本'), findsOneWidget);
    expect(find.text('导入选中（2）'), findsOneWidget);

    await tester.tap(find.text('反选'));
    await tester.pump();
    // 反选后仅剩"库内已有"行被勾上（新书全部取消）。
    expect(find.textContaining('已选 1 / 3 本'), findsOneWidget);
    expect(find.text('未选择任何文件'), findsNothing);
    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(find.textContaining('已选 3 / 3 本'), findsOneWidget);
    await tester.tap(find.text('反选'));
    await tester.pump();
    expect(find.text('未选择任何文件'), findsOneWidget);
    // 0 勾选时导入按钮禁用。
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('batch-import-start')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('导入中：常驻进度（x/y + 当前文件名）+ 交互冻结', (tester) async {
    final controller = _FakeController(readyState);
    await pumpFake(tester, controller: controller);

    await tester.tap(find.byKey(const ValueKey('batch-import-start')));
    await tester.pump();

    expect(controller.importCalls, 1);
    expect(controller.lastUploadToCloud, isTrue, reason: '开关默认开，透传给控制器');
    expect(find.textContaining('正在导入（0/2）：甲.txt'), findsOneWidget);
    // 按钮转入禁用 + 导入中。
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('batch-import-start')),
          )
          .onPressed,
      isNull,
    );
    expect(find.text('导入中…'), findsOneWidget);
    // 行勾选与开关冻结。
    expect(
      tester.widget<Checkbox>(find.byType(Checkbox).at(0)).onChanged,
      isNull,
    );
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    // 顶栏动作冻结。
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '全选'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('导入中触发导入时上传开关为关 → 透传 uploadToCloud=false', (tester) async {
    final controller = _FakeController(readyState);
    await pumpFake(tester, controller: controller);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('batch-import-start')));
    await tester.pump();
    expect(controller.lastUploadToCloud, isFalse);
  });

  testWidgets('假控制器 done：汇总卡渲染成功/失败清单', (tester) async {
    final summary = ImportSummary()
      ..imported.add(_book('01A'))
      ..failures['坏.txt'] = '读取失败';
    await pumpFake(
      tester,
      controller: _FakeController(readyState, nextSummary: summary),
    );

    await tester.tap(find.byKey(const ValueKey('batch-import-start')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pumpAndSettle();

    expect(find.text('批量导入完成'), findsOneWidget);
    expect(find.textContaining('成功 1 本'), findsOneWidget);
    expect(find.textContaining('失败 1 本'), findsOneWidget);
    expect(find.textContaining('坏.txt 导入失败：读取失败'), findsOneWidget);
    // 完成返回书库。
    await tester.tap(find.byKey(const ValueKey('batch-done')));
    await tester.pumpAndSettle();
    expect(find.text('书库首页-stub'), findsOneWidget);
  });

  testWidgets('响应式冒烟：1440 / 860 / 390 无溢出', (tester) async {
    for (final size in [
      const Size(1440, 900),
      const Size(860, 900),
      const Size(390, 844),
    ]) {
      await pumpFake(tester, size: size);
      expect(tester.takeException(), isNull, reason: '宽度 ${size.width}');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });
}

Book _book(String id) => Book(
  bookId: id,
  title: '书$id',
  author: '',
  format: 'txt',
  fileName: '$id.txt',
  contentHash: 'sha256:$id',
  sizeBytes: 1,
  tocFingerprint: 'tfp:0000000000000000',
  addedAt: 1,
  totalSeconds: 0,
);

/// 假扫描文件条目（假控制器清单用，无真实文件）。
ScannedFile fakeFile(
  String relativePath, {
  String ext = 'txt',
  int size = 1024,
}) => ScannedFile(
  path: 'X:/dir/$relativePath',
  relativePath: relativePath,
  ext: ext,
  sizeBytes: size,
);

/// 标准三行清单：新书 ×2（默认勾选）+ 库内重复 ×1（默认不勾）。
BatchImportState get readyState => BatchImportState(
  phase: BatchImportPhase.ready,
  directoryPath: 'X:/dir',
  analyzedCount: 3,
  candidates: [
    ImportCandidate(file: fakeFile('三体.txt'), contentHash: 'sha256:a'),
    ImportCandidate(
      file: fakeFile('旧书.epub', ext: 'epub'),
      contentHash: 'sha256:b',
      duplicateOf: '库内书名',
      selected: false,
    ),
    ImportCandidate(
      file: fakeFile('散文.md', ext: 'md'),
      contentHash: 'sha256:c',
    ),
  ],
);

/// 假目录选择器：返回固定路径。
class _FakePicker implements DirectoryPicker {
  _FakePicker(this.path);

  final String path;
  int calls = 0;

  @override
  Future<String?> pickDirectory() async {
    calls++;
    return path;
  }
}

/// 假控制器：固定初始状态，startScan 不做真实扫描；importSelected 记录
/// uploadToCloud 透传值，并可配置推进到 done + 汇总以驱动汇总卡分支。
class _FakeController extends BatchImportController {
  _FakeController(this._initial, {this.nextSummary});

  final BatchImportState _initial;

  /// 非空时 importSelected 会异步推进到 done 并携带该汇总。
  final ImportSummary? nextSummary;

  int importCalls = 0;
  bool? lastUploadToCloud;

  @override
  BatchImportState build() => _initial;

  @override
  Future<void> startScan(String directoryPath) async {}

  @override
  Future<ImportSummary?> importSelected({bool uploadToCloud = true}) async {
    importCalls++;
    lastUploadToCloud = uploadToCloud;
    state = state.copyWith(
      phase: BatchImportPhase.importing,
      progress: const ImportProgress(
        completed: 0,
        total: 2,
        currentName: '甲.txt',
      ),
      clearError: true,
    );
    final summary = nextSummary;
    if (summary == null) return null;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    state = state.copyWith(
      phase: BatchImportPhase.done,
      summary: summary,
      clearProgress: true,
    );
    return summary;
  }
}

/// 最小路由：批量导入页 + 书库首页 stub（「完成」返回的落点断言用）。
GoRouter _buildRouter() => GoRouter(
  initialLocation: '/tools/batch-import',
  routes: [
    GoRoute(
      path: '/tools/batch-import',
      builder: (_, _) => const BatchImportPage(),
    ),
    GoRoute(
      path: '/',
      builder: (_, _) =>
          const Scaffold(key: Key('home-stub'), body: Text('书库首页-stub')),
    ),
  ],
);
