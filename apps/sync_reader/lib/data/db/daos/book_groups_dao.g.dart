// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'book_groups_dao.dart';

// ignore_for_file: type=lint
mixin _$BookGroupsDaoMixin on DatabaseAccessor<AppDatabase> {
  $BookGroupsTable get bookGroups => attachedDatabase.bookGroups;
  $BooksTable get books => attachedDatabase.books;
  BookGroupsDaoManager get managers => BookGroupsDaoManager(this);
}

class BookGroupsDaoManager {
  final _$BookGroupsDaoMixin _db;
  BookGroupsDaoManager(this._db);
  $$BookGroupsTableTableManager get bookGroups =>
      $$BookGroupsTableTableManager(_db.attachedDatabase, _db.bookGroups);
  $$BooksTableTableManager get books =>
      $$BooksTableTableManager(_db.attachedDatabase, _db.books);
}
