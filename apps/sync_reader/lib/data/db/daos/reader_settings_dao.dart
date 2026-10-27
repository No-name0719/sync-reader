/// 阅读偏好 DAO（FR-206）：key-value，值为 JSON 文本（docs/05 §5 reader_settings）。
library;

import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables.dart';

part 'reader_settings_dao.g.dart';

/// 阅读偏好表访问对象。
@DriftAccessor(tables: [ReaderSettings])
class ReaderSettingsDao extends DatabaseAccessor<AppDatabase>
    with _$ReaderSettingsDaoMixin {
  ReaderSettingsDao(super.db);

  /// 读一个键的 JSON 值（不存在返回 null）。
  Future<String?> getValue(String key) async {
    final row = await (select(
      readerSettings,
    )..where((r) => r.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  /// 写一个键的 JSON 值（存在则覆盖）。
  Future<void> setValue(String key, String value) => into(readerSettings)
      .insertOnConflictUpdate(
        ReaderSettingsCompanion.insert(key: key, value: value),
      );
}
