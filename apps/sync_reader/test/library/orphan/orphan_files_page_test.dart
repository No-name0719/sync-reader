/// 游离文件管理页 widget 测试（FR-408）：空态、列表渲染、懒解析标题
/// （旁路不阻塞）、挂回/删除操作流、二次确认拦截与并发防重入，
/// 以及书库溢出菜单入口。
///
/// 注意：testWidgets 的 fakeAsync 中真实 IO 不可靠——扫描/删除经
/// `_FakeOrphanService` 注入纯内存假实现，标题解析经假 handler（微任务
/// 完成）；drift 流（内存库）由 pump 驱动，收尾排空定时器后真实区关库。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/features/library/import/book_import_service.dart';
import 'package:sync_reader/features/library/library_page.dart';
import 'package:sync_reader/features/library/library_providers.dart'
    show bookImportServiceProvider;
import 'package:sync_reader/features/library/orphan/orphan_book_file.dart';
import 'package:sync_reader/features/library/orphan/orphan_file_service.dart';
import 'package:sync_reader/features/library/orphan/orphan_files_page.dart';
import 'package:sync_reader/features/sync/sync_facade.dart'
    show secureCredentialStoreProvider;
import 'package:sync_reader/features/reader/contract/book_file.dart';
import 'package:sync_reader/features/reader/contract/book_format_handler.dart';
import 'package:sync_reader/features/reader/contract/book_renderer.dart';
import 'package:sync_reader/features/reader/contract/format_registry.dart';
import 'package:sync_reader/features/reader/contract/parsed_book.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';

import '../fake_handler.dart';

void main() {
  AppDatabase? db;
  Directory? tmp;

  /// 建库 + 临时目录（真实 IO 经 runAsync）。
  Future<void> bootstrap(WidgetTester tester) async {
    await tester.runAsync(() async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      await database.customSelect('SELECT 1').getSingle();
      db = database;
      tmp = await Directory.systemTemp.createTemp('orphan_page_test');
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

  /// 测试体收尾：卸载 widget 树 → 排空 drift 定时器 → 真实区关库。
  Future<void> shutdown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 60));
    await tester.runAsync(() async {
      await db?.close();
      db = null;
    });
  }

  /// 构造一条游离条目（纯数据，不落盘——扫描经假服务注入）。
  OrphanBookFile entry(String fileName, {int size = 12}) {
    final dot = fileName.lastIndexOf('.');
    return OrphanBookFile(
      path: '/fake/books/$fileName',
      fileName: fileName,
      stem: fileName.substring(0, dot),
      ext: fileName.substring(dot + 1),
      sizeBytes: size,
      formatId: fileName.substring(dot + 1),
    );
  }

  /// 渲染游离文件页（全部依赖注入假实现，无真实 IO）。
  Future<void> pumpPanel(
    WidgetTester tester, {
    required _FakeOrphanService service,
    BookImportService? importService,
    FormatRegistry? registry,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db!),
          bookFileStoreProvider.overrideWith(
            (ref) async => BookFileStore(tmp!),
          ),
          formatRegistryProvider.overrideWithValue(
            registry ??
                (FormatRegistry()..register(FakeHandler(coverBytes: tinyPng))),
          ),
          orphanFileServiceProvider.overrideWithValue(service),
          if (importService != null)
            bookImportServiceProvider.overrideWithValue(importService),
        ],
        child: const MaterialApp(home: OrphanFilesPage()),
      ),
    );
    // 控制器首扫在微任务中触发；定长泵推进（空扫描无持续动画帧）。
    await tester.pump();
    await tester.pumpAndSettle();
  }

  testWidgets('空态：标题 + 游离文件来源说明', (tester) async {
    await bootstrapSafely(tester);
    await pumpPanel(tester, service: _FakeOrphanService());

    expect(find.text('游离文件管理'), findsOneWidget); // AppBar 标题
    expect(find.text('没有游离文件'), findsOneWidget);
    expect(find.textContaining('其他设备删除的书会在这里保留本地正文'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('列表渲染：格式/大小/文件名齐全，懒解析标题替换主干', (tester) async {
    await bootstrapSafely(tester);
    await pumpPanel(
      tester,
      service: _FakeOrphanService(
        scanResult: [entry('01ARZ3NDEKTSV4RRFFQ69G5FAV.txt', size: 2048)],
      ),
    );

    // 假 handler 微任务级返回 → pumpAndSettle 后标题为解析书名（主干消失）。
    expect(find.text('解析书名'), findsOneWidget);
    expect(find.text('01ARZ3NDEKTSV4RRFFQ69G5FAV'), findsNothing);
    // 行元信息与操作入口。
    expect(find.textContaining('TXT · 2.00 KB'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '挂回'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('懒解析是旁路：解析中列表照常渲染（门控 handler）', (tester) async {
    await bootstrapSafely(tester);
    final gate = _GatedHandler();
    await pumpPanel(
      tester,
      registry: FormatRegistry()..register(gate),
      service: _FakeOrphanService(scanResult: [entry('甲.txt')]),
    );

    // 解析被门控挂起：列表已渲染主干标题（不阻塞）。
    expect(find.text('甲'), findsOneWidget);
    expect(find.text('解析书名'), findsNothing);
    gate.gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('解析书名'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('懒解析失败：保持文件名主干（不阻塞面板）', (tester) async {
    await bootstrapSafely(tester);
    await pumpPanel(
      tester,
      registry: FormatRegistry()..register(const _ThrowingHandler()),
      service: _FakeOrphanService(scanResult: [entry('甲.txt')]),
    );

    await tester.pumpAndSettle();
    expect(find.text('甲'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('挂回成功：出"进度将在同步时尽力恢复"提示', (tester) async {
    await bootstrapSafely(tester);
    final import = _StubImportService(db!, tmp!)..nextAdopt = const _Adopted();
    final service = _FakeOrphanService(scanResult: [entry('甲.txt')]);
    await pumpPanel(tester, service: service, importService: import);

    await tester.tap(find.widgetWithText(TextButton, '挂回'));
    await tester.pumpAndSettle();
    expect(import.adoptCalls, ['/fake/books/甲.txt']);
    expect(find.textContaining('挂回成功，进度将在同步时尽力恢复'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('挂回去重：库内已有同 hash 书 → 提示冗余并可引导删除', (tester) async {
    await bootstrapSafely(tester);
    final import = _StubImportService(db!)..nextAdopt = const _Duplicate('三体');
    await pumpPanel(
      tester,
      service: _FakeOrphanService(scanResult: [entry('甲.txt')]),
      importService: import,
    );

    await tester.tap(find.widgetWithText(TextButton, '挂回'));
    await tester.pumpAndSettle();
    expect(find.textContaining('书库已有同内容书籍《三体》'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('彻底删除：二次确认拦截——取消不删，确认才删', (tester) async {
    await bootstrapSafely(tester);
    final service = _FakeOrphanService(scanResult: [entry('甲.txt')]);
    await pumpPanel(tester, service: service);

    // 未确认（取消）：删除未执行。
    await tester.tap(find.byTooltip('彻底删除'));
    await tester.pumpAndSettle();
    expect(find.text('彻底删除'), findsOneWidget); // 对话框标题
    expect(find.textContaining('永久删除，不可恢复'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.deleteCalls, isEmpty);

    // 确认：执行删除并出提示。
    await tester.tap(find.byTooltip('彻底删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();
    expect(service.deleteCalls, hasLength(1));
    expect(service.deleteCalls.single.fileName, '甲.txt');
    expect(find.textContaining('已删除《甲》的本地文件'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('并发防重入：挂回进行中冻结全部行内操作，结束后恢复', (tester) async {
    await bootstrapSafely(tester);
    final import = _GatedImportService(db!, tmp!);
    await pumpPanel(
      tester,
      service: _FakeOrphanService(scanResult: [entry('甲.txt')]),
      importService: import,
    );

    await tester.tap(find.widgetWithText(TextButton, '挂回'));
    await tester.pump();
    // 挂回被门控挂起（busy）：挂回与删除按钮全部禁用。
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '挂回'))
          .onPressed,
      isNull,
    );
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
    import.gate.complete(const _Adopted());
    await tester.pumpAndSettle();
    // 操作结束后按钮恢复可用。
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '挂回'))
          .onPressed,
      isNotNull,
    );
    await shutdown(tester);
  });

  testWidgets('书库溢出菜单提供"游离文件管理"入口并可进入面板', (tester) async {
    await bootstrapSafely(tester);
    final service = _FakeOrphanService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db!),
          bookFileStoreProvider.overrideWith(
            (ref) async => BookFileStore(tmp!),
          ),
          // 同步横幅（FR-406）会触碰平台通道：注入内存凭据存储。
          secureCredentialStoreProvider.overrideWithValue(
            InMemoryCredentialStore(),
          ),
          orphanFileServiceProvider.overrideWithValue(service),
        ],
        child: const MaterialApp(home: LibraryPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('游离文件管理'), findsOneWidget);
    await tester.tap(find.text('游离文件管理'));
    await tester.pumpAndSettle();
    // 已进入面板（AppBar 标题 + 空态）。
    expect(find.text('没有游离文件'), findsOneWidget);
    await shutdown(tester);
  });
}

/// 假挂回结果：已挂回（book 行内容本组测试不消费）。
class _Adopted implements OrphanAdoptResult {
  const _Adopted();

  @override
  Book? get book => throw UnimplementedError();

  @override
  String? get duplicateOf => null;

  @override
  bool get adopted => true;

  @override
  bool get isDuplicate => false;
}

/// 假挂回结果：库内已有同 hash 书。
class _Duplicate implements OrphanAdoptResult {
  const _Duplicate(this.duplicateOf);

  @override
  Book? get book => null;

  @override
  final String? duplicateOf;

  @override
  bool get adopted => false;

  @override
  bool get isDuplicate => true;
}

/// 假游离文件服务：纯内存，无真实 IO（fakeAsync 安全）。
class _FakeOrphanService implements OrphanFileService {
  _FakeOrphanService({List<OrphanBookFile> scanResult = const []})
    : scanResult = List.of(scanResult);

  List<OrphanBookFile> scanResult;
  final deleteCalls = <OrphanBookFile>[];

  @override
  Future<List<OrphanBookFile>> scan() async => scanResult;

  @override
  Future<void> deleteOrphan(OrphanBookFile orphan) async {
    deleteCalls.add(orphan);
  }

  @override
  Future<void> cleanupContainer(OrphanBookFile orphan) async {}
}

/// 假导入服务：挂回结果可编程（记录调用，不动真实文件）。
class _StubImportService extends BookImportService {
  _StubImportService(AppDatabase db, [Directory? tmpDir])
    : super(
        booksDao: db.booksDao,
        registry: FormatRegistry()..register(FakeHandler()),
        fileStore: Future.value(BookFileStore(tmpDir ?? Directory.systemTemp)),
      );

  OrphanAdoptResult? nextAdopt;
  final adoptCalls = <String>[];

  @override
  Future<OrphanAdoptResult> adoptExistingFile({
    required String filePath,
  }) async {
    adoptCalls.add(filePath);
    return nextAdopt!;
  }
}

/// 门控导入服务：挂回挂起直至 [gate] 完成（busy 防重入窗口模拟）。
class _GatedImportService extends BookImportService {
  _GatedImportService(AppDatabase db, Directory tmpDir)
    : super(
        booksDao: db.booksDao,
        registry: FormatRegistry()..register(FakeHandler()),
        fileStore: Future.value(BookFileStore(tmpDir)),
      );

  final gate = Completer<OrphanAdoptResult>();

  @override
  Future<OrphanAdoptResult> adoptExistingFile({required String filePath}) =>
      gate.future;
}

/// 门控假 handler：parseMetadata 挂起至 [gate] 完成（懒解析旁路验证）。
class _GatedHandler implements BookFormatHandler {
  final gate = Completer<void>();

  @override
  String get formatId => 'txt';

  @override
  bool canHandle(String ext, Uint8List magicHeader) => ext == 'txt';

  @override
  Future<ParsedBook> parseMetadata(BookFile file) async {
    await gate.future;
    return const ParsedBook(
      title: '解析书名',
      author: '',
      toc: [],
      tocFingerprint: 'tfp:0000000000000000',
    );
  }

  @override
  Future<BookRenderer> createRenderer(
    BookFile file,
    ReaderSettings settings,
    ProgressAnchor anchor,
  ) => throw UnimplementedError();
}

/// 恒抛异常的假 handler（懒解析失败降级验证）。
class _ThrowingHandler implements BookFormatHandler {
  const _ThrowingHandler();

  @override
  String get formatId => 'txt';

  @override
  bool canHandle(String ext, Uint8List magicHeader) => ext == 'txt';

  @override
  Future<ParsedBook> parseMetadata(BookFile file) async {
    throw Exception('解析失败');
  }

  @override
  Future<BookRenderer> createRenderer(
    BookFile file,
    ReaderSettings settings,
    ProgressAnchor anchor,
  ) => throw UnimplementedError();
}
