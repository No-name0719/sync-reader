/// 应用级本地设置 DAO（docs/10 §3.1：accent / 外观模式持久化等）。
///
/// key-value 表（app_settings，schemaVersion 3 新增），值为 JSON 或纯
/// 字符串；仅本地、不同步、不入云端 meta。
library;

import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables.dart';

part 'app_settings_dao.g.dart';

/// 应用级设置表访问对象。
@DriftAccessor(tables: [AppSettings])
class AppSettingsDao extends DatabaseAccessor<AppDatabase>
    with _$AppSettingsDaoMixin {
  AppSettingsDao(super.db);

  /// 读一个键的值（不存在返回 null）。
  Future<String?> getValue(String key) async {
    final row = await (select(
      appSettings,
    )..where((r) => r.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  /// 写一个键的值（存在则覆盖）。
  Future<void> setValue(String key, String value) => into(
    appSettings,
  ).insertOnConflictUpdate(AppSettingsCompanion.insert(key: key, value: value));

  /// 监听一个键的值（键不存在时发 null；写入后实时推送）。
  Stream<String?> watchValue(String key) {
    return (select(appSettings)..where((r) => r.key.equals(key)))
        .watchSingleOrNull()
        .map((row) => row?.value);
  }
}
