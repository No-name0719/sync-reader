/// SyncReader 同步核心（纯 Dart，无 Flutter 依赖）。
///
/// 目录职责（CLAUDE.md §3 / docs/03 §2）：
/// - `src/model/`     领域模型：BookMeta、Locator、SyncError 等（schema 见 docs/05）
/// - `src/engine/`    同步引擎与状态机（docs/04 §4）
/// - `src/diff/`      差异计算（docs/04 §5）
/// - `src/conflict/`  冲突合并 LWW（docs/04 §6）
/// - `src/transfer/`  传输队列：限流/重试/断点（docs/04 §8）
/// - `src/store/`     持久化纯接口（sync_state/deleted_books/sync_cursor/书库，docs/05 §5）
/// - `src/backend/`   BackendAdapter 接口 + memory/（参考实现）+ webdav/ + rest/（docs/03 §4.3）
library;

export 'src/backend/backend_adapter.dart';
export 'src/backend/memory/in_memory_adapter.dart';
export 'src/backend/webdav/webdav_adapter.dart';
export 'src/conflict/conflict_resolver.dart';
export 'src/diff/diff_engine.dart';
export 'src/diff/group_diff_engine.dart';
export 'src/diff/group_merger.dart';
export 'src/engine/sync_engine.dart';
export 'src/model/book_meta.dart';
export 'src/model/group_meta.dart';
export 'src/model/locator.dart';
export 'src/model/sync_error.dart';
export 'src/store/in_memory_store.dart';
export 'src/store/local_library.dart';
export 'src/store/sync_store.dart';
export 'src/transfer/transfer_queue.dart';
