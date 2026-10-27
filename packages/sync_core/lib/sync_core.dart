/// SyncReader 同步核心（纯 Dart，无 Flutter 依赖）。
///
/// 目录职责（CLAUDE.md §3 / docs/03 §2）：
/// - `src/model/`     领域模型：BookMeta、Locator、Tombstone 等（schema 见 docs/05）
/// - `src/engine/`    同步引擎与状态机（docs/04 §4）
/// - `src/diff/`      差异计算（docs/04 §5）
/// - `src/conflict/`  冲突合并 LWW（docs/04 §6）
/// - `src/transfer/`  传输队列：限流/重试/断点（docs/04 §8）
/// - `src/backend/`   BackendAdapter 接口 + webdav/ + rest/ 适配器（docs/03 §4.3）
library;

export 'src/backend/backend_adapter.dart';
export 'src/model/book_meta.dart';
export 'src/model/locator.dart';
