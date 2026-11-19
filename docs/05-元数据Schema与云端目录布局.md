# 05 - 元数据 Schema 与云端目录布局

> **TL;DR**：云端布局（坚果云与通用 WebDAV **完全一致**）：`library.json`（库常量）+ `meta/{bookId}.json`（每书一份元数据）+ `books/{bookId}.{ext}`（正文）+ `tmp/`（上传暂存）。meta JSON 顶层带 `schemaVersion`，演进遵循"只增不删、读方容忍未知字段"。本文给出**字段级定义**（类型/必填/语义）、四种格式的 `locator` 子 schema（跨设备恢复进度的关键）、bookId 生成与哈希去重规则、本地 SQLite 表结构（drift DDL 级别）与云端字段的映射关系。同步行为见 [04](./04-同步引擎与冲突解决.md)，接口层见 [03 §4](./03-系统架构设计.md)。

---

## 1. 云端目录布局

```
{同步根}/                            # 坚果云默认 /我的坚果云/Apps/SyncReader（可自选）；通用 WebDAV 由用户填写同步根 URL
├── library.json                     # 库级常量，几乎不变
├── meta/
│   ├── {bookId}.json                # 每书一份元数据（含 tombstone 形态）
│   └── ...
├── groups/
│   ├── {groupId}.json               # 每个分组一份元数据（FR-107，含 tombstone 形态）
│   └── ...
├── books/
│   ├── {bookId}.epub                # 正文原样字节，文件名 = bookId + 原扩展名
│   └── ...
└── tmp/
    └── {bookId}.{ext}.part          # 上传暂存，成功后 MOVE 到 books/
```

> **`groups/` 为何与 `meta/` 平级而不是放进 `meta/`**：`meta/` 的 Depth:1
> PROPFIND 被 `listMetas` 用来枚举**书籍**，混入分组文件会污染书籍清单与
> 哈希去重逻辑（docs/04 §5.3）。分组是独立文件类型（独立 rev/CAS/墓碑），
> 独立顶层目录最干净。老版本云端目录没有 `groups/` 时，首次同步由
> `ensureLayout()` **幂等创建**（不得因目录缺失报错，docs/04 §5.2）。

| 项 | 约定 |
| --- | --- |
| 同步根选择 | 坚果云：默认 `/Apps/SyncReader`（坚果云为第三方应用预留的目录，配置向导自动创建，也允许用户改到任意子目录）；通用 WebDAV 则由用户填写同步根 URL |
| 为什么正文用 bookId 命名 | 原文件名可能含非法字符/重名/改名引发同步抖动；原文件名存于 `meta.book.fileName` 供恢复导出 |
| 原子性 | WebDAV 无原子 rename 保证的网盘（少数）：上传后用 `GET Content-Length` 校验代替 MOVE 语义；坚果云支持 MOVE |
| 权限要求 | 读写 + 列目录 + MOVE；配置向导的"连接测试"显式验证这四项（FR-505） |
| 分组目录 | `groups/` 与 `books/` 平级；`ensureLayout()` 幂等创建（老云端目录首次同步自动补建） |

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

## 2.1 分组元数据 `groups/{groupId}.json`（FR-107，参与同步）

分组是**独立文件类型**：每个分组自带 `rev`，因此「改 A 组名」与「改 B 组名」
互不冲突；改名 / 排序 / 删除都走与书籍一致的 `(rev, updatedAt, deviceId)`
LWW + CAS 乐观锁（docs/04 §6.2）。

```json
{
  "schemaVersion": 1,
  "groupId": "01JBGX5T7Y9Z1A3B5C7D9E1F3G",
  "rev": 7,
  "deviceId": "01JBGX3Z5W8M9Q2V7K4T6R8Y0C",
  "deviceName": "Pixel 7",
  "createdAt": "2026-11-17T08:00:00.000Z",
  "updatedAt": "2026-11-17T09:12:33.000Z",
  "deleted": false,
  "deletedAt": null,
  "name": "小说",
  "sortOrder": 3
}
```

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `schemaVersion` | int | ✅ | 分组自己的 schema 版本（独立于书籍 meta），固定 `1`；演进规则同 §6 |
| `groupId` | string(ULID) | ✅ | 分组全局唯一，= 文件名主干 |
| `rev` | int ≥1 | ✅ | 写端单调递增；冲突定序首位（[04 §6.2](./04-同步引擎与冲突解决.md)） |
| `deviceId` | string(ULID) | ✅ | 最后写入设备，冲突决胜第三位 |
| `deviceName` | string | ✅ | 展示用 |
| `createdAt` | ISO-8601 UTC | ✅ | 首次创建 |
| `updatedAt` | ISO-8601 UTC | ✅ | 最后修改，冲突决胜第二位 |
| `deleted` | bool | ✅ | tombstone 标记 |
| `deletedAt` | ISO-8601? | 删除时 | GC 依据（90 天，与书籍同期限） |
| `name` | string | ✅ | 分组名（非空；trim 后比较） |
| `sortOrder` | int | ✅ | 排序权重（升序；本地与云端同序） |

**tombstone 形态**：同一文件名，`"deleted": true` + `"deletedAt"`；`name` /
`sortOrder` 保留（墓碑自带分组名，便于对端识别"删的是哪个组"）。

### 2.1.1 同名分组的名称级去重（两台设备各建同名分组）

两台设备各自新建「小说」时，云端会出现**两条同名记录**（groupId 不同）。
若按 groupId 区分，书库会出现两个同名分组、书籍归属互相看不懂，因此规定
**名称级合并**（docs/04 §5.1 分组矩阵）：

1. 名称为空、已本地删除（待推墓碑）、已是远端墓碑的分组**不参与**合并；
2. 按分组名聚类（本地活分组 ∪ 云端活分组）；
3. 同一 groupId 若出现在多个名称聚类中（本地改名未同步 vs 远端改名），
   视为改名冲突，**跳过合并**（由 id 级 LWW 定序解决）；
4. 聚类内的**规范 id** = 全部 id 中**字典序最小者**（ULID 时间有序 →
   最早创建者优先）。该规则对两端对称——同样的 id 集合在 A/B 端得到同一个
   规范 id，避免"各把本地那条并入云端那条"造成的乒乓（两端各留各的）；
5. 其余 id 被吸收：本地行删除 + **组内书籍 `group_id` 迁移到规范 id**；
   云端冗余条目在规范分组确实存在于云端时删除（避免每次同步重复去重）。

> 合并后两端收敛到同一个 groupId，书籍 meta 里的 `groupId` 也随之收敛
> （见 §2.2）。合并是**幂等**的：重复同步不会再次迁移。

## 2.2 书籍 meta 的分组字段 `groupId`（可选）

书籍 meta 顶层新增**可选**字段 `groupId`（String?，null = 未分组）：

```jsonc
{
  "schemaVersion": 1,
  "bookId": "01JBGX4A2N6P8R0T2V4X6Z8B1D",
  "rev": 43,
  // ...
  "groupId": "01JBGX5T7Y9Z1A3B5C7D9E1F3G"   // 可选：所属分组 id
}
```

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `groupId` | string? | 否 | 所属分组 id（FR-107）；null = 未分组。**只增不删**：旧客户端读到该字段会忽略（`fromJson` 只取已知键），写回时丢失分组归属 = 降级为"未分组"，不影响其它同步语义 |

配套规则：

- **分组对象与书籍 meta 各自独立同步**：书籍 meta 推上去后对端知道"这本书
  属于 group X"，但还需要 `groups/{X}.json` 才知道 X 叫什么 → 引擎**先拉
  分组、再拉书籍**（docs/04 §4 阶段 3），保证落库时不存在悬空外键；
- **不得写悬空外键**：远端 meta 的 `groupId` 在本地不存在（分组尚未到达 /
  已被删除）时，书籍的 `books.group_id` 落为 NULL（未分组），等分组到达后
  由书籍 meta 再次同步纠正；
- 旧客户端（无分组支持的版本）上传的 meta 不含 `groupId` → 读方按"未分组"
  处理（已知降级，登记 [07](./07-风险与待确认问题.md)）。

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
| `groupId` | string? | 否 | 所属分组 id（FR-107，**可选**）；null = 未分组。详见 §2.2 |

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
  total_seconds  INTEGER NOT NULL DEFAULT 0,
  group_id       TEXT REFERENCES book_groups(group_id) ON DELETE SET NULL
                                              -- 分组（FR-107）；随书籍 meta 的 groupId 字段同步（§2.2）
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

-- 同步状态（每本书每后端一份；backend_key = 'webdav'）
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
-- 注：删除即移出书库（`books` 行删除，docs/10 §4.7b / 04 §7.1），
-- 本表是「已删除」的**唯一**留痕：驱动云端 tombstone 推送与 90 天 GC。
CREATE TABLE deleted_books (
  book_id     TEXT PRIMARY KEY,
  deleted_at  INTEGER NOT NULL,
  pushed      INTEGER NOT NULL DEFAULT 0,    -- tombstone 是否已上云
  content_hash TEXT NOT NULL                  -- 游离文件重关联用
);

-- 同步游标与全局状态（每后端一行）
CREATE TABLE sync_cursor (
  backend_key    TEXT PRIMARY KEY,
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

-- 阅读时长按天统计（FR-208；仅本地表，不参与云端同步；schemaVersion 2 新增）
CREATE TABLE reading_days (
  book_id TEXT NOT NULL REFERENCES books(book_id) ON DELETE CASCADE,
  day     TEXT NOT NULL,                       -- 本地自然日 'YYYY-MM-DD'（设备时区）
  seconds INTEGER NOT NULL DEFAULT 0,          -- 当天累计阅读秒数
  PRIMARY KEY (book_id, day)
);

-- 书籍分组（FR-107；schemaVersion 2 新增；参与云端同步，docs/05 §2.1）
CREATE TABLE book_groups (
  group_id   TEXT PRIMARY KEY,                 -- ULID
  name       TEXT NOT NULL,                    -- 重名校验在 DAO/UI 层做
  sort_order INTEGER NOT NULL DEFAULT 0,       -- 排序权重（按创建顺序递增）
  created_at INTEGER NOT NULL,                 -- epoch ms
  deleted    INTEGER NOT NULL DEFAULT 0,       -- 软删标记：1 = 已删除、待推墓碑
  deleted_at INTEGER                          -- 软删时间（epoch ms，墓碑 deletedAt 来源）
);

-- 分组同步状态（每分组每后端一行，docs/05 §5）
CREATE TABLE group_sync_state (
  group_id       TEXT NOT NULL,
  backend_key    TEXT NOT NULL,
  base_rev       INTEGER NOT NULL,             -- 已确认的远端 rev（乐观锁基线）
  remote_etag    TEXT,                         -- WebDAV 条件请求用
  last_synced_group_json TEXT,                -- 上次同步副本 = 冲突合并的公共祖先（04 §6.3）
  last_synced_at INTEGER NOT NULL,
  PRIMARY KEY (group_id, backend_key)
);

-- 仅本地书籍标记（docs/10 §4.7c「仅本地 / 未上传」；仅本地表，不参与同步；schemaVersion 3 新增）
CREATE TABLE local_only_books (
  book_id    TEXT PRIMARY KEY,                 -- 对应 books.book_id；命中即永不参与 diff
  created_at INTEGER NOT NULL DEFAULT 0        -- 标记时间（epoch ms）
);

-- 应用级本地设置（accent 持久化等；仅本地表，不参与同步；schemaVersion 3 新增）
CREATE TABLE app_settings (
  key        TEXT PRIMARY KEY,                 -- 设置键（如 'accent'）
  value      TEXT NOT NULL                     -- JSON 文本或纯字符串
);
```

> **books 表不允许加列**（本文 §5 的 DDL 是同步语义的一部分）。需要新字段时
> 一律新表——`book_groups`（分组）、`local_only_books`（仅本地标记）、
> `app_settings`（通用设置）、`group_sync_state`（分组同步状态）都是这样
> 演进的先例。
>
> **`book_groups` 的软删语义**：本地删除分组 = 置 `deleted=1` +
> 组内书籍 `group_id` 置 NULL（回到未分组），**行保留**——离线删除时分组
> 墓碑仍可补推上云（docs/04 §7.1 分组同款语义）；墓碑上云成功后该行被
> 同步层硬删。UI 侧只展示活分组（`deleted=0`）。
>
> **`local_only_books` 的语义**：命中本表的书**永不参与 diff**（既不推 meta
> 也不传正文）。两种来源在 UI 上是同一个状态「仅本地」：导入时取消勾选
> 「同时上传到云端」；或「从云端移除」后各端因仍有 baseRev 落 diff 第 7b 行
> （云端缺失）。反向操作「上传到云端」= 删除本行 + **清除该书 `sync_state`
> 的 baseRev**（否则落第 7b 行上架不了，docs/10 §4.7c 实施要点 6）。

### 云端 JSON ↔ 本地表映射

| 云端字段 | 本地归属 |
| --- | --- |
| `book.*`（title/author/format/hash/size/toc 指纹） | `books` 表 |
| `progress.*` | `progress` 表（dirty=0 时与云端一致） |
| `reading.*` | `books.total_seconds` / `books.last_read_at` |
| `rev/baseRev` | `sync_state.base_rev`（`meta.rev` 以 `last_synced_meta_json` 为准） |
| `deleted/deletedAt` | `deleted_books` 表 |
| `deviceId/deviceName` | 不持久化到书表（仅存于 `last_synced_meta_json` 原文） |
| `groupId` | `books.group_id`（外键指向 `book_groups.group_id`；远端分组未到达时落 NULL，§2.2） |
| 分组 `name/sortOrder` | `book_groups.name` / `book_groups.sort_order` |
| 分组 `rev/baseRev` | `group_sync_state.base_rev`（`groups/*.json` 的 rev 以 `last_synced_group_json` 为准） |
| 分组 `deleted/deletedAt` | `book_groups.deleted` / `book_groups.deleted_at`（软删；行保留待推墓碑） |

## 6. schemaVersion 演进与迁移

| 版本 | 变更类型 | 规则 |
| --- | --- | --- |
| 1 | 初版 | — |
| 2 | 本地库新增 `reading_days` / `book_groups` 表与 `books.group_id` 列 | drift `schemaVersion` 1→2，**只增不删**；三者均为本地列/表，不入云端 meta JSON，v1 不参与同步 |
| 3 | 本地库新增 `local_only_books` / `app_settings` 表 | drift `schemaVersion` 2→3，**只增不删**（两张新表均为纯本地表，不入云端 meta JSON，不参与同步）；`local_only_books` 承载「仅本地 / 未上传」状态（docs/10 §4.7c），`app_settings` 承载应用级本地设置（如 accent 持久化） |
| 4 | 本地库新增 `group_sync_state` 表；`book_groups` 增 `deleted` / `deleted_at` 两列 | drift `schemaVersion` 3→4，**只增不删**（新增一张表 + 两列；`books` 表未动）；分组本体从"纯本地"升级为"参与云端同步"（FR-107，docs/05 §2.1）：分组对象以 `groups/{groupId}.json` 上云，书籍 meta 增**可选**字段 `groupId`（§2.2）。**云端 meta 的 `schemaVersion` 保持 1 不变**——新增的是可选字段，不改变既有字段的语义与类型，属"只增不删"的兼容演进（旧读方忽略未知键即可） |
| 5（当前） | **纯数据迁移，DDL 不变**：清理旧版「删正文、留元数据」语义留下的残影行 | drift `schemaVersion` 4→5，**DDL 完全不变**（只增不删不变式不受影响）；迁移删掉 `deleted_books` 有墓碑的 `books` 行（旧版软删除保留行、只置空 `local_path` → 落进书库「未下载」区永久显示）+ 其 `progress` / `reading_days` / `local_only_books` 子行（迁移在事务内跑、`PRAGMA foreign_keys` 尚未生效，级联不会自动触发 → 显式先删）。**墓碑账本保留**——它才是"已删除"的留痕（驱动云端 tombstone 推送与 90 天 GC）。删除语义见 docs/10 §4.7b / 04 §7.1 |
| 次版本演进（云端 meta 的 1 → 2） | **只允许**：新增可选字段、新增 `extra` 键、locator 新增 `type` | 旧客户端读到新版本：按已知字段使用 + `percent` 兜底，**不得报错**；写回时保留原 `schemaVersion` 不变，避免降级破坏。**实例**：`groupId`（§2.2）即属此类——只加可选字段，`schemaVersion` 仍为 1 |
| 分组 meta（`groups/*.json`）的演进 | 与书籍 meta 同规则（只增不删、读方容忍未知字段） | 分组是独立文件类型：老客户端根本不读 `groups/` 目录 → 分组同步对旧客户端零风险；旧客户端**写回**的书籍 meta 不含 `groupId` → 该书的分组归属降级为"未分组"（已知取舍，docs/07 登记） |
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
- schema 相关风险：[07-风险与待确认问题](./07-风险与待确认问题.md)
