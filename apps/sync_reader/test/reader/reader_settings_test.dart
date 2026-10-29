/// ReaderSettings 契约测试：音量键翻页字段（FR-209）序列化、v1.1 出厂
/// 默认值（docs/10 A14/Q9：字号 19 / 行高 1.95 / 默认分页）、主题 4 套
/// 与旧值迁移映射（A11）、字体栈解析（Q2/Q4）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/core/design_tokens.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';

void main() {
  group('volumeKeyPageTurn（FR-209）', () {
    test('volumeKeyPageTurn 默认 false（出厂默认不开音量键翻页）', () {
      expect(ReaderSettings.defaults.volumeKeyPageTurn, isFalse);
    });

    test('toJson/fromJson roundtrip 保留 volumeKeyPageTurn', () {
      const settings = ReaderSettings(volumeKeyPageTurn: true);
      final restored = ReaderSettings.fromJson(settings.toJson());
      expect(restored, settings);
      expect(restored.volumeKeyPageTurn, isTrue);
    });

    test('旧 JSON（无 volumeKeyPageTurn 键）回落默认 false（向后兼容）', () {
      final legacy = ReaderSettings.fromJson({
        'fontSize': 20,
        'pageMode': 'page',
      });
      expect(legacy.fontSize, 20);
      expect(legacy.pageMode, ReaderPageMode.page);
      expect(legacy.volumeKeyPageTurn, isFalse);
    });

    test('copyWith 覆盖该字段，并参与 ==/hashCode', () {
      final on = ReaderSettings.defaults.copyWith(volumeKeyPageTurn: true);
      expect(on.volumeKeyPageTurn, isTrue);
      expect(on, isNot(ReaderSettings.defaults));
      expect(on.hashCode, isNot(ReaderSettings.defaults.hashCode));
      expect(on, ReaderSettings.defaults.copyWith(volumeKeyPageTurn: true));
    });
  });

  group('v1.1 出厂默认值（docs/10 A14/Q9/§4.4）', () {
    test('字号 19 / 行高 1.95（正文排版基线）', () {
      expect(ReaderSettings.defaults.fontSize, 19.0);
      expect(ReaderSettings.defaults.lineHeight, 1.95);
      expect(ReaderSettings.defaults.pageMargin, 16.0);
    });

    test('翻页模式默认「分页」（Q9，与 v1.0 默认滚动相反）', () {
      expect(ReaderSettings.defaults.pageMode, ReaderPageMode.page);
    });

    test('主题默认纸白（Q5 四套之首选）', () {
      expect(ReaderSettings.defaults.theme, ReaderTheme.paper);
    });
  });

  group('阅读主题 4 套（Q5/A11）', () {
    test('枚举含纸白/米黄/护眼/夜间，与设计令牌一一对应', () {
      expect(ReaderTheme.values.map((t) => t.name).toList(), [
        'paper',
        'beige',
        'green',
        'dark',
      ]);
      expect(ReaderTheme.values.map((t) => t.label).toList(), [
        '纸白',
        '米黄',
        '护眼',
        '夜间',
      ]);
      for (final theme in ReaderTheme.values) {
        expect(theme.palette, AppReaderTheme.values.byName(theme.name).palette);
      }
    });

    test('色值对照 design_tokens 权威 ReaderPalette', () {
      expect(ReaderTheme.paper.palette.bg, const Color(0xFFFFFFFF));
      expect(ReaderTheme.paper.palette.fg, const Color(0xFF26251F));
      expect(ReaderTheme.beige.palette.bg, const Color(0xFFF6EFE0));
      expect(ReaderTheme.beige.palette.fg, const Color(0xFF40382B));
      expect(ReaderTheme.green.palette.bg, const Color(0xFFE5EEE2));
      expect(ReaderTheme.green.palette.fg, const Color(0xFF2B3529));
      expect(ReaderTheme.dark.palette.bg, const Color(0xFF14151A));
      expect(ReaderTheme.dark.palette.fg, const Color(0xFFC8CACD));
    });
  });

  group('旧值迁移映射（A11）', () {
    test('v1.0 主题名：light→paper、paper→beige、dark→dark', () {
      expect(
        ReaderSettings.fromJson({'v': 1, 'theme': 'light'}).theme,
        ReaderTheme.paper,
        reason: 'v1.0 浅色 → 纸白',
      );
      expect(
        ReaderSettings.fromJson({'v': 1, 'theme': 'paper'}).theme,
        ReaderTheme.beige,
        reason: 'v1.0 纸张（米黄系 #F5EFDC）→ 米黄',
      );
      expect(
        ReaderSettings.fromJson({'v': 1, 'theme': 'dark'}).theme,
        ReaderTheme.dark,
        reason: '夜间语义不变（色值换新）',
      );
    });

    test('未知主题名回落默认纸白（只增不删）', () {
      expect(
        ReaderSettings.fromJson({'theme': '未来新主题'}).theme,
        ReaderTheme.paper,
      );
      expect(ReaderSettings.fromJson({}).theme, ReaderTheme.paper);
    });

    test('新形态（v:2）按新语义直读：paper=纸白、beige=米黄', () {
      expect(
        ReaderSettings.fromJson({'v': 2, 'theme': 'paper'}).theme,
        ReaderTheme.paper,
      );
      expect(
        ReaderSettings.fromJson({'v': 2, 'theme': 'beige'}).theme,
        ReaderTheme.beige,
      );
      expect(
        ReaderSettings.fromJson({'v': 2, 'theme': 'green'}).theme,
        ReaderTheme.green,
      );
    });
  });

  group('字体栈解析（Q2/Q4）', () {
    test('null/空 = 衬线宋体默认（Q2）', () {
      expect(resolveReaderFont(null).family, AppFonts.serif);
      expect(resolveReaderFont(null).fallback, contains('Source Han Serif SC'));
      expect(ReaderSettings.defaults.resolvedFontFamily, AppFonts.serif);
    });

    test('黑体/楷体映射 AppFonts.sans / AppFonts.kai', () {
      expect(resolveReaderFont(AppFonts.sans).family, AppFonts.sans);
      expect(resolveReaderFont(AppFonts.sans).fallback, isNotEmpty);
      expect(resolveReaderFont(AppFonts.kai).family, AppFonts.kai);
      expect(resolveReaderFont(AppFonts.kai).fallback, contains('STKaiti'));
    });

    test('v1.0 面板遗留键 serif/sans/monospace 容错归位', () {
      expect(resolveReaderFont('serif').family, AppFonts.serif);
      expect(resolveReaderFont('sans').family, AppFonts.sans);
      expect(resolveReaderFont('monospace').family, AppFonts.mono);
    });

    test('自定义字体名按名称直用、回退衬线栈', () {
      final stack = resolveReaderFont('宋体');
      expect(stack.family, '宋体');
      expect(stack.fallback, contains('SimSun'));
    });

    test('json roundtrip 保留字体设置', () {
      const settings = ReaderSettings(fontFamily: AppFonts.kai);
      final restored = ReaderSettings.fromJson(settings.toJson());
      expect(restored, settings);
      expect(restored.resolvedFontFamily, AppFonts.kai);
    });
  });
}
