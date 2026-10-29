# CLAUDE.md — SyncReader 项目上下文

> 面向后续 AI 编码会话的项目说明。**当前阶段：v1.1 界面重设计（docs/10，A1–A22）开发完成并已分批提交（2026-10-29），待逐屏验收；M4 真机验收与 v1.0.0 发布收口并行待办；M5 服务端已后置（07-A18）。** 开工前请先通读本文与 `docs/` 设计基线。

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
| M0 工程奠基（Flutter 工程 + sync_core + Go 骨架） | ✅ 完成（2026-10-26；analyze/test 全绿，APK 空壳构建通过；Windows 本机构建依赖 VS Build Tools，见 docs/08 §4） |
| M1 本地阅读闭环（书库 FR-1xx + txt/md/pdf 阅读器 + 本地进度/时长/设置 + TOC 抽屉） | ✅ 完成（2026-10-26；app 293 测试全绿；Windows debug 构建通过并冒烟验证；Android debug APK 构建通过（含四 ABI libpdfium）；epub 渲染器按路线图随 M2/M3 交付；pdfrx 收编副本与机器环境补丁见 docs/07-R15、docs/08 §6.3） |
| M2 同步上线（sync_core 引擎 + WebDAV 适配器 + App 接入） | ✅ 开发完成（2026-10-27）：sync_core 165 + app 359 测试全绿；契约套件同用例双跑（内存参考实现 + 标准/降级内存 WebDAV 服务器）；rclone 真实 HTTP 联调通过；**坚果云真实环境联调完成**（R3：实测画像 + 缺失目录 409 兼容修复 + 双端收敛 FR-404 真实预演，见 docs/07-R3）；Windows debug 构建通过。**待收口**：两真机 FR-404 验收；flutter_secure_storage_windows 收编见 docs/07-R16 |
| M3 客户端功能补全（epub 渲染器 + 同步体验 P1；服务端方案后置至 M5，2026-10-27 调整） | ✅ 开发完成（2026-10-28）：sync_core 192 + app 514 测试全绿。**epub 渲染器**（FR-203）：epub_pro 解析 + flutter_widget_from_html 块化渲染、分页（连续排版+视口 snap）/滚动双模式、NCX 目录跳转、locator 与 sync_core EpubLocator 字段级互通、ReaderPage 指纹门（指纹不一致全格式降级 percent）、阅读设置热应用；降级项（复杂表格/浮动布局）登记 07-R2。**同步体验**：游离文件面板（FR-408 UI 半边：orphans 区/分层残留/平铺三形态扫描 + contentHash 挂回 + 彻底删除）；云端孤儿清理工具（docs/04 §7.1 规则 4：逐文件确认、批量可暂停、配额联动）；FR-410 文件替换（sync_core 冻结 replaceBookContent + uploadBook overwrite 语义，接收端自动下载覆盖；详情页"重新选择文件"）。**书库补齐**：批量导入（FR-109 递归扫描+清单确认）、pdf 封面（FR-103 第一页缩略图，pdfrx 可注入）、配额面板 80% 常驻提醒（docs/04 §8.3）。C3（FR-208 阅读时长按天统计）按任务允许后置 |
| M4 打磨分发（P0 平台可安装分发；性能/离线/补功能） | ✅ 开发完成（2026-10-28）：sync_core 192 + app 595 测试全绿。**发布打包**：release keystore 本地生成不入库（`android/key/` gitignored，环境变量可覆盖，材料缺失回退 debug——storeFile 须以 rootProject 解析，见 docs/08 §8.3 指纹验证教训）；applicationId 正式化为 `com.syncreader.app`；版本 1.0.0+1（pubspec 单点）；Inno Setup 安装器（16.5MB）+ 便携 zip（20.3MB）+ 三 ABI 签名 APK（32-36MB，apksigner 指纹比对通过）经 `scripts/package_release.ps1` 一键产出（NFR-04 体积门全过）；LICENSE（MIT，Q2 拍板）、CHANGELOG、README、docs/09 发布流程。**性能**：NFR-05 启动打点（startup_timer，release 冒烟 firstFrame=136ms）；FR-106 基准 2000 本搜索中位 0.4ms（门 100ms，docs/08 §8）。**离线/健壮性**：FR-601 飞行模式 9 用例固化（零报错弹窗，未发现生产缺陷）；FR-604 导出日志（2000 行环形缓冲 + 二次脱敏 + 同步设置页入口）。**补功能**：C3 FR-208 按天时长（schema v2 只增不删迁移 + 详情页最近 7 天）；FR-107 分组标签（分组栏/拖拽归组/管理，本地不同步）；FR-209 音量键翻页（Android 平台通道拦截 + 四渲染器翻页 API，默认关）。**待收口**：真机验收（M2/M3 遗留 epub 全链路与 FR-404 双端收敛 + M4 启动时长/音量键/离线/安装），清单见 §7 下一步 |
| v1.1 界面重设计（docs/10，A1–A22） | ✅ 开发完成（2026-10-29，**已分批提交，待真机验收**）：app 775 + sync_core 195 测试全绿，Windows/Android debug 构建通过。**UI 层**：设计令牌 ThemeExtension（三 accent × 深浅，赭石默认）、应用外壳（232px 侧栏/68px 窄栏/移动底栏，导航只留 书库·同步·设置）、书库两层筛选取交集+分面计数、书卡点封面直开+右键/长按菜单+右上角状态胶囊、纸底墨字生成封面、详情页 Hero+7 天柱状图+目录预览、阅读器沉浸态+点击热区+Aa 面板+目录抽屉+正文首行缩进 2em/两端对齐/衬线（txt 引擎级 justify）+阅读主题 4 套（加护眼绿）+默认分页/字号 19、同步设置八分区+「未上传的书」卡片、配置引导四步轨、新增设置页（外观/阅读/存储/关于，accent 即时生效持久化 `app_settings` 表）、批量导入页重做+导入确认弹窗（上传开关默认开）、云端书库管理页（新）；「工具」模块取消（游离文件页/云端孤儿清理页已删）。**数据层**：schema v3（`local_only_books` + `app_settings`，只增不删）；删除语义变更（删正文文件+留元数据+墓碑，落「未下载」区，三处配套：softDelete/listBooks 排除/applyRemoteMeta 幂等）；「仅本地」状态（listBooks 排除+pushBookMeta 跳过+uploadToCloud 清 baseRev 走 7a 行+removeFromCloud=deleteMeta 不写 tombstone）。基线文档已同步：docs/01 FR-408、docs/04 §5.1 排除规则+§7.1.2、docs/05 §5+§6、docs/10 §9 实施记录。**追加**：同步设置页「测试连接」按钮（点一下即测已保存的配置，结果就地显示；移除维护区同名跳转向导的旧入口）、应用图标统一为「赭石圆角方 + 白色打开的书」（Android adaptive + Windows 多尺寸 ico，`scripts/gen_app_icons.py` 可复现）、逐屏比对材料（本地 `ui_audit/v11/`，不入库）。**待收口**：真机/桌面逐屏比对（四档视口×三 accent×深浅色，含 5 条同步语义场景抽查） |
| M5 服务端扩展（Go + REST 适配器） | ⬜ 见 `docs/00-总览.md` §4 |

下一步：**v1.1 界面重设计逐屏验收**（需用户配合；改动全部留在工作区未提交，验收通过后按 docs/10 §9.1 的 8 批分批提交）——① 桌面/真机按 docs/10 §8 逐屏比对（四档视口 × 三 accent × 深浅色：书库/详情/阅读器/同步/设置/批量导入/云端书库/引导）；② 5 条同步语义场景抽查（本地删除落「未下载」不回推、导入不上传→手动上架、云端移除→本地保留可读、仅本地进度不上云、双端删除收敛）；③ 阅读器沉浸态/热区/排版真机手感。之后回到 **M4 真机验收收口**（① 签名 APK 真机安装冒烟（新包名 `com.syncreader.app`，与旧 debug 包不互替）；② 常规小说 epub（含图片/粗斜体/标题/引用）Windows+Android 导入→阅读→换端恢复进度全链路（M2/M3 遗留）；③ FR-404 两真机离线收敛（坚果云真实环境，M2 遗留）；④ NFR-05 真机冷启动实测（Android 中端机 ≤2.5s，打点随「导出诊断日志」带走）；⑤ FR-209 音量键翻页（开关/退出恢复/旋转重建/边界）；⑥ 飞行模式真机抽查；⑦ Windows 安装器+便携包安装冒烟；⑧ **keystore 与 key.properties 离线备份**（丢失将无法同签名覆盖升级）——注意 ②③⑤⑥ 需在 v1.1 新界面上重跑）。**M5 服务端已后置**（07-A18，设计基线 docs/06 不变，随时可重启）。

## 8. 文档索引

`docs/00-总览.md`（地图+路线图）｜ `docs/01-需求规格说明.md`（FR/NFR 基线）｜ `docs/02-技术选型.md`（六大决策对比）｜ `docs/03-系统架构设计.md`（架构+接口）｜ `docs/04-同步引擎与冲突解决.md`（同步规格）｜ `docs/05-元数据Schema与云端目录布局.md`（schema 权威）｜ `docs/06-自建服务端设计与部署.md`（API+部署）｜ `docs/07-风险与待确认问题.md`（假设/风险登记）｜ `docs/08-开发环境搭建.md`（本机环境：安装位置/环境变量/镜像源/性能实测）｜ `docs/09-发布与分发.md`（版本/签名/打包/Releases 流程/第三方声明）
