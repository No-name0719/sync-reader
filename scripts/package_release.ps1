# ============================================================================
# SyncReader 发布打包脚本（M4 Phase A）
#
# 职责：一键产出 Windows / Android 发布产物到仓库根 dist/ 目录：
#   - SyncReader-v{版本}-android-{abi}.apk          （单 ABI，split-per-abi）
#   - SyncReader-v{版本}-windows-x64-portable.zip   （便携包，zip 顶层目录为 SyncReader/）
#   - SyncReader-v{版本}-windows-x64-setup.exe      （Inno Setup 安装器，未装 ISCC 时跳过）
#
# 版本号单点来源：apps/sync_reader/pubspec.yaml 的 `version: <semver>+<build>`，
# 产物命名只取 semver 部分（不含 +build 号）。可用 -Version 覆盖产物命名
# （注意：仅影响产物文件名，应用内嵌版本仍由 flutter 构建时读 pubspec.yaml）。
#
# 安全约束：本脚本绝不读取、不回显任何签名材料。Android 签名由 gradle 内部
# 读取 gitignored 的 android/key.properties 完成，脚本只复制构建产物。
#
# 体积门（NFR-04）：任一单 ABI APK > 60MB 或 setup.exe > 120MB → 脚本以非零码失败；
# 便携 zip 只打印体积、不设门；ISCC 缺失导致安装器未生成时，对应体积门一并跳过。
#
# 兼容性：面向 Windows PowerShell 5.1 编写（无 ?: 三元、无 ??，全部用 if/else）。
#
# 用法示例：
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\package_release.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\package_release.ps1 -SkipAndroid
#   powershell ... -IsccPath "D:\softwares\node_env\innosetup\ISCC.exe" -OutDir "D:\tmp\dist"
# ============================================================================

param(
    # 跳过 Windows 桌面端构建（flutter build windows）
    [switch]$SkipWindows,

    # 跳过 Android 构建（flutter build apk --split-per-abi）
    [switch]$SkipAndroid,

    # 跳过 Inno Setup 安装器（即便探测到 ISCC 也不打包安装器）
    [switch]$SkipInstaller,

    # 跳过便携 zip 打包
    [switch]$SkipPortable,

    # 显式指定 ISCC.exe 完整路径（优先级最高）；不传则按探测顺序自动查找
    [string]$IsccPath = "",

    # 发布产物输出目录，默认仓库根下 dist\
    [string]$OutDir = "",

    # 覆盖产物命名所用版本号（默认从 pubspec.yaml 解析）
    [string]$Version = ""
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# 常量与路径
# ---------------------------------------------------------------------------
$RepoRoot = Split-Path -Parent $PSScriptRoot          # 脚本位于 <仓库根>\scripts\
$AppDir   = Join-Path $RepoRoot "apps\sync_reader"    # Flutter 应用目录
$Pubspec  = Join-Path $AppDir "pubspec.yaml"
$IssFile  = Join-Path $AppDir "windows\packaging\syncreader.iss"
$LicenseFile = Join-Path $RepoRoot "LICENSE"          # 仓库根 LICENSE（可选传入 iss）

# Windows 构建产物目录（exe 为 sync_reader.exe，旁边是 dll 与 data\）
$ReleaseDir = Join-Path $AppDir "build\windows\x64\runner\Release"
# Android 单 ABI APK 输出目录
$ApkDir = Join-Path $AppDir "build\app\outputs\flutter-apk"

# NFR-04 体积门（MB）
$ApkMaxMb   = 60
$SetupMaxMb = 120

# ---------------------------------------------------------------------------
# 输出辅助函数
# ---------------------------------------------------------------------------
function Write-Info([string]$Message) { Write-Host "[打包] $Message" }
function Write-Ok([string]$Message)   { Write-Host "[ OK ] $Message" -ForegroundColor Green }
function Write-Warn2([string]$Message){ Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Fail2([string]$Message){ Write-Host "[FAIL] $Message" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# 探测 flutter：探测不到时给出明确报错，提示先把 flutter/bin 加入 PATH
# ---------------------------------------------------------------------------
function Get-FlutterExe {
    if ($null -ne $script:FlutterExeCached) { return $script:FlutterExeCached }
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        Write-Fail2 "未在 PATH 中找到 flutter（flutter.bat）。"
        Write-Fail2 "请先把 Flutter 的 bin 目录加入 PATH 再运行本脚本，例如："
        Write-Fail2 '  $env:PATH += ";D:\softwares\node_env\flutter\bin"'
        exit 1
    }
    $script:FlutterExeCached = $cmd.Source
    return $script:FlutterExeCached
}

# ---------------------------------------------------------------------------
# 探测 Inno Setup 编译器 ISCC.exe，探测顺序：
#   1) -IsccPath 参数（显式指定，不存在则直接报错退出）
#   2) 环境变量 INNO_SETUP_HOME（拼接 ISCC.exe）
#   3) 常见安装路径（Program Files (x86) / Program Files / LocalAppData）
# 都找不到时：警告并返回 $null（跳过安装器，不算失败）
# ---------------------------------------------------------------------------
function Find-IsccExe {
    # 1) 显式参数
    if ($IsccPath -ne "") {
        if (-not (Test-Path -LiteralPath $IsccPath)) {
            Write-Fail2 "-IsccPath 指定的文件不存在：$IsccPath"
            exit 1
        }
        return $IsccPath
    }

    # 2) 环境变量 INNO_SETUP_HOME（未定义时为 $null，需先做空值守卫）
    if ($null -ne $env:INNO_SETUP_HOME -and $env:INNO_SETUP_HOME -ne "") {
        $candidate = Join-Path $env:INNO_SETUP_HOME "ISCC.exe"
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    # 3) 常见安装路径
    $commonPaths = @(
        "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
        "C:\Program Files\Inno Setup 6\ISCC.exe",
        (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe")
    )
    foreach ($p in $commonPaths) {
        if (Test-Path -LiteralPath $p) { return $p }
    }

    return $null
}

# ---------------------------------------------------------------------------
# 第 1 步：解析版本号（pubspec.yaml 单点来源）
# ---------------------------------------------------------------------------
$semver = ""
if ($Version -ne "") {
    # -Version 显式覆盖产物命名所用版本
    $semver = $Version
    Write-Info "版本号（-Version 覆盖）：$semver"
}
else {
    if (-not (Test-Path -LiteralPath $Pubspec)) {
        Write-Fail2 "找不到 pubspec.yaml：$Pubspec"
        exit 1
    }
    $raw = Get-Content -Raw -LiteralPath $Pubspec
    # 形如 version: 1.0.0+1，捕获 semver 与 build 两段
    $m = [regex]::Match($raw, '(?m)^version:\s*(\S+)\+(\d+)\s*$')
    if (-not $m.Success) {
        Write-Fail2 "pubspec.yaml 的 version 字段解析失败（期望格式：version: <semver>+<build>）。"
        exit 1
    }
    $semver      = $m.Groups[1].Value
    $buildNumber = $m.Groups[2].Value
    Write-Info "版本号（pubspec.yaml）：$semver（build $buildNumber，产物命名不含 build 号）"
}

# 产物命名期望纯 semver，若带预发布后缀（如 1.0.0-beta）仅提示不阻断
if ($semver -notmatch '^\d+\.\d+\.\d+$') {
    Write-Warn2 "版本号 $semver 不是标准 X.Y.Z 形式，产物名将原样使用。"
}

# ---------------------------------------------------------------------------
# 输出目录：默认仓库根 dist\；相对路径按当前工作目录补全
# ---------------------------------------------------------------------------
if ($OutDir -eq "") {
    $OutDir = Join-Path $RepoRoot "dist"
}
if (-not [System.IO.Path]::IsPathRooted($OutDir)) {
    $OutDir = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutDir))
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
Write-Info "产物输出目录：$OutDir"

# ---------------------------------------------------------------------------
# 第 2 步：Windows 桌面端构建（-SkipWindows 跳过；便携包/安装器复用该产物）
# ---------------------------------------------------------------------------
$needRelease = (-not $SkipWindows) -or (-not $SkipPortable) -or (-not $SkipInstaller)

if (-not $SkipWindows) {
    $flutter = Get-FlutterExe
    Write-Info "开始构建 Windows：flutter build windows --release"
    Push-Location $AppDir
    try {
        & $flutter build windows --release
        if ($LASTEXITCODE -ne 0) {
            Write-Fail2 "flutter build windows 失败（退出码 $LASTEXITCODE）。"
            exit 1
        }
    }
    finally {
        Pop-Location
    }
    Write-Ok "Windows 构建完成。"
}

# Release 目录完整性检查：exe 必须存在（便携包/安装器都依赖整个目录）
if ($needRelease) {
    if (-not (Test-Path -LiteralPath (Join-Path $ReleaseDir "sync_reader.exe"))) {
        Write-Fail2 "未找到 Windows 构建产物：$ReleaseDir\sync_reader.exe"
        Write-Fail2 "请先执行 flutter build windows --release（或去掉 -SkipWindows）。"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# 第 3 步：便携 zip（-SkipPortable 跳过）
# zip 顶层目录必须为 SyncReader/：先拷贝 Release 内容到临时目录的 SyncReader/
# 子目录，再用 .NET System.IO.Compression 压缩（Compress-Archive 不便控制
# 顶层目录结构，且此处需要稳定的 PS 5.1 行为）。
# ---------------------------------------------------------------------------
$portableZip = Join-Path $OutDir ("SyncReader-v{0}-windows-x64-portable.zip" -f $semver)
if (-not $SkipPortable) {
    Write-Info "打包便携 zip：$portableZip"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.IO.Compression

    $stageRoot = Join-Path $env:TEMP ("syncreader-portable-" + [guid]::NewGuid().ToString("N"))
    $stageApp  = Join-Path $stageRoot "SyncReader"
    New-Item -ItemType Directory -Path $stageApp -Force | Out-Null
    try {
        # 拷贝 Release 目录全部内容（exe + dll + data\）到 <临时目录>\SyncReader\
        Copy-Item -Path (Join-Path $ReleaseDir "*") -Destination $stageApp -Recurse -Force

        # CreateFromDirectory 不允许目标已存在，先清理旧 zip
        if (Test-Path -LiteralPath $portableZip) {
            Remove-Item -LiteralPath $portableZip -Force
        }
        # includeBaseDirectory=$false：以 stageRoot 为根，zip 内顶层即 SyncReader/
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $stageRoot, $portableZip,
            [System.IO.Compression.CompressionLevel]::Optimal,
            $false)
        Write-Ok "便携 zip 完成。"
    }
    finally {
        if (Test-Path -LiteralPath $stageRoot) {
            Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# 第 4 步：Inno Setup 安装器（-SkipInstaller 跳过；未找到 ISCC 时警告并跳过）
# ---------------------------------------------------------------------------
$setupExe     = Join-Path $OutDir ("SyncReader-v{0}-windows-x64-setup.exe" -f $semver)
$isccAvailable = $false
$installerAttempted = $false

if (-not $SkipInstaller) {
    $iscc = Find-IsccExe
    if ($null -eq $iscc) {
        Write-Warn2 "未找到 ISCC.exe（Inno Setup 6），跳过安装器打包（不算失败）。"
        Write-Warn2 "安装 Inno Setup 6 后重跑，或用 -IsccPath 显式指定 ISCC.exe 路径；"
        Write-Warn2 "详见 apps\sync_reader\windows\packaging\README.md。"
    }
    else {
        if (-not (Test-Path -LiteralPath $IssFile)) {
            Write-Fail2 "找不到 Inno Setup 脚本：$IssFile"
            exit 1
        }
        $isccAvailable = $true
        $installerAttempted = $true
        Write-Info "使用 ISCC：$iscc"
        Write-Info "编译安装器：$IssFile"

        $isccArgs = @()
        $isccArgs += "/DAppVersion=$semver"
        $isccArgs += "/DReleaseDir=$ReleaseDir"
        $isccArgs += "/DOutputDir=$OutDir"
        # LICENSE 可选：仓库根存在才传给 iss（iss 内用 #ifdef 决定是否显示许可页）
        if (Test-Path -LiteralPath $LicenseFile) {
            $isccArgs += "/DLicenseFile=$LicenseFile"
        }
        else {
            Write-Warn2 "仓库根不存在 LICENSE，跳过 /DLicenseFile（安装器将不含许可页）。"
        }
        $isccArgs += $IssFile

        & $iscc @isccArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Fail2 "ISCC 编译失败（退出码 $LASTEXITCODE）。"
            exit 1
        }
        Write-Ok "安装器完成：$setupExe"
    }
}

# ---------------------------------------------------------------------------
# 第 5 步：Android 构建（-SkipAndroid 跳过），复制改名到 dist
# 注意：本脚本不接触任何签名材料——key.properties 由 gradle 内部读取（已
# gitignore），脚本只复制 build 产物，绝不读取或回显任何密码/别名。
# ---------------------------------------------------------------------------
if (-not $SkipAndroid) {
    $flutter = Get-FlutterExe
    Write-Info "开始构建 Android：flutter build apk --release --split-per-abi"
    Push-Location $AppDir
    try {
        & $flutter build apk --release --split-per-abi
        if ($LASTEXITCODE -ne 0) {
            Write-Fail2 "flutter build apk 失败（退出码 $LASTEXITCODE）。"
            exit 1
        }
    }
    finally {
        Pop-Location
    }

    # 单 ABI APK：app-<abi>-release.apk → SyncReader-v{版本}-android-<abi>.apk
    $abis = @("arm64-v8a", "armeabi-v7a", "x86_64")
    foreach ($abi in $abis) {
        $src = Join-Path $ApkDir ("app-{0}-release.apk" -f $abi)
        $dst = Join-Path $OutDir ("SyncReader-v{0}-android-{1}.apk" -f $semver, $abi)
        if (-not (Test-Path -LiteralPath $src)) {
            Write-Fail2 "未找到 APK 产物：$src"
            exit 1
        }
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
    Write-Ok "Android APK 复制改名完成。"
}

# ---------------------------------------------------------------------------
# 第 6 步：汇总体积 + NFR-04 体积门校验
# 未生成的产物（如缺 ISCC 时的安装器）不参与打印与校验；便携 zip 只打印不设门。
# ---------------------------------------------------------------------------
Write-Info "========== 产物汇总（$OutDir） =========="
$gateFailures = @()

# 逐项构造：@($路径, 体积门上限 MB；$null 表示只打印不设门)
$summary = @()

# Android 单 ABI APK：门 60MB
$abis = @("arm64-v8a", "armeabi-v7a", "x86_64")
foreach ($abi in $abis) {
    $apk = Join-Path $OutDir ("SyncReader-v{0}-android-{1}.apk" -f $semver, $abi)
    if (Test-Path -LiteralPath $apk) {
        $summary += ,@($apk, $ApkMaxMb)
    }
}

# Windows 安装器：门 120MB（仅当确实尝试过编译且产物存在时才校验）
if ($installerAttempted) {
    if (Test-Path -LiteralPath $setupExe) {
        $summary += ,@($setupExe, $SetupMaxMb)
    }
}
elseif (-not $SkipInstaller) {
    Write-Info "（安装器因缺少 ISCC 被跳过，未生成、不参与体积门校验）"
}

# 便携 zip：只打印体积，不设门
if (-not $SkipPortable) {
    if (Test-Path -LiteralPath $portableZip) {
        $summary += ,@($portableZip, $null)
    }
}

foreach ($entry in $summary) {
    $path    = $entry[0]
    $limitMb = $entry[1]
    $item    = Get-Item -LiteralPath $path
    $sizeMb  = [math]::Round($item.Length / 1MB, 1)

    $line = ("{0}  {1,8:N1} MB" -f $item.Name, $sizeMb)
    if ($null -eq $limitMb) {
        Write-Host "$line"
    }
    else {
        Write-Host "$line  （体积门 <= $limitMb MB）"
        if ($sizeMb -gt $limitMb) {
            $gateFailures += ("{0} 体积 {1} MB 超过上限 {2} MB（NFR-04）" -f $item.Name, $sizeMb, $limitMb)
        }
    }
}

if ($gateFailures.Count -gt 0) {
    Write-Host ""
    foreach ($f in $gateFailures) {
        Write-Fail2 $f
    }
    Write-Fail2 "体积门校验未通过，以非零码退出。"
    exit 1
}

Write-Host ""
Write-Ok "全部产物打包完成，体积门校验通过。"
exit 0
