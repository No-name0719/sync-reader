# sync_reader —— SyncReader 客户端

跨平台电子书进度同步阅读应用（P0：Android / Windows；P1：iPad/macOS/Linux）。

- 设计基线：[`docs/`](../../docs/)（需求 `01`、架构 `03`、同步 `04`、schema `05`）
- 代码分层：`lib/app`（入口/路由/主题）、`core`（通用基础）、`features`（按界面：library/reader/sync/onboarding）、`data`（drift/文件/凭据）——见 `docs/03 §2`
- 命令：`flutter analyze`（零告警）→ `flutter test` → `flutter run`（Windows 需先装 VS Build Tools，见 `docs/08 §4`）
