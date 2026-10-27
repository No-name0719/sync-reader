# CLAUDE.md — SyncReader 项目上下文

> 面向后续 AI 编码会话的项目说明。**当前阶段：M2 同步上线开发完成（坚果云真实联调待用户），下一站 M3。** 开工前请先通读本文与 `docs/` 设计基线。

## 1. 项目一句话

跨平台电子书进度同步阅读应用（工作名 **SyncReader**）：免费、无容量限制；多端（Android 手机/平板、Windows；P1：iPad/macOS/Linux）共享同一书库与阅读进度；同步通道由用户自己的坚果云（WebDAV）或自建服务器（REST）承载，软件本身不提供云服务。

## 2. 技术栈（已定论，勿随意更换；对比依据见 `docs/02-技术选型.md`）

| 层 | 选型 |
| --- | --- |
| 客户端框架 | Flutter（Dart 3 stable）；P0 = Android 8+ / Windows 10 1809+，P1 = iPad/macOS/Linux（选型已验证可达） |
| 状态/路由 | Riverpod + go_router |
| 渲染 | txt：自研（编码检测+章节切分+TextPainter 分页）；md：flutter_markdown_plus；epub：epub_pro 解析 + flutter_widget_from_html + 自研分页；pdf：pdfrx（pdfium）。**禁止引入 WebView 依赖**（兜底方案除外，见 07-R2） |
| 本地存储 | drift（SQLite，WAL）管元数据/进度/同步状态；正文文件在应用私有目录 |
| 安全存储 | flutter_secure_storage（Keystore/DPAPI/Keychain），凭据禁止落 SQLite/日志 |
| 同步核心 | `packages/sync_core`（纯 Dart 包，无 Flutter 依赖）：状态机 + diff + LWW(rev→updatedAt→deviceId) 冲突合并 + tombstone 删除 |
| 后端抽象 | `BackendAdapter` 统一接口；实现 A：WebDAV（坚果云，dio 自研薄客户端）；实现 B：REST（自建） |
| 服务端 | Go（chi + modernc.org/sqlite + golang-jwt），单二进制/Docker；**自定义 REST API**（不是 WebDAV 兼容）；不做冲突裁决（仅 CAS） |

## 3. 目录结构（规划；编码时按此创建）

```
sync-reader/
├── docs/                # 设计基线（8 份，改动需求/设计须同步更新对应文档）
├── apps/sync_reader/    # Flutter 客户端（lib/ 下 app/core/features/data/shared）
├── packages/sync_core/  # 纯 Dart 同步核心（engine/diff/conflict/transfer/backend/model）
├── server/              # Go 服务端（cmd/internal/deploy: Dockerfile、compose、Caddyfile、systemd）
├── CLAUDE.md            # 本文件
└── AGENT.md             # 指向本文件
```

## 4. 关键设计约定（编码前必读）

1. **本地优先**：同步是异步旁路，任何同步失败不得影响本地阅读/导入/删除。
2. **元数据先行**：日常同步只传 KB 级 meta JSON；正文按需下载（占位书机制）。流量规则与坚果云配额闸门见 `docs/04-同步引擎与冲突解决.md` §8。
3. **冲突规则**：`(rev, updatedAt, deviceId)` 定序 LWW；rev 由写端持久计数器单调递增；`totalSeconds` 求和特例；删除=tombstone，**永不自动删正文**，本地多出的书保留为游离文件。
4. **两种后端语义一致**：所有同步逻辑写在 sync_core，适配器只做传输；sync_core 契约测试必须同时跑 WebDAV 与 REST 两个适配器（同一套用例）。
5. **元数据 schema**：以 `docs/05-元数据Schema与云端目录布局.md` 为唯一权威；`schemaVersion` 演进规则（只增不删、读方容忍未知字段）不得违反；进度 locator 记录逻辑坐标（章节+字符偏移），禁止记录物理页码。
6. **凭据安全**：WebDAV 账号/应用密码、服务器 token 只进系统安全存储；日志强制脱敏。
7. **免费开源**：禁止引入任何付费依赖或云服务 SDK。

## 5. 开发约定

- 语言：文档、注释、提交信息用**中文**；代码标识符用英文。
- Dart：`flutter analyze` 零告警；`dart format`；lint 用 `flutter_lints` 起步。
- Go：`gofmt` + `go vet`；错误必须显式处理。
- 测试：sync_core 单元测试覆盖 diff/冲突/重试全部规则表（04 §5.1、§6、§8.4 每行一个用例）；服务端 API 有集成测试。
- 提交：Conventional Commits（`feat/fix/docs/refactor/test/chore`）；分支 `main` + 特性分支。
- 每完成一个里程碑：更新本文 §7 的"当前进度"，并核对 `docs/00-总览.md` §4 路线图。

## 6. 禁止事项

- 不要初始化/操作 git 远端、不要引入付费服务、不要在客户端内置任何账号体系或遥测。
- 不要绕过 sync_core 直接在 UI 层发同步请求。
- 不要在未更新 `docs/07-风险与待确认问题.md` 的情况下引入新的隐含假设。

## 7. 当前进度

| 阶段 | 状态 |
| --- | --- |
| 规划文档（docs/00-07） | ✅ 完成（2026-10-26） |
| CLAUDE.md / AGENT.md | ✅ 完成 |
| 开发环境（Flutter 3.47.8 / Go 1.27.3 / JDK17 / Android SDK 36，全落 D 盘） | ✅ 完成（2026-10-26，见 docs/08） |
| M0 工程奠基（Flutter 工程 + sync_core + Go 骨架 + CI） | ✅ 完成（2026-10-26；analyze/test 全绿，APK 空壳构建通过；Windows 本机构建依赖 VS Build Tools，见 docs/08 §4） |
| M1 本地阅读闭环（书库 FR-1xx + txt/md/pdf 阅读器 + 本地进度/时长/设置 + TOC 抽屉） | ✅ 完成（2026-10-26；app 293 测试全绿；Windows debug 构建通过并冒烟验证；Android debug APK 构建通过（含四 ABI libpdfium）；epub 渲染器按路线图随 M2/M3 交付；pdfrx 收编副本与机器环境补丁见 docs/07-R15、docs/08 §6.3） |
| M2 同步上线（sync_core 引擎 + WebDAV 适配器 + App 接入） | ✅ 开发完成（2026-10-27）：sync_core 165 + app 359 测试全绿；契约套件同用例双跑（内存参考实现 + 标准/降级内存 WebDAV 服务器）；rclone 真实 HTTP 联调通过；双端收敛 FR-404 自动化预演通过；Windows debug 构建通过。**待联调收口**：坚果云真实环境实测（docs/07-R3，需用户提供账号+应用密码）+ 两真机 FR-404 验收；flutter_secure_storage_windows 收编见 docs/07-R16 |
| M3 REST 适配器 + 自建服务端 → M4 打磨分发 | ⬜ 见 `docs/00-总览.md` §4 |

下一步：M3——自建服务端（Go，docs/06）+ REST 适配器（契约套件第三跑，NFR-08）+ epub 渲染器；收尾项：坚果云 R3 联调（凭据就绪后 `packages/sync_core/tool/rclone_probe.dart` 模式可直接换成坚果云端点实测）。

## 8. 文档索引

`docs/00-总览.md`（地图+路线图）｜ `docs/01-需求规格说明.md`（FR/NFR 基线）｜ `docs/02-技术选型.md`（六大决策对比）｜ `docs/03-系统架构设计.md`（架构+接口）｜ `docs/04-同步引擎与冲突解决.md`（同步规格）｜ `docs/05-元数据Schema与云端目录布局.md`（schema 权威）｜ `docs/06-自建服务端设计与部署.md`（API+部署）｜ `docs/07-风险与待确认问题.md`（假设/风险登记）｜ `docs/08-开发环境搭建.md`（本机环境：安装位置/环境变量/镜像源）
