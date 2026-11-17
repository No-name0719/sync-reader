/// 阅读设置仓库（FR-206）：ReaderSettings ↔ reader_settings 表的 JSON 序列化。
///
/// 通知方式选择 **Stream**（而非 ChangeNotifier）：与 drift/书库侧的
/// watch 习惯一致，UI 侧用 `StreamBuilder` 或 Riverpod StreamProvider 消费。
///
/// v1.3.6（移动端实测反馈）：[load] 改为**返回当前生效值**而非首次载入的
/// 旧快照——旧实现让「改了设置再打开页面又显示默认配置」「换一本书后翻页
/// 模式被重置为默认」成为常态（详见 [load]）。
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

  /// 首次载入的 future（并发调用只读一次库）。
  Future<ReaderSettings>? _loading;

  /// 保存序号：用于识别「读取库期间发生了保存」的竞态
  /// （此时以保存值为准，不让旧库值覆盖新值）。
  int _saveSeq = 0;

  /// 当前生效的设置（未调用 [load] 前为出厂默认；[save] 后为最新值）。
  ReaderSettings get current => _cached;

  /// 设置变更广播（含 [save] 触发的变更）。
  Stream<ReaderSettings> get changes => _controller.stream;

  /// 从数据库载入（幂等；并发调用只读一次库）。
  ///
  /// **返回当前生效值，而非首次载入的旧快照**：
  /// 旧实现把首次 [load] 的 future 记下来，之后每次 [load] 都返回那个快照
  /// ——会话中改过设置后，[load] 仍返回改之前的值，于是
  /// 「改了设置 → 重新打开页面又变回默认值」「换一本书后翻页模式被重置」
  /// （用户实测）。现在：首次载入完成后，[load] 一律返回 [_cached]
  /// （[save] 会同步更新它）。
  Future<ReaderSettings> load() {
    final pending = _loading;
    if (pending != null) {
      // 首次载入进行中：等它结束，返回**当前**值（期间若有保存，以保存为准）。
      return pending.then((_) => _cached);
    }
    return _loading = _doLoad();
  }

  Future<ReaderSettings> _doLoad() async {
    final seqAtStart = _saveSeq;
    final raw = await _dao.getValue(storageKey);
    if (seqAtStart != _saveSeq) {
      // 读取期间发生了保存：不以旧库值覆盖新值（保存值已是权威）。
      return _cached;
    }
    if (raw != null) {
      try {
        final parsed = ReaderSettings.fromJson(
          jsonDecode(raw) as Map<String, Object?>,
        );
        _cached = parsed;
        // 旧值迁移落盘（docs/10 A11「只增不删」）：解析成功但序列化形态
        // 已升级（如 v1.0 主题名 light→paper、无 v 标记 → 有 v:2 标记）时
        // 以新形态覆写回库，下次读取即为新形态（未知主题名也随之归一为
        // 默认纸白）。覆写失败不阻塞阅读。
        final normalized = jsonEncode(parsed.toJson());
        if (normalized != raw) {
          try {
            await _dao.setValue(storageKey, normalized);
          } on Exception {
            // 迁移覆写失败：本次会话仍使用迁移后的内存值。
          }
        }
      } on FormatException {
        // 损坏的设置回落默认并覆写，不阻塞阅读。
        await _dao.setValue(storageKey, jsonEncode(_cached.toJson()));
      }
    }
    return _cached;
  }

  /// 保存设置：落库 + 更新缓存 + 广播。
  Future<void> save(ReaderSettings settings) async {
    _saveSeq++;
    _cached = settings;
    await _dao.setValue(storageKey, jsonEncode(settings.toJson()));
    _controller.add(settings);
  }

  /// 释放（通常由 Riverpod onDispose 调用）。
  void dispose() {
    _controller.close();
  }
}
