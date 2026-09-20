<#
.SYNOPSIS
    Install the GameShelf Launcher next to a shelf.

.DESCRIPTION
    Copies the launcher into <shelf>\_ui\, generates a matching icon, writes a
    no-console .vbs entry point and puts a shortcut on the Desktop.

.EXAMPLE
    .\install.ps1 -ShelfPath H:\Games
.EXAMPLE
    .\install.ps1 -ShelfPath H:\Games -ShortcutName 'Games' -NoShortcut
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ShelfPath,
    [string]$ShortcutName = '游戏架',
    [switch]$NoShortcut
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path -LiteralPath (Join-Path $ShelfPath '_shelf.txt'))) {
    throw "Not a gameshelf (no _shelf.txt): $ShelfPath"
}

$uiDir = Join-Path $ShelfPath '_ui'
if (-not (Test-Path -LiteralPath $uiDir)) { New-Item -ItemType Directory -Path $uiDir | Out-Null }

# ---------------------------------------------------------------- app
$src = Join-Path $PSScriptRoot 'GameLauncher.ps1'
if (-not (Test-Path -LiteralPath $src)) { throw "GameLauncher.ps1 not found next to install.ps1" }
$appPath = Join-Path $uiDir 'GameLauncher.ps1'
Copy-Item -LiteralPath $src -Destination $appPath -Force
Write-Output ("app       : " + $appPath)

# ---------------------------------------------------------------- icon
<#
  A dark rounded tile with a green play button, matching the launcher's own
  top-left mark.

  Two details that matter for how it actually looks:
    * Every size from 16 to 256 is drawn at its own resolution rather than
      downscaled from one big bitmap, so the taskbar and Alt-Tab versions stay
      crisp instead of soft.
    * Entries are uncompressed 32bpp DIBs. A PNG payload inside an ICO renders
      fine in Explorer but System.Drawing.Icon cannot read it back, which breaks
      any tooling that touches the file.
#>
function New-RoundedRect([double]$x, [double]$y, [double]$w, [double]$h, [double]$r) {
    if ($r -lt 1) { $r = 1 }
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc([single]$x, [single]$y, [single]$r, [single]$r, 180, 90)
    $p.AddArc([single]($x + $w - $r), [single]$y, [single]$r, [single]$r, 270, 90)
    $p.AddArc([single]($x + $w - $r), [single]($y + $h - $r), [single]$r, [single]$r, 0, 90)
    $p.AddArc([single]$x, [single]($y + $h - $r), [single]$r, [single]$r, 90, 90)
    $p.CloseFigure()
    return $p
}

function New-LauncherIconPixels {
    param([int]$Size)

    # Draw on a 256-unit design grid and scale, so proportions hold at every size.
    $k = $Size / 256.0
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    # outer tile: faint vertical gradient plus a light rim for definition on dark desktops
    $tileRect = New-Object System.Drawing.Rectangle 0, 0, $Size, $Size
    $tile = New-RoundedRect (8 * $k) (8 * $k) (240 * $k) (240 * $k) (52 * $k)
    $tileBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush $tileRect,
    ([System.Drawing.Color]::FromArgb(255, 0x2A, 0x2A, 0x2A)),
    ([System.Drawing.Color]::FromArgb(255, 0x12, 0x12, 0x12)), 90.0
    $g.FillPath($tileBrush, $tile)
    if ($Size -ge 32) {
        $rim = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(70, 0xFF, 0xFF, 0xFF), [single](2.4 * $k))
        $g.DrawPath($rim, $tile)
    }

    # green button: lit at the top-left, deeper at the bottom
    $btnRect = New-Object System.Drawing.Rectangle 0, 0, $Size, $Size
    $btn = New-RoundedRect (46 * $k) (46 * $k) (164 * $k) (164 * $k) (36 * $k)
    $btnBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush $btnRect,
    ([System.Drawing.Color]::FromArgb(255, 0x22, 0xC5, 0x22)),
    ([System.Drawing.Color]::FromArgb(255, 0x0A, 0x5A, 0x0A)), 60.0
    $g.FillPath($btnBrush, $btn)

    # play triangle: optically centred by shifting right by ~6% of the button
    $cx = 128.0
    $cy = 128.0
    $half = 42.0
    $shift = 7.0
    $tri = New-Object System.Drawing.Drawing2D.GraphicsPath
    # ::new rather than New-Object Type(a), (b): a comma there is parsed as an
    # argument separator for New-Object, not as a two-argument constructor call.
    $tri.AddPolygon([System.Drawing.PointF[]]@(
            [System.Drawing.PointF]::new([single](($cx - $half + $shift) * $k), [single](($cy - $half) * $k)),
            [System.Drawing.PointF]::new([single](($cx - $half + $shift) * $k), [single](($cy + $half) * $k)),
            [System.Drawing.PointF]::new([single](($cx + $half + $shift) * $k), [single]($cy * $k))
        ))
    if ($Size -ge 48) {
        $shadow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(60, 0x00, 0x00, 0x00))
        $shifted = $tri.Clone()
        $shifted.Transform((New-Object System.Drawing.Drawing2D.Matrix(1, 0, 0, 1, [single](1.5 * $k), [single](1.5 * $k))))
        $g.FillPath($shadow, $shifted)
    }
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)), $tri)
    $g.Dispose()

    $rect = New-Object System.Drawing.Rectangle 0, 0, $Size, $Size
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $data.Stride
    $bytes = New-Object byte[] ($stride * $Size)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
    $bmp.UnlockBits($data)
    $bmp.Dispose()

    return [pscustomobject]@{ Size = $Size; Stride = $stride; Pixels = $bytes }
}

$icoPath = Join-Path $uiDir 'icon.ico'
$frames = @()
foreach ($size in @(16, 24, 32, 48, 64, 128, 256)) {
    $frames += New-LauncherIconPixels -Size $size
}

$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$frames.Count)

$offset = 6 + (16 * $frames.Count)
foreach ($f in $frames) {
    $xorSize = $f.Size * $f.Size * 4
    $andStride = [int]([math]::Ceiling($f.Size / 32.0) * 4)
    $andSize = $andStride * $f.Size
    $imgSize = 40 + $xorSize + $andSize
    # 0 means 256 in the ICONDIRENTRY width/height bytes
    if ($f.Size -ge 256) { $bw.Write([byte]0); $bw.Write([byte]0) }
    else { $bw.Write([byte]$f.Size); $bw.Write([byte]$f.Size) }
    $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$imgSize); $bw.Write([uint32]$offset)
    $offset += $imgSize
}
foreach ($f in $frames) {
    $xorSize = $f.Size * $f.Size * 4
    $andStride = [int]([math]::Ceiling($f.Size / 32.0) * 4)
    $andSize = $andStride * $f.Size
    $bw.Write([uint32]40)
    $bw.Write([int32]$f.Size)
    $bw.Write([int32]($f.Size * 2))
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]0); $bw.Write([uint32]$xorSize)
    $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([uint32]0); $bw.Write([uint32]0)
    for ($y = $f.Size - 1; $y -ge 0; $y--) { $bw.Write($f.Pixels, $y * $f.Stride, $f.Size * 4) }
    $bw.Write((New-Object byte[] $andSize))
}
$bw.Flush()
[System.IO.File]::WriteAllBytes($icoPath, $ms.ToArray())
$bw.Close(); $ms.Dispose()
Write-Output ("icon      : {0}  ({1} sizes, {2:N0} KB)" -f $icoPath, $frames.Count, ((Get-Item -LiteralPath $icoPath).Length / 1KB))

# ---------------------------------------------------------------- no-console entry point
$vbs = @"
' Starts the shelf launcher with no console window.
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$appPath""", 0, False
"@
[System.IO.File]::WriteAllText((Join-Path $uiDir 'launch.vbs'), $vbs, [System.Text.Encoding]::ASCII)
Write-Output ("launcher  : " + (Join-Path $uiDir 'launch.vbs'))

# ---------------------------------------------------------------- shortcut
if (-not $NoShortcut) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnkPath = Join-Path $desktop ($ShortcutName + '.lnk')
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = 'wscript.exe'
    $lnk.Arguments = '"' + (Join-Path $uiDir 'launch.vbs') + '"'
    $lnk.WorkingDirectory = $ShelfPath
    $lnk.IconLocation = $icoPath + ',0'
    $lnk.Description = 'GameShelf Launcher'
    $lnk.Save()
    Write-Output ("shortcut  : " + $lnkPath)
}

Write-Output ''
Write-Output 'Done. Double-click the shortcut to open the library.'
