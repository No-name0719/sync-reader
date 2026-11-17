/// 书架网格度量单测（v1.3.4 移动端书架密度整改）。
///
/// 锁两件事：
/// 1. 宽屏档的列数与改造前一致（1440 → 7 列、860 → 5 列），桌面不退化；
/// 2. 窄屏档（手机）在四档代表性视口下**一屏至少 3 行完整卡片**
///    （≥9 本），这是用户诉求「一屏 3*3 - 3*4 本」的硬口径。
library;

import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/library/library_grid_metrics.dart';

/// 网格视口上方的固定外壳高度：顶栏 56 + 搜索框 48（含 12 上内边距）
/// + 筛选栏 84（窄屏两行排版）。
const double _appChromeAboveGrid = 200;

/// 移动底栏高度（应用外壳 `.mobile-nav`）。
const double _mobileBottomBar = 58;

/// 设备视口 → 网格视口（扣掉顶栏/搜索/筛选与移动底栏）。
Size _gridViewport(Size device) =>
    Size(device.width, device.height - _appChromeAboveGrid - _mobileBottomBar);

/// 四档代表性手机视口。
const _phones = <String, Size>{
  '360×640 小屏安卓': Size(360, 640),
  '390×844 iPhone 14': Size(390, 844),
  '412×915 Pixel 7': Size(412, 915),
  '430×932 iPhone 15 Pro Max': Size(430, 932),
};

void main() {
  group('窄屏（手机）紧凑档', () {
    test('四档手机视口：一屏 ≥3 行完整卡片（≥9 本）', () {
      for (final entry in _phones.entries) {
        final viewport = _gridViewport(entry.value);
        final metrics = computeLibraryGridMetrics(
          viewportWidth: viewport.width,
          viewportHeight: viewport.height,
          spec: LibraryGridSpec.compact,
        );
        expect(metrics.columns, 3, reason: '${entry.key}：应为 3 列');
        expect(
          metrics.rowsPerScreen,
          greaterThanOrEqualTo(3),
          reason: '${entry.key}：一屏应至少 3 行完整卡片',
        );
        expect(
          metrics.visibleBooks,
          greaterThanOrEqualTo(9),
          reason: '${entry.key}：一屏应至少 9 本完整可见',
        );
      }
    });

    test('紧凑档：卡高 = 封面高（书名叠在封面上，不占额外行高）', () {
      final metrics = computeLibraryGridMetrics(
        viewportWidth: 390,
        viewportHeight: 586,
        spec: LibraryGridSpec.compact,
      );
      expect(metrics.metaHeight, 0);
      expect(metrics.cardHeight, closeTo(metrics.coverHeight, 0.001));
      expect(metrics.overlayTitle, isTrue);
      // 宽高比 = 卡宽 / 卡高（网格格子与卡片实际高度一致 → 不裁切、不留白）。
      expect(
        metrics.childAspectRatio,
        closeTo(metrics.cardWidth / metrics.cardHeight, 1e-9),
      );
    });

    test('紧凑档：封面比例在 [1:1, 2:3] 之间（不压成横片）', () {
      for (final entry in _phones.entries) {
        final viewport = _gridViewport(entry.value);
        final metrics = computeLibraryGridMetrics(
          viewportWidth: viewport.width,
          viewportHeight: viewport.height,
          spec: LibraryGridSpec.compact,
        );
        final factor = metrics.coverHeight / metrics.cardWidth;
        expect(
          factor,
          greaterThanOrEqualTo(libraryGridCompactMinCoverFactor - 1e-9),
          reason: '${entry.key}：封面高宽比不得小于 1:1',
        );
        expect(
          factor,
          lessThanOrEqualTo(libraryGridCompactMaxCoverFactor + 1e-9),
          reason: '${entry.key}：封面高宽比不得大于 2:3',
        );
      }
    });

    test('紧凑档：矮屏（小屏安卓）按可见行数压扁封面，高屏保留 2:3', () {
      final small = computeLibraryGridMetrics(
        viewportWidth: 360,
        viewportHeight: 382,
        spec: LibraryGridSpec.compact,
      );
      final tall = computeLibraryGridMetrics(
        viewportWidth: 390,
        viewportHeight: 586,
        spec: LibraryGridSpec.compact,
      );
      // 小屏：2:3 放不下 3 行 → 必须压扁（但不低于 1:1）。
      expect(small.coverHeight / small.cardWidth, lessThan(1.5));
      // 高屏：2:3 放得下 3 行 → 保留书籍标准比例。
      expect(tall.coverHeight / tall.cardWidth, closeTo(1.5, 1e-9));
    });
  });

  group('宽屏（桌面）舒适档', () {
    test('列数与改造前一致：1440 → 7 列、860 → 5 列、1180 → 6 列', () {
      // 网格视口宽 = 页面内容宽 - 网格内边距 32。
      // 1440 视口下内容受 contentMaxWidth(1240) 限制 → 网格视口 1240。
      expect(
        computeLibraryGridMetrics(
          viewportWidth: 1240,
          viewportHeight: 798,
          spec: LibraryGridSpec.comfortable,
        ).columns,
        7,
      );
      expect(
        computeLibraryGridMetrics(
          viewportWidth: 860,
          viewportHeight: 798,
          spec: LibraryGridSpec.comfortable,
        ).columns,
        5,
      );
      // 1180 窄栏：内容 1112 → 网格视口 1112 → 6 列（改造前委托口径）。
      expect(
        computeLibraryGridMetrics(
          viewportWidth: 1112,
          viewportHeight: 798,
          spec: LibraryGridSpec.comfortable,
        ).columns,
        6,
      );
    });

    test('封面 2:3 + 文字区 84px（观感与改造前一致）', () {
      final metrics = computeLibraryGridMetrics(
        viewportWidth: 1240,
        viewportHeight: 798,
        spec: LibraryGridSpec.comfortable,
      );
      expect(metrics.coverAspectRatio, closeTo(2 / 3, 1e-9));
      expect(metrics.metaHeight, libraryGridComfortableMetaHeight);
      expect(metrics.overlayTitle, isFalse);
      // 1440 下 7 列：卡宽 = (1208 - 16*6) / 7。
      expect(metrics.cardWidth, closeTo((1208 - 96) / 7, 1e-9));
    });
  });

  group('规格分档', () {
    test('按视口宽挑档：≤520 手机走紧凑档，其余走宽屏档', () {
      expect(libraryGridSpecForWidth(360), LibraryGridSpec.compact);
      expect(libraryGridSpecForWidth(390), LibraryGridSpec.compact);
      expect(libraryGridSpecForWidth(430), LibraryGridSpec.compact);
      expect(libraryGridSpecForWidth(520), LibraryGridSpec.compact);
      expect(libraryGridSpecForWidth(521), LibraryGridSpec.comfortable);
      expect(libraryGridSpecForWidth(860), LibraryGridSpec.comfortable);
      expect(libraryGridSpecForWidth(1440), LibraryGridSpec.comfortable);
    });
  });
}
