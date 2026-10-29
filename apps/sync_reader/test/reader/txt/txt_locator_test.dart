/// locator 编解码校验、percent↔locator 往返、章定位映射与主题色测试
/// （FR-202/FR-207，docs/05 §3.3）。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/contract/toc_entry.dart';
import 'package:sync_reader/features/reader/contract/toc_fingerprint.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_chapter.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_chapter_anchor.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_locator.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_theme.dart';

/// 章表夹具：三段 10/20/30 字符，总 60。
const _chapters = [
  TxtChapter(title: '一', startOffset: 0, endOffset: 10),
  TxtChapter(title: '二', startOffset: 10, endOffset: 30),
  TxtChapter(title: '三', startOffset: 30, endOffset: 60),
];

void main() {
  group('TxtLocator 编解码', () {
    test('encode → decode 往返一致', () {
      final json = TxtLocator.encode(87, 1204);
      final decoded = TxtLocator.decode(
        jsonDecode(json) as Map<String, Object?>,
      );
      expect(
        decoded,
        const TxtChapterAnchor(chapterIndex: 87, charOffset: 1204),
      );
      expect(json, '{"type":"txt","chapterIndex":87,"charOffset":1204}');
    });

    test('decode 校验表：非法输入一律 null（走 percent 降级）', () {
      Map<String, Object?> m(String type, Object? ci, Object? co) => {
        'type': type,
        'chapterIndex': ci,
        'charOffset': co,
      };
      expect(TxtLocator.decode(null), isNull);
      expect(TxtLocator.decode(m('epub', 1, 2)), isNull, reason: 'type 不符');
      expect(TxtLocator.decode(m('txt', 1, null)), isNull, reason: '字段缺失');
      expect(TxtLocator.decode(m('txt', '1', 2)), isNull, reason: '非整数');
      expect(TxtLocator.decode(m('txt', 1.5, 2)), isNull, reason: '浮点非整数');
      expect(TxtLocator.decode(m('txt', -1, 2)), isNull, reason: '负值');
      expect(TxtLocator.decode(m('txt', 1, -2)), isNull, reason: '负偏移');
      expect(TxtLocator.decode(<String, Object?>{}), isNull, reason: '空对象');
    });
  });

  group('TxtPercentMath', () {
    test('percentOf 基线与钳制', () {
      expect(TxtPercentMath.percentOf(_chapters, 0, 0), 0);
      expect(
        TxtPercentMath.percentOf(_chapters, 0, 10),
        closeTo(10 / 60, 1e-9),
      );
      expect(TxtPercentMath.percentOf(_chapters, 1, 0), closeTo(10 / 60, 1e-9));
      expect(
        TxtPercentMath.percentOf(_chapters, 2, 30),
        1.0,
        reason: '末章末尾 = 100%',
      );
      expect(
        TxtPercentMath.percentOf(_chapters, 1, 999),
        closeTo(30 / 60, 1e-9),
        reason: '章内偏移钳制到章长',
      );
      expect(
        TxtPercentMath.percentOf(_chapters, 99, 0),
        closeTo(0.5, 1e-9),
        reason: '章越界钳到末章',
      );
      expect(TxtPercentMath.percentOf(const [], 0, 0), 0);
    });

    test('chapterIndexAtPercent：percent → 所在章首', () {
      expect(TxtPercentMath.chapterIndexAtPercent(_chapters, 0), 0);
      expect(
        TxtPercentMath.chapterIndexAtPercent(_chapters, 0.1),
        0,
        reason: '10% → 字符 6 → 第 0 章（0..10）',
      );
      expect(
        TxtPercentMath.chapterIndexAtPercent(_chapters, 0.2),
        1,
        reason: '20% → 字符 12 → 第 1 章（10..30）',
      );
      expect(
        TxtPercentMath.chapterIndexAtPercent(_chapters, 0.5),
        2,
        reason: '50% → 字符 30 → 第 2 章（30..60）',
      );
      expect(TxtPercentMath.chapterIndexAtPercent(_chapters, 0.99), 2);
      expect(TxtPercentMath.chapterIndexAtPercent(_chapters, 1.0), 2);
      expect(
        TxtPercentMath.chapterIndexAtPercent(_chapters, -1),
        0,
        reason: '越界钳制',
      );
    });

    test('percent ↔ locator 往返一致（单调、可逆到章粒度）', () {
      // 对每章采样若干位置：encode → percent → locate 回同一章。
      for (var ci = 0; ci < _chapters.length; ci++) {
        for (final off in [0, 3, _chapters[ci].length - 1]) {
          final json = TxtLocator.encode(ci, off);
          final anchor = TxtLocator.decode(
            jsonDecode(json) as Map<String, Object?>,
          )!;
          final p = TxtPercentMath.percentOf(
            _chapters,
            anchor.chapterIndex,
            anchor.charOffset,
          );
          final mapped = TxtPercentMath.chapterIndexAtPercent(_chapters, p);
          expect(mapped, ci, reason: '章 $ci 偏移 $off → percent $p 应回到同章');
        }
      }
    });
  });

  group('主题色映射与指纹工具', () {
    test('ReaderTheme → 配色（v1.1 四套，权威色值对齐 design_tokens）', () {
      // A11：纸白/米黄/护眼/夜间，色值权威源 = ReaderPalette。
      expect(
        TxtThemeColors.of(ReaderTheme.paper).background,
        const Color(0xFFFFFFFF),
      );
      expect(
        TxtThemeColors.of(ReaderTheme.beige).background,
        const Color(0xFFF6EFE0),
      );
      expect(
        TxtThemeColors.of(ReaderTheme.green).background,
        const Color(0xFFE5EEE2),
      );
      expect(
        TxtThemeColors.of(ReaderTheme.dark).background,
        const Color(0xFF14151A),
      );
      for (final theme in ReaderTheme.values) {
        expect(
          TxtThemeColors.of(theme).foreground,
          isNot(TxtThemeColors.of(theme).background),
        );
      }
    });

    test('TocFingerprint 依赖锚点 toString 稳定', () {
      final toc = [
        TocEntry(
          title: '一',
          level: 0,
          anchor: const TxtChapterAnchor(chapterIndex: 0, charOffset: 0),
        ),
      ];
      final again = [
        TocEntry(
          title: '一',
          level: 0,
          anchor: const TxtChapterAnchor(chapterIndex: 0, charOffset: 0),
        ),
      ];
      expect(TocFingerprint.compute(toc), TocFingerprint.compute(again));
      final changed = [
        TocEntry(
          title: '一',
          level: 0,
          anchor: const TxtChapterAnchor(chapterIndex: 0, charOffset: 5),
        ),
      ];
      expect(
        TocFingerprint.compute(changed),
        isNot(TocFingerprint.compute(toc)),
      );
    });
  });
}
