// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'reading_days_dao.dart';

// ignore_for_file: type=lint
mixin _$ReadingDaysDaoMixin on DatabaseAccessor<AppDatabase> {
  $BookGroupsTable get bookGroups => attachedDatabase.bookGroups;
  $BooksTable get books => attachedDatabase.books;
  $ReadingDaysTable get readingDays => attachedDatabase.readingDays;
  ReadingDaysDaoManager get managers => ReadingDaysDaoManager(this);
}

class ReadingDaysDaoManager {
  final _$ReadingDaysDaoMixin _db;
  ReadingDaysDaoManager(this._db);
  $$BookGroupsTableTableManager get bookGroups =>
      $$BookGroupsTableTableManager(_db.attachedDatabase, _db.bookGroups);
  $$BooksTableTableManager get books =>
      $$BooksTableTableManager(_db.attachedDatabase, _db.books);
  $$ReadingDaysTableTableManager get readingDays =>
      $$ReadingDaysTableTableManager(_db.attachedDatabase, _db.readingDays);
}
