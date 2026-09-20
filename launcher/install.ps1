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
# Dark rounded tile, green play button - matches the launcher's own top-left mark.
$N = 256
$bmp = New-Object System.Drawing.Bitmap $N, $N, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.Clear([System.Drawing.Color]::Transparent)

function New-RoundedRect([int]$x, [int]$y, [int]$w, [int]$h, [int]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc($x, $y, $r, $r, 180, 90)
    $p.AddArc($x + $w - $r, $y, $r, $r, 270, 90)
    $p.AddArc($x + $w - $r, $y + $h - $r, $r, $r, 0, 90)
    $p.AddArc($x, $y + $h - $r, $r, $r, 90, 90)
    $p.CloseFigure()
    return $p
}

$outer = New-RoundedRect 8 8 240 240 46
$g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 0x1F, 0x1F, 0x1F))), $outer)

$inner = New-RoundedRect 44 44 168 168 30
$g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 0x10, 0x7C, 0x10))), $inner)

# play triangle, nudged right so it looks optically centred
$tri = New-Object System.Drawing.Drawing2D.GraphicsPath
$tri.AddPolygon(@(
        (New-Object System.Drawing.Point 112, 88),
        (New-Object System.Drawing.Point 112, 168),
        (New-Object System.Drawing.Point 176, 128)
    ))
$g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)), $tri)
$g.Dispose()

$lockRect = New-Object System.Drawing.Rectangle 0, 0, $N, $N
$data = $bmp.LockBits($lockRect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$stride = $data.Stride
$pixels = New-Object byte[] ($stride * $N)
[System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
$bmp.UnlockBits($data)
$bmp.Dispose()

# A hand-built 32bpp DIB entry. Hand-rolling a PNG entry inside an ICO renders in
# Explorer but System.Drawing.Icon cannot read it back, which breaks tooling.
$xorSize = $N * $N * 4
$andStride = [int]([math]::Ceiling($N / 32.0) * 4)
$andSize = $andStride * $N
$imgSize = 40 + $xorSize + $andSize

$icoPath = Join-Path $uiDir 'icon.ico'
$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]1)
$bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0)
$bw.Write([uint16]1); $bw.Write([uint16]32)
$bw.Write([uint32]$imgSize); $bw.Write([uint32]22)
$bw.Write([uint32]40)
$bw.Write([int32]$N)
$bw.Write([int32]($N * 2))
$bw.Write([uint16]1); $bw.Write([uint16]32)
$bw.Write([uint32]0); $bw.Write([uint32]$xorSize)
$bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([uint32]0); $bw.Write([uint32]0)
for ($y = $N - 1; $y -ge 0; $y--) { $bw.Write($pixels, $y * $stride, $N * 4) }
$bw.Write((New-Object byte[] $andSize))
$bw.Flush()
[System.IO.File]::WriteAllBytes($icoPath, $ms.ToArray())
$bw.Close(); $ms.Dispose()
Write-Output ("icon      : " + $icoPath)

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
