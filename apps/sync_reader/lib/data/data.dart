/// 数据层（docs/03 §2）：
/// - `db/`     drift 表、DAO、迁移（docs/05 §5 DDL 的权威转写）
/// - `files/`  书籍/封面文件存取
/// - `secure/` 凭据读写封装（CredentialStore，M2 随同步接入实现）
library;

export 'db/app_database.dart';
export 'db/daos/books_dao.dart';
export 'db/daos/progress_dao.dart';
export 'db/daos/reader_settings_dao.dart';
export 'db/daos/sync_queue_dao.dart';
export 'db/tables.dart';
export 'files/book_file_store.dart';
