// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'local_only_books_dao.dart';

// ignore_for_file: type=lint
mixin _$LocalOnlyBooksDaoMixin on DatabaseAccessor<AppDatabase> {
  $LocalOnlyBooksTable get localOnlyBooks => attachedDatabase.localOnlyBooks;
  LocalOnlyBooksDaoManager get managers => LocalOnlyBooksDaoManager(this);
}

class LocalOnlyBooksDaoManager {
  final _$LocalOnlyBooksDaoMixin _db;
  LocalOnlyBooksDaoManager(this._db);
  $$LocalOnlyBooksTableTableManager get localOnlyBooks =>
      $$LocalOnlyBooksTableTableManager(
        _db.attachedDatabase,
        _db.localOnlyBooks,
      );
}
