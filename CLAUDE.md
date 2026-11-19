# SyncReader — 项目上下文（AI 编码会话入口）

## 1. 定位

SyncReader 是一个**跨平台电子书进度同步阅读客户端**：用户在 Android（手机/平板）与 Windows 桌面端使用同一份书库，阅读进度实时一致；同步完全由用户自己的存储（WebDAV 网盘，坚果云为第一目标）承载，软件零云服务、零收费。

## 2. 技术栈（以 pubspec 为准）

| 层 | 选型 | 关键依赖与版本 |
| --- | --- | --- |
| 客户端框架 | Flutter 3.47.8 / Dart 3.13.7 | `apps/sync_reader/pubspec.yaml`，`sdk: ^3.13.7`，`version: 1.0.0+1` |
| 状态管理 / 路由 | Riverpod + go_router | `flutter_riverpod: ^3.0.0`、`go_router: ^16.0.0` |
| 本地存储 | drift（SQLite，schemaVersion 5，WAL） | `drift: ^2.35.3`、`drift_flutter: ^0.3.1`、`sqlite3_flutter_libs: ^0.6.0+eol`、`path_provider`、`path` |
| 同步核心 | 纯 Dart 包 `sync_core`（无 Flutter 依赖） | `packages/sync_core/pubspec.yaml`，`sdk: ^3.9.0`；依赖仅 `meta`、`crypto`、`dio: ^5.0.0`、`xml: ^6.0.0` |
| 网络 / 安全 | dio（WebDAV 六动词直用）、flutter_secure_storage、connectivity_plus | `dio: ^5.0.0`、`flutter_secure_storage: ^10.0.0`、`connectivity_plus: ^6.1.5` |
| 阅读渲染 | 自研 txt/md/epub 渲染 + pdfrx（PDF） | `epub_pro: ^5.6.0`、`flutter_widget_from_html: ^0.17.4`、`flutter_markdown_plus: ^1.0.12`、`pdfrx: 1.3.5` |
| 其它 | crypto、ulid、fast_gbk、intl、file_picker、window_manager | `crypto: ^3.0.8`、`ulid: ^2.2.0`、`fast_gbk: ^1.0.0`、`file_picker: ^13.3.0`、`window_manager: ^0.5.2` |
| 代码生成 | drift_dev + build_runner | `drift_dev: ^2.35.2`、`build_runner: ^2.17.1` |
| 收编第三方包 | `packages/third_party/`（dependency_overrides 指向） | `pdfrx` 1.3.5（Dart 3.13 流分析补丁）、`flutter_secure_storage_windows` 4.2.2（ATL→Win32 等价实现） |

`apps/sync_reader/pubspec.yaml` 的 `dependency_overrides`：`pdfrx` → `packages/third_party/pdfrx`，`flutter_secure_storage_windows` → `packages/third_party/flutter_secure_storage_windows`；`sync_core` 以 path 依赖引入。

## 3. 真实目录结构

```
sync-reader/
├── apps/sync_reader/                 # Flutter 客户端（Android + Windows）
│   ├── lib/
│   │   ├── app/                      # 入口装配：app.dart / router(go_router) / providers(Riverpod DI)
│   │   │                              #   / onboarding(首启闸门) / app_preferences / window(桌面窗口)
│   │   ├── core/                     # 通用层：design_tokens / app_logger / content_hasher / ulid / errors / startup_timer / version / log_exporter
│   │   ├── data/
│   │   │   ├── db/                   # drift 表定义 + DAO + 迁移（app_database.dart，schemaVersion 5）
│   │   │   ├── files/                # 正文与封面文件存取（BookFileStore）
│   │   │   ├── secure/               # 凭据安全存储（CredentialStore 实现）
│   │   │   └── sync/                 # sync_core 的 drift 桥接（LocalLibrary / SyncStore 实现）
│   │   ├── features/
│   │   │   ├── library/              # 书库页、详情页、分组、批量导入、导入服务、扫描器、封面生成
│   │   │   │   ├── import/  orphan/  replace/  widgets/
│   │   │   ├── reader/               # 阅读框架 + contract(冻结 API) + formats/{txt,md,pdf,epub}
│   │   │   ├── sync/                 # 同步门面、触发器、配额闸门、连接测试、设置页、云端书库页、向导页
│   │   │   ├── settings/  onboarding/  shell/
│   │   └── shared/                   # 通用组件：cover_view / copy / format_utils
│   ├── test/                         # 单元 + 集成 + golden 测试
│   ├── android/  windows/  assets/jianguoyun/   # 平台壳、Inno Setup 脚本、向导图文截图
│   └── pubspec.yaml
├── packages/
│   ├── sync_core/                    # 纯 Dart 同步核心
│   │   ├── lib/src/{model,engine,diff,conflict,transfer,store,backend,internal}/
│   │   ├── lib/sync_core.dart        # 唯一公开出口（export 白名单）
│   │   ├── test/                     # 单测 + 契约套件（memory / WebDAV 标准 / WebDAV 降级）
│   │   └── tool/                     # 真实环境联调探针（jianguoyun_probe / rclone_probe）
│   └── third_party/{pdfrx,flutter_secure_storage_windows}/
├── scripts/                          # package_release.ps1 / drive_app.ps1 / run_virtual_display.ps1
│                                     # gen_app_icons.py / check_page_breaks.py
├── docs/                             # 设计基线文档（docs/local/ 为本地草稿，不入库）
├── LICENSE (MIT)   README.md
```

不入库目录（.gitignore）：`dist/`、`testdata/`、`.tools/`、`.secrets/`、`ui_prototype/`、`ui_audit/`、`.shots/`、`docs/local/`。

## 4. 关键设计约定

1. **本地优先**：导入/阅读/删除立即作用于本地；同步是异步旁路，任何同步失败不影响本地操作。`SyncEngine` 的同步入口**永不抛出**，错误一律收进 `SyncReport`（阶段级 `phaseError`/`groupPhaseError`，逐项 `results`/`groupResults`）。
2. **元数据先行**：全量同步 = 五阶段 `PullListing → Diff → PullMetas → PushMetas → Transfer → 落游标`。正文（MB 级）只在本地缺失或落后时按需传输；元数据走 ETag/If-None-Match 条件请求（304 零流量）。任何阶段失败只记录并回 Idle，下次触发自动重放（幂等可重放）。
3. **冲突定序 `(rev, updatedAt, deviceId)`**：`rev` 由写端单调递增维护（基线存 `sync_state.baseRev`），实现于 `BookMeta.compareTo`；LWW 胜者框架（书信息/进度/locator 全取胜者），累积型字段特例：`totalSeconds = local + remote − 公共祖先值`（缺祖先退化为直接求和，clamp ≥ 0）、`lastReadAt = max`。
4. **乐观锁 CAS**：写前 `expectedRev = baseRev`；`RevConflict` → 拉远端 → 合并 → 以远端当前 rev **重试恰一次**，再冲突 → `ConflictUnresolvable`。
5. **tombstone 删除**：删除 = `deleted=true` 的 meta（同一 `bookId` 文件名）。本端删除 = 删正文/封面文件 + 删 `books` 行（进度级联清除）+ 写 `deleted_books` 墓碑账本；**云端正文永不删除**；其它端收到墓碑 → 移出书库、正文保留为**游离文件**（可重新关联）。墓碑与正常 meta 走同一 `(rev, updatedAt, deviceId)` 定序：墓碑赢则删，正常 meta 赢则"复活"。云端墓碑 GC 90 天，本地账本随之清理。
6. **仅本地书**：`local_only_books` 表标记的书同步引擎完全看不见（导入时取消"同时上传到云端"，或"从云端移除"后落 diff 第 7b 行）。
7. **凭据安全存储**：只经 `flutter_secure_storage`（Android Keystore / Windows DPAPI）；**凭据零落 SQLite / 日志 / 崩溃报告**；密钥名见 `SecureKeys`（`webdav.account`/`webdav.password`/`webdav.baseUrl`/`webdav.rootPath`/`device.id`）；日志统一走 `AppLogger` 脱敏钩子。
8. **排版偏好不同步**：字号/行距/主题/字体等存在 `reader_settings` 表，仅本地（docs/07 A5/Q7）。v1 同步范围仅 **进度 + 阅读时长 + 书籍信息 + 删除**；批注/高亮 schema 占位不同步。
9. **进度定位用逻辑位置**：locator 记录章节/字符偏移/块坐标，**不记物理页码或像素**，天然免疫各端排版差异；`tocFingerprint` 不一致时进度降级为 `percent`。
10. **格式扩展点**：新格式 = 实现 `BookFormatHandler`（冻结 API）并注册进 `FormatRegistry`；同步层只消费 `formatId` 字符串，与格式无关。已注册 txt / md / pdf / epub（`app/providers.dart` 的 `formatRegistryProvider`）。
11. **云端目录布局**：`{root}/library.json`、`meta/{bookId}.json`、`groups/{groupId}.json`、`books/{bookId}.{ext}`、`tmp/{bookId}.{ext}.part`。`groups/` 与 `meta/` **平级**（`meta/` 的 Depth:1 PROPFIND 用于枚举书籍，混入分组会污染清单）；`ensureLayout()` 幂等创建，老云端目录缺 `groups/` 不报错。
12. **分组同步**：分组是独立文件类型（独立 rev / CAS / 墓碑）；**同名分组按名称级去重**（规范 id = 簇内字典序最小者）；同步顺序恒为**分组先于书籍**（拉取与推送都是），避免悬空 `groupId` 外键。
13. **schemaVersion 只增不删**：meta JSON 与 drift 表迁移都遵守；读方容忍未知字段，写回保留原 `schemaVersion`。
14. **sync_core 禁 Flutter 依赖**：只允许纯 Dart 包；公共 API 只经 `lib/sync_core.dart` 导出。
15. **适配器只做传输**：diff / 合并 / 墓碑 / 重试策略全在 sync_core；`BackendAdapter` 只负责 HTTP 语义与能力探测。仓库内现役实现为 `WebDavAdapter`（仅 PROPFIND/GET/PUT/MOVE/MKCOL/DELETE 六动词）与 `InMemoryAdapter`（参考实现，契约套件用）；`BackendKind` 枚举另保留 `server` 取值但无对应实现。
16. **契约套件**：`packages/sync_core/test/contract/` 的同一套用例必须同时跑通 memory 参考实现、WebDAV 标准形态、WebDAV 降级形态。
17. **WebDAV 特性适配**：两级清单（PROPFIND 拿 etag/size/mtime → 实例内 `etag→rev` 缓存，未命中逐本补拉一次 GET），保证 `stub.rev` 权威；能力探测 MOVE/ETag/Range，缺失时按 `size+mtime` 合成 etag、以 Content-Length 校验替代 MOVE。

## 5. 常用命令

质量门由本机承担（仓库无 CI 流水线，`.github/` 不存在）。

```bash
# 格式化（提交前）
dart format apps/sync_reader packages/sync_core

# 静态分析（要求零告警）
cd apps/sync_reader && flutter analyze
cd packages/sync_core && dart analyze

# 测试
cd apps/sync_reader && flutter test
cd packages/sync_core && dart test

# drift 代码生成（改表后必跑；生成物 .g.dart 必须提交）
cd apps/sync_reader && dart run build_runner build --delete-conflicting-outputs
cd apps/sync_reader && git diff --exit-code   # 校验生成物未漂移

# 构建
cd apps/sync_reader && flutter build apk --release --split-per-abi    # Android，按 ABI 拆分
cd apps/sync_reader && flutter build windows --release                 # Windows x64

# golden 截图更新（按需）
cd apps/sync_reader && READER_SHOTS=1 flutter test --update-goldens
```

```powershell
# 一键发布打包（Android + Windows + 安装器 + 便携包 → dist/）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/package_release.ps1
# 常用参数：-SkipWindows / -SkipAndroid / -SkipInstaller / -SkipPortable
#            -IsccPath "<ISCC.exe>" / -OutDir "<目录>" / -Version "<x.y.z>"
```

```bash
# 真实环境联调探针（凭据取自 .secrets/ 或环境变量，目录已 gitignore）
cd packages/sync_core && dart run tool/jianguoyun_probe.dart
cd packages/sync_core && dart run tool/rclone_probe.dart
```

## 6. 已实现功能概览

### 书库
- 网格/列表书库：书卡（封面、状态胶囊、进度条），状态 chip × 分组下拉两层筛选（取交集 + 分面计数），搜索、排序、视图模式切换。
- 导入：单本导入；批量导入（选文件夹 → 递归扫描 → 清单确认 → 导入，含"同时上传到云端"开关与完成汇总）。
- 导入流水线：流式哈希 → 去重（库内查重 + 同批内存 Set）→ 生成 ULID → 解析元数据 → 封面落盘 → 复制正文 → upsert。
- 书籍详情页：Hero + 阅读数据（统计块 + 近 7 天柱状图）+ 文件信息 + 目录预览；操作为打开阅读 / 重新选择文件（内容替换）/ 删除。
- 分组（本地标签）：新建、改名、排序、删除、书籍归组。
- 游离文件面板：扫描、挂回书库、彻底删除。
- 无真封面时生成"纸底墨字"封面；存储占用统计与缓存清理。

### 阅读器（txt / md / epub / pdf）
- txt：编码自动检测（GBK/UTF-8/UTF-16）、章节切分、首行缩进、滚动与分页双模式。
- md：markdown 渲染与目录。
- epub：块化解析 + HTML 渲染（图片、粗斜体、标题、引用、列表、简单表格），目录跳转，复杂表格/浮动布局降级为顺序文本。
- pdf：pdfrx 渲染、封面、大纲映射。
- 统一阅读框架：进度锚点与 locator、TOC 抽屉、设置面板（字体/字号/行距/背景/翻页方式）、亮度调节、Android 音量键翻页、页界裁剪与分页稳定性处理。
- 进度管线：渲染节流 → 3s 防抖落库（dirty 标记）→ 切后台/退出阅读页立即落库；阅读时长每秒累计并按自然日拆分写入 `reading_days`。

### 同步
- WebDAV 后端（坚果云第一目标）：分步连接测试（列目录/MKCOL/写读删/MOVE，含往返延迟）与能力探测（MOVE/ETag/Range）。
- 坚果云四步配置向导（应用密码图文指引 → 账号与应用密码 → 自动连接测试 → 能力展示并落凭据）。
- 六种触发时机：冷启动 +2s、切后台回前台、阅读进度防抖单书推送、网络恢复、前台 15min 定时、手动。
- 全量同步五阶段 + 冲突合并重试恰一次 + 删除墓碑推送 + 分组同步 + 哈希去重（同名/同 hash 合并）。
- 占位书正文按需下载（`.part` 续传 + SHA-256 校验）；配额闸门（上行 1GiB / 下行 3GiB，80% 告警、100% 挂起正文传输）。
- 云端书库管理页（云端全量清单、逐本"从云端移除"）；仅本地书列表（单本/全部上传）；诊断日志导出（二次脱敏）；全局与书级同步状态展示。

### 通用
- 响应式应用外壳：≥1180px 侧栏 / 861–1179px 图标栏 / ≤860px 底部标签栏；阅读页全屏沉浸（不套外壳）。
- 设计令牌主题（`core/design_tokens.dart`）：三套主题风格 × 三种外观模式，落 `app_settings` 表；阅读主题独立于应用主题。
- 首启引导页（可跳过）+ 首启专用全屏四步向导；路由 `redirect` 在首帧前完成闸门判定。
- 设置页：外观 / 阅读 / 存储 / 关于四区。
- 启动打点（`core/startup_timer.dart`）、分级日志与导出；离线/飞行模式零报错弹窗。

## 7. 文档地图

| 文档 | 内容 |
| --- | --- |
| `docs/00-总览.md` | 定位、文档地图、关键决策、能力总览、当前状态 |
| `docs/01-需求规格说明.md` | FR/NFR 逐条编号、平台优先级、用户流程 |
| `docs/02-技术选型.md` | 决策 D1 UI 框架 / D2 渲染 / D3 本地存储 / D4 元数据格式与云端目录布局 / D5 冲突策略 / D6 工程配套 |
| `docs/03-系统架构设计.md` | 总体架构、模块划分、核心接口、数据流、平台适配 |
| `docs/04-同步引擎与冲突解决.md` | 同步触发、状态机、diff 矩阵、冲突合并、删除语义、流量优化 |
| `docs/05-元数据Schema与云端目录布局.md` | 云端目录、meta JSON 字段级 schema、locator、SQLite DDL、迁移 |
| `docs/07-风险与待确认问题.md` | 默认假设、待确认问题、风险登记 |
| `docs/08-开发环境搭建.md` | Windows/Android 构建环境 |
| `docs/09-发布与分发.md` | 版本号、签名、打包、发布流程、第三方声明 |
| `docs/10-界面重设计方案.md` | 界面设计规范（色彩/字体/间距/页面方案），不含实施流水 |

源码注释普遍带 `docs/XX §Y` 引用——**改动行为时同步更新对应文档章节**，这是本仓库的既有约定。

## 8. 修改代码时的注意事项

1. **drift 生成物必须提交**：`lib/data/db/app_database.g.dart` 与各 DAO 的 `.g.dart` 随表结构变更一起入库；改表后跑 build_runner 并用 `git diff --exit-code` 校验无漂移。迁移遵守"只增不删"，`schemaVersion` 单调递增。
2. **收编第三方包的补丁约定**：`packages/third_party/` 下每一处改动必须带 `// SyncReader patch (日期): 原因` 注释块（现有两处：`pdfrx/lib/src/pdfium/pdf_file_cache.dart`、`flutter_secure_storage_windows/windows/flutter_secure_storage_windows_plugin.cpp`）；与上游差异保持最小；升级上游版本时先确认补丁是否仍需要。
3. **sync_core 保持纯 Dart**：禁止 import Flutter；新增能力放进对应子目录并补 `lib/sync_core.dart` 的 export。app 侧只 import 该出口，不引包内私有路径。
4. **改 BackendAdapter 语义要同步契约用例**：同一套契约必须同时跑通 memory / WebDAV 标准 / WebDAV 降级三形态。
5. **改同步行为要成组修改**：`sync_core`（diff / 冲突 / 墓碑）+ app 侧 `data/sync/drift_local_library.dart` + 相关测试 + `docs/04`（§5–§7）与 `docs/05`。
6. **新增阅读格式**：实现 `BookFormatHandler` → 在 `formatRegistryProvider` 注册 → locator 的 `type` 前缀与 `formatId` 一致；同步层无需改动。
7. **凭据与书名等敏感字段不入日志**；新日志统一走 `AppLogger` 的脱敏钩子。
8. **UI 走设计令牌**：颜色、间距、圆角、字号取自 `core/design_tokens.dart`（`Theme.of(context).extension<AppDesignTokens>()`），不写死数值；阅读主题与应用主题分离。
9. **注释与文档用中文**：每个模块头部写明"职责 + 对应 docs 章节"，接口注释写成可直接开码的规格。
10. **版本号单点维护**：`apps/sync_reader/pubspec.yaml` 的 `version:`（语义化版本，产物名只取 semver 部分）。发布签名材料不入库（`android/key.properties`、`android/key/`）；release 签名凭据优先级为环境变量 > `key.properties` > debug 回退。
11. **质量门本地承担**：提交前 `dart format` + `flutter analyze` 零告警 + `flutter test` / `dart test` 全绿 + drift 生成检查。
