/// TxtRenderer 无头（无视图）行为测试：restore 三分支（docs/05 §3.3）、
/// percent↔locator 往返、jumpTo、节流上报、applySettings（编码覆盖/排版/主题）。
/// 真实文件样本在系统临时目录构造（GBK 由 bytes 编码生成，不依赖仓库外文件）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/contract/book_file.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/contract/toc_entry.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_chapter.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_chapter_anchor.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_chapter_splitter.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_locator.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_renderer.dart';

/// 三章样本（每章约 300 字符，恢复/重排都有余量）。
final String bookText =
    '第一章 开端\n${'甲' * 300}\n'
    '第二章 发展\n${'乙' * 300}\n'
    '第三章 结局\n${'丙' * 300}\n';

/// 与渲染器同一套切分结果（期望值基准）。
final List<TxtChapter> chapters = TxtChapterSplitter.split(bookText);

/// percent → 章序号期望值（与渲染器同表同算法）。
int expectedChapterAtPercent(double percent) =>
    TxtPercentMath.chapterIndexAtPercent(chapters, percent);

Future<BookFile> _writeBook(
  String content, {
  bool asGbk = false,
  String fileName = '测试书 - 张三.txt',
}) async {
  final dir = await Directory.systemTemp.createTemp('sync_reader_txt_test');
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不阻塞测试
    }
  });
  final file = File('${dir.path}${Platform.pathSeparator}$fileName');
  await file.writeAsBytes(
    asGbk ? Uint8List.fromList(gbk.encode(content)) : utf8.encode(content),
  );
  return BookFile.fromPath(file.path);
}

Future<TxtRenderer> _open([ReaderSettings? settings]) async {
  final bf = await _writeBook(bookText);
  final r = await TxtRenderer.open(
    file: bf,
    settings: settings ?? ReaderSettings.defaults,
  );
  return r;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('restore 三分支（docs/05 §3.3）', () {
    test('分支 1：无进度 → noProgress 开卷第一章首', () async {
      final r = await _open();
      final result = await r.controller.restore(ProgressAnchor.empty);
      expect(result.mode, ReaderRestoreMode.noProgress);
      expect(result.applied, ProgressAnchor.empty);
      expect(r.positionChapter, 0);
      expect(r.positionOffset, 0);
      expect(r.percent, 0);
      expect(r.controller.currentLocator.locatorJson, TxtLocator.encode(0, 0));
      expect(r.controller.percent, 0);
      r.dispose();
    });

    test('分支 3：合法 locator → exact，位置与 applied 精确', () async {
      final r = await _open();
      final result = await r.controller.restore(
        ProgressAnchor(
          locatorJson: TxtLocator.encode(1, 5),
          percent: 0.5,
          hasProgress: true,
        ),
      );
      expect(result.mode, ReaderRestoreMode.exact);
      expect(r.positionChapter, 1);
      expect(r.positionOffset, 5);
      expect(result.applied.locatorJson, TxtLocator.encode(1, 5));
      expect(result.applied.percent, r.percent);
      // percent ↔ locator 往返一致
      final decoded = TxtLocator.decode(
        r.controller.currentLocator.decodeLocator(),
      );
      expect(decoded, const TxtChapterAnchor(chapterIndex: 1, charOffset: 5));
      r.dispose();
    });

    test('分支 3：章内偏移超长 → 钳制到章长仍为 exact', () async {
      final r = await _open();
      final result = await r.controller.restore(
        ProgressAnchor(
          locatorJson: TxtLocator.encode(0, 999999),
          percent: 0.9,
          hasProgress: true,
        ),
      );
      expect(result.mode, ReaderRestoreMode.exact);
      expect(r.positionChapter, 0);
      expect(r.positionOffset, chapters[0].length);
      r.dispose();
    });

    test('分支 2：locator type 不支持 → degradedToPercent 落最近章首', () async {
      final r = await _open();
      final result = await r.controller.restore(
        const ProgressAnchor(
          locatorJson: '{"type":"epub","spineIndex":3}',
          percent: 0.9,
          hasProgress: true,
        ),
      );
      expect(result.mode, ReaderRestoreMode.degradedToPercent);
      expect(r.positionChapter, expectedChapterAtPercent(0.9));
      expect(r.positionOffset, 0, reason: '定位到章首');
      expect(result.applied.locatorJson, '{}', reason: '降级时 locator 为空对象');
      expect(result.applied.percent, 0.9, reason: '降级时 percent 保持不变');
      r.dispose();
    });

    test('分支 2：章越界 → degradedToPercent', () async {
      final r = await _open();
      final result = await r.controller.restore(
        ProgressAnchor(
          locatorJson: TxtLocator.encode(999, 0),
          percent: 0.25,
          hasProgress: true,
        ),
      );
      expect(result.mode, ReaderRestoreMode.degradedToPercent);
      expect(r.positionChapter, expectedChapterAtPercent(0.25));
      expect(result.applied.percent, 0.25);
      r.dispose();
    });

    test('分支 2：损坏 JSON → degradedToPercent', () async {
      final r = await _open();
      final result = await r.controller.restore(
        const ProgressAnchor(
          locatorJson: '{oops broken',
          percent: 0.4,
          hasProgress: true,
        ),
      );
      expect(result.mode, ReaderRestoreMode.degradedToPercent);
      expect(r.positionChapter, expectedChapterAtPercent(0.4));
      r.dispose();
    });
  });

  group('jumpTo / 节流上报', () {
    test('jumpTo：TxtChapterAnchor 跳章首；异构锚点忽略', () async {
      final r = await _open();
      await r.controller.jumpTo(
        TocEntry(
          title: '第三章 结局',
          level: 0,
          anchor: const TxtChapterAnchor(chapterIndex: 2, charOffset: 12345),
        ),
      );
      expect(r.positionChapter, 2);
      expect(r.positionOffset, 0, reason: '跳章首');
      expect(
        TxtLocator.decode(r.controller.currentLocator.decodeLocator()),
        const TxtChapterAnchor(chapterIndex: 2, charOffset: 0),
      );
      // 异构锚点（其他格式误入）→ 位置不变
      await r.controller.jumpTo(
        TocEntry(title: 'x', level: 0, anchor: 'not-an-anchor'),
      );
      expect(r.positionChapter, 2);
      r.dispose();
    });

    test('onProgressChanged：首报即时、窗口内合并为尾随一次', () async {
      final r = await _open();
      final received = <ProgressAnchor>[];
      final percents = <double>[];
      r.controller.onProgressChanged = (locator, percent) {
        received.add(locator);
        percents.add(percent);
      };
      r.reportPosition(0, 10); // 距上次上报远 → 立即
      expect(received, hasLength(1));
      r.reportPosition(0, 20); // 窗口内 → 合并
      r.reportPosition(0, 30); // 窗口内 → 继续合并
      expect(received, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(received, hasLength(2), reason: '尾随上报一次');
      expect(received.last.locatorJson, TxtLocator.encode(0, 30));
      for (final p in percents) {
        expect(p, inInclusiveRange(0, 1));
      }
      r.dispose();
    });
  });

  group('applySettings', () {
    test('编码覆盖变更：整书重解码，位置按新章表钳制保留', () async {
      final bf = await _writeBook(bookText, asGbk: true);
      final r = await TxtRenderer.open(
        file: bf,
        settings: ReaderSettings.defaults,
      );
      expect(r.encodingName, 'gbk', reason: 'auto 探测 GBK');
      expect(r.chapterCount, 3);
      await r.controller.restore(
        ProgressAnchor(
          locatorJson: TxtLocator.encode(1, 50),
          percent: 0.5,
          hasProgress: true,
        ),
      );
      // 强制 UTF-8：GBK 字节解为乱码，章回标题模式消失 → 单章。
      await r.applySettings(
        r.settings.copyWith(txtEncodingOverride: ReaderTextEncoding.utf8),
      );
      expect(r.encodingName, 'utf-8');
      expect(r.chapterCount, 1, reason: '乱码文本无章回命中');
      expect(r.positionChapter, 0, reason: '章序号钳制到新章表');
      // 切回 GBK：章节结构恢复。
      await r.applySettings(
        r.settings.copyWith(txtEncodingOverride: ReaderTextEncoding.gbk),
      );
      expect(r.encodingName, 'gbk');
      expect(r.chapterCount, 3);
      r.dispose();
    });

    test('排版变更：重排后按当前章首字符偏移重新定位（落章首）', () async {
      final r = await _open();
      await r.controller.restore(
        ProgressAnchor(
          locatorJson: TxtLocator.encode(2, 100),
          percent: 0.8,
          hasProgress: true,
        ),
      );
      await r.applySettings(r.settings.copyWith(fontSize: 28));
      expect(r.positionChapter, 2, reason: '章不变');
      expect(r.positionOffset, 0, reason: '规格约定：落当前章首');
      r.dispose();
    });

    test('主题/翻页模式变更：位置不变', () async {
      final r = await _open();
      await r.controller.restore(
        ProgressAnchor(
          locatorJson: TxtLocator.encode(1, 100),
          percent: 0.5,
          hasProgress: true,
        ),
      );
      await r.applySettings(
        r.settings.copyWith(
          theme: ReaderTheme.paper,
          pageMode: ReaderPageMode.page,
        ),
      );
      expect(r.positionChapter, 1);
      expect(r.positionOffset, 100);
      expect(r.themeColors.background, const Color(0xFFF5EFDC));
      r.dispose();
    });

    test('相同设置重复应用为 no-op', () async {
      final r = await _open();
      await r.applySettings(ReaderSettings.defaults);
      expect(r.positionChapter, 0);
      r.dispose();
    });
  });

  test('dispose 后再报告/恢复不崩溃', () async {
    final r = await _open();
    r.dispose();
    expect(() => r.reportPosition(0, 5), returnsNormally);
    expect(r.controller.currentLocator, isA<ProgressAnchor>());
  });
}
