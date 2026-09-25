# ============================================================
#  桌面悬浮歌词 for Spotify  ——  Spotify Desktop Lyrics Overlay
#  版本：v8.1
#  许可：MIT
#
#  特性
#   · 免账号/免 API key/免 Premium：曲目信息来自 Windows SMTC
#   · 三行显示：原文 / 中文翻译 / 下一句（中间行永不空着）
#   · KTV 逐字变色：当前行按播放进度从左到右渐变
#   · 字幕颜色、字号、间距、对齐方式全部可调
#   · 未锁定时可鼠标拖动、悬停手柄改字号；锁定后鼠标穿透
#   · 歌词源：LRCLIB（原文）+ 网易云（逐行中文翻译），本地缓存
#
#  性能
#   · 画面由 CompositionTarget.Rendering 驱动（每帧回调，与 VSync 对齐）
#   · 播放位置采用「Stopwatch 逐帧累加 + 平滑吸收 SMTC 误差」模型
#
#  环境：Windows 10/11 + Windows PowerShell 5.1 + Node.js
# ============================================================

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 顶层错误陷阱：静默启动（vbs）失败时也能弹框告知
trap {
    $msg = "悬浮歌词启动/运行失败：`n`n$($_.Exception.Message)"
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue } catch { }
    try { [System.Windows.Forms.MessageBox]::Show($msg, 'Spotify 桌面悬浮歌词', 'OK', 'Error') | Out-Null } catch { }
    try { Add-Content -LiteralPath (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'lyrics-overlay.log') -Value ("FATAL  " + $_.Exception.Message) -Encoding UTF8 } catch { }
    exit 1
}

# ---------- 路径 ----------
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir 'lyrics-overlay.json'
$LogPath    = Join-Path $ScriptDir 'lyrics-overlay.log'
$FetchJs    = Join-Path $ScriptDir 'lyrics-fetch.js'
$ReqFile    = Join-Path $ScriptDir '_lyr_req.json'
$OutFile    = Join-Path $ScriptDir '_lyr_out.json'
$CacheFile  = Join-Path $ScriptDir 'lyrics-cache.json'

$NodeExe = $null
foreach ($c in @(
    (Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
    (Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
    "$env:ProgramFiles\nodejs\node.exe",
    "${env:ProgramFiles(x86)}\nodejs\node.exe",
    "$env:LOCALAPPDATA\Programs\nodejs\node.exe"
)) {
    if ($c -and (Test-Path $c)) { $NodeExe = $c; break }
}

# ---------- 日志（512KB 轮转） ----------
try {
    if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 512KB) {
        if (Test-Path "$LogPath.old") { Remove-Item "$LogPath.old" -Force -ErrorAction SilentlyContinue }
        Move-Item $LogPath "$LogPath.old" -Force -ErrorAction SilentlyContinue
    }
} catch { }

$script:LastLog = [datetime]::MinValue
function Log([string]$m, [switch]$Throttle) {
    $now = Get-Date
    if ($Throttle -and ($now - $script:LastLog).TotalSeconds -lt 5) { return }
    $script:LastLog = $now
    try { Add-Content -LiteralPath $LogPath -Value ("{0}  {1}" -f $now.ToString('HH:mm:ss'), $m) -Encoding UTF8 } catch { }
}

# ---------- 单实例 ----------
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\SpotifyDesktopLyricsOverlay')
if (-not $script:Mutex.WaitOne(0)) {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show('桌面歌词已经在运行了（看托盘图标）。', 'Spotify 桌面悬浮歌词', 'OK', 'Information') | Out-Null
    } catch { }
    exit 0
}

# ---------- 配置 ----------
$CFG = [ordered]@{
    AnchorX          = -1
    Top              = -1
    Anchor           = 'center'    # center | left | right
    FontSize         = 30
    TransFontSize    = 20
    NextFontSize     = 17
    FollowMain       = $true
    TransRatio       = 0.66
    NextRatio        = 0.56
    ShowTrans        = $true
    ShowNextLine     = $true
    MaxWidth         = 1200
    TextColor        = '#FFFFFFFF'
    TransColor       = '#D9FFE9B0'
    NextColor        = '#73FFE9B0'
    Karaoke          = $true
    KaraokeBaseColor = '#59FFFFFF'
    LyricsOffset     = 0.0         # 秒，正值 = 歌词提前
    Shadow           = $true
    Locked           = $false
    GapScale         = 1.0
    PollMs           = 500         # 只用于查询 SMTC；画面更新由渲染帧驱动
}
if (Test-Path $ConfigPath) {
    try {
        $saved = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($CFG.Keys)) { if ($null -ne $saved.$k) { $CFG[$k] = $saved.$k } }
        if ($CFG.AnchorX -lt 0 -and $null -ne $saved.Left -and $saved.Left -ge 0) { $CFG.AnchorX = [double]$saved.Left }
        if ([int]$CFG.PollMs -lt 200) { $CFG.PollMs = 500 }     # 兼容旧配置里的小值

        # ---- 迁移旧配置：字号只有「主歌词 × 比例」一套机制 ----
        # 以前可以单独写死翻译/下一句的绝对字号（并把 FollowMain 关掉），
        # 那种配置下拖手柄只会缩放主歌词。这里把旧的绝对字号折算成比例，观感不变。
        $clampR = { param($r) if ($r -lt 0.25) { 0.25 } elseif ($r -gt 1.60) { 1.60 } else { $r } }
        $fs = [double]$CFG.FontSize
        if ($fs -gt 0) {
            if ($null -ne $saved.TransFontSize -and -not [bool]$CFG.FollowMain) {
                $CFG.TransRatio = & $clampR ([double]$saved.TransFontSize / $fs)
            }
            if ($null -ne $saved.NextFontSize -and -not [bool]$CFG.FollowMain) {
                $CFG.NextRatio = & $clampR ([double]$saved.NextFontSize / $fs)
            }
        }
        $CFG.FollowMain = $true                                 # 该开关已取消，固定为真
    } catch { }
}
function Save-Cfg { try { ($CFG | ConvertTo-Json) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8 } catch { } }

# ---------- Win32 ----------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class W32 {
    public const int GWL_EXSTYLE       = -20;
    public const int WS_EX_TRANSPARENT = 0x00000020;
    public const int WS_EX_LAYERED     = 0x00080000;
    public const int WS_EX_TOOLWINDOW  = 0x00000080;
    public const int WS_EX_NOACTIVATE  = 0x08000000;
    [DllImport("user32.dll")] public static extern int  GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int  SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
}
'@ -ErrorAction SilentlyContinue

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime

# ---------- SMTC ----------
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
$script:AwaitMethods = @{}
function Await($op, $type) {
    # 反射构造泛型方法是每个轮询周期最贵的固定开销，按类型缓存下来只做一次
    $k = $type.FullName
    $m = $script:AwaitMethods[$k]
    if (-not $m) { $m = $asTaskGeneric.MakeGenericMethod($type); $script:AwaitMethods[$k] = $m }
    $t = $m.Invoke($null, @($op)); $t.Wait(-1) | Out-Null; $t.Result
}
$MgrType   = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType=WindowsRuntime]
$PropsType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType=WindowsRuntime]
$script:SmtcMgr = Await ($MgrType::RequestAsync()) $MgrType

function Get-SpotifySession {
    try {
        foreach ($sess in $script:SmtcMgr.GetSessions()) {
            if ($sess.SourceAppUserModelId -like '*Spotify*') { return $sess }
        }
    } catch { }
    return $null
}

# 播放控制：直接调用 SMTC 会话上的控制方法（不模拟媒体按键，所以不会影响前台窗口）
function Invoke-Playback([string]$action) {
    $sess = Get-SpotifySession
    if (-not $sess) {
        try { $ni.ShowBalloonTip(1500, '播放控制', '没找到 Spotify 媒体会话（先在 Spotify 里放一首歌）', [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
        return
    }
    try {
        $ok = $false
        switch ($action) {
            'toggle' { $ok = Await ($sess.TryTogglePlayPauseAsync()) ([bool]) }
            'next'   { $ok = Await ($sess.TrySkipNextAsync())        ([bool]) }
            'prev'   { $ok = Await ($sess.TrySkipPreviousAsync())    ([bool]) }
            'fwd'    { $ok = Await ($sess.TryFastForwardAsync())     ([bool]) }
            'rew'    { $ok = Await ($sess.TryRewindAsync())          ([bool]) }
        }
        # 让下一次轮询立刻刷新状态，不用等
        if (-not $ok) { Log ("playback control '{0}' returned false" -f $action) }
    } catch { Log ("playback control error (" + $action + "): " + $_.Exception.Message) }
}

function Get-NowPlaying {
    try {
        # 用 foreach 而不是 Where-Object | Select-Object：管道在 PowerShell 里开销明显，
        # 而这个函数每个轮询周期都要跑一次
        $s = Get-SpotifySession
        if (-not $s) { return $null }
        $p  = Await ($s.TryGetMediaPropertiesAsync()) $PropsType
        $tl = $s.GetTimelineProperties()
        $updated = $null
        try { $updated = $tl.LastUpdatedTime.LocalDateTime } catch { }
        [pscustomobject]@{
            Title    = [string]$p.Title
            Artist   = [string]$p.Artist
            Album    = [string]$p.AlbumTitle
            Status   = [string]$s.GetPlaybackInfo().PlaybackStatus
            Position = [double]$tl.Position.TotalSeconds
            Duration = [double]$tl.EndTime.TotalSeconds
            Updated  = $updated
        }
    } catch { $null }
}

# ---------- 歌词抓取 ----------
# 直接跑 node 进程，不再用 Start-Job。
# Start-Job 每次抓取都会额外起一个完整的 PowerShell 子进程（实测几十 MB + 几百毫秒启动），
# 而我们只需要 node 跑完、结果落在 OutFile 里 —— 那个中间进程纯属浪费。
function Start-NodeProcess([string]$nodeExe, [string]$jsFile, [string]$reqFile, [string]$outFile, [string]$cacheFile) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $nodeExe
    $psi.Arguments       = '"' + $jsFile + '" "' + $reqFile + '" "' + $outFile + '" "' + $cacheFile + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    $psi.WindowStyle     = [System.Diagnostics.ProcessWindowStyle]::Hidden
    return [System.Diagnostics.Process]::Start($psi)
}


# ---------- 颜色 / 字号 ----------
function HexToWpfColor([string]$hex) {
    $h = ([string]$hex).TrimStart('#')
    if ($h.Length -eq 6) { $h = 'FF' + $h }
    if ($h.Length -ne 8) { $h = 'FFFFFFFF' }
    try {
        return [System.Windows.Media.Color]::FromArgb(
            [Convert]::ToInt32($h.Substring(0, 2), 16), [Convert]::ToInt32($h.Substring(2, 2), 16),
            [Convert]::ToInt32($h.Substring(4, 2), 16), [Convert]::ToInt32($h.Substring(6, 2), 16))
    } catch { return [System.Windows.Media.Colors]::White }
}
function Brush([string]$hex) { New-Object System.Windows.Media.SolidColorBrush((HexToWpfColor $hex)) }

# ---------- 界面 ----------
$shadow = ''
if ([bool]$CFG.Shadow) {
    $shadow = '<TextBlock.Effect><DropShadowEffect Color="Black" BlurRadius="10" ShadowDepth="0" Opacity="0.95"/></TextBlock.Effect>'
}
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        SizeToContent="WidthAndHeight">
  <Border x:Name="Root" Margin="20,10,20,10" Background="#01000000"
          BorderThickness="1" BorderBrush="#00FFFFFF">
   <Grid>
    <StackPanel>
      <Grid>
        <TextBlock x:Name="Cur" FontFamily="Microsoft YaHei UI" FontWeight="Bold"
                   FontSize="$($CFG.FontSize)" Foreground="$($CFG.TextColor)"
                   TextAlignment="Center" TextWrapping="Wrap" MaxWidth="$($CFG.MaxWidth)">
          $shadow
        </TextBlock>
        <!-- CurFill 是叠在 Cur 上面的"已唱部分"，故意不加投影效果：
             Cur 在同一位置画着完全相同的字形、也带着同一个投影，
             CurFill 再加一次纯属重复计算（而且它每帧都在改裁剪矩形）。
             去掉后视觉完全一致，但省掉一次模糊渲染。 -->
        <TextBlock x:Name="CurFill" FontFamily="Microsoft YaHei UI" FontWeight="Bold"
                   FontSize="$($CFG.FontSize)" Foreground="$($CFG.TextColor)"
                   TextAlignment="Center" TextWrapping="Wrap" MaxWidth="$($CFG.MaxWidth)">
          <TextBlock.Clip><RectangleGeometry x:Name="CurClip" Rect="0,0,0,0"/></TextBlock.Clip>
        </TextBlock>
      </Grid>
      <TextBlock x:Name="Trans" FontFamily="Microsoft YaHei UI"
                 FontSize="$($CFG.TransFontSize)" Foreground="$($CFG.TransColor)"
                 TextAlignment="Center" TextWrapping="Wrap" MaxWidth="$($CFG.MaxWidth)">
        $shadow
      </TextBlock>
      <TextBlock x:Name="Next" FontFamily="Microsoft YaHei UI"
                 FontSize="$($CFG.NextFontSize)" Foreground="$($CFG.NextColor)"
                 TextAlignment="Center" TextWrapping="Wrap" MaxWidth="$($CFG.MaxWidth)">
        $shadow
      </TextBlock>
    </StackPanel>
    <Thumb x:Name="Grip" Width="16" Height="16" HorizontalAlignment="Right" VerticalAlignment="Bottom"
           Background="#40FFFFFF" BorderBrush="#90FFFFFF" BorderThickness="1"
           Cursor="SizeNWSE" Visibility="Collapsed"/>
   </Grid>
  </Border>
</Window>
"@
$win     = [Windows.Markup.XamlReader]::Parse($xaml)
$cur     = $win.FindName('Cur')
$curFill = $win.FindName('CurFill')
$curClip = $win.FindName('CurClip')
$trans   = $win.FindName('Trans')
$next    = $win.FindName('Next')
$grip    = $win.FindName('Grip')
$root    = $win.FindName('Root')

# 设置次要行文本（翻译 / 下一句）。
# 注意：WPF 的 TextBlock 即使 Text='' 也照样占一整行高度（实测 34px 字号仍占 46px），
# 所以空行必须 Collapsed 折叠掉，否则只有两句歌词时下面会留一块空白，
# 把右下角的缩放手柄推到离歌词很远的地方。
function Set-LineText($tb, [string]$s) {
    if ($tb.Text -ne $s) { $tb.Text = $s }
    $v = $(if ($s) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed })
    if ($tb.Visibility -ne $v) { $tb.Visibility = $v }
}

function Apply-Shadow {
    try {
        $eff = $null
        if ([bool]$CFG.Shadow) {
            $eff = New-Object System.Windows.Media.Effects.DropShadowEffect
            $eff.Color       = [System.Windows.Media.Colors]::Black
            $eff.BlurRadius  = 10
            $eff.ShadowDepth = 0
            $eff.Opacity     = 0.95
        }
        # 只给 Cur 加投影，不给 CurFill（它叠在 Cur 上、字形完全一样，投影重复且每帧重算）
        foreach ($tb in @($cur, $trans, $next)) { $tb.Effect = $eff }
        $curFill.Effect = $null
    } catch { Log ("apply-shadow error: " + $_.Exception.Message) }
}

function Apply-Colors {
    try {
        $curFill.Foreground = Brush $CFG.TextColor
        if ([bool]$CFG.Karaoke) {
            $cur.Foreground = Brush $CFG.KaraokeBaseColor
            $curFill.Visibility = [System.Windows.Visibility]::Visible
        } else {
            $cur.Foreground = Brush $CFG.TextColor
            $curFill.Visibility = [System.Windows.Visibility]::Collapsed
        }
        $trans.Foreground = Brush $CFG.TransColor
        $next.Foreground  = Brush $CFG.NextColor
    } catch { Log ("apply-colors error: " + $_.Exception.Message) }
}
function Apply-Spacing {
    try {
        $g = [double]$CFG.GapScale
        if ($g -le 0) { $g = 1.0 }
        $trans.Margin = New-Object System.Windows.Thickness(0, ([double]$CFG.TransFontSize * 0.15 * $g), 0, 0)
        $next.Margin  = New-Object System.Windows.Thickness(0, ([double]$CFG.NextFontSize  * 0.22 * $g), 0, 0)
    } catch { Log ("apply-spacing error: " + $_.Exception.Message) }
}
function Apply-Fonts {
    try {
        # 次级字号永远 = 主字号 × 比例。只有这一套机制，所以拖右下角手柄时
        # 翻译行和下一句必然跟着一起缩放（以前单独调过次级字号会关掉跟随，就不跟了）
        $CFG.TransFontSize = [int][math]::Round([double]$CFG.FontSize * [double]$CFG.TransRatio)
        $CFG.NextFontSize  = [int][math]::Round([double]$CFG.FontSize * [double]$CFG.NextRatio)
        if ([int]$CFG.TransFontSize -lt 9) { $CFG.TransFontSize = 9 }
        if ([int]$CFG.NextFontSize -lt 9)  { $CFG.NextFontSize = 9 }
        $cur.FontSize = [double]$CFG.FontSize
        $curFill.FontSize = [double]$CFG.FontSize
        $trans.FontSize = [double]$CFG.TransFontSize
        $next.FontSize  = [double]$CFG.NextFontSize
        Apply-Spacing
    } catch { Log ("apply-fonts error: " + $_.Exception.Message) }
}
$script:Hover = $false
function Update-Hover([bool]$on) {
    try {
        $script:Hover = $on
        $show = ($on -and -not [bool]$CFG.Locked)
        if ($show) { $grip.Visibility = [System.Windows.Visibility]::Visible }
        else       { $grip.Visibility = [System.Windows.Visibility]::Collapsed }
        $a = 0
        if ($show) { $a = 70 }
        $root.BorderBrush = New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.Color]::FromArgb($a, 255, 255, 255))
    } catch { }
}
function Reposition {
    try {
        $w = $win.ActualWidth
        if ($w -le 0) { $w = 1 }
        switch ([string]$CFG.Anchor) {
            'left'  { $win.Left = [double]$CFG.AnchorX }
            'right' { $win.Left = [double]$CFG.AnchorX - $w }
            default { $win.Left = [double]$CFG.AnchorX - ($w / 2) }
        }
    } catch { }
}
function Set-AnchorFromLeft([double]$left) {
    $w = $win.ActualWidth
    if ($w -le 0) { $w = 1 }
    switch ([string]$CFG.Anchor) {
        'left'  { $CFG.AnchorX = $left }
        'right' { $CFG.AnchorX = $left + $w }
        default { $CFG.AnchorX = $left + ($w / 2) }
    }
}
function Apply-Align {
    try {
        $ta = [System.Windows.TextAlignment]::Center
        if ([string]$CFG.Anchor -eq 'left')  { $ta = [System.Windows.TextAlignment]::Left }
        if ([string]$CFG.Anchor -eq 'right') { $ta = [System.Windows.TextAlignment]::Right }
        $cur.TextAlignment = $ta; $curFill.TextAlignment = $ta
        $trans.TextAlignment = $ta; $next.TextAlignment = $ta
        Reposition
    } catch { Log ("apply-align error: " + $_.Exception.Message) }
}

$wa = [System.Windows.SystemParameters]::WorkArea
if ($CFG.AnchorX -lt 0) { $CFG.AnchorX = [double]($wa.Left + ($wa.Width / 2)) }
if ($CFG.Top -lt 0)     { $CFG.Top     = [double]($wa.Bottom - 210) }
$win.Top = [double]$CFG.Top

function Apply-Mode {
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
        if ($h -eq [IntPtr]::Zero) { return }
        $ex = [W32]::GetWindowLong($h, [W32]::GWL_EXSTYLE)
        $ex = $ex -bor [W32]::WS_EX_LAYERED -bor [W32]::WS_EX_TOOLWINDOW
        if ([bool]$CFG.Locked) {
            $ex = $ex -bor [W32]::WS_EX_TRANSPARENT -bor [W32]::WS_EX_NOACTIVATE
        } else {
            $ex = $ex -band (-bnot [W32]::WS_EX_TRANSPARENT)
            $ex = $ex -band (-bnot [W32]::WS_EX_NOACTIVATE)
        }
        [void][W32]::SetWindowLong($h, [W32]::GWL_EXSTYLE, $ex)
        Update-Hover $script:Hover
    } catch { Log ("apply-mode error: " + $_.Exception.Message) }
}

$win.Add_SizeChanged({ Reposition })
$win.Show()
Reposition
Apply-Mode
Apply-Fonts
Apply-Colors
Apply-Shadow
Apply-Align

# ---------- 状态 ----------
$script:Lyrics        = @()
$script:LyricsState   = 'idle'
$script:LyricsSrc     = ''
$script:HasTrans      = $false
$script:TrackKey      = ''
$script:BasePos       = 0.0      # 逐帧累加得到的播放位置
$script:PosBias       = 0.0      # 与 SMTC 的平滑修正量
$script:Clock         = [System.Diagnostics.Stopwatch]::StartNew()   # 单调高精度时钟
$script:LastFrame     = 0.0
$script:FetchProc      = $null
$script:FetchStart    = Get-Date
$script:LastIdx       = -2
$script:Playing       = $false
$script:Duration      = 0.0
$script:LastPos       = 0.0
$script:NoSessionFrom = $null
$script:FailText      = ''
$script:KaraokeFrac   = -1.0
$script:FreshFrom     = $null      # 换歌时刻；之后 1.5 秒内位置直接硬对齐
$script:LastKtvT      = 0.0        # 上一次更新 KTV 裁剪的时刻（限制更新频率用）

function Start-Fetch([string]$artist, [string]$title, [string]$album, [double]$duration) {
    if ($script:FetchProc) {
        try { if (-not $script:FetchProc.HasExited) { $script:FetchProc.Kill() } } catch { }
        try { $script:FetchProc.Dispose() } catch { }
        $script:FetchProc = $null
    }
    $script:Lyrics = @(); $script:LyricsState = 'loading'; $script:LastIdx = -2; $script:LastPos = 0.0
    $script:HasTrans = $false; $script:KaraokeFrac = -1.0
    $cur.Text = '♪  ' + $title; $curFill.Text = $cur.Text
    Set-LineText $trans ''
    Set-LineText $next '正在获取歌词…'
    $script:FailText = ''
    if (-not $NodeExe -or -not (Test-Path $FetchJs)) {
        $script:LyricsState = 'error'; $script:FailText = '缺少 node 或 lyrics-fetch.js'
        Log "fetch impossible: node='$NodeExe' js=$FetchJs"
        return
    }
    # 缓存查表交给 node 做，PowerShell 这边不再自己解析缓存文件。
    # 原因：缓存里带逐字数据，一个文件 1~2 年后会涨到几百 KB，而 PowerShell 的
    # ConvertFrom-Json 是同步的 —— 实测 160KB 就要 72ms，全部卡在 UI 线程上；
    # node 那边 JSON.parse 快得多，而且是子进程、不阻塞界面。
    # force = 菜单里点了"重新获取歌词"：跳过缓存，逼抓取器重新去问一遍数据源
    $reqJson = @{ artist = $artist; title = $title; album = $album; duration = [int]$duration; force = [bool]$script:ForceFetch } | ConvertTo-Json -Compress
    $script:ForceFetch = $false
    try {
        [System.IO.File]::WriteAllText($ReqFile, $reqJson, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
        $script:FetchStart = Get-Date
        $script:FetchProc  = Start-NodeProcess $NodeExe $FetchJs $ReqFile $OutFile $CacheFile
    } catch {
        $script:FetchProc   = $null
        $script:LyricsState = 'error'
        $script:FailText    = 'node 启动失败'
        Log ("fetch spawn error: " + $_.Exception.Message)
        return
    }
    Log ("fetch start: {0} - {1} ({2}s)" -f $artist, $title, [int]$duration)
}

function Complete-Fetch {
    if (-not $script:FetchProc) { return }
    $elapsed = ((Get-Date) - $script:FetchStart).TotalSeconds

    if (-not $script:FetchProc.HasExited) {
        if ($elapsed -gt 40) {
            try { $script:FetchProc.Kill() } catch { }
            try { $script:FetchProc.Dispose() } catch { }
            $script:FetchProc = $null; $script:LyricsState = 'error'
            Log ("fetch timeout after {0:N0}s" -f $elapsed)
        }
        return
    }

    $code = -1
    try { $code = $script:FetchProc.ExitCode } catch { }
    try { $script:FetchProc.Dispose() } catch { }
    $script:FetchProc = $null

    $res = $null
    try {
        if (Test-Path $OutFile) {
            $txt = [System.IO.File]::ReadAllText($OutFile, [System.Text.Encoding]::UTF8)
            if ($txt -and $txt.Trim()) { $res = $txt.Trim() | ConvertFrom-Json }
        }
    } catch { Log ("fetch json parse error: " + $_.Exception.Message) }

    if ($res -and $res.ok -and @($res.lines).Count -gt 0) {
        $script:Lyrics      = @($res.lines)
        $script:LyricsState = 'ready'
        $script:HasTrans    = ([int]$res.transCount -gt 0)
        $script:LyricsSrc   = "$($res.src) · $($res.name)"
        if ($script:HasTrans) { $script:LyricsSrc += "  +翻译 $($res.transCount) 行" }
        if ([int]$res.wordLines -gt 0) { $script:LyricsSrc += "  +逐字 $($res.wordLines) 行" }
        Log ("fetch ok: {0} lines, trans {1}, words {2} via {3} ({4})" -f $script:Lyrics.Count, $res.transCount, $res.wordLines, $res.src, $res.name)
        if ($ni) {
            if ([int]$res.wordLines -gt 0) { $ni.Text = "Spotify 桌面歌词 · 逐字 $($res.wordLines)/$($script:Lyrics.Count) 行" }
            else { $ni.Text = 'Spotify 桌面歌词 · 这首无逐字数据' }
        }
    } else {
        $script:LyricsState = 'none'; $script:HasTrans = $false
        $errText = 'unparsable result'
        if ($res -and $res.err) { $errText = [string]$res.err }
        elseif ($code -ne 0) { $errText = "取值进程异常退出 (exit $code)" }
        $script:FailText = $errText
        Log ("fetch none after {0:N0}s: {1}" -f $elapsed, $errText)
    }
}

# ---------- 每 500ms：查询 SMTC、平滑校准、取回歌词 ----------
function Poll-Smtc {
    $now = Get-Date
    $np  = Get-NowPlaying
    if ($np -and $np.Title) {
        $script:NoSessionFrom = $null
        $key = "$($np.Artist)|$($np.Title)"
        if ($key -ne $script:TrackKey) {
            $script:TrackKey  = $key
            $script:Duration  = $np.Duration
            # 换歌这一轮也必须补上采样滞后。
            # Spotify 报的 Position 更新很稀疏（实测能停在同一个值上 4 秒以上不动），
            # 直接拿原始值当基准会让歌词整体慢 1~4 秒，而且之后要好几轮才吸收回来
            # ——这就是"新播放的歌慢一两秒"的根因。
            $est = [double]$np.Position
            if (($np.Status -eq 'Playing') -and $np.Updated) {
                $lag = ($now - $np.Updated).TotalSeconds
                if ($lag -gt 0 -and $lag -lt 30) { $est += $lag }
            }
            $script:BasePos   = $est
            $script:PosBias   = 0.0
            $script:LastFrame = $script:Clock.Elapsed.TotalSeconds
            $script:LastPos   = 0.0
            # 这一轮也要更新播放状态：否则暂停状态下切歌，本轮不会累加帧时钟
            $script:Playing   = ($np.Status -eq 'Playing')
            # 换歌后开一个短暂窗口，期间完全信任估算值（见下面 else 分支）
            $script:FreshFrom = $now
            Start-Fetch $np.Artist $np.Title $np.Album $np.Duration
        } else {
            # 用 LastUpdatedTime 补上采样滞后，得到更接近真实的位置
            $est = [double]$np.Position
            if (($np.Status -eq 'Playing') -and $np.Updated) {
                $lag = ($now - $np.Updated).TotalSeconds
                if ($lag -gt 0 -and $lag -lt 30) { $est += $lag }
            }
            $drift = $est - ($script:BasePos + $script:PosBias)
            # 换歌后 1.5 秒内直接对齐（不按 25% 慢慢吸收）：这段时间估算值本来就最可信，
            # 慢慢吸收只会让开头那一两秒一直滞后
            $fresh = $script:FreshFrom -and ((($now - $script:FreshFrom)).TotalSeconds -lt 1.5)
            if ([math]::Abs($drift) -gt 2.5 -or $fresh) {
                # 真正的跳转（拖动进度条/换曲）或刚换歌：直接对齐
                $script:BasePos = $est; $script:PosBias = 0.0
            } else {
                # 平滑吸收误差：每次只吸收 25%，位置连续变化，画面不会跳
                $script:PosBias += $drift * 0.25
            }
            if ($np.Duration -gt 0) { $script:Duration = $np.Duration }
            $script:Playing = ($np.Status -eq 'Playing')
        }
    } else {
        $script:Playing = $false
        if (-not $script:NoSessionFrom) { $script:NoSessionFrom = $now }
        if (($now - $script:NoSessionFrom).TotalSeconds -gt 5 -and $script:LyricsState -ne 'idle') {
            $script:Lyrics = @(); $script:LyricsState = 'idle'; $script:TrackKey = ''
            $script:LastIdx = -2; $script:LastPos = 0; $script:KaraokeFrac = -1.0
            $cur.Text = ''; $curFill.Text = ''
            Set-LineText $trans ''
            Set-LineText $next ''
            $curFill.Visibility = [System.Windows.Visibility]::Collapsed
        }
    }
    Complete-Fetch

    # 保险：WPF 对完全静止的视觉树可能不再触发 Rendering 回调，那样帧时钟就停了。
    # 但播放中 KTV 每帧都在改裁剪矩形，视觉树本来就不静止 —— 那一刀是白挨的
    # （而且会连带把文字和投影重算一遍），所以只在"不会自己重绘"时才补这一下。
    $animating = $script:Playing -and [bool]$CFG.Karaoke -and $script:LastIdx -ge 0
    if (-not $animating) { try { $curFill.InvalidateVisual() } catch { } }
}

# ---------- 每帧（60fps）：累加位置、更新文字与 KTV 填充 ----------
function Render-Tick {
    # 单调高精度时钟：比每帧 Get-Date 做减法更准更快，也不受系统时间调整影响
    $t = $script:Clock.Elapsed.TotalSeconds
    if ($script:Playing) { $script:BasePos += ($t - $script:LastFrame) }
    $script:LastFrame = $t

    $st = $script:LyricsState
    if ($st -eq 'loading') { return }
    if ($st -eq 'none') {
        if ($cur.Text -ne '（未找到歌词）') { $cur.Text = '（未找到歌词）'; $curFill.Text = ''; Set-LineText $trans ''; Set-LineText $next '' }
        return
    }
    if ($st -eq 'error') {
        if ($cur.Text -ne '（歌词获取失败）') {
            $cur.Text = '（歌词获取失败）'; $curFill.Text = ''
            Set-LineText $trans ''
            Set-LineText $next $(if ($script:FailText) { $script:FailText } else { '详见 lyrics-overlay.log' })
        }
        return
    }
    if ($st -ne 'ready' -or $script:Lyrics.Count -eq 0) { return }

    $pos = $script:BasePos + $script:PosBias
    if ($pos -lt 0) { $pos = 0 }
    if ($pos -lt ($script:LastPos - 1.5)) { $script:LastPos = $pos }
    elseif ($pos -lt $script:LastPos) { $pos = $script:LastPos }
    else { $script:LastPos = $pos }

    # 校准：正值 = 歌词提前
    $effPos = $pos + [double]$CFG.LyricsOffset

    # 位置单调前进：从上次的索引往后走即可（均摊 O(1)，不必每帧全表扫描）
    $idx = $script:LastIdx
    if ($idx -lt -1) { $idx = -1 }
    if ($idx -ge $script:Lyrics.Count) { $idx = $script:Lyrics.Count - 1 }
    while (($idx + 1) -lt $script:Lyrics.Count -and [double]$script:Lyrics[$idx + 1].t -le $effPos) { $idx++ }
    while ($idx -ge 0 -and [double]$script:Lyrics[$idx].t -gt $effPos) { $idx-- }   # 拖进度条回退时往回找

    if ($idx -ne $script:LastIdx) {
        $script:LastIdx = $idx
        $midText = ''; $botText = ''
        if ($idx -lt 0) {
            $cur.Text = '♪'; $curFill.Text = '♪'
            if ([bool]$CFG.ShowNextLine) { $midText = [string]$script:Lyrics[0].s }
        } else {
            $cur.Text = [string]$script:Lyrics[$idx].s
            $curFill.Text = $cur.Text
            $trText = ''
            if ([bool]$CFG.ShowTrans) {
                $tv = $script:Lyrics[$idx].tr
                if ($tv) { $trText = [string]$tv }
            }
            $nxText = ''
            if ([bool]$CFG.ShowNextLine -and ($idx + 1) -lt $script:Lyrics.Count) {
                $nxText = [string]$script:Lyrics[$idx + 1].s
            }
            if ($trText) { $midText = $trText; $botText = $nxText }
            else         { $midText = $nxText; $botText = '' }
        }
        Set-LineText $trans $midText
        Set-LineText $next  $botText
    }

    # KTV 填充：每帧更新（行不变也要更新，否则颜色不会推进）
    if (-not [bool]$CFG.Karaoke -or $idx -lt 0) {
        if ($curFill.Visibility -ne [System.Windows.Visibility]::Collapsed) {
            $curFill.Visibility = [System.Windows.Visibility]::Collapsed
        }
        return
    }
    if ($curFill.Visibility -ne [System.Windows.Visibility]::Visible) {
        $curFill.Visibility = [System.Windows.Visibility]::Visible
    }
    $start = [double]$script:Lyrics[$idx].t
    $end   = $script:Duration
    if (($idx + 1) -lt $script:Lyrics.Count) { $end = [double]$script:Lyrics[$idx + 1].t }
    $dur = $end - $start
    if ($dur -le 0.2) { $dur = 0.2 }
    if ($dur -gt 8) { $dur = 8 }          # 长间奏时 8 秒内填满，不要慢吞吞爬
    # 更新频率上限 ~70Hz：CompositionTarget.Rendering 跟的是显示器刷新率，
    # 100Hz / 165Hz 屏上会白跑 40%~140% 的帧，而这个填充每帧只挪几个像素，看不出区别
    if (($t - $script:LastKtvT) -lt 0.014) { return }
    $script:LastKtvT = $t
    # 【逐字】有逐字时间轴就按字推进，没有则回退到行级线性
    $frac = Get-KtvFraction $script:Lyrics[$idx] $effPos $start $dur
    if ([math]::Abs($frac - $script:KaraokeFrac) -lt 0.0015) { return }   # 变化太小就不重绘
    $script:KaraokeFrac = $frac
    $w = $curFill.ActualWidth
    if ($w -le 0) { return }
    # 用 [Rect]::new 而不是 New-Object：结构体走 New-Object 要走反射，
    # 实测 0.098ms/次 vs 0.0016ms/次（60fps 每秒 60 次，差 6ms/秒）
    $curClip.Rect = [System.Windows.Rect]::new(0, 0, ($w * $frac), $curFill.ActualHeight)
}

# ---------- KTV 填充进度（有逐字按字，否则回退行级） ----------
# 有 yrc 逐字时间轴：把「当前时刻」映射成「字符进度」，再换算成裁剪宽度
#   - 词的起止时刻是真实数据，所以不再出现"整行按时间匀速爬"导致的早亮/晚亮半拍
#   - 词内部仍是线性插值（词很短，看不出来）
# 没有逐字数据：完全回退到正式版的行级线性，行为一致
$script:KtvLine = $null
function Get-KtvFraction($ln, [double]$pos, [double]$lineStart, [double]$lineDur) {
    $ws = $ln.w
    if ($ws -and @($ws).Count -gt 1) {
        if (-not [object]::ReferenceEquals($script:KtvLine, $ln)) {
            $cum = @(0.0); $starts = @(); $durs = @(); $total = 0.0
            foreach ($w in @($ws)) {
                $starts += ([double]$w[0] / 1000.0)
                $durs   += ([double]$w[1] / 1000.0)
                $total  += ([string]$w[2]).Length
                $cum    += $total
            }
            $script:KtvLine = $ln; $script:KtvStarts = $starts
            $script:KtvDurs = $durs; $script:KtvCum = $cum; $script:KtvTotal = $total
            $script:KtvIdx = 0
        }
        if ($script:KtvTotal -gt 0) {
            $n = @($script:KtvStarts).Count
            # 播放位置通常单调前进，从上次的索引继续走即可（均摊 O(1)，不必每帧从头扫）
            $i = [int]$script:KtvIdx
            if ($i -ge $n) { $i = $n - 1 }
            if ($i -lt 0) { $i = 0 }
            while ($i -gt 0 -and $pos -lt [double]$script:KtvStarts[$i]) { $i-- }          # 拖进度条回退
            while (($i + 1) -lt $n -and $pos -ge [double]$script:KtvStarts[$i + 1]) { $i++ }
            $script:KtvIdx = $i

            $st = [double]$script:KtvStarts[$i]
            if ($pos -lt $st) {
                # 还没唱到第 i 个词 —— 停在"前面几个词已唱满"的位置。
                # 注意这里不能返回 1.0：老版本在这一分支直接返回 cum[n]/total(=100%)，
                # 于是词与词之间的空隙会让整行瞬间填满、下个词开始又弹回去，看起来就是"太快"。
                return [double]$script:KtvCum[$i] / [double]$script:KtvTotal
            }
            $du = [double]$script:KtvDurs[$i]
            if ($du -lt 0.02) { $du = 0.02 }
            $cl = [double]$script:KtvCum[$i + 1] - [double]$script:KtvCum[$i]
            if ($pos -le ($st + $du)) {
                $r = ([double]$script:KtvCum[$i] + ((($pos - $st) / $du) * $cl)) / [double]$script:KtvTotal
                if ($r -gt 1) { $r = 1 }
                return $r
            }
            # 这个词也唱完了：停在它的结束位置，等下一个词
            if (($i + 1) -ge $n) { return 1.0 }
            return [double]$script:KtvCum[$i + 1] / [double]$script:KtvTotal
        }
    }
    # 没有逐字数据：行级线性推进
    $frac = ($pos - $lineStart) / $lineDur
    if ($frac -lt 0) { $frac = 0 }
    if ($frac -gt 1) { $frac = 1 }
    return $frac
}

# ---------- 托盘 / 菜单 ----------
$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = [System.Drawing.SystemIcons]::Application
$TrayIco = Join-Path $ScriptDir 'tray.ico'
if (Test-Path $TrayIco) {
    try { $ni.Icon = New-Object System.Drawing.Icon($TrayIco, 16, 16) } catch { }
}
$ni.Text = 'Spotify 桌面歌词'
$ni.Visible = $true

function Pick-Color([string]$cfgKey) {
    $old = HexToWpfColor $CFG[$cfgKey]
    $dlg = New-Object System.Windows.Forms.ColorDialog
    $dlg.FullOpen = $true
    $dlg.AnyColor = $true
    $dlg.Color = [System.Drawing.Color]::FromArgb($old.R, $old.G, $old.B)
    $wasTop = $win.Topmost
    $win.Topmost = $false
    try {
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $CFG[$cfgKey] = '#{0:X2}{1:X2}{2:X2}{3:X2}' -f $old.A, $dlg.Color.R, $dlg.Color.G, $dlg.Color.B
            Apply-Colors; Save-Cfg
        }
    } catch { Log ("pick color error: " + $_.Exception.Message) }
    finally { $win.Topmost = $wasTop; $dlg.Dispose() }
}
function Set-SecondaryAlpha([int]$alpha) {
    foreach ($k in @('TransColor', 'NextColor')) {
        $c = HexToWpfColor $CFG[$k]
        $CFG[$k] = '#{0:X2}{1:X2}{2:X2}{3:X2}' -f $alpha, $c.R, $c.G, $c.B
    }
    Apply-Colors; Save-Cfg
}
function New-MenuItem([string]$text, $tag, [scriptblock]$onClick, [scriptblock]$isChecked = $null) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($text)
    if ($null -ne $tag) { $mi.Tag = $tag }
    if ($null -ne $isChecked) {
        # 开关类菜单项：显示勾选状态。没有它的话"锁定/KTV/跟随"这类开关
        # 点完看不出当前是开还是关，只能靠猜。
        $mi.CheckOnClick = $true
        $mi.Checked = [bool](& $isChecked)
        $script:CheckItems += ,@($mi, $isChecked)
    }
    $mi.Add_Click($onClick)
    return $mi
}
$script:CheckItems = @()
function Sync-MenuChecks {
    foreach ($ci in $script:CheckItems) {
        try { $ci[0].Checked = [bool](& $ci[1]) } catch { }
    }
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip

# ---------- 播放控制（托盘菜单里随时可用；鼠标操作要求未锁定） ----------
[void]$menu.Items.Add((New-MenuItem '◀◀  上一首' $null { Invoke-Playback 'prev' }))
[void]$menu.Items.Add((New-MenuItem '▶   播放 / 暂停' $null { Invoke-Playback 'toggle' }))
[void]$menu.Items.Add((New-MenuItem '▶▶  下一首' $null { Invoke-Playback 'next' }))
[void]$menu.Items.Add((New-MenuItem '⏪  快退' $null { Invoke-Playback 'rew' }))
[void]$menu.Items.Add((New-MenuItem '⏩  快进' $null { Invoke-Playback 'fwd' }))
[void]$menu.Items.Add('-')

[void]$menu.Items.Add((New-MenuItem '显示歌词' $null { if ($win.IsVisible) { $win.Hide() } else { $win.Show() } } { $win.IsVisible }))
[void]$menu.Items.Add((New-MenuItem '锁定位置（鼠标穿透）' $null {
    $CFG.Locked = -not [bool]$CFG.Locked
    Apply-Mode; Save-Cfg
    $msg = '已解锁：左键拖动移动，右键出菜单，悬停右下角手柄可改字号'
    if ([bool]$CFG.Locked) { $msg = '已锁定：鼠标穿透，不会再挡住点击' }
    try { $ni.ShowBalloonTip(2000, 'Spotify 桌面歌词', $msg, [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
} { $CFG.Locked }))

[void]$menu.Items.Add('-')

[void]$menu.Items.Add((New-MenuItem 'KTV 逐字变色' $null {
    $CFG.Karaoke = -not [bool]$CFG.Karaoke
    $script:KaraokeFrac = -1.0
    Apply-Colors; Save-Cfg
} { $CFG.Karaoke }))
[void]$menu.Items.Add((New-MenuItem 'KTV 未唱部分颜色…' 'KaraokeBaseColor' { param($sender, $e) Pick-Color ([string]$sender.Tag) }))

[void]$menu.Items.Add('-')

$miAlign = New-Object System.Windows.Forms.ToolStripMenuItem('对齐方式')
foreach ($A in @(@{ n = '居中'; v = 'center' }, @{ n = '左对齐'; v = 'left' }, @{ n = '右对齐'; v = 'right' })) {
    [void]$miAlign.DropDownItems.Add((New-MenuItem $A.n $A.v { param($sender, $e) $CFG.Anchor = [string]$sender.Tag; Apply-Align; Save-Cfg }))
}
[void]$menu.Items.Add($miAlign)

$miLayout = New-Object System.Windows.Forms.ToolStripMenuItem('显示布局')
foreach ($L in @(
    @{ n = '原文 + 翻译 + 下一句'; t = $true;  x = $true  },
    @{ n = '原文 + 翻译';          t = $true;  x = $false },
    @{ n = '原文 + 下一句';        t = $false; x = $true  },
    @{ n = '仅原文（单行）';        t = $false; x = $false }
)) {
    [void]$miLayout.DropDownItems.Add((New-MenuItem $L.n $L {
        param($sender, $e)
        $v = $sender.Tag
        $CFG.ShowTrans = [bool]$v.t; $CFG.ShowNextLine = [bool]$v.x
        if (-not [bool]$CFG.ShowTrans)    { Set-LineText $trans '' }
        if (-not [bool]$CFG.ShowNextLine) { Set-LineText $next  '' }
        Save-Cfg; $script:LastIdx = -2
    }))
}
[void]$menu.Items.Add($miLayout)
# 文字投影：配置里一直有 Shadow 这个键、README 也写了，但以前没有开关（等于文档写了没实现）
[void]$menu.Items.Add((New-MenuItem '文字投影（阴影）' $null {
    $CFG.Shadow = -not [bool]$CFG.Shadow; Apply-Shadow; Save-Cfg
} { $CFG.Shadow }))

function Get-Font-Info {
    return ("主歌词 {0} 磅   翻译 {1}% = {2}   下一句 {3}% = {4}" -f [int]$CFG.FontSize,
        [int][math]::Round([double]$CFG.TransRatio * 100), [int]$CFG.TransFontSize,
        [int][math]::Round([double]$CFG.NextRatio * 100), [int]$CFG.NextFontSize)
}

$miFont = New-Object System.Windows.Forms.ToolStripMenuItem('字号')
foreach ($op in @(
    @{ n = '主歌词 增大'; f = 'main';  d =  2     },
    @{ n = '主歌词 减小'; f = 'main';  d = -2     },
    @{ n = '翻译 增大';   f = 'trans'; d =  0.03  },
    @{ n = '翻译 减小';   f = 'trans'; d = -0.03  },
    @{ n = '下一句 增大'; f = 'next';  d =  0.03  },
    @{ n = '下一句 减小'; f = 'next';  d = -0.03  }
)) {
    [void]$miFont.DropDownItems.Add((New-MenuItem $op.n $op {
        param($sender, $e)
        $o = $sender.Tag
        if ($o.f -eq 'main') {
            $v = [int]$CFG.FontSize + [int]$o.d
            if ($v -lt 10) { $v = 10 }; if ($v -gt 120) { $v = 120 }
            $CFG.FontSize = $v
        } elseif ($o.f -eq 'trans') {
            $r = [double]$CFG.TransRatio + [double]$o.d
            if ($r -lt 0.25) { $r = 0.25 }; if ($r -gt 1.60) { $r = 1.60 }
            $CFG.TransRatio = [math]::Round($r, 2)
        } else {
            $r = [double]$CFG.NextRatio + [double]$o.d
            if ($r -lt 0.25) { $r = 0.25 }; if ($r -gt 1.60) { $r = 1.60 }
            $CFG.NextRatio = [math]::Round($r, 2)
        }
        Apply-Fonts; Save-Cfg
        try { $ni.ShowBalloonTip(1500, '字号', (Get-Font-Info), [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
    }))
}
[void]$miFont.DropDownItems.Add('-')
[void]$miFont.DropDownItems.Add((New-MenuItem '重置比例（翻译 66% / 下一句 56%）' $null {
    $CFG.TransRatio = 0.66; $CFG.NextRatio = 0.56
    Apply-Fonts; Save-Cfg
    try { $ni.ShowBalloonTip(1500, '字号', (Get-Font-Info), [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
}))
[void]$menu.Items.Add($miFont)

$miGap = New-Object System.Windows.Forms.ToolStripMenuItem('行间距')
foreach ($G in @(@{ n = '紧凑'; g = 0.6 }, @{ n = '标准'; g = 1.0 }, @{ n = '宽松'; g = 1.5 }, @{ n = '很宽'; g = 2.0 })) {
    [void]$miGap.DropDownItems.Add((New-MenuItem $G.n ([double]$G.g) { param($sender, $e) $CFG.GapScale = [double]$sender.Tag; Apply-Spacing; Save-Cfg }))
}
[void]$menu.Items.Add($miGap)

foreach ($c in @(@{ n = '歌词颜色…'; k = 'TextColor' }, @{ n = '翻译颜色…'; k = 'TransColor' }, @{ n = '下一行颜色…'; k = 'NextColor' })) {
    [void]$menu.Items.Add((New-MenuItem $c.n $c.k { param($sender, $e) Pick-Color ([string]$sender.Tag) }))
}
$miPreset = New-Object System.Windows.Forms.ToolStripMenuItem('预置配色')
foreach ($p in @(
    @{ n = '纯白';   c = '#FFFFFFFF'; t = '#D9FFFFFF'; x = '#73FFFFFF'; k = '#59FFFFFF' },
    @{ n = '暖金';   c = '#FFFFD98A'; t = '#D9FFE9B0'; x = '#73FFE9B0'; k = '#59FFE9B0' },
    @{ n = '天蓝';   c = '#FF9AD8FF'; t = '#D9BCE6FF'; x = '#73BCE6FF'; k = '#59BCE6FF' },
    @{ n = '樱花粉'; c = '#FFFFB3D9'; t = '#D9FFCCE5'; x = '#73FFCCE5'; k = '#59FFCCE5' },
    @{ n = '薄荷绿'; c = '#FFA8F0C6'; t = '#D9C6F5DA'; x = '#73C6F5DA'; k = '#59C6F5DA' }
)) {
    [void]$miPreset.DropDownItems.Add((New-MenuItem $p.n $p {
        param($sender, $e)
        $v = $sender.Tag
        $CFG.TextColor = $v.c; $CFG.TransColor = $v.t; $CFG.NextColor = $v.x; $CFG.KaraokeBaseColor = $v.k
        Apply-Colors; Save-Cfg
    }))
}
[void]$menu.Items.Add($miPreset)
$miAlpha = New-Object System.Windows.Forms.ToolStripMenuItem('次要行（翻译/下一行）透明度')
foreach ($pct in 100, 85, 70, 55, 40, 25) {
    [void]$miAlpha.DropDownItems.Add((New-MenuItem "$pct%" ([int][math]::Round($pct * 2.55)) { param($sender, $e) Set-SecondaryAlpha ([int]$sender.Tag) }))
}
[void]$menu.Items.Add($miAlpha)

[void]$menu.Items.Add('-')

$miCal = New-Object System.Windows.Forms.ToolStripMenuItem('歌词校准（比实际演唱早晚）')
foreach ($c in @(
    @{ n = '歌词提前 0.2s'; d =  0.2  },
    @{ n = '歌词延后 0.2s'; d = -0.2  },
    @{ n = '微调提前 0.05s'; d =  0.05 },
    @{ n = '微调延后 0.05s'; d = -0.05 }
)) {
    [void]$miCal.DropDownItems.Add((New-MenuItem $c.n ([double]$c.d) {
        param($sender, $e)
        $CFG.LyricsOffset = [math]::Round(([double]$CFG.LyricsOffset + [double]$sender.Tag), 2); Save-Cfg
        try { $ni.ShowBalloonTip(1200, '歌词校准', ("当前 " + $CFG.LyricsOffset + " 秒（正值=歌词提前）"), [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
    }))
}
[void]$miCal.DropDownItems.Add('-')
[void]$miCal.DropDownItems.Add((New-MenuItem '重置为 0' $null { $CFG.LyricsOffset = 0.0; Save-Cfg }))
[void]$menu.Items.Add($miCal)

[void]$menu.Items.Add((New-MenuItem '重新获取歌词（忽略缓存）' $null { $script:ForceFetch = $true; $script:TrackKey = '' }))
[void]$menu.Items.Add((New-MenuItem '把状态写进日志' $null {
    Log ("state: {0} | {1} | anchor={2} font={3}/{4}/{5} karaoke={6} offset={7} poll={8}ms" -f `
        $script:LyricsState, $script:LyricsSrc, $CFG.Anchor, $CFG.FontSize, $CFG.TransFontSize, $CFG.NextFontSize, [bool]$CFG.Karaoke, $CFG.LyricsOffset, $CFG.PollMs)
}))
[void]$menu.Items.Add((New-MenuItem '重置位置' $null {
    $CFG.AnchorX = [double]($wa.Left + ($wa.Width / 2)); $CFG.Top = [double]($wa.Bottom - 210)
    $win.Top = [double]$CFG.Top; Apply-Align; Save-Cfg
}))

[void]$menu.Items.Add('-')

[void]$menu.Items.Add((New-MenuItem '退出' $null {
    Save-Cfg
    try { $ni.Visible = $false; $ni.Dispose() } catch { }
    if ($script:FetchProc) {
        try { if (-not $script:FetchProc.HasExited) { $script:FetchProc.Kill() } } catch { }
        try { $script:FetchProc.Dispose() } catch { }
        $script:FetchProc = $null
    }
    $win.Close()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
}))
$ni.ContextMenuStrip = $menu
# 每次弹出菜单前把开关的勾选状态和实际配置对齐（避免视觉状态和真实状态漂移）
$menu.Add_Opening({ Sync-MenuChecks })

function Show-MenuAtCursor {
    try {
        $p = [System.Windows.Forms.Cursor]::Position
        $menu.Show($p.X, $p.Y)
    } catch { Log ("show menu error: " + $_.Exception.Message) }
}

# ---------- 鼠标 ----------
$script:Dragging   = $false
$script:DragStartX = 0
$script:DragStartY = 0
$script:DragWinL   = 0.0
$script:DragWinT   = 0.0

$win.Add_MouseEnter({ Update-Hover $true })
$win.Add_MouseLeave({ Update-Hover $false })

# 中键单击 = 播放/暂停（滚轮 = 上/下一首，带 700ms 防抖，免得滚一下跳好几首）
$script:LastSkip = [datetime]::MinValue
$win.Add_MouseDown({
    param($sender, $e)
    if ([bool]$CFG.Locked) { return }
    if ($e.ChangedButton -eq [System.Windows.Input.MouseButton]::Middle) {
        Invoke-Playback 'toggle'
        $e.Handled = $true
    }
})
$win.Add_MouseWheel({
    param($sender, $e)
    if ([bool]$CFG.Locked) { return }
    $now = Get-Date
    if (($now - $script:LastSkip).TotalMilliseconds -lt 700) { $e.Handled = $true; return }
    $script:LastSkip = $now
    if ($e.Delta -gt 0) { Invoke-Playback 'prev' } else { Invoke-Playback 'next' }
    $e.Handled = $true
})

$win.Add_MouseRightButtonDown({
    if ([bool]$CFG.Locked) { return }
    $script:Dragging = $false
    Show-MenuAtCursor
})
$win.Add_MouseLeftButtonDown({
    param($sender, $e)
    if ([bool]$CFG.Locked) { return }
    $script:Dragging   = $true
    $p = [System.Windows.Forms.Cursor]::Position
    $script:DragStartX = $p.X; $script:DragStartY = $p.Y
    $script:DragWinL   = $win.Left; $script:DragWinT = $win.Top
})
$win.Add_MouseMove({
    if (-not $script:Dragging) { return }
    if ([bool]$CFG.Locked) { $script:Dragging = $false; return }
    $sx = 1.0; $sy = 1.0
    try {
        $src = [System.Windows.PresentationSource]::FromVisual($win)
        if ($src -and $src.CompositionTarget) {
            $m = $src.CompositionTarget.TransformToDevice
            if ($m.M11 -gt 0) { $sx = $m.M11 }
            if ($m.M22 -gt 0) { $sy = $m.M22 }
        }
    } catch { }
    $p = [System.Windows.Forms.Cursor]::Position
    $newLeft = $script:DragWinL + (($p.X - $script:DragStartX) / $sx)
    $win.Left = $newLeft
    $win.Top  = $script:DragWinT + (($p.Y - $script:DragStartY) / $sy)
    Set-AnchorFromLeft $newLeft
    $CFG.Top = $win.Top
})
$win.Add_MouseLeftButtonUp({
    if ($script:Dragging) { $script:Dragging = $false; Save-Cfg }
})
$grip.Add_DragDelta({
    param($sender, $e)
    if ([bool]$CFG.Locked) { return }
    $d = ([double]$e.VerticalChange + [double]$e.HorizontalChange) / 20.0
    $v = [double]$CFG.FontSize + $d
    if ($v -lt 10) { $v = 10 }
    if ($v -gt 120) { $v = 120 }
    $CFG.FontSize = [int][math]::Round($v)
    Apply-Fonts
})
$grip.Add_DragCompleted({ Save-Cfg })

# ---------- 两个时钟 ----------
# 1) 慢时钟：查询 SMTC（500ms 足够，位置由逐帧累加补齐）
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds([int]$CFG.PollMs)
$timer.Add_Tick({ try { Poll-Smtc } catch { Log ("poll error: " + $_.Exception.Message) -Throttle } })
$timer.Start()

# 2) 快时钟：WPF 合成器每帧回调（60fps，与 VSync 对齐）—— 画面更新靠它，天然丝滑
$script:RenderHandler = [System.EventHandler]{
    param($sender, $e)
    try { Render-Tick } catch { Log ("render error: " + $_.Exception.Message) -Throttle }
}
[System.Windows.Media.CompositionTarget]::add_Rendering($script:RenderHandler)

Log ("overlay v9 started (node='$NodeExe', anchor=$($CFG.Anchor), font=$($CFG.FontSize)/$($CFG.TransFontSize)/$($CFG.NextFontSize), karaoke=$([bool]$CFG.Karaoke), smtcPoll=$($CFG.PollMs)ms, render=CompositionTarget)")
[System.Windows.Threading.Dispatcher]::Run() | Out-Null
[System.Windows.Media.CompositionTarget]::remove_Rendering($script:RenderHandler)
Save-Cfg
Log "overlay exited"
