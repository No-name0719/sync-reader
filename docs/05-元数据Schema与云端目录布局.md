# 05 - 元数据 Schema 与云端目录布局

> **TL;DR**：云端布局对 WebDAV 与自建服务器**完全一致**：`library.json`（库常量）+ `meta/{bookId}.json`（每书一份元数据）+ `books/{bookId}.{ext}`（正文）+ `tmp/`（上传暂存）。meta JSON 顶层带 `schemaVersion`，演进遵循"只增不删、读方容忍未知字段"。本文给出**字段级定义**（类型/必填/语义）、四种格式的 `locator` 子 schema（跨设备恢复进度的关键）、bookId 生成与哈希去重规则、本地 SQLite 表结构（drift DDL 级别）与云端字段的映射关系。同步行为见 [04](./04-同步引擎与冲突解决.md)，接口层见 [03 §4](./03-系统架构设计.md)。

---

## 1. 云端目录布局

```
{同步根}/                            # 坚果云模式默认 /我的坚果云/Apps/SyncReader（可自选）；自建模式为 /{user}/
├── library.json                     # 库级常量，几乎不变
├── meta/
│   ├── {bookId}.json                # 每书一份元数据（含 tombstone 形态）
│   └── ...
├── books/
│   ├── {bookId}.epub                # 正文原样字节，文件名 = bookId + 原扩展名
│   └── ...
└── tmp/
    └── {bookId}.{ext}.part          # 上传暂存，成功后 MOVE 到 books/
```

| 项 | 约定 |
| --- | --- |
| 同步根选择 | 坚果云模式：默认 `/Apps/SyncReader`（坚果云为第三方应用预留的目录，配置向导自动创建，也允许用户改到任意子目录）；自建模式：服务端每用户独立根，客户端无感 |
| 为什么正文用 bookId 命名 | 原文件名可能含非法字符/重名/改名引发同步抖动；原文件名存于 `meta.book.fileName` 供恢复导出 |
| 原子性 | WebDAV 无原子 rename 保证的网盘（少数）：上传后用 `GET Content-Length` 校验代替 MOVE 语义；坚果云与自建服务器均支持 MOVE |
| 权限要求 | 读写 + 列目录 + MOVE；配置向导的"连接测试"显式验证这四项（FR-505） |

### library.json

```json
{
  "schemaVersion": 1,
  "libraryId": "01JBGX3Z5W8M9Q2V7K4T6R8Y0C",
  "createdAt": "2026-10-26T08:00:00.000Z"
}
```

## 2. 每书元数据 `meta/{bookId}.json` 完整示例

```json
{
  "schemaVersion": 1,
  "bookId": "01JBGX4A2N6P8R0T2V4X6Z8B1D",
  "rev": 42,
  "deviceId": "01JBGX3Z5W8M9Q2V7K4T6R8Y0C",
  "deviceName": "Pixel 7",
  "createdAt": "2026-10-26T08:00:00.000Z",
  "updatedAt": "2026-10-26T21:30:15.123Z",
  "deleted": false,
  "deletedAt": null,
  "dedupOf": null,
  "book": {
    "title": "三体",
    "author": "刘慈欣",
    "format": "epub",
    "fileName": "三体.epub",
    "contentHash": "sha256:9f2c...a1",
    "sizeBytes": 2384123,
    "language": "zh",
    "coverHash": "sha256:77ab...0c",
    "tocFingerprint": "tfp:4b1e..."
  },
  "progress": {
    "locator": { "type": "epub", "spineIndex": 12, "href": "OEBPS/ch05.xhtml", "blockIndex": 87, "charOffset": 1204 },
    "percent": 0.4127,
    "updatedAt": "2026-10-26T21:30:15.123Z"
  },
  "reading": {
    "totalSeconds": 128730,
    "lastReadAt": "2026-10-26T21:30:15.123Z"
  },
  "annotations": [],
  "extra": {}
}
```

**tombstone 形态**：同一文件名，`"deleted": true`、`"deletedAt": "<时间>"`、`progress` 可保留、`book` 保留（供游离文件重关联时比对 hash）。

## 3. 字段定义

### 3.1 顶层字段

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `schemaVersion` | int | ✅ | 固定 `1`；演进规则见 §6 |
| `bookId` | string(ULID) | ✅ | 全局唯一，= 文件名主干 |
| `rev` | int ≥1 | ✅ | 写端单调递增；冲突定序首位（[04 §6.2](./04-同步引擎与冲突解决.md)） |
| `deviceId` | string(ULID) | ✅ | 最后写入设备，冲突决胜第三位 |
| `deviceName` | string | ✅ | 展示用（"上次在 Pixel 7 上阅读"） |
| `createdAt` | ISO-8601 UTC | ✅ | 首次创建 |
| `updatedAt` | ISO-8601 UTC | ✅ | 最后修改，冲突决胜第二位 |
| `deleted` | bool | ✅ | tombstone 标记 |
| `deletedAt` | ISO-8601? | 删除时 | GC 依据（90 天，[04 §7.3](./04-同步引擎与冲突解决.md)） |
| `dedupOf` | string? | 去重时 | 被合并到哪个 bookId（§4.3） |
| `book` | object | ✅ | 静态书信息，见 §3.2 |
| `progress` | object? | 否 | 未读过为 null；结构见 §3.3 |
| `reading` | object | ✅ | 阅读统计 |
| `annotations` | array | ✅ | v1 恒为空数组（批注同步 v2 预留，字段已占位避免未来大迁移） |
| `extra` | object | ✅ | 向前兼容扩展区，读方必须容忍未知键 |

### 3.2 `book` 对象

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `title` | string | ✅ | epub 取 OPF dc:title，否则文件名去扩展名 |
| `author` | string | ✅ | 可为空串；支持"书名 - 作者"文件名模式 |
| `format` | string | ✅ | `txt|epub|md|pdf`，扩展格式自由字符串（[02 §D2.5](./02-技术选型.md)） |
| `fileName` | string | ✅ | 原始文件名（恢复导出用） |
| `contentHash` | string | ✅ | `sha256:<hex>`，正文全量哈希，去重与完整性核心 |
| `sizeBytes` | int | ✅ | 正文字节数 |
| `language` | string | 否 | ISO 639-1 |
| `coverHash` | string? | 否 | 封面哈希（封面文件本身不上云，各端自行生成；hash 用于变化检测） |
| `tocFingerprint` | string | ✅ | 目录指纹 = hash(目录结构序列化)。**用途**：两端目录解析结果不一致时（解析器升级/规则调整），进度定位降级为 percent，防跳错章节 |

### 3.3 `progress.locator` —— 按格式判别联合（跨设备恢复进度的核心）

设计原则：**记录逻辑位置（内容坐标），不记录物理页码/像素**，天然免疫各端排版差异（[02 §D1.2-R2](./02-技术选型.md)）。

```jsonc
// type = "txt"：章节 + 章内字符偏移
{ "type": "txt", "chapterIndex": 87, "charOffset": 1204 }

// type = "epub"：spine 序号 + 文件 href + 块序号 + 块内字符偏移
{ "type": "epub", "spineIndex": 12, "href": "OEBPS/ch05.xhtml",
  "blockIndex": 87, "charOffset": 1204 }

// type = "md"：标题块（章节）+ 块内字符偏移（相对该块源文本）
{ "type": "md", "headingIndex": 14, "blockIndex": 87, "charOffset": 1204 }

// type = "pdf"：页码(0-based) + 页内纵向比例 + 阅读方向提示
{ "type": "pdf", "pageIndex": 41, "yRatio": 0.35, "readingDir": "ltr" }

// type = "raw"：所有无法结构化定位的情况（含未来未知格式）的兜底
{ "type": "raw", "ratio": 0.4127 }
```

恢复规则（编码级）：

1. 本地书 `tocFingerprint` == meta 中值 → 按 locator 精确恢复；
2. 指纹不一致（版本升级等）或 locator `type` 本端不支持 → 降级用 `percent` 定位到最近章节开头；
3. `percent` 定义 = 已读字符数（文本类）/ 已读页数（pdf）占总量的比例，各 Handler 实现 `percentOf(locator)` 与 `locate(percent)` 双向换算。

### 3.4 `reading` 对象

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `totalSeconds` | int | 累计阅读秒数；冲突时**求和合并**（[04 §6.3](./04-同步引擎与冲突解决.md)） |
| `lastReadAt` | ISO-8601 | 书库"最近阅读"排序依据；取两端最大值 |

## 4. bookId 生成与去重

### 4.1 生成

- 导入时本地生成 ULID（时间有序，天然按导入时间排列）；
- `deviceId` 同规则，首次启动生成。

### 4.2 为什么不用 contentHash 直接当 bookId

hash 当 ID 看似可免去重，但：用户替换文件（修正版 epub）后同书 hash 变化，会分裂成两本书；而进度、批注应跟随"书"而非"文件版本"。故 ID 与 hash 分离，`book.contentHash` 仅作去重与完整性。

### 4.3 双端独立导入同一本书（去重规则）

1. 任一端在推送前以 `contentHash` 查询云端清单（[04 §5.3](./04-同步引擎与冲突解决.md)）；
2. 发现同 hash 的云端书 → 本地条目并入云端书：保留云端 `bookId` 与其 `rev` 链，本端将自家 bookId 写成 `dedupOf=<云端bookId>` 的 tombstone，进度按 updatedAt 与云端进度 LWW 合并；
3. 两端几乎同时上架的竞态：Diff 阶段发现两个 bookId 同 hash → 统一保留字典序小的 bookId，另一端补 tombstone（同样的 LWW 定序保证收敛）。

## 5. 本地存储结构（drift / SQLite）

```sql
-- 书籍主表（本地视图，云端 meta 的投影 + 本地文件指针）
CREATE TABLE books (
  book_id        TEXT PRIMARY KEY,            -- ULID
  title          TEXT NOT NULL,
  author         TEXT NOT NULL DEFAULT '',
  format         TEXT NOT NULL,
  file_name      TEXT NOT NULL,               -- 原始文件名
  local_path     TEXT,                        -- 本地正文路径；NULL = 占位（云端有、本地无）
  content_hash   TEXT NOT NULL,               -- sha256:hex
  size_bytes     INTEGER NOT NULL,
  cover_path     TEXT,
  toc_fingerprint TEXT NOT NULL,
  added_at       INTEGER NOT NULL,            -- epoch ms
  last_read_at   INTEGER,
  total_seconds  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_books_last_read ON books(last_read_at DESC);
CREATE INDEX idx_books_title ON books(title);

-- 阅读进度（本地实时值；push 前与 meta 同步）
CREATE TABLE progress (
  book_id     TEXT PRIMARY KEY REFERENCES books(book_id) ON DELETE CASCADE,
  locator_json TEXT NOT NULL,                 -- §3.3 判别联合原样存储
  percent     REAL NOT NULL,
  updated_at  INTEGER NOT NULL,
  dirty       INTEGER NOT NULL DEFAULT 0     -- 1 = 待上传
);

-- 同步状态（每本书每后端一份；backend_key = 'webdav' | 'server:{libraryId}'）
CREATE TABLE sync_state (
  book_id       TEXT NOT NULL,
  backend_key   TEXT NOT NULL,
  base_rev      INTEGER NOT NULL,
  remote_etag   TEXT,                          -- WebDAV 模式条件请求用
  last_synced_meta_json TEXT,                  -- 上次同步副本 = 冲突合并的公共祖先（04 §6.3）
  last_synced_at INTEGER NOT NULL,
  PRIMARY KEY (book_id, backend_key)
);

-- tombstone 本地账本（删除同步与 GC）
CREATE TABLE deleted_books (
  book_id     TEXT PRIMARY KEY,
  deleted_at  INTEGER NOT NULL,
  pushed      INTEGER NOT NULL DEFAULT 0,    -- tombstone 是否已上云
  content_hash TEXT NOT NULL                  -- 游离文件重关联用
);

-- 同步游标与全局状态（每后端一行）
CREATE TABLE sync_cursor (
  backend_key    TEXT PRIMARY KEY,
  changes_cursor TEXT,                         -- REST 模式服务端游标
  meta_listing_etag TEXT,                      -- WebDAV PROPFIND 响应 ETag（无则全量列）
  last_full_sync_at INTEGER,
  quota_up_bytes   INTEGER NOT NULL DEFAULT 0, -- 本自然月对坚果云上行累计（04 §8.3）
  quota_down_bytes INTEGER NOT NULL DEFAULT 0,
  quota_month      TEXT
);

-- 阅读偏好（仅本地，不同步）
CREATE TABLE reader_settings ( key TEXT PRIMARY KEY, value TEXT NOT NULL );

-- 待同步队列（重启后恢复）
CREATE TABLE sync_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  book_id TEXT NOT NULL,
  op TEXT NOT NULL,                            -- 'meta' | 'book_upload'
  enqueued_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0
);
```

### 云端 JSON ↔ 本地表映射

| 云端字段 | 本地归属 |
| --- | --- |
| `book.*`（title/author/format/hash/size/toc 指纹） | `books` 表 |
| `progress.*` | `progress` 表（dirty=0 时与云端一致） |
| `reading.*` | `books.total_seconds` / `books.last_read_at` |
| `rev/baseRev` | `sync_state.base_rev`（`meta.rev` 以 `last_synced_meta_json` 为准） |
| `deleted/deletedAt` | `deleted_books` 表 |
| `deviceId/deviceName` | 不持久化到书表（仅存于 `last_synced_meta_json` 原文） |

## 6. schemaVersion 演进与迁移

| 版本 | 变更类型 | 规则 |
| --- | --- | --- |
| 1（当前） | 初版 | — |
| 次版本演进（1 → 2） | **只允许**：新增可选字段、新增 `extra` 键、locator 新增 `type` | 旧客户端读到新版本：按已知字段使用 + `percent` 兜底，**不得报错**；写回时保留原 `schemaVersion` 不变，避免降级破坏 |
| 破坏性演进（大版本） | 字段改名/类型变更/语义变更 | 客户端内置迁移器：读到旧版本 → 迁移到当前版本再写回并升 `schemaVersion`；迁移矩阵与用例纳入 `sync_core` 单元测试 |
| 校验 | — | `sync_core` 中 `BookMeta.fromJson` 执行严格校验（必填/类型/枚举），失败 → 该书标记 `Corruption` 并跳过，不阻塞全库同步 |

不变式（编码时作为断言/测试用例）：

1. `rev` 严格单调：同一 bookId 的写入端，本地计数器只增不减；
2. tombstone 不可逆覆盖：`deleted=true` 的 meta 只能被 `rev` 更高的正常 meta 复活（[04 §7.2](./04-同步引擎与冲突解决.md)）；
3. `contentHash` 不可变：同一 bookId 下 hash 变化必须伴随显式的"替换文件"流程（FR-410），否则视为损坏；
4. `percent ∈ [0,1]`；`locator.type` ∈ 本端 Handler 注册表 ∪ {raw}。

## 7. 相关文档

- 同步时序与冲突规则：[04-同步引擎与冲突解决](./04-同步引擎与冲突解决.md)
- 模型类与接口：[03-系统架构设计](./03-系统架构设计.md) §4 ｜ 存储选型：[02-技术选型](./02-技术选型.md) §D3
- 服务端如何存取这些文件：[06-自建服务端设计与部署](./06-自建服务端设计与部署.md)
- schema 相关风险：[07-风险与待确认问题](./07-风险与待确认问题.md)
