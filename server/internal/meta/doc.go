// Package meta 实现元数据的版本化存储：PUT 带 If-Match: "rev:{n}" 的 CAS 乐观锁
// （冲突返回 409 + 服务端当前副本）、全局 seq 分配与增量查询（GET /sync/changes?cursor）。
// 服务端不做冲突合并——那是客户端 sync_core 的职责。M3 里程碑实现。
package meta
