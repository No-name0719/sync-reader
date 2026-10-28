# Changelog

本文件记录 SyncReader 的所有显著变更。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 原则，版本号遵循[语义化版本（SemVer）](https://semver.org/lang/zh-CN/)。条目使用中文，新增条目写在文件顶部。

## 1.0.0 - 2026-10-28

首个公开发布版本。

### Added

- **书库管理**
  - 本地导入 txt / Markdown / PDF / EPUB（导入即复制），按内容哈希去重
  - 书库搜索、排序、书籍详情与封面展示
  - 批量导入（目录递归扫描 + 导入清单确认）
  - 游离文件面板：扫描未被元数据引用的正文文件，支持按内容哈希挂回与彻底删除
  - 分组标签（本地分类）：建组 / 重命名 / 删除，书卡长按拖拽归组（拖拽中浮现落点栏）；不参与同步
  - 书库筛选（右上角下拉，单选）：全部 / 未分组 / 未下载（占位书）/ 分组
- **阅读器**
  - txt：编码自动检测 + 章节切分，分页 / 滚动双模式
  - Markdown 渲染
  - PDF：pdfium 渲染（pdfrx）
  - EPUB：解析后块化渲染，分页 / 滚动双模式，目录（NCX）跳转，图片内嵌渲染（含 svg 包裹图形页与路径大小写兼容）
  - 阅读设置（字号 / 主题等）热应用，全局目录（TOC）抽屉
  - 阅读进度与阅读时长本地记录，详情页展示最近 7 天按天统计
  - 音量键翻页（Android，阅读设置开关，默认关闭）
- **同步**
  - 坚果云 WebDAV 引导式配置（4 步）与连接测试
  - 元数据先行：日常同步只传 KB 级 meta JSON，正文按需下载（占位书机制）
  - LWW（rev → updatedAt → deviceId）冲突合并
  - 删除 = tombstone 墓碑语义，永不自动删除正文文件
  - 云端孤儿清理工具（逐文件确认、批量可暂停、配额联动）
  - 文件替换：重新选择文件后全端覆盖更新
  - 坚果云流量配额闸门（80% 常驻提醒）
  - 六种同步触发时机（启动 / 回前台 / 阅读中防抖 / 网络恢复 / 定时 / 手动）
- **打磨与分发**
  - Android 正式签名 + 按 ABI 拆分 APK（arm64-v8a / armeabi-v7a / x86_64）
  - Windows 分发：Inno Setup 安装器 + zip 便携包双形态
  - 启动性能打点与优化（Android 中端机冷启动 ≤2.5s、Windows ≤3s）

### 格式约定

- 版本号：语义化版本 `major.minor.patch+build`（如 `1.0.0+1`），**单点维护**于 [`apps/sync_reader/pubspec.yaml`](apps/sync_reader/pubspec.yaml) 的 `version` 字段；本文件条目标题使用不含 build 号的 semver（与发布产物命名一致）。
- 发布流程、产物命名与第三方声明见 [docs/09-发布与分发.md](docs/09-发布与分发.md)。
