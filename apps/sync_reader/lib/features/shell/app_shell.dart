/// 应用外壳（docs/10 §4.1 / A1）：左侧导航栏 / 图标栏 / 底部标签栏 + 内容区。
///
/// 响应式断点（原型 §11 容器查询的 Flutter 转写）：
/// - ≥1180px：232px 宽侧栏（品牌区 / 主导航三项 / 底部同步状态胶囊）；
/// - 861–1179px：68px 图标栏（只留图标 + 选中态）；
/// - ≤860px：隐藏侧栏，改底部标签栏（书库 / 同步 / 设置）。
///
/// 外壳本体不画 AppBar——每个页面自带 Scaffold/AppBar，外壳只提供
/// 导航与内容区。阅读器（`/reader/:id`）不包外壳，全屏沉浸。
/// 当前选中项从路由位置前缀推导（`GoRouterState.of`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../core/version.dart';
import '../sync/sync_status.dart';

/// 外壳响应式断点（docs/10 §4.1；宽度取 `MediaQuery.sizeOf`）。
abstract final class AppShellBreakpoints {
  /// ≥ 此宽度用 232px 宽侧栏。
  static const double wideRailMin = 1180;

  /// ≤ 此宽度用底部标签栏（861–1179 为图标栏）。
  static const double bottomBarMax = 860;
}

/// 导航目的地（只有三项：书库 / 同步 / 设置，docs/10 §4.1 Q16）。
enum ShellDestination {
  /// 书库（含详情页；批 7 的 `/tools/batch-import` 也归书库组）。
  library('/', '书库', Icons.auto_stories_outlined, Icons.auto_stories),

  /// 同步设置（含配置向导；批 7 的 `/sync/cloudlib` 归同步组）。
  sync('/sync/settings', '同步', Icons.cloud_sync_outlined, Icons.cloud_sync),

  /// 应用设置。
  settings('/settings', '设置', Icons.settings_outlined, Icons.settings);

  const ShellDestination(this.route, this.label, this.icon, this.selectedIcon);

  /// 点击导航去的路由位置。
  final String route;

  /// 导航标签。
  final String label;

  /// 未选中图标。
  final IconData icon;

  /// 选中图标。
  final IconData selectedIcon;

  /// 路由位置 → 当前选中项（前缀匹配，docs/10 §4.1）。
  ///
  /// `/` 与 `/book/*` → 书库；`/sync/*` → 同步；`/settings` → 设置；
  /// `/tools/*`（批 7 批量导入）归书库组。未匹配回落书库（首页）。
  static ShellDestination of(String location) {
    if (location.startsWith('/sync')) return ShellDestination.sync;
    if (location.startsWith('/settings')) return ShellDestination.settings;
    // `/`、`/book/*`、`/tools/*` 及任何未来未分组路由都归书库组。
    return ShellDestination.library;
  }
}

/// 应用外壳。
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child, this.location});

  /// shell 内当前页面的内容（由 ShellRoute 传入的子导航器）。
  final Widget child;

  /// 当前匹配的路由位置；缺省时经 [GoRouterState.of] 推导。
  final String? location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = MediaQuery.sizeOf(context).width;
    final destination = ShellDestination.of(
      location ?? GoRouterState.of(context).matchedLocation,
    );
    if (width <= AppShellBreakpoints.bottomBarMax) {
      // ≤860：隐藏侧栏，底部标签栏（原型 .mobile-nav）。
      return Scaffold(
        body: child,
        bottomNavigationBar: _BottomTabBar(destination: destination),
      );
    }
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SideRail(
            narrow: width < AppShellBreakpoints.wideRailMin,
            destination: destination,
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// 左侧导航栏（宽 232 / 窄 68）。
class _SideRail extends ConsumerWidget {
  const _SideRail({required this.narrow, required this.destination});

  final bool narrow;
  final ShellDestination destination;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.appTokens;
    return Container(
      width: narrow ? AppLayout.railNarrowWidth : AppLayout.railWidth,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: t.border)),
      ),
      child: Material(
        color: t.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _RailBrand(narrow: narrow),
            Expanded(
              child: SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: narrow ? 8 : 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 「主导航」分组标签：窄栏隐藏（原型 3013-3016 行）。
                      if (!narrow) const _RailSectionLabel(),
                      for (final d in ShellDestination.values)
                        _RailItem(
                          destination: d,
                          selected: d == destination,
                          narrow: narrow,
                        ),
                      SizedBox(height: AppSpacing.s4),
                    ],
                  ),
                ),
              ),
            ),
            _RailSyncChip(narrow: narrow),
          ],
        ),
      ),
    );
  }
}

/// 品牌区：品牌标 + 产品名 + 版本小字（窄栏只留品牌标）。
class _RailBrand extends StatelessWidget {
  const _RailBrand({required this.narrow});

  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    // 品牌标直接用应用图标 PNG：与 Android 启动器 / Windows 应用图标
    // 是同一张资源（蜂蜜黄圆角方块 + 白色 R 标），生成脚本见
    // scripts/gen_app_icons.py。
    final mark = SizedBox(
      width: 36,
      height: 36,
      child: Image.asset(
        'assets/brand/app_icon.png',
        width: 36,
        height: 36,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s4,
        AppSpacing.s4,
        AppSpacing.s4,
        AppSpacing.s3,
      ),
      child: narrow
          ? Center(child: mark)
          : Row(
              children: [
                mark,
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'SyncReader',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.sm.copyWith(
                          fontSize: 15,
                          height: 1.15,
                          fontWeight: FontWeight.w600,
                          color: t.text,
                        ),
                      ),
                      Text('v$appVersion', style: t.tertiary),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

/// 「主导航」分组标签（原型 .rail-label）。
class _RailSectionLabel extends StatelessWidget {
  const _RailSectionLabel();

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s3,
        AppSpacing.s2,
        AppSpacing.s3,
        AppSpacing.s1,
      ),
      child: Text(
        '主导航',
        style: t.micro.copyWith(color: t.text3, letterSpacing: 1.2),
      ),
    );
  }
}

/// 导航项：宽栏「图标 + 文字」，窄栏居中只留图标（选中态 = 品牌浅底圆角）。
class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.destination,
    required this.selected,
    required this.narrow,
  });

  final ShellDestination destination;
  final bool selected;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final item = Material(
      color: selected ? t.brandSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        // 选中态底色是品牌浅色 → 浮层用品牌色淡染（见 [brandOverlay]）。
        overlayColor: brandOverlay(selected ? t.brandText : t.text2),
        onTap: () => context.go(destination.route),
        child: Container(
          height: narrow ? 38 : 37,
          padding: narrow
              ? EdgeInsets.zero
              : const EdgeInsets.symmetric(horizontal: AppSpacing.s3),
          alignment: Alignment.center,
          child: Row(
            children: [
              Icon(
                selected ? destination.selectedIcon : destination.icon,
                size: 18,
                color: selected ? t.brandText : t.text2,
              ),
              if (!narrow) ...[
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Text(
                    destination.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.sm.copyWith(
                      fontSize: 13.5,
                      color: selected ? t.brandText : t.text2,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return narrow
        ? Tooltip(
            message: destination.label,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: item,
            ),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: item,
          );
  }
}

/// 底部同步状态胶囊（读 [syncMemoryStatusProvider]，点击进同步设置）。
/// 宽栏显示状态词 + 副文案；窄栏只显示状态圆点。
class _RailSyncChip extends ConsumerWidget {
  const _RailSyncChip({required this.narrow});

  final bool narrow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memory = ref.watch(syncMemoryStatusProvider);
    final t = context.appTokens;

    final (
      Color dotColor,
      Color halo,
      String title,
      String subtitle,
      Color titleColor,
    ) = switch (memory.id) {
      SyncStateId.unconfigured => (
        t.text3,
        Colors.transparent,
        '未配置',
        '点按配置同步',
        t.text2,
      ),
      SyncStateId.idle ||
      SyncStateId.ok => (t.success, t.successSoft, '已同步', '点按管理同步', t.text),
      SyncStateId.syncing => (t.brand, t.brandSoft, '同步中…', '正在同步书库数据', t.text),
      SyncStateId.failed => (
        t.danger,
        t.dangerSoft,
        '同步失败',
        memory.failureText ?? '点按查看原因',
        t.danger,
      ),
    };

    final dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: dotColor,
        boxShadow: [
          if (halo != Colors.transparent)
            BoxShadow(color: halo, spreadRadius: 3, blurRadius: 0),
        ],
      ),
    );

    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.border)),
      ),
      padding: const EdgeInsets.all(AppSpacing.s3),
      child: Material(
        color: t.surface2,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: () => context.go(ShellDestination.sync.route),
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.s3),
            child: narrow
                ? Center(child: dot)
                : Row(
                    children: [
                      dot,
                      const SizedBox(width: AppSpacing.s2),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.sm.copyWith(
                                fontWeight: FontWeight.w600,
                                color: titleColor,
                              ),
                            ),
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.micro.copyWith(
                                fontWeight: FontWeight.w400,
                                color: t.text3,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// 底部标签栏（≤860px；原型 .mobile-nav：高 58，图标 22 + 标签 11px）。
class _BottomTabBar extends StatelessWidget {
  const _BottomTabBar({required this.destination});

  final ShellDestination destination;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Material(
      color: t.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: t.border)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 58,
            child: Row(
              children: [
                for (final d in ShellDestination.values)
                  Expanded(
                    child: InkWell(
                      onTap: () => context.go(d.route),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            d == destination ? d.selectedIcon : d.icon,
                            size: 22,
                            color: d == destination ? t.brand : t.text2,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            d.label,
                            style: t.micro.copyWith(
                              fontWeight: FontWeight.w400,
                              color: d == destination ? t.brand : t.text2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
