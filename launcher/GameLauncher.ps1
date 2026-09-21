<#
.SYNOPSIS
    GameShelf Launcher - an Xbox-style front end for a GameShelf.

.DESCRIPTION
    Reads a shelf's _shelf.txt plus its _launch.txt mapping and presents the games
    as a console-style library: a left icon rail for categories, a hero banner for
    the most recently played game, and one horizontally scrolling rail per
    category. Double-click a tile (or press the hero button) to start a game.

    Games are started through the shelf path rather than the recorded target, so
    an entry whose real folder sits on a non-ASCII path still launches from an
    all-ASCII path.

.PARAMETER ShelfPath
    Folder holding _shelf.txt. Defaults to the parent of this script's folder, so
    the app works when installed into <shelf>\_ui\.

.PARAMETER NoUI
    Skip the window and print the resolved launch target for every entry this machine
    has.

.PARAMETER Sakura
    Overlay drifting cherry petals. Off by default; the Xbox look is monochrome.

.PARAMETER Shot
    Render the composed window to this PNG file and exit, without opening a window.
    -Diag prints the geometry; geometry does not tell you whether a long name is
    clipped, a subtitle is unreadable against its gradient, or the spacing is off.
    This does, on a machine with no display.

.EXAMPLE
    .\GameLauncher.ps1
.EXAMPLE
    .\GameLauncher.ps1 -ShelfPath H:\Games -NoUI
.EXAMPLE
    .\GameLauncher.ps1 -ShelfPath H:\Games -Shot C:\tmp\shelf.png
#>
[CmdletBinding()]
param(
    [string]$ShelfPath,
    [switch]$NoUI,
    [switch]$Sakura,
    [switch]$Diag,
    [string]$Shot
)

$ErrorActionPreference = 'Stop'

# -NoUI prints launch targets, -Diag measures the layout, -Shot renders it: none of
# them open a window, so none of them should claim the single-instance mutex or go
# looking for a running launcher to bring forward.
$headless = [bool]($NoUI -or $Diag -or $Shot)

if (-not $ShelfPath) { $ShelfPath = Split-Path -Parent $PSScriptRoot }
$manifest = Join-Path $ShelfPath '_shelf.txt'
if (-not (Test-Path -LiteralPath $manifest)) {
    throw "Not a gameshelf (no _shelf.txt): $ShelfPath"
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

Add-Type -Namespace GameShelf -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
'@

#region single instance

# One window per shelf. Clicking the shortcut again should bring the running
# library forward, not open a second copy of it.
#
# Under the shelf's _ui rather than next to this script, matching where the shelf's
# other state lives (_recent.txt, _layout.log) and what the README documents. The
# two only differ when the launcher is run from a checkout instead of from
# <shelf>\_ui\ - and then this way round, two copies of the launcher still find each
# other's marker instead of each writing its own.
$script:InstancePidFile = Join-Path (Join-Path $ShelfPath '_ui') '_instance.pid'

function Get-ShelfMutexName {
    param([string]$Path)
    $h = [long]2166136261
    foreach ($b in [System.Text.Encoding]::Unicode.GetBytes($Path.ToLowerInvariant())) {
        $h = $h -bxor $b
        $h = ($h * 16777619) % 4294967296
    }
    return 'Local\GameShelfLauncher_' + [int]($h % 2147483647)
}

function Focus-RunningInstance {
    <#
      Returns $true when an existing launcher was found and brought forward, in
      which case this process should quit instead of opening a second window.
    #>
    if (-not (Test-Path -LiteralPath $script:InstancePidFile)) { return $false }
    $raw = ''
    try { $raw = ([System.IO.File]::ReadAllText($script:InstancePidFile)).Trim() } catch { return $false }
    $other = 0
    if (-not [int]::TryParse($raw, [ref]$other) -or $other -le 0) { return $false }
    if ($other -eq $PID) { return $false }
    try {
        $proc = [System.Diagnostics.Process]::GetProcessById($other)
        $proc.Refresh()
        $h = $proc.MainWindowHandle
        if ($h -eq [IntPtr]::Zero) { return $false }
        [GameShelf.Native]::ShowWindow($h, 9) | Out-Null      # SW_RESTORE
        [GameShelf.Native]::SetForegroundWindow($h) | Out-Null
        return $true
    } catch {
        return $false
    }
}

if (-not $headless) {
    $script:instanceMutex = New-Object System.Threading.Mutex($true, (Get-ShelfMutexName -Path $ShelfPath), [ref]$false)
    $isFirst = $false
    try { $isFirst = $script:instanceMutex.WaitOne(0, $false) } catch { $isFirst = $true }

    if (-not $isFirst) {
        if (Focus-RunningInstance) {
            Write-Host '  Already running - brought the existing window forward.' -ForegroundColor DarkGray
            exit 0
        }
        # The mutex is held but no window answered: a previous run died badly.
        # Take ownership and carry on rather than leaving the user with nothing.
        try { $isFirst = $script:instanceMutex.WaitOne(2000, $false) } catch { }
        if (-not $isFirst) { exit 0 }
    }

    try { [System.IO.File]::WriteAllText($script:InstancePidFile, [string]$PID) } catch { }
}

#endregion single instance

#region data

function Read-Shelf {
    param([string]$Path)
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $p = $t.Split('|')
        if ($p.Count -lt 3) { continue }
        $note = ''
        if ($p.Count -ge 4) { $note = $p[3].Trim() }
        $items.Add([pscustomobject]@{
                Category = $p[0].Trim()
                Name     = $p[1].Trim()
                Target   = $p[2].Trim()
                Note     = $note
            })
    }
    return , $items
}

$script:RootsPath = Join-Path $ShelfPath '_roots.txt'

function Read-Roots {
    <#
      The labels this machine has bound to folders:
          # <label>|<folder>
          main|H:\@game

      Duplicated from the module on purpose. install.ps1 copies this script into
      <shelf>\_ui\ on its own - that is what makes the launcher portable - so it
      cannot import src\GameShelf.psm1, the same reason it already reads _shelf.txt
      and _launch.txt itself.
    #>
    param([string]$Path)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('|')
        if ($i -lt 1) { continue }
        $map[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
    }
    return $map
}

$script:envTokens = @(
    @('%DOCUMENTS%', [Environment]::GetFolderPath('MyDocuments')),
    @('%SAVEDGAMES%', (Join-Path $env:USERPROFILE 'Saved Games')),
    @('%LOCALLOW%', (Join-Path $env:USERPROFILE 'AppData\LocalLow')),
    @('%APPDATA%', $env:APPDATA),
    @('%LOCALAPPDATA%', $env:LOCALAPPDATA),
    @('%USERPROFILE%', $env:USERPROFILE)
)

function Resolve-ShelfTarget {
    <#
      %label%\rest resolves through _roots.txt, %APPDATA%-style tokens through the
      environment, anything else is already a path. Bound says whether a label had
      an answer, so an unbound one can be reported honestly instead of looking like
      a game that went missing.
    #>
    param([string]$Target, [hashtable]$Roots)

    $t = ([string]$Target).Trim()
    if (-not $t) { return [pscustomobject]@{ Path = ''; Label = ''; Bound = $false } }
    if ($t -notmatch '^%([^%]+)%') { return [pscustomobject]@{ Path = $t; Label = ''; Bound = $true } }

    $label = $Matches[1]
    $rest = $t.Substring($label.Length + 2).TrimStart('\')

    foreach ($pair in $script:envTokens) {
        if (([string]$pair[0]).Trim('%') -ieq $label) {
            $base = [string]$pair[1]
            if (-not $base) { break }
            $p = $base
            if ($rest) { $p = Join-Path $base $rest }
            return [pscustomobject]@{ Path = $p; Label = $label; Bound = $true }
        }
    }
    if ($Roots.ContainsKey($label)) {
        $base = ([string]$Roots[$label]).Trim()
        $p = $base
        if ($rest) { $p = Join-Path $base $rest }
        return [pscustomobject]@{ Path = $p; Label = $label; Bound = $true }
    }
    return [pscustomobject]@{ Path = $t; Label = $label; Bound = $false }
}

$script:roots = Read-Roots -Path $script:RootsPath

function Get-RealPath {
    <#
      The folder this machine actually has for an entry. Target is the shelf's own
      description of itself and may be a portable %label%\...; Path is what it means
      here. Falls back to Target so a caller never ends up with nothing.
    #>
    param($Entry)
    if ($null -eq $Entry) { return '' }
    $p = $Entry.PSObject.Properties['Path']
    if ($null -ne $p -and $p.Value) { return [string]$p.Value }
    return [string]$Entry.Target
}

$script:LaunchConfigPath = Join-Path $ShelfPath '_launch.txt'
$script:RecentPath = Join-Path (Join-Path $ShelfPath '_ui') '_recent.txt'
$script:FOLDER_SENTINEL = 'FOLDER'

function Read-LaunchConfig {
    param([string]$Path)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('|')
        if ($i -lt 1) { continue }
        $map[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
    }
    return $map
}

function Save-LaunchConfig {
    param([string]$Path, [hashtable]$Map)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# GameShelf launcher mapping.')
    $lines.Add('# Format: <shelf entry name>|<path to exe, relative to that game''s folder>')
    $lines.Add('# Use FOLDER to mean "there is no exe, open the folder instead".')
    foreach ($k in ($Map.Keys | Sort-Object)) { $lines.Add($k + '|' + $Map[$k]) }
    [System.IO.File]::WriteAllLines($Path, $lines, (New-Object System.Text.UTF8Encoding($true)))
}

function Read-Recent {
    # Most recent first, de-duplicated by name.
    $order = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $script:RecentPath)) { return , $order }
    $seen = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($script:RecentPath, [System.Text.Encoding]::UTF8)) {
        $i = $line.IndexOf('|')
        if ($i -lt 1) { continue }
        $name = $line.Substring($i + 1).Trim()
        if ($name -eq '' -or $seen.ContainsKey($name)) { continue }
        $seen[$name] = $true
        $order.Add($name)
    }
    return , $order
}

function Add-Recent {
    param([string]$Name)
    $dir = Split-Path -Parent $script:RecentPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((Get-Date -Format 's') + '|' + $Name)
    if (Test-Path -LiteralPath $script:RecentPath) {
        $n = 0
        foreach ($line in [System.IO.File]::ReadAllLines($script:RecentPath, [System.Text.Encoding]::UTF8)) {
            if ($line -like ('*|' + $Name)) { continue }
            if ($n -ge 40) { break }
            $lines.Add($line)
            $n++
        }
    }
    [System.IO.File]::WriteAllLines($script:RecentPath, $lines, (New-Object System.Text.UTF8Encoding($true)))
}

#endregion data

#region exe resolution

$script:ExeBlocklist = @(
    'unitycrashhandler*', 'unins*.exe', 'uninstall*', '*setup*', '*installer*', '*install*',
    'vcredist*', 'dxsetup*', 'dxwebsetup*', '*crashpad*', '*crashreport*', '*crashhandler*',
    'easyanticheat*', 'start_protected_game*', 'battleye*', '*updater*', '*update*',
    '*config*', '*setting*', '*option*', '*register*', '*benchmark*',
    'notepad*', 'cmd.exe', '*dedicated*', '*redist*', '*dotnet*', '*cleanup*', '*repair*',
    '*修改器*', '*trainer*', '*启动说明*', '*注册机*', '*卸载*', '*安装*', '*补丁*',
    '*修复*', '*工具*', '*说明*', '*编辑器*', '*mod*', '*server*', '*service*',
    'python*', 'java*', 'node.exe', '*helper*'
)

$script:ExePrefer = @('开始游戏*', 'start*.exe', 'play*.exe', 'launch*.exe', 'game.exe', '*启动*')

function Get-CandidateExes {
    param([string]$Root, [int]$MaxDepth = 3)
    $found = New-Object System.Collections.Generic.List[object]
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue([pscustomobject]@{ Path = $Root; Depth = 0 })
    while ($queue.Count -gt 0) {
        $node = $queue.Dequeue()
        $files = @()
        try { $files = @([System.IO.Directory]::EnumerateFiles($node.Path, '*.exe')) } catch { }
        foreach ($f in $files) {
            try {
                $fi = New-Object System.IO.FileInfo $f
                $found.Add([pscustomobject]@{ Path = $f; Name = $fi.Name; Size = $fi.Length; Depth = $node.Depth })
            } catch { }
        }
        if ($node.Depth -ge $MaxDepth) { continue }
        try {
            foreach ($d in [System.IO.Directory]::EnumerateDirectories($node.Path)) {
                $leaf = [System.IO.Path]::GetFileName($d)
                if ($leaf -match '^(Redist|_CommonRedist|DirectX|dotnet|Support|EasyAntiCheat|BattlEye|__Installer|Engine)$') { continue }
                $queue.Enqueue([pscustomobject]@{ Path = $d; Depth = $node.Depth + 1 })
            }
        } catch { }
    }
    return , $found
}

function Get-LaunchExe {
    param([string]$Root, [string]$EntryName)
    $cands = Get-CandidateExes -Root $Root
    if ($cands.Count -eq 0) { return $null }
    $scored = New-Object System.Collections.Generic.List[object]
    foreach ($c in $cands) {
        $blocked = $false
        foreach ($pat in $script:ExeBlocklist) { if ($c.Name -like $pat) { $blocked = $true; break } }
        if ($blocked) { continue }
        $score = 0
        $lower = $c.Name.ToLowerInvariant()
        foreach ($pat in $script:ExePrefer) { if ($lower -like $pat.ToLowerInvariant()) { $score += 40; break } }
        $a = ($EntryName -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
        $b = ([System.IO.Path]::GetFileNameWithoutExtension($c.Name) -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
        if ($a -and $b) {
            if ($a -eq $b) { $score += 60 }
            elseif ($b.StartsWith($a) -or $a.StartsWith($b)) { $score += 30 }
            elseif ($b.Contains($a) -or $a.Contains($b)) { $score += 15 }
        }
        $score -= ($c.Depth * 8)
        $score += [math]::Min([math]::Log10([math]::Max($c.Size, 1024)) * 3, 24)
        $scored.Add([pscustomobject]@{ Path = $c.Path; Name = $c.Name; Size = $c.Size; Score = [math]::Round($score, 1) })
    }
    if ($scored.Count -eq 0) { return $null }
    return ($scored | Sort-Object Score, @{Expression = 'Size'; Descending = $true } | Select-Object -First 1)
}

function Get-ExeIcon {
    param([string]$ExePath)
    if (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath)) { return $null }
    try {
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($ExePath)
        if (-not $ico) { return $null }
        $bmp = $ico.ToBitmap()
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $ms.Position = 0
        $frame = [System.Windows.Media.Imaging.BitmapFrame]::Create(
            $ms, [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
            [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $ms.Dispose(); $bmp.Dispose(); $ico.Dispose()
        return $frame
    } catch { return $null }
}

#endregion exe resolution

#region visuals helpers

function Convert-HslToColor {
    param([double]$H, [double]$S, [double]$L)
    $c = (1 - [math]::Abs(2 * $L - 1)) * $S
    $x = $c * (1 - [math]::Abs((($H / 60) % 2) - 1))
    $m = $L - $c / 2
    $r = 0.0; $g = 0.0; $b = 0.0
    if ($H -lt 60) { $r = $c; $g = $x }
    elseif ($H -lt 120) { $r = $x; $g = $c }
    elseif ($H -lt 180) { $g = $c; $b = $x }
    elseif ($H -lt 240) { $g = $x; $b = $c }
    elseif ($H -lt 300) { $r = $x; $b = $c }
    else { $r = $c; $b = $x }
    $rr = [byte][math]::Round(($r + $m) * 255)
    $gg = [byte][math]::Round(($g + $m) * 255)
    $bb = [byte][math]::Round(($b + $m) * 255)
    return [System.Windows.Media.Color]::FromRgb($rr, $gg, $bb)
}

function Get-NameHue {
    param([string]$Name)
    # FNV-1a truncated with modulo. A "sum * 31 + char" hash collapsed every name
    # onto the same low bits, which is exactly what a palette index reads.
    $h = [long]2166136261
    foreach ($b in [System.Text.Encoding]::Unicode.GetBytes($Name)) {
        $h = $h -bxor $b
        $h = ($h * 16777619) % 4294967296
    }
    $palette = @(268, 285, 305, 322, 340, 200, 190, 250)
    return $palette[[int](($h -shr 7) % $palette.Count)]
}

function Get-Initials {
    param([string]$Name)
    $clean = ($Name -replace '^(The|A|An)\s+', '').Trim()
    # @() matters: a split yielding one part returns a bare string, and indexing
    # that hands back a Char instead of a String.
    $parts = @($clean -split '[\s\-_:]+' | Where-Object { $_ })
    if ($parts.Count -eq 0) { return '?' }
    if ($parts.Count -eq 1) {
        $w = [string]$parts[0]
        if ($w -match '^[\u4e00-\u9fff\u3040-\u30ff]') { return $w.Substring(0, [math]::Min(2, $w.Length)) }
        return $w.Substring(0, [math]::Min(2, $w.Length)).ToUpperInvariant()
    }
    $a = ([string]$parts[0]).Substring(0, 1)
    $b = ([string]$parts[1]).Substring(0, 1)
    return ($a + $b).ToUpperInvariant()
}

function Get-Subtitle {
    # The Chinese/Japanese original, when the note carries one. Skipping "18+" and
    # annotation-only segments keeps "18+" from showing up as a subtitle.
    param([string]$Note)
    if (-not $Note) { return '' }
    foreach ($seg in ($Note -split '[，,]')) {
        $seg = $seg.Trim()
        if ($seg -eq '') { continue }
        if ($seg -match '^18\+') { continue }
        if ($seg -notmatch '[\u4e00-\u9fff\u3040-\u30ff]') { continue }
        if ($seg -match '^(含|需|原|已|从|支持|附|赠|内容)') { continue }
        if ($seg.Length -gt 20) { return $seg.Substring(0, 19) + '…' }
        return $seg
    }
    return ''
}

function Get-CategoryCode {
    param([string]$Category)
    $map = @{
        '01_Action-Adventure' = 'AC'; '02_RPG' = 'RP'; '03_Shooter' = 'SH'
        '04_Racing-Sports'    = 'RC'; '05_Strategy-Sim' = 'ST'; '06_Indie-Roguelike' = 'IN'
        '07_Party-Casual'     = 'PC'; '08_Visual-Novel' = 'VN'; '09_Emulator' = 'EM'
        '10_Archive'          = 'AR'; '11_Other' = 'OT'
    }
    if ($map.ContainsKey($Category)) { return $map[$Category] }
    return $Category.Substring(0, [math]::Min(2, $Category.Length)).ToUpperInvariant()
}

#endregion visuals helpers

#region resolve every entry

Write-Host ''
Write-Host '  Reading shelf...' -ForegroundColor DarkGray

$entries = Read-Shelf -Path $manifest
$script:launchMap = Read-LaunchConfig -Path $script:LaunchConfigPath
$sw = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($e in $entries) {
    $e | Add-Member -NotePropertyName ExePath -NotePropertyValue $null -Force
    $e | Add-Member -NotePropertyName ExeName -NotePropertyValue '' -Force
    $e | Add-Member -NotePropertyName Mapped -NotePropertyValue $false -Force
    $e | Add-Member -NotePropertyName OpenFolderOnly -NotePropertyValue $false -Force

    # A target may be written %label%\... so the manifest travels between machines;
    # Path is what it means here, and Available is whether this machine has it at
    # all - only the junction is proof, since that is what launching goes through.
    $resolved = Resolve-ShelfTarget -Target $e.Target -Roots $script:roots
    $e | Add-Member -NotePropertyName Path -NotePropertyValue $resolved.Path -Force
    $e | Add-Member -NotePropertyName Portable -NotePropertyValue ([bool]$resolved.Label) -Force
    $e | Add-Member -NotePropertyName Bound -NotePropertyValue $resolved.Bound -Force
    $e | Add-Member -NotePropertyName Available -NotePropertyValue $false -Force

    $link = Join-Path (Join-Path $ShelfPath $e.Category) $e.Name
    $probe = $link
    if (-not (Test-Path -LiteralPath $probe)) { $probe = $e.Path }
    if (-not (Test-Path -LiteralPath $probe)) { continue }
    $e.Available = $true

    if ($script:launchMap.ContainsKey($e.Name)) {
        $rel = $script:launchMap[$e.Name]
        if ($rel -eq $script:FOLDER_SENTINEL) {
            $e.OpenFolderOnly = $true
            $e.Mapped = $true
            continue
        }
        $cand = Join-Path $probe $rel
        if (Test-Path -LiteralPath $cand) {
            $e.ExePath = $cand
            $e.ExeName = Split-Path -Leaf $cand
            $e.Mapped = $true
            continue
        }
        Write-Host ("  ! mapping points at a missing file: " + $e.Name + ' -> ' + $rel) -ForegroundColor Yellow
    }

    $pick = Get-LaunchExe -Root $probe -EntryName $e.Name
    if ($pick) {
        $rel = $pick.Path.Substring($probe.Length).TrimStart('\')
        $e.ExePath = Join-Path $link $rel
        if (-not (Test-Path -LiteralPath $e.ExePath)) { $e.ExePath = $pick.Path }
        $e.ExeName = $pick.Name
    }
}

$launchable = @($entries | Where-Object { $_.ExePath })

# The window shows this machine's shelf: an entry whose folder is not here cannot be
# launched, and on a shelf that lives in git that is most of the library on the
# second computer. The count of the rest is kept for the status line so the absence
# is stated rather than hidden.
$script:elsewhere = @($entries | Where-Object { -not $_.Available }).Count
$entries = @($entries | Where-Object { $_.Available })

Write-Host ("  {0} entries, {1} launchable, {2} not on this machine ({3:N1}s)" -f `
        $entries.Count, $launchable.Count, $script:elsewhere, $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray

if ($NoUI) {
    foreach ($g in ($entries | Group-Object Category | Sort-Object Name)) {
        Write-Host ('  [' + $g.Name + ']') -ForegroundColor Cyan
        foreach ($e in ($g.Group | Sort-Object Name)) {
            if ($e.OpenFolderOnly) { Write-Host ('    {0,-38} (open folder)' -f $e.Name) -ForegroundColor DarkGray }
            elseif ($e.ExePath) { Write-Host ('    {0,-38} {1}' -f $e.Name, $e.ExeName) }
            else { Write-Host ('    {0,-38} !! nothing found' -f $e.Name) -ForegroundColor Yellow }
        }
    }
    return
}

#endregion resolve every entry

#region ui

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Game Library" Width="1440" Height="900"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        FontFamily="Segoe UI Variable Display, Segoe UI, Microsoft YaHei UI"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">

  <Window.Resources>
    <SolidColorBrush x:Key="Bg"      Color="#FF0F0F0F"/>
    <SolidColorBrush x:Key="Surface" Color="#FF1A1A1A"/>
    <SolidColorBrush x:Key="TileBg"  Color="#FF262626"/>
    <SolidColorBrush x:Key="TextHi"  Color="#FFFFFFFF"/>
    <SolidColorBrush x:Key="TextLo"  Color="#FF9E9E9E"/>
    <SolidColorBrush x:Key="Accent"  Color="#FF107C10"/>
  </Window.Resources>

  <Border x:Name="RootBorder" CornerRadius="8" BorderThickness="1"
          Background="{StaticResource Bg}" BorderBrush="#FF2E2E2E">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="56"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="28"/>
      </Grid.RowDefinitions>

      <!-- top bar -->
      <Grid Grid.Row="0" x:Name="TopBar">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <StackPanel Grid.Column="0" Orientation="Horizontal" Margin="22,0,0,0" VerticalAlignment="Center">
          <Border Width="26" Height="26" CornerRadius="6" Background="{StaticResource Accent}">
            <!-- MinWidth: the glyph measures a hair wider than the cell the border
                 gives it by default, and the right edge of the triangle was being
                 cut. -Diag reports it as CLIPPED when it regresses. -->
            <TextBlock Text="&#x25B6;" FontSize="12" MinWidth="16" TextAlignment="Center"
                       Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock Text="游戏库" FontSize="15" FontWeight="SemiBold" Margin="10,0,0,0"
                     VerticalAlignment="Center" Foreground="{StaticResource TextHi}"/>
        </StackPanel>

        <Border Grid.Column="1" x:Name="SearchBox" Width="340" Height="32" CornerRadius="16"
                Background="#FF1F1F1F" BorderBrush="#FF333333" BorderThickness="1"
                HorizontalAlignment="Left" Margin="28,0,0,0" VerticalAlignment="Center">
          <Grid>
            <TextBlock Text="&#xE721;" FontFamily="Segoe MDL2 Assets" FontSize="12" Margin="13,0,0,0"
                       VerticalAlignment="Center" Foreground="{StaticResource TextLo}"/>
            <TextBox x:Name="Search" Background="Transparent" BorderThickness="0" Foreground="White"
                     CaretBrush="White" FontSize="13" Margin="34,0,12,0" VerticalContentAlignment="Center"/>
            <TextBlock x:Name="SearchHint" Text="搜索游戏" FontSize="13" Margin="35,0,0,0"
                       VerticalAlignment="Center" Foreground="#FF9E9E9E" IsHitTestVisible="False"/>
          </Grid>
        </Border>

        <StackPanel Grid.Column="2" Orientation="Horizontal" Margin="0,0,8,0" VerticalAlignment="Center">
          <Button x:Name="BtnMin" Content="&#xE921;" FontFamily="Segoe MDL2 Assets" Width="42" Height="32"
                  FontSize="10" Foreground="#FFB0B0B0" Background="Transparent" BorderThickness="0" Cursor="Hand"/>
          <Button x:Name="BtnMax" Content="&#xE922;" FontFamily="Segoe MDL2 Assets" Width="42" Height="32"
                  FontSize="10" Foreground="#FFB0B0B0" Background="Transparent" BorderThickness="0" Cursor="Hand"/>
          <Button x:Name="BtnClose" Content="&#xE8BB;" FontFamily="Segoe MDL2 Assets" Width="42" Height="32"
                  FontSize="10" Foreground="#FFB0B0B0" Background="Transparent" BorderThickness="0" Cursor="Hand"/>
        </StackPanel>
      </Grid>

      <!-- rail + content -->
      <Grid Grid.Row="1">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="84"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <Border Grid.Column="0" Background="#FF141414" BorderBrush="#FF232323" BorderThickness="0,0,1,0">
          <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel x:Name="NavRail" Margin="0,10,0,10"/>
          </ScrollViewer>
        </Border>

        <Grid Grid.Column="1">
          <ScrollViewer x:Name="Scroller" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel x:Name="ContentHost" Margin="0,0,0,24"/>
          </ScrollViewer>
        </Grid>
      </Grid>

      <Grid Grid.Row="2" Margin="24,0,24,0">
        <TextBlock x:Name="Status" FontSize="11" Foreground="#FF8A8A8A" VerticalAlignment="Center"/>
        <TextBlock x:Name="Toast" FontSize="11.5" Foreground="#FF8CD98C"
                   HorizontalAlignment="Right" VerticalAlignment="Center"/>
      </Grid>

      <Canvas x:Name="Petals" Grid.RowSpan="3" IsHitTestVisible="False" ClipToBounds="True" Visibility="Collapsed"/>
    </Grid>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$root = $window.FindName('RootBorder')
$topBar = $window.FindName('TopBar')
$navRail = $window.FindName('NavRail')
$contentHost = $window.FindName('ContentHost')
$scroller = $window.FindName('Scroller')
$search = $window.FindName('Search')
$searchHint = $window.FindName('SearchHint')
$status = $window.FindName('Status')
$toast = $window.FindName('Toast')
$petals = $window.FindName('Petals')

$script:COL_BG = [System.Windows.Media.Color]::FromRgb(0x0F, 0x0F, 0x0F)
$script:COL_TEXT_HI = [System.Windows.Media.Color]::FromRgb(0xFF, 0xFF, 0xFF)
$script:COL_TEXT_LO = [System.Windows.Media.Color]::FromRgb(0x9E, 0x9E, 0x9E)
$script:COL_ACCENT = [System.Windows.Media.Color]::FromRgb(0x10, 0x7C, 0x10)
$script:COL_ACCENT_HI = [System.Windows.Media.Color]::FromRgb(0x16, 0xA0, 0x16)

function New-Brush { param([System.Windows.Media.Color]$C) New-Object System.Windows.Media.SolidColorBrush $C }

$toastTimer = New-Object System.Windows.Threading.DispatcherTimer
$toastTimer.Interval = [TimeSpan]::FromSeconds(3)
$toastTimer.Add_Tick({ $toast.Text = ''; $toastTimer.Stop() })

function Show-Toast([string]$Text) {
    $toast.Text = $Text
    $toastTimer.Stop()
    $toastTimer.Start()
}

function Start-Entry {
    param($Entry)
    if ($Entry.OpenFolderOnly) {
        Start-Process explorer.exe (Get-RealPath -Entry $Entry)
        Show-Toast ($Entry.Name + ' 是合集/压缩包，已打开目录')
        return
    }
    if (-not $Entry.ExePath -or -not (Test-Path -LiteralPath $Entry.ExePath)) {
        Show-Toast '没有可启动的程序，右键磁贴可设置'
        return
    }
    try {
        $wd = Split-Path -Parent $Entry.ExePath
        Start-Process -FilePath $Entry.ExePath -WorkingDirectory $wd
        Add-Recent -Name $Entry.Name
        Show-Toast ('正在启动  ' + $Entry.Name)
    } catch {
        Show-Toast ('启动失败: ' + $_.Exception.Message)
    }
}

#endregion ui

#region tiles, rails, hero

function New-Tile {
    param($Entry, [int]$Size = 158)

    $hue = Get-NameHue -Name $Entry.Name
    $c1 = Convert-HslToColor -H $hue -S 0.52 -L 0.34
    $c2 = Convert-HslToColor -H (($hue + 24) % 360) -S 0.48 -L 0.16

    $wrap = New-Object System.Windows.Controls.StackPanel
    $wrap.Width = $Size
    $wrap.Margin = New-Object System.Windows.Thickness(0, 0, 12, 14)

    $tile = New-Object System.Windows.Controls.Border
    $tile.Width = $Size
    $tile.Height = $Size
    $tile.CornerRadius = New-Object System.Windows.CornerRadius(8)
    $tile.BorderThickness = New-Object System.Windows.Thickness(2)
    $tile.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x00, 0xFF, 0xFF, 0xFF))
    $tile.Cursor = [System.Windows.Input.Cursors]::Hand
    $tile.Tag = $Entry

    # The shelf label can be a rename of the real folder, and the path is what the
    # context menu copies anyway - so put it under the cursor on hover.
    $tip = '' 
    if ($Entry.Note) { $tip = $Entry.Note + "`n" }
    $tile.ToolTip = $tip + (Get-RealPath -Entry $Entry)

    $grad = New-Object System.Windows.Media.LinearGradientBrush
    $grad.StartPoint = New-Object System.Windows.Point(0, 0)
    $grad.EndPoint = New-Object System.Windows.Point(1, 1)
    $grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop($c1, 0)))
    $grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop($c2, 1)))
    $tile.Background = $grad

    $inner = New-Object System.Windows.Controls.Grid

    $ini = New-Object System.Windows.Controls.TextBlock
    $ini.Text = Get-Initials -Name $Entry.Name
    $ini.FontSize = 40
    $ini.FontWeight = 'Bold'
    $ini.HorizontalAlignment = 'Center'
    $ini.VerticalAlignment = 'Center'
    $ini.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0xD0, 0xFF, 0xFF, 0xFF))
    $inner.Children.Add($ini) | Out-Null

    $frame = Get-ExeIcon -ExePath $Entry.ExePath
    if ($frame) {
        $img = New-Object System.Windows.Controls.Image
        $img.Source = $frame
        $img.Width = 30
        $img.Height = 30
        $img.HorizontalAlignment = 'Left'
        $img.VerticalAlignment = 'Bottom'
        $img.Margin = New-Object System.Windows.Thickness(10, 0, 0, 10)
        $inner.Children.Add($img) | Out-Null
    }

    $badge = New-Object System.Windows.Controls.Border
    $badge.CornerRadius = New-Object System.Windows.CornerRadius(4)
    $badge.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0xA0, 0x00, 0x00, 0x00))
    $badge.Padding = New-Object System.Windows.Thickness(5, 2, 5, 2)
    $badge.HorizontalAlignment = 'Right'
    $badge.VerticalAlignment = 'Top'
    $badge.Margin = New-Object System.Windows.Thickness(0, 7, 7, 0)
    $bt = New-Object System.Windows.Controls.TextBlock
    $bt.Text = Get-CategoryCode -Category $Entry.Category
    $bt.FontSize = 9
    $bt.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0xCC, 0xFF, 0xFF, 0xFF))
    $badge.Child = $bt
    $inner.Children.Add($badge) | Out-Null

    $tile.Child = $inner
    $wrap.Children.Add($tile) | Out-Null

    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = $Entry.Name
    $title.FontSize = 12
    $title.Margin = New-Object System.Windows.Thickness(1, 7, 0, 0)
    $title.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0xE6, 0xFF, 0xFF, 0xFF))
    $title.TextTrimming = 'CharacterEllipsis'
    $wrap.Children.Add($title) | Out-Null

    $subText = Get-Subtitle -Note $Entry.Note
    if ($subText) {
        $sub = New-Object System.Windows.Controls.TextBlock
        $sub.Text = $subText
        $sub.FontSize = 10.5
        $sub.Margin = New-Object System.Windows.Thickness(1, 2, 0, 0)
        $sub.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x99, 0x9E, 0x9E, 0x9E))
        $sub.TextTrimming = 'CharacterEllipsis'
        $wrap.Children.Add($sub) | Out-Null
    }

    # Xbox-style focus: white outline, slight lift, gentle scale
    $scale = New-Object System.Windows.Media.ScaleTransform(1, 1)
    $tile.RenderTransform = $scale
    $tile.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)

    $tile.Add_MouseEnter({
            param($s, $ev)
            $s.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0xFF, 0xFF, 0xFF, 0xFF))
            $s.RenderTransform.ScaleX = 1.05
            $s.RenderTransform.ScaleY = 1.05
            $eff = New-Object System.Windows.Media.Effects.DropShadowEffect
            $eff.Color = [System.Windows.Media.Color]::FromRgb(0, 0, 0)
            $eff.BlurRadius = 18
            $eff.ShadowDepth = 3
            $eff.Opacity = 0.7
            $s.Effect = $eff
        })
    $tile.Add_MouseLeave({
            param($s, $ev)
            $s.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x00, 0xFF, 0xFF, 0xFF))
            $s.RenderTransform.ScaleX = 1
            $s.RenderTransform.ScaleY = 1
            $s.Effect = $null
        })
    $tile.Add_MouseLeftButtonDown({
            param($s, $ev)
            if ($ev.ClickCount -eq 2) { Start-Entry -Entry $s.Tag }
        })

    $menu = New-Object System.Windows.Controls.ContextMenu
    $miOpen = New-Object System.Windows.Controls.MenuItem
    $miOpen.Header = '打开游戏目录'
    $miOpen.Tag = $Entry
    $miOpen.Add_Click({
            param($s, $ev)
            $e = $s.Tag
            $p = $e.ExePath
            if ($p) { $p = Split-Path -Parent $p } else { $p = Get-RealPath -Entry $e }
            if (Test-Path -LiteralPath $p) { Start-Process explorer.exe $p }
        })
    $menu.Items.Add($miOpen) | Out-Null

    $miCopy = New-Object System.Windows.Controls.MenuItem
    $miCopy.Header = '复制真实路径'
    $miCopy.Tag = $Entry
    $miCopy.Add_Click({
            param($s, $ev)
            [System.Windows.Clipboard]::SetText((Get-RealPath -Entry $s.Tag))
            Show-Toast '已复制路径'
        })
    $menu.Items.Add($miCopy) | Out-Null

    $miSet = New-Object System.Windows.Controls.MenuItem
    $miSet.Header = '设置启动程序…'
    $miSet.Tag = $Entry
    $miSet.Add_Click({
            param($s, $ev)
            $e = $s.Tag
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Filter = '可执行文件 (*.exe)|*.exe|所有文件 (*.*)|*.*'
            $dlg.Title = '选择要启动的程序 — ' + $e.Name
            $real = Get-RealPath -Entry $e
            if (Test-Path -LiteralPath $real) { $dlg.InitialDirectory = $real }
            if ($dlg.ShowDialog() -eq $true) {
                $chosen = $dlg.FileName
                $rel = $chosen
                if ($chosen.StartsWith($real, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $rel = $chosen.Substring($real.Length).TrimStart('\')
                }
                $script:launchMap[$e.Name] = $rel
                Save-LaunchConfig -Path $script:LaunchConfigPath -Map $script:launchMap
                $e.ExePath = $chosen
                $e.ExeName = Split-Path -Leaf $chosen
                $e.OpenFolderOnly = $false
                Show-Toast ('已设置：' + $e.ExeName)
                Rebuild-Content
            }
        })
    $menu.Items.Add($miSet) | Out-Null

    $miFolder = New-Object System.Windows.Controls.MenuItem
    $miFolder.Header = '改为「双击打开文件夹」'
    $miFolder.Tag = $Entry
    $miFolder.Add_Click({
            param($s, $ev)
            $e = $s.Tag
            $script:launchMap[$e.Name] = $script:FOLDER_SENTINEL
            Save-LaunchConfig -Path $script:LaunchConfigPath -Map $script:launchMap
            $e.OpenFolderOnly = $true
            $e.ExePath = $null
            Show-Toast ($e.Name + ' 改为打开文件夹')
            Rebuild-Content
        })
    $menu.Items.Add($miFolder) | Out-Null

    $tile.ContextMenu = $menu
    return $wrap
}

function New-Heading {
    param([string]$Text, [string]$Right = '')
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = New-Object System.Windows.Thickness(24, 22, 24, 10)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.FontSize = 15
    $t.FontWeight = 'SemiBold'
    $t.Foreground = New-Object System.Windows.Media.SolidColorBrush $script:COL_TEXT_HI
    $grid.Children.Add($t) | Out-Null
    if ($Right) {
        $r = New-Object System.Windows.Controls.TextBlock
        $r.Text = $Right
        $r.FontSize = 11.5
        $r.HorizontalAlignment = 'Right'
        $r.VerticalAlignment = 'Center'
        $r.Foreground = New-Object System.Windows.Media.SolidColorBrush $script:COL_TEXT_LO
        $grid.Children.Add($r) | Out-Null
    }
    return $grid
}

function New-TileGrid {
    <#
      Tiles flow into rows and wrap. A WrapPanel inside a vertically scrolling
      ScrollViewer with horizontal scrolling disabled takes the viewport width, so
      everything is reachable by scrolling down - no sideways dragging.
    #>
    param([object[]]$Items, [int]$TileSize = 158)
    $panel = New-Object System.Windows.Controls.WrapPanel
    $panel.Orientation = 'Horizontal'
    $panel.Margin = New-Object System.Windows.Thickness(24, 0, 12, 0)
    foreach ($e in $Items) { $panel.Children.Add((New-Tile -Entry $e -Size $TileSize)) | Out-Null }
    return $panel
}

function New-Hero {
    <#
      -Recent says whether this entry came from _recent.txt. Without it the banner
      labelled whatever it was showing as "最近游玩" - including the first game on
      the shelf, which nobody had played yet.
    #>
    param($Entry, [switch]$Recent)
    if (-not $Entry) { return $null }

    $hue = Get-NameHue -Name $Entry.Name
    $c1 = Convert-HslToColor -H $hue -S 0.60 -L 0.30
    $c2 = Convert-HslToColor -H (($hue + 40) % 360) -S 0.55 -L 0.10
    $c3 = Convert-HslToColor -H (($hue + 300) % 360) -S 0.50 -L 0.18

    $card = New-Object System.Windows.Controls.Border
    $card.Height = 236
    $card.CornerRadius = New-Object System.Windows.CornerRadius(8)
    $card.Margin = New-Object System.Windows.Thickness(24, 20, 24, 0)
    $card.ClipToBounds = $true

    $grad = New-Object System.Windows.Media.LinearGradientBrush
    $grad.StartPoint = New-Object System.Windows.Point(0, 0)
    $grad.EndPoint = New-Object System.Windows.Point(1, 0.6)
    $grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop($c1, 0)))
    $grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop($c2, 1)))
    $card.Background = $grad

    $grid = New-Object System.Windows.Controls.Grid

    $watermark = New-Object System.Windows.Controls.TextBlock
    $watermark.Text = Get-Initials -Name $Entry.Name
    $watermark.FontSize = 150
    $watermark.FontWeight = 'Bold'
    $watermark.HorizontalAlignment = 'Right'
    $watermark.VerticalAlignment = 'Center'
    $watermark.Margin = New-Object System.Windows.Thickness(0, 0, 44, 0)
    $watermark.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x1E, 0xFF, 0xFF, 0xFF))
    $grid.Children.Add($watermark) | Out-Null

    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.VerticalAlignment = 'Center'
    $stack.Margin = New-Object System.Windows.Thickness(34, 0, 0, 0)

    $kicker = New-Object System.Windows.Controls.TextBlock
    if ($Recent) { $kicker.Text = '最近游玩' } else { $kicker.Text = '开始游玩' }
    $kicker.FontSize = 11
    $kicker.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0xCC, 0xFF, 0xFF, 0xFF))
    $stack.Children.Add($kicker) | Out-Null

    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = $Entry.Name
    $title.FontSize = 34
    $title.FontWeight = 'Bold'
    $title.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
    $title.Foreground = New-Object System.Windows.Media.SolidColorBrush $script:COL_TEXT_HI
    $stack.Children.Add($title) | Out-Null

    $subText = Get-Subtitle -Note $Entry.Note
    $metaText = $subText
    if ($metaText) { $metaText = $metaText + '   ·   ' }
    $metaText = $metaText + ($Entry.Category -replace '^\d+_', '')
    $meta = New-Object System.Windows.Controls.TextBlock
    $meta.Text = $metaText
    $meta.FontSize = 12.5
    $meta.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)
    $meta.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0xCC, 0xFF, 0xFF, 0xFF))
    $stack.Children.Add($meta) | Out-Null

    $play = New-Object System.Windows.Controls.Border
    $play.CornerRadius = New-Object System.Windows.CornerRadius(4)
    $play.Background = New-Object System.Windows.Media.SolidColorBrush $script:COL_ACCENT
    $play.Padding = New-Object System.Windows.Thickness(20, 9, 22, 9)
    $play.Margin = New-Object System.Windows.Thickness(0, 18, 0, 0)
    $play.HorizontalAlignment = 'Left'
    $play.Cursor = [System.Windows.Input.Cursors]::Hand
    $play.Tag = $Entry
    $playInner = New-Object System.Windows.Controls.StackPanel
    $playInner.Orientation = 'Horizontal'
    $playGlyph = New-Object System.Windows.Controls.TextBlock
    $playGlyph.Text = [char]0x25B6
    $playGlyph.FontSize = 11
    $playGlyph.MinWidth = 16
    $playGlyph.TextAlignment = 'Center'
    $playGlyph.VerticalAlignment = 'Center'
    $playGlyph.Foreground = New-Object System.Windows.Media.SolidColorBrush $script:COL_TEXT_HI
    $playInner.Children.Add($playGlyph) | Out-Null
    $playText = New-Object System.Windows.Controls.TextBlock
    # Say what the click will do. A collection or an archive opens its folder, and
    # an entry with no executable yet does nothing until one is set - a button
    # labelled 启动 in those cases is just wrong.
    $playLabel = '启动'
    if ($Entry.OpenFolderOnly) { $playLabel = '打开目录' }
    elseif (-not $Entry.ExePath) { $playLabel = '未设置启动程序' }
    $playText.Text = $playLabel
    $playText.FontSize = 13
    $playText.FontWeight = 'SemiBold'
    $playText.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
    $playText.VerticalAlignment = 'Center'
    $playText.Foreground = New-Object System.Windows.Media.SolidColorBrush $script:COL_TEXT_HI
    $playInner.Children.Add($playText) | Out-Null
    $play.Child = $playInner
    $play.Add_MouseEnter({ param($s, $ev) $s.Background = New-Object System.Windows.Media.SolidColorBrush $script:COL_ACCENT_HI })
    $play.Add_MouseLeave({ param($s, $ev) $s.Background = New-Object System.Windows.Media.SolidColorBrush $script:COL_ACCENT })
    $play.Add_MouseLeftButtonUp({ param($s, $ev) Start-Entry -Entry $s.Tag })
    $stack.Children.Add($play) | Out-Null

    $grid.Children.Add($stack) | Out-Null
    $card.Child = $grid

    # Exposed for -Diag, which reports what the banner claims to be showing.
    $script:heroInfo = [pscustomobject]@{
        Name   = $Entry.Name
        Kicker = $kicker.Text
        Action = $playLabel
    }
    return $card
}

#endregion tiles, rails, hero

#region nav + composition

$script:activeCat = ''
$navButtons = New-Object System.Collections.Generic.List[object]

function New-NavButton {
    param([string]$Code, [string]$Label, [string]$Value, [int]$Count)

    $b = New-Object System.Windows.Controls.Button
    $b.Width = 84
    $b.Height = 62
    $b.Cursor = [System.Windows.Input.Cursors]::Hand
    $b.BorderThickness = New-Object System.Windows.Thickness(3, 0, 0, 0)
    $b.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x00, 0xFF, 0xFF, 0xFF))
    $b.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x00, 0xFF, 0xFF, 0xFF))
    $b.Tag = $Value
    $b.Padding = New-Object System.Windows.Thickness(0)

    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.HorizontalAlignment = 'Center'
    $sp.VerticalAlignment = 'Center'

    $badge = New-Object System.Windows.Controls.Border
    $badge.Width = 28
    $badge.Height = 28
    $badge.CornerRadius = New-Object System.Windows.CornerRadius(6)
    $badge.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x22, 0xFF, 0xFF, 0xFF))
    $badge.HorizontalAlignment = 'Center'
    $bt = New-Object System.Windows.Controls.TextBlock
    $bt.Text = $Code
    $bt.FontSize = 11
    $bt.FontWeight = 'SemiBold'
    $bt.HorizontalAlignment = 'Center'
    $bt.VerticalAlignment = 'Center'
    $bt.Foreground = New-Object System.Windows.Media.SolidColorBrush $script:COL_TEXT_HI
    $badge.Child = $bt
    $sp.Children.Add($badge) | Out-Null

    $lb = New-Object System.Windows.Controls.TextBlock
    $lb.Text = $Label
    $lb.FontSize = 9.5
    $lb.Margin = New-Object System.Windows.Thickness(0, 3, 0, 0)
    $lb.HorizontalAlignment = 'Center'
    $lb.TextTrimming = 'CharacterEllipsis'
    $lb.MaxWidth = 74
    $lb.Foreground = New-Object System.Windows.Media.SolidColorBrush $script:COL_TEXT_LO
    $sp.Children.Add($lb) | Out-Null

    $b.Content = $sp

    $b.Add_Click({
            param($s, $ev)
            $script:activeCat = $s.Tag
            foreach ($x in $navButtons) {
                if ($x.Tag -eq $script:activeCat) {
                    $x.BorderBrush = New-Object System.Windows.Media.SolidColorBrush $script:COL_ACCENT
                    $x.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x18, 0xFF, 0xFF, 0xFF))
                    $x.Content.Children[0].Background = New-Object System.Windows.Media.SolidColorBrush $script:COL_ACCENT
                } else {
                    $x.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x00, 0xFF, 0xFF, 0xFF))
                    $x.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x00, 0xFF, 0xFF, 0xFF))
                    $x.Content.Children[0].Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x22, 0xFF, 0xFF, 0xFF))
                }
            }
            Rebuild-Content
        })
    $b.Add_MouseEnter({
            param($s, $ev)
            if ($s.Tag -ne $script:activeCat) {
                $s.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x12, 0xFF, 0xFF, 0xFF))
            }
        })
    $b.Add_MouseLeave({
            param($s, $ev)
            if ($s.Tag -ne $script:activeCat) {
                $s.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x00, 0xFF, 0xFF, 0xFF))
            }
        })

    $navButtons.Add($b)
    return $b
}

function Rebuild-Content {
    $contentHost.Children.Clear()

    if ($entries.Count -eq 0) {
        <#
          Everything on the shelf is somewhere else: a manifest that travels between
          machines, opened on one whose roots are not bound yet - or a shelf whose
          game folders have gone. Saying so beats an empty window.
        #>
        $none = New-Object System.Windows.Controls.TextBlock
        $none.Text = '本机没有可用的游戏'
        $none.FontSize = 15
        $none.Margin = New-Object System.Windows.Thickness(24, 26, 24, 0)
        $none.Foreground = New-Object System.Windows.Media.SolidColorBrush $script:COL_TEXT_LO
        $contentHost.Children.Add($none) | Out-Null

        if ($script:elsewhere -gt 0) {
            $why = New-Object System.Windows.Controls.TextBlock
            $why.Text = ("清单里有 {0} 款，但它们的目录不在这台电脑上。用 gameshelf.ps1 roots -Shelf <文件架> 看看要绑定哪些根目录。" -f $script:elsewhere)
            $why.FontSize = 12
            $why.TextWrapping = 'Wrap'
            $why.MaxWidth = 820
            $why.Margin = New-Object System.Windows.Thickness(24, 8, 24, 0)
            $why.Foreground = New-Object System.Windows.Media.SolidColorBrush $script:COL_TEXT_LO
            $contentHost.Children.Add($why) | Out-Null
        }
        Update-Status
        return
    }

    $query = $search.Text
    if ($query) {
        $hits = @($entries | Where-Object {
                ($_.Name + ' ' + $_.Note + ' ' + $_.Category) -like ('*' + $query + '*')
            })
        $contentHost.Children.Add((New-Heading -Text '搜索结果' -Right ("$($hits.Count) 个结果"))) | Out-Null
        if ($hits.Count -gt 0) {
            $contentHost.Children.Add((New-TileGrid -Items $hits)) | Out-Null
        } else {
            $none = New-Object System.Windows.Controls.TextBlock
            $none.Text = '没有匹配的游戏'
            $none.FontSize = 13
            $none.Margin = New-Object System.Windows.Thickness(24, 10, 0, 0)
            $none.Foreground = New-Object System.Windows.Media.SolidColorBrush $script:COL_TEXT_LO
            $contentHost.Children.Add($none) | Out-Null
        }
        Update-Status -Scope ('搜索：{0} 个结果' -f $hits.Count)
        return
    }

    if ($script:activeCat) {
        $items = @($entries | Where-Object { $_.Category -eq $script:activeCat })
        $label = $script:activeCat -replace '^\d+_', ''
        $contentHost.Children.Add((New-Heading -Text $label -Right ("$($items.Count) 款"))) | Out-Null
        $contentHost.Children.Add((New-TileGrid -Items $items)) | Out-Null
        Update-Status -Scope ('{0}：{1} 款' -f $label, $items.Count)
        return
    }

    # Xbox layout: hero, then recently played, then one rail per category
    $recentNames = Read-Recent
    $recent = New-Object System.Collections.Generic.List[object]
    foreach ($n in $recentNames) {
        foreach ($e in $entries) { if ($e.Name -eq $n) { $recent.Add($e); break } }
    }

    $hero = $null
    if ($recent.Count -gt 0) { $hero = $recent[0] } elseif ($entries.Count -gt 0) { $hero = $entries[0] }
    $heroCard = New-Hero -Entry $hero -Recent:($recent.Count -gt 0)
    if ($heroCard) { $contentHost.Children.Add($heroCard) | Out-Null }

    if ($recent.Count -gt 1) {
        $contentHost.Children.Add((New-Heading -Text '最近游玩')) | Out-Null
        $contentHost.Children.Add((New-TileGrid -Items $recent)) | Out-Null
    }

    foreach ($g in ($entries | Group-Object Category | Sort-Object Name)) {
        $label = $g.Name -replace '^\d+_', ''
        $contentHost.Children.Add((New-Heading -Text $label -Right ("$($g.Count) 款"))) | Out-Null
        $contentHost.Children.Add((New-TileGrid -Items @($g.Group | Sort-Object Name))) | Out-Null
    }
    Update-Status
}

function Update-Status {
    <#
      Says what is on screen, not what the shelf holds. After a search or a category
      click the old line still reported the whole library next to a heading that
      said "3 个结果", which reads as a bug.
    #>
    param([string]$Scope = '')

    $hint = '双击磁贴启动，右键更多操作'
    $elsewhere = ''
    if ($script:elsewhere -gt 0) { $elsewhere = ("   ·   另有 {0} 款不在本机" -f $script:elsewhere) }
    if ($Scope) {
        $status.Text = (("{0}   ·   本机 {1} 款   ·   {2}" -f $Scope, $entries.Count, $hint) + $elsewhere)
    } else {
        $status.Text = (("{0} 款游戏   ·   {1} 个分类   ·   {2}" -f `
                $entries.Count, @($entries | Group-Object Category).Count, $hint) + $elsewhere)
    }
}

$navRail.Children.Add((New-NavButton -Code 'ALL' -Label '全部' -Value '' -Count $entries.Count)) | Out-Null
foreach ($g in ($entries | Group-Object Category | Sort-Object Name)) {
    $navRail.Children.Add((New-NavButton -Code (Get-CategoryCode -Category $g.Name) -Label ($g.Name -replace '^\d+_', '') -Value $g.Name -Count $g.Count)) | Out-Null
}
# highlight "全部" on startup
$navButtons[0].BorderBrush = New-Object System.Windows.Media.SolidColorBrush $script:COL_ACCENT
$navButtons[0].Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(0x18, 0xFF, 0xFF, 0xFF))
$navButtons[0].Content.Children[0].Background = New-Object System.Windows.Media.SolidColorBrush $script:COL_ACCENT

$search.Add_TextChanged({
        $searchHint.Visibility = 'Collapsed'
        if ($search.Text -eq '') { $searchHint.Visibility = 'Visible' }
        Rebuild-Content
    })

Rebuild-Content

<#
  A launcher started by launch.vbs goes through WScript.Shell.Run(..., 0, ...),
  which hands SW_HIDE to the process as its startup show-state. WPF's first
  top-level window inherits it and ends up minimized off-screen. Force it back to
  a normal foreground window as soon as the handle exists. (GameShelf.Native is
  declared once, near the top of this script.)
#>
function Show-LauncherWindow {
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        $h = $helper.Handle
        if ($h -eq [IntPtr]::Zero) { return }
        $window.WindowState = [System.Windows.WindowState]::Normal
        [GameShelf.Native]::ShowWindow($h, 9) | Out-Null   # SW_RESTORE
        [GameShelf.Native]::SetForegroundWindow($h) | Out-Null
    } catch { }
}

$window.Add_SourceInitialized({ Show-LauncherWindow })
$window.Add_Loaded({ Show-LauncherWindow })

#region diagnostics

# Helpers for -Diag and -Shot. They are only ever called from those two paths, and
# they exist so a UI change can be argued about with numbers instead of taste.

function Get-Descendants {
    param($Root, [Type]$Type)
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $v = $stack.Pop()
        $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($v)
        for ($i = 0; $i -lt $n; $i++) {
            $child = [System.Windows.Media.VisualTreeHelper]::GetChild($v, $i)
            if ($child -is $Type) { $child }
            $stack.Push($child)
        }
    }
}

function Get-TextBlockList { param($Root) Get-Descendants -Root $Root -Type ([System.Windows.Controls.TextBlock]) }
function Get-ButtonList { param($Root) Get-Descendants -Root $Root -Type ([System.Windows.Controls.Button]) }

function Test-TextFits {
    <#
      Lays the same string out with the same typeface and compares the width it
      needs with the width it was given. A TextBlock with no room and no
      TextTrimming is cut off mid-word, which is invisible in a geometry dump.
    #>
    param($TextBlock)

    $size = 12.0
    if ($TextBlock.FontSize -gt 0) { $size = $TextBlock.FontSize }
    $typeface = New-Object System.Windows.Media.Typeface($TextBlock.FontFamily,
        $TextBlock.FontStyle, $TextBlock.FontWeight, $TextBlock.FontStretch)
    $ft = New-Object System.Windows.Media.FormattedText($TextBlock.Text,
        [System.Globalization.CultureInfo]::CurrentUICulture,
        [System.Windows.FlowDirection]::LeftToRight, $typeface, $size,
        [System.Windows.Media.Brushes]::White)

    return [pscustomobject]@{
        Needed = $ft.Width
        Have   = $TextBlock.ActualWidth
        Trims  = ($TextBlock.TextTrimming -ne [System.Windows.TextTrimming]::None)
    }
}

function Get-RelativeLuminance {
    param([System.Windows.Media.Color]$Colour)
    $channel = {
        param([double]$v)
        $s = $v / 255.0
        if ($s -le 0.03928) { return $s / 12.92 }
        return [math]::Pow((($s + 0.055) / 1.055), 2.4)
    }
    return (0.2126 * (& $channel $Colour.R) + 0.7152 * (& $channel $Colour.G) + 0.0722 * (& $channel $Colour.B))
}

function Get-ContrastRatio {
    param([System.Windows.Media.Color]$Fore, [System.Windows.Media.Color]$Back)
    $a = Get-RelativeLuminance -Colour $Fore
    $b = Get-RelativeLuminance -Colour $Back
    $hi = [math]::Max($a, $b)
    $lo = [math]::Min($a, $b)
    return [math]::Round((($hi + 0.05) / ($lo + 0.05)), 2)
}

function Get-EffectiveBackground {
    <#
      Walks up from a text node blending whatever backgrounds it passes over, so a
      white label inside a 13%-white badge on the window still reports the colour
      it is really drawn against. Gradients are not blended, so text on the hero
      banner reports against the window instead - optimistic, never pessimistic,
      which keeps the audit free of false alarms.
    #>
    param($Visual)

    $layers = New-Object System.Collections.Generic.List[object]
    $cur = $Visual
    while ($null -ne $cur) {
        $prop = $cur.PSObject.Properties['Background']
        if ($null -ne $prop -and $prop.Value -is [System.Windows.Media.SolidColorBrush]) {
            $c = $prop.Value.Color
            if ($c.A -gt 0) {
                # A control's template repeats its own Background, so walking up
                # meets the same semi-transparent layer twice. Counting it twice
                # darkens the reading and invents failures that are not there.
                $dup = $false
                if ($layers.Count -gt 0) {
                    $last = $layers[$layers.Count - 1]
                    if ($last.A -eq $c.A -and $last.R -eq $c.R -and $last.G -eq $c.G -and $last.B -eq $c.B) { $dup = $true }
                }
                if (-not $dup) { $layers.Add($c) }
            }
        }
        if ($layers.Count -ge 4) { break }
        $cur = [System.Windows.Media.VisualTreeHelper]::GetParent($cur)
    }

    $result = [System.Windows.Media.Color]::FromArgb(255, 0x0F, 0x0F, 0x0F)
    for ($i = $layers.Count - 1; $i -ge 0; $i--) {
        $c = $layers[$i]
        $a = $c.A / 255.0
        $result = [System.Windows.Media.Color]::FromArgb(255,
            [int]($c.R * $a + $result.R * (1 - $a)),
            [int]($c.G * $a + $result.G * (1 - $a)),
            [int]($c.B * $a + $result.B * (1 - $a)))
    }

    # The chain is returned as well: a contrast ratio is only actionable if you can
    # see what it was measured against, and a wrong reading is obvious from it.
    $chain = $layers | ForEach-Object { '#{0:X2}{1:X2}{2:X2}(a={3:X2})' -f $_.R, $_.G, $_.B, $_.A }
    return [pscustomobject]@{
        Colour = $result
        Chain  = (($chain -join ' over ') + ' over #0F0F0F')
    }
}

#endregion diagnostics

if ($Diag) {
    <#
      Headless layout check: measure the built grids, audit the text, and write it
      all to a log. The grid geometry confirms the tiles actually wrap into rows
      instead of forming one long horizontal strip; the rest checks the things a
      layout can get wrong silently, which is unreadable text, clipped text and
      targets too small to hit. -Shot draws the same window to a PNG for the parts
      a measurement cannot judge.
    #>
    $window.Add_ContentRendered({
            $log = Join-Path (Join-Path $ShelfPath '_ui') '_layout.log'
            $lines = New-Object System.Collections.Generic.List[string]
            $lines.Add(('window            : {0:N0} x {1:N0}' -f $window.ActualWidth, $window.ActualHeight))
            $lines.Add(('scroll viewport   : {0:N0} wide' -f $scroller.ViewportWidth))
            $lines.Add(('horizontal scroll : {0}' -f $scroller.ComputedHorizontalScrollBarVisibility))
            $lines.Add(('top-level blocks  : {0}' -f $contentHost.Children.Count))
            foreach ($child in $contentHost.Children) {
                if ($child -is [System.Windows.Controls.WrapPanel]) {
                    $rows = @{}
                    $cols = @{}
                    foreach ($k in $child.Children) {
                        $pt = $k.TranslatePoint((New-Object System.Windows.Point(0, 0)), $child)
                        $rows[[int][math]::Round($pt.Y)] = $true
                        $cols[[int][math]::Round($pt.X)] = $true
                    }
                    $lines.Add(('  grid: {0,2} tiles   {1} columns   {2} rows   panel {3:N0} x {4:N0}' -f `
                                $child.Children.Count, $cols.Count, $rows.Count, $child.ActualWidth, $child.ActualHeight))
                }
            }

            # ---- text: clipped or unreadable ------------------------------------
            if ($script:heroInfo) {
                $lines.Add('')
                $lines.Add(('hero              : {0}' -f $script:heroInfo.Name))
                $lines.Add(('  kicker / action : {0} / {1}' -f $script:heroInfo.Kicker, $script:heroInfo.Action))
            }

            $texts = @(Get-TextBlockList -Root $root)
            $lines.Add('')
            $lines.Add(('text blocks       : {0}' -f $texts.Count))

            $clipped = 0
            $ellipsised = 0
            foreach ($t in $texts) {
                if (-not $t.Text) { continue }
                if ($t.TextWrapping -ne [System.Windows.TextWrapping]::NoWrap) { continue }
                $fit = Test-TextFits -TextBlock $t
                if ($fit.Needed -le ($fit.Have + 1)) { continue }
                if ($fit.Trims) { $ellipsised++; continue }
                $clipped++
                $shown = $t.Text
                if ($shown.Length -gt 40) { $shown = $shown.Substring(0, 37) + '...' }
                $lines.Add(('  CLIPPED {0,7:N0}px text in {1,6:N0}px   "{2}"' -f $fit.Needed, $fit.Have, $shown))
            }
            $lines.Add(('  ellipsised      : {0}   (by design, TextTrimming is set)' -f $ellipsised))
            $lines.Add(('  clipped         : {0}   (no room and no trimming - text is cut)' -f $clipped))

            # ---- contrast against the surface behind each text -------------------
            <#
              WCAG AA wants 4.5:1 for body text and 3:1 for large text (>=18.66px
              bold or >=24px). Text on a gradient reports against the window colour
              instead of the gradient, so those readings are optimistic - the point
              is to catch dim grey on near-black, which is what this UI had.
            #>
            $lines.Add('')
            $lines.Add('contrast (WCAG AA: 4.5 body, 3.0 large)')
            $worst = @()
            foreach ($t in $texts) {
                if (-not $t.Text) { continue }
                $fg = $t.Foreground
                if ($fg -isnot [System.Windows.Media.SolidColorBrush]) { continue }
                if ($fg.Color.A -lt 255) { continue }   # alpha blended elsewhere; skip rather than guess
                $backInfo = Get-EffectiveBackground -Visual $t
                $back = $backInfo.Colour
                $ratio = Get-ContrastRatio -Fore $fg.Color -Back $back
                $large = ($t.FontSize -ge 24) -or (($t.FontSize -ge 18.66) -and ($t.FontWeight.ToString() -match 'Bold|SemiBold|Black|Heavy'))
                $need = 3.0
                if (-not $large) { $need = 4.5 }
                if ($ratio -lt $need) {
                    $shown = $t.Text
                    if ($shown.Length -gt 30) { $shown = $shown.Substring(0, 27) + '...' }
                    # The resolved background is printed too: a ratio is only worth
                    # acting on if you can see what it was measured against.
                    $worst += ('  FAIL {0,5:N2}:1  need {1:N1}  {2,5:N1}px  on #{3:X2}{4:X2}{5:X2}  "{6}"' -f `
                            $ratio, $need, $t.FontSize, $back.R, $back.G, $back.B, $shown)
                    $worst += ('       layers: {0}' -f $backInfo.Chain)
                }
            }
            if ($worst.Count -eq 0) { $lines.Add('  all readable') } else { foreach ($w in $worst) { $lines.Add($w) } }

            # ---- hit targets ----------------------------------------------------
            $small = @()
            foreach ($b in @(Get-ButtonList -Root $root)) {
                if ($b.ActualWidth -lt 32 -or $b.ActualHeight -lt 32) {
                    $small += ('  small target {0,4:N0} x {1,-4:N0} {2}' -f $b.ActualWidth, $b.ActualHeight, $b.GetType().Name)
                }
            }
            $lines.Add('')
            $lines.Add(('hit targets < 32px : {0}' -f $small.Count))
            foreach ($s in $small) { $lines.Add($s) }

            [System.IO.File]::WriteAllLines($log, $lines, (New-Object System.Text.UTF8Encoding($false)))
            $window.Close()
        })
}

#endregion nav + composition

#region chrome + optional petals

$topBar.Add_MouseLeftButtonDown({ param($s, $ev) try { $window.DragMove() } catch { } })
$window.FindName('BtnMin').Add_Click({ $window.WindowState = 'Minimized' })
$window.FindName('BtnMax').Add_Click({
        if ($window.WindowState -eq 'Maximized') { $window.WindowState = 'Normal' }
        else { $window.WindowState = 'Maximized' }
    })
$window.FindName('BtnClose').Add_Click({ $window.Close() })

if ($Sakura) {
    $petals.Visibility = 'Visible'
    $rand = New-Object System.Random
    $petalList = New-Object System.Collections.Generic.List[object]
    $geo = [System.Windows.Media.Geometry]::Parse('M0,0 C5,-5 11,-1 10,6 C9,12 3,15 0,0 Z')
    for ($i = 0; $i -lt 20; $i++) {
        $p = New-Object System.Windows.Shapes.Path
        $p.Data = $geo
        $sz = 5 + $rand.NextDouble() * 6
        $tg = New-Object System.Windows.Media.TransformGroup
        $sc = New-Object System.Windows.Media.ScaleTransform(($sz / 10.0), ($sz / 10.0))
        $rot = New-Object System.Windows.Media.RotateTransform(($rand.NextDouble() * 360))
        $tg.Children.Add($sc) | Out-Null
        $tg.Children.Add($rot) | Out-Null
        $p.RenderTransform = $tg
        $alpha = [byte](35 + $rand.Next(60))
        $p.Fill = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb($alpha, 0xFF, 0x9F, 0xCF))
        [System.Windows.Controls.Canvas]::SetLeft($p, $rand.NextDouble() * 1440)
        [System.Windows.Controls.Canvas]::SetTop($p, $rand.NextDouble() * 900)
        $petals.Children.Add($p) | Out-Null
        $petalList.Add([pscustomobject]@{
                Shape = $p
                Vy    = 0.35 + $rand.NextDouble() * 0.8
                Vx    = -0.2 + $rand.NextDouble() * 0.4
                Spin  = -0.8 + $rand.NextDouble() * 1.6
                Phase = $rand.NextDouble() * 6.28
            })
    }
    $petalTimer = New-Object System.Windows.Threading.DispatcherTimer
    $petalTimer.Interval = [TimeSpan]::FromMilliseconds(33)
    $petalTimer.Add_Tick({
            $h = $petals.ActualHeight
            $w = $petals.ActualWidth
            if ($w -le 0 -or $h -le 0) { return }
            foreach ($pt in $petalList) {
                $top = [System.Windows.Controls.Canvas]::GetTop($pt.Shape) + $pt.Vy
                $left = [System.Windows.Controls.Canvas]::GetLeft($pt.Shape) + $pt.Vx + [math]::Sin($top / 60.0 + $pt.Phase) * 0.5
                if ($top -gt $h + 20) { $top = -20; $left = $rand.NextDouble() * $w }
                if ($left -lt -20) { $left = $w + 10 }
                if ($left -gt $w + 20) { $left = -10 }
                [System.Windows.Controls.Canvas]::SetTop($pt.Shape, $top)
                [System.Windows.Controls.Canvas]::SetLeft($pt.Shape, $left)
                $pt.Shape.RenderTransform.Children[1].Angle = ($pt.Shape.RenderTransform.Children[1].Angle + $pt.Spin) % 360
            }
        })
    $petalTimer.Start()
    $window.Add_Closed({ $petalTimer.Stop() })
}

if ($Shot) {
    <#
      Measure, arrange, draw. The window is never shown, so nothing here depends on
      a display, a session or a GPU presenter - which is the point: a UI change can
      be looked at (and diffed against the last one) on a headless machine.
    #>
    $w = [double]$window.Width
    $h = [double]$window.Height
    $root.Measure([System.Windows.Size]::new($w, $h))
    $root.Arrange([System.Windows.Rect]::new(0, 0, $w, $h))
    $root.UpdateLayout()

    $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
        [int]$w, [int]$h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($root)

    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))

    $dir = Split-Path -Parent $Shot
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        # CreateDirectory is a no-op on an existing path and does not throw on a
        # drive root, where New-Item -ItemType Directory refuses outright.
        [void][System.IO.Directory]::CreateDirectory($dir)
    }
    $stream = [System.IO.File]::Create($Shot)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }

    Write-Output ('shot : {0}' -f (Resolve-Path -LiteralPath $Shot).Path)
    Write-Output ('size : {0:N0} x {1:N0}' -f $w, $h)
    exit 0
}

$window.Add_Closed({
        $toastTimer.Stop()
        if (-not $headless) {
            # Tidy up the single-instance markers. A stale pid file is harmless
            # (Focus-RunningInstance just fails to find a window), but leaving it
            # around is untidy.
            try {
                if (Test-Path -LiteralPath $script:InstancePidFile) {
                    $raw = ([System.IO.File]::ReadAllText($script:InstancePidFile)).Trim()
                    if ($raw -eq [string]$PID) { Remove-Item -LiteralPath $script:InstancePidFile -Force }
                }
            } catch { }
            try { if ($script:instanceMutex) { $script:instanceMutex.ReleaseMutex(); $script:instanceMutex.Dispose() } } catch { }
        }
    })
$window.ShowDialog() | Out-Null

#endregion chrome + optional petals
