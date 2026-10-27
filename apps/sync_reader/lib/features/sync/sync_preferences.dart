/// 同步偏好存取（FR-405/407）：autoSyncEnabled / wifiOnlyContent / 配额越权。
///
/// 存储于 reader_settings 表（M1 已有 key-value 结构，键 `sync.preferences`，
/// 值 JSON），**不改表结构**（docs/05 §5）。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// 同步偏好快照。
class SyncPreferences {
  const SyncPreferences({
    this.autoSyncEnabled = true,
    this.wifiOnlyContent = true,
    this.quotaOverride = false,
  });

  /// 自动同步总开关（关闭时仅手动"立即同步"生效，docs/04 §3）。
  final bool autoSyncEnabled;

  /// 仅 Wi-Fi 同步正文（元数据不受限，默认开，docs/04 §3）。
  final bool wifiOnlyContent;

  /// 配额越权放行（100% 后手动继续下载；二次确认由 UI 层做，docs/04 §8.3）。
  final bool quotaOverride;

  SyncPreferences copyWith({
    bool? autoSyncEnabled,
    bool? wifiOnlyContent,
    bool? quotaOverride,
  }) => SyncPreferences(
    autoSyncEnabled: autoSyncEnabled ?? this.autoSyncEnabled,
    wifiOnlyContent: wifiOnlyContent ?? this.wifiOnlyContent,
    quotaOverride: quotaOverride ?? this.quotaOverride,
  );

  Map<String, Object?> toJson() => {
    'autoSyncEnabled': autoSyncEnabled,
    'wifiOnlyContent': wifiOnlyContent,
    'quotaOverride': quotaOverride,
  };

  factory SyncPreferences.fromJson(Map<String, Object?> json) =>
      SyncPreferences(
        autoSyncEnabled: json['autoSyncEnabled'] is bool
            ? json['autoSyncEnabled'] as bool
            : true,
        wifiOnlyContent: json['wifiOnlyContent'] is bool
            ? json['wifiOnlyContent'] as bool
            : true,
        quotaOverride: json['quotaOverride'] is bool
            ? json['quotaOverride'] as bool
            : false,
      );
}

/// 同步偏好状态：默认值先行，启动时异步恢复；写即落库。
final syncPreferencesProvider =
    NotifierProvider<SyncPreferencesNotifier, SyncPreferences>(
      SyncPreferencesNotifier.new,
    );

final class SyncPreferencesNotifier extends Notifier<SyncPreferences> {
  /// reader_settings 表中的存储键。
  static const storageKey = 'sync.preferences';

  @override
  SyncPreferences build() {
    _restore();
    return const SyncPreferences();
  }

  Future<void> _restore() async {
    String? raw;
    try {
      raw = await ref.read(readerSettingsDaoProvider).getValue(storageKey);
    } catch (_) {
      // 数据层暂不可用（如无平台通道的测试环境）：保持默认值。
      return;
    }
    if (!ref.mounted || raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        state = SyncPreferences.fromJson(decoded.cast<String, Object?>());
      }
    } on FormatException {
      // 值损坏则保持默认，不阻塞主流程。
    }
  }

  /// 整体保存（写状态 + 落库）。
  Future<void> save(SyncPreferences prefs) async {
    state = prefs;
    try {
      await ref
          .read(readerSettingsDaoProvider)
          .setValue(storageKey, jsonEncode(prefs.toJson()));
    } catch (_) {
      // 落库失败不影响本会话生效（下次启动恢复默认/旧值）。
    }
  }

  /// 自动同步总开关。
  Future<void> setAutoSyncEnabled(bool value) =>
      save(state.copyWith(autoSyncEnabled: value));

  /// 仅 Wi-Fi 同步正文。
  Future<void> setWifiOnlyContent(bool value) =>
      save(state.copyWith(wifiOnlyContent: value));

  /// 配额越权放行（UI 层负责二次确认）。
  Future<void> setQuotaOverride(bool value) =>
      save(state.copyWith(quotaOverride: value));
}
