// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'books_dao.dart';

// ignore_for_file: type=lint
mixin _$BooksDaoMixin on DatabaseAccessor<AppDatabase> {
  $BooksTable get books => attachedDatabase.books;
  $ProgressTable get progress => attachedDatabase.progress;
  $DeletedBooksTable get deletedBooks => attachedDatabase.deletedBooks;
  BooksDaoManager get managers => BooksDaoManager(this);
}

class BooksDaoManager {
  final _$BooksDaoMixin _db;
  BooksDaoManager(this._db);
  $$BooksTableTableManager get books =>
      $$BooksTableTableManager(_db.attachedDatabase, _db.books);
  $$ProgressTableTableManager get progress =>
      $$ProgressTableTableManager(_db.attachedDatabase, _db.progress);
  $$DeletedBooksTableTableManager get deletedBooks =>
      $$DeletedBooksTableTableManager(_db.attachedDatabase, _db.deletedBooks);
}
