; ============================================================================
; SyncReader Windows 安装器脚本（Inno Setup 6）
;
; 本脚本不直接双击使用，由仓库根 scripts/package_release.ps1 调用 ISCC 编译，
; 通过命令行预处理定义（/D）传入以下变量：
;   AppVersion  ：应用版本号（不含 build 号的 semver，如 1.0.0）；未传时默认 0.0.0
;   ReleaseDir  ：flutter build windows 产物目录
;                 （apps/sync_reader/build/windows/x64/runner/Release）绝对路径，必传
;   OutputDir   ：安装器输出目录（仓库根 dist/）绝对路径，必传
;   LicenseFile ：可选；仓库根 LICENSE 绝对路径，未传时安装器不含许可页
;
; ISCC 典型调用（由 package_release.ps1 拼装）：
;   ISCC.exe /DAppVersion=1.0.0 /DReleaseDir=<Release 绝对路径>
;            /DOutputDir=<dist 绝对路径> /DLicenseFile=<LICENSE 绝对路径>
;            apps\sync_reader\windows\packaging\syncreader.iss
; ============================================================================

#define AppName "SyncReader"

#ifndef AppVersion
  ; 兜底版本号；正常流程 package_release.ps1 必传 /DAppVersion
  #define AppVersion "0.0.0"
#endif

#ifndef ReleaseDir
  #error 缺少 /DReleaseDir：请传入 flutter build windows 的 Release 产物目录绝对路径
#endif

#ifndef OutputDir
  #error 缺少 /DOutputDir：请传入发布产物目录（仓库根 dist/）绝对路径
#endif

[Setup]
; AppId：唯一标识本应用（写入 Windows 卸载注册表）。此 GUID 已固定，
; 后续版本必须保持不变——更换 GUID 会导致升级安装被识别为不同程序，出现双份安装。
AppId={{282211B2-276A-46C6-994A-8A9F091CE2CE}}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
; 控制面板“卸载程序”列表中的显示名
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\sync_reader.exe
; 安装器自身的图标：与应用图标、桌面快捷方式一致（蜂蜜黄圆角方 + 白色 R 标）。
; 路径相对本 .iss 文件；未设置时 Inno Setup 用自带默认图标（黑方块）。
SetupIconFile=..\runner\resources\app_icon.ico
; 默认安装目录：{autopf}\SyncReader
; - 本脚本默认以最低权限运行（见 PrivilegesRequired）→ 解析为用户目录
;   %LOCALAPPDATA%\Programs\SyncReader，无需管理员；
; - 用户以管理员覆盖运行时 → 解析为 Program Files\SyncReader。
DefaultDirName={autopf}\SyncReader
; 以最低权限运行安装器；允许在向导对话框或命令行（/ALLUSERS、/CURRENTUSER）
; 覆盖权限模式，兼顾“无管理员也能装到用户目录”与“管理员可全局安装”。
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
; 最低系统要求：Windows 10 1809（docs/07-A8 冻结的桌面端最低支持版本）
MinVersion=10.0.17763
; 产物输出位置与命名（最终文件：SyncReader-v{版本}-windows-x64-setup.exe）
OutputDir={#OutputDir}
OutputBaseFilename=SyncReader-v{#AppVersion}-windows-x64-setup
; 压缩：lzma2 最高档 + 固实压缩，尽量压小安装器体积
Compression=lzma2/max
SolidCompression=yes
; 不显示“程序组”选择页（开始菜单快捷方式仍会创建，见 [Icons]）
DisableProgramGroupPage=yes
; 按 64 位应用安装（管理员模式下装入 64 位 Program Files）；需要 Inno Setup 6.3+，
; 若使用 6.0~6.2 请把 x64compatible 改为 x64。
ArchitecturesInstallIn64BitMode=x64compatible

; 许可协议页：仅当 package_release.ps1 传入 /DLicenseFile 时启用；
; 未传时本段整块不参与编译，安装器不含许可页。
#ifdef LicenseFile
LicenseFile={#LicenseFile}
#endif

[Tasks]
; 可选的桌面快捷方式，默认不勾选（Flags: unchecked）
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; \
    GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; 将 Release 目录全部内容装入 {app}：sync_reader.exe、全部 dll、data\ 子目录等。
; - recursesubdirs：递归所有子目录（data\ 内含 flutter_assets 等层级）；
; - createallsubdirs：空子目录也照原样创建，保证与 Release 目录结构完全一致；
; - ignoreversion：无条件覆盖文件。Flutter 产物缺少版本资源，必须 ignoreversion，
;   否则升级安装时文件不会被覆盖。
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; \
    Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; 开始菜单快捷方式（PrivilegesRequired=lowest 时写入当前用户的开始菜单）
Name: "{autoprograms}\SyncReader"; Filename: "{app}\sync_reader.exe"
; 桌面快捷方式：仅当用户勾选 desktopicon 任务时创建
Name: "{autodesktop}\SyncReader"; Filename: "{app}\sync_reader.exe"; \
    Tasks: desktopicon

[Run]
; 安装完成后可选立即启动（静默安装时不显示该选项）
Filename: "{app}\sync_reader.exe"; \
    Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

; ----------------------------------------------------------------------------
; 备注（NFR-04 体积门）：安装器产物 SyncReader-v*-windows-x64-setup.exe <= 120MB
; 的体积校验由 scripts/package_release.ps1 统一负责，本 iss 不做重复校验。
; ----------------------------------------------------------------------------
