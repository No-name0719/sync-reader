import 'package:sync_core/sync_core.dart';

/// BackendAdapter 契约测试套件类型（CLAUDE.md §4.4 / NFR-08）。
///
/// **同一套用例必须同时跑 WebDAV 与 REST 两个适配器**：M2 实现 WebDAV 适配器、
/// M3 实现 REST 适配器时，各自在 `test/contract/webdav_test.dart` /
/// `rest_test.dart` 中以工厂函数注入本套件，用例本身不得分叉。
///
/// 用例清单（对齐 docs/04 §5/§7/§8 与 docs/06 §2）——M2/M3 实现时逐项落地：
///
/// 1. ensureLayout 幂等：连跑两次，目录布局与 library.json 一致（docs/05 §1）；
/// 2. listMetas：空库返回空清单；写入 N 本后返回 N 条 stub（含 rev/etag）；
/// 3. getMeta 条件请求：ifNoneMatch 命中返回 null（304 语义）；
/// 4. putMeta 乐观锁：expectedRev 落后时抛 RevConflict 且携带服务端副本（docs/06 §2.2）；
/// 5. putTombstone：写入后 listMetas 标记 deleted=true（docs/04 §7）；
/// 6. uploadBook 幂等：同 hash 二次上传跳过；hash 不符报错；
/// 7. downloadBook Range：startByte 续传字节流与原文件后缀一致（docs/04 §8.2）；
/// 8. 并发写不同书互不冲突；并发写同本书由调用方串行化。
typedef AdapterFactory = Future<BackendAdapter> Function();
