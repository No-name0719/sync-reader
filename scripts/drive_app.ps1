# SyncReader 桌面端（Windows）真机驱动脚本
#
# 用途：验收阶段驱动打包版 sync_reader.exe（点击 / 拖拽 / 滚轮 / 键入 /
#       窗口定位 / 窗口截图 / 全屏截图），供「原型 vs 实现」对照验收复用。
#
# 关键约束（踩过的坑）：
#  - 本机 2560x1440、DPI 125%。必须在 PER_MONITOR_AWARE_V2 进程里取
#    GetWindowRect / SetCursorPos，否则坐标被 DPI 虚拟化（差 1.25 倍）。
#    本脚本用 Add-Type 注册 Win32 API，并在调用前把进程置为 DPI 感知。
#  - VS Code 会抢前台：合成点击前必须先敲一下 Alt（消掉菜单态），再
#    SetForegroundWindow(target)，否则事件全落到编辑器上。
#  - Flutter 默认 dragDevices 不含鼠标 → 鼠标拖拽不能滚动；合成滚轮事件
#    对原生 Win32 列表框同样无效。滚轮相关结论必须人工用真实滚轮确认。
#
# 编码：文件必须存为 UTF-8 with BOM —— PowerShell 5.1 会把无 BOM 的
# UTF-8 中文解成乱码并导致语法解析失败。

param(
    [ValidateSet('Find', 'Focus', 'Click', 'ClickClient', 'Move', 'Drag', 'Wheel',
        'Keys', 'HoldKey', 'Shot', 'ShotClient', 'ClientRect', 'ResizeClient', 'Screen',
        'Rect', 'Resize', 'List', 'Displays', 'MoveToDisplay', 'RestoreFocus', 'Close')]
    [string]$Action = 'List',

    # 按窗口标题模糊匹配（默认匹配标题含该子串的窗口）
    [string]$Title = 'SyncReader',

    # 按进程名匹配（阅读页会把窗口标题改成书名，用进程名更稳）
    [string]$Process = '',

    # 动作参数
    [int]$X = 0,
    [int]$Y = 0,
    [int]$X2 = 0,
    [int]$Y2 = 0,
    [int]$Steps = 24,
    [int]$Clicks = 1,
    [int]$Delta = 0,
    [int]$Width = 0,
    [int]$Height = 0,
    [string]$Text = '',
    [string]$Out = '',
    [int]$Delay = 350,

    # HoldKey：按住键的时长（毫秒）
    [int]$HoldMs = 1500,

    # 目标显示器：'primary'（主屏）/ 'secondary'（第二屏，通常是虚拟屏）/
    # 序号（0,1…，按设备名里的数字排序）/ 设备名片段（如 'DISPLAY5'）。
    # 屏幕截图（Screen）与 MoveToDisplay 均以此为准——**默认只碰主屏，
    # 传 -Display secondary 才切到虚拟屏**，避免打扰主屏上的其他工作。
    [string]$Display = 'primary'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

if (-not ('Win32Drive' -as [type])) {
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class Win32Drive {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, IntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, IntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int X, int Y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr FindWindowW(string cls, string win);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc proc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc proc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT pt);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern int GetDeviceCaps(IntPtr hdc, int index);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP   = 0x0004;
    public const uint MOUSEEVENTF_RIGHTDOWN= 0x0008;
    public const uint MOUSEEVENTF_RIGHTUP  = 0x0010;
    public const uint MOUSEEVENTF_WHEEL    = 0x0800;
    public const uint MOUSEEVENTF_MOVE     = 0x0001;
    public const uint MOUSEEVENTF_ABSOLUTE = 0x8000;

    // PER_MONITOR_AWARE_V2 = -4
    public static void MakeDpiAware() {
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); }
        catch { SetProcessDPIAware(); }
    }
}
"@
}
[Win32Drive]::MakeDpiAware()

function Get-WindowList {
    param([string]$Filter = '', [string]$ProcName = '')
    $result = New-Object System.Collections.ArrayList
    $cb = [Win32Drive+EnumWindowsProc]{
        param($hWnd, $lParam)
        if (-not [Win32Drive]::IsWindowVisible($hWnd)) { return $true }
        $sb = New-Object System.Text.StringBuilder 512
        [void][Win32Drive]::GetWindowTextW($hWnd, $sb, 512)
        $winTitle = $sb.ToString()
        if ($winTitle -eq '') { return $true }
        # 注意：$pid 是 PowerShell 只读自动变量（当前进程 id），不能作参数名
        $procId = 0
        [void][Win32Drive]::GetWindowThreadProcessId($hWnd, [ref]$procId)
        if ($ProcName -ne '') {
            try {
                $pn = (Get-Process -Id $procId -ErrorAction Stop).ProcessName
                if ($pn -notlike $ProcName) { return $true }
            } catch { return $true }
        } elseif ($Filter -ne '' -and $winTitle -notlike "*$Filter*") {
            return $true
        }
        $r = New-Object Win32Drive+RECT
        [void][Win32Drive]::GetWindowRect($hWnd, [ref]$r)
        [void]$result.Add([pscustomobject]@{
            Handle  = $hWnd
            Title   = $winTitle
            X       = $r.Left
            Y       = $r.Top
            Width   = $r.Right - $r.Left
            Height  = $r.Bottom - $r.Top
            ProcessId = $procId
        })
        return $true
    }
    [void][Win32Drive]::EnumWindows($cb, [IntPtr]::Zero)
    return $result
}

function Get-TargetWindow {
    param([string]$Filter, [string]$ProcName = '')
    $wins = Get-WindowList -Filter $Filter -ProcName $ProcName
    if ($wins.Count -eq 0) {
        throw "no visible window matching (title='$Filter', proc='$ProcName')"
    }
    # 优先取前台窗口，其次取面积最大的匹配窗口
    $fg = [Win32Drive]::GetForegroundWindow()
    foreach ($w in $wins) { if ($w.Handle -eq $fg) { return $w } }
    return ($wins | Sort-Object { $_.Width * $_.Height } -Descending)[0]
}

function Set-WindowForeground {
    param($Win)
    # 记录驱动前的前台窗口，便于驱动完把焦点还给用户（RestoreFocus 动作）——
    # 合成点击/按键必须抢前台，但驱动不该把用户留在「被抢焦点」的状态。
    $script:PrevForeground = [Win32Drive]::GetForegroundWindow()
    # Alt 消掉菜单态，再置前——否则 VS Code 会吃掉合成点击
    [Win32Drive]::keybd_event(0x12, 0, 0, [IntPtr]::Zero)      # ALT down
    [Win32Drive]::keybd_event(0x12, 0, 2, [IntPtr]::Zero)      # ALT up
    [void][Win32Drive]::ShowWindow($Win.Handle, 9)              # SW_RESTORE
    [void][Win32Drive]::BringWindowToTop($Win.Handle)
    [void][Win32Drive]::SetForegroundWindow($Win.Handle)
    Start-Sleep -Milliseconds 180
}

# —— 显示器（虚拟屏）——
#
# 本机接了虚拟屏：主屏 DISPLAY1（2048x1152，primary）+ 虚拟屏
# DISPLAY5（1280x800，坐标 0,-1280，在主屏**上方**）。驱动与截图默认只碰
# 主屏；跑验收一律显式 -Display secondary，把窗口搬到虚拟屏上，截图也只
# 截虚拟屏那块矩形，绝不打扰用户在主屏上的操作。

function Get-DisplayList {
    # 显示器列表：按设备名里的数字排序（DISPLAY1, DISPLAY5, DISPLAY10…）。
    $screens = [System.Windows.Forms.Screen]::AllScreens |
        Sort-Object { [int](($_.DeviceName -replace '\D', '')) }
    $i = 0
    foreach ($s in $screens) {
        [pscustomobject]@{
            Index       = $i
            DeviceName  = $s.DeviceName
            X           = $s.Bounds.X
            Y           = $s.Bounds.Y
            Width       = $s.Bounds.Width
            Height      = $s.Bounds.Height
            Primary     = $s.Primary
            BitsPerPixel = $s.BitsPerPixel
        }
        $i++
    }
}

function Resolve-Display {
    # -Display 规格 → 显示器对象：primary / secondary / 序号 / 设备名片段。
    param([string]$Spec)
    $list = @(Get-DisplayList)
    if ($list.Count -eq 0) { throw 'no display found' }
    if ($Spec -eq '' -or $Spec -eq 'primary') {
        return $list | Where-Object { $_.Primary } | Select-Object -First 1
    }
    if ($Spec -eq 'secondary') {
        return $list | Where-Object { -not $_.Primary } | Select-Object -First 1
    }
    if ($Spec -match '^\d+$') {
        return $list[[int]$Spec]
    }
    return $list | Where-Object { $_.DeviceName -like "*$Spec*" } | Select-Object -First 1
}

function Invoke-Click {
    param([int]$CX, [int]$CY, [int]$Count = 1)
    [void][Win32Drive]::SetCursorPos($CX, $CY)
    Start-Sleep -Milliseconds 60
    for ($i = 0; $i -lt $Count; $i++) {
        [Win32Drive]::mouse_event([Win32Drive]::MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 40
        [Win32Drive]::mouse_event([Win32Drive]::MOUSEEVENTF_LEFTUP, 0, 0, 0, [IntPtr]::Zero)
        if ($Count -gt 1) { Start-Sleep -Milliseconds 90 }
    }
}

function Invoke-Drag {
    param([int]$X1, [int]$Y1, [int]$X2, [int]$Y2, [int]$StepCount = 24)
    [void][Win32Drive]::SetCursorPos($X1, $Y1)
    Start-Sleep -Milliseconds 80
    [Win32Drive]::mouse_event([Win32Drive]::MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    for ($i = 1; $i -le $StepCount; $i++) {
        $t = $i / [double]$StepCount
        $cx = [int]($X1 + ($X2 - $X1) * $t)
        $cy = [int]($Y1 + ($Y2 - $Y1) * $t)
        [void][Win32Drive]::SetCursorPos($cx, $cy)
        Start-Sleep -Milliseconds 12
    }
    Start-Sleep -Milliseconds 60
    [Win32Drive]::mouse_event([Win32Drive]::MOUSEEVENTF_LEFTUP, 0, 0, 0, [IntPtr]::Zero)
}

function Save-WindowShot {
    param($Win, [string]$Path)
    $r = New-Object Win32Drive+RECT
    [void][Win32Drive]::GetWindowRect($Win.Handle, [ref]$r)
    $w = $r.Right - $r.Left
    $h = $r.Bottom - $r.Top
    if ($w -le 0 -or $h -le 0) { throw "window has zero size" }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Host "saved $Path ($w x $h)"
}

function Save-ScreenShot {
    param([string]$Path, [string]$Spec = 'primary')
    $d = Resolve-Display -Spec $Spec
    if ($null -eq $d) { throw "display not found: $Spec" }
    $bmp = New-Object System.Drawing.Bitmap($d.Width, $d.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($d.X, $d.Y, 0, 0, $bmp.Size)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Host "saved $Path (display $($d.DeviceName) $($d.Width) x $($d.Height) at $($d.X),$($d.Y))"
}

function Get-WindowScale {
    # 窗口所在显示器的 DPI 缩放（96 = 100%）。本机 125% → 1.25。
    param($Win)
    $hdc = [Win32Drive]::GetDC($Win.Handle)
    $dpi = 96
    try {
        $dpi = [Win32Drive]::GetDeviceCaps($hdc, 88)  # LOGPIXELSX
    } finally {
        [void][Win32Drive]::ReleaseDC($Win.Handle, $hdc)
    }
    if ($dpi -le 0) { $dpi = 96 }
    return [math]::Round($dpi / 96.0, 4)
}

function Get-ClientRect {
    # 客户区（去掉标题栏与边框）在屏幕上的物理矩形
    param($Win)
    $cr = New-Object Win32Drive+RECT
    [void][Win32Drive]::GetClientRect($Win.Handle, [ref]$cr)
    $p = New-Object Win32Drive+POINT
    $p.X = 0; $p.Y = 0
    [void][Win32Drive]::ClientToScreen($Win.Handle, [ref]$p)
    return [pscustomobject]@{
        X = $p.X
        Y = $p.Y
        Width = $cr.Right - $cr.Left
        Height = $cr.Bottom - $cr.Top
    }
}

function Save-ClientShot {
    # 只截客户区（阅读页内容区，不含 Windows 标题栏），便于与原型视口对照
    param($Win, [string]$Path)
    $cr = Get-ClientRect -Win $Win
    if ($cr.Width -le 0 -or $cr.Height -le 0) { throw "client area has zero size" }
    $bmp = New-Object System.Drawing.Bitmap($cr.Width, $cr.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($cr.X, $cr.Y, 0, 0, (New-Object System.Drawing.Size($cr.Width, $cr.Height)))
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Host "saved $Path (client $($cr.Width) x $($cr.Height) at $($cr.X),$($cr.Y))"
}

switch ($Action) {
    'List' {
        Get-WindowList -ProcName $Process | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    }
    'Find' {
        $w = Get-TargetWindow -Filter $Title -ProcName $Process
        $w | Format-List | Out-String | Write-Host
    }
    'Focus' {
        $w = Get-TargetWindow -Filter $Title -ProcName $Process
        Set-WindowForeground -Win $w
        Write-Host "focused: $($w.Title) @ $($w.X),$($w.Y) $($w.Width)x$($w.Height)"
    }
    'Click' {
        $w = Get-TargetWindow -Filter $Title -ProcName $Process
        Set-WindowForeground -Win $w
        Invoke-Click -CX $X -CY $Y -Count $Clicks
        Start-Sleep -Milliseconds $Delay
        Write-Host "clicked $X,$Y (screen)"
    }
    'ClickClient' {
        # 客户区相对坐标（0..1000 的千分比）：自动换算成屏幕物理像素。
        # 比用屏幕绝对坐标稳——窗口移动后不必重算。
        $w = Get-TargetWindow -Filter $Title -ProcName $Process
        Set-WindowForeground -Win $w
        $cr = Get-ClientRect -Win $w
        $sx = $cr.X + [int]($cr.Width * $X / 1000)
        $sy = $cr.Y + [int]($cr.Height * $Y / 1000)
        Invoke-Click -CX $sx -CY $sy -Count $Clicks
        Start-Sleep -Milliseconds $Delay
        Write-Host "clicked client($X,$Y)/1000 -> screen $sx,$sy"
    }
    'Move' {
        $w = Get-TargetWindow -Filter $Title -ProcName $Process
        Set-WindowForeground -Win $w
        [void][Win32Drive]::SetCursorPos($X, $Y)
        Start-Sleep -Milliseconds 120
        Write-Host "moved to $X,$Y"
    }
    'Drag' {
        $w = Get-TargetWindow -Filter $Title -ProcName $Process
        Set-WindowForeground -Win $w
        Invoke-Drag -X1 $X -Y1 $Y -X2 $X2 -Y2 $Y2 -StepCount $Steps
        Start-Sleep -Milliseconds $Delay
        Write-Host "dragged $X,$Y -> $X2,$Y2"
    }
    'Wheel' {
        # 注意：合成滚轮事件对 Flutter 默认 ScrollBehavior 与原生 Win32 列表框
        # 都可能无效；此类结论必须人工用真实滚轮确认。
        $w = Get-TargetWindow -Filter $Title -ProcName $Process
        Set-WindowForeground -Win $w
        [void][Win32Drive]::SetCursorPos($X, $Y)
        Start-Sleep -Milliseconds 60
        $notches = [math]::Abs($Delta)
        for ($i = 0; $i -lt $notches; $i++) {
            $d = if ($Delta -lt 0) { 120 } else { -120 }
            # 负 delta 转 uint32：PS 的 -band 会按 Int32 符号位得到负数，
            # [uint32] 转换直接抛异常（Wheel 正向注入从未生效），手动加 2^32。
            $u = $d
            if ($u -lt 0) { $u = $u + 4294967296 }
            [Win32Drive]::mouse_event([Win32Drive]::MOUSEEVENTF_WHEEL, 0, 0, [uint32]$u, [IntPtr]::Zero)
            Start-Sleep -Milliseconds 40
        }
        Start-Sleep -Milliseconds $Delay
        Write-Host "wheel $Delta at $X,$Y"
    }
    'Keys' {
        $w = Get-TargetWindow -Filter $Title -ProcName $Process
        Set-WindowForeground -Win $w
        [System.Windows.Forms.SendKeys]::SendWait($Text)
        Start-Sleep -Milliseconds $Delay
        Write-Host "sent keys"
    }
    'HoldKey' {
        # 按住某个键一段时间（KEYDOWN → 等待 → KEYUP）：验证**按键自动重复**
        # 的行为（如阅读页「按住↓一直翻页停不下来」）。键名用虚拟键码名：
        # DOWN/UP/LEFT/RIGHT/SPACE/PGUP/PGDN。
        $w = Get-TargetWindow -Filter $Title -ProcName $Process
        Set-WindowForeground -Win $w
        $codes = @{ DOWN = 0x28; UP = 0x26; LEFT = 0x25; RIGHT = 0x27;
                    SPACE = 0x20; PGUP = 0x21; PGDN = 0x22 }
        $key = $Text.ToUpper()
        if (-not $codes.ContainsKey($key)) { throw "unknown key: $Text" }
        $vk = [byte]$codes[$key]
        [Win32Drive]::keybd_event($vk, 0, 0, [IntPtr]::Zero)          # KEYDOWN
        Start-Sleep -Milliseconds $HoldMs
        [Win32Drive]::keybd_event($vk, 0, 2, [IntPtr]::Zero)          # KEYUP
        Start-Sleep -Milliseconds $Delay
        Write-Host "held $key for ${HoldMs}ms"
    }
    'Shot' {
        $w = Get-TargetWindow -Filter $Title -ProcName $Process
        if ($Out -eq '') { $Out = "$PWD\shot.png" }
        Save-WindowShot -Win $w -Path $Out
    }
    'ShotClient' {
        $w = Get-TargetWindow -Filter $Title -ProcName $Process
        if ($Out -eq '') { $Out = "$PWD\shot.png" }
        Save-ClientShot -Win $w -Path $Out
    }
    'ClientRect' {
        $w = Get-TargetWindow -Filter $Title -ProcName $Process
        $cr = Get-ClientRect -Win $w
        $sc = Get-WindowScale -Win $w
        Write-Host "client=$($cr.Width)x$($cr.Height) at $($cr.X),$($cr.Y) | scale=$sc | logical=$([int]($cr.Width/$sc))x$([int]($cr.Height/$sc))"
    }
    'ResizeClient' {
        # 把客户区调成指定**逻辑**像素尺寸（自动乘以 DPI 缩放）。
        # 例：-Width 1440 -Height 900 在 125% 屏上得到 1800x1125 物理像素。
        $w = Get-TargetWindow -Filter $Title -ProcName $Process
        Set-WindowForeground -Win $w
        $sc = Get-WindowScale -Win $w
        $physW = [int][math]::Round($Width * $sc)
        $physH = [int][math]::Round($Height * $sc)
        # 先按目标客户区反推整个窗口尺寸（边框 + 标题栏由系统决定 → 先放大再校正）
        # 注意：局部变量名不要与参数 $Title 同名（PowerShell 变量名大小写不敏感）
        $r = New-Object Win32Drive+RECT
        [void][Win32Drive]::GetWindowRect($w.Handle, [ref]$r)
        $targetW = $physW + 16
        $targetH = $physH + 60
        # SWP_NOMOVE(0x0002) | SWP_NOZORDER(0x0004) | SWP_NOACTIVATE(0x0010)：
        # 只改尺寸、保留位置（否则会把窗口挪到屏幕原点 —— 旧代码漏了 NOMOVE，
        # 一 resize 就把虚拟屏上的窗口弹回主屏左上角）。
        [void][Win32Drive]::SetWindowPos($w.Handle, [IntPtr]::Zero, 0, 0, $targetW, $targetH, 0x0002 -bor 0x0004 -bor 0x0010)
        Start-Sleep -Milliseconds 600
        $w2 = Get-TargetWindow -Filter $Title -ProcName $Process
        $cr2 = Get-ClientRect -Win $w2
        Write-Host "requested logical ${Width}x${Height} (scale $sc) -> client $($cr2.Width)x$($cr2.Height) = logical $([int]($cr2.Width/$sc))x$([int]($cr2.Height/$sc))"
    }
    'Screen' {
        if ($Out -eq '') { $Out = "$PWD\screen.png" }
        Save-ScreenShot -Path $Out -Spec $Display
    }
    'Displays' {
        # 列出全部显示器（含虚拟屏）及其矩形/DPI 缩放，供选屏用。
        Get-DisplayList | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    }
    'MoveToDisplay' {
        # 把目标窗口搬到指定显示器（左上角 + 铺满工作区），**不抢前台**：
        # 用户在主屏上继续干活，应用只在虚拟屏上显示。
        $w = Get-TargetWindow -Filter $Title -ProcName $Process
        $d = Resolve-Display -Spec $Display
        if ($null -eq $d) { throw "display not found: $Display" }
        # SWP_NOZORDER(0x0004) | SWP_NOACTIVATE(0x0010)：不动 Z 序、不激活
        # 先 SW_RESTORE：最大化窗口下 SetWindowPos 的尺寸会被系统忽略。
        [void][Win32Drive]::ShowWindow($w.Handle, 9)
        [void][Win32Drive]::SetWindowPos(
            $w.Handle, [IntPtr]::Zero,
            $d.X + 8, $d.Y + 8, $d.Width - 16, $d.Height - 16, 0x0004 -bor 0x0010)
        Start-Sleep -Milliseconds 500
        $w2 = Get-TargetWindow -Filter $Title -ProcName $Process
        $sc = Get-WindowScale -Win $w2
        Write-Host "moved to display $($d.DeviceName) ($($d.X),$($d.Y)) -> window $($w2.Width)x$($w2.Height) at $($w2.X),$($w2.Y) | scale=$sc"
    }
    'Close' {
        # 关闭耗时实测：发 WM_CLOSE（等同点标题栏的 X）→ 轮询窗口何时消失，
        # 再等进程退出 → 分别报「窗口消失」与「进程退出」的耗时（毫秒）。
        $w = Get-TargetWindow -Filter $Title -ProcName $Process
        $pid0 = $w.ProcessId
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        [void][Win32Drive]::PostMessage($w.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)  # WM_CLOSE
        $gone = -1
        while ($sw.ElapsedMilliseconds -lt 120000) {
            if (-not [Win32Drive]::IsWindow($w.Handle)) { $gone = $sw.ElapsedMilliseconds; break }
            Start-Sleep -Milliseconds 20
        }
        $exited = -1
        while ($sw.ElapsedMilliseconds -lt 120000) {
            $alive = Get-Process -Id $pid0 -ErrorAction SilentlyContinue
            if (-not $alive) { $exited = $sw.ElapsedMilliseconds; break }
            Start-Sleep -Milliseconds 20
        }
        Write-Host "close: window-gone=$gone ms, process-exit=$exited ms"
    }
    'RestoreFocus' {
        # 把前台焦点还给驱动前的窗口（用户的主屏工作不被夺走）。
        if ($script:PrevForeground -eq [IntPtr]::Zero) {
            Write-Host 'no previous foreground recorded'
        } else {
            [void][Win32Drive]::SetForegroundWindow($script:PrevForeground)
            Write-Host "restored foreground $($script:PrevForeground)"
        }
    }
    'Rect' {
        $w = Get-TargetWindow -Filter $Title -ProcName $Process
        Write-Host "title=$($w.Title) x=$($w.X) y=$($w.Y) w=$($w.Width) h=$($w.Height) pid=$($w.ProcessId)"
    }
    'Resize' {
        $w = Get-TargetWindow -Filter $Title -ProcName $Process
        Set-WindowForeground -Win $w
        # SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE：只改尺寸，保留位置
        [void][Win32Drive]::SetWindowPos($w.Handle, [IntPtr]::Zero, 0, 0, $Width, $Height, 0x0002 -bor 0x0004 -bor 0x0010)
        Start-Sleep -Milliseconds 500
        $w2 = Get-TargetWindow -Filter $Title -ProcName $Process
        Write-Host "resized to $($w2.Width)x$($w2.Height)"
    }
}
