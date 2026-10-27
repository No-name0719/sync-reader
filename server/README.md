# server —— SyncReader 自建服务端

Go 单二进制 + SQLite（modernc 纯 Go 驱动），自定义 REST API（非 WebDAV 兼容）。
只做带 CAS 乐观锁的元数据存储、增量游标、正文托管与设备级鉴权；**冲突裁决在客户端**。

- API 规格：[`docs/06-自建服务端设计与部署.md`](../docs/06-自建服务端设计与部署.md)
- 本地运行：`go run ./cmd/server`（环境变量 `PORT` / `DATA_DIR` / `SINGLE_USER`，默认 8080 + ./data）
- 管理 CLI：`go run ./cmd/serverctl`（user/devices/backup/reindex，M3 实现）
- 部署：`deploy/`（Dockerfile / docker-compose / Caddyfile / systemd）
