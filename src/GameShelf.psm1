<#
.SYNOPSIS
    GameShelf - build one browsable folder for things scattered across drives,
    without moving a single byte.

.DESCRIPTION
    Core module. Everything is driven by a plain-text manifest and a self-describing
    `_shelf.txt` written next to the links, so there is no hidden database state.

    Modes:
        Link  (default) NTFS directory junctions. No space, nothing moves.
        Move            Actually relocate folders. Cross-volume moves copy+delete.
        Copy            Duplicate folders into the shelf. Needs free space.

    Requires Windows PowerShell 5.1 or PowerShell 7+.
#>

Set-StrictMode -Version Latest

$script:GSFormatVersion = 1
$script:GSManifestName = '_shelf.txt'

# Save-data support lives in its own file to keep this one navigable. Dot-sourced
# so its functions share this module's scope (and its StrictMode).
. (Join-Path $PSScriptRoot 'GameShelf.Saves.ps1')

# Integrations with tools that know things GameShelf would otherwise guess at:
# Ludusavi for save locations, Playnite for the library itself. Both are optional
# at runtime - nothing here is required for a shelf to work.
. (Join-Path $PSScriptRoot 'GameShelf.Ludusavi.ps1')
. (Join-Path $PSScriptRoot 'GameShelf.Playnite.ps1')

#region ---------------------------------------------------------------- manifest

function Import-GSManifest {
    <#
    .SYNOPSIS
        Parse a shelf manifest file.
    .DESCRIPTION
        Pipe-delimited text (default):
            category|name|target|note
        or a CSV file with columns category,name,target,note.
        Blank lines and lines starting with '#' are ignored.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Manifest not found: $Path" }

    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)

    if ([System.IO.Path]::GetExtension($Path) -ieq '.csv') {
        $rows = @($text | ConvertFrom-Csv)
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($r in $rows) {
            $cat = Get-GSProp $r 'category'
            $name = Get-GSProp $r 'name'
            $target = Get-GSProp $r 'target'
            if (-not $cat -or -not $name -or -not $target) { continue }
            $items.Add([pscustomobject]@{
                    Category = $cat
                    Name     = $name
                    Target   = $target
                    Note     = (Get-GSProp $r 'note')
                })
        }
        if ($items.Count -eq 0) { throw "CSV manifest has no usable rows: $Path" }
        # Leading comma: keeps the List intact instead of unwrapping a single item.
        return , $items
    }

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($raw in ($text -split "`r?`n")) {
        $line = $raw.Trim()
        if ($line.Length -eq 0) { continue }
        if ($line.StartsWith('#')) { continue }

        $parts = $line.Split('|')
        if ($parts.Count -lt 3) {
            Write-Warning "Skipping malformed line: $line"
            continue
        }
        $note = ''
        if ($parts.Count -ge 4) { $note = $parts[3].Trim() }
        $items.Add([pscustomobject]@{
                Category = $parts[0].Trim()
                Name     = $parts[1].Trim()
                Target   = $parts[2].Trim()
                Note     = $note
            })
    }

    if ($items.Count -eq 0) { throw "Manifest has no usable items: $Path" }
    # Leading comma: keeps the List intact instead of unwrapping a single item.
    return , $items
}

function Get-GSProp {
    # Safe property read: returns '' instead of throwing under StrictMode.
    # Handles hashtables (whose keys are not PSObject properties) as well.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return '' }
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) { return '' }
        $v = $Object[$Name]
        if ($null -eq $v) { return '' }
        return ([string]$v).Trim()
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return '' }
    return ([string]$p.Value).Trim()
}

function Get-GSJsonMember {
    # Safe member read for objects that came out of ConvertFrom-Json.
    # Get-GSProp flattens everything to a trimmed string, which is right for
    # manifest columns and wrong here: a score of 0, a boolean false and a missing
    # key have to stay distinguishable, and under StrictMode a missing one is an
    # exception rather than $null. Covers PSCustomObject (the default) and
    # dictionaries (-AsHashtable, PowerShell 7).
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Export-GSManifest {
    <#
    .SYNOPSIS
        Write a manifest, optionally with a '# key: value' metadata header.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Position = 1)][object[]]$Items = @(),
        [hashtable]$Meta
    )

    $out = New-Object System.Collections.Generic.List[string]
    if ($Meta) {
        $out.Add("# gameshelf v$script:GSFormatVersion")
        foreach ($k in ($Meta.Keys | Sort-Object)) { $out.Add("# ${k}: $($Meta[$k])") }
    }
    foreach ($i in $Items) {
        $note = ''
        if ($null -ne $i.Note) { $note = $i.Note }
        $out.Add(('{0}|{1}|{2}|{3}' -f $i.Category, $i.Name, $i.Target, $note))
    }

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllLines($Path, $out, (New-Object System.Text.UTF8Encoding($true)))
}

function Get-GSManifestMeta {
    <#
    .SYNOPSIS
        Read the '# key: value' header lines of a manifest.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $meta = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $meta }
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        if (-not $line.StartsWith('#')) { continue }
        $body = $line.Substring(1).Trim()
        $idx = $body.IndexOf(':')
        if ($idx -lt 1) { continue }
        $meta[$body.Substring(0, $idx).Trim()] = $body.Substring($idx + 1).Trim()
    }
    return $meta
}

#endregion ------------------------------------------------------------- manifest

#region ------------------------------------------------------------------ links

function Test-GSLink {
    <#
    .SYNOPSIS
        True when the path exists and is a junction or symbolic link.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    try {
        $attr = [System.IO.File]::GetAttributes($Path)
    } catch {
        return $false
    }
    return (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-GSLinkTarget {
    <#
    .SYNOPSIS
        Resolve a junction / symlink target. Returns $null for a real folder.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    if (-not (Test-GSLink -Path $Path)) { return $null }
    $item = Get-Item -LiteralPath $Path -Force
    $t = $item.Target
    if ($t -is [array]) { $t = $t[0] }
    if (-not $t) { return $null }
    return ([string]$t)
}

function New-GSLink {
    <#
    .SYNOPSIS
        Create a directory junction. Does not require administrator rights.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LinkPath,
        [Parameter(Mandatory)][string]$TargetPath
    )

    if (Test-Path -LiteralPath $LinkPath) { throw "Already exists: $LinkPath" }
    if (-not (Test-Path -LiteralPath $TargetPath)) { throw "Target missing: $TargetPath" }

    $resolved = (Get-Item -LiteralPath $TargetPath -Force).FullName
    $parent = Split-Path -Parent $LinkPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $firstError = ''
    try {
        New-Item -ItemType Junction -Path $LinkPath -Target $resolved -ErrorAction Stop | Out-Null
    } catch {
        $firstError = $_.Exception.Message
    }

    if (-not (Test-GSLink -Path $LinkPath)) {
        $fallback = & cmd.exe /c mklink /J "$LinkPath" "$resolved" 2>&1
        if (-not (Test-GSLink -Path $LinkPath)) {
            throw "Could not create junction '$LinkPath' -> '$resolved'. New-Item said: $firstError | mklink said: $fallback"
        }
    }
    return $resolved
}

function Remove-GSLink {
    <#
    .SYNOPSIS
        Remove a junction. Never removes the data behind it.
    .DESCRIPTION
        Uses Directory.Delete(path, recursive: $false), which unlinks the reparse
        point itself. Recursive deletion is deliberately avoided because it can
        follow the link and destroy the target folder.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$LinkPath)

    if (-not (Test-Path -LiteralPath $LinkPath)) { return 'absent' }
    if (-not (Test-GSLink -Path $LinkPath)) {
        throw "Refusing to remove '$LinkPath': it is a real folder, not a junction."
    }

    [System.IO.Directory]::Delete($LinkPath, $false)
    if (Test-Path -LiteralPath $LinkPath) { throw "Junction still present: $LinkPath" }
    return 'removed'
}

#endregion --------------------------------------------------------------- links

#region ------------------------------------------------------------------- size

function Get-GSFolderSize {
    <#
    .SYNOPSIS
        Sum file sizes under a path. Does not follow junctions, so a shelf never
        counts the same bytes twice.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $bytes = [long]0
    $count = 0
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Path)

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($dir)) {
                try {
                    $bytes += (New-Object System.IO.FileInfo $f).Length
                    $count++
                } catch { }
            }
        } catch { }
        try {
            foreach ($d in [System.IO.Directory]::EnumerateDirectories($dir)) {
                try {
                    $attr = [System.IO.File]::GetAttributes($d)
                    if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { $stack.Push($d) }
                } catch { }
            }
        } catch { }
    }

    return [pscustomobject]@{
        Bytes = $bytes
        GB    = [math]::Round($bytes / 1GB, 2)
        Files = $count
    }
}

#endregion ---------------------------------------------------------------- size

#region ---------------------------------------------------------- game detection

$script:GSEngineMarkers = @(
    @{ Name = 'Unity'; Files = @('UnityPlayer.dll'); Dirs = @() ; DirSuffix = @('_Data') }
    @{ Name = 'Unreal'; Files = @(); Dirs = @('Engine') ; DirSuffix = @() }
    @{ Name = 'GameMaker'; Files = @('data.win'); Dirs = @() ; DirSuffix = @() }
    @{ Name = 'Godot'; Files = @('*.pck'); Dirs = @() ; DirSuffix = @() }
    @{ Name = 'KiriKiri'; Files = @('*.xp3'); Dirs = @() ; DirSuffix = @() }
    @{ Name = "Ren'Py"; Files = @('*.rpa'); Dirs = @('renpy') ; DirSuffix = @() }
    @{ Name = 'RPG Maker'; Files = @('RGSS*.dll', 'Game.ini'); Dirs = @() ; DirSuffix = @() }
    @{ Name = 'LiveMaker'; Files = @('*.lsb', 'LiveMaker.ttf'); Dirs = @() ; DirSuffix = @() }
    @{ Name = 'BepInEx'; Files = @('doorstop_config.ini'); Dirs = @('BepInEx') ; DirSuffix = @() }
    @{ Name = 'NW.js'; Files = @('nw.exe', 'package.nw'); Dirs = @() ; DirSuffix = @() }
    @{ Name = 'Steam DRM stub'; Files = @('steam_api.dll', 'steam_api64.dll'); Dirs = @() ; DirSuffix = @() }
)

$script:GSMediaExtensions = @(
    '.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.ts', '.rmvb',
    '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.heic', '.tif', '.tiff'
)

# Folder names that are infrastructure, never content.
$script:GSExcludedNames = @(
    '$RECYCLE.BIN', '$Recycle.Bin', 'System Volume Information', 'Windows', 'Recovery',
    'PerfLogs', 'Program Files', 'Program Files (x86)', 'ProgramData', 'Documents and Settings',
    'AppData', 'node_modules', '.git', '.svn', '.cache', 'Temp', 'tmp', 'found.000',
    'DCIM', 'Downloads', 'Download', 'Desktop', 'Documents', 'Music', 'Pictures', 'Videos',
    'Movies', 'Recordings', 'Ringtones', 'Alarms', 'Notifications', 'Podcasts', 'Audiobooks',
    'Sounds', 'Android', 'hiberfil.sys', 'pagefile.sys', 'swapfile.sys'
)

# Game launcher libraries: managed by the launcher itself, never worth re-shelving.
$script:GSLauncherNames = @(
    'steamapps', 'SteamLibrary', 'Steam', 'WeGameApps', 'XboxGames', 'TapTap',
    'Epic Games', 'GOG Games', 'Battle.net', 'Ubisoft', 'Riot Games', 'EA Games',
    'Origin', 'EA Desktop', 'common_apps', 'rail_apps', 'downloading'
)

function Get-GSGameSignal {
    <#
    .SYNOPSIS
        Heuristically decide whether a folder looks like an installed game.
    .DESCRIPTION
        Looks at the folder itself plus one level below for executables and known
        engine markers, and measures how much of the payload is plain media.
        Returns a score plus the reasons behind it, so a scan result can be
        reviewed instead of trusted blindly.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $reasons = New-Object System.Collections.Generic.List[string]
    $score = 0

    $level0Files = @()
    $level0Dirs = @()
    $level1Files = @()
    try { $level0Files = @([System.IO.Directory]::EnumerateFiles($Path)) } catch { }
    try { $level0Dirs = @([System.IO.Directory]::EnumerateDirectories($Path)) } catch { }
    foreach ($d in $level0Dirs) {
        try { $level1Files += @([System.IO.Directory]::EnumerateFiles($d)) } catch { }
    }

    $names0 = New-Object System.Collections.Generic.List[string]
    foreach ($f in $level0Files) { $names0.Add([System.IO.Path]::GetFileName($f)) }
    $dirNames = New-Object System.Collections.Generic.List[string]
    foreach ($d in $level0Dirs) { $dirNames.Add([System.IO.Path]::GetFileName($d)) }
    $allFiles = $level0Files + $level1Files

    $exeCount = 0
    $mediaCount = 0
    $total = 0
    foreach ($f in $allFiles) {
        $total++
        $ext = [System.IO.Path]::GetExtension($f).ToLowerInvariant()
        if ($ext -eq '.exe') { $exeCount++ }
        if ($script:GSMediaExtensions -contains $ext) { $mediaCount++ }
    }

    if ($exeCount -gt 0) {
        $score += 2
        $reasons.Add("$exeCount executable(s)")
    }

    foreach ($m in $script:GSEngineMarkers) {
        $hit = $false
        foreach ($pat in $m.Files) {
            foreach ($n in $names0) {
                if ($n -like $pat) { $hit = $true; break }
            }
            if ($hit) { break }
        }
        if (-not $hit) {
            foreach ($d in $m.Dirs) {
                if ($dirNames -contains $d) { $hit = $true; break }
            }
        }
        if (-not $hit -and $m.DirSuffix.Count -gt 0) {
            foreach ($dn in $dirNames) {
                foreach ($suffix in $m.DirSuffix) {
                    if ($dn.EndsWith($suffix)) { $hit = $true; break }
                }
                if ($hit) { break }
            }
        }
        if ($hit) {
            $score += 3
            $reasons.Add("$($m.Name) engine marker")
        }
    }

    $mediaRatio = 0.0
    if ($total -gt 0) { $mediaRatio = [math]::Round($mediaCount / $total, 3) }
    if ($exeCount -eq 0 -and $total -gt 5 -and $mediaRatio -ge 0.9) {
        $score -= 4
        $reasons.Add("mostly media ($([int]($mediaRatio * 100))%)")
    }

    return [pscustomobject]@{
        Score      = $score
        Reasons    = ($reasons -join ', ')
        ExeCount   = $exeCount
        MediaRatio = $mediaRatio
        FileCount  = $total
    }
}

function Invoke-GSScan {
    <#
    .SYNOPSIS
        Walk one or more roots and emit a draft manifest of candidate folders.
    .DESCRIPTION
        Never modifies anything. The draft is meant to be reviewed and edited
        before New-GSShelf is run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string[]]$Root,
        [ValidateRange(1, 4)][int]$Depth = 2,
        [double]$MinSizeGB = 0.05,
        [switch]$SkipSize,
        [string[]]$Exclude = @()
    )

    $results = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Exclude) { $Exclude = @() }

    foreach ($r in $Root) {
        if (-not (Test-Path -LiteralPath $r)) {
            Write-Warning "Root not found, skipping: $r"
            continue
        }
        Write-Verbose "Scanning $r (depth $Depth)"

        $queue = New-Object System.Collections.Generic.Queue[object]
        $queue.Enqueue([pscustomobject]@{ Path = (Get-Item -LiteralPath $r -Force).FullName; Level = 0 })

        while ($queue.Count -gt 0) {
            $node = $queue.Dequeue()
            if ($node.Level -ge $Depth) { continue }

            $children = @()
            try { $children = @([System.IO.Directory]::EnumerateDirectories($node.Path)) } catch { continue }

            foreach ($child in $children) {
                $leaf = [System.IO.Path]::GetFileName($child)
                if ($script:GSExcludedNames -contains $leaf) { continue }
                if ($Exclude.Count -gt 0) {
                    $skip = $false
                    foreach ($pat in $Exclude) { if ($leaf -like $pat) { $skip = $true; break } }
                    if ($skip) { continue }
                }
                if (Test-GSLink -Path $child) { continue }

                $isLauncher = $script:GSLauncherNames -contains $leaf
                $sig = Get-GSGameSignal -Path $child

                if ($isLauncher) {
                    $results.Add([pscustomobject]@{
                            Name       = $leaf
                            Path       = $child
                            Score      = $sig.Score
                            Kind       = 'LauncherLibrary'
                            SizeGB     = $null
                            Reasons    = $sig.Reasons
                            SourceRoot = $r
                        })
                } elseif ($sig.Score -ge 2) {
                    $gb = $null
                    if (-not $SkipSize) { $gb = (Get-GSFolderSize -Path $child).GB }
                    if ($null -eq $gb -or $gb -ge $MinSizeGB) {
                        $results.Add([pscustomobject]@{
                                Name       = $leaf
                                Path       = $child
                                Score      = $sig.Score
                                Kind       = 'Game'
                                SizeGB     = $gb
                                Reasons    = $sig.Reasons
                                SourceRoot = $r
                            })
                    }
                }

                $queue.Enqueue([pscustomobject]@{ Path = $child; Level = $node.Level + 1 })
            }
        }
    }

    return , $results
}

#endregion ------------------------------------------------------ game detection

#region ------------------------------------------------------------------ build

function New-GSShelf {
    <#
    .SYNOPSIS
        Materialise a shelf from a manifest.
    .DESCRIPTION
        By default an existing shelf is merged with, not replaced: entries that are
        not mentioned in the new manifest keep their place. Use -Replace to make the
        manifest the single source of truth instead.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Manifest,
        [Parameter(Mandatory, Position = 1)][string]$Shelf,
        [ValidateSet('Link', 'Move', 'Copy')][string]$Mode = 'Link',
        [switch]$Force,
        [switch]$Replace
    )

    $items = Import-GSManifest -Path $Manifest

    if (-not (Test-Path -LiteralPath $Shelf)) {
        if ($PSCmdlet.ShouldProcess($Shelf, 'Create shelf root')) {
            New-Item -ItemType Directory -Path $Shelf -Force | Out-Null
        }
    }
    $Shelf = (Get-Item -LiteralPath $Shelf -Force).FullName

    $created = 0; $skipped = 0; $failed = 0
    $placed = New-Object System.Collections.Generic.List[object]

    foreach ($item in $items) {
        $categoryDir = Join-Path $Shelf $item.Category
        $link = Join-Path $categoryDir $item.Name

        if (-not (Test-Path -LiteralPath $item.Target)) {
            Write-Warning "Target missing, skipped: $($item.Target)"
            $failed++
            continue
        }
        if (Test-Path -LiteralPath $link) {
            if (Test-GSLink -Path $link) {
                $existing = Get-GSLinkTarget -Path $link
                $sameTarget = ($existing -eq $item.Target)
                if (-not $sameTarget) {
                    Write-Warning "Link exists but points elsewhere, skipped: $link -> $existing"
                    $failed++
                    continue
                }
            }
            if (-not $Force) {
                Write-Verbose "Already present: $link"
                $skipped++
                $placed.Add($item)
                continue
            }
            if ($PSCmdlet.ShouldProcess($link, 'Remove existing entry')) {
                Remove-GSLink -LinkPath $link | Out-Null
            }
        }

        if (-not $PSCmdlet.ShouldProcess($link, "$Mode $($item.Target)")) { continue }

        try {
            if (-not (Test-Path -LiteralPath $categoryDir)) {
                New-Item -ItemType Directory -Path $categoryDir -Force | Out-Null
            }
            switch ($Mode) {
                'Link' { New-GSLink -LinkPath $link -TargetPath $item.Target | Out-Null }
                'Move' { Move-Item -LiteralPath $item.Target -Destination $link -Force }
                'Copy' { Copy-Item -LiteralPath $item.Target -Destination $link -Recurse -Force }
            }
            $created++
            $placed.Add($item)
        } catch {
            Write-Warning "Failed for '$($item.Name)': $($_.Exception.Message)"
            $failed++
        }
    }

    # Merge with what the shelf already knew about, so building a second manifest
    # into the same shelf does not silently drop the first manifest's entries.
    $shelfManifest = Join-Path $Shelf $script:GSManifestName
    $kept = 0
    if (-not $Replace -and (Test-Path -LiteralPath $shelfManifest)) {
        $seen = @{}
        foreach ($i in $placed) { $seen[$i.Category + [char]1 + $i.Name] = $true }
        try {
            foreach ($old in (Import-GSManifest -Path $shelfManifest)) {
                $key = $old.Category + [char]1 + $old.Name
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                $placed.Add($old)
                $kept++
            }
        } catch {
            Write-Verbose "Existing shelf manifest was unreadable, starting fresh: $($_.Exception.Message)"
        }
    }

    Export-GSManifest -Path $shelfManifest -Items $placed -Meta @{
        mode    = $Mode
        shelf   = $Shelf
        created = (Get-Date -Format 's')
        source  = $Manifest
    }

    return [pscustomobject]@{
        Shelf    = $Shelf
        Mode     = $Mode
        Created  = $created
        Skipped  = $skipped
        Failed   = $failed
        Kept     = $kept
        OnShelf  = $placed.Count
        Total    = $items.Count
    }
}

#endregion --------------------------------------------------------------- build

#region ------------------------------------------------------- read/verify/index

function Get-GSShelf {
    <#
    .SYNOPSIS
        Read a shelf back from its _shelf.txt, with live status per entry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Shelf,
        [switch]$SkipSize
    )

    $manifest = Join-Path $Shelf $script:GSManifestName
    if (-not (Test-Path -LiteralPath $manifest)) {
        throw "Not a gameshelf (no $script:GSManifestName): $Shelf"
    }

    $meta = Get-GSManifestMeta -Path $manifest
    $items = Import-GSManifest -Path $manifest
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($i in $items) {
        $link = Join-Path (Join-Path $Shelf $i.Category) $i.Name
        $status = 'Missing'
        if (Test-Path -LiteralPath $link) {
            if (Test-GSLink -Path $link) {
                $status = 'Link'
                if (-not (Test-Path -LiteralPath $i.Target)) { $status = 'Broken' }
            } else {
                $status = 'Folder'
            }
        }

        $gb = $null
        if (-not $SkipSize) {
            $probe = $link
            if ($status -eq 'Broken' -or $status -eq 'Missing') { $probe = $i.Target }
            if (Test-Path -LiteralPath $probe) { $gb = (Get-GSFolderSize -Path $probe).GB }
        }

        $rows.Add([pscustomobject]@{
                Category = $i.Category
                Name     = $i.Name
                Target   = $i.Target
                Note     = $i.Note
                Status   = $status
                SizeGB   = $gb
            })
    }

    return [pscustomobject]@{
        Shelf = $Shelf
        Mode  = (Get-GSProp $meta 'mode')
        # A plain array, not a List: PowerShell's array subexpression operator
        # throws "parameter type mismatch" on List values in this position, so
        # @($shelf.Items) would fail for callers even though .Count and foreach work.
        Items = $rows.ToArray()
    }
}

function Test-GSShelf {
    <#
    .SYNOPSIS
        Verify every shelf entry resolves and is readable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Shelf)

    $shelfData = Get-GSShelf -Shelf $Shelf -SkipSize
    $report = New-Object System.Collections.Generic.List[object]

    foreach ($item in $shelfData.Items) {
        $link = Join-Path (Join-Path $Shelf $item.Category) $item.Name
        $readable = $false
        $detail = ''
        try {
            $probe = Get-ChildItem -LiteralPath $link -Force -ErrorAction Stop | Select-Object -First 1
            $readable = $true
            if ($null -eq $probe) { $detail = 'readable but empty' }
        } catch {
            $detail = $_.Exception.Message
        }

        $report.Add([pscustomobject]@{
                Category = $item.Category
                Name     = $item.Name
                Status   = $item.Status
                Readable = $readable
                Target   = $item.Target
                Detail   = $detail
            })
    }

    $bad = @($report | Where-Object { $_.Status -ne 'Link' -or -not $_.Readable })
    return [pscustomobject]@{
        Shelf  = $Shelf
        Total  = $report.Count
        Bad    = $bad.Count
        # Plain array for the same reason as Get-GSShelf's Items.
        Report = $report.ToArray()
    }
}

function Select-GSShelfEntry {
    <#
    .SYNOPSIS
        Pick shelf entries out of a shelf listing by name or by target folder.
    .DESCRIPTION
        -Target exists so that a caller who only has the install folder can address
        an entry. That is the normal case for a launcher: Playnite knows
        'D:\SteamLibrary\steamapps\common\ELDEN RING', while the label on the shelf
        ('艾尔登法环') is GameShelf's own and may have been renamed to anything.

        Emits matching entries; wrap the call in @() to count them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [string]$Name,
        [string]$Target
    )

    if (-not $Name -and -not $Target) { return }

    if ($Name) {
        foreach ($i in @($Items | Where-Object { $_ })) {
            if ($i.Name -eq $Name) { $i }
        }
        return
    }

    $want = $Target.TrimEnd('\')
    foreach ($i in @($Items | Where-Object { $_ })) {
        if (-not $i.Target) { continue }
        if (([string]$i.Target).TrimEnd('\') -ieq $want) { $i }
    }
}

function Export-GSIndex {
    <#
    .SYNOPSIS
        Regenerate the Markdown catalogue and CSV index for a shelf.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Shelf,
        [string]$MarkdownName = 'CATALOG.md',
        [string]$CsvName = 'index.csv'
    )

    $data = Get-GSShelf -Shelf $Shelf
    $items = $data.Items

    $sum = ($items | Measure-Object -Property SizeGB -Sum).Sum
    if ($null -eq $sum) { $sum = 0 }
    $totalGB = [math]::Round([double]$sum, 2)

    $md = New-Object System.Collections.Generic.List[string]
    $md.Add('# Shelf catalogue')
    $md.Add('')
    $md.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')  |  Items: $($items.Count)  |  Total: $totalGB GB")
    $md.Add("Mode: $($data.Mode)")
    $md.Add('')
    $md.Add('Each entry below is an entry on the shelf, not a copy. The `Target` column is')
    $md.Add('where the data really lives - do not move or rename it.')
    $md.Add('')

    foreach ($group in ($items | Group-Object Category | Sort-Object Name)) {
        $gsum = ($group.Group | Measure-Object -Property SizeGB -Sum).Sum
        if ($null -eq $gsum) { $gsum = 0 }
        $groupGB = [math]::Round([double]$gsum, 2)
        $md.Add("## $($group.Name)  ($($group.Count) items, $groupGB GB)")
        $md.Add('')
        $md.Add('| Name | Size | Target | Status | Note |')
        $md.Add('|---|---|---|---|---|')
        foreach ($i in ($group.Group | Sort-Object Name)) {
            $size = '?'
            if ($null -ne $i.SizeGB) { $size = "$($i.SizeGB) GB" }
            $md.Add("| $($i.Name) | $size | ``$($i.Target)`` | $($i.Status) | $($i.Note) |")
        }
        $md.Add('')
    }

    $mdPath = Join-Path $Shelf $MarkdownName
    [System.IO.File]::WriteAllLines($mdPath, $md, (New-Object System.Text.UTF8Encoding($true)))

    $csv = New-Object System.Collections.Generic.List[string]
    $csv.Add('category,name,target,size_gb,status,note')
    foreach ($i in ($items | Sort-Object Category, Name)) {
        $size = ''
        if ($null -ne $i.SizeGB) { $size = $i.SizeGB }
        $note = ($i.Note -replace '"', '""')
        $csv.Add(('"{0}","{1}","{2}","{3}","{4}","{5}"' -f $i.Category, $i.Name, $i.Target, $size, $i.Status, $note))
    }
    $csvPath = Join-Path $Shelf $CsvName
    [System.IO.File]::WriteAllLines($csvPath, $csv, (New-Object System.Text.UTF8Encoding($true)))

    return [pscustomobject]@{
        Markdown = $mdPath
        Csv      = $csvPath
        Items    = $items.Count
        TotalGB  = $totalGB
    }
}

function Remove-GSShelf {
    <#
    .SYNOPSIS
        Remove shelf entries. Only ever removes junctions.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Shelf,
        [string]$Name,
        [string]$Category,
        [switch]$All
    )

    $manifest = Join-Path $Shelf $script:GSManifestName
    if (-not (Test-Path -LiteralPath $manifest)) {
        throw "Not a gameshelf (no $script:GSManifestName): $Shelf"
    }
    $meta = Get-GSManifestMeta -Path $manifest
    $mode = Get-GSProp $meta 'mode'
    if ($mode -ne 'Link') {
        throw ("This shelf was built in '$mode' mode, so its entries are real folders, not junctions. " +
            'GameShelf will not delete them. Remove or relocate them yourself.')
    }

    $items = Import-GSManifest -Path $manifest
    $targets = @()
    if ($All) {
        $targets = $items
    } else {
        $targets = @($items | Where-Object {
                ($Name -and $_.Name -eq $Name) -or ($Category -and $_.Category -eq $Category)
            })
        if ($targets.Count -eq 0) { throw 'Nothing matched. Pass -Name, -Category or -All.' }
    }

    $removed = 0; $failed = 0; $absent = 0
    $takenOff = @{}
    foreach ($i in $targets) {
        $link = Join-Path (Join-Path $Shelf $i.Category) $i.Name
        if (-not $PSCmdlet.ShouldProcess($link, 'Remove junction')) { continue }
        try {
            $outcome = Remove-GSLink -LinkPath $link
            if ($outcome -eq 'removed') {
                $removed++
                $takenOff[$i.Category + [char]1 + $i.Name] = $true
            } else {
                # Already gone. Leave the manifest entry in place so verify still
                # reports it, rather than quietly forgetting the shelf is stale.
                $absent++
            }
        } catch {
            Write-Warning $_.Exception.Message
            $failed++
        }
    }

    if (-not $All) {
        # Keep the shelf manifest honest: drop exactly what was taken off.
        $meta = Get-GSManifestMeta -Path $manifest
        if ((Get-GSProp $meta 'mode') -eq 'Link') {
            $survivors = New-Object System.Collections.Generic.List[object]
            foreach ($i in $items) {
                if (-not $takenOff.ContainsKey($i.Category + [char]1 + $i.Name)) { $survivors.Add($i) }
            }
            Export-GSManifest -Path $manifest -Items $survivors -Meta $meta
        }
    }

    if ($All) {
        $empty = @(Get-ChildItem -LiteralPath $Shelf -Directory | Where-Object {
                @(Get-ChildItem -LiteralPath $_.FullName -Force).Count -eq 0
            })
        foreach ($e in $empty) {
            if ($PSCmdlet.ShouldProcess($e.FullName, 'Remove now-empty category folder')) {
                Remove-Item -LiteralPath $e.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        if ($PSCmdlet.ShouldProcess($manifest, 'Remove shelf manifest')) {
            Remove-Item -LiteralPath $manifest -Force -ErrorAction SilentlyContinue
        }
    }

    return [pscustomobject]@{
        Removed = $removed
        Failed  = $failed
        Absent  = $absent
        Matched = $targets.Count
    }
}

#endregion ---------------------------------------------------- read/verify/index

#region ------------------------------------------------------------- environment

function Test-GSEnvironment {
    <#
    .SYNOPSIS
        Report whether this machine can build a junction shelf.
    #>
    [CmdletBinding()]
    param()

    $checks = New-Object System.Collections.Generic.List[object]

    $psOk = $PSVersionTable.PSVersion.Major -ge 5
    $checks.Add([pscustomobject]@{
            Check = 'PowerShell 5.1+'; Ok = $psOk; Detail = "$($PSVersionTable.PSVersion)"
        })

    $isWindows = $true
    if ($PSVersionTable.ContainsKey('Platform')) {
        $isWindows = ($PSVersionTable.Platform -eq 'Win32NT')
    }
    $checks.Add([pscustomobject]@{
            Check = 'Windows'; Ok = $isWindows; Detail = 'NTFS junctions are Windows-only'
        })

    $elevated = Test-GSIsElevated
    $elevDetail = 'not elevated (fine - junctions need no admin rights)'
    if ($elevated) { $elevDetail = 'running elevated (not required, but harmless)' }
    $checks.Add([pscustomobject]@{
            Check  = 'Elevation'
            Ok     = $true
            Detail = $elevDetail
        })

    $probeDir = [System.IO.Path]::GetTempPath()
    $target = Join-Path $probeDir ('gs_t_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $link = Join-Path $probeDir ('gs_l_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $ok = $false
    $detail = ''
    try {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        New-GSLink -LinkPath $link -TargetPath $target | Out-Null
        $resolved = Test-GSLink -Path $link
        $visible = Test-Path -LiteralPath $link
        $ok = ($resolved -and $visible)
        $detail = 'created and resolved'
    } catch {
        $detail = $_.Exception.Message
    } finally {
        if (Test-Path -LiteralPath $link) {
            try { Remove-GSLink -LinkPath $link | Out-Null } catch { }
        }
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $checks.Add([pscustomobject]@{ Check = 'Junction creation'; Ok = $ok; Detail = $detail })

    return , $checks
}

function Test-GSIsElevated {
    [CmdletBinding()]
    param()
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

#endregion ---------------------------------------------------------- environment

#region ------------------------------------------------------------- launch map

$script:GSLaunchMapName = '_launch.txt'

function Import-GSLaunchMap {
    <#
    .SYNOPSIS
        Read a shelf's launch map (_launch.txt): entry name -> exe path relative to
        that entry's folder. 'FOLDER' means the entry has no executable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Shelf)

    $map = @{}
    $path = Join-Path $Shelf $script:GSLaunchMapName
    if (-not (Test-Path -LiteralPath $path)) { return $map }
    foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('|')
        if ($i -lt 1) { continue }
        $map[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
    }
    return $map
}

function Get-GSLaunchExe {
    <#
    .SYNOPSIS
        The executable a shelf entry launches, or $null when unmapped or set to
        FOLDER. Used by save discovery, which reads the executable's metadata.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Shelf,
        [Parameter(Mandatory)][string]$EntryName,
        [Parameter(Mandatory)][string]$Target
    )
    $map = Import-GSLaunchMap -Shelf $Shelf
    if (-not $map.ContainsKey($EntryName)) { return $null }
    $rel = $map[$EntryName]
    if ($rel -eq 'FOLDER') { return $null }
    $p = Join-Path $Target $rel
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

#endregion ---------------------------------------------------------- launch map

Export-ModuleMember -Function @(
    'Import-GSManifest', 'Export-GSManifest', 'Get-GSManifestMeta',
    'Test-GSLink', 'Get-GSLinkTarget', 'New-GSLink', 'Remove-GSLink',
    'Get-GSFolderSize', 'Get-GSGameSignal', 'Invoke-GSScan',
    'New-GSShelf', 'Get-GSShelf', 'Test-GSShelf', 'Export-GSIndex',
    'Remove-GSShelf', 'Test-GSEnvironment', 'Test-GSIsElevated',
    'Get-GSSaveMapPath', 'Import-GSSaveMap', 'Export-GSSaveMap', 'Add-GSSaveMapEntry',
    'Write-GSLineFile',
    'Resolve-GSSavePath', 'Get-GSSaveTarget', 'Get-GSFileStat',
    'Find-GSSaveCandidate', 'Get-GSSaveStore',
    'Backup-GSSave', 'Get-GSSaveBackup', 'Restore-GSSave',
    'Import-GSLaunchMap', 'Get-GSLaunchExe', 'Select-GSShelfEntry',
    # save-map path tools, shared by the Ludusavi bridge
    'Get-GSRelativeTo', 'ConvertTo-GSSaveMapPath', 'Test-GSPathIsSpecific',
    'Get-GSPathClusterRoot', 'Group-GSPathCluster',
    # ludusavi bridge
    'Get-GSLudusaviMapPath', 'Import-GSLudusaviMap', 'Export-GSLudusaviMap',
    'Add-GSLudusaviMapEntry',
    'Get-GSLudusaviExe', 'Get-GSLudusaviAppDir', 'Test-GSLudusavi',
    'ConvertTo-GSProcessArgument', 'Invoke-GSLudusavi',
    'ConvertFrom-GSLudusaviFind', 'ConvertFrom-GSLudusaviPreview', 'Get-GSLudusaviUnknown',
    'Find-GSLudusaviTitle', 'Get-GSLudusaviPreview', 'ConvertTo-GSLudusaviProposal',
    'Get-GSLudusaviProposal',
    # playnite bridge
    'Get-GSPlayniteExportPath', 'Import-GSPlayniteLibrary',
    'Get-GSPlayniteExtensionRoot', 'Import-GSPlayniteExtensionManifest',
    'Install-GSPlayniteExtension', 'ConvertTo-GSManifestField',
    'New-GSPlayniteManifest', 'Get-GSPlayniteMatch'
)
