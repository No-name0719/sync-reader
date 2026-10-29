// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $BookGroupsTable extends BookGroups
    with TableInfo<$BookGroupsTable, BookGroup> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BookGroupsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _groupIdMeta = const VerificationMeta(
    'groupId',
  );
  @override
  late final GeneratedColumn<String> groupId = GeneratedColumn<String>(
    'group_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [groupId, name, sortOrder, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'book_groups';
  @override
  VerificationContext validateIntegrity(
    Insertable<BookGroup> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('group_id')) {
      context.handle(
        _groupIdMeta,
        groupId.isAcceptableOrUnknown(data['group_id']!, _groupIdMeta),
      );
    } else if (isInserting) {
      context.missing(_groupIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {groupId};
  @override
  BookGroup map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BookGroup(
      groupId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}group_id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $BookGroupsTable createAlias(String alias) {
    return $BookGroupsTable(attachedDatabase, alias);
  }
}

class BookGroup extends DataClass implements Insertable<BookGroup> {
  /// ULID 主键（复用 lib/core/ulid.dart）。
  final String groupId;

  /// 分组名（非空；重名校验在 DAO/UI 层做）。
  final String name;

  /// 排序权重（按创建顺序递增）。
  final int sortOrder;

  /// 创建时间（epoch ms）。
  final int createdAt;
  const BookGroup({
    required this.groupId,
    required this.name,
    required this.sortOrder,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['group_id'] = Variable<String>(groupId);
    map['name'] = Variable<String>(name);
    map['sort_order'] = Variable<int>(sortOrder);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  BookGroupsCompanion toCompanion(bool nullToAbsent) {
    return BookGroupsCompanion(
      groupId: Value(groupId),
      name: Value(name),
      sortOrder: Value(sortOrder),
      createdAt: Value(createdAt),
    );
  }

  factory BookGroup.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BookGroup(
      groupId: serializer.fromJson<String>(json['groupId']),
      name: serializer.fromJson<String>(json['name']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'groupId': serializer.toJson<String>(groupId),
      'name': serializer.toJson<String>(name),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  BookGroup copyWith({
    String? groupId,
    String? name,
    int? sortOrder,
    int? createdAt,
  }) => BookGroup(
    groupId: groupId ?? this.groupId,
    name: name ?? this.name,
    sortOrder: sortOrder ?? this.sortOrder,
    createdAt: createdAt ?? this.createdAt,
  );
  BookGroup copyWithCompanion(BookGroupsCompanion data) {
    return BookGroup(
      groupId: data.groupId.present ? data.groupId.value : this.groupId,
      name: data.name.present ? data.name.value : this.name,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BookGroup(')
          ..write('groupId: $groupId, ')
          ..write('name: $name, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(groupId, name, sortOrder, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BookGroup &&
          other.groupId == this.groupId &&
          other.name == this.name &&
          other.sortOrder == this.sortOrder &&
          other.createdAt == this.createdAt);
}

class BookGroupsCompanion extends UpdateCompanion<BookGroup> {
  final Value<String> groupId;
  final Value<String> name;
  final Value<int> sortOrder;
  final Value<int> createdAt;
  final Value<int> rowid;
  const BookGroupsCompanion({
    this.groupId = const Value.absent(),
    this.name = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BookGroupsCompanion.insert({
    required String groupId,
    required String name,
    this.sortOrder = const Value.absent(),
    required int createdAt,
    this.rowid = const Value.absent(),
  }) : groupId = Value(groupId),
       name = Value(name),
       createdAt = Value(createdAt);
  static Insertable<BookGroup> custom({
    Expression<String>? groupId,
    Expression<String>? name,
    Expression<int>? sortOrder,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (groupId != null) 'group_id': groupId,
      if (name != null) 'name': name,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BookGroupsCompanion copyWith({
    Value<String>? groupId,
    Value<String>? name,
    Value<int>? sortOrder,
    Value<int>? createdAt,
    Value<int>? rowid,
  }) {
    return BookGroupsCompanion(
      groupId: groupId ?? this.groupId,
      name: name ?? this.name,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (groupId.present) {
      map['group_id'] = Variable<String>(groupId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BookGroupsCompanion(')
          ..write('groupId: $groupId, ')
          ..write('name: $name, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $BooksTable extends Books with TableInfo<$BooksTable, Book> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BooksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _bookIdMeta = const VerificationMeta('bookId');
  @override
  late final GeneratedColumn<String> bookId = GeneratedColumn<String>(
    'book_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _authorMeta = const VerificationMeta('author');
  @override
  late final GeneratedColumn<String> author = GeneratedColumn<String>(
    'author',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _formatMeta = const VerificationMeta('format');
  @override
  late final GeneratedColumn<String> format = GeneratedColumn<String>(
    'format',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fileNameMeta = const VerificationMeta(
    'fileName',
  );
  @override
  late final GeneratedColumn<String> fileName = GeneratedColumn<String>(
    'file_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _localPathMeta = const VerificationMeta(
    'localPath',
  );
  @override
  late final GeneratedColumn<String> localPath = GeneratedColumn<String>(
    'local_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _contentHashMeta = const VerificationMeta(
    'contentHash',
  );
  @override
  late final GeneratedColumn<String> contentHash = GeneratedColumn<String>(
    'content_hash',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sizeBytesMeta = const VerificationMeta(
    'sizeBytes',
  );
  @override
  late final GeneratedColumn<int> sizeBytes = GeneratedColumn<int>(
    'size_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _coverPathMeta = const VerificationMeta(
    'coverPath',
  );
  @override
  late final GeneratedColumn<String> coverPath = GeneratedColumn<String>(
    'cover_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _tocFingerprintMeta = const VerificationMeta(
    'tocFingerprint',
  );
  @override
  late final GeneratedColumn<String> tocFingerprint = GeneratedColumn<String>(
    'toc_fingerprint',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _addedAtMeta = const VerificationMeta(
    'addedAt',
  );
  @override
  late final GeneratedColumn<int> addedAt = GeneratedColumn<int>(
    'added_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastReadAtMeta = const VerificationMeta(
    'lastReadAt',
  );
  @override
  late final GeneratedColumn<int> lastReadAt = GeneratedColumn<int>(
    'last_read_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _totalSecondsMeta = const VerificationMeta(
    'totalSeconds',
  );
  @override
  late final GeneratedColumn<int> totalSeconds = GeneratedColumn<int>(
    'total_seconds',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _groupIdMeta = const VerificationMeta(
    'groupId',
  );
  @override
  late final GeneratedColumn<String> groupId = GeneratedColumn<String>(
    'group_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES book_groups (group_id) ON DELETE SET NULL',
    ),
  );
  @override
  List<GeneratedColumn> get $columns => [
    bookId,
    title,
    author,
    format,
    fileName,
    localPath,
    contentHash,
    sizeBytes,
    coverPath,
    tocFingerprint,
    addedAt,
    lastReadAt,
    totalSeconds,
    groupId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'books';
  @override
  VerificationContext validateIntegrity(
    Insertable<Book> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('book_id')) {
      context.handle(
        _bookIdMeta,
        bookId.isAcceptableOrUnknown(data['book_id']!, _bookIdMeta),
      );
    } else if (isInserting) {
      context.missing(_bookIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('author')) {
      context.handle(
        _authorMeta,
        author.isAcceptableOrUnknown(data['author']!, _authorMeta),
      );
    }
    if (data.containsKey('format')) {
      context.handle(
        _formatMeta,
        format.isAcceptableOrUnknown(data['format']!, _formatMeta),
      );
    } else if (isInserting) {
      context.missing(_formatMeta);
    }
    if (data.containsKey('file_name')) {
      context.handle(
        _fileNameMeta,
        fileName.isAcceptableOrUnknown(data['file_name']!, _fileNameMeta),
      );
    } else if (isInserting) {
      context.missing(_fileNameMeta);
    }
    if (data.containsKey('local_path')) {
      context.handle(
        _localPathMeta,
        localPath.isAcceptableOrUnknown(data['local_path']!, _localPathMeta),
      );
    }
    if (data.containsKey('content_hash')) {
      context.handle(
        _contentHashMeta,
        contentHash.isAcceptableOrUnknown(
          data['content_hash']!,
          _contentHashMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_contentHashMeta);
    }
    if (data.containsKey('size_bytes')) {
      context.handle(
        _sizeBytesMeta,
        sizeBytes.isAcceptableOrUnknown(data['size_bytes']!, _sizeBytesMeta),
      );
    } else if (isInserting) {
      context.missing(_sizeBytesMeta);
    }
    if (data.containsKey('cover_path')) {
      context.handle(
        _coverPathMeta,
        coverPath.isAcceptableOrUnknown(data['cover_path']!, _coverPathMeta),
      );
    }
    if (data.containsKey('toc_fingerprint')) {
      context.handle(
        _tocFingerprintMeta,
        tocFingerprint.isAcceptableOrUnknown(
          data['toc_fingerprint']!,
          _tocFingerprintMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_tocFingerprintMeta);
    }
    if (data.containsKey('added_at')) {
      context.handle(
        _addedAtMeta,
        addedAt.isAcceptableOrUnknown(data['added_at']!, _addedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_addedAtMeta);
    }
    if (data.containsKey('last_read_at')) {
      context.handle(
        _lastReadAtMeta,
        lastReadAt.isAcceptableOrUnknown(
          data['last_read_at']!,
          _lastReadAtMeta,
        ),
      );
    }
    if (data.containsKey('total_seconds')) {
      context.handle(
        _totalSecondsMeta,
        totalSeconds.isAcceptableOrUnknown(
          data['total_seconds']!,
          _totalSecondsMeta,
        ),
      );
    }
    if (data.containsKey('group_id')) {
      context.handle(
        _groupIdMeta,
        groupId.isAcceptableOrUnknown(data['group_id']!, _groupIdMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {bookId};
  @override
  Book map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Book(
      bookId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}book_id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      author: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}author'],
      )!,
      format: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}format'],
      )!,
      fileName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_name'],
      )!,
      localPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_path'],
      ),
      contentHash: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_hash'],
      )!,
      sizeBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size_bytes'],
      )!,
      coverPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cover_path'],
      ),
      tocFingerprint: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}toc_fingerprint'],
      )!,
      addedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}added_at'],
      )!,
      lastReadAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_read_at'],
      ),
      totalSeconds: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}total_seconds'],
      )!,
      groupId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}group_id'],
      ),
    );
  }

  @override
  $BooksTable createAlias(String alias) {
    return $BooksTable(attachedDatabase, alias);
  }
}

class Book extends DataClass implements Insertable<Book> {
  /// ULID 主键（docs/05 §4.1）。
  final String bookId;

  /// 书名（epub 取 OPF dc:title，否则文件名去扩展名）。
  final String title;

  /// 作者，可为空串。
  final String author;

  /// 格式：txt | epub | md | pdf（自由字符串，docs/05 §3.2）。
  final String format;

  /// 原始文件名（恢复导出用）。
  final String fileName;

  /// 本地正文路径；NULL = 占位书（云端有、本地无）。
  final String? localPath;

  /// 正文全量哈希，`sha256:<hex>`（去重与完整性核心）。
  final String contentHash;

  /// 正文字节数。
  final int sizeBytes;

  /// 本地封面路径（可空；封面不上云，各端自行生成）。
  final String? coverPath;

  /// 目录指纹 `tfp:<16hex>`（解析结果不一致时进度降级用）。
  final String tocFingerprint;

  /// 入库时间（epoch ms，"添加时间"排序依据）。
  final int addedAt;

  /// 最近阅读时间（epoch ms；从未阅读为 NULL；NULL 在 DESC 排序中排最后）。
  final int? lastReadAt;

  /// 累计阅读秒数（冲突时求和合并，docs/04 §6.3）。
  final int totalSeconds;

  /// 所属分组（FR-107 本地列，不参与同步、不入云端 meta）；NULL = 未分组。
  /// 分组删除时由外键置回未分组。
  final String? groupId;
  const Book({
    required this.bookId,
    required this.title,
    required this.author,
    required this.format,
    required this.fileName,
    this.localPath,
    required this.contentHash,
    required this.sizeBytes,
    this.coverPath,
    required this.tocFingerprint,
    required this.addedAt,
    this.lastReadAt,
    required this.totalSeconds,
    this.groupId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['book_id'] = Variable<String>(bookId);
    map['title'] = Variable<String>(title);
    map['author'] = Variable<String>(author);
    map['format'] = Variable<String>(format);
    map['file_name'] = Variable<String>(fileName);
    if (!nullToAbsent || localPath != null) {
      map['local_path'] = Variable<String>(localPath);
    }
    map['content_hash'] = Variable<String>(contentHash);
    map['size_bytes'] = Variable<int>(sizeBytes);
    if (!nullToAbsent || coverPath != null) {
      map['cover_path'] = Variable<String>(coverPath);
    }
    map['toc_fingerprint'] = Variable<String>(tocFingerprint);
    map['added_at'] = Variable<int>(addedAt);
    if (!nullToAbsent || lastReadAt != null) {
      map['last_read_at'] = Variable<int>(lastReadAt);
    }
    map['total_seconds'] = Variable<int>(totalSeconds);
    if (!nullToAbsent || groupId != null) {
      map['group_id'] = Variable<String>(groupId);
    }
    return map;
  }

  BooksCompanion toCompanion(bool nullToAbsent) {
    return BooksCompanion(
      bookId: Value(bookId),
      title: Value(title),
      author: Value(author),
      format: Value(format),
      fileName: Value(fileName),
      localPath: localPath == null && nullToAbsent
          ? const Value.absent()
          : Value(localPath),
      contentHash: Value(contentHash),
      sizeBytes: Value(sizeBytes),
      coverPath: coverPath == null && nullToAbsent
          ? const Value.absent()
          : Value(coverPath),
      tocFingerprint: Value(tocFingerprint),
      addedAt: Value(addedAt),
      lastReadAt: lastReadAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastReadAt),
      totalSeconds: Value(totalSeconds),
      groupId: groupId == null && nullToAbsent
          ? const Value.absent()
          : Value(groupId),
    );
  }

  factory Book.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Book(
      bookId: serializer.fromJson<String>(json['bookId']),
      title: serializer.fromJson<String>(json['title']),
      author: serializer.fromJson<String>(json['author']),
      format: serializer.fromJson<String>(json['format']),
      fileName: serializer.fromJson<String>(json['fileName']),
      localPath: serializer.fromJson<String?>(json['localPath']),
      contentHash: serializer.fromJson<String>(json['contentHash']),
      sizeBytes: serializer.fromJson<int>(json['sizeBytes']),
      coverPath: serializer.fromJson<String?>(json['coverPath']),
      tocFingerprint: serializer.fromJson<String>(json['tocFingerprint']),
      addedAt: serializer.fromJson<int>(json['addedAt']),
      lastReadAt: serializer.fromJson<int?>(json['lastReadAt']),
      totalSeconds: serializer.fromJson<int>(json['totalSeconds']),
      groupId: serializer.fromJson<String?>(json['groupId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'bookId': serializer.toJson<String>(bookId),
      'title': serializer.toJson<String>(title),
      'author': serializer.toJson<String>(author),
      'format': serializer.toJson<String>(format),
      'fileName': serializer.toJson<String>(fileName),
      'localPath': serializer.toJson<String?>(localPath),
      'contentHash': serializer.toJson<String>(contentHash),
      'sizeBytes': serializer.toJson<int>(sizeBytes),
      'coverPath': serializer.toJson<String?>(coverPath),
      'tocFingerprint': serializer.toJson<String>(tocFingerprint),
      'addedAt': serializer.toJson<int>(addedAt),
      'lastReadAt': serializer.toJson<int?>(lastReadAt),
      'totalSeconds': serializer.toJson<int>(totalSeconds),
      'groupId': serializer.toJson<String?>(groupId),
    };
  }

  Book copyWith({
    String? bookId,
    String? title,
    String? author,
    String? format,
    String? fileName,
    Value<String?> localPath = const Value.absent(),
    String? contentHash,
    int? sizeBytes,
    Value<String?> coverPath = const Value.absent(),
    String? tocFingerprint,
    int? addedAt,
    Value<int?> lastReadAt = const Value.absent(),
    int? totalSeconds,
    Value<String?> groupId = const Value.absent(),
  }) => Book(
    bookId: bookId ?? this.bookId,
    title: title ?? this.title,
    author: author ?? this.author,
    format: format ?? this.format,
    fileName: fileName ?? this.fileName,
    localPath: localPath.present ? localPath.value : this.localPath,
    contentHash: contentHash ?? this.contentHash,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    coverPath: coverPath.present ? coverPath.value : this.coverPath,
    tocFingerprint: tocFingerprint ?? this.tocFingerprint,
    addedAt: addedAt ?? this.addedAt,
    lastReadAt: lastReadAt.present ? lastReadAt.value : this.lastReadAt,
    totalSeconds: totalSeconds ?? this.totalSeconds,
    groupId: groupId.present ? groupId.value : this.groupId,
  );
  Book copyWithCompanion(BooksCompanion data) {
    return Book(
      bookId: data.bookId.present ? data.bookId.value : this.bookId,
      title: data.title.present ? data.title.value : this.title,
      author: data.author.present ? data.author.value : this.author,
      format: data.format.present ? data.format.value : this.format,
      fileName: data.fileName.present ? data.fileName.value : this.fileName,
      localPath: data.localPath.present ? data.localPath.value : this.localPath,
      contentHash: data.contentHash.present
          ? data.contentHash.value
          : this.contentHash,
      sizeBytes: data.sizeBytes.present ? data.sizeBytes.value : this.sizeBytes,
      coverPath: data.coverPath.present ? data.coverPath.value : this.coverPath,
      tocFingerprint: data.tocFingerprint.present
          ? data.tocFingerprint.value
          : this.tocFingerprint,
      addedAt: data.addedAt.present ? data.addedAt.value : this.addedAt,
      lastReadAt: data.lastReadAt.present
          ? data.lastReadAt.value
          : this.lastReadAt,
      totalSeconds: data.totalSeconds.present
          ? data.totalSeconds.value
          : this.totalSeconds,
      groupId: data.groupId.present ? data.groupId.value : this.groupId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Book(')
          ..write('bookId: $bookId, ')
          ..write('title: $title, ')
          ..write('author: $author, ')
          ..write('format: $format, ')
          ..write('fileName: $fileName, ')
          ..write('localPath: $localPath, ')
          ..write('contentHash: $contentHash, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('coverPath: $coverPath, ')
          ..write('tocFingerprint: $tocFingerprint, ')
          ..write('addedAt: $addedAt, ')
          ..write('lastReadAt: $lastReadAt, ')
          ..write('totalSeconds: $totalSeconds, ')
          ..write('groupId: $groupId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    bookId,
    title,
    author,
    format,
    fileName,
    localPath,
    contentHash,
    sizeBytes,
    coverPath,
    tocFingerprint,
    addedAt,
    lastReadAt,
    totalSeconds,
    groupId,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Book &&
          other.bookId == this.bookId &&
          other.title == this.title &&
          other.author == this.author &&
          other.format == this.format &&
          other.fileName == this.fileName &&
          other.localPath == this.localPath &&
          other.contentHash == this.contentHash &&
          other.sizeBytes == this.sizeBytes &&
          other.coverPath == this.coverPath &&
          other.tocFingerprint == this.tocFingerprint &&
          other.addedAt == this.addedAt &&
          other.lastReadAt == this.lastReadAt &&
          other.totalSeconds == this.totalSeconds &&
          other.groupId == this.groupId);
}

class BooksCompanion extends UpdateCompanion<Book> {
  final Value<String> bookId;
  final Value<String> title;
  final Value<String> author;
  final Value<String> format;
  final Value<String> fileName;
  final Value<String?> localPath;
  final Value<String> contentHash;
  final Value<int> sizeBytes;
  final Value<String?> coverPath;
  final Value<String> tocFingerprint;
  final Value<int> addedAt;
  final Value<int?> lastReadAt;
  final Value<int> totalSeconds;
  final Value<String?> groupId;
  final Value<int> rowid;
  const BooksCompanion({
    this.bookId = const Value.absent(),
    this.title = const Value.absent(),
    this.author = const Value.absent(),
    this.format = const Value.absent(),
    this.fileName = const Value.absent(),
    this.localPath = const Value.absent(),
    this.contentHash = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.coverPath = const Value.absent(),
    this.tocFingerprint = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.lastReadAt = const Value.absent(),
    this.totalSeconds = const Value.absent(),
    this.groupId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BooksCompanion.insert({
    required String bookId,
    required String title,
    this.author = const Value.absent(),
    required String format,
    required String fileName,
    this.localPath = const Value.absent(),
    required String contentHash,
    required int sizeBytes,
    this.coverPath = const Value.absent(),
    required String tocFingerprint,
    required int addedAt,
    this.lastReadAt = const Value.absent(),
    this.totalSeconds = const Value.absent(),
    this.groupId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : bookId = Value(bookId),
       title = Value(title),
       format = Value(format),
       fileName = Value(fileName),
       contentHash = Value(contentHash),
       sizeBytes = Value(sizeBytes),
       tocFingerprint = Value(tocFingerprint),
       addedAt = Value(addedAt);
  static Insertable<Book> custom({
    Expression<String>? bookId,
    Expression<String>? title,
    Expression<String>? author,
    Expression<String>? format,
    Expression<String>? fileName,
    Expression<String>? localPath,
    Expression<String>? contentHash,
    Expression<int>? sizeBytes,
    Expression<String>? coverPath,
    Expression<String>? tocFingerprint,
    Expression<int>? addedAt,
    Expression<int>? lastReadAt,
    Expression<int>? totalSeconds,
    Expression<String>? groupId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (bookId != null) 'book_id': bookId,
      if (title != null) 'title': title,
      if (author != null) 'author': author,
      if (format != null) 'format': format,
      if (fileName != null) 'file_name': fileName,
      if (localPath != null) 'local_path': localPath,
      if (contentHash != null) 'content_hash': contentHash,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      if (coverPath != null) 'cover_path': coverPath,
      if (tocFingerprint != null) 'toc_fingerprint': tocFingerprint,
      if (addedAt != null) 'added_at': addedAt,
      if (lastReadAt != null) 'last_read_at': lastReadAt,
      if (totalSeconds != null) 'total_seconds': totalSeconds,
      if (groupId != null) 'group_id': groupId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BooksCompanion copyWith({
    Value<String>? bookId,
    Value<String>? title,
    Value<String>? author,
    Value<String>? format,
    Value<String>? fileName,
    Value<String?>? localPath,
    Value<String>? contentHash,
    Value<int>? sizeBytes,
    Value<String?>? coverPath,
    Value<String>? tocFingerprint,
    Value<int>? addedAt,
    Value<int?>? lastReadAt,
    Value<int>? totalSeconds,
    Value<String?>? groupId,
    Value<int>? rowid,
  }) {
    return BooksCompanion(
      bookId: bookId ?? this.bookId,
      title: title ?? this.title,
      author: author ?? this.author,
      format: format ?? this.format,
      fileName: fileName ?? this.fileName,
      localPath: localPath ?? this.localPath,
      contentHash: contentHash ?? this.contentHash,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      coverPath: coverPath ?? this.coverPath,
      tocFingerprint: tocFingerprint ?? this.tocFingerprint,
      addedAt: addedAt ?? this.addedAt,
      lastReadAt: lastReadAt ?? this.lastReadAt,
      totalSeconds: totalSeconds ?? this.totalSeconds,
      groupId: groupId ?? this.groupId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (bookId.present) {
      map['book_id'] = Variable<String>(bookId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (author.present) {
      map['author'] = Variable<String>(author.value);
    }
    if (format.present) {
      map['format'] = Variable<String>(format.value);
    }
    if (fileName.present) {
      map['file_name'] = Variable<String>(fileName.value);
    }
    if (localPath.present) {
      map['local_path'] = Variable<String>(localPath.value);
    }
    if (contentHash.present) {
      map['content_hash'] = Variable<String>(contentHash.value);
    }
    if (sizeBytes.present) {
      map['size_bytes'] = Variable<int>(sizeBytes.value);
    }
    if (coverPath.present) {
      map['cover_path'] = Variable<String>(coverPath.value);
    }
    if (tocFingerprint.present) {
      map['toc_fingerprint'] = Variable<String>(tocFingerprint.value);
    }
    if (addedAt.present) {
      map['added_at'] = Variable<int>(addedAt.value);
    }
    if (lastReadAt.present) {
      map['last_read_at'] = Variable<int>(lastReadAt.value);
    }
    if (totalSeconds.present) {
      map['total_seconds'] = Variable<int>(totalSeconds.value);
    }
    if (groupId.present) {
      map['group_id'] = Variable<String>(groupId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BooksCompanion(')
          ..write('bookId: $bookId, ')
          ..write('title: $title, ')
          ..write('author: $author, ')
          ..write('format: $format, ')
          ..write('fileName: $fileName, ')
          ..write('localPath: $localPath, ')
          ..write('contentHash: $contentHash, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('coverPath: $coverPath, ')
          ..write('tocFingerprint: $tocFingerprint, ')
          ..write('addedAt: $addedAt, ')
          ..write('lastReadAt: $lastReadAt, ')
          ..write('totalSeconds: $totalSeconds, ')
          ..write('groupId: $groupId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ProgressTable extends Progress
    with TableInfo<$ProgressTable, BookProgress> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProgressTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _bookIdMeta = const VerificationMeta('bookId');
  @override
  late final GeneratedColumn<String> bookId = GeneratedColumn<String>(
    'book_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES books (book_id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _locatorJsonMeta = const VerificationMeta(
    'locatorJson',
  );
  @override
  late final GeneratedColumn<String> locatorJson = GeneratedColumn<String>(
    'locator_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _percentMeta = const VerificationMeta(
    'percent',
  );
  @override
  late final GeneratedColumn<double> percent = GeneratedColumn<double>(
    'percent',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dirtyMeta = const VerificationMeta('dirty');
  @override
  late final GeneratedColumn<bool> dirty = GeneratedColumn<bool>(
    'dirty',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("dirty" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    bookId,
    locatorJson,
    percent,
    updatedAt,
    dirty,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'progress';
  @override
  VerificationContext validateIntegrity(
    Insertable<BookProgress> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('book_id')) {
      context.handle(
        _bookIdMeta,
        bookId.isAcceptableOrUnknown(data['book_id']!, _bookIdMeta),
      );
    } else if (isInserting) {
      context.missing(_bookIdMeta);
    }
    if (data.containsKey('locator_json')) {
      context.handle(
        _locatorJsonMeta,
        locatorJson.isAcceptableOrUnknown(
          data['locator_json']!,
          _locatorJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_locatorJsonMeta);
    }
    if (data.containsKey('percent')) {
      context.handle(
        _percentMeta,
        percent.isAcceptableOrUnknown(data['percent']!, _percentMeta),
      );
    } else if (isInserting) {
      context.missing(_percentMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('dirty')) {
      context.handle(
        _dirtyMeta,
        dirty.isAcceptableOrUnknown(data['dirty']!, _dirtyMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {bookId};
  @override
  BookProgress map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BookProgress(
      bookId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}book_id'],
      )!,
      locatorJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}locator_json'],
      )!,
      percent: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}percent'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      dirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}dirty'],
      )!,
    );
  }

  @override
  $ProgressTable createAlias(String alias) {
    return $ProgressTable(attachedDatabase, alias);
  }
}

class BookProgress extends DataClass implements Insertable<BookProgress> {
  /// 所属书籍（级联删除）。
  final String bookId;

  /// docs/05 §3.3 判别联合 JSON 原样存储（逻辑坐标，禁止物理页码）。
  final String locatorJson;

  /// 全书阅读比例 0.0–1.0（跨格式统一展示 + 降级恢复用）。
  final double percent;

  /// 最近进度更新时间（epoch ms）。
  final int updatedAt;

  /// 1 = 待上传（同步队列的脏标记）。
  final bool dirty;
  const BookProgress({
    required this.bookId,
    required this.locatorJson,
    required this.percent,
    required this.updatedAt,
    required this.dirty,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['book_id'] = Variable<String>(bookId);
    map['locator_json'] = Variable<String>(locatorJson);
    map['percent'] = Variable<double>(percent);
    map['updated_at'] = Variable<int>(updatedAt);
    map['dirty'] = Variable<bool>(dirty);
    return map;
  }

  ProgressCompanion toCompanion(bool nullToAbsent) {
    return ProgressCompanion(
      bookId: Value(bookId),
      locatorJson: Value(locatorJson),
      percent: Value(percent),
      updatedAt: Value(updatedAt),
      dirty: Value(dirty),
    );
  }

  factory BookProgress.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BookProgress(
      bookId: serializer.fromJson<String>(json['bookId']),
      locatorJson: serializer.fromJson<String>(json['locatorJson']),
      percent: serializer.fromJson<double>(json['percent']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      dirty: serializer.fromJson<bool>(json['dirty']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'bookId': serializer.toJson<String>(bookId),
      'locatorJson': serializer.toJson<String>(locatorJson),
      'percent': serializer.toJson<double>(percent),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'dirty': serializer.toJson<bool>(dirty),
    };
  }

  BookProgress copyWith({
    String? bookId,
    String? locatorJson,
    double? percent,
    int? updatedAt,
    bool? dirty,
  }) => BookProgress(
    bookId: bookId ?? this.bookId,
    locatorJson: locatorJson ?? this.locatorJson,
    percent: percent ?? this.percent,
    updatedAt: updatedAt ?? this.updatedAt,
    dirty: dirty ?? this.dirty,
  );
  BookProgress copyWithCompanion(ProgressCompanion data) {
    return BookProgress(
      bookId: data.bookId.present ? data.bookId.value : this.bookId,
      locatorJson: data.locatorJson.present
          ? data.locatorJson.value
          : this.locatorJson,
      percent: data.percent.present ? data.percent.value : this.percent,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      dirty: data.dirty.present ? data.dirty.value : this.dirty,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BookProgress(')
          ..write('bookId: $bookId, ')
          ..write('locatorJson: $locatorJson, ')
          ..write('percent: $percent, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('dirty: $dirty')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(bookId, locatorJson, percent, updatedAt, dirty);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BookProgress &&
          other.bookId == this.bookId &&
          other.locatorJson == this.locatorJson &&
          other.percent == this.percent &&
          other.updatedAt == this.updatedAt &&
          other.dirty == this.dirty);
}

class ProgressCompanion extends UpdateCompanion<BookProgress> {
  final Value<String> bookId;
  final Value<String> locatorJson;
  final Value<double> percent;
  final Value<int> updatedAt;
  final Value<bool> dirty;
  final Value<int> rowid;
  const ProgressCompanion({
    this.bookId = const Value.absent(),
    this.locatorJson = const Value.absent(),
    this.percent = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.dirty = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ProgressCompanion.insert({
    required String bookId,
    required String locatorJson,
    required double percent,
    required int updatedAt,
    this.dirty = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : bookId = Value(bookId),
       locatorJson = Value(locatorJson),
       percent = Value(percent),
       updatedAt = Value(updatedAt);
  static Insertable<BookProgress> custom({
    Expression<String>? bookId,
    Expression<String>? locatorJson,
    Expression<double>? percent,
    Expression<int>? updatedAt,
    Expression<bool>? dirty,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (bookId != null) 'book_id': bookId,
      if (locatorJson != null) 'locator_json': locatorJson,
      if (percent != null) 'percent': percent,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (dirty != null) 'dirty': dirty,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ProgressCompanion copyWith({
    Value<String>? bookId,
    Value<String>? locatorJson,
    Value<double>? percent,
    Value<int>? updatedAt,
    Value<bool>? dirty,
    Value<int>? rowid,
  }) {
    return ProgressCompanion(
      bookId: bookId ?? this.bookId,
      locatorJson: locatorJson ?? this.locatorJson,
      percent: percent ?? this.percent,
      updatedAt: updatedAt ?? this.updatedAt,
      dirty: dirty ?? this.dirty,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (bookId.present) {
      map['book_id'] = Variable<String>(bookId.value);
    }
    if (locatorJson.present) {
      map['locator_json'] = Variable<String>(locatorJson.value);
    }
    if (percent.present) {
      map['percent'] = Variable<double>(percent.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (dirty.present) {
      map['dirty'] = Variable<bool>(dirty.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProgressCompanion(')
          ..write('bookId: $bookId, ')
          ..write('locatorJson: $locatorJson, ')
          ..write('percent: $percent, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('dirty: $dirty, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncStateTable extends SyncState
    with TableInfo<$SyncStateTable, BookSyncState> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncStateTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _bookIdMeta = const VerificationMeta('bookId');
  @override
  late final GeneratedColumn<String> bookId = GeneratedColumn<String>(
    'book_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _backendKeyMeta = const VerificationMeta(
    'backendKey',
  );
  @override
  late final GeneratedColumn<String> backendKey = GeneratedColumn<String>(
    'backend_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _baseRevMeta = const VerificationMeta(
    'baseRev',
  );
  @override
  late final GeneratedColumn<int> baseRev = GeneratedColumn<int>(
    'base_rev',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remoteEtagMeta = const VerificationMeta(
    'remoteEtag',
  );
  @override
  late final GeneratedColumn<String> remoteEtag = GeneratedColumn<String>(
    'remote_etag',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastSyncedMetaJsonMeta =
      const VerificationMeta('lastSyncedMetaJson');
  @override
  late final GeneratedColumn<String> lastSyncedMetaJson =
      GeneratedColumn<String>(
        'last_synced_meta_json',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _lastSyncedAtMeta = const VerificationMeta(
    'lastSyncedAt',
  );
  @override
  late final GeneratedColumn<int> lastSyncedAt = GeneratedColumn<int>(
    'last_synced_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    bookId,
    backendKey,
    baseRev,
    remoteEtag,
    lastSyncedMetaJson,
    lastSyncedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_state';
  @override
  VerificationContext validateIntegrity(
    Insertable<BookSyncState> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('book_id')) {
      context.handle(
        _bookIdMeta,
        bookId.isAcceptableOrUnknown(data['book_id']!, _bookIdMeta),
      );
    } else if (isInserting) {
      context.missing(_bookIdMeta);
    }
    if (data.containsKey('backend_key')) {
      context.handle(
        _backendKeyMeta,
        backendKey.isAcceptableOrUnknown(data['backend_key']!, _backendKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_backendKeyMeta);
    }
    if (data.containsKey('base_rev')) {
      context.handle(
        _baseRevMeta,
        baseRev.isAcceptableOrUnknown(data['base_rev']!, _baseRevMeta),
      );
    } else if (isInserting) {
      context.missing(_baseRevMeta);
    }
    if (data.containsKey('remote_etag')) {
      context.handle(
        _remoteEtagMeta,
        remoteEtag.isAcceptableOrUnknown(data['remote_etag']!, _remoteEtagMeta),
      );
    }
    if (data.containsKey('last_synced_meta_json')) {
      context.handle(
        _lastSyncedMetaJsonMeta,
        lastSyncedMetaJson.isAcceptableOrUnknown(
          data['last_synced_meta_json']!,
          _lastSyncedMetaJsonMeta,
        ),
      );
    }
    if (data.containsKey('last_synced_at')) {
      context.handle(
        _lastSyncedAtMeta,
        lastSyncedAt.isAcceptableOrUnknown(
          data['last_synced_at']!,
          _lastSyncedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lastSyncedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {bookId, backendKey};
  @override
  BookSyncState map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BookSyncState(
      bookId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}book_id'],
      )!,
      backendKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}backend_key'],
      )!,
      baseRev: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}base_rev'],
      )!,
      remoteEtag: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_etag'],
      ),
      lastSyncedMetaJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_synced_meta_json'],
      ),
      lastSyncedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_synced_at'],
      )!,
    );
  }

  @override
  $SyncStateTable createAlias(String alias) {
    return $SyncStateTable(attachedDatabase, alias);
  }
}

class BookSyncState extends DataClass implements Insertable<BookSyncState> {
  final String bookId;

  /// 'webdav' | 'server:{libraryId}'（docs/05 §5 注释）。
  final String backendKey;

  /// 已确认的远端 rev（乐观锁基线）。
  final int baseRev;

  /// WebDAV 条件请求用的 ETag。
  final String? remoteEtag;

  /// 上次同步的 meta 副本 = 冲突合并的公共祖先（docs/04 §6.3）。
  final String? lastSyncedMetaJson;

  /// 上次同步时间（epoch ms）。
  final int lastSyncedAt;
  const BookSyncState({
    required this.bookId,
    required this.backendKey,
    required this.baseRev,
    this.remoteEtag,
    this.lastSyncedMetaJson,
    required this.lastSyncedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['book_id'] = Variable<String>(bookId);
    map['backend_key'] = Variable<String>(backendKey);
    map['base_rev'] = Variable<int>(baseRev);
    if (!nullToAbsent || remoteEtag != null) {
      map['remote_etag'] = Variable<String>(remoteEtag);
    }
    if (!nullToAbsent || lastSyncedMetaJson != null) {
      map['last_synced_meta_json'] = Variable<String>(lastSyncedMetaJson);
    }
    map['last_synced_at'] = Variable<int>(lastSyncedAt);
    return map;
  }

  SyncStateCompanion toCompanion(bool nullToAbsent) {
    return SyncStateCompanion(
      bookId: Value(bookId),
      backendKey: Value(backendKey),
      baseRev: Value(baseRev),
      remoteEtag: remoteEtag == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteEtag),
      lastSyncedMetaJson: lastSyncedMetaJson == null && nullToAbsent
          ? const Value.absent()
          : Value(lastSyncedMetaJson),
      lastSyncedAt: Value(lastSyncedAt),
    );
  }

  factory BookSyncState.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BookSyncState(
      bookId: serializer.fromJson<String>(json['bookId']),
      backendKey: serializer.fromJson<String>(json['backendKey']),
      baseRev: serializer.fromJson<int>(json['baseRev']),
      remoteEtag: serializer.fromJson<String?>(json['remoteEtag']),
      lastSyncedMetaJson: serializer.fromJson<String?>(
        json['lastSyncedMetaJson'],
      ),
      lastSyncedAt: serializer.fromJson<int>(json['lastSyncedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'bookId': serializer.toJson<String>(bookId),
      'backendKey': serializer.toJson<String>(backendKey),
      'baseRev': serializer.toJson<int>(baseRev),
      'remoteEtag': serializer.toJson<String?>(remoteEtag),
      'lastSyncedMetaJson': serializer.toJson<String?>(lastSyncedMetaJson),
      'lastSyncedAt': serializer.toJson<int>(lastSyncedAt),
    };
  }

  BookSyncState copyWith({
    String? bookId,
    String? backendKey,
    int? baseRev,
    Value<String?> remoteEtag = const Value.absent(),
    Value<String?> lastSyncedMetaJson = const Value.absent(),
    int? lastSyncedAt,
  }) => BookSyncState(
    bookId: bookId ?? this.bookId,
    backendKey: backendKey ?? this.backendKey,
    baseRev: baseRev ?? this.baseRev,
    remoteEtag: remoteEtag.present ? remoteEtag.value : this.remoteEtag,
    lastSyncedMetaJson: lastSyncedMetaJson.present
        ? lastSyncedMetaJson.value
        : this.lastSyncedMetaJson,
    lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
  );
  BookSyncState copyWithCompanion(SyncStateCompanion data) {
    return BookSyncState(
      bookId: data.bookId.present ? data.bookId.value : this.bookId,
      backendKey: data.backendKey.present
          ? data.backendKey.value
          : this.backendKey,
      baseRev: data.baseRev.present ? data.baseRev.value : this.baseRev,
      remoteEtag: data.remoteEtag.present
          ? data.remoteEtag.value
          : this.remoteEtag,
      lastSyncedMetaJson: data.lastSyncedMetaJson.present
          ? data.lastSyncedMetaJson.value
          : this.lastSyncedMetaJson,
      lastSyncedAt: data.lastSyncedAt.present
          ? data.lastSyncedAt.value
          : this.lastSyncedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BookSyncState(')
          ..write('bookId: $bookId, ')
          ..write('backendKey: $backendKey, ')
          ..write('baseRev: $baseRev, ')
          ..write('remoteEtag: $remoteEtag, ')
          ..write('lastSyncedMetaJson: $lastSyncedMetaJson, ')
          ..write('lastSyncedAt: $lastSyncedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    bookId,
    backendKey,
    baseRev,
    remoteEtag,
    lastSyncedMetaJson,
    lastSyncedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BookSyncState &&
          other.bookId == this.bookId &&
          other.backendKey == this.backendKey &&
          other.baseRev == this.baseRev &&
          other.remoteEtag == this.remoteEtag &&
          other.lastSyncedMetaJson == this.lastSyncedMetaJson &&
          other.lastSyncedAt == this.lastSyncedAt);
}

class SyncStateCompanion extends UpdateCompanion<BookSyncState> {
  final Value<String> bookId;
  final Value<String> backendKey;
  final Value<int> baseRev;
  final Value<String?> remoteEtag;
  final Value<String?> lastSyncedMetaJson;
  final Value<int> lastSyncedAt;
  final Value<int> rowid;
  const SyncStateCompanion({
    this.bookId = const Value.absent(),
    this.backendKey = const Value.absent(),
    this.baseRev = const Value.absent(),
    this.remoteEtag = const Value.absent(),
    this.lastSyncedMetaJson = const Value.absent(),
    this.lastSyncedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncStateCompanion.insert({
    required String bookId,
    required String backendKey,
    required int baseRev,
    this.remoteEtag = const Value.absent(),
    this.lastSyncedMetaJson = const Value.absent(),
    required int lastSyncedAt,
    this.rowid = const Value.absent(),
  }) : bookId = Value(bookId),
       backendKey = Value(backendKey),
       baseRev = Value(baseRev),
       lastSyncedAt = Value(lastSyncedAt);
  static Insertable<BookSyncState> custom({
    Expression<String>? bookId,
    Expression<String>? backendKey,
    Expression<int>? baseRev,
    Expression<String>? remoteEtag,
    Expression<String>? lastSyncedMetaJson,
    Expression<int>? lastSyncedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (bookId != null) 'book_id': bookId,
      if (backendKey != null) 'backend_key': backendKey,
      if (baseRev != null) 'base_rev': baseRev,
      if (remoteEtag != null) 'remote_etag': remoteEtag,
      if (lastSyncedMetaJson != null)
        'last_synced_meta_json': lastSyncedMetaJson,
      if (lastSyncedAt != null) 'last_synced_at': lastSyncedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncStateCompanion copyWith({
    Value<String>? bookId,
    Value<String>? backendKey,
    Value<int>? baseRev,
    Value<String?>? remoteEtag,
    Value<String?>? lastSyncedMetaJson,
    Value<int>? lastSyncedAt,
    Value<int>? rowid,
  }) {
    return SyncStateCompanion(
      bookId: bookId ?? this.bookId,
      backendKey: backendKey ?? this.backendKey,
      baseRev: baseRev ?? this.baseRev,
      remoteEtag: remoteEtag ?? this.remoteEtag,
      lastSyncedMetaJson: lastSyncedMetaJson ?? this.lastSyncedMetaJson,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (bookId.present) {
      map['book_id'] = Variable<String>(bookId.value);
    }
    if (backendKey.present) {
      map['backend_key'] = Variable<String>(backendKey.value);
    }
    if (baseRev.present) {
      map['base_rev'] = Variable<int>(baseRev.value);
    }
    if (remoteEtag.present) {
      map['remote_etag'] = Variable<String>(remoteEtag.value);
    }
    if (lastSyncedMetaJson.present) {
      map['last_synced_meta_json'] = Variable<String>(lastSyncedMetaJson.value);
    }
    if (lastSyncedAt.present) {
      map['last_synced_at'] = Variable<int>(lastSyncedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncStateCompanion(')
          ..write('bookId: $bookId, ')
          ..write('backendKey: $backendKey, ')
          ..write('baseRev: $baseRev, ')
          ..write('remoteEtag: $remoteEtag, ')
          ..write('lastSyncedMetaJson: $lastSyncedMetaJson, ')
          ..write('lastSyncedAt: $lastSyncedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DeletedBooksTable extends DeletedBooks
    with TableInfo<$DeletedBooksTable, DeletedBook> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DeletedBooksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _bookIdMeta = const VerificationMeta('bookId');
  @override
  late final GeneratedColumn<String> bookId = GeneratedColumn<String>(
    'book_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
    'deleted_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pushedMeta = const VerificationMeta('pushed');
  @override
  late final GeneratedColumn<bool> pushed = GeneratedColumn<bool>(
    'pushed',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("pushed" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _contentHashMeta = const VerificationMeta(
    'contentHash',
  );
  @override
  late final GeneratedColumn<String> contentHash = GeneratedColumn<String>(
    'content_hash',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    bookId,
    deletedAt,
    pushed,
    contentHash,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'deleted_books';
  @override
  VerificationContext validateIntegrity(
    Insertable<DeletedBook> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('book_id')) {
      context.handle(
        _bookIdMeta,
        bookId.isAcceptableOrUnknown(data['book_id']!, _bookIdMeta),
      );
    } else if (isInserting) {
      context.missing(_bookIdMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_deletedAtMeta);
    }
    if (data.containsKey('pushed')) {
      context.handle(
        _pushedMeta,
        pushed.isAcceptableOrUnknown(data['pushed']!, _pushedMeta),
      );
    }
    if (data.containsKey('content_hash')) {
      context.handle(
        _contentHashMeta,
        contentHash.isAcceptableOrUnknown(
          data['content_hash']!,
          _contentHashMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_contentHashMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {bookId};
  @override
  DeletedBook map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DeletedBook(
      bookId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}book_id'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deleted_at'],
      )!,
      pushed: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}pushed'],
      )!,
      contentHash: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_hash'],
      )!,
    );
  }

  @override
  $DeletedBooksTable createAlias(String alias) {
    return $DeletedBooksTable(attachedDatabase, alias);
  }
}

class DeletedBook extends DataClass implements Insertable<DeletedBook> {
  final String bookId;

  /// 删除时间（epoch ms，GC 依据：90 天）。
  final int deletedAt;

  /// tombstone 是否已上云。
  final bool pushed;

  /// 游离文件重关联时比对哈希用。
  final String contentHash;
  const DeletedBook({
    required this.bookId,
    required this.deletedAt,
    required this.pushed,
    required this.contentHash,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['book_id'] = Variable<String>(bookId);
    map['deleted_at'] = Variable<int>(deletedAt);
    map['pushed'] = Variable<bool>(pushed);
    map['content_hash'] = Variable<String>(contentHash);
    return map;
  }

  DeletedBooksCompanion toCompanion(bool nullToAbsent) {
    return DeletedBooksCompanion(
      bookId: Value(bookId),
      deletedAt: Value(deletedAt),
      pushed: Value(pushed),
      contentHash: Value(contentHash),
    );
  }

  factory DeletedBook.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DeletedBook(
      bookId: serializer.fromJson<String>(json['bookId']),
      deletedAt: serializer.fromJson<int>(json['deletedAt']),
      pushed: serializer.fromJson<bool>(json['pushed']),
      contentHash: serializer.fromJson<String>(json['contentHash']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'bookId': serializer.toJson<String>(bookId),
      'deletedAt': serializer.toJson<int>(deletedAt),
      'pushed': serializer.toJson<bool>(pushed),
      'contentHash': serializer.toJson<String>(contentHash),
    };
  }

  DeletedBook copyWith({
    String? bookId,
    int? deletedAt,
    bool? pushed,
    String? contentHash,
  }) => DeletedBook(
    bookId: bookId ?? this.bookId,
    deletedAt: deletedAt ?? this.deletedAt,
    pushed: pushed ?? this.pushed,
    contentHash: contentHash ?? this.contentHash,
  );
  DeletedBook copyWithCompanion(DeletedBooksCompanion data) {
    return DeletedBook(
      bookId: data.bookId.present ? data.bookId.value : this.bookId,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      pushed: data.pushed.present ? data.pushed.value : this.pushed,
      contentHash: data.contentHash.present
          ? data.contentHash.value
          : this.contentHash,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DeletedBook(')
          ..write('bookId: $bookId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('pushed: $pushed, ')
          ..write('contentHash: $contentHash')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(bookId, deletedAt, pushed, contentHash);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DeletedBook &&
          other.bookId == this.bookId &&
          other.deletedAt == this.deletedAt &&
          other.pushed == this.pushed &&
          other.contentHash == this.contentHash);
}

class DeletedBooksCompanion extends UpdateCompanion<DeletedBook> {
  final Value<String> bookId;
  final Value<int> deletedAt;
  final Value<bool> pushed;
  final Value<String> contentHash;
  final Value<int> rowid;
  const DeletedBooksCompanion({
    this.bookId = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.pushed = const Value.absent(),
    this.contentHash = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DeletedBooksCompanion.insert({
    required String bookId,
    required int deletedAt,
    this.pushed = const Value.absent(),
    required String contentHash,
    this.rowid = const Value.absent(),
  }) : bookId = Value(bookId),
       deletedAt = Value(deletedAt),
       contentHash = Value(contentHash);
  static Insertable<DeletedBook> custom({
    Expression<String>? bookId,
    Expression<int>? deletedAt,
    Expression<bool>? pushed,
    Expression<String>? contentHash,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (bookId != null) 'book_id': bookId,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (pushed != null) 'pushed': pushed,
      if (contentHash != null) 'content_hash': contentHash,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DeletedBooksCompanion copyWith({
    Value<String>? bookId,
    Value<int>? deletedAt,
    Value<bool>? pushed,
    Value<String>? contentHash,
    Value<int>? rowid,
  }) {
    return DeletedBooksCompanion(
      bookId: bookId ?? this.bookId,
      deletedAt: deletedAt ?? this.deletedAt,
      pushed: pushed ?? this.pushed,
      contentHash: contentHash ?? this.contentHash,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (bookId.present) {
      map['book_id'] = Variable<String>(bookId.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    if (pushed.present) {
      map['pushed'] = Variable<bool>(pushed.value);
    }
    if (contentHash.present) {
      map['content_hash'] = Variable<String>(contentHash.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DeletedBooksCompanion(')
          ..write('bookId: $bookId, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('pushed: $pushed, ')
          ..write('contentHash: $contentHash, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncCursorTable extends SyncCursor
    with TableInfo<$SyncCursorTable, SyncCursorRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncCursorTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _backendKeyMeta = const VerificationMeta(
    'backendKey',
  );
  @override
  late final GeneratedColumn<String> backendKey = GeneratedColumn<String>(
    'backend_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _changesCursorMeta = const VerificationMeta(
    'changesCursor',
  );
  @override
  late final GeneratedColumn<String> changesCursor = GeneratedColumn<String>(
    'changes_cursor',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _metaListingEtagMeta = const VerificationMeta(
    'metaListingEtag',
  );
  @override
  late final GeneratedColumn<String> metaListingEtag = GeneratedColumn<String>(
    'meta_listing_etag',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastFullSyncAtMeta = const VerificationMeta(
    'lastFullSyncAt',
  );
  @override
  late final GeneratedColumn<int> lastFullSyncAt = GeneratedColumn<int>(
    'last_full_sync_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _quotaUpBytesMeta = const VerificationMeta(
    'quotaUpBytes',
  );
  @override
  late final GeneratedColumn<int> quotaUpBytes = GeneratedColumn<int>(
    'quota_up_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _quotaDownBytesMeta = const VerificationMeta(
    'quotaDownBytes',
  );
  @override
  late final GeneratedColumn<int> quotaDownBytes = GeneratedColumn<int>(
    'quota_down_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _quotaMonthMeta = const VerificationMeta(
    'quotaMonth',
  );
  @override
  late final GeneratedColumn<String> quotaMonth = GeneratedColumn<String>(
    'quota_month',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    backendKey,
    changesCursor,
    metaListingEtag,
    lastFullSyncAt,
    quotaUpBytes,
    quotaDownBytes,
    quotaMonth,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_cursor';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncCursorRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('backend_key')) {
      context.handle(
        _backendKeyMeta,
        backendKey.isAcceptableOrUnknown(data['backend_key']!, _backendKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_backendKeyMeta);
    }
    if (data.containsKey('changes_cursor')) {
      context.handle(
        _changesCursorMeta,
        changesCursor.isAcceptableOrUnknown(
          data['changes_cursor']!,
          _changesCursorMeta,
        ),
      );
    }
    if (data.containsKey('meta_listing_etag')) {
      context.handle(
        _metaListingEtagMeta,
        metaListingEtag.isAcceptableOrUnknown(
          data['meta_listing_etag']!,
          _metaListingEtagMeta,
        ),
      );
    }
    if (data.containsKey('last_full_sync_at')) {
      context.handle(
        _lastFullSyncAtMeta,
        lastFullSyncAt.isAcceptableOrUnknown(
          data['last_full_sync_at']!,
          _lastFullSyncAtMeta,
        ),
      );
    }
    if (data.containsKey('quota_up_bytes')) {
      context.handle(
        _quotaUpBytesMeta,
        quotaUpBytes.isAcceptableOrUnknown(
          data['quota_up_bytes']!,
          _quotaUpBytesMeta,
        ),
      );
    }
    if (data.containsKey('quota_down_bytes')) {
      context.handle(
        _quotaDownBytesMeta,
        quotaDownBytes.isAcceptableOrUnknown(
          data['quota_down_bytes']!,
          _quotaDownBytesMeta,
        ),
      );
    }
    if (data.containsKey('quota_month')) {
      context.handle(
        _quotaMonthMeta,
        quotaMonth.isAcceptableOrUnknown(data['quota_month']!, _quotaMonthMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {backendKey};
  @override
  SyncCursorRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncCursorRow(
      backendKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}backend_key'],
      )!,
      changesCursor: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}changes_cursor'],
      ),
      metaListingEtag: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}meta_listing_etag'],
      ),
      lastFullSyncAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_full_sync_at'],
      ),
      quotaUpBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}quota_up_bytes'],
      )!,
      quotaDownBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}quota_down_bytes'],
      )!,
      quotaMonth: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}quota_month'],
      ),
    );
  }

  @override
  $SyncCursorTable createAlias(String alias) {
    return $SyncCursorTable(attachedDatabase, alias);
  }
}

class SyncCursorRow extends DataClass implements Insertable<SyncCursorRow> {
  final String backendKey;

  /// REST 模式服务端游标。
  final String? changesCursor;

  /// WebDAV PROPFIND 响应 ETag（无则全量列）。
  final String? metaListingEtag;

  /// 上次全量同步时间（epoch ms）。
  final int? lastFullSyncAt;

  /// 本自然月对坚果云上行累计（docs/04 §8.3）。
  final int quotaUpBytes;

  /// 本自然月下行累计。
  final int quotaDownBytes;

  /// 配额累计所属月份（如 '2026-10'）。
  final String? quotaMonth;
  const SyncCursorRow({
    required this.backendKey,
    this.changesCursor,
    this.metaListingEtag,
    this.lastFullSyncAt,
    required this.quotaUpBytes,
    required this.quotaDownBytes,
    this.quotaMonth,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['backend_key'] = Variable<String>(backendKey);
    if (!nullToAbsent || changesCursor != null) {
      map['changes_cursor'] = Variable<String>(changesCursor);
    }
    if (!nullToAbsent || metaListingEtag != null) {
      map['meta_listing_etag'] = Variable<String>(metaListingEtag);
    }
    if (!nullToAbsent || lastFullSyncAt != null) {
      map['last_full_sync_at'] = Variable<int>(lastFullSyncAt);
    }
    map['quota_up_bytes'] = Variable<int>(quotaUpBytes);
    map['quota_down_bytes'] = Variable<int>(quotaDownBytes);
    if (!nullToAbsent || quotaMonth != null) {
      map['quota_month'] = Variable<String>(quotaMonth);
    }
    return map;
  }

  SyncCursorCompanion toCompanion(bool nullToAbsent) {
    return SyncCursorCompanion(
      backendKey: Value(backendKey),
      changesCursor: changesCursor == null && nullToAbsent
          ? const Value.absent()
          : Value(changesCursor),
      metaListingEtag: metaListingEtag == null && nullToAbsent
          ? const Value.absent()
          : Value(metaListingEtag),
      lastFullSyncAt: lastFullSyncAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastFullSyncAt),
      quotaUpBytes: Value(quotaUpBytes),
      quotaDownBytes: Value(quotaDownBytes),
      quotaMonth: quotaMonth == null && nullToAbsent
          ? const Value.absent()
          : Value(quotaMonth),
    );
  }

  factory SyncCursorRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncCursorRow(
      backendKey: serializer.fromJson<String>(json['backendKey']),
      changesCursor: serializer.fromJson<String?>(json['changesCursor']),
      metaListingEtag: serializer.fromJson<String?>(json['metaListingEtag']),
      lastFullSyncAt: serializer.fromJson<int?>(json['lastFullSyncAt']),
      quotaUpBytes: serializer.fromJson<int>(json['quotaUpBytes']),
      quotaDownBytes: serializer.fromJson<int>(json['quotaDownBytes']),
      quotaMonth: serializer.fromJson<String?>(json['quotaMonth']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'backendKey': serializer.toJson<String>(backendKey),
      'changesCursor': serializer.toJson<String?>(changesCursor),
      'metaListingEtag': serializer.toJson<String?>(metaListingEtag),
      'lastFullSyncAt': serializer.toJson<int?>(lastFullSyncAt),
      'quotaUpBytes': serializer.toJson<int>(quotaUpBytes),
      'quotaDownBytes': serializer.toJson<int>(quotaDownBytes),
      'quotaMonth': serializer.toJson<String?>(quotaMonth),
    };
  }

  SyncCursorRow copyWith({
    String? backendKey,
    Value<String?> changesCursor = const Value.absent(),
    Value<String?> metaListingEtag = const Value.absent(),
    Value<int?> lastFullSyncAt = const Value.absent(),
    int? quotaUpBytes,
    int? quotaDownBytes,
    Value<String?> quotaMonth = const Value.absent(),
  }) => SyncCursorRow(
    backendKey: backendKey ?? this.backendKey,
    changesCursor: changesCursor.present
        ? changesCursor.value
        : this.changesCursor,
    metaListingEtag: metaListingEtag.present
        ? metaListingEtag.value
        : this.metaListingEtag,
    lastFullSyncAt: lastFullSyncAt.present
        ? lastFullSyncAt.value
        : this.lastFullSyncAt,
    quotaUpBytes: quotaUpBytes ?? this.quotaUpBytes,
    quotaDownBytes: quotaDownBytes ?? this.quotaDownBytes,
    quotaMonth: quotaMonth.present ? quotaMonth.value : this.quotaMonth,
  );
  SyncCursorRow copyWithCompanion(SyncCursorCompanion data) {
    return SyncCursorRow(
      backendKey: data.backendKey.present
          ? data.backendKey.value
          : this.backendKey,
      changesCursor: data.changesCursor.present
          ? data.changesCursor.value
          : this.changesCursor,
      metaListingEtag: data.metaListingEtag.present
          ? data.metaListingEtag.value
          : this.metaListingEtag,
      lastFullSyncAt: data.lastFullSyncAt.present
          ? data.lastFullSyncAt.value
          : this.lastFullSyncAt,
      quotaUpBytes: data.quotaUpBytes.present
          ? data.quotaUpBytes.value
          : this.quotaUpBytes,
      quotaDownBytes: data.quotaDownBytes.present
          ? data.quotaDownBytes.value
          : this.quotaDownBytes,
      quotaMonth: data.quotaMonth.present
          ? data.quotaMonth.value
          : this.quotaMonth,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncCursorRow(')
          ..write('backendKey: $backendKey, ')
          ..write('changesCursor: $changesCursor, ')
          ..write('metaListingEtag: $metaListingEtag, ')
          ..write('lastFullSyncAt: $lastFullSyncAt, ')
          ..write('quotaUpBytes: $quotaUpBytes, ')
          ..write('quotaDownBytes: $quotaDownBytes, ')
          ..write('quotaMonth: $quotaMonth')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    backendKey,
    changesCursor,
    metaListingEtag,
    lastFullSyncAt,
    quotaUpBytes,
    quotaDownBytes,
    quotaMonth,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncCursorRow &&
          other.backendKey == this.backendKey &&
          other.changesCursor == this.changesCursor &&
          other.metaListingEtag == this.metaListingEtag &&
          other.lastFullSyncAt == this.lastFullSyncAt &&
          other.quotaUpBytes == this.quotaUpBytes &&
          other.quotaDownBytes == this.quotaDownBytes &&
          other.quotaMonth == this.quotaMonth);
}

class SyncCursorCompanion extends UpdateCompanion<SyncCursorRow> {
  final Value<String> backendKey;
  final Value<String?> changesCursor;
  final Value<String?> metaListingEtag;
  final Value<int?> lastFullSyncAt;
  final Value<int> quotaUpBytes;
  final Value<int> quotaDownBytes;
  final Value<String?> quotaMonth;
  final Value<int> rowid;
  const SyncCursorCompanion({
    this.backendKey = const Value.absent(),
    this.changesCursor = const Value.absent(),
    this.metaListingEtag = const Value.absent(),
    this.lastFullSyncAt = const Value.absent(),
    this.quotaUpBytes = const Value.absent(),
    this.quotaDownBytes = const Value.absent(),
    this.quotaMonth = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncCursorCompanion.insert({
    required String backendKey,
    this.changesCursor = const Value.absent(),
    this.metaListingEtag = const Value.absent(),
    this.lastFullSyncAt = const Value.absent(),
    this.quotaUpBytes = const Value.absent(),
    this.quotaDownBytes = const Value.absent(),
    this.quotaMonth = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : backendKey = Value(backendKey);
  static Insertable<SyncCursorRow> custom({
    Expression<String>? backendKey,
    Expression<String>? changesCursor,
    Expression<String>? metaListingEtag,
    Expression<int>? lastFullSyncAt,
    Expression<int>? quotaUpBytes,
    Expression<int>? quotaDownBytes,
    Expression<String>? quotaMonth,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (backendKey != null) 'backend_key': backendKey,
      if (changesCursor != null) 'changes_cursor': changesCursor,
      if (metaListingEtag != null) 'meta_listing_etag': metaListingEtag,
      if (lastFullSyncAt != null) 'last_full_sync_at': lastFullSyncAt,
      if (quotaUpBytes != null) 'quota_up_bytes': quotaUpBytes,
      if (quotaDownBytes != null) 'quota_down_bytes': quotaDownBytes,
      if (quotaMonth != null) 'quota_month': quotaMonth,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncCursorCompanion copyWith({
    Value<String>? backendKey,
    Value<String?>? changesCursor,
    Value<String?>? metaListingEtag,
    Value<int?>? lastFullSyncAt,
    Value<int>? quotaUpBytes,
    Value<int>? quotaDownBytes,
    Value<String?>? quotaMonth,
    Value<int>? rowid,
  }) {
    return SyncCursorCompanion(
      backendKey: backendKey ?? this.backendKey,
      changesCursor: changesCursor ?? this.changesCursor,
      metaListingEtag: metaListingEtag ?? this.metaListingEtag,
      lastFullSyncAt: lastFullSyncAt ?? this.lastFullSyncAt,
      quotaUpBytes: quotaUpBytes ?? this.quotaUpBytes,
      quotaDownBytes: quotaDownBytes ?? this.quotaDownBytes,
      quotaMonth: quotaMonth ?? this.quotaMonth,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (backendKey.present) {
      map['backend_key'] = Variable<String>(backendKey.value);
    }
    if (changesCursor.present) {
      map['changes_cursor'] = Variable<String>(changesCursor.value);
    }
    if (metaListingEtag.present) {
      map['meta_listing_etag'] = Variable<String>(metaListingEtag.value);
    }
    if (lastFullSyncAt.present) {
      map['last_full_sync_at'] = Variable<int>(lastFullSyncAt.value);
    }
    if (quotaUpBytes.present) {
      map['quota_up_bytes'] = Variable<int>(quotaUpBytes.value);
    }
    if (quotaDownBytes.present) {
      map['quota_down_bytes'] = Variable<int>(quotaDownBytes.value);
    }
    if (quotaMonth.present) {
      map['quota_month'] = Variable<String>(quotaMonth.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncCursorCompanion(')
          ..write('backendKey: $backendKey, ')
          ..write('changesCursor: $changesCursor, ')
          ..write('metaListingEtag: $metaListingEtag, ')
          ..write('lastFullSyncAt: $lastFullSyncAt, ')
          ..write('quotaUpBytes: $quotaUpBytes, ')
          ..write('quotaDownBytes: $quotaDownBytes, ')
          ..write('quotaMonth: $quotaMonth, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ReaderSettingsTable extends ReaderSettings
    with TableInfo<$ReaderSettingsTable, ReaderSettingsEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ReaderSettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'reader_settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<ReaderSettingsEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  ReaderSettingsEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ReaderSettingsEntry(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $ReaderSettingsTable createAlias(String alias) {
    return $ReaderSettingsTable(attachedDatabase, alias);
  }
}

class ReaderSettingsEntry extends DataClass
    implements Insertable<ReaderSettingsEntry> {
  /// 设置键（如 'reader_settings' 单键整体存取，或后续分键）。
  final String key;

  /// JSON 序列化的值。
  final String value;
  const ReaderSettingsEntry({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  ReaderSettingsCompanion toCompanion(bool nullToAbsent) {
    return ReaderSettingsCompanion(key: Value(key), value: Value(value));
  }

  factory ReaderSettingsEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ReaderSettingsEntry(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  ReaderSettingsEntry copyWith({String? key, String? value}) =>
      ReaderSettingsEntry(key: key ?? this.key, value: value ?? this.value);
  ReaderSettingsEntry copyWithCompanion(ReaderSettingsCompanion data) {
    return ReaderSettingsEntry(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ReaderSettingsEntry(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ReaderSettingsEntry &&
          other.key == this.key &&
          other.value == this.value);
}

class ReaderSettingsCompanion extends UpdateCompanion<ReaderSettingsEntry> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const ReaderSettingsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ReaderSettingsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<ReaderSettingsEntry> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ReaderSettingsCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return ReaderSettingsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ReaderSettingsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncQueueTable extends SyncQueue
    with TableInfo<$SyncQueueTable, SyncQueueEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncQueueTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _bookIdMeta = const VerificationMeta('bookId');
  @override
  late final GeneratedColumn<String> bookId = GeneratedColumn<String>(
    'book_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _opMeta = const VerificationMeta('op');
  @override
  late final GeneratedColumn<String> op = GeneratedColumn<String>(
    'op',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _enqueuedAtMeta = const VerificationMeta(
    'enqueuedAt',
  );
  @override
  late final GeneratedColumn<int> enqueuedAt = GeneratedColumn<int>(
    'enqueued_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _attemptsMeta = const VerificationMeta(
    'attempts',
  );
  @override
  late final GeneratedColumn<int> attempts = GeneratedColumn<int>(
    'attempts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [id, bookId, op, enqueuedAt, attempts];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_queue';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncQueueEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('book_id')) {
      context.handle(
        _bookIdMeta,
        bookId.isAcceptableOrUnknown(data['book_id']!, _bookIdMeta),
      );
    } else if (isInserting) {
      context.missing(_bookIdMeta);
    }
    if (data.containsKey('op')) {
      context.handle(_opMeta, op.isAcceptableOrUnknown(data['op']!, _opMeta));
    } else if (isInserting) {
      context.missing(_opMeta);
    }
    if (data.containsKey('enqueued_at')) {
      context.handle(
        _enqueuedAtMeta,
        enqueuedAt.isAcceptableOrUnknown(data['enqueued_at']!, _enqueuedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_enqueuedAtMeta);
    }
    if (data.containsKey('attempts')) {
      context.handle(
        _attemptsMeta,
        attempts.isAcceptableOrUnknown(data['attempts']!, _attemptsMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SyncQueueEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncQueueEntry(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      bookId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}book_id'],
      )!,
      op: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}op'],
      )!,
      enqueuedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}enqueued_at'],
      )!,
      attempts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}attempts'],
      )!,
    );
  }

  @override
  $SyncQueueTable createAlias(String alias) {
    return $SyncQueueTable(attachedDatabase, alias);
  }
}

class SyncQueueEntry extends DataClass implements Insertable<SyncQueueEntry> {
  /// 自增主键（FIFO 序）。
  final int id;
  final String bookId;

  /// 'meta' | 'book_upload'（docs/05 §5 注释）。
  final String op;

  /// 入队时间（epoch ms）。
  final int enqueuedAt;

  /// 重试次数。
  final int attempts;
  const SyncQueueEntry({
    required this.id,
    required this.bookId,
    required this.op,
    required this.enqueuedAt,
    required this.attempts,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['book_id'] = Variable<String>(bookId);
    map['op'] = Variable<String>(op);
    map['enqueued_at'] = Variable<int>(enqueuedAt);
    map['attempts'] = Variable<int>(attempts);
    return map;
  }

  SyncQueueCompanion toCompanion(bool nullToAbsent) {
    return SyncQueueCompanion(
      id: Value(id),
      bookId: Value(bookId),
      op: Value(op),
      enqueuedAt: Value(enqueuedAt),
      attempts: Value(attempts),
    );
  }

  factory SyncQueueEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncQueueEntry(
      id: serializer.fromJson<int>(json['id']),
      bookId: serializer.fromJson<String>(json['bookId']),
      op: serializer.fromJson<String>(json['op']),
      enqueuedAt: serializer.fromJson<int>(json['enqueuedAt']),
      attempts: serializer.fromJson<int>(json['attempts']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'bookId': serializer.toJson<String>(bookId),
      'op': serializer.toJson<String>(op),
      'enqueuedAt': serializer.toJson<int>(enqueuedAt),
      'attempts': serializer.toJson<int>(attempts),
    };
  }

  SyncQueueEntry copyWith({
    int? id,
    String? bookId,
    String? op,
    int? enqueuedAt,
    int? attempts,
  }) => SyncQueueEntry(
    id: id ?? this.id,
    bookId: bookId ?? this.bookId,
    op: op ?? this.op,
    enqueuedAt: enqueuedAt ?? this.enqueuedAt,
    attempts: attempts ?? this.attempts,
  );
  SyncQueueEntry copyWithCompanion(SyncQueueCompanion data) {
    return SyncQueueEntry(
      id: data.id.present ? data.id.value : this.id,
      bookId: data.bookId.present ? data.bookId.value : this.bookId,
      op: data.op.present ? data.op.value : this.op,
      enqueuedAt: data.enqueuedAt.present
          ? data.enqueuedAt.value
          : this.enqueuedAt,
      attempts: data.attempts.present ? data.attempts.value : this.attempts,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncQueueEntry(')
          ..write('id: $id, ')
          ..write('bookId: $bookId, ')
          ..write('op: $op, ')
          ..write('enqueuedAt: $enqueuedAt, ')
          ..write('attempts: $attempts')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, bookId, op, enqueuedAt, attempts);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncQueueEntry &&
          other.id == this.id &&
          other.bookId == this.bookId &&
          other.op == this.op &&
          other.enqueuedAt == this.enqueuedAt &&
          other.attempts == this.attempts);
}

class SyncQueueCompanion extends UpdateCompanion<SyncQueueEntry> {
  final Value<int> id;
  final Value<String> bookId;
  final Value<String> op;
  final Value<int> enqueuedAt;
  final Value<int> attempts;
  const SyncQueueCompanion({
    this.id = const Value.absent(),
    this.bookId = const Value.absent(),
    this.op = const Value.absent(),
    this.enqueuedAt = const Value.absent(),
    this.attempts = const Value.absent(),
  });
  SyncQueueCompanion.insert({
    this.id = const Value.absent(),
    required String bookId,
    required String op,
    required int enqueuedAt,
    this.attempts = const Value.absent(),
  }) : bookId = Value(bookId),
       op = Value(op),
       enqueuedAt = Value(enqueuedAt);
  static Insertable<SyncQueueEntry> custom({
    Expression<int>? id,
    Expression<String>? bookId,
    Expression<String>? op,
    Expression<int>? enqueuedAt,
    Expression<int>? attempts,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (bookId != null) 'book_id': bookId,
      if (op != null) 'op': op,
      if (enqueuedAt != null) 'enqueued_at': enqueuedAt,
      if (attempts != null) 'attempts': attempts,
    });
  }

  SyncQueueCompanion copyWith({
    Value<int>? id,
    Value<String>? bookId,
    Value<String>? op,
    Value<int>? enqueuedAt,
    Value<int>? attempts,
  }) {
    return SyncQueueCompanion(
      id: id ?? this.id,
      bookId: bookId ?? this.bookId,
      op: op ?? this.op,
      enqueuedAt: enqueuedAt ?? this.enqueuedAt,
      attempts: attempts ?? this.attempts,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (bookId.present) {
      map['book_id'] = Variable<String>(bookId.value);
    }
    if (op.present) {
      map['op'] = Variable<String>(op.value);
    }
    if (enqueuedAt.present) {
      map['enqueued_at'] = Variable<int>(enqueuedAt.value);
    }
    if (attempts.present) {
      map['attempts'] = Variable<int>(attempts.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncQueueCompanion(')
          ..write('id: $id, ')
          ..write('bookId: $bookId, ')
          ..write('op: $op, ')
          ..write('enqueuedAt: $enqueuedAt, ')
          ..write('attempts: $attempts')
          ..write(')'))
        .toString();
  }
}

class $ReadingDaysTable extends ReadingDays
    with TableInfo<$ReadingDaysTable, ReadingDay> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ReadingDaysTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _bookIdMeta = const VerificationMeta('bookId');
  @override
  late final GeneratedColumn<String> bookId = GeneratedColumn<String>(
    'book_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES books (book_id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _dayMeta = const VerificationMeta('day');
  @override
  late final GeneratedColumn<String> day = GeneratedColumn<String>(
    'day',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _secondsMeta = const VerificationMeta(
    'seconds',
  );
  @override
  late final GeneratedColumn<int> seconds = GeneratedColumn<int>(
    'seconds',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [bookId, day, seconds];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'reading_days';
  @override
  VerificationContext validateIntegrity(
    Insertable<ReadingDay> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('book_id')) {
      context.handle(
        _bookIdMeta,
        bookId.isAcceptableOrUnknown(data['book_id']!, _bookIdMeta),
      );
    } else if (isInserting) {
      context.missing(_bookIdMeta);
    }
    if (data.containsKey('day')) {
      context.handle(
        _dayMeta,
        day.isAcceptableOrUnknown(data['day']!, _dayMeta),
      );
    } else if (isInserting) {
      context.missing(_dayMeta);
    }
    if (data.containsKey('seconds')) {
      context.handle(
        _secondsMeta,
        seconds.isAcceptableOrUnknown(data['seconds']!, _secondsMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {bookId, day};
  @override
  ReadingDay map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ReadingDay(
      bookId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}book_id'],
      )!,
      day: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}day'],
      )!,
      seconds: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}seconds'],
      )!,
    );
  }

  @override
  $ReadingDaysTable createAlias(String alias) {
    return $ReadingDaysTable(attachedDatabase, alias);
  }
}

class ReadingDay extends DataClass implements Insertable<ReadingDay> {
  /// 所属书籍（级联删除）。
  final String bookId;

  /// 本地自然日，格式 'YYYY-MM-DD'（设备时区）。
  final String day;

  /// 当天累计阅读秒数。
  final int seconds;
  const ReadingDay({
    required this.bookId,
    required this.day,
    required this.seconds,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['book_id'] = Variable<String>(bookId);
    map['day'] = Variable<String>(day);
    map['seconds'] = Variable<int>(seconds);
    return map;
  }

  ReadingDaysCompanion toCompanion(bool nullToAbsent) {
    return ReadingDaysCompanion(
      bookId: Value(bookId),
      day: Value(day),
      seconds: Value(seconds),
    );
  }

  factory ReadingDay.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ReadingDay(
      bookId: serializer.fromJson<String>(json['bookId']),
      day: serializer.fromJson<String>(json['day']),
      seconds: serializer.fromJson<int>(json['seconds']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'bookId': serializer.toJson<String>(bookId),
      'day': serializer.toJson<String>(day),
      'seconds': serializer.toJson<int>(seconds),
    };
  }

  ReadingDay copyWith({String? bookId, String? day, int? seconds}) =>
      ReadingDay(
        bookId: bookId ?? this.bookId,
        day: day ?? this.day,
        seconds: seconds ?? this.seconds,
      );
  ReadingDay copyWithCompanion(ReadingDaysCompanion data) {
    return ReadingDay(
      bookId: data.bookId.present ? data.bookId.value : this.bookId,
      day: data.day.present ? data.day.value : this.day,
      seconds: data.seconds.present ? data.seconds.value : this.seconds,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ReadingDay(')
          ..write('bookId: $bookId, ')
          ..write('day: $day, ')
          ..write('seconds: $seconds')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(bookId, day, seconds);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ReadingDay &&
          other.bookId == this.bookId &&
          other.day == this.day &&
          other.seconds == this.seconds);
}

class ReadingDaysCompanion extends UpdateCompanion<ReadingDay> {
  final Value<String> bookId;
  final Value<String> day;
  final Value<int> seconds;
  final Value<int> rowid;
  const ReadingDaysCompanion({
    this.bookId = const Value.absent(),
    this.day = const Value.absent(),
    this.seconds = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ReadingDaysCompanion.insert({
    required String bookId,
    required String day,
    this.seconds = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : bookId = Value(bookId),
       day = Value(day);
  static Insertable<ReadingDay> custom({
    Expression<String>? bookId,
    Expression<String>? day,
    Expression<int>? seconds,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (bookId != null) 'book_id': bookId,
      if (day != null) 'day': day,
      if (seconds != null) 'seconds': seconds,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ReadingDaysCompanion copyWith({
    Value<String>? bookId,
    Value<String>? day,
    Value<int>? seconds,
    Value<int>? rowid,
  }) {
    return ReadingDaysCompanion(
      bookId: bookId ?? this.bookId,
      day: day ?? this.day,
      seconds: seconds ?? this.seconds,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (bookId.present) {
      map['book_id'] = Variable<String>(bookId.value);
    }
    if (day.present) {
      map['day'] = Variable<String>(day.value);
    }
    if (seconds.present) {
      map['seconds'] = Variable<int>(seconds.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ReadingDaysCompanion(')
          ..write('bookId: $bookId, ')
          ..write('day: $day, ')
          ..write('seconds: $seconds, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalOnlyBooksTable extends LocalOnlyBooks
    with TableInfo<$LocalOnlyBooksTable, LocalOnlyBook> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalOnlyBooksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _bookIdMeta = const VerificationMeta('bookId');
  @override
  late final GeneratedColumn<String> bookId = GeneratedColumn<String>(
    'book_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [bookId, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_only_books';
  @override
  VerificationContext validateIntegrity(
    Insertable<LocalOnlyBook> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('book_id')) {
      context.handle(
        _bookIdMeta,
        bookId.isAcceptableOrUnknown(data['book_id']!, _bookIdMeta),
      );
    } else if (isInserting) {
      context.missing(_bookIdMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {bookId};
  @override
  LocalOnlyBook map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalOnlyBook(
      bookId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}book_id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $LocalOnlyBooksTable createAlias(String alias) {
    return $LocalOnlyBooksTable(attachedDatabase, alias);
  }
}

class LocalOnlyBook extends DataClass implements Insertable<LocalOnlyBook> {
  /// 书籍 ULID（对应 books.book_id）。
  final String bookId;

  /// 标记时间（epoch ms，诊断与「最近标记」排序用）。
  final int createdAt;
  const LocalOnlyBook({required this.bookId, required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['book_id'] = Variable<String>(bookId);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  LocalOnlyBooksCompanion toCompanion(bool nullToAbsent) {
    return LocalOnlyBooksCompanion(
      bookId: Value(bookId),
      createdAt: Value(createdAt),
    );
  }

  factory LocalOnlyBook.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalOnlyBook(
      bookId: serializer.fromJson<String>(json['bookId']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'bookId': serializer.toJson<String>(bookId),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  LocalOnlyBook copyWith({String? bookId, int? createdAt}) => LocalOnlyBook(
    bookId: bookId ?? this.bookId,
    createdAt: createdAt ?? this.createdAt,
  );
  LocalOnlyBook copyWithCompanion(LocalOnlyBooksCompanion data) {
    return LocalOnlyBook(
      bookId: data.bookId.present ? data.bookId.value : this.bookId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalOnlyBook(')
          ..write('bookId: $bookId, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(bookId, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalOnlyBook &&
          other.bookId == this.bookId &&
          other.createdAt == this.createdAt);
}

class LocalOnlyBooksCompanion extends UpdateCompanion<LocalOnlyBook> {
  final Value<String> bookId;
  final Value<int> createdAt;
  final Value<int> rowid;
  const LocalOnlyBooksCompanion({
    this.bookId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalOnlyBooksCompanion.insert({
    required String bookId,
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : bookId = Value(bookId);
  static Insertable<LocalOnlyBook> custom({
    Expression<String>? bookId,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (bookId != null) 'book_id': bookId,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalOnlyBooksCompanion copyWith({
    Value<String>? bookId,
    Value<int>? createdAt,
    Value<int>? rowid,
  }) {
    return LocalOnlyBooksCompanion(
      bookId: bookId ?? this.bookId,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (bookId.present) {
      map['book_id'] = Variable<String>(bookId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalOnlyBooksCompanion(')
          ..write('bookId: $bookId, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AppSettingsTable extends AppSettings
    with TableInfo<$AppSettingsTable, AppSetting> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AppSettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'app_settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<AppSetting> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  AppSetting map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AppSetting(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $AppSettingsTable createAlias(String alias) {
    return $AppSettingsTable(attachedDatabase, alias);
  }
}

class AppSetting extends DataClass implements Insertable<AppSetting> {
  /// 设置键（如 'accent'）。
  final String key;

  /// JSON 序列化的值（或纯字符串）。
  final String value;
  const AppSetting({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  AppSettingsCompanion toCompanion(bool nullToAbsent) {
    return AppSettingsCompanion(key: Value(key), value: Value(value));
  }

  factory AppSetting.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AppSetting(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  AppSetting copyWith({String? key, String? value}) =>
      AppSetting(key: key ?? this.key, value: value ?? this.value);
  AppSetting copyWithCompanion(AppSettingsCompanion data) {
    return AppSetting(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AppSetting(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppSetting &&
          other.key == this.key &&
          other.value == this.value);
}

class AppSettingsCompanion extends UpdateCompanion<AppSetting> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const AppSettingsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AppSettingsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<AppSetting> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AppSettingsCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return AppSettingsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AppSettingsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $BookGroupsTable bookGroups = $BookGroupsTable(this);
  late final $BooksTable books = $BooksTable(this);
  late final $ProgressTable progress = $ProgressTable(this);
  late final $SyncStateTable syncState = $SyncStateTable(this);
  late final $DeletedBooksTable deletedBooks = $DeletedBooksTable(this);
  late final $SyncCursorTable syncCursor = $SyncCursorTable(this);
  late final $ReaderSettingsTable readerSettings = $ReaderSettingsTable(this);
  late final $SyncQueueTable syncQueue = $SyncQueueTable(this);
  late final $ReadingDaysTable readingDays = $ReadingDaysTable(this);
  late final $LocalOnlyBooksTable localOnlyBooks = $LocalOnlyBooksTable(this);
  late final $AppSettingsTable appSettings = $AppSettingsTable(this);
  late final Index idxBooksLastRead = Index(
    'idx_books_last_read',
    'CREATE INDEX idx_books_last_read ON books (last_read_at)',
  );
  late final Index idxBooksTitle = Index(
    'idx_books_title',
    'CREATE INDEX idx_books_title ON books (title)',
  );
  late final BooksDao booksDao = BooksDao(this as AppDatabase);
  late final ProgressDao progressDao = ProgressDao(this as AppDatabase);
  late final ReaderSettingsDao readerSettingsDao = ReaderSettingsDao(
    this as AppDatabase,
  );
  late final SyncQueueDao syncQueueDao = SyncQueueDao(this as AppDatabase);
  late final ReadingDaysDao readingDaysDao = ReadingDaysDao(
    this as AppDatabase,
  );
  late final BookGroupsDao bookGroupsDao = BookGroupsDao(this as AppDatabase);
  late final LocalOnlyBooksDao localOnlyBooksDao = LocalOnlyBooksDao(
    this as AppDatabase,
  );
  late final AppSettingsDao appSettingsDao = AppSettingsDao(
    this as AppDatabase,
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    bookGroups,
    books,
    progress,
    syncState,
    deletedBooks,
    syncCursor,
    readerSettings,
    syncQueue,
    readingDays,
    localOnlyBooks,
    appSettings,
    idxBooksLastRead,
    idxBooksTitle,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'book_groups',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('books', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'books',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('progress', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'books',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('reading_days', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$BookGroupsTableCreateCompanionBuilder = BookGroupsCompanion Function({
  required String groupId,
  required String name,
  Value<int> sortOrder,
  required int createdAt,
  Value<int> rowid,
});
typedef $$BookGroupsTableUpdateCompanionBuilder = BookGroupsCompanion Function({
  Value<String> groupId,
  Value<String> name,
  Value<int> sortOrder,
  Value<int> createdAt,
  Value<int> rowid,
});

final class $$BookGroupsTableReferences
    extends BaseReferences<_$AppDatabase, $BookGroupsTable, BookGroup> {
  $$BookGroupsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$BooksTable, List<Book>> _booksRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.books,
    aliasName: 'book_groups__group_id__books__group_id',
  );

  $$BooksTableProcessedTableManager get booksRefs {
    final manager = $$BooksTableTableManager($_db, $_db.books).filter(
      (f) => f.groupId.groupId.sqlEquals($_itemColumn<String>('group_id')!),
    );

    final cache = $_typedResult.readTableOrNull(_booksRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$BookGroupsTableFilterComposer
    extends Composer<_$AppDatabase, $BookGroupsTable> {
  $$BookGroupsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> booksRefs(
    Expression<bool> Function($$BooksTableFilterComposer f) f,
  ) {
    final $$BooksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.groupId,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.groupId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableFilterComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$BookGroupsTableOrderingComposer
    extends Composer<_$AppDatabase, $BookGroupsTable> {
  $$BookGroupsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$BookGroupsTableAnnotationComposer
    extends Composer<_$AppDatabase, $BookGroupsTable> {
  $$BookGroupsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get groupId =>
      $composableBuilder(column: $table.groupId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  Expression<T> booksRefs<T extends Object>(
    Expression<T> Function($$BooksTableAnnotationComposer a) f,
  ) {
    final $$BooksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.groupId,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.groupId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableAnnotationComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$BookGroupsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $BookGroupsTable,
          BookGroup,
          $$BookGroupsTableFilterComposer,
          $$BookGroupsTableOrderingComposer,
          $$BookGroupsTableAnnotationComposer,
          $$BookGroupsTableCreateCompanionBuilder,
          $$BookGroupsTableUpdateCompanionBuilder,
          (BookGroup, $$BookGroupsTableReferences),
          BookGroup,
          PrefetchHooks Function({bool booksRefs})
        > {
  $$BookGroupsTableTableManager(_$AppDatabase db, $BookGroupsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BookGroupsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BookGroupsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BookGroupsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> groupId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BookGroupsCompanion(
                groupId: groupId,
                name: name,
                sortOrder: sortOrder,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String groupId,
                required String name,
                Value<int> sortOrder = const Value.absent(),
                required int createdAt,
                Value<int> rowid = const Value.absent(),
              }) => BookGroupsCompanion.insert(
                groupId: groupId,
                name: name,
                sortOrder: sortOrder,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$BookGroupsTable, BookGroup>(table),
                  $$BookGroupsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({booksRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (booksRefs) db.books],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (booksRefs)
                    await $_getPrefetchedDataByColumns<
                      BookGroup,
                      $BookGroupsTable,
                      Book,
                      $BooksTable
                    >(
                      currentTable: table,
                      referencedTable: $$BookGroupsTableReferences
                          ._booksRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$BookGroupsTableReferences(db, table, p0).booksRefs,
                      currentColumn: 'group_id',
                      referencedColumn: 'group_id',
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$BookGroupsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $BookGroupsTable,
      BookGroup,
      $$BookGroupsTableFilterComposer,
      $$BookGroupsTableOrderingComposer,
      $$BookGroupsTableAnnotationComposer,
      $$BookGroupsTableCreateCompanionBuilder,
      $$BookGroupsTableUpdateCompanionBuilder,
      (BookGroup, $$BookGroupsTableReferences),
      BookGroup,
      PrefetchHooks Function({bool booksRefs})
    >;
typedef $$BooksTableCreateCompanionBuilder = BooksCompanion Function({
  required String bookId,
  required String title,
  Value<String> author,
  required String format,
  required String fileName,
  Value<String?> localPath,
  required String contentHash,
  required int sizeBytes,
  Value<String?> coverPath,
  required String tocFingerprint,
  required int addedAt,
  Value<int?> lastReadAt,
  Value<int> totalSeconds,
  Value<String?> groupId,
  Value<int> rowid,
});
typedef $$BooksTableUpdateCompanionBuilder = BooksCompanion Function({
  Value<String> bookId,
  Value<String> title,
  Value<String> author,
  Value<String> format,
  Value<String> fileName,
  Value<String?> localPath,
  Value<String> contentHash,
  Value<int> sizeBytes,
  Value<String?> coverPath,
  Value<String> tocFingerprint,
  Value<int> addedAt,
  Value<int?> lastReadAt,
  Value<int> totalSeconds,
  Value<String?> groupId,
  Value<int> rowid,
});

final class $$BooksTableReferences
    extends BaseReferences<_$AppDatabase, $BooksTable, Book> {
  $$BooksTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $BookGroupsTable _groupIdTable(_$AppDatabase db) =>
      db.bookGroups.createAlias('books__group_id__book_groups__group_id');

  $$BookGroupsTableProcessedTableManager? get groupId {
    final $_column = $_itemColumn<String>('group_id');
    if ($_column == null) return null;
    final manager = $$BookGroupsTableTableManager(
      $_db,
      $_db.bookGroups,
    ).filter((f) => f.groupId.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_groupIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$ProgressTable, List<BookProgress>>
  _progressRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.progress,
    aliasName: 'books__book_id__progress__book_id',
  );

  $$ProgressTableProcessedTableManager get progressRefs {
    final manager = $$ProgressTableTableManager($_db, $_db.progress).filter(
      (f) => f.bookId.bookId.sqlEquals($_itemColumn<String>('book_id')!),
    );

    final cache = $_typedResult.readTableOrNull(_progressRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$ReadingDaysTable, List<ReadingDay>>
  _readingDaysRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.readingDays,
    aliasName: 'books__book_id__reading_days__book_id',
  );

  $$ReadingDaysTableProcessedTableManager get readingDaysRefs {
    final manager = $$ReadingDaysTableTableManager($_db, $_db.readingDays)
        .filter(
          (f) => f.bookId.bookId.sqlEquals($_itemColumn<String>('book_id')!),
        );

    final cache = $_typedResult.readTableOrNull(_readingDaysRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$BooksTableFilterComposer extends Composer<_$AppDatabase, $BooksTable> {
  $$BooksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get author => $composableBuilder(
    column: $table.author,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get format => $composableBuilder(
    column: $table.format,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localPath => $composableBuilder(
    column: $table.localPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentHash => $composableBuilder(
    column: $table.contentHash,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get coverPath => $composableBuilder(
    column: $table.coverPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tocFingerprint => $composableBuilder(
    column: $table.tocFingerprint,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastReadAt => $composableBuilder(
    column: $table.lastReadAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get totalSeconds => $composableBuilder(
    column: $table.totalSeconds,
    builder: (column) => ColumnFilters(column),
  );

  $$BookGroupsTableFilterComposer get groupId {
    final $$BookGroupsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.groupId,
      referencedTable: $db.bookGroups,
      getReferencedColumn: (t) => t.groupId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BookGroupsTableFilterComposer(
            $db: $db,
            $table: $db.bookGroups,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> progressRefs(
    Expression<bool> Function($$ProgressTableFilterComposer f) f,
  ) {
    final $$ProgressTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.bookId,
      referencedTable: $db.progress,
      getReferencedColumn: (t) => t.bookId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProgressTableFilterComposer(
            $db: $db,
            $table: $db.progress,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> readingDaysRefs(
    Expression<bool> Function($$ReadingDaysTableFilterComposer f) f,
  ) {
    final $$ReadingDaysTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.bookId,
      referencedTable: $db.readingDays,
      getReferencedColumn: (t) => t.bookId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ReadingDaysTableFilterComposer(
            $db: $db,
            $table: $db.readingDays,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$BooksTableOrderingComposer
    extends Composer<_$AppDatabase, $BooksTable> {
  $$BooksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get author => $composableBuilder(
    column: $table.author,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get format => $composableBuilder(
    column: $table.format,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localPath => $composableBuilder(
    column: $table.localPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentHash => $composableBuilder(
    column: $table.contentHash,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get coverPath => $composableBuilder(
    column: $table.coverPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tocFingerprint => $composableBuilder(
    column: $table.tocFingerprint,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastReadAt => $composableBuilder(
    column: $table.lastReadAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get totalSeconds => $composableBuilder(
    column: $table.totalSeconds,
    builder: (column) => ColumnOrderings(column),
  );

  $$BookGroupsTableOrderingComposer get groupId {
    final $$BookGroupsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.groupId,
      referencedTable: $db.bookGroups,
      getReferencedColumn: (t) => t.groupId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BookGroupsTableOrderingComposer(
            $db: $db,
            $table: $db.bookGroups,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$BooksTableAnnotationComposer
    extends Composer<_$AppDatabase, $BooksTable> {
  $$BooksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get bookId =>
      $composableBuilder(column: $table.bookId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get author =>
      $composableBuilder(column: $table.author, builder: (column) => column);

  GeneratedColumn<String> get format =>
      $composableBuilder(column: $table.format, builder: (column) => column);

  GeneratedColumn<String> get fileName =>
      $composableBuilder(column: $table.fileName, builder: (column) => column);

  GeneratedColumn<String> get localPath =>
      $composableBuilder(column: $table.localPath, builder: (column) => column);

  GeneratedColumn<String> get contentHash => $composableBuilder(
    column: $table.contentHash,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sizeBytes =>
      $composableBuilder(column: $table.sizeBytes, builder: (column) => column);

  GeneratedColumn<String> get coverPath =>
      $composableBuilder(column: $table.coverPath, builder: (column) => column);

  GeneratedColumn<String> get tocFingerprint => $composableBuilder(
    column: $table.tocFingerprint,
    builder: (column) => column,
  );

  GeneratedColumn<int> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => column);

  GeneratedColumn<int> get lastReadAt => $composableBuilder(
    column: $table.lastReadAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get totalSeconds => $composableBuilder(
    column: $table.totalSeconds,
    builder: (column) => column,
  );

  $$BookGroupsTableAnnotationComposer get groupId {
    final $$BookGroupsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.groupId,
      referencedTable: $db.bookGroups,
      getReferencedColumn: (t) => t.groupId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BookGroupsTableAnnotationComposer(
            $db: $db,
            $table: $db.bookGroups,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> progressRefs<T extends Object>(
    Expression<T> Function($$ProgressTableAnnotationComposer a) f,
  ) {
    final $$ProgressTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.bookId,
      referencedTable: $db.progress,
      getReferencedColumn: (t) => t.bookId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProgressTableAnnotationComposer(
            $db: $db,
            $table: $db.progress,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> readingDaysRefs<T extends Object>(
    Expression<T> Function($$ReadingDaysTableAnnotationComposer a) f,
  ) {
    final $$ReadingDaysTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.bookId,
      referencedTable: $db.readingDays,
      getReferencedColumn: (t) => t.bookId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ReadingDaysTableAnnotationComposer(
            $db: $db,
            $table: $db.readingDays,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$BooksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $BooksTable,
          Book,
          $$BooksTableFilterComposer,
          $$BooksTableOrderingComposer,
          $$BooksTableAnnotationComposer,
          $$BooksTableCreateCompanionBuilder,
          $$BooksTableUpdateCompanionBuilder,
          (Book, $$BooksTableReferences),
          Book,
          PrefetchHooks Function({
            bool groupId,
            bool progressRefs,
            bool readingDaysRefs,
          })
        > {
  $$BooksTableTableManager(_$AppDatabase db, $BooksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BooksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BooksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BooksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> bookId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> author = const Value.absent(),
                Value<String> format = const Value.absent(),
                Value<String> fileName = const Value.absent(),
                Value<String?> localPath = const Value.absent(),
                Value<String> contentHash = const Value.absent(),
                Value<int> sizeBytes = const Value.absent(),
                Value<String?> coverPath = const Value.absent(),
                Value<String> tocFingerprint = const Value.absent(),
                Value<int> addedAt = const Value.absent(),
                Value<int?> lastReadAt = const Value.absent(),
                Value<int> totalSeconds = const Value.absent(),
                Value<String?> groupId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BooksCompanion(
                bookId: bookId,
                title: title,
                author: author,
                format: format,
                fileName: fileName,
                localPath: localPath,
                contentHash: contentHash,
                sizeBytes: sizeBytes,
                coverPath: coverPath,
                tocFingerprint: tocFingerprint,
                addedAt: addedAt,
                lastReadAt: lastReadAt,
                totalSeconds: totalSeconds,
                groupId: groupId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String bookId,
                required String title,
                Value<String> author = const Value.absent(),
                required String format,
                required String fileName,
                Value<String?> localPath = const Value.absent(),
                required String contentHash,
                required int sizeBytes,
                Value<String?> coverPath = const Value.absent(),
                required String tocFingerprint,
                required int addedAt,
                Value<int?> lastReadAt = const Value.absent(),
                Value<int> totalSeconds = const Value.absent(),
                Value<String?> groupId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BooksCompanion.insert(
                bookId: bookId,
                title: title,
                author: author,
                format: format,
                fileName: fileName,
                localPath: localPath,
                contentHash: contentHash,
                sizeBytes: sizeBytes,
                coverPath: coverPath,
                tocFingerprint: tocFingerprint,
                addedAt: addedAt,
                lastReadAt: lastReadAt,
                totalSeconds: totalSeconds,
                groupId: groupId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$BooksTable, Book>(table),
                  $$BooksTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                groupId = false,
                progressRefs = false,
                readingDaysRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (progressRefs) db.progress,
                    if (readingDaysRefs) db.readingDays,
                  ],
                  addJoins:
                      <
                        T extends TableManagerState<
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic
                        >
                      >(state) {
                        if (groupId) {
                          state = state.withJoin(
                            currentTable: table,
                            currentColumn: table.groupId,
                            referencedTable: $$BooksTableReferences
                                ._groupIdTable(db),
                            referencedColumn: $$BooksTableReferences
                                ._groupIdTable(db)
                                .groupId,
                          ) as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (progressRefs)
                        await $_getPrefetchedDataByColumns<
                          Book,
                          $BooksTable,
                          BookProgress,
                          $ProgressTable
                        >(
                          currentTable: table,
                          referencedTable: $$BooksTableReferences
                              ._progressRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$BooksTableReferences(
                                db,
                                table,
                                p0,
                              ).progressRefs,
                          currentColumn: 'book_id',
                          referencedColumn: 'book_id',
                          typedResults: items,
                        ),
                      if (readingDaysRefs)
                        await $_getPrefetchedDataByColumns<
                          Book,
                          $BooksTable,
                          ReadingDay,
                          $ReadingDaysTable
                        >(
                          currentTable: table,
                          referencedTable: $$BooksTableReferences
                              ._readingDaysRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$BooksTableReferences(
                                db,
                                table,
                                p0,
                              ).readingDaysRefs,
                          currentColumn: 'book_id',
                          referencedColumn: 'book_id',
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$BooksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $BooksTable,
      Book,
      $$BooksTableFilterComposer,
      $$BooksTableOrderingComposer,
      $$BooksTableAnnotationComposer,
      $$BooksTableCreateCompanionBuilder,
      $$BooksTableUpdateCompanionBuilder,
      (Book, $$BooksTableReferences),
      Book,
      PrefetchHooks Function({
        bool groupId,
        bool progressRefs,
        bool readingDaysRefs,
      })
    >;
typedef $$ProgressTableCreateCompanionBuilder = ProgressCompanion Function({
  required String bookId,
  required String locatorJson,
  required double percent,
  required int updatedAt,
  Value<bool> dirty,
  Value<int> rowid,
});
typedef $$ProgressTableUpdateCompanionBuilder = ProgressCompanion Function({
  Value<String> bookId,
  Value<String> locatorJson,
  Value<double> percent,
  Value<int> updatedAt,
  Value<bool> dirty,
  Value<int> rowid,
});

final class $$ProgressTableReferences
    extends BaseReferences<_$AppDatabase, $ProgressTable, BookProgress> {
  $$ProgressTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $BooksTable _bookIdTable(_$AppDatabase db) =>
      db.books.createAlias('progress__book_id__books__book_id');

  $$BooksTableProcessedTableManager get bookId {
    final $_column = $_itemColumn<String>('book_id')!;

    final manager = $$BooksTableTableManager(
      $_db,
      $_db.books,
    ).filter((f) => f.bookId.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_bookIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ProgressTableFilterComposer
    extends Composer<_$AppDatabase, $ProgressTable> {
  $$ProgressTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get locatorJson => $composableBuilder(
    column: $table.locatorJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get percent => $composableBuilder(
    column: $table.percent,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnFilters(column),
  );

  $$BooksTableFilterComposer get bookId {
    final $$BooksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.bookId,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.bookId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableFilterComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ProgressTableOrderingComposer
    extends Composer<_$AppDatabase, $ProgressTable> {
  $$ProgressTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get locatorJson => $composableBuilder(
    column: $table.locatorJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get percent => $composableBuilder(
    column: $table.percent,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnOrderings(column),
  );

  $$BooksTableOrderingComposer get bookId {
    final $$BooksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.bookId,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.bookId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableOrderingComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ProgressTableAnnotationComposer
    extends Composer<_$AppDatabase, $ProgressTable> {
  $$ProgressTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get locatorJson => $composableBuilder(
    column: $table.locatorJson,
    builder: (column) => column,
  );

  GeneratedColumn<double> get percent =>
      $composableBuilder(column: $table.percent, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<bool> get dirty =>
      $composableBuilder(column: $table.dirty, builder: (column) => column);

  $$BooksTableAnnotationComposer get bookId {
    final $$BooksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.bookId,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.bookId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableAnnotationComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ProgressTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ProgressTable,
          BookProgress,
          $$ProgressTableFilterComposer,
          $$ProgressTableOrderingComposer,
          $$ProgressTableAnnotationComposer,
          $$ProgressTableCreateCompanionBuilder,
          $$ProgressTableUpdateCompanionBuilder,
          (BookProgress, $$ProgressTableReferences),
          BookProgress,
          PrefetchHooks Function({bool bookId})
        > {
  $$ProgressTableTableManager(_$AppDatabase db, $ProgressTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ProgressTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ProgressTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ProgressTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> bookId = const Value.absent(),
                Value<String> locatorJson = const Value.absent(),
                Value<double> percent = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProgressCompanion(
                bookId: bookId,
                locatorJson: locatorJson,
                percent: percent,
                updatedAt: updatedAt,
                dirty: dirty,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String bookId,
                required String locatorJson,
                required double percent,
                required int updatedAt,
                Value<bool> dirty = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProgressCompanion.insert(
                bookId: bookId,
                locatorJson: locatorJson,
                percent: percent,
                updatedAt: updatedAt,
                dirty: dirty,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ProgressTable, BookProgress>(table),
                  $$ProgressTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({bookId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (bookId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.bookId,
                        referencedTable: $$ProgressTableReferences._bookIdTable(
                          db,
                        ),
                        referencedColumn: $$ProgressTableReferences
                            ._bookIdTable(db)
                            .bookId,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ProgressTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ProgressTable,
      BookProgress,
      $$ProgressTableFilterComposer,
      $$ProgressTableOrderingComposer,
      $$ProgressTableAnnotationComposer,
      $$ProgressTableCreateCompanionBuilder,
      $$ProgressTableUpdateCompanionBuilder,
      (BookProgress, $$ProgressTableReferences),
      BookProgress,
      PrefetchHooks Function({bool bookId})
    >;
typedef $$SyncStateTableCreateCompanionBuilder = SyncStateCompanion Function({
  required String bookId,
  required String backendKey,
  required int baseRev,
  Value<String?> remoteEtag,
  Value<String?> lastSyncedMetaJson,
  required int lastSyncedAt,
  Value<int> rowid,
});
typedef $$SyncStateTableUpdateCompanionBuilder = SyncStateCompanion Function({
  Value<String> bookId,
  Value<String> backendKey,
  Value<int> baseRev,
  Value<String?> remoteEtag,
  Value<String?> lastSyncedMetaJson,
  Value<int> lastSyncedAt,
  Value<int> rowid,
});

class $$SyncStateTableFilterComposer
    extends Composer<_$AppDatabase, $SyncStateTable> {
  $$SyncStateTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get backendKey => $composableBuilder(
    column: $table.backendKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get baseRev => $composableBuilder(
    column: $table.baseRev,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteEtag => $composableBuilder(
    column: $table.remoteEtag,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastSyncedMetaJson => $composableBuilder(
    column: $table.lastSyncedMetaJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastSyncedAt => $composableBuilder(
    column: $table.lastSyncedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncStateTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncStateTable> {
  $$SyncStateTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get backendKey => $composableBuilder(
    column: $table.backendKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get baseRev => $composableBuilder(
    column: $table.baseRev,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteEtag => $composableBuilder(
    column: $table.remoteEtag,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastSyncedMetaJson => $composableBuilder(
    column: $table.lastSyncedMetaJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastSyncedAt => $composableBuilder(
    column: $table.lastSyncedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncStateTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncStateTable> {
  $$SyncStateTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get bookId =>
      $composableBuilder(column: $table.bookId, builder: (column) => column);

  GeneratedColumn<String> get backendKey => $composableBuilder(
    column: $table.backendKey,
    builder: (column) => column,
  );

  GeneratedColumn<int> get baseRev =>
      $composableBuilder(column: $table.baseRev, builder: (column) => column);

  GeneratedColumn<String> get remoteEtag => $composableBuilder(
    column: $table.remoteEtag,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastSyncedMetaJson => $composableBuilder(
    column: $table.lastSyncedMetaJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastSyncedAt => $composableBuilder(
    column: $table.lastSyncedAt,
    builder: (column) => column,
  );
}

class $$SyncStateTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SyncStateTable,
          BookSyncState,
          $$SyncStateTableFilterComposer,
          $$SyncStateTableOrderingComposer,
          $$SyncStateTableAnnotationComposer,
          $$SyncStateTableCreateCompanionBuilder,
          $$SyncStateTableUpdateCompanionBuilder,
          (
            BookSyncState,
            BaseReferences<_$AppDatabase, $SyncStateTable, BookSyncState>,
          ),
          BookSyncState,
          PrefetchHooks Function()
        > {
  $$SyncStateTableTableManager(_$AppDatabase db, $SyncStateTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncStateTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncStateTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncStateTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> bookId = const Value.absent(),
                Value<String> backendKey = const Value.absent(),
                Value<int> baseRev = const Value.absent(),
                Value<String?> remoteEtag = const Value.absent(),
                Value<String?> lastSyncedMetaJson = const Value.absent(),
                Value<int> lastSyncedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncStateCompanion(
                bookId: bookId,
                backendKey: backendKey,
                baseRev: baseRev,
                remoteEtag: remoteEtag,
                lastSyncedMetaJson: lastSyncedMetaJson,
                lastSyncedAt: lastSyncedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String bookId,
                required String backendKey,
                required int baseRev,
                Value<String?> remoteEtag = const Value.absent(),
                Value<String?> lastSyncedMetaJson = const Value.absent(),
                required int lastSyncedAt,
                Value<int> rowid = const Value.absent(),
              }) => SyncStateCompanion.insert(
                bookId: bookId,
                backendKey: backendKey,
                baseRev: baseRev,
                remoteEtag: remoteEtag,
                lastSyncedMetaJson: lastSyncedMetaJson,
                lastSyncedAt: lastSyncedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SyncStateTable, BookSyncState>(table),
                  BaseReferences<_$AppDatabase, $SyncStateTable, BookSyncState>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncStateTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SyncStateTable,
      BookSyncState,
      $$SyncStateTableFilterComposer,
      $$SyncStateTableOrderingComposer,
      $$SyncStateTableAnnotationComposer,
      $$SyncStateTableCreateCompanionBuilder,
      $$SyncStateTableUpdateCompanionBuilder,
      (
        BookSyncState,
        BaseReferences<_$AppDatabase, $SyncStateTable, BookSyncState>,
      ),
      BookSyncState,
      PrefetchHooks Function()
    >;
typedef $$DeletedBooksTableCreateCompanionBuilder =
    DeletedBooksCompanion Function({
      required String bookId,
      required int deletedAt,
      Value<bool> pushed,
      required String contentHash,
      Value<int> rowid,
    });
typedef $$DeletedBooksTableUpdateCompanionBuilder =
    DeletedBooksCompanion Function({
      Value<String> bookId,
      Value<int> deletedAt,
      Value<bool> pushed,
      Value<String> contentHash,
      Value<int> rowid,
    });

class $$DeletedBooksTableFilterComposer
    extends Composer<_$AppDatabase, $DeletedBooksTable> {
  $$DeletedBooksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get pushed => $composableBuilder(
    column: $table.pushed,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentHash => $composableBuilder(
    column: $table.contentHash,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DeletedBooksTableOrderingComposer
    extends Composer<_$AppDatabase, $DeletedBooksTable> {
  $$DeletedBooksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get pushed => $composableBuilder(
    column: $table.pushed,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentHash => $composableBuilder(
    column: $table.contentHash,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DeletedBooksTableAnnotationComposer
    extends Composer<_$AppDatabase, $DeletedBooksTable> {
  $$DeletedBooksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get bookId =>
      $composableBuilder(column: $table.bookId, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<bool> get pushed =>
      $composableBuilder(column: $table.pushed, builder: (column) => column);

  GeneratedColumn<String> get contentHash => $composableBuilder(
    column: $table.contentHash,
    builder: (column) => column,
  );
}

class $$DeletedBooksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DeletedBooksTable,
          DeletedBook,
          $$DeletedBooksTableFilterComposer,
          $$DeletedBooksTableOrderingComposer,
          $$DeletedBooksTableAnnotationComposer,
          $$DeletedBooksTableCreateCompanionBuilder,
          $$DeletedBooksTableUpdateCompanionBuilder,
          (
            DeletedBook,
            BaseReferences<_$AppDatabase, $DeletedBooksTable, DeletedBook>,
          ),
          DeletedBook,
          PrefetchHooks Function()
        > {
  $$DeletedBooksTableTableManager(_$AppDatabase db, $DeletedBooksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DeletedBooksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DeletedBooksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DeletedBooksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> bookId = const Value.absent(),
                Value<int> deletedAt = const Value.absent(),
                Value<bool> pushed = const Value.absent(),
                Value<String> contentHash = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DeletedBooksCompanion(
                bookId: bookId,
                deletedAt: deletedAt,
                pushed: pushed,
                contentHash: contentHash,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String bookId,
                required int deletedAt,
                Value<bool> pushed = const Value.absent(),
                required String contentHash,
                Value<int> rowid = const Value.absent(),
              }) => DeletedBooksCompanion.insert(
                bookId: bookId,
                deletedAt: deletedAt,
                pushed: pushed,
                contentHash: contentHash,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$DeletedBooksTable, DeletedBook>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $DeletedBooksTable,
                    DeletedBook
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DeletedBooksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DeletedBooksTable,
      DeletedBook,
      $$DeletedBooksTableFilterComposer,
      $$DeletedBooksTableOrderingComposer,
      $$DeletedBooksTableAnnotationComposer,
      $$DeletedBooksTableCreateCompanionBuilder,
      $$DeletedBooksTableUpdateCompanionBuilder,
      (
        DeletedBook,
        BaseReferences<_$AppDatabase, $DeletedBooksTable, DeletedBook>,
      ),
      DeletedBook,
      PrefetchHooks Function()
    >;
typedef $$SyncCursorTableCreateCompanionBuilder = SyncCursorCompanion Function({
  required String backendKey,
  Value<String?> changesCursor,
  Value<String?> metaListingEtag,
  Value<int?> lastFullSyncAt,
  Value<int> quotaUpBytes,
  Value<int> quotaDownBytes,
  Value<String?> quotaMonth,
  Value<int> rowid,
});
typedef $$SyncCursorTableUpdateCompanionBuilder = SyncCursorCompanion Function({
  Value<String> backendKey,
  Value<String?> changesCursor,
  Value<String?> metaListingEtag,
  Value<int?> lastFullSyncAt,
  Value<int> quotaUpBytes,
  Value<int> quotaDownBytes,
  Value<String?> quotaMonth,
  Value<int> rowid,
});

class $$SyncCursorTableFilterComposer
    extends Composer<_$AppDatabase, $SyncCursorTable> {
  $$SyncCursorTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get backendKey => $composableBuilder(
    column: $table.backendKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get changesCursor => $composableBuilder(
    column: $table.changesCursor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get metaListingEtag => $composableBuilder(
    column: $table.metaListingEtag,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastFullSyncAt => $composableBuilder(
    column: $table.lastFullSyncAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get quotaUpBytes => $composableBuilder(
    column: $table.quotaUpBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get quotaDownBytes => $composableBuilder(
    column: $table.quotaDownBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get quotaMonth => $composableBuilder(
    column: $table.quotaMonth,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncCursorTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncCursorTable> {
  $$SyncCursorTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get backendKey => $composableBuilder(
    column: $table.backendKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get changesCursor => $composableBuilder(
    column: $table.changesCursor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get metaListingEtag => $composableBuilder(
    column: $table.metaListingEtag,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastFullSyncAt => $composableBuilder(
    column: $table.lastFullSyncAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get quotaUpBytes => $composableBuilder(
    column: $table.quotaUpBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get quotaDownBytes => $composableBuilder(
    column: $table.quotaDownBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get quotaMonth => $composableBuilder(
    column: $table.quotaMonth,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncCursorTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncCursorTable> {
  $$SyncCursorTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get backendKey => $composableBuilder(
    column: $table.backendKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get changesCursor => $composableBuilder(
    column: $table.changesCursor,
    builder: (column) => column,
  );

  GeneratedColumn<String> get metaListingEtag => $composableBuilder(
    column: $table.metaListingEtag,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastFullSyncAt => $composableBuilder(
    column: $table.lastFullSyncAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get quotaUpBytes => $composableBuilder(
    column: $table.quotaUpBytes,
    builder: (column) => column,
  );

  GeneratedColumn<int> get quotaDownBytes => $composableBuilder(
    column: $table.quotaDownBytes,
    builder: (column) => column,
  );

  GeneratedColumn<String> get quotaMonth => $composableBuilder(
    column: $table.quotaMonth,
    builder: (column) => column,
  );
}

class $$SyncCursorTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SyncCursorTable,
          SyncCursorRow,
          $$SyncCursorTableFilterComposer,
          $$SyncCursorTableOrderingComposer,
          $$SyncCursorTableAnnotationComposer,
          $$SyncCursorTableCreateCompanionBuilder,
          $$SyncCursorTableUpdateCompanionBuilder,
          (
            SyncCursorRow,
            BaseReferences<_$AppDatabase, $SyncCursorTable, SyncCursorRow>,
          ),
          SyncCursorRow,
          PrefetchHooks Function()
        > {
  $$SyncCursorTableTableManager(_$AppDatabase db, $SyncCursorTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncCursorTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncCursorTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncCursorTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> backendKey = const Value.absent(),
                Value<String?> changesCursor = const Value.absent(),
                Value<String?> metaListingEtag = const Value.absent(),
                Value<int?> lastFullSyncAt = const Value.absent(),
                Value<int> quotaUpBytes = const Value.absent(),
                Value<int> quotaDownBytes = const Value.absent(),
                Value<String?> quotaMonth = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncCursorCompanion(
                backendKey: backendKey,
                changesCursor: changesCursor,
                metaListingEtag: metaListingEtag,
                lastFullSyncAt: lastFullSyncAt,
                quotaUpBytes: quotaUpBytes,
                quotaDownBytes: quotaDownBytes,
                quotaMonth: quotaMonth,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String backendKey,
                Value<String?> changesCursor = const Value.absent(),
                Value<String?> metaListingEtag = const Value.absent(),
                Value<int?> lastFullSyncAt = const Value.absent(),
                Value<int> quotaUpBytes = const Value.absent(),
                Value<int> quotaDownBytes = const Value.absent(),
                Value<String?> quotaMonth = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncCursorCompanion.insert(
                backendKey: backendKey,
                changesCursor: changesCursor,
                metaListingEtag: metaListingEtag,
                lastFullSyncAt: lastFullSyncAt,
                quotaUpBytes: quotaUpBytes,
                quotaDownBytes: quotaDownBytes,
                quotaMonth: quotaMonth,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SyncCursorTable, SyncCursorRow>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $SyncCursorTable,
                    SyncCursorRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncCursorTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SyncCursorTable,
      SyncCursorRow,
      $$SyncCursorTableFilterComposer,
      $$SyncCursorTableOrderingComposer,
      $$SyncCursorTableAnnotationComposer,
      $$SyncCursorTableCreateCompanionBuilder,
      $$SyncCursorTableUpdateCompanionBuilder,
      (
        SyncCursorRow,
        BaseReferences<_$AppDatabase, $SyncCursorTable, SyncCursorRow>,
      ),
      SyncCursorRow,
      PrefetchHooks Function()
    >;
typedef $$ReaderSettingsTableCreateCompanionBuilder =
    ReaderSettingsCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$ReaderSettingsTableUpdateCompanionBuilder =
    ReaderSettingsCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$ReaderSettingsTableFilterComposer
    extends Composer<_$AppDatabase, $ReaderSettingsTable> {
  $$ReaderSettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ReaderSettingsTableOrderingComposer
    extends Composer<_$AppDatabase, $ReaderSettingsTable> {
  $$ReaderSettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ReaderSettingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ReaderSettingsTable> {
  $$ReaderSettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$ReaderSettingsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ReaderSettingsTable,
          ReaderSettingsEntry,
          $$ReaderSettingsTableFilterComposer,
          $$ReaderSettingsTableOrderingComposer,
          $$ReaderSettingsTableAnnotationComposer,
          $$ReaderSettingsTableCreateCompanionBuilder,
          $$ReaderSettingsTableUpdateCompanionBuilder,
          (
            ReaderSettingsEntry,
            BaseReferences<
              _$AppDatabase,
              $ReaderSettingsTable,
              ReaderSettingsEntry
            >,
          ),
          ReaderSettingsEntry,
          PrefetchHooks Function()
        > {
  $$ReaderSettingsTableTableManager(
    _$AppDatabase db,
    $ReaderSettingsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ReaderSettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ReaderSettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ReaderSettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => ReaderSettingsCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => ReaderSettingsCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ReaderSettingsTable, ReaderSettingsEntry>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $ReaderSettingsTable,
                    ReaderSettingsEntry
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ReaderSettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ReaderSettingsTable,
      ReaderSettingsEntry,
      $$ReaderSettingsTableFilterComposer,
      $$ReaderSettingsTableOrderingComposer,
      $$ReaderSettingsTableAnnotationComposer,
      $$ReaderSettingsTableCreateCompanionBuilder,
      $$ReaderSettingsTableUpdateCompanionBuilder,
      (
        ReaderSettingsEntry,
        BaseReferences<
          _$AppDatabase,
          $ReaderSettingsTable,
          ReaderSettingsEntry
        >,
      ),
      ReaderSettingsEntry,
      PrefetchHooks Function()
    >;
typedef $$SyncQueueTableCreateCompanionBuilder = SyncQueueCompanion Function({
  Value<int> id,
  required String bookId,
  required String op,
  required int enqueuedAt,
  Value<int> attempts,
});
typedef $$SyncQueueTableUpdateCompanionBuilder = SyncQueueCompanion Function({
  Value<int> id,
  Value<String> bookId,
  Value<String> op,
  Value<int> enqueuedAt,
  Value<int> attempts,
});

class $$SyncQueueTableFilterComposer
    extends Composer<_$AppDatabase, $SyncQueueTable> {
  $$SyncQueueTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get op => $composableBuilder(
    column: $table.op,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get enqueuedAt => $composableBuilder(
    column: $table.enqueuedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attempts => $composableBuilder(
    column: $table.attempts,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncQueueTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncQueueTable> {
  $$SyncQueueTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get op => $composableBuilder(
    column: $table.op,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get enqueuedAt => $composableBuilder(
    column: $table.enqueuedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attempts => $composableBuilder(
    column: $table.attempts,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncQueueTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncQueueTable> {
  $$SyncQueueTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get bookId =>
      $composableBuilder(column: $table.bookId, builder: (column) => column);

  GeneratedColumn<String> get op =>
      $composableBuilder(column: $table.op, builder: (column) => column);

  GeneratedColumn<int> get enqueuedAt => $composableBuilder(
    column: $table.enqueuedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get attempts =>
      $composableBuilder(column: $table.attempts, builder: (column) => column);
}

class $$SyncQueueTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SyncQueueTable,
          SyncQueueEntry,
          $$SyncQueueTableFilterComposer,
          $$SyncQueueTableOrderingComposer,
          $$SyncQueueTableAnnotationComposer,
          $$SyncQueueTableCreateCompanionBuilder,
          $$SyncQueueTableUpdateCompanionBuilder,
          (
            SyncQueueEntry,
            BaseReferences<_$AppDatabase, $SyncQueueTable, SyncQueueEntry>,
          ),
          SyncQueueEntry,
          PrefetchHooks Function()
        > {
  $$SyncQueueTableTableManager(_$AppDatabase db, $SyncQueueTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncQueueTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncQueueTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncQueueTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> bookId = const Value.absent(),
                Value<String> op = const Value.absent(),
                Value<int> enqueuedAt = const Value.absent(),
                Value<int> attempts = const Value.absent(),
              }) => SyncQueueCompanion(
                id: id,
                bookId: bookId,
                op: op,
                enqueuedAt: enqueuedAt,
                attempts: attempts,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String bookId,
                required String op,
                required int enqueuedAt,
                Value<int> attempts = const Value.absent(),
              }) => SyncQueueCompanion.insert(
                id: id,
                bookId: bookId,
                op: op,
                enqueuedAt: enqueuedAt,
                attempts: attempts,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SyncQueueTable, SyncQueueEntry>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $SyncQueueTable,
                    SyncQueueEntry
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncQueueTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SyncQueueTable,
      SyncQueueEntry,
      $$SyncQueueTableFilterComposer,
      $$SyncQueueTableOrderingComposer,
      $$SyncQueueTableAnnotationComposer,
      $$SyncQueueTableCreateCompanionBuilder,
      $$SyncQueueTableUpdateCompanionBuilder,
      (
        SyncQueueEntry,
        BaseReferences<_$AppDatabase, $SyncQueueTable, SyncQueueEntry>,
      ),
      SyncQueueEntry,
      PrefetchHooks Function()
    >;
typedef $$ReadingDaysTableCreateCompanionBuilder =
    ReadingDaysCompanion Function({
      required String bookId,
      required String day,
      Value<int> seconds,
      Value<int> rowid,
    });
typedef $$ReadingDaysTableUpdateCompanionBuilder =
    ReadingDaysCompanion Function({
      Value<String> bookId,
      Value<String> day,
      Value<int> seconds,
      Value<int> rowid,
    });

final class $$ReadingDaysTableReferences
    extends BaseReferences<_$AppDatabase, $ReadingDaysTable, ReadingDay> {
  $$ReadingDaysTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $BooksTable _bookIdTable(_$AppDatabase db) =>
      db.books.createAlias('reading_days__book_id__books__book_id');

  $$BooksTableProcessedTableManager get bookId {
    final $_column = $_itemColumn<String>('book_id')!;

    final manager = $$BooksTableTableManager(
      $_db,
      $_db.books,
    ).filter((f) => f.bookId.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_bookIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ReadingDaysTableFilterComposer
    extends Composer<_$AppDatabase, $ReadingDaysTable> {
  $$ReadingDaysTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get day => $composableBuilder(
    column: $table.day,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get seconds => $composableBuilder(
    column: $table.seconds,
    builder: (column) => ColumnFilters(column),
  );

  $$BooksTableFilterComposer get bookId {
    final $$BooksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.bookId,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.bookId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableFilterComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ReadingDaysTableOrderingComposer
    extends Composer<_$AppDatabase, $ReadingDaysTable> {
  $$ReadingDaysTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get day => $composableBuilder(
    column: $table.day,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get seconds => $composableBuilder(
    column: $table.seconds,
    builder: (column) => ColumnOrderings(column),
  );

  $$BooksTableOrderingComposer get bookId {
    final $$BooksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.bookId,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.bookId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableOrderingComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ReadingDaysTableAnnotationComposer
    extends Composer<_$AppDatabase, $ReadingDaysTable> {
  $$ReadingDaysTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get day =>
      $composableBuilder(column: $table.day, builder: (column) => column);

  GeneratedColumn<int> get seconds =>
      $composableBuilder(column: $table.seconds, builder: (column) => column);

  $$BooksTableAnnotationComposer get bookId {
    final $$BooksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.bookId,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.bookId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableAnnotationComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ReadingDaysTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ReadingDaysTable,
          ReadingDay,
          $$ReadingDaysTableFilterComposer,
          $$ReadingDaysTableOrderingComposer,
          $$ReadingDaysTableAnnotationComposer,
          $$ReadingDaysTableCreateCompanionBuilder,
          $$ReadingDaysTableUpdateCompanionBuilder,
          (ReadingDay, $$ReadingDaysTableReferences),
          ReadingDay,
          PrefetchHooks Function({bool bookId})
        > {
  $$ReadingDaysTableTableManager(_$AppDatabase db, $ReadingDaysTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ReadingDaysTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ReadingDaysTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ReadingDaysTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> bookId = const Value.absent(),
                Value<String> day = const Value.absent(),
                Value<int> seconds = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ReadingDaysCompanion(
                bookId: bookId,
                day: day,
                seconds: seconds,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String bookId,
                required String day,
                Value<int> seconds = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ReadingDaysCompanion.insert(
                bookId: bookId,
                day: day,
                seconds: seconds,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ReadingDaysTable, ReadingDay>(table),
                  $$ReadingDaysTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({bookId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (bookId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.bookId,
                        referencedTable: $$ReadingDaysTableReferences
                            ._bookIdTable(db),
                        referencedColumn: $$ReadingDaysTableReferences
                            ._bookIdTable(db)
                            .bookId,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ReadingDaysTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ReadingDaysTable,
      ReadingDay,
      $$ReadingDaysTableFilterComposer,
      $$ReadingDaysTableOrderingComposer,
      $$ReadingDaysTableAnnotationComposer,
      $$ReadingDaysTableCreateCompanionBuilder,
      $$ReadingDaysTableUpdateCompanionBuilder,
      (ReadingDay, $$ReadingDaysTableReferences),
      ReadingDay,
      PrefetchHooks Function({bool bookId})
    >;
typedef $$LocalOnlyBooksTableCreateCompanionBuilder =
    LocalOnlyBooksCompanion Function({
      required String bookId,
      Value<int> createdAt,
      Value<int> rowid,
    });
typedef $$LocalOnlyBooksTableUpdateCompanionBuilder =
    LocalOnlyBooksCompanion Function({
      Value<String> bookId,
      Value<int> createdAt,
      Value<int> rowid,
    });

class $$LocalOnlyBooksTableFilterComposer
    extends Composer<_$AppDatabase, $LocalOnlyBooksTable> {
  $$LocalOnlyBooksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalOnlyBooksTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalOnlyBooksTable> {
  $$LocalOnlyBooksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get bookId => $composableBuilder(
    column: $table.bookId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalOnlyBooksTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalOnlyBooksTable> {
  $$LocalOnlyBooksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get bookId =>
      $composableBuilder(column: $table.bookId, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$LocalOnlyBooksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalOnlyBooksTable,
          LocalOnlyBook,
          $$LocalOnlyBooksTableFilterComposer,
          $$LocalOnlyBooksTableOrderingComposer,
          $$LocalOnlyBooksTableAnnotationComposer,
          $$LocalOnlyBooksTableCreateCompanionBuilder,
          $$LocalOnlyBooksTableUpdateCompanionBuilder,
          (
            LocalOnlyBook,
            BaseReferences<_$AppDatabase, $LocalOnlyBooksTable, LocalOnlyBook>,
          ),
          LocalOnlyBook,
          PrefetchHooks Function()
        > {
  $$LocalOnlyBooksTableTableManager(
    _$AppDatabase db,
    $LocalOnlyBooksTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalOnlyBooksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalOnlyBooksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalOnlyBooksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> bookId = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalOnlyBooksCompanion(
                bookId: bookId,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String bookId,
                Value<int> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalOnlyBooksCompanion.insert(
                bookId: bookId,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LocalOnlyBooksTable, LocalOnlyBook>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $LocalOnlyBooksTable,
                    LocalOnlyBook
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalOnlyBooksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalOnlyBooksTable,
      LocalOnlyBook,
      $$LocalOnlyBooksTableFilterComposer,
      $$LocalOnlyBooksTableOrderingComposer,
      $$LocalOnlyBooksTableAnnotationComposer,
      $$LocalOnlyBooksTableCreateCompanionBuilder,
      $$LocalOnlyBooksTableUpdateCompanionBuilder,
      (
        LocalOnlyBook,
        BaseReferences<_$AppDatabase, $LocalOnlyBooksTable, LocalOnlyBook>,
      ),
      LocalOnlyBook,
      PrefetchHooks Function()
    >;
typedef $$AppSettingsTableCreateCompanionBuilder =
    AppSettingsCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$AppSettingsTableUpdateCompanionBuilder =
    AppSettingsCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$AppSettingsTableFilterComposer
    extends Composer<_$AppDatabase, $AppSettingsTable> {
  $$AppSettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AppSettingsTableOrderingComposer
    extends Composer<_$AppDatabase, $AppSettingsTable> {
  $$AppSettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AppSettingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AppSettingsTable> {
  $$AppSettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$AppSettingsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AppSettingsTable,
          AppSetting,
          $$AppSettingsTableFilterComposer,
          $$AppSettingsTableOrderingComposer,
          $$AppSettingsTableAnnotationComposer,
          $$AppSettingsTableCreateCompanionBuilder,
          $$AppSettingsTableUpdateCompanionBuilder,
          (
            AppSetting,
            BaseReferences<_$AppDatabase, $AppSettingsTable, AppSetting>,
          ),
          AppSetting,
          PrefetchHooks Function()
        > {
  $$AppSettingsTableTableManager(_$AppDatabase db, $AppSettingsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AppSettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AppSettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AppSettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => AppSettingsCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => AppSettingsCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AppSettingsTable, AppSetting>(table),
                  BaseReferences<_$AppDatabase, $AppSettingsTable, AppSetting>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AppSettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AppSettingsTable,
      AppSetting,
      $$AppSettingsTableFilterComposer,
      $$AppSettingsTableOrderingComposer,
      $$AppSettingsTableAnnotationComposer,
      $$AppSettingsTableCreateCompanionBuilder,
      $$AppSettingsTableUpdateCompanionBuilder,
      (
        AppSetting,
        BaseReferences<_$AppDatabase, $AppSettingsTable, AppSetting>,
      ),
      AppSetting,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$BookGroupsTableTableManager get bookGroups =>
      $$BookGroupsTableTableManager(_db, _db.bookGroups);
  $$BooksTableTableManager get books =>
      $$BooksTableTableManager(_db, _db.books);
  $$ProgressTableTableManager get progress =>
      $$ProgressTableTableManager(_db, _db.progress);
  $$SyncStateTableTableManager get syncState =>
      $$SyncStateTableTableManager(_db, _db.syncState);
  $$DeletedBooksTableTableManager get deletedBooks =>
      $$DeletedBooksTableTableManager(_db, _db.deletedBooks);
  $$SyncCursorTableTableManager get syncCursor =>
      $$SyncCursorTableTableManager(_db, _db.syncCursor);
  $$ReaderSettingsTableTableManager get readerSettings =>
      $$ReaderSettingsTableTableManager(_db, _db.readerSettings);
  $$SyncQueueTableTableManager get syncQueue =>
      $$SyncQueueTableTableManager(_db, _db.syncQueue);
  $$ReadingDaysTableTableManager get readingDays =>
      $$ReadingDaysTableTableManager(_db, _db.readingDays);
  $$LocalOnlyBooksTableTableManager get localOnlyBooks =>
      $$LocalOnlyBooksTableTableManager(_db, _db.localOnlyBooks);
  $$AppSettingsTableTableManager get appSettings =>
      $$AppSettingsTableTableManager(_db, _db.appSettings);
}
