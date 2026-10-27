// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'reader_settings_dao.dart';

// ignore_for_file: type=lint
mixin _$ReaderSettingsDaoMixin on DatabaseAccessor<AppDatabase> {
  $ReaderSettingsTable get readerSettings => attachedDatabase.readerSettings;
  ReaderSettingsDaoManager get managers => ReaderSettingsDaoManager(this);
}

class ReaderSettingsDaoManager {
  final _$ReaderSettingsDaoMixin _db;
  ReaderSettingsDaoManager(this._db);
  $$ReaderSettingsTableTableManager get readerSettings =>
      $$ReaderSettingsTableTableManager(
        _db.attachedDatabase,
        _db.readerSettings,
      );
}
