// 设计令牌测试（docs/10 §3；对照原型 `ui_prototype/styles.css` 第 1-233 行）。
//
// 断言口径：令牌值必须与原型 CSS 变量逐字一致，任何调色/取近似都要红。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/core/design_tokens.dart';

void main() {
  group('六套主题（3 accent × 浅/深）', () {
    test('都能构建成功且挂载 AppDesignTokens 扩展', () {
      for (final accent in AppAccent.values) {
        for (final theme in <ThemeData>[
          AppTheme.light(accent),
          AppTheme.dark(accent),
        ]) {
          final tokens = theme.extension<AppDesignTokens>();
          expect(tokens, isNotNull, reason: '$accent 主题未挂载扩展');
          expect(tokens!.accent, accent);
          expect(
            tokens.brightness,
            theme.brightness,
            reason: '明暗与 ThemeData.brightness 不一致',
          );
        }
      }
    });

    test('colorScheme.primary 等于该 accent 的 --brand 值', () {
      // 浅色 / 深色两套品牌色（原型 [data-accent=...]）。
      const expected = <AppAccent, (Color, Color)>{
        AppAccent.terracotta: (Color(0xFFB25430), Color(0xFFE08A62)),
        AppAccent.teal: (Color(0xFF0E7A6E), Color(0xFF35B8A3)),
        AppAccent.ink: (Color(0xFF2F5D4F), Color(0xFF6FBB9F)),
      };
      for (final accent in AppAccent.values) {
        final (light, dark) = expected[accent]!;
        expect(AppTheme.light(accent).colorScheme.primary, light);
        expect(AppTheme.dark(accent).colorScheme.primary, dark);
        expect(
          AppTheme.light(accent).extension<AppDesignTokens>()!.brand,
          light,
        );
        expect(AppTheme.dark(accent).extension<AppDesignTokens>()!.brand, dark);
      }
    });

    test('品牌色五件套与原型一致', () {
      final tokens = AppTheme.light(AppAccent.terracotta)
          .extension<AppDesignTokens>()!;
      expect(tokens.brand, const Color(0xFFB25430));
      expect(tokens.brandHover, const Color(0xFF93421F));
      expect(tokens.brandSoft, const Color(0xFFF8E8DF));
      expect(tokens.brandSoft2, const Color(0xFFF0D5C6));
      expect(tokens.brandText, const Color(0xFF8A3F22));

      final dark = AppTheme.dark(AppAccent.terracotta)
          .extension<AppDesignTokens>()!;
      expect(dark.brand, const Color(0xFFE08A62));
      expect(dark.brandHover, const Color(0xFFEE9B75));
      expect(dark.brandSoft, const Color(0xFF3A2119));
      expect(dark.brandSoft2, const Color(0xFF4D2B1F));
      expect(dark.brandText, const Color(0xFFF0B294));
    });
  });

  group('中性色与语义色', () {
    test('浅色 bg/surface/text 符合原型', () {
      final t = AppTheme.light(AppAccent.terracotta)
          .extension<AppDesignTokens>()!;
      expect(t.bg, const Color(0xFFF6F5F1));
      expect(t.surface, const Color(0xFFFFFFFF));
      expect(t.surface2, const Color(0xFFFAF9F6));
      expect(t.surface3, const Color(0xFFEFEEE9));
      expect(t.surfaceInset, const Color(0xFFF1F0EB));
      expect(t.border, const Color(0xFFE4E2DB));
      expect(t.borderStrong, const Color(0xFFD1CEC4));
      expect(t.text, const Color(0xFF1D1C1A));
      expect(t.text2, const Color(0xFF6A6862));
      expect(t.text3, const Color(0xFF98958C));
      expect(t.textInv, const Color(0xFFFFFFFF));
    });

    test('深色 bg/surface/text 符合原型', () {
      final t = AppTheme.dark(AppAccent.terracotta)
          .extension<AppDesignTokens>()!;
      expect(t.bg, const Color(0xFF121317));
      expect(t.surface, const Color(0xFF1A1C21));
      expect(t.surface2, const Color(0xFF212429));
      expect(t.surface3, const Color(0xFF2A2E35));
      expect(t.surfaceInset, const Color(0xFF16181C));
      expect(t.border, const Color(0xFF2C3038));
      expect(t.borderStrong, const Color(0xFF3A3F49));
      expect(t.text, const Color(0xFFE9E7E2));
      expect(t.text2, const Color(0xFF9EA2AB));
      expect(t.text3, const Color(0xFF6F747E));
      expect(t.textInv, const Color(0xFF121317));
    });

    test('语义色浅深两套符合原型', () {
      final light = AppTheme.light(AppAccent.terracotta)
          .extension<AppDesignTokens>()!;
      expect(light.success, const Color(0xFF1F7A4D));
      expect(light.successSoft, const Color(0xFFE0F2E8));
      expect(light.warn, const Color(0xFFA95B06));
      expect(light.warnSoft, const Color(0xFFFBEEDA));
      expect(light.danger, const Color(0xFFB42318));
      expect(light.dangerSoft, const Color(0xFFFCE9E6));
      expect(light.info, const Color(0xFF2563EB));
      expect(light.infoSoft, const Color(0xFFE4EDFD));

      final dark = AppTheme.dark(AppAccent.terracotta)
          .extension<AppDesignTokens>()!;
      expect(dark.success, const Color(0xFF4EC27F));
      expect(dark.successSoft, const Color(0xFF12301F));
      expect(dark.warn, const Color(0xFFE0A34A));
      expect(dark.warnSoft, const Color(0xFF33260F));
      expect(dark.danger, const Color(0xFFF28B82));
      expect(dark.dangerSoft, const Color(0xFF3A1A17));
      expect(dark.info, const Color(0xFF7AA7F8));
      expect(dark.infoSoft, const Color(0xFF17233F));
    });
  });

  group('字阶', () {
    test('八档字号为 30/22/18/15/14/13/12/11', () {
      final t = AppTheme.light(AppAccent.terracotta)
          .extension<AppDesignTokens>()!;
      expect(t.display.fontSize, 30);
      expect(t.h1.fontSize, 22);
      expect(t.h2.fontSize, 18);
      expect(t.h3.fontSize, 15);
      expect(t.body.fontSize, 14);
      expect(t.sm.fontSize, 13);
      expect(t.caption.fontSize, 12);
      expect(t.micro.fontSize, 11);
    });

    test('行高倍数 = 行高像素 / 字号', () {
      expect(AppTextScale.display.heightRatio, closeTo(38 / 30, 1e-9));
      expect(AppTextScale.h1.heightRatio, closeTo(30 / 22, 1e-9));
      expect(AppTextScale.h2.heightRatio, closeTo(26 / 18, 1e-9));
      expect(AppTextScale.h3.heightRatio, closeTo(22 / 15, 1e-9));
      expect(AppTextScale.body.heightRatio, closeTo(22 / 14, 1e-9));
      expect(AppTextScale.sm.heightRatio, closeTo(20 / 13, 1e-9));
      expect(AppTextScale.caption.heightRatio, closeTo(18 / 12, 1e-9));
      expect(AppTextScale.micro.heightRatio, closeTo(16 / 11, 1e-9));
    });

    test('字重映射：680/650→w700、620/600→w600、400→w400', () {
      expect(AppTextScale.display.weight, FontWeight.w700); // 680
      expect(AppTextScale.h2.weight, FontWeight.w700); // 650
      expect(AppTextScale.h1.weight, FontWeight.w600); // 620
      expect(AppTextScale.h3.weight, FontWeight.w600); // 620
      expect(AppTextScale.body.weight, FontWeight.w400);
      expect(AppTextScale.sm.weight, FontWeight.w400);
      expect(AppTextScale.caption.weight, FontWeight.w400);
      expect(AppTextScale.micro.weight, FontWeight.w600); // 600
    });

    test('Material 槽位全部映射到八档，全局无 9px/10px 角标', () {
      final theme = AppTheme.light(AppAccent.terracotta);
      final slots = <TextStyle?>[
        theme.textTheme.displayLarge,
        theme.textTheme.displayMedium,
        theme.textTheme.displaySmall,
        theme.textTheme.headlineLarge,
        theme.textTheme.headlineMedium,
        theme.textTheme.headlineSmall,
        theme.textTheme.titleLarge,
        theme.textTheme.titleMedium,
        theme.textTheme.titleSmall,
        theme.textTheme.bodyLarge,
        theme.textTheme.bodyMedium,
        theme.textTheme.bodySmall,
        theme.textTheme.labelLarge,
        theme.textTheme.labelMedium,
        theme.textTheme.labelSmall,
      ];
      expect(slots.every((s) => s != null), isTrue);
      for (final style in slots) {
        expect(style!.fontSize, greaterThanOrEqualTo(11));
      }
      expect(theme.textTheme.labelSmall!.fontSize, 12);
      expect(theme.textTheme.labelMedium!.fontSize, 11);
      expect(theme.textTheme.bodySmall!.fontSize, 13);
    });
  });

  group('阅读主题（v1.2 B2：7 套，独立于应用主题）', () {
    test('背景色与正文色符合权威色表', () {
      expect(AppReaderTheme.paper.palette.bg, const Color(0xFFFFFFFF));
      expect(AppReaderTheme.paper.palette.fg, const Color(0xFF26251F));
      expect(AppReaderTheme.beige.palette.bg, const Color(0xFFF6EFE0));
      expect(AppReaderTheme.beige.palette.fg, const Color(0xFF40382B));
      expect(AppReaderTheme.green.palette.bg, const Color(0xFFE5EEE2));
      expect(AppReaderTheme.green.palette.fg, const Color(0xFF2B3529));
      expect(AppReaderTheme.slate.palette.bg, const Color(0xFFE9EEF4));
      expect(AppReaderTheme.slate.palette.fg, const Color(0xFF262E3A));
      expect(AppReaderTheme.dark.palette.bg, const Color(0xFF14151A));
      expect(AppReaderTheme.dark.palette.fg, const Color(0xFFC8CACD));
      expect(AppReaderTheme.dusk.palette.bg, const Color(0xFF1E1913));
      expect(AppReaderTheme.dusk.palette.fg, const Color(0xFFD8CFC0));
      expect(AppReaderTheme.ink.palette.bg, const Color(0xFF0B0B0D));
      expect(AppReaderTheme.ink.palette.fg, const Color(0xFFDADADD));
    });

    test('弱化文字与分隔线色符合权威色表（次级文字 ≥4.5:1 由对比度门锁定）', () {
      expect(AppReaderTheme.paper.palette.muted, const Color(0xFF6F6C64));
      expect(AppReaderTheme.paper.palette.rule, const Color(0xFFECEAE4));
      expect(AppReaderTheme.beige.palette.muted, const Color(0xFF6B6152));
      expect(AppReaderTheme.beige.palette.rule, const Color(0xFFE3D9C2));
      expect(AppReaderTheme.green.palette.muted, const Color(0xFF556354));
      expect(AppReaderTheme.green.palette.rule, const Color(0xFFD2DDCD));
      expect(AppReaderTheme.slate.palette.muted, const Color(0xFF56616F));
      expect(AppReaderTheme.slate.palette.rule, const Color(0xFFD5DCE5));
      expect(AppReaderTheme.dark.palette.muted, const Color(0xFF9AA0A8));
      expect(AppReaderTheme.dark.palette.rule, const Color(0xFF26282E));
      expect(AppReaderTheme.dusk.palette.muted, const Color(0xFFB0A492));
      expect(AppReaderTheme.dusk.palette.rule, const Color(0xFF332C22));
      expect(AppReaderTheme.ink.palette.muted, const Color(0xFF9C9CA4));
      expect(AppReaderTheme.ink.palette.rule, const Color(0xFF222226));
    });

    test('令牌透出阅读主题色（默认白色）', () {
      final t = AppTheme.dark(AppAccent.terracotta)
          .extension<AppDesignTokens>()!;
      expect(t.readerBg, const Color(0xFFFFFFFF));
      expect(t.readerFg, const Color(0xFF26251F));
      expect(t.readerMuted, const Color(0xFF6F6C64));
      expect(t.readerRule, const Color(0xFFECEAE4));
      expect(t.readerPageShadow, const Color(0x241C1A16));
      expect(t.readerPalette, AppReaderTheme.paper.palette);
    });

    test('七套阅读主题都有中文名（朴素颜色描述，B2）', () {
      expect(AppReaderTheme.values.map((t) => t.label).toList(), [
        '白色',
        '米黄',
        '浅绿',
        '浅灰蓝',
        '深灰',
        '深棕',
        '纯黑',
      ]);
    });

    test('isNight：夜间系 = 深灰/深棕/纯黑（B3）', () {
      expect(
        AppReaderTheme.values.where((t) => t.isNight).map((t) => t.name),
        ['dark', 'dusk', 'ink'],
      );
    });
  });

  group('尺度与品牌风格', () {
    test('间距 4px 基准', () {
      expect(AppSpacing.s1, 4);
      expect(AppSpacing.s2, 8);
      expect(AppSpacing.s3, 12);
      expect(AppSpacing.s4, 16);
      expect(AppSpacing.s5, 20);
      expect(AppSpacing.s6, 24);
      expect(AppSpacing.s8, 32);
      expect(AppSpacing.s10, 40);
      expect(AppSpacing.s12, 48);
    });

    test('圆角与布局常量符合原型', () {
      expect(AppRadius.xs, 4);
      expect(AppRadius.sm, 6);
      expect(AppRadius.md, 10);
      expect(AppRadius.lg, 14);
      expect(AppRadius.xl, 20);
      expect(AppRadius.full, 999);
      expect(AppLayout.railWidth, 232);
      expect(AppLayout.railNarrowWidth, 68);
      expect(AppLayout.topBarHeight, 60);
      expect(AppLayout.contentMaxWidth, 1240);
      expect(AppLayout.readerMaxWidth, 720);
    });

    test('accent 中文名与解析', () {
      expect(AppAccent.terracotta.label, '赭石');
      expect(AppAccent.teal.label, '青瓷');
      expect(AppAccent.ink.label, '墨绿');
      expect(AppAccent.fromName('teal'), AppAccent.teal);
      expect(AppAccent.fromName('TERRACOTTA'), AppAccent.terracotta);
      expect(AppAccent.fromName('墨绿'), AppAccent.ink);
      // 未知值回落到默认赭石，不让应用起不来。
      expect(AppAccent.fromName('不存在的风格'), AppAccent.terracotta);
    });

    test('阴影三级：浅深各一套且非空', () {
      final light = AppTheme.light(AppAccent.terracotta)
          .extension<AppDesignTokens>()!;
      final dark = AppTheme.dark(AppAccent.terracotta)
          .extension<AppDesignTokens>()!;
      expect(light.sh1, isNotEmpty);
      expect(light.sh2, isNotEmpty);
      expect(light.sh3, isNotEmpty);
      expect(dark.sh1, isNotEmpty);
      expect(dark.sh2, isNotEmpty);
      expect(dark.sh3, isNotEmpty);
      expect(light.brandFocus, isNotEmpty);
    });
  });

  group('ThemeExtension 契约', () {
    test('copyWith / lerp 不抛异常且保留未覆盖字段', () {
      final t = AppDesignTokens.light(AppAccent.terracotta);
      final copy = t.copyWith(accent: AppAccent.ink);
      expect(copy.accent, AppAccent.ink);
      expect(copy.bg, t.bg);

      final dark = AppDesignTokens.dark(AppAccent.terracotta);
      final mid = t.lerp(dark, 0.5);
      expect(mid.bg, isNot(t.bg));
      expect(mid.bg, isNot(dark.bg));
      expect(t.lerp(null, 0.5).bg, t.bg);
    });

    test('应用底色 = 令牌 bg（不再有独立底色）', () {
      for (final accent in AppAccent.values) {
        final light = AppTheme.light(accent);
        final dark = AppTheme.dark(accent);
        expect(
          light.scaffoldBackgroundColor,
          light.extension<AppDesignTokens>()!.bg,
        );
        expect(
          dark.scaffoldBackgroundColor,
          dark.extension<AppDesignTokens>()!.bg,
        );
      }
    });
  });
}
