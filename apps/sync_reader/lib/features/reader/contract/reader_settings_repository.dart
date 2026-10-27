/// 阅读设置仓库（FR-206）：ReaderSettings ↔ reader_settings 表的 JSON 序列化。
///
/// 通知方式选择 **Stream**（而非 ChangeNotifier）：与 drift/书库侧的
/// watch 习惯一致，UI 侧用 `StreamBuilder` 或 Riverpod StreamProvider 消费。
library;

import 'dart:async';
import 'dart:convert';

import '../../../data/db/daos/reader_settings_dao.dart';
import 'reader_settings.dart';

/// 阅读设置仓库。缓存当前值；[save] 落库后向 [changes] 广播新值。
class ReaderSettingsRepository {
  /// [dao] 来自 databaseProvider（测试可注入内存库 DAO）。
  ReaderSettingsRepository(this._dao);

  /// reader_settings 表中的存储键（v1 整体单键存取）。
  static const storageKey = 'reader_settings';

  final ReaderSettingsDao _dao;
  ReaderSettings _cached = ReaderSettings.defaults;
  final _controller = StreamController<ReaderSettings>.broadcast();
  Future<ReaderSettings>? _loaded;

  /// 当前生效的设置（未调用 [load] 前为出厂默认）。
  ReaderSettings get current => _cached;

  /// 设置变更广播（含 [save] 触发的变更）。
  Stream<ReaderSettings> get changes => _controller.stream;

  /// 从数据库载入（幂等；并发调用只读一次）。
  Future<ReaderSettings> load() {
    return _loaded ??= _doLoad();
  }

  Future<ReaderSettings> _doLoad() async {
    final raw = await _dao.getValue(storageKey);
    if (raw != null) {
      try {
        _cached = ReaderSettings.fromJson(
          jsonDecode(raw) as Map<String, Object?>,
        );
      } on FormatException {
        // 损坏的设置回落默认并覆写，不阻塞阅读。
        await _dao.setValue(storageKey, jsonEncode(_cached.toJson()));
      }
    }
    return _cached;
  }

  /// 保存设置：落库 + 更新缓存 + 广播。
  Future<void> save(ReaderSettings settings) async {
    _cached = settings;
    await _dao.setValue(storageKey, jsonEncode(settings.toJson()));
    _controller.add(settings);
  }

  /// 释放（通常由 Riverpod onDispose 调用）。
  void dispose() {
    _controller.close();
  }
}
