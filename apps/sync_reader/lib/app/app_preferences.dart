/// 应用偏好（外观风格 accent / 明暗模式）的持久化状态（docs/10 §4.7 外观区）。
///
/// 实现方式（v1.1 重设计第 2 批，替换批 0 的写死默认值）：
/// - `Notifier` 持内存态（初始默认：赭石 + 跟随系统），UI watch 即时生效；
/// - 启动时由 [hydrateAppPreferences]（app.dart 挂载）异步从 `app_settings`
///   表读回，读到什么用什么；表损坏等异常回落默认值，不阻塞启动；
/// - 设置页写入走 `notifier.set*`：先更新内存再落库，双向一致。
///
/// 键名：`app.accent` / `app.theme_mode`（值均为枚举名字符串）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/design_tokens.dart';
import 'providers.dart';

/// app_settings 表中的偏好键名。
abstract final class AppPreferenceKeys {
  /// 品牌风格（AppAccent.name）。
  static const accent = 'app.accent';

  /// 外观模式（ThemeMode.name）。
  static const themeMode = 'app.theme_mode';
}

/// 品牌风格状态：内存值 + `app_settings` 落库。
final appAccentProvider = NotifierProvider<AppAccentNotifier, AppAccent>(
  AppAccentNotifier.new,
);

final class AppAccentNotifier extends Notifier<AppAccent> {
  /// 用户本会话是否已手动改过（改过则启动加载不再覆盖用户选择）。
  bool _touched = false;

  @override
  AppAccent build() => AppAccent.terracotta;

  /// 从 app_settings 读回 accent（应用启动时调用一次；失败回落默认）。
  Future<void> load() async {
    if (_touched) return;
    try {
      final raw = await ref
          .read(appSettingsDaoProvider)
          .getValue(AppPreferenceKeys.accent);
      if (_touched || raw == null) return;
      state = AppAccent.fromName(raw);
    } catch (_) {
      // 表损坏/读取失败：保持默认赭石，不阻塞启动（本地优先，CLAUDE.md §4.1）。
    }
  }

  /// 切换 accent：内存即时生效 + 落库（失败不回滚内存，下次启动再收敛）。
  Future<void> setAccent(AppAccent accent) async {
    _touched = true;
    state = accent;
    try {
      await ref
          .read(appSettingsDaoProvider)
          .setValue(AppPreferenceKeys.accent, accent.name);
    } catch (_) {
      // 落库失败静默：内存态已生效，仅本次会话持久化缺失。
    }
  }
}

/// 外观模式状态：内存值 + `app_settings` 落库。
final appThemeModeProvider = NotifierProvider<AppThemeModeNotifier, ThemeMode>(
  AppThemeModeNotifier.new,
);

final class AppThemeModeNotifier extends Notifier<ThemeMode> {
  bool _touched = false;

  @override
  ThemeMode build() => ThemeMode.system;

  /// 从 app_settings 读回外观模式（应用启动时调用一次；失败回落默认）。
  Future<void> load() async {
    if (_touched) return;
    try {
      final raw = await ref
          .read(appSettingsDaoProvider)
          .getValue(AppPreferenceKeys.themeMode);
      if (_touched || raw == null) return;
      state = _themeModeFromName(raw);
    } catch (_) {
      // 同上：读取失败保持「跟随系统」。
    }
  }

  /// 切换外观模式：内存即时生效 + 落库。
  Future<void> setThemeMode(ThemeMode mode) async {
    _touched = true;
    state = mode;
    try {
      await ref
          .read(appSettingsDaoProvider)
          .setValue(AppPreferenceKeys.themeMode, mode.name);
    } catch (_) {
      // 落库失败静默。
    }
  }

  /// 解析持久化的模式名：未知/损坏值一律回落「跟随系统」。
  static ThemeMode _themeModeFromName(String name) {
    for (final mode in ThemeMode.values) {
      if (mode.name == name.trim()) return mode;
    }
    return ThemeMode.system;
  }
}

/// 偏好水合宿主：挂载时异步从 app_settings 读回 accent / 外观模式
/// （fire-and-forget；读取失败由 notifier 内部回落默认值，不阻塞启动）。
///
/// 由 app.dart 挂在 MaterialApp 外层；测试经它复现真实的启动读回路径。
class AppPreferencesHydrator extends ConsumerStatefulWidget {
  const AppPreferencesHydrator({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppPreferencesHydrator> createState() =>
      _AppPreferencesHydratorState();
}

final class _AppPreferencesHydratorState
    extends ConsumerState<AppPreferencesHydrator> {
  @override
  void initState() {
    super.initState();
    unawaited(ref.read(appAccentProvider.notifier).load().catchError((_) {}));
    unawaited(
      ref.read(appThemeModeProvider.notifier).load().catchError((_) {}),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
