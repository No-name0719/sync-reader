/// drift 表定义（docs/05 §5 本地 SQLite DDL 的权威转写）。
///
/// 约束：
/// - 列名/索引名必须与 docs/05 §5 DDL 完全一致（SQLite 表结构是同步语义的一部分）；
/// - schemaVersion 从 1 开始，迁移只增不删（docs/05 §6）；
/// - epoch 毫秒统一用 INTEGER 存储（与云端 ISO-8601 字符串换算发生在同步层）。
library;

import 'package:drift/drift.dart';

/// 书籍主表：云端 meta 的本地投影 + 本地文件指针（docs/05 §5 books）。
@DataClassName('Book')
@TableIndex(name: 'idx_books_last_read', columns: {#lastReadAt})
@TableIndex(name: 'idx_books_title', columns: {#title})
class Books extends Table {
  /// ULID 主键（docs/05 §4.1）。
  TextColumn get bookId => text()();

  /// 书名（epub 取 OPF dc:title，否则文件名去扩展名）。
  TextColumn get title => text()();

  /// 作者，可为空串。
  TextColumn get author => text().withDefault(const Constant(''))();

  /// 格式：txt | epub | md | pdf（自由字符串，docs/05 §3.2）。
  TextColumn get format => text()();

  /// 原始文件名（恢复导出用）。
  TextColumn get fileName => text()();

  /// 本地正文路径；NULL = 占位书（云端有、本地无）。
  TextColumn get localPath => text().nullable()();

  /// 正文全量哈希，`sha256:<hex>`（去重与完整性核心）。
  TextColumn get contentHash => text()();

  /// 正文字节数。
  IntColumn get sizeBytes => integer()();

  /// 本地封面路径（可空；封面不上云，各端自行生成）。
  TextColumn get coverPath => text().nullable()();

  /// 目录指纹 `tfp:<16hex>`（解析结果不一致时进度降级用）。
  TextColumn get tocFingerprint => text()();

  /// 入库时间（epoch ms，"添加时间"排序依据）。
  IntColumn get addedAt => integer()();

  /// 最近阅读时间（epoch ms；从未阅读为 NULL；NULL 在 DESC 排序中排最后）。
  IntColumn get lastReadAt => integer().nullable()();

  /// 累计阅读秒数（冲突时求和合并，docs/04 §6.3）。
  IntColumn get totalSeconds => integer().withDefault(const Constant(0))();

  /// 所属分组（FR-107 本地列，不参与同步、不入云端 meta）；NULL = 未分组。
  /// 分组删除时由外键置回未分组。
  TextColumn get groupId => text().references(BookGroups, #groupId, onDelete: KeyAction.setNull).nullable()();

  @override
  Set<Column> get primaryKey => {bookId};
}

/// 阅读进度表：本地实时值，push 前与云端 meta 对齐（docs/05 §5 progress）。
@DataClassName('BookProgress')
class Progress extends Table {
  /// 所属书籍（级联删除）。
  TextColumn get bookId =>
      text().references(Books, #bookId, onDelete: KeyAction.cascade)();

  /// docs/05 §3.3 判别联合 JSON 原样存储（逻辑坐标，禁止物理页码）。
  TextColumn get locatorJson => text()();

  /// 全书阅读比例 0.0–1.0（跨格式统一展示 + 降级恢复用）。
  RealColumn get percent => real()();

  /// 最近进度更新时间（epoch ms）。
  IntColumn get updatedAt => integer()();

  /// 1 = 待上传（同步队列的脏标记）。
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {bookId};
}

/// 同步状态：每本书 × 每后端一行（docs/05 §5 sync_state，M2 使用）。
@DataClassName('BookSyncState')
class SyncState extends Table {
  TextColumn get bookId => text()();

  /// 'webdav' | 'server:{libraryId}'（docs/05 §5 注释）。
  TextColumn get backendKey => text()();

  /// 已确认的远端 rev（乐观锁基线）。
  IntColumn get baseRev => integer()();

  /// WebDAV 条件请求用的 ETag。
  TextColumn get remoteEtag => text().nullable()();

  /// 上次同步的 meta 副本 = 冲突合并的公共祖先（docs/04 §6.3）。
  TextColumn get lastSyncedMetaJson => text().nullable()();

  /// 上次同步时间（epoch ms）。
  IntColumn get lastSyncedAt => integer()();

  @override
  Set<Column> get primaryKey => {bookId, backendKey};
}

/// tombstone 本地账本：删除同步与 GC（docs/05 §5 deleted_books，M2 使用）。
@DataClassName('DeletedBook')
class DeletedBooks extends Table {
  TextColumn get bookId => text()();

  /// 删除时间（epoch ms，GC 依据：90 天）。
  IntColumn get deletedAt => integer()();

  /// tombstone 是否已上云。
  BoolColumn get pushed => boolean().withDefault(const Constant(false))();

  /// 游离文件重关联时比对哈希用。
  TextColumn get contentHash => text()();

  @override
  Set<Column> get primaryKey => {bookId};
}

/// 同步游标与全局状态：每后端一行（docs/05 §5 sync_cursor，M2 使用）。
@DataClassName('SyncCursorRow')
class SyncCursor extends Table {
  TextColumn get backendKey => text()();

  /// REST 模式服务端游标。
  TextColumn get changesCursor => text().nullable()();

  /// WebDAV PROPFIND 响应 ETag（无则全量列）。
  TextColumn get metaListingEtag => text().nullable()();

  /// 上次全量同步时间（epoch ms）。
  IntColumn get lastFullSyncAt => integer().nullable()();

  /// 本自然月对坚果云上行累计（docs/04 §8.3）。
  IntColumn get quotaUpBytes => integer().withDefault(const Constant(0))();

  /// 本自然月下行累计。
  IntColumn get quotaDownBytes => integer().withDefault(const Constant(0))();

  /// 配额累计所属月份（如 '2026-10'）。
  TextColumn get quotaMonth => text().nullable()();

  @override
  Set<Column> get primaryKey => {backendKey};
}

/// 阅读偏好（仅本地，不同步，docs/05 §5 reader_settings）：key-value，值为 JSON 文本。
@DataClassName('ReaderSettingsEntry')
class ReaderSettings extends Table {
  /// 设置键（如 'reader_settings' 单键整体存取，或后续分键）。
  TextColumn get key => text()();

  /// JSON 序列化的值。
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// 待同步队列：重启后恢复（docs/05 §5 sync_queue，M2 使用）。
@DataClassName('SyncQueueEntry')
class SyncQueue extends Table {
  /// 自增主键（FIFO 序）。
  IntColumn get id => integer().autoIncrement()();

  TextColumn get bookId => text()();

  /// 'meta' | 'book_upload'（docs/05 §5 注释）。
  TextColumn get op => text()();

  /// 入队时间（epoch ms）。
  IntColumn get enqueuedAt => integer()();

  /// 重试次数。
  IntColumn get attempts => integer().withDefault(const Constant(0))();
}

/// 阅读时长按天统计（FR-208，M4 补做）：每书 × 每自然日一行，秒数累加。
/// 仅本地表，不参与云端同步；schemaVersion 2 新增（迁移只增不删，docs/05 §6）。
@DataClassName('ReadingDay')
class ReadingDays extends Table {
  /// 所属书籍（级联删除）。
  TextColumn get bookId => text().references(Books, #bookId, onDelete: KeyAction.cascade)();

  /// 本地自然日，格式 'YYYY-MM-DD'（设备时区）。
  TextColumn get day => text()();

  /// 当天累计阅读秒数。
  IntColumn get seconds => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {bookId, day};
}

/// 书籍分组（FR-107，本地分类，v1 不参与同步、不入云端 meta）。
@DataClassName('BookGroup')
class BookGroups extends Table {
  /// ULID 主键（复用 lib/core/ulid.dart）。
  TextColumn get groupId => text()();

  /// 分组名（非空；重名校验在 DAO/UI 层做）。
  TextColumn get name => text()();

  /// 排序权重（按创建顺序递增）。
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// 创建时间（epoch ms）。
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {groupId};
}
