/// 批量导入控制器单测（FR-109）：内存库 + 临时目录 + 假 handler，
/// 覆盖扫描后的去重标记（库内 / 同批）、默认勾选语义、导入执行与
/// 结果汇总、防重入保护。
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/features/library/import/batch_import_controller.dart';
import 'package:sync_reader/features/library/import/book_import_service.dart';
import 'package:sync_reader/features/library/library_providers.dart';
import 'package:sync_reader/features/reader/contract/format_registry.dart';

import 'fake_handler.dart';

void main() {
  late AppDatabase db;
  late Directory tmp;
  late Directory storeDir;
  late Directory scanDir;
  late ProviderContainer container;

  /// 在扫描目录写一个候选文件。
  Future<File> candidate(String name, List<int> bytes) async {
    final file = File(p.join(scanDir.path, name));
    await file.writeAsBytes(bytes);
    return file;
  }

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    tmp = await Directory.systemTemp.createTemp('batch_controller_test');
    storeDir = Directory(p.join(tmp.path, 'store'));
    scanDir = Directory(p.join(tmp.path, 'scan'));
    await storeDir.create();
    await scanDir.create();
    final store = BookFileStore(storeDir);
    await store.ensureLayout();
    container = ProviderContainer(
      overrides: [
        booksDaoProvider.overrideWithValue(db.booksDao),
        formatRegistryProvider.overrideWithValue(
          FormatRegistry()..register(FakeHandler()),
        ),
        bookImportServiceProvider.overrideWithValue(
          BookImportService(
            booksDao: db.booksDao,
            registry: FormatRegistry()..register(FakeHandler()),
            fileStore: Future.value(store),
          ),
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose(); // Riverpod 3：dispose 同步返回 void。
    await db.close();
    if (tmp.existsSync()) {
      await tmp.delete(recursive: true);
    }
  });

  BatchImportController notifier() =>
      container.read(batchImportControllerProvider.notifier);

  BatchImportState state() => container.read(batchImportControllerProvider);

  test('扫描 + 分析：新书默认勾选，哈希渐进填充，终态 ready', () async {
    await candidate('甲.txt', [1, 2, 3]);
    await candidate('乙.epub', [4, 5, 6]);
    await notifier().startScan(scanDir.path);

    expect(state().phase, BatchImportPhase.ready);
    expect(state().candidates, hasLength(2));
    expect(state().analyzedCount, 2);
    for (final c in state().candidates) {
      expect(c.contentHash, startsWith('sha256:'));
      expect(c.isDuplicate, isFalse);
      expect(c.selected, isTrue);
    }
  });

  test('与库内同 hash → 标"已存在"且默认不勾选', () async {
    final file = await candidate('三体.txt', [9, 9, 9]);
    // 预置：先经单本管线入库。
    final pre = await container.read(bookImportServiceProvider).importFiles([
      file.path,
    ]);
    expect(pre.imported, hasLength(1));

    await notifier().startScan(scanDir.path);
    final dup = state().candidates.single;
    expect(dup.isDuplicate, isTrue);
    expect(dup.duplicateOf, pre.imported.single.title);
    expect(dup.duplicateInBatch, isFalse, reason: '库内重复而非同批重复');
    expect(dup.selected, isFalse, reason: 'FR-109：已在书库的默认不勾选');
  });

  test('同批内容相同 → 后者标重复（指向先出现者）且默认不勾', () async {
    await candidate('甲.txt', [1, 1, 1]);
    await candidate('乙.txt', [1, 1, 1]);
    await notifier().startScan(scanDir.path);

    final candidates = state().candidates;
    expect(candidates, hasLength(2));
    // 字典序（乙 U+4E59 < 甲 U+7532）：乙 先出现保持勾选，
    // 甲 标重复指向 乙 且不勾选。
    final dup = candidates.where((c) => c.isDuplicate).toList();
    expect(dup, hasLength(1));
    expect(dup.single.file.relativePath, '甲.txt');
    expect(dup.single.duplicateOf, '乙.txt');
    expect(dup.single.duplicateInBatch, isTrue);
    expect(dup.single.selected, isFalse);
    final fresh = candidates.where((c) => !c.isDuplicate).toList();
    expect(fresh.single.file.relativePath, '乙.txt');
    expect(fresh.single.selected, isTrue);
  });

  test('导入选中：调 BookImportService 并出汇总，phase → done', () async {
    await candidate('甲.txt', [1, 2, 3]);
    await candidate('乙.txt', [4, 5, 6]);
    final n = notifier();
    await n.startScan(scanDir.path);

    final summary = await n.importSelected();
    expect(summary, isNotNull);
    expect(summary!.imported, hasLength(2));
    expect(state().phase, BatchImportPhase.done);
    expect(state().summary, same(summary));
    // 库内落行。
    expect(await db.select(db.books).get(), hasLength(2));
  });

  test('单本失败不中断：消失文件计入失败，其余成功', () async {
    final gone = await candidate('会消失.txt', [7, 8]);
    await candidate('存活.md', [10]);
    final n = notifier();
    await n.startScan(scanDir.path);
    // 扫描后删除：哈希分析兜底（不标记），导入时 BookFile.fromPath 失败。
    await File(gone.path).delete();

    final summary = await n.importSelected();
    expect(summary, isNotNull);
    expect(summary!.imported.map((b) => b.fileName), ['存活.md']);
    expect(summary.failures, hasLength(1));
    expect(state().phase, BatchImportPhase.done);
  });

  test('导入进行中防重入：第二次 importSelected 返回 null', () async {
    await candidate('甲.txt', [1, 2, 3]);
    final n = notifier();
    await n.startScan(scanDir.path);

    // async 函数首个 await 前同步执行：首次调用（未立即 await）已同步置
    // importing，此后的第二次调用必须被拒。
    final first = n.importSelected();
    final second = await n.importSelected();
    expect(second, isNull);
    expect(state().phase, BatchImportPhase.importing);
    await first;
    expect(state().phase, BatchImportPhase.done);
    expect((await db.select(db.books).get()), hasLength(1));
  });

  test('导入进行中禁止重新扫描（startScan 静默忽略）', () async {
    await candidate('甲.txt', [1, 2, 3]);
    final n = notifier();
    await n.startScan(scanDir.path);
    final first = n.importSelected();
    // 未等首次导入结束就再扫描：应被忽略，不破坏进行中的状态。
    await n.startScan(scanDir.path);
    expect(state().phase, BatchImportPhase.importing);
    await first;
    expect(state().phase, BatchImportPhase.done);
  });

  test('无勾选 / 未就绪时 importSelected 返回 null', () async {
    await candidate('甲.txt', [1, 2, 3]);
    final n = notifier();
    // idle 阶段直接导入 → null。
    expect(await n.importSelected(), isNull);

    await n.startScan(scanDir.path);
    n.toggle(0); // 取消唯一候选。
    expect(await n.importSelected(), isNull);
    expect(state().phase, BatchImportPhase.ready);
    expect(await db.select(db.books).get(), isEmpty);
  });

  test('toggle / selectAll / invertSelection 勾选语义', () async {
    await candidate('甲.txt', [1]);
    await candidate('乙.txt', [2]);
    final n = notifier();
    await n.startScan(scanDir.path);

    int indexOf(String name) =>
        state().candidates.indexWhere((c) => c.file.relativePath == name);
    n.toggle(indexOf('乙.txt'));
    expect(state().selectedCandidates.map((c) => c.file.relativePath), [
      '甲.txt',
    ]);
    n.invertSelection();
    expect(state().selectedCandidates.map((c) => c.file.relativePath), [
      '乙.txt',
    ]);
    n.selectAll();
    expect(state().selectedCandidates, hasLength(2));
    n.toggle(99); // 越界：静默忽略。
    expect(state().selectedCandidates, hasLength(2));
    expect(state().selectedBytes, 2);
  });

  test('根目录不可访问 → errorMessage，空清单', () async {
    await notifier().startScan(p.join(scanDir.path, '不存在'));
    expect(state().phase, BatchImportPhase.ready);
    expect(state().errorMessage, '目录不存在或无法访问');
    expect(state().candidates, isEmpty);
  });

  test('汇总文案：成功/重复/失败与首条失败原因', () {
    final summary = ImportSummary();
    expect(batchImportSummaryMessage(summary), '没有可导入的文件');

    final withFailures = ImportSummary()..failures['坏.txt'] = '不支持的格式';
    final message = batchImportSummaryMessage(withFailures);
    expect(message, contains('失败 1 本'));
    expect(message, contains('首条失败：坏.txt'));

    // imported 需要真实 Book 行：这里只验证 duplicates 分支文案。
    final withDups = ImportSummary()..duplicates['重复.txt'] = '已有书';
    expect(batchImportSummaryMessage(withDups), contains('跳过重复 1 本'));
  });
}
