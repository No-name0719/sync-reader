/// 目录扫描器单测（FR-109）：临时目录嵌套夹具，覆盖递归、多格式、
/// 大小写、不支持扩展名、截断上限、根缺失与无法访问条目静默计数。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sync_reader/features/library/import/book_scanner.dart';
import 'package:sync_reader/features/reader/contract/format_registry.dart';

import 'fake_handler.dart';

void main() {
  late Directory tmp;
  late FormatRegistry registry;

  /// 相对路径拼平台分隔符的期望值（p.relative 输出与平台一致）。
  String rel(String sub) => p.joinAll(sub.split('/'));

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('book_scanner_test');
    registry = FormatRegistry()..register(FakeHandler());
  });

  tearDown(() async {
    if (tmp.existsSync()) {
      await tmp.delete(recursive: true);
    }
  });

  /// 在夹具里写出标准嵌套结构：
  /// 根/{三体.txt, 笔记.md, 画册.pdf, 封面图.png(不支持)},
  /// 根/子目录/{大写.TXT, 混合.EpUb, 不支持.xyz, 无扩展名},
  /// 根/子目录/深层/{完本.epub}, 根/空目录/。
  Future<void> seedNested() async {
    await File(p.join(tmp.path, '三体.txt')).writeAsString('x');
    await File(p.join(tmp.path, '笔记.md')).writeAsString('y');
    await File(p.join(tmp.path, '画册.pdf')).writeAsString('z');
    await File(p.join(tmp.path, '封面图.png')).writeAsString('img');
    final sub = Directory(p.join(tmp.path, '子目录'));
    await sub.create();
    await File(p.join(sub.path, '大写.TXT')).writeAsString('a');
    await File(p.join(sub.path, '混合.EpUb')).writeAsString('b');
    await File(p.join(sub.path, '不支持.xyz')).writeAsString('c');
    await File(p.join(sub.path, '无扩展名')).writeAsString('d');
    final deep = Directory(p.join(sub.path, '深层'));
    await deep.create();
    await File(p.join(deep.path, '完本.epub')).writeAsString('e');
    await Directory(p.join(tmp.path, '空目录')).create();
  }

  test('递归扫描：相对路径 / 排序 / 大小就位', () async {
    await seedNested();
    final result = await BookScanner(registry: registry)
        .scan(Directory(tmp.path));
    expect(result.rootMissing, isFalse);
    expect(result.truncated, isFalse);
    expect(result.skippedCount, 0);
    // 内容齐整（含子目录与深层）。
    final names = result.files.map((f) => f.relativePath).toList();
    expect(names.toSet(), {
      rel('三体.txt'),
      rel('笔记.md'),
      rel('画册.pdf'),
      rel('子目录/大写.TXT'),
      rel('子目录/混合.EpUb'),
      rel('子目录/深层/完本.epub'),
    });
    // 结果按相对路径字典序（稳定可测）。
    expect(names, [...names]..sort());
    // 绝对路径与大小：txt 写入 1 字节。
    final first = result.files.first;
    expect(first.path, File(p.join(tmp.path, '三体.txt')).path);
    expect(first.ext, 'txt');
    expect(first.sizeBytes, 1);
  });

  test('扩展名大小写不敏感（.TXT / .EpUb 均收集）', () async {
    await seedNested();
    final result = await BookScanner(registry: registry)
        .scan(Directory(tmp.path));
    final exts = result.files.map((f) => f.ext).toSet();
    expect(exts, containsAll(['txt', 'epub', 'md', 'pdf']));
  });

  test('不支持的扩展名与无扩展名文件不进清单', () async {
    await seedNested();
    final result = await BookScanner(registry: registry)
        .scan(Directory(tmp.path));
    final names = result.files.map((f) => f.relativePath);
    expect(names, isNot(contains(rel('封面图.png'))));
    expect(names, isNot(contains(rel('不支持.xyz'))));
    expect(names, isNot(contains(rel('无扩展名'))));
  });

  test('达到上限即截断并标记（NFR-07 规模上限）', () async {
    await seedNested();
    final result = await BookScanner(
      registry: registry,
      maxFiles: 3,
    ).scan(Directory(tmp.path));
    expect(result.files, hasLength(3));
    expect(result.truncated, isTrue);
  });

  test('上限之外仅计可导入文件（不支持文件不占名额）', () async {
    // 5 个文件里只有 3 个受支持，上限 3 → 不应因不支持文件提前截断。
    for (var i = 0; i < 5; i++) {
      await File(p.join(tmp.path, 'f$i.${i < 3 ? 'txt' : 'xyz'}'))
          .writeAsString('x');
    }
    final result = await BookScanner(
      registry: registry,
      maxFiles: 3,
    ).scan(Directory(tmp.path));
    expect(result.files.map((f) => f.ext), everyElement('txt'));
    expect(result.truncated, isFalse); // 恰好 3 个受支持，未溢出。
  });

  test('空目录：空清单不截断', () async {
    final result = await BookScanner(registry: registry)
        .scan(Directory(tmp.path));
    expect(result.files, isEmpty);
    expect(result.truncated, isFalse);
    expect(result.rootMissing, isFalse);
  });

  test('根不存在：rootMissing 标记', () async {
    final result = await BookScanner(registry: registry)
        .scan(Directory(p.join(tmp.path, '不存在的目录')));
    expect(result.rootMissing, isTrue);
    expect(result.files, isEmpty);
  });

  test('无法访问的条目（悬空链接/接合点）静默计数不中断', () async {
    await File(p.join(tmp.path, '好书.txt')).writeAsString('x');
    final linkPath = p.join(tmp.path, '悬空');
    var created = false;
    if (Platform.isWindows) {
      // Windows：目录接合点（junction）无需特权，指向不存在目标即悬空。
      final process = await Process.run('cmd', [
        '/c',
        'mklink',
        '/J',
        linkPath,
        p.join(tmp.path, '不存在的目标'),
      ]);
      created = process.exitCode == 0;
    } else {
      try {
        await Link(linkPath).create(p.join(tmp.path, '不存在的目标'));
        created = true;
      } catch (_) {
        created = false;
      }
    }
    if (!created) {
      // ignore: avoid_print
      print('跳过：链接夹具创建失败');
      return;
    }
    addTearDown(() {
      // 只删链接本身，不跟随目标。
      final link = FileSystemEntity.typeSync(linkPath, followLinks: false);
      if (link == FileSystemEntityType.link) {
        Link(linkPath).deleteSync();
      }
    });

    final result = await BookScanner(registry: registry)
        .scan(Directory(tmp.path));
    // 好书仍在清单，悬空条目被静默跳过并计数。
    expect(result.files.map((f) => f.relativePath), [rel('好书.txt')]);
    expect(result.skippedCount, greaterThanOrEqualTo(1));
    expect(result.truncated, isFalse);
  });
}
