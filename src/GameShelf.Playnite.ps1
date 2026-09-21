<#
    GameShelf - Playnite bridge.

    Dot-sourced by GameShelf.psm1, so these functions live in the module scope
    and run under the module's StrictMode.

    Playnite (https://playnite.link) already knows what is installed, where, how
    long it has been played and how the user categorised it. GameShelf knows how
    to turn a pile of folders into one browsable shelf. This file is the seam
    between them, and it reads one file:

        %APPDATA%\GameShelf\playnite-library.json

    written by the Playnite extension in integrations/playnite/. The seam is a
    JSON file rather than Playnite's own database on purpose: games.db is LiteDB,
    the maintainer explicitly discourages third-party tools from reading it
    ("If you want to access game library data, you need to make a plugin for
    Playnite"), and its format is slated to change. A file both sides agree on is
    a contract; an internal database is a coincidence.

    The extension itself is thin. Everything interesting happens here, so a future
    C# plugin (Playnite 11 drops PowerShell script extensions) only has to produce
    the same JSON.
#>

$script:GSPlayniteSchema = 'gameshelf.playnite.library'
$script:GSPlayniteSchemaVersion = 1
$script:GSPlayniteExportName = 'playnite-library.json'
$script:GSPlayniteExtensionId = 'GameShelf'

# Stores whose games are managed by a launcher. Shelving them is the case the
# README warns about, so they are labelled and can be skipped rather than being
# silently included and then blamed on GameShelf.
$script:GSLauncherSources = @(
    'Steam', 'Epic', 'Epic Games', 'GOG', 'GOG Galaxy', 'Xbox', 'Microsoft Store',
    'Ubisoft Connect', 'Uplay', 'EA app', 'Origin', 'Battle.net', 'WeGame'
)

function Get-GSPlayniteExportPath {
    <#
    .SYNOPSIS
        Where the Playnite extension writes its library export, and where GameShelf
        reads it from.
    #>
    [CmdletBinding()]
    param([string]$File)

    if ($File) { return $File }
    if ($env:GAMESHELF_PLAYNITE_EXPORT) { return $env:GAMESHELF_PLAYNITE_EXPORT }
    if ($env:APPDATA) { return (Join-Path $env:APPDATA ('GameShelf\' + $script:GSPlayniteExportName)) }
    return $null
}

function Import-GSPlayniteLibrary {
    <#
    .SYNOPSIS
        Read a Playnite library export.
    .DESCRIPTION
        Validates the schema before trusting anything in the file: an export from
        a newer extension can mean something different by the same field names,
        and guessing there would put wrong paths into a manifest.

        Returns the export's metadata plus a Games array. A single-game export
        still arrives as an array - PowerShell 5.1 unwraps one-element JSON arrays
        into a bare object, which is the kind of bug that only shows up on someone
        else's machine with exactly one game installed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Playnite export not found: $Path"
    }

    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if (-not $text.Trim()) { throw "Playnite export is empty: $Path" }

    $data = $null
    try { $data = $text | ConvertFrom-Json } catch { throw "Playnite export is not valid JSON: $($_.Exception.Message)" }
    if ($null -eq $data) { throw "Playnite export is not valid JSON: $Path" }

    $schema = [string](Get-GSJsonMember -Object $data -Name 'schema')
    if (-not $schema) {
        throw "Not a GameShelf Playnite export (no schema): $Path"
    }
    if ($schema -notlike ($script:GSPlayniteSchema + '/*')) {
        throw "Unknown export schema '$schema' - expected $($script:GSPlayniteSchema)/<n>."
    }
    $version = 0
    [void][int]::TryParse(($schema -replace '^.*/', ''), [ref]$version)
    if ($version -gt $script:GSPlayniteSchemaVersion) {
        throw ("Export schema '$schema' is newer than this GameShelf understands " +
            "($($script:GSPlayniteSchema)/$($script:GSPlayniteSchemaVersion)). Update GameShelf.")
    }

    $games = New-Object System.Collections.Generic.List[object]
    $raw = Get-GSJsonMember -Object $data -Name 'games'
    foreach ($g in @($raw)) {
        if ($null -eq $g) { continue }
        $name = [string](Get-GSJsonMember -Object $g -Name 'name')
        if (-not $name) { continue }

        $last = [string](Get-GSJsonMember -Object $g -Name 'lastActivity')
        $lastDate = $null
        if ($last) {
            try { $lastDate = [datetime]::Parse($last, [System.Globalization.CultureInfo]::InvariantCulture) } catch { }
        }

        $games.Add([pscustomobject]@{
                Id              = [string](Get-GSJsonMember -Object $g -Name 'id')
                Name            = $name
                InstallDir      = ([string](Get-GSJsonMember -Object $g -Name 'installDir')).TrimEnd('\')
                IsInstalled     = [bool](Get-GSJsonMember -Object $g -Name 'isInstalled')
                PlaytimeSeconds = [long](Get-GSJsonMember -Object $g -Name 'playtimeSeconds')
                PlayCount       = [long](Get-GSJsonMember -Object $g -Name 'playCount')
                LastActivity    = $last
                LastActivityAt  = $lastDate
                Categories      = @(Get-GSJsonMember -Object $g -Name 'categories')
                Genres          = @(Get-GSJsonMember -Object $g -Name 'genres')
                Tags            = @(Get-GSJsonMember -Object $g -Name 'tags')
                Source          = [string](Get-GSJsonMember -Object $g -Name 'source')
                Platforms       = @(Get-GSJsonMember -Object $g -Name 'platforms')
                Hidden          = [bool](Get-GSJsonMember -Object $g -Name 'hidden')
                Favorite        = [bool](Get-GSJsonMember -Object $g -Name 'favorite')
            })
    }

    return [pscustomobject]@{
        Path            = (Resolve-Path -LiteralPath $Path).Path
        Schema          = $schema
        Generated       = [string](Get-GSJsonMember -Object $data -Name 'generated')
        PlayniteVersion = [string](Get-GSJsonMember -Object $data -Name 'playniteVersion')
        Games           = $games.ToArray()
    }
}

function Get-GSPlayniteExtensionRoot {
    <#
    .SYNOPSIS
        Playnite's extensions folder.
    .DESCRIPTION
        Documented layout: installed Playnite keeps extensions in
        %APPDATA%\Playnite\Extensions, the portable build keeps them next to
        itself. A portable install cannot be located reliably from here, so -Root
        is there for it and the default is returned even when the folder does not
        exist yet, so -WhatIf can still say where something would go.
    #>
    [CmdletBinding()]
    param([string]$Root)

    if ($Root) { return $Root }
    if ($env:PLAYNITE_EXTENSIONS) { return $env:PLAYNITE_EXTENSIONS }
    if ($env:APPDATA) { return (Join-Path $env:APPDATA 'Playnite\Extensions') }
    return $null
}

function Import-GSPlayniteExtensionManifest {
    <#
    .SYNOPSIS
        Read the handful of keys GameShelf cares about from an extension.yaml.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    $meta = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $meta }
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        if ($line -match '^\s*#' -or -not $line.Trim()) { continue }
        $idx = $line.IndexOf(':')
        if ($idx -lt 1) { continue }
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        # strip the quotes YAML allows around scalars
        if ($val.Length -ge 2) {
            $q = $val.Substring(0, 1)
            if (($q -eq '"' -or $q -eq "'") -and $val.EndsWith($q)) {
                $val = $val.Substring(1, $val.Length - 2)
            }
        }
        $meta[$key] = $val
    }
    return $meta
}

function Install-GSPlayniteExtension {
    <#
    .SYNOPSIS
        Copy the bundled Playnite extension into Playnite's extensions folder.
    .DESCRIPTION
        Refuses to overwrite an existing extension folder that declares a
        different Id: that would be some other extension, and replacing it because
        the folder name matched would be a destructive surprise.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Root,
        [switch]$Force
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Extension source not found: $Source"
    }
    $manifestPath = Join-Path $Source 'extension.yaml'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Extension source has no extension.yaml: $Source"
    }

    $meta = Import-GSPlayniteExtensionManifest -Path $manifestPath
    $id = [string]$meta['Id']
    if (-not $id) { throw "extension.yaml has no Id: $manifestPath" }
    $module = [string]$meta['Module']
    if ($module -and -not (Test-Path -LiteralPath (Join-Path $Source $module))) {
        throw "extension.yaml names Module '$module' but it is not in $Source"
    }

    $dest = Join-Path $Root $id
    if (Test-Path -LiteralPath $dest) {
        $existing = Import-GSPlayniteExtensionManifest -Path (Join-Path $dest 'extension.yaml')
        $existingId = [string]$existing['Id']
        if ($existingId -and $existingId -ne $id) {
            throw "Refusing to replace '$dest': it declares Id '$existingId', not '$id'."
        }
        if (-not $Force) {
            throw "Extension already installed at $dest. Re-run with -Force to replace it."
        }
    }

    $files = @(Get-ChildItem -LiteralPath $Source -Recurse -File)
    if (-not $PSCmdlet.ShouldProcess($dest, "Install Playnite extension '$id' ($($files.Count) files)")) {
        return [pscustomobject]@{ Id = $id; Path = $dest; Files = $files.Count; Installed = $false }
    }

    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    # Robocopy keeps long paths working and mirrors the folder exactly, which
    # matters because Playnite replaces the whole extension directory on update
    # and a stale leftover file would survive the next install.
    & robocopy $Source $dest /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed (code $LASTEXITCODE) installing the extension" }

    return [pscustomobject]@{ Id = $id; Path = $dest; Files = $files.Count; Installed = $true }
}

function ConvertTo-GSManifestField {
    <#
    .SYNOPSIS
        Make a value safe for one field of a pipe-delimited manifest line.
    .DESCRIPTION
        Import-GSManifest splits on '|' and takes exactly four fields, so a pipe
        or a newline inside a Playnite game name would silently shift the columns
        of every row after it.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Value)

    if (-not $Value) { return '' }
    return ($Value -replace '\|', '/' -replace '[\r\n]+', ' ').Trim()
}

function New-GSPlayniteManifest {
    <#
    .SYNOPSIS
        Build manifest items from a Playnite library.
    .DESCRIPTION
        Emits the same shape scan does - Category, Name, Target, Note - so the
        result can be edited and fed straight to build.

        The category comes from Playnite's own categories, then genres, then the
        'Unsorted' default: the point of scanning from Playnite rather than from
        the filesystem is that the user has already done the sorting.

        Games with no install folder are skipped outright, because a manifest
        entry with no target cannot be built. Launcher-managed stores are labelled
        in the note and can be dropped with -SkipLauncherManaged.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Games,
        [ValidateSet('Categories', 'Genres', 'Tags')][string]$CategorySource = 'Categories',
        [switch]$OnlyInstalled,
        [switch]$SkipLauncherManaged
    )

    foreach ($g in @($Games | Where-Object { $_ })) {
        if ($g.Hidden) { continue }
        if (-not $g.InstallDir) { continue }
        if ($OnlyInstalled -and -not $g.IsInstalled) { continue }

        $source = [string]$g.Source
        $managed = $false
        foreach ($s in $script:GSLauncherSources) {
            if ($source -ieq $s) { $managed = $true; break }
        }
        if ($managed -and $SkipLauncherManaged) { continue }

        $category = ''
        foreach ($c in @($g.$CategorySource)) {
            if ($c) { $category = [string]$c; break }
        }
        if (-not $category) { $category = 'Unsorted' }

        $bits = New-Object System.Collections.Generic.List[string]
        if ($g.PlaytimeSeconds -gt 0) {
            $bits.Add(('{0:N1} h played' -f ($g.PlaytimeSeconds / 3600.0)))
        }
        if ($g.LastActivityAt) { $bits.Add('last played ' + $g.LastActivityAt.ToString('yyyy-MM-dd')) }
        if ($source) { $bits.Add('via ' + $source) }
        if (-not $g.IsInstalled) { $bits.Add('not marked installed') }
        if ($managed) { $bits.Add('launcher-managed: use Link mode, see README') }
        if (-not (Test-Path -LiteralPath $g.InstallDir)) { $bits.Add('folder missing') }

        [pscustomobject]@{
            Category = ConvertTo-GSManifestField -Value $category
            Name     = ConvertTo-GSManifestField -Value $g.Name
            Target   = [string]$g.InstallDir
            Note     = ConvertTo-GSManifestField -Value ($bits -join '; ')
        }
    }
}

function Get-GSPlayniteMatch {
    <#
    .SYNOPSIS
        Line a shelf up against a Playnite library.
    .DESCRIPTION
        Matches on the install path first and the name second. The path is
        authoritative - a shelf entry's target is literally the folder Playnite
        launches from - while the name is a fallback for entries whose folder was
        renamed on the shelf, which is exactly what the manifest's name column is
        for. A name match is reported as such so it can be eyeballed.

        Returns the shelf side and the leftover games: knowing what Playnite has
        that the shelf does not is the other half of the answer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Shelf,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Games
    )

    $remaining = New-Object System.Collections.Generic.List[object]
    $byPath = @{}
    $byName = @{}
    foreach ($g in @($Games | Where-Object { $_ })) {
        $remaining.Add($g)
        if ($g.InstallDir) {
            $key = $g.InstallDir.ToLowerInvariant()
            if (-not $byPath.ContainsKey($key)) { $byPath[$key] = $g }
        }
        $nk = ($g.Name -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
        if ($nk -and -not $byName.ContainsKey($nk)) { $byName[$nk] = $g }
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($e in (Get-GSShelf -Shelf $Shelf -SkipSize).Items) {
        $game = $null
        $kind = 'none'
        if ($e.Target) {
            $key = ([string]$e.Target).TrimEnd('\').ToLowerInvariant()
            if ($byPath.ContainsKey($key)) { $game = $byPath[$key]; $kind = 'path' }
        }
        if (-not $game) {
            $nk = ($e.Name -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
            if ($nk -and $byName.ContainsKey($nk)) { $game = $byName[$nk]; $kind = 'name' }
        }
        # [void] matters: List.Remove returns a bool, and a bare call would leak
        # those bools into this function's output, making it return an array of
        # results instead of one object. Member enumeration then quietly turns the
        # empty leftover list into $null, so callers see "one unmatched game" that
        # has no name instead of none at all.
        if ($game) { [void]$remaining.Remove($game) }

        $hours = $null
        if ($game) { $hours = [math]::Round($game.PlaytimeSeconds / 3600.0, 1) }

        $rows.Add([pscustomobject]@{
                Name      = $e.Name
                Category  = $e.Category
                Target    = $e.Target
                Matched   = [bool]$game
                MatchKind = $kind
                Game      = $game
                Hours     = $hours
                LastPlayed = $(if ($game) { $game.LastActivityAt } else { $null })
                Source    = $(if ($game) { $game.Source } else { '' })
            })
    }

    return [pscustomobject]@{
        OnShelf   = $rows.ToArray()
        Unmatched = $remaining.ToArray()
        Matched   = @($rows | Where-Object { $_.Matched }).Count
        Total     = $rows.Count
    }
}
