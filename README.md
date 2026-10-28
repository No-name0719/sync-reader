# SyncReader

跨平台电子书进度同步阅读应用：免费、无容量限制；Android 与 Windows 共享同一书库与阅读进度，同步由你自己的坚果云（WebDAV）或自建服务器承载，软件本身不提供任何云服务、零收费、零遥测。

## 功能特性

**书库**

- 导入 txt / Markdown / PDF / EPUB（导入即复制），按内容哈希去重
- 搜索、排序、书籍详情与封面
- 批量导入（递归扫描 + 清单确认）
- 游离文件面板：挂回 / 清理未被元数据引用的正文文件

**阅读器**

- txt：编码自动检测 + 章节切分，分页 / 滚动双模式
- Markdown 渲染
- PDF：pdfium 渲染
- EPUB：块化渲染 + 分页 / 滚动 + 目录跳转
- 阅读设置（字号 / 主题）、目录抽屉、进度与阅读时长记录

**同步**

- 坚果云 WebDAV 引导配置 + 连接测试（自建服务器模式见 docs/06，后续交付）
- 元数据先行：日常同步只传 KB 级元数据，正文按需下载（占位书机制）
- 冲突按 LWW（rev → updatedAt → deviceId）合并；删除走 tombstone 语义，永不自动删正文
- 云端孤儿清理、文件替换同步、坚果云流量配额闸门
- 六种同步触发时机（启动 / 回前台 / 阅读中防抖 / 网络恢复 / 定时 / 手动）

## 下载安装

前往 [GitHub Releases](../../releases) 页面下载。

**Android**：下载对应 ABI 的 APK 直接侧载安装；不确定选哪个就选 `arm64-v8a`（2016 年后机型的主流 ABI），老设备选 `armeabi-v7a`，x86 模拟器选 `x86_64`。首次安装需在系统设置中允许「安装未知来源应用」。

**Windows**（x64）两种形态任选：

- `SyncReader-v*-windows-x64-setup.exe`：Inno Setup 安装器，双击安装、后续版本覆盖升级；
- `SyncReader-v*-windows-x64-portable.zip`：便携包，解压即用，适合免安装或绿色使用场景。

## 快速上手（坚果云同步，4 步）

1. 登录[坚果云网页版](https://www.jianguoyun.com)，进入「账户信息 → 安全选项」，添加一个**应用密码**；
2. 在 SyncReader 同步设置中填入坚果云账号（邮箱）与该应用密码（不是网页登录密码）；
3. 点击「连接测试」，提示通过即配置完成；
4. 在另一台设备重复第 2-3 步，两端书库与进度即可同步。

应用内引导页有同样的分步说明与失败排查提示。

## 从源码构建

依赖 Flutter 稳定通道（本机实测 3.47.8 stable / Dart 3.13.7；环境搭建与国内镜像、pdfium 预置等必看事项见 [docs/08-开发环境搭建.md](docs/08-开发环境搭建.md)）。

```bash
# Android（按 ABI 拆分）
flutter build apk --release --split-per-abi

# Windows
flutter build windows --release
```

正式发布产物（签名、安装器、便携包、产物命名）的完整流程见 [docs/09-发布与分发.md](docs/09-发布与分发.md)。

## 仓库结构

| 目录 | 内容 |
| --- | --- |
| `apps/sync_reader/` | Flutter 客户端（Android / Windows） |
| `packages/sync_core/` | 纯 Dart 同步核心（diff / 冲突合并 / 传输队列，无 Flutter 依赖） |
| `packages/third_party/` | 收编的第三方包副本（pdfrx、flutter_secure_storage_windows） |
| `server/` | Go 自建服务端（M5 交付，规划见 docs/06） |
| `docs/` | 设计基线文档（[docs/09-发布与分发.md](docs/09-发布与分发.md) 为发布基线） |

## 许可证

本项目以 [MIT](LICENSE) 许可证开源。第三方依赖的许可证与再分发声明（含收编包的修改说明）见 [docs/09-发布与分发.md](docs/09-发布与分发.md) §6。
