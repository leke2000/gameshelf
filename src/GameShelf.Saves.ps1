<#
    GameShelf save-data support.

    Dot-sourced by GameShelf.psm1, so these functions live in the module scope and
    run under the module's StrictMode.

    A game's saves can be inside the game folder, under %APPDATA%, under
    %LOCALAPPDATA%\..\LocalLow, in Documents\My Games, in Saved Games, or in a
    Steam emulator's own store. Guessing is unreliable, so the source of truth is
    <shelf>\_saves.txt:

        # <shelf entry name>|<path>[;<path>...]
        Subnautica|GAME\SNAppData
        Cyberpunk 2077|%SAVEDGAMES%\CD Projekt Red\Cyberpunk 2077

    Find-GSSaveCandidate can suggest locations for an unmapped game, but treat its
    output as a hint to review, not an answer.
#>

$script:GSSaveMapName = '_saves.txt'
$script:GSSaveStoreName = '_saves'
$script:GSSaveManifestName = '_backup.txt'

<#
  The tokens a save-map path may contain, most specific first. Order is load
  bearing in both directions: Resolve-GSSavePath replaces the first match it
  finds, and ConvertTo-GSSaveMapPath walks this list to turn an absolute path
  back into a token form. '%LOCALLOW%' must therefore come before
  '%USERPROFILE%', which is also an ancestor of it, and '%DOCUMENTS%' before
  '%USERPROFILE%' so a redirected (OneDrive) Documents still wins.
#>
$script:GSSaveTokens = @(
    @('%DOCUMENTS%', [Environment]::GetFolderPath('MyDocuments')),
    @('%SAVEDGAMES%', (Join-Path $env:USERPROFILE 'Saved Games')),
    @('%LOCALLOW%', (Join-Path $env:USERPROFILE 'AppData\LocalLow')),
    @('%APPDATA%', $env:APPDATA),
    @('%LOCALAPPDATA%', $env:LOCALAPPDATA),
    @('%USERPROFILE%', $env:USERPROFILE)
)

# Folder names that usually hold saves when they sit inside the game itself.
$script:GSInGameSaveDirs = @(
    'savedata', 'savedatas', 'save', 'saves', 'savegame', 'savegames', 'savedgames',
    'saved games', 'userdata', 'user', 'profile', 'profiles', '存档', '存档数据',
    'SNAppData', 'RemoteStorage'
)

function Get-GSSaveMapPath {
    <#
    .SYNOPSIS
        Path of the save map for a shelf.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Shelf)
    return (Join-Path $Shelf $script:GSSaveMapName)
}

function Import-GSSaveMap {
    <#
    .SYNOPSIS
        Read a shelf's save map.
    .DESCRIPTION
        Returns a hashtable of entry name -> array of raw (unexpanded) paths.
        A missing map is not an error; it just yields an empty table.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Shelf)

    $map = @{}
    $path = Get-GSSaveMapPath -Shelf $Shelf
    if (-not (Test-Path -LiteralPath $path)) { return $map }

    foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('|')
        if ($i -lt 1) { continue }
        $name = $t.Substring(0, $i).Trim()
        $rest = $t.Substring($i + 1).Trim()
        if ($name -eq '' -or $rest -eq '') { continue }
        $map[$name] = @($rest -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    return $map
}

function Export-GSSaveMap {
    <#
    .SYNOPSIS
        Write a shelf's save map, with the format header.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Shelf,
        [Parameter(Mandatory)][hashtable]$Map
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# GameShelf save map.')
    $lines.Add('# <shelf entry name>|<path>[;<path>...]')
    $lines.Add('# %APPDATA% %LOCALAPPDATA% %USERPROFILE% %DOCUMENTS% %SAVEDGAMES% %LOCALLOW% expand.')
    $lines.Add('# A leading GAME\ means "relative to that game''s own folder".')
    foreach ($k in ($Map.Keys | Sort-Object)) {
        $paths = @($Map[$k])
        if ($paths.Count -eq 0) { continue }
        $lines.Add($k + '|' + ($paths -join ';'))
    }
    [System.IO.File]::WriteAllLines((Get-GSSaveMapPath -Shelf $Shelf), $lines,
        (New-Object System.Text.UTF8Encoding($true)))
}

function Write-GSLineFile {
    <#
    .SYNOPSIS
        Write lines back in the style the file already uses.
    .DESCRIPTION
        Line endings and the byte order mark belong to the file someone else
        maintains, not to the tool appending to it. A shelf map curated in an editor
        that writes LF, rewritten as CRLF, turns one appended entry into a
        sixty-line diff; adding a BOM to a file that had none does the same to its
        first line. Both were observed on a real shelf.

        [AllowEmptyString] is load-bearing: a hand-maintained map can contain a
        blank line, and without it Mandatory rejects the whole array with "cannot
        bind ... because it is an empty string".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines
    )

    $nl = "`r`n"
    $encoding = New-Object System.Text.UTF8Encoding($true)

    if (Test-Path -LiteralPath $Path) {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        if (-not $hasBom) { $encoding = New-Object System.Text.UTF8Encoding($false) }

        $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ($text -notmatch "`r`n" -and $text -match "`n") { $nl = "`n" }
    }

    $body = (@($Lines) -join $nl) + $nl
    [System.IO.File]::WriteAllText($Path, $body, $encoding)
}

function Add-GSSaveMapEntry {
    <#
    .SYNOPSIS
        Append entries to a shelf's save map without rewriting what is there.
    .DESCRIPTION
        The save map is a file the user curates by hand - the README says so - so
        the commands that learn new locations must not reformat it. Entries
        already present are left alone: the curated path wins over anything a tool
        proposes, and that only holds if adopting never touches an existing line.
        Line endings and the BOM are the file's own; see Write-GSLineFile.

        Returns the number of entries that were (or, under -WhatIf, would be)
        appended.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Shelf,
        [Parameter(Mandatory)][hashtable]$Entry
    )

    $existing = Import-GSSaveMap -Shelf $Shelf
    $path = Get-GSSaveMapPath -Shelf $Shelf

    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $path) {
        foreach ($l in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) { $lines.Add($l) }
    } else {
        $lines.Add('# GameShelf save map.')
        $lines.Add('# <shelf entry name>|<path>[;<path>...]')
        $lines.Add('# %APPDATA% %LOCALAPPDATA% %USERPROFILE% %DOCUMENTS% %SAVEDGAMES% %LOCALLOW% expand.')
        $lines.Add('# A leading GAME\ means "relative to that game''s own folder".')
    }

    $added = 0
    foreach ($k in ($Entry.Keys | Sort-Object)) {
        if ($existing.ContainsKey($k)) { continue }
        $paths = @($Entry[$k] | Where-Object { $_ })
        if ($paths.Count -eq 0) { continue }
        $lines.Add($k + '|' + ($paths -join ';'))
        $added++
    }

    if ($added -gt 0) {
        if ($PSCmdlet.ShouldProcess($path, "append $added save-map entr(ies)")) {
            Write-GSLineFile -Path $path -Lines $lines.ToArray()
        }
    }
    return $added
}

function Resolve-GSSavePath {
    <#
    .SYNOPSIS
        Expand one raw map path into an absolute filesystem path.
    .DESCRIPTION
        Accepts an absolute path, one containing %APPDATA%-style tokens, a GAME\
        prefix, or a bare relative path - the last two are taken as relative to the
        game's own folder, which is what they read like.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][string]$Target
    )

    $p = $Raw.Trim()

    if ($p -match '^GAME\\') { return (Join-Path $Target $p.Substring(5)) }

    foreach ($pair in $script:GSSaveTokens) {
        # Escape the pattern but NOT the replacement. [regex]::Escape on a Windows
        # path doubles its backslashes, and a doubled backslash is inserted
        # literally, producing C:\\Users\\... Only '$' is special in a replacement.
        $repl = ([string]$pair[1]) -replace '\$', '$$'
        $p = $p -replace [regex]::Escape($pair[0]), $repl
    }

    if (-not [System.IO.Path]::IsPathRooted($p)) { return (Join-Path $Target $p) }
    return $p
}

function Get-GSRelativeTo {
    <#
    .SYNOPSIS
        The path of Child relative to Ancestor, '' when they are equal, or $null
        when Child is not inside Ancestor at all.
    .DESCRIPTION
        Comparison is case-insensitive and boundary-aware: 'C:\ab' is not
        considered to be inside 'C:\a'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Child,
        [Parameter(Mandatory)][string]$Ancestor
    )

    $c = $Child.TrimEnd('\')
    $a = $Ancestor.TrimEnd('\')
    if ($a -eq '') { return $null }
    if ($c -ieq $a) { return '' }
    if ($c.StartsWith($a + '\', [System.StringComparison]::InvariantCultureIgnoreCase)) {
        return $c.Substring($a.Length + 1)
    }
    return $null
}

function ConvertTo-GSSaveMapPath {
    <#
    .SYNOPSIS
        Turn an absolute save path into the token form a save map prefers.
    .DESCRIPTION
        The inverse of Resolve-GSSavePath, and it exists for the same reason: a
        map that reads '%APPDATA%\Team Cherry\Hollow Knight' keeps working when
        the user profile moves or the shelf is copied to another machine, while
        'C:\Users\bob\AppData\...' does not.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Absolute,
        [string]$Target
    )

    $abs = $Absolute.TrimEnd('\')

    if ($Target) {
        $rel = Get-GSRelativeTo -Child $abs -Ancestor $Target
        if ($null -ne $rel) {
            if ($rel -eq '') { return 'GAME\' }
            return ('GAME\' + $rel)
        }
    }

    foreach ($pair in $script:GSSaveTokens) {
        if (-not $pair[1]) { continue }
        $rel = Get-GSRelativeTo -Child $abs -Ancestor ([string]$pair[1])
        if ($null -ne $rel) {
            if ($rel -eq '') { return $pair[0] }
            return ($pair[0] + '\' + $rel)
        }
    }

    return $abs
}

function Test-GSPathIsSpecific {
    <#
    .SYNOPSIS
        Whether a folder is specific enough to be recorded as a save location.
    .DESCRIPTION
        This is the guard that keeps path clustering honest. Two saves that live
        in unrelated subfolders of %APPDATA% share that whole folder as their
        common prefix, and a map entry of bare '%APPDATA%' would back up the
        entire roaming profile. So a candidate must sit strictly below a token
        root, strictly below the game's own folder, or below a drive root - being
        equal to any of those is not enough.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [string]$Target
    )

    $p = $Path.TrimEnd('\')

    if ($Target) {
        $rel = Get-GSRelativeTo -Child $p -Ancestor $Target
        if ($null -ne $rel -and $rel -ne '') { return $true }
    }

    foreach ($pair in $script:GSSaveTokens) {
        if (-not $pair[1]) { continue }
        $rel = Get-GSRelativeTo -Child $p -Ancestor ([string]$pair[1])
        if ($null -ne $rel) { return ($rel -ne '') }
    }

    if ($p -match '^[A-Za-z]:\\?$') { return $false }
    if ($p -match '^[A-Za-z]:$') { return $false }
    return $true
}

function Get-GSPathClusterRoot {
    <#
    .SYNOPSIS
        The deepest folder on the common path of two entries.
    .DESCRIPTION
        When one entry is an ancestor of the other it is returned unchanged, so a
        folder key that already covers a file key survives. Otherwise the two are
        compared character by character and the result is cut back to the last
        separator, which is what makes sibling files collapse onto their folder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$A,
        [Parameter(Mandatory)][string]$B
    )

    $x = $A.TrimEnd('\')
    $y = $B.TrimEnd('\')

    if ($x -ieq $y) { return $x }
    if ($null -ne (Get-GSRelativeTo -Child $y -Ancestor $x)) { return $x }
    if ($null -ne (Get-GSRelativeTo -Child $x -Ancestor $y)) { return $y }

    $min = [Math]::Min($x.Length, $y.Length)
    $i = 0
    while ($i -lt $min) {
        if ([char]::ToLowerInvariant($x[$i]) -ne [char]::ToLowerInvariant($y[$i])) { break }
        $i++
    }
    $cut = $x.Substring(0, $i)
    $sep = $cut.LastIndexOf('\')
    if ($sep -lt 0) { return '' }
    $dir = $cut.Substring(0, $sep)
    if ($dir -match '^[A-Za-z]:$') { return ($dir + '\') }
    return $dir
}

function Group-GSPathCluster {
    <#
    .SYNOPSIS
        Collapse a flat list of paths into the smallest set of folders covering
        them all.
    .DESCRIPTION
        Ludusavi reports one entry per file, which is the wrong shape for a save
        map: a game with 900 save slots would become 900 lines. Entries are
        sorted first, so everything under one folder is adjacent, then merged
        greedily as long as the merged root stays specific (Test-GSPathIsSpecific)
        and still covers the group.

        Emits one object per cluster: Root, Keys (how many reported paths it
        covers) and Bytes (summed from the optional -Bytes table, keyed by the
        same paths, when the caller has sizes to hand).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Paths,
        [string]$Target,
        [hashtable]$Bytes
    )

    $keys = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($p in $Paths) {
        if (-not $p) { continue }
        $k = ($p.Trim() -replace '/', '\').TrimEnd('\')
        if ($k.Length -lt 2) { continue }
        $lk = $k.ToLowerInvariant()
        if ($seen.ContainsKey($lk)) { continue }
        $seen[$lk] = $true
        $keys.Add($k)
    }
    if ($keys.Count -eq 0) { return }

    # Byte totals arrive keyed by whatever casing the caller used; normalise here
    # so cluster accounting cannot silently miss.
    $sizes = @{}
    if ($Bytes) {
        foreach ($bk in $Bytes.Keys) {
            if ($null -eq $Bytes[$bk]) { continue }
            $sizes[([string]$bk).ToLowerInvariant()] = [long]$Bytes[$bk]
        }
    }

    $sorted = @($keys | Sort-Object)

    $root = $sorted[0]
    $count = 1
    $sum = [long]0
    if ($sizes.ContainsKey($sorted[0].ToLowerInvariant())) { $sum = [long]$sizes[$sorted[0].ToLowerInvariant()] }
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        $p = $sorted[$i]
        $candidate = Get-GSPathClusterRoot -A $root -B $p
        $merge = $false
        if ($candidate) {
            if ((Test-GSPathIsSpecific -Path $candidate -Target $Target) -and
                ($null -ne (Get-GSRelativeTo -Child $root -Ancestor $candidate)) -and
                ($null -ne (Get-GSRelativeTo -Child $p -Ancestor $candidate))) {
                $merge = $true
            }
        }
        if ($merge) {
            $root = $candidate
            $count++
            if ($sizes.ContainsKey($p.ToLowerInvariant())) { $sum += [long]$sizes[$p.ToLowerInvariant()] }
        } else {
            [pscustomobject]@{ Root = $root; Keys = $count; Bytes = $sum }
            $root = $p
            $count = 1
            $sum = [long]0
            if ($sizes.ContainsKey($p.ToLowerInvariant())) { $sum = [long]$sizes[$p.ToLowerInvariant()] }
        }
    }
    [pscustomobject]@{ Root = $root; Keys = $count; Bytes = $sum }
}

function Get-GSSaveTarget {
    <#
    .SYNOPSIS
        Resolve an entry's raw save paths, marking which currently exist.
    .DESCRIPTION
        Emits one object per path. Output is emitted item by item rather than as a
        List so callers can wrap it in @() and still enumerate it:
        returning a List makes it arrive as a single object, and Where-Object then
        member-enumerates it ($_.Path yields every path) instead of filtering.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string[]]$RawPaths
    )

    foreach ($raw in $RawPaths) {
        $abs = Resolve-GSSavePath -Raw $raw -Target $Target
        $exists = Test-Path -LiteralPath $abs
        $kind = 'Missing'
        if ($exists) {
            $kind = 'Folder'
            if (-not (Test-Path -LiteralPath $abs -PathType Container)) { $kind = 'File' }
        }
        [pscustomobject]@{ Raw = $raw; Path = $abs; Exists = $exists; Kind = $kind }
    }
}

function Get-GSFileStat {
    <#
    .SYNOPSIS
        File count and total bytes under a path; a plain file counts as one.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Files = 0; Bytes = [long]0 }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        $fi = New-Object System.IO.FileInfo $Path
        return [pscustomobject]@{ Files = 1; Bytes = [long]$fi.Length }
    }

    $n = 0
    $b = [long]0
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($dir)) {
                try {
                    $fi = New-Object System.IO.FileInfo $f
                    $b += $fi.Length
                    $n++
                } catch { }
            }
            foreach ($d in [System.IO.Directory]::EnumerateDirectories($dir)) { $stack.Push($d) }
        } catch { }
    }
    return [pscustomobject]@{ Files = $n; Bytes = $b }
}

function Find-GSSaveCandidate {
    <#
    .SYNOPSIS
        Suggest where a game keeps its saves.
    .DESCRIPTION
        Looks for save-named folders inside the game, then probes the usual
        per-user locations using the executable's company/product metadata and its
        own file name (Unreal names its user folder after the project, which is the
        executable). Emits one object per hit; treat the result as a hint to
        review, not an answer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EntryName,
        [Parameter(Mandatory)][string]$Target,
        [string]$ExePath
    )

    $seen = @{}
    $emit = {
        param($Path, $Why)
        if (-not $Path) { return }
        $key = $Path.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { return }
        if (-not (Test-Path -LiteralPath $Path)) { return }
        $seen[$key] = $true
        [pscustomobject]@{ Path = $Path; Why = $Why }
    }

    # 1. saves kept inside the game - at the root and one level down, because
    #    releases often nest the actual game in a folder of its own
    $bases = @($Target)
    foreach ($sub in (Get-ChildItem -LiteralPath $Target -Directory -ErrorAction SilentlyContinue |
            Select-Object -First 12)) {
        $bases += $sub.FullName
    }
    foreach ($base in $bases) {
        foreach ($name in $script:GSInGameSaveDirs) {
            $cand = Join-Path $base $name
            if (Test-Path -LiteralPath $cand -PathType Container) {
                $where = 'the game root'
                if ($base -ne $Target) { $where = Split-Path -Leaf $base }
                & $emit $cand "folder named '$name' inside $where"
            }
        }
    }

    # 2. metadata-driven
    $company = ''
    $product = ''
    $exeBase = ''
    if ($ExePath -and (Test-Path -LiteralPath $ExePath)) {
        try {
            $vi = (Get-Item -LiteralPath $ExePath).VersionInfo
            $company = ([string]$vi.CompanyName).Trim()
            $product = ([string]$vi.ProductName).Trim()
            if ($product -and $product -match '^(Unity|Unreal|Microsoft|Windows)') { $product = '' }
            if ($company -and $company -match '^(Unity|Unreal|Microsoft|Windows)') { $company = '' }
            $exeBase = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
            $exeBase = $exeBase -replace '-Win64-Shipping$', '' -replace '-Win32-Shipping$', ''
            if ($exeBase -match '^(start_protected_game|launcher|game)$') { $exeBase = '' }
        } catch { }
    }

    $roots = @()
    if ($env:APPDATA) { $roots += [pscustomobject]@{ Root = $env:APPDATA; Label = 'Roaming' } }
    if ($env:LOCALAPPDATA) { $roots += [pscustomobject]@{ Root = $env:LOCALAPPDATA; Label = 'Local' } }
    if ($env:USERPROFILE) {
        $roots += [pscustomobject]@{ Root = (Join-Path $env:USERPROFILE 'AppData\LocalLow'); Label = 'LocalLow' }
    }

    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r.Root)) { continue }
        if ($company -and $product) {
            & $emit (Join-Path (Join-Path $r.Root $company) $product) "$($r.Label)\$company\$product (from exe metadata)"
        }
        if ($product) {
            & $emit (Join-Path $r.Root $product) "$($r.Label)\$product (from exe metadata)"
        }
        if ($exeBase) {
            $byExe = Join-Path $r.Root $exeBase
            & $emit $byExe "$($r.Label)\$exeBase (from the executable name)"
            & $emit (Join-Path $byExe 'Saved\SaveGames') "$($r.Label)\$exeBase\Saved\SaveGames (Unreal layout)"
            & $emit (Join-Path $byExe 'Saved') "$($r.Label)\$exeBase\Saved (Unreal layout)"
        }
    }

    # 3. Documents and Saved Games
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $docRoots = @()
    if ($docs) {
        $docRoots += [pscustomobject]@{ Root = $docs; Label = 'Documents' }
        $docRoots += [pscustomobject]@{ Root = (Join-Path $docs 'My Games'); Label = 'Documents\My Games' }
    }
    if ($env:USERPROFILE) {
        $docRoots += [pscustomobject]@{ Root = (Join-Path $env:USERPROFILE 'Saved Games'); Label = 'Saved Games' }
    }
    foreach ($d in $docRoots) {
        foreach ($cand in @($EntryName, $product)) {
            if (-not $cand) { continue }
            & $emit (Join-Path $d.Root $cand) "$($d.Label)\$cand"
        }
    }

    # 4. anything under those roots whose name resembles the entry
    $needle = ($EntryName -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
    if ($needle.Length -ge 4) {
        foreach ($r in ($roots + $docRoots)) {
            if (-not (Test-Path -LiteralPath $r.Root)) { continue }
            foreach ($d in (Get-ChildItem -LiteralPath $r.Root -Directory -ErrorAction SilentlyContinue)) {
                $dn = ($d.Name -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
                if ($dn -eq $needle -or $dn.Contains($needle)) {
                    & $emit $d.FullName "name matches the entry ($($r.Label))"
                }
                foreach ($sub in (Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue)) {
                    $sn = ($sub.Name -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
                    if ($sn -eq $needle -or $sn.Contains($needle)) {
                        & $emit $sub.FullName "name matches the entry ($($r.Label)\$($d.Name))"
                    }
                }
            }
        }
    }
}

function Copy-GSTree {
    <#
    .SYNOPSIS
        Copy a file or a folder tree, tolerating long paths.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )
    if (-not (Test-Path -LiteralPath $To)) { New-Item -ItemType Directory -Path $To -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $From -PathType Container)) {
        Copy-Item -LiteralPath $From -Destination $To -Force
        return
    }
    & robocopy $From $To /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
    # robocopy exits 0-7 on success; 8 and above are real failures
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed (code $LASTEXITCODE) copying '$From'" }
}

function Get-GSSaveStore {
    <#
    .SYNOPSIS
        Where a shelf's backups live. Defaults to <shelf>\_saves.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Shelf,
        [string]$Store
    )
    if ($Store) { return $Store }
    return (Join-Path $Shelf $script:GSSaveStoreName)
}

function Backup-GSSave {
    <#
    .SYNOPSIS
        Copy an entry's saves into <store>\<entry>\<timestamp>\.
    .DESCRIPTION
        Each source becomes p0, p1, ... so two sources with the same folder name
        cannot collide. The manifest records the mapping plus the resulting counts,
        and the copy is re-counted afterwards so a truncated copy is reported
        rather than silently kept.

        Returns $null when the entry has no existing save paths.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EntryName,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string[]]$RawPaths,
        [Parameter(Mandatory)][string]$Store,
        [string]$Label,
        [int]$Keep = 10
    )

    $live = @(Get-GSSaveTarget -Target $Target -RawPaths $RawPaths | Where-Object { $_.Exists })
    if ($live.Count -eq 0) { return $null }

    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    if ($Label) { $stamp = $Label + '_' + $stamp }
    $entryRoot = Join-Path $Store $EntryName
    $destRoot = Join-Path $entryRoot $stamp
    if (Test-Path -LiteralPath $destRoot) { $destRoot = $destRoot + '_' + (Get-Random -Maximum 9999) }
    New-Item -ItemType Directory -Path $destRoot -Force | Out-Null

    $manifest = New-Object System.Collections.Generic.List[string]
    $manifest.Add('# gameshelf save backup v1')
    $manifest.Add("# entry: $EntryName")
    $manifest.Add("# created: $((Get-Date -Format s))")

    $files = 0
    $bytes = [long]0
    $i = 0
    foreach ($src in $live) {
        $sub = 'p' + $i
        $dest = Join-Path $destRoot $sub
        Copy-GSTree -From $src.Path -To $dest
        $st = Get-GSFileStat -Path $dest
        $files += $st.Files
        $bytes += $st.Bytes
        $manifest.Add(('{0}|{1}|{2}|{3}' -f $sub, $src.Kind, $st.Files, $src.Path))
        $i++
    }
    $manifest.Insert(3, "# files: $files")
    $manifest.Insert(4, "# bytes: $bytes")
    [System.IO.File]::WriteAllLines((Join-Path $destRoot $script:GSSaveManifestName), $manifest,
        (New-Object System.Text.UTF8Encoding($true)))

    # prune old backups, never the safety copies
    $old = @(Get-ChildItem -LiteralPath $entryRoot -Directory |
        Where-Object { -not $_.Name.StartsWith('_prerestore_') } |
        Sort-Object Name -Descending)
    $pruned = 0
    if ($Keep -gt 0 -and $old.Count -gt $Keep) {
        foreach ($o in ($old | Select-Object -Skip $Keep)) {
            Remove-Item -LiteralPath $o.FullName -Recurse -Force
            $pruned++
        }
    }

    return [pscustomobject]@{
        Entry  = $EntryName
        Backup = $destRoot
        Id     = Split-Path -Leaf $destRoot
        Sources = $live.Count
        Files  = $files
        Bytes  = $bytes
        Pruned = $pruned
    }
}

function Get-GSSaveBackup {
    <#
    .SYNOPSIS
        List an entry's backups, newest first.
    .DESCRIPTION
        Emits one object per backup. Safety copies are included and flagged, so a
        listing never looks like it is missing the state you just had.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EntryName,
        [Parameter(Mandatory)][string]$Store
    )

    $entryRoot = Join-Path $Store $EntryName
    if (-not (Test-Path -LiteralPath $entryRoot)) { return }

    foreach ($d in (Get-ChildItem -LiteralPath $entryRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending)) {
        $files = 0
        $bytes = [long]0
        $sources = 0
        $mf = Join-Path $d.FullName $script:GSSaveManifestName
        if (Test-Path -LiteralPath $mf) {
            foreach ($line in [System.IO.File]::ReadAllLines($mf, [System.Text.Encoding]::UTF8)) {
                if ($line -like '# files:*') { $files = [int]($line -replace '\D', '') }
                elseif ($line -like '# bytes:*') { $bytes = [long]($line -replace '\D', '') }
                elseif (-not $line.StartsWith('#') -and $line.Contains('|')) { $sources++ }
            }
        }
        [pscustomobject]@{
            Id      = $d.Name
            Path    = $d.FullName
            Kind    = $(if ($d.Name.StartsWith('_prerestore_')) { 'Pre-restore' } else { 'Backup' })
            Safe    = $d.Name.StartsWith('_prerestore_')
            Files   = $files
            Bytes   = $bytes
            Sources = $sources
            Created = $d.CreationTime
        }
    }
}

function Restore-GSSave {
    <#
    .SYNOPSIS
        Copy a backup back over the live save paths.
    .DESCRIPTION
        The live saves are written aside to a _prerestore_* folder first, so a
        mistaken restore is recoverable. Live paths are cleared before the copy so
        the result reflects the backup rather than merging with it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EntryName,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string[]]$RawPaths,
        [Parameter(Mandatory)][string]$Store,
        [string]$BackupId
    )

    $all = @(Get-GSSaveBackup -EntryName $EntryName -Store $Store)
    $real = @($all | Where-Object { -not $_.Safe })
    if ($real.Count -eq 0) { throw "No backup found for '$EntryName'." }

    $pick = $real[0]
    if ($BackupId) {
        $pick = $null
        foreach ($b in $real) { if ($b.Id -eq $BackupId) { $pick = $b; break } }
        if (-not $pick) { throw "Backup '$BackupId' not found for '$EntryName'." }
    }

    # 1. write the current state aside
    $safety = Backup-GSSave -EntryName $EntryName -Target $Target -RawPaths $RawPaths `
        -Store $Store -Label '_prerestore' -Keep 0

    # 2. read the chosen manifest
    $manifestPath = Join-Path $pick.Path $script:GSSaveManifestName
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Backup '$($pick.Id)' has no readable manifest." }

    $restored = 0
    foreach ($line in [System.IO.File]::ReadAllLines($manifestPath, [System.Text.Encoding]::UTF8)) {
        if ($line.StartsWith('#')) { continue }
        $p = $line.Split('|')
        if ($p.Count -lt 4) { continue }
        # The path is always the last field: an older layout also recorded bytes.
        $sub = $p[0]
        $kind = $p[1]
        $destPath = $p[$p.Count - 1]
        $src = Join-Path $pick.Path $sub
        if (-not (Test-Path -LiteralPath $src)) { continue }

        if ($kind -eq 'File') {
            $parent = Split-Path -Parent $destPath
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Copy-Item -LiteralPath $src -Destination $destPath -Force
        } else {
            if (Test-Path -LiteralPath $destPath) { Remove-Item -LiteralPath $destPath -Recurse -Force }
            Copy-GSTree -From $src -To $destPath
        }
        $restored++
    }

    return [pscustomobject]@{
        Entry      = $EntryName
        From       = $pick.Id
        Restored   = $restored
        SafetyCopy = $(if ($safety) { $safety.Backup } else { $null })
    }
}
