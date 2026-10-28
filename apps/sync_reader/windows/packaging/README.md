# windows/packaging — Windows 桌面端打包脚本

本目录存放 SyncReader Windows 安装器（Inno Setup 6）的打包脚本，与仓库根的
`scripts/package_release.ps1` 配合完成 M4 Phase A 的 Windows 分发产物。

## 目录内文件职责

| 文件 | 职责 |
| --- | --- |
| `syncreader.iss` | Inno Setup 6 安装器脚本。由 `package_release.ps1` 探测到 ISCC.exe 后调用编译，产出 `SyncReader-v<版本>-windows-x64-setup.exe` 到仓库根 `dist/`。版本号、Release 目录、输出目录、LICENSE 均通过 ISCC 的 `/D` 预处理定义传入。 |
| `README.md` | 本说明。 |

> 便携包 `SyncReader-v<版本>-windows-x64-portable.zip`（zip 内顶层目录为 `SyncReader/`）
> 不经过 Inno Setup，由 `package_release.ps1` 直接用 .NET `System.IO.Compression`
> 压缩 Release 目录生成；Android APK 同样由该脚本复制改名到 `dist/`。

## 与 scripts/package_release.ps1 的调用关系

`scripts/package_release.ps1` 的完整流程：

1. 从 `apps/sync_reader/pubspec.yaml` 解析 `version: <semver>+<build>`，取 semver 作为产物命名版本；
2. `flutter build windows --release`，产物目录
   `apps/sync_reader/build/windows/x64/runner/Release/`（`sync_reader.exe` + dll + `data\`）；
3. 将 Release 目录内容压成便携 zip（顶层 `SyncReader/`）；
4. 探测 ISCC.exe，找到则执行：
   `ISCC.exe /DAppVersion=<v> /DReleaseDir=<Release 绝对路径> /DOutputDir=<dist 绝对路径> /DLicenseFile=<仓库根 LICENSE> windows\packaging\syncreader.iss`；
5. `flutter build apk --release --split-per-abi`，三个单 ABI APK 复制改名到 `dist/`；
6. 汇总打印产物体积并执行 NFR-04 体积门：单 ABI APK ≤ 60MB、setup.exe ≤ 120MB，
   超限脚本以非零码退出；便携 zip 只打印体积不设门；缺 ISCC 时安装器跳过、
   对应体积门一并跳过（iss 内不做重复校验）。

## 未安装 Inno Setup 时的两种安装方式

`package_release.ps1` 探测不到 ISCC.exe 时只**警告并跳过**安装器打包（APK 与便携包
不受影响），不算失败。需要产出安装器时，任选其一安装 Inno Setup 6：

1. **管理员安装（常规）**：直接运行官方 `innosetup-6.x.x.exe` 安装向导，默认安装到
   `C:\Program Files (x86)\Inno Setup 6`，脚本可自动探测到。

2. **无管理员权限（静默装到自选目录）**：Inno 官方安装器本身即 Inno 打包，原生支持
   静默、指定目录与“仅当前用户”参数，例如装到 D 盘：

   ```
   innosetup-6.x.x.exe /VERYSILENT /CURRENTUSER /DIR="D:\softwares\node_env\innosetup"
   ```

   安装后让脚本找到 ISCC.exe 的两种方式（任选其一）：
   - 设置环境变量 `INNO_SETUP_HOME=D:\softwares\node_env\innosetup`；
   - 或运行脚本时传参 `-IsccPath "D:\softwares\node_env\innosetup\ISCC.exe"`。

## ISCC.exe 探测顺序（package_release.ps1 实现）

`-IsccPath` 参数 → 环境变量 `INNO_SETUP_HOME`（拼 `ISCC.exe`）→ 常见路径
（`C:\Program Files (x86)\Inno Setup 6\ISCC.exe`、`C:\Program Files\Inno Setup 6\ISCC.exe`、
`%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe`）→ 均未找到则警告并跳过安装器。
