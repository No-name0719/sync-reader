# 在**虚拟屏**上启动 SyncReader（Windows），并在虚拟屏上截图。
#
# 用途：验收/自查时不要在用户的主屏上弹窗——主屏是用户自己的工作区。
# 本机显示器：DISPLAY1（主屏 2560x1440）+ DISPLAY5（虚拟屏 2560x1600，
# 坐标 0,-1600，在主屏上方）。本脚本把应用窗口搬到虚拟屏并只在虚拟屏截图。
#
# 用法：
#   powershell -File scripts/run_virtual_display.ps1 [-ExePath <exe>] [-Shot <png>]
#                                               [-WaitSec 12] [-NoBuild] [-KeepRunning]
#
# 关键约束（踩过的坑）：
#  - 应用自己记住窗口位置（%APPDATA%\com.example\sync_reader\window_state.json，
#    logical 像素）。若把它改成虚拟屏坐标，用户**下次自己启动**时窗口就会跑
#    到虚拟屏上（主屏看不到窗口、只在任务栏有条目）——本脚本因此在启动前
#    备份、结束后**还原**该文件，绝不把用户的位置改掉。
#  - 验收结束后默认**关掉**测试实例：窗口在虚拟屏时，主屏任务栏仍会出现
#    应用条目，看着像「有图标没窗口」。要留着就加 -KeepRunning。
#
# 说明：窗口位置由 window_state.json 记忆，本脚本额外用 drive_app.ps1 的
# MoveToDisplay 兜底校正（启动后主动搬到虚拟屏）。

param(
    # 要启动的可执行文件（默认 Windows Release 构建产物）
    [string]$ExePath = "$PSScriptRoot\..\apps\sync_reader\build\windows\x64\runner\Release\sync_reader.exe",

    # 启动后等待秒数（首帧 + 恢复进度需要时间）
    [int]$WaitSec = 12,

    # 启动后截虚拟屏整屏到该路径（留空 = 不截图）
    [string]$Shot = '',

    # 跳过 flutter build（直接跑已有产物）
    [switch]$NoBuild,

    # 结束后保留测试实例（默认关掉，避免主屏任务栏出现「有图标没窗口」）
    [switch]$KeepRunning
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$drive = Join-Path $root 'scripts\drive_app.ps1'

# —— 窗口位置文件（备份 → 还原）——
$stateFiles = @(
    (Join-Path $env:APPDATA 'com.example\sync_reader\window_state.json'),
    (Join-Path $env:APPDATA 'com.example\SyncReader\window_state.json')
)
$stateBackup = @{}
foreach ($f in $stateFiles) {
    if (Test-Path $f) {
        $stateBackup[$f] = Get-Content -Raw -Encoding UTF8 $f
    }
}

function Restore-WindowState {
    # 写回必须**不带 BOM**：Dart 的 jsonDecode 遇 BOM 直接抛错（窗口位置读不出来
    # → 应用退回默认位置）。PS 5.1 的 Set-Content -Encoding UTF8 会加 BOM，
    # 故用 UTF8Encoding($false) 显式写。
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    foreach ($f in $stateFiles) {
        if ($stateBackup.ContainsKey($f)) {
            [System.IO.File]::WriteAllText($f, [string]$stateBackup[$f], $utf8NoBom)
        } elseif (Test-Path $f) {
            Remove-Item $f -Force
        }
    }
}

# 虚拟屏在不在？（不在就别白跑一趟构建，也别动用户的窗口位置）
Add-Type -AssemblyName System.Windows.Forms
$screenCount = ([System.Windows.Forms.Screen]::AllScreens | Measure-Object).Count
if ($screenCount -lt 2) {
    Write-Host 'WARNING: 未检测到第二块显示器（虚拟屏已断开？）——应用仍会启动，但只能在主屏显示。'
}

# 1) 构建（Release）
if (-not $NoBuild) {
    Write-Host 'building windows release...'
    Push-Location (Join-Path $root 'apps\sync_reader')
    try {
        & flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed' }
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path $ExePath)) { throw "exe not found: $ExePath" }

# 2) 杀掉旧实例（避免残留窗口在主屏上）
Get-Process sync_reader -ErrorAction SilentlyContinue | ForEach-Object {
    try { $_.Kill() } catch { }
}
Start-Sleep -Milliseconds 800

try {
    # 3) 启动
    Write-Host "launching $ExePath"
    Start-Process -FilePath $ExePath
    Start-Sleep -Seconds $WaitSec

    # 4) 搬到虚拟屏（不抢前台：用户主屏上的工作不受影响）
    if ($screenCount -ge 2) {
        & $drive -Action MoveToDisplay -Display secondary -Process sync_reader
    } else {
        Write-Host 'WARNING: 虚拟屏不可用，窗口留在主屏（请尽快断开测试实例，别挡住用户）'
    }
    & $drive -Action Rect -Process sync_reader

    # 5) 截图（只截虚拟屏那块矩形）
    if ($Shot -ne '') {
        $target = if ($screenCount -ge 2) { 'secondary' } else { 'primary' }
        & $drive -Action Screen -Display $target -Out $Shot
    }
} finally {
    # 6) 还原窗口位置 + 收摊（用户的窗口位置不被测试改掉）
    Restore-WindowState
    if (-not $KeepRunning) {
        Get-Process sync_reader -ErrorAction SilentlyContinue | ForEach-Object {
            try { $_.Kill() } catch { }
        }
        Write-Host 'test instance closed (window state restored)'
    }
}

Write-Host 'done.'
