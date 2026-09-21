<#
.SYNOPSIS
    GameShelf command line.

.EXAMPLE
    .\gameshelf.ps1 doctor

.EXAMPLE
    .\gameshelf.ps1 scan -Root D:\, E:\, F:\ -Out draft.txt

.EXAMPLE
    .\gameshelf.ps1 build -Manifest draft.txt -Shelf H:\Games

.EXAMPLE
    .\gameshelf.ps1 verify -Shelf H:\Games

.EXAMPLE
    .\gameshelf.ps1 index -Shelf H:\Games

.EXAMPLE
    .\gameshelf.ps1 remove -Shelf H:\Games -All -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0, Mandatory)]
    [ValidateSet('doctor', 'scan', 'build', 'list', 'verify', 'index', 'remove',
        'saves', 'backup', 'backups', 'restore', 'adopt', 'playnite',
        'roots', 'sync', 'help')]
    [string]$Command,

    # scan
    [string[]]$Root,
    [ValidateRange(1, 4)][int]$Depth = 2,
    [double]$MinSizeGB = 0.05,
    [switch]$SkipSize,
    [string[]]$Exclude,
    [string]$Out,
    [string]$Csv,

    # build / list / verify / index / remove
    [string]$Manifest,
    [string]$Shelf,
    [ValidateSet('Link', 'Move', 'Copy')][string]$Mode = 'Link',
    [switch]$Force,
    [switch]$Replace,

    # remove / saves / backup / restore
    [string]$Name,
    [string]$Category,
    [switch]$All,

    # save data
    [string]$Store,
    [int]$Keep = 10,
    [string]$Backup,

    # ... and addressing an entry by the folder it points at, which is all a
    # launcher such as Playnite has to hand
    [string]$Target,

    # ludusavi / adopt
    [switch]$Ludusavi,
    [string]$LudusaviExe,
    [string]$Title,
    [double]$MinScore = 0.8,
    [switch]$UpdateManifest,

    # playnite
    [string]$File,
    [switch]$Install,
    [string]$PlayniteRoot,
    [ValidateSet('Categories', 'Genres', 'Tags')][string]$CategorySource = 'Categories',
    [switch]$OnlyInstalled,
    [switch]$SkipLauncherManaged,

    # roots: bind a portable %label% to a folder on this machine
    [string[]]$Set,
    [switch]$Portable,

    # sync: add newly detected games, optionally commit and schedule
    [string]$Label,
    [switch]$Commit,
    [switch]$Push,
    [switch]$Register,
    [switch]$Unregister,
    [string]$At = '20:00',
    [string]$TaskName = 'GameShelf sync'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\GameShelf.psm1') -Force

function Write-Head([string]$Text) {
    Write-Host ''
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * $Text.Length)) -ForegroundColor DarkGray
}

function Write-Ok([string]$Text) { Write-Host "  [ok]   $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text) { Write-Host "  [warn] $Text" -ForegroundColor Yellow }
function Write-Bad([string]$Text) { Write-Host "  [fail] $Text" -ForegroundColor Red }
function Write-Info([string]$Text) { Write-Host "         $Text" -ForegroundColor DarkGray }

function Format-GSSize([long]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Write-GSLudusaviProposal([object]$Proposal, [switch]$RawPaths) {
    <#
      One Ludusavi proposal, in the two shapes the two callers want: 'saves' shows
      what is on disk right now, 'adopt' shows exactly what would be written to the
      map. Same header either way, so the two views read as one feature.
    #>
    if (-not $Proposal.Ok) {
        $why = $Proposal.Reason
        if (-not $why) { $why = 'no usable paths' }
        if ($Proposal.Title -and $Proposal.Match -eq 'fuzzy') {
            $why = $why + '  (best: "' + $Proposal.Title + '" ' + ('{0:N2}' -f $Proposal.Score) + ')'
        }
        Write-Host ("  {0,-30} {1}" -f $Proposal.Entry, $why) -ForegroundColor DarkYellow
        return
    }

    $how = $Proposal.Match
    if ($Proposal.Match -eq 'fuzzy') { $how = 'fuzzy ' + ('{0:N2}' -f $Proposal.Score) }
    Write-Host ("  {0,-30} {1}" -f $Proposal.Entry, ('-> "' + $Proposal.Title + '"   ' + $how)) -ForegroundColor White

    if ($RawPaths) {
        foreach ($path in $Proposal.Paths) { Write-Host ('      ' + $path) -ForegroundColor Gray }
        $bits = New-Object System.Collections.Generic.List[string]
        if ($Proposal.Files -gt 0) { $bits.Add(('{0} file(s)' -f $Proposal.Files)) }
        if ($Proposal.Bytes -gt 0) { $bits.Add((Format-GSSize $Proposal.Bytes)) }
        if ($bits.Count -gt 0) { Write-Info (($bits -join ', ') + ' as Ludusavi counts them') }
    } else {
        foreach ($t in (Get-GSSaveTarget -Target $Proposal.Target -RawPaths $Proposal.Paths)) {
            if ($t.Exists) {
                $st = Get-GSFileStat -Path $t.Path
                Write-Host ("      [ok]      {0,10}  {1,6} files  {2}" -f `
                        (Format-GSSize $st.Bytes), $st.Files, $t.Path) -ForegroundColor Green
            } else {
                Write-Host ("      [missing]                        " + $t.Path) -ForegroundColor DarkGray
            }
        }
    }

    if ($Proposal.Dropped -gt 0) { Write-Info ("+ $($Proposal.Dropped) more location(s), not shown") }
    if ($Proposal.Registry -gt 0) {
        Write-Info ("Ludusavi also lists $($Proposal.Registry) registry key(s); GameShelf backs up files only")
    }
}

function Write-GSPlayniteSettingsTemplate([string]$Cli) {
    <#
      The Playnite extension reads shelf + cli from this file. Written here rather
      than left to the extension's own template because the CLI knows its real
      path, and a first run that already has the right cli in it removes the step
      people actually get stuck on. Never overwrites an existing file.
    #>
    if (-not $env:APPDATA) { return $null }
    $dir = Join-Path $env:APPDATA 'GameShelf'
    $path = Join-Path $dir 'playnite-extension.json'
    if (Test-Path -LiteralPath $path) { return $path }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $template = [ordered]@{
        _comment = 'shelf = the folder GameShelf built. cli is filled in already; change it if you move the checkout.'
        cli      = $Cli
        shelf    = 'H:\Games'
    }
    [System.IO.File]::WriteAllText($path, ($template | ConvertTo-Json -Depth 4),
        (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

switch ($Command) {

    'help' {
        Write-Host ''
        Write-Host '  GameShelf - one browsable folder for everything scattered across your drives.' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  Commands'
        Write-Host '    doctor                        Check this machine can build a shelf.'
        Write-Host '    scan    -Root <paths>         Draft a manifest of candidate games.'
        Write-Host '            [-Depth 2] [-MinSizeGB 0.05] [-SkipSize] [-Exclude <glob>]'
        Write-Host '            [-Out draft.txt] [-Csv report.csv]'
        Write-Host '    build   -Manifest <file>      Materialise the shelf.'
        Write-Host '            -Shelf <folder> [-Mode Link|Move|Copy] [-Force] [-Replace]'
        Write-Host '            merges into an existing shelf unless -Replace is given'
        Write-Host '    list    -Shelf <folder>       Show what is on the shelf. [-SkipSize]'
        Write-Host '    verify  -Shelf <folder>       Check every entry resolves and is readable.'
        Write-Host '    index   -Shelf <folder>       Regenerate CATALOG.md and index.csv.'
        Write-Host '    remove  -Shelf <folder>       Remove junction entries (never the data).'
        Write-Host '            [-All] | [-Name <name>] | [-Category <category>]'
        Write-Host ''
        Write-Host '  Save data'
        Write-Host '    saves   -Shelf <folder>       Show save locations, with candidates for'
        Write-Host '                                  games that are not mapped yet. [-Name <game>]'
        Write-Host '                                  [-Target <folder>] [-Ludusavi]'
        Write-Host '    backup  -Shelf <folder>       Copy saves into the backup store.'
        Write-Host '            -All | -Name <game>   [-Store <folder>] [-Keep 10] [-Target <folder>]'
        Write-Host '    backups -Shelf <folder>       List stored backups. [-Name <game>]'
        Write-Host '                                 [-Target <folder>]'
        Write-Host '    restore -Shelf <folder>       Put a backup back. [-Backup <id>] [-Force]'
        Write-Host '            -Name <game>          The live saves are kept aside first.'
        Write-Host ''
        Write-Host '  Ludusavi (https://github.com/mtkennerly/ludusavi)'
        Write-Host '    adopt   -Shelf <folder>       Ask Ludusavi where the unmapped games keep'
        Write-Host '            -All | -Name <game>   their saves and write those paths into the map.'
        Write-Host '            [-Title <ludusavi title>]   pin the title when names differ'
        Write-Host '            [-MinScore 0.8] [-LudusaviExe <exe>] [-UpdateManifest]'
        Write-Host '    saves -Ludusavi               Same proposals, without writing anything.'
        Write-Host ''
        Write-Host '  Playnite (https://playnite.link)'
        Write-Host '    playnite [-File <json>]       Read the library the Playnite extension'
        Write-Host '            [-Out draft.txt]      exports: draft a manifest, or with'
        Write-Host '            [-Shelf <folder>]     -Shelf, line the shelf up against it.'
        Write-Host '            [-CategorySource Categories|Genres|Tags]'
        Write-Host '            [-OnlyInstalled] [-SkipLauncherManaged]'
        Write-Host '    playnite -Install             Put the bundled extension into Playnite.'
        Write-Host '            [-PlayniteRoot <dir>] [-Force]'
        Write-Host ''
        Write-Host '  Across machines'
        Write-Host '    roots   -Shelf <folder>       Where THIS machine keeps the folders the'
        Write-Host '            [-Set label=folder]   manifest names as %label%. Lists what is'
        Write-Host '            [-Portable]           bound and what is missing; -Portable turns'
        Write-Host '                                  existing drive letters into %label% paths.'
        Write-Host '    sync    -Shelf <folder>       Add games that appeared since last time.'
        Write-Host '            [-Root <folder>]      Default: every %label% bound here.'
        Write-Host '            [-Label <name>]       Name the root being scanned, so the new'
        Write-Host '            [-Category <name>]    targets come out portable too.'
        Write-Host '            [-Commit] [-Push]     Commit the shelf when it changed.'
        Write-Host '            [-Register [-At 20:00]]   Run this daily on this machine.'
        Write-Host '            [-Unregister]'
        Write-Host ''
        Write-Host '  Always available: -WhatIf -Verbose'
        Write-Host ''
    }

    'doctor' {
        Write-Host ''
        Write-Host '  GameShelf doctor' -ForegroundColor Cyan
        Write-Host ''
        $checks = Test-GSEnvironment
        $bad = 0
        foreach ($c in $checks) {
            if ($c.Ok) { Write-Ok ("{0,-22} {1}" -f $c.Check, $c.Detail) }
            else { Write-Bad ("{0,-22} {1}" -f $c.Check, $c.Detail); $bad++ }
        }

        # Optional integrations. Absent is the normal case and is not a failure -
        # only a -LudusaviExe the user named themselves counts against the run,
        # because that one is a typo rather than a choice.
        $lud = $null
        try {
            $lud = Test-GSLudusavi -Exe $LudusaviExe
        } catch {
            Write-Bad ("{0,-22} {1}" -f 'Ludusavi', $_.Exception.Message)
            $bad++
        }
        if ($null -ne $lud) {
            if ($lud.Available) {
                $version = $lud.Version
                if (-not $version) { $version = 'ludusavi' }
                Write-Ok ("{0,-22} {1}" -f 'Ludusavi', "$version - $($lud.Note)")
                if ($lud.ManifestPath) { Write-Info ("manifest  " + $lud.ManifestPath) }
            } else {
                Write-Host ("  [--]   {0,-22} {1}" -f 'Ludusavi', $lud.Note) -ForegroundColor DarkGray
            }
        }

        $export = Get-GSPlayniteExportPath -File $File
        if ($export -and (Test-Path -LiteralPath $export -PathType Leaf)) {
            $age = ((Get-Date) - (Get-Item -LiteralPath $export).LastWriteTime)
            $stamp = '{0:N1}h' -f $age.TotalHours
            if ($age.TotalDays -ge 1) { $stamp = '{0:N1}d' -f $age.TotalDays }
            try {
                $lib = Import-GSPlayniteLibrary -Path $export
                Write-Ok ("{0,-22} {1}" -f 'Playnite export', "$($lib.Games.Count) game(s), written $stamp ago")
                Write-Info ("export    " + $lib.Path)
            } catch {
                Write-Bad ("{0,-22} {1}" -f 'Playnite export', $_.Exception.Message)
            }
        } else {
            Write-Host ("  [--]   {0,-22} {1}" -f 'Playnite', 'no library export yet (optional)') -ForegroundColor DarkGray
            Write-Info 'gameshelf.ps1 playnite -Install    then export from Playnite''s main menu'
        }

        Write-Host ''
        if ($bad -eq 0) { Write-Host '  Ready. You can build a Link shelf.' -ForegroundColor Green }
        else { Write-Host "  $bad check(s) failed." -ForegroundColor Red }
        Write-Host ''
        if ($bad -gt 0) { exit 1 }
    }

    'scan' {
        if (-not $Root) { throw 'scan needs -Root, for example: scan -Root D:\, E:\' }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Write-Host ''
        Write-Host '  Scanning (read-only, nothing is modified)' -ForegroundColor Cyan
        Write-Host ''

        $scanArgs = @{
            Root      = $Root
            Depth     = $Depth
            MinSizeGB = $MinSizeGB
            SkipSize  = $SkipSize.IsPresent
        }
        if ($Exclude) { $scanArgs['Exclude'] = $Exclude }
        $found = Invoke-GSScan @scanArgs

        if ($found.Count -eq 0) {
            Write-Warn2 'Nothing detected. Try -Depth 3, a lower -MinSizeGB, or build a manifest by hand.'
            return
        }

        Write-Host ("  {0,-42} {1,10} {2,6}  {3}" -f 'NAME', 'GB', 'SCORE', 'WHY') -ForegroundColor DarkGray
        foreach ($f in ($found | Sort-Object Kind, @{Expression = 'SizeGB'; Descending = $true })) {
            $gb = '?'
            if ($null -ne $f.SizeGB) { $gb = ('{0:N2}' -f $f.SizeGB) }
            $kind = ''
            if ($f.Kind -eq 'LauncherLibrary') { $kind = ' [launcher]' }
            # Not $name: that is this script's -Name parameter, and PowerShell
            # variable names are case-insensitive.
            $caption = $f.Name + $kind
            if ($caption.Length -gt 41) { $caption = $caption.Substring(0, 38) + '...' }
            Write-Host ("  {0,-42} {1,10} {2,6}  {3}" -f $caption, $gb, $f.Score, $f.Reasons)
        }

        Write-Host ''
        Write-Host ("  {0} candidate(s) in {1:N1}s" -f $found.Count, $sw.Elapsed.TotalSeconds) -ForegroundColor Cyan

        if ($Out) {
            $items = @()
            foreach ($f in $found) {
                if ($f.Kind -ne 'Game') { continue }
                $items += [pscustomobject]@{
                    Category = 'Unsorted'
                    Name     = $f.Name
                    Target   = $f.Path
                    Note     = ''
                }
            }
            Export-GSManifest -Path $Out -Items $items -Meta @{
                generated = (Get-Date -Format 's')
                note      = 'Draft from scan. Set the category column to your own grouping, then run build.'
            }
            Write-Host "  Draft manifest written: $Out" -ForegroundColor Green
            Write-Info 'Edit the first column (category), delete what you do not want, then build.'
        }

        if ($Csv) {
            $found | Select-Object Name, Kind, Score, SizeGB, Path, Reasons, SourceRoot |
            Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8
            Write-Host "  Report written: $Csv" -ForegroundColor Green
        }
        Write-Host ''
    }

    'build' {
        if (-not $Manifest) { throw 'build needs -Manifest' }
        if (-not $Shelf) { throw 'build needs -Shelf' }
        $res = New-GSShelf -Manifest $Manifest -Shelf $Shelf -Mode $Mode -Force:$Force -Replace:$Replace `
            -WhatIf:$WhatIfPreference -Confirm:$false
        if ($WhatIfPreference) { return }
        Write-Ok ("{0} entr(ies) placed in {1}" -f $res.Created, $res.Shelf)
        if ($res.Skipped -gt 0) { Write-Info ("{0} already present" -f $res.Skipped) }
        if ($res.Kept -gt 0) { Write-Info ("{0} kept from the existing shelf manifest" -f $res.Kept) }
        if ($res.Failed -gt 0) { Write-Warn2 ("{0} skipped (missing target or conflict)" -f $res.Failed) }
        Write-Info ("{0} entries on the shelf now" -f $res.OnShelf)
        Write-Host ''
    }

    'list' {
        if (-not $Shelf) { throw 'list needs -Shelf' }
        $data = Get-GSShelf -Shelf $Shelf -SkipSize:$SkipSize
        Write-Host ''
        Write-Host ("  {0}   mode={1}" -f $data.Shelf, $data.Mode) -ForegroundColor Cyan
        $totalGB = 0
        foreach ($group in ($data.Items | Group-Object Category | Sort-Object Name)) {
            $gsum = ($group.Group | Measure-Object -Property SizeGB -Sum).Sum
            if ($null -eq $gsum) { $gsum = 0 }
            $totalGB += [double]$gsum
            $head = "{0}  ({1} entries, {2:N2} GB)" -f $group.Name, $group.Count, $gsum
            Write-Host ''
            Write-Host "  $head" -ForegroundColor White
            foreach ($i in ($group.Group | Sort-Object Name)) {
                $gb = ''
                if ($null -ne $i.SizeGB) { $gb = ('{0,8:N2} GB' -f $i.SizeGB) }
                $flag = ''
                if ($i.Status -ne 'Link') { $flag = '  <' + $i.Status + '>' }
                Write-Host ("    {0,-44} {1}{2}" -f $i.Name, $gb, $flag)
            }
        }
        Write-Host ''
        Write-Host ("  {0} entries, {1:N2} GB total" -f $data.Items.Count, $totalGB) -ForegroundColor Cyan
        Write-Host ''
    }

    'verify' {
        if (-not $Shelf) { throw 'verify needs -Shelf' }
        $res = Test-GSShelf -Shelf $Shelf
        Write-Host ''
        Write-Host ("  Verifying {0}" -f $res.Shelf) -ForegroundColor Cyan
        foreach ($r in $res.Report) {
            $caption = "$($r.Category)\$($r.Name)"
            if ($r.Status -eq 'Link' -and $r.Readable) {
                Write-Verbose "ok $caption"
            } elseif ($r.Status -ne 'Link') {
                Write-Bad ("{0,-46} {1}" -f $caption, $r.Status)
            } else {
                Write-Bad ("{0,-46} not readable: {1}" -f $caption, $r.Detail)
            }
        }
        Write-Host ''
        if ($res.Bad -eq 0) { Write-Host "  All $($res.Total) entries are healthy." -ForegroundColor Green }
        else { Write-Host "  $($res.Bad) of $($res.Total) entries need attention (run with -Verbose for the healthy ones)." -ForegroundColor Yellow }
        # Unresolved is not breakage: the manifest names a root this machine has not
        # bound, which is the normal state of a shelf on its second computer.
        $unresolved = @($res.Report | Where-Object { $_.Status -eq 'Unresolved' })
        if ($unresolved.Count -gt 0) {
            Write-Host ''
            Write-Info ("{0} entr(ies) use a %root% this machine has not bound:" -f $unresolved.Count)
            Write-Info ("  gameshelf.ps1 roots -Shelf `"$Shelf`"")
        }
        Write-Host ''
        if ($res.Bad -gt 0) { exit 1 }
    }

    'index' {
        if (-not $Shelf) { throw 'index needs -Shelf' }
        $res = Export-GSIndex -Shelf $Shelf
        Write-Host ''
        Write-Ok ("Catalogue: {0}" -f $res.Markdown)
        Write-Ok ("CSV      : {0}" -f $res.Csv)
        Write-Info ("{0} entries, {1:N2} GB" -f $res.Items, $res.TotalGB)
        Write-Host ''
    }

    'remove' {
        if (-not $Shelf) { throw 'remove needs -Shelf' }
        if (-not $All -and -not $Name -and -not $Category) {
            throw 'remove needs -All, -Name or -Category'
        }
        if (-not $WhatIfPreference -and -not $Force) {
            try {
                $go = $PSCmdlet.ShouldContinue(
                    'Remove shelf entries? GameShelf only ever deletes junctions, never your data.',
                    'Confirm removal')
            } catch {
                throw 'Non-interactive session: refusing to remove without confirmation. Re-run with -Force.'
            }
            if (-not $go) { return }
        }

        $res = Remove-GSShelf -Shelf $Shelf -Name $Name -Category $Category -All:$All `
            -WhatIf:$WhatIfPreference -Confirm:$false
        if ($WhatIfPreference) { return }
        Write-Ok ("{0} of {1} junction(s) removed" -f $res.Removed, $res.Matched)
        if ($res.Failed -gt 0) { Write-Warn2 ("{0} failed" -f $res.Failed) }
        Write-Host ''
    }

    'saves' {
        if (-not $Shelf) { throw 'saves needs -Shelf' }
        $shelfData = Get-GSShelf -Shelf $Shelf -SkipSize
        $map = Import-GSSaveMap -Shelf $Shelf
        $storePath = Get-GSSaveStore -Shelf $Shelf -Store $Store

        $items = @($shelfData.Items)
        if ($Name -or $Target) {
            $items = @(Select-GSShelfEntry -Items $shelfData.Items -Name $Name -Target $Target)
            if ($items.Count -eq 0) {
                $what = "named '$Name'"
                if ($Target) { $what = "pointing at '$Target'" }
                throw "No shelf entry $what."
            }
        }

        $mapped = 0; $candidates = 0; $nothing = 0
        $unmapped = New-Object System.Collections.Generic.List[object]
        Write-Host ''
        foreach ($e in $items) {
            $hasMap = $map.ContainsKey($e.Name)
            if ($hasMap) {
                $mapped++
                Write-Host ("  " + $e.Name) -ForegroundColor White
                # $e.Path, not $e.Target: the target may be written %label%\... so
                # the manifest stays portable, and GAME\ save paths can only be
                # resolved against a real folder.
                foreach ($t in (Get-GSSaveTarget -Target $e.Path -RawPaths $map[$e.Name])) {
                    if ($t.Exists) {
                        $st = Get-GSFileStat -Path $t.Path
                        Write-Host ("      [ok]      {0,10}  {1,6} files  {2}" -f `
                                (Format-GSSize $st.Bytes), $st.Files, $t.Path) -ForegroundColor Green
                    } else {
                        Write-Host ("      [missing]                        " + $t.Path) -ForegroundColor DarkGray
                    }
                }
            } else {
                $unmapped.Add($e)
                $exe = Get-GSLaunchExe -Shelf $Shelf -EntryName $e.Name -Target $e.Path
                $found = @(Find-GSSaveCandidate -EntryName $e.Name -Target $e.Path -ExePath $exe)
                if ($found.Count -gt 0) {
                    $candidates++
                    Write-Host ("  " + $e.Name) -ForegroundColor White
                    Write-Host '      not mapped - candidates:' -ForegroundColor Yellow
                    foreach ($c in ($found | Select-Object -First 6)) {
                        $st = Get-GSFileStat -Path $c.Path
                        Write-Host ("        {0,10}  {1,6} files  {2}" -f (Format-GSSize $st.Bytes), $st.Files, $c.Path) -ForegroundColor DarkGray
                        Write-Host ("                    ^ " + $c.Why) -ForegroundColor DarkGray
                    }
                } else {
                    $nothing++
                }
            }
        }
        Write-Host ''
        Write-Host ("  mapped {0}   unmapped with candidates {1}   unmapped, nothing found {2}" -f `
                $mapped, $candidates, $nothing) -ForegroundColor Cyan
        Write-Info ("map   : " + (Get-GSSaveMapPath -Shelf $Shelf))
        Write-Info ("store : " + $storePath)

        if ($Ludusavi) {
            if ($unmapped.Count -eq 0) {
                Write-Host ''
                Write-Info 'Nothing to look up: every entry shown is already mapped.'
            } else {
                $ludExe = Get-GSLudusaviExe -Exe $LudusaviExe
                if (-not $ludExe) {
                    throw 'Ludusavi not found. Install it, or point at it with -LudusaviExe <path to ludusavi.exe>.'
                }
                $info = Test-GSLudusavi -Exe $ludExe
                $ludMap = Import-GSLudusaviMap -Shelf $Shelf
                # The probe only looks for a cached manifest, and with -UpdateManifest
                # the first query is about to fetch one. Saying "none cached" and then
                # fetching it reads like a failure; say what is about to happen.
                $ludNote = $info.Note
                if ($UpdateManifest -and -not $info.ManifestPath) {
                    $ludNote = 'no manifest cached; -UpdateManifest fetches it with the first query'
                }
                Write-Host ''
                Write-Host ("  Ludusavi - " + $ludNote) -ForegroundColor Cyan
                $props = @(Get-GSLudusaviProposal -Entry $unmapped -Exe $ludExe -Titles $ludMap `
                        -MinScore $MinScore -AllowManifestUpdate:$UpdateManifest -Progress {
                            param($who, $what)
                            if ($who) { Write-Verbose "ludusavi: $who - $what" } elseif ($what) { Write-Verbose "ludusavi: $what" }
                        })
                foreach ($p in $props) { Write-GSLudusaviProposal -Proposal $p }
                Write-Host ''
                Write-Info 'Nothing was written. adopt -All (or -Name <game>) puts these in the save map.'
                if ($ludMap.Count -gt 0) { Write-Info ("titles: " + (Get-GSLudusaviMapPath -Shelf $Shelf)) }
            }
        }
        Write-Host ''
    }

    'backup' {
        if (-not $Shelf) { throw 'backup needs -Shelf' }
        if (-not $All -and -not $Name -and -not $Target) { throw 'backup needs -All, -Name or -Target' }

        $shelfData = Get-GSShelf -Shelf $Shelf -SkipSize
        $map = Import-GSSaveMap -Shelf $Shelf
        if ($map.Keys.Count -eq 0) { throw "No save map at $(Get-GSSaveMapPath -Shelf $Shelf)." }
        $storePath = Get-GSSaveStore -Shelf $Shelf -Store $Store

        $items = @($shelfData.Items)
        if ($Name -or $Target) {
            $items = @(Select-GSShelfEntry -Items $shelfData.Items -Name $Name -Target $Target)
            if ($items.Count -eq 0) {
                $what = "named '$Name'"
                if ($Target) { $what = "pointing at '$Target'" }
                throw "No shelf entry $what."
            }
        }

        $done = 0; $skipped = 0; $failed = 0
        $totalBytes = [long]0; $totalFiles = 0
        foreach ($e in $items) {
            if (-not $map.ContainsKey($e.Name)) { $skipped++; continue }
            if (-not $PSCmdlet.ShouldProcess($e.Name, 'Back up saves')) { continue }
            try {
                $res = Backup-GSSave -EntryName $e.Name -Target $e.Path -RawPaths $map[$e.Name] `
                    -Store $storePath -Keep $Keep
                if ($null -eq $res) {
                    Write-Host ("  skip    {0,-40} no existing saves" -f $e.Name) -ForegroundColor DarkGray
                    $skipped++
                } else {
                    Write-Host ("  ok      {0,-40} {1,10}  {2,6} files" -f `
                            $e.Name, (Format-GSSize $res.Bytes), $res.Files) -ForegroundColor Green
                    $done++; $totalBytes += $res.Bytes; $totalFiles += $res.Files
                }
            } catch {
                Write-Host ("  FAILED  {0,-40} {1}" -f $e.Name, $_.Exception.Message) -ForegroundColor Red
                $failed++
            }
        }
        Write-Host ''
        Write-Host ("  backed up {0}   skipped {1}   failed {2}" -f $done, $skipped, $failed) -ForegroundColor Cyan
        Write-Info ("{0} across {1} files" -f (Format-GSSize $totalBytes), $totalFiles)
        Write-Info ("store : " + $storePath)
        Write-Host ''
    }

    'backups' {
        if (-not $Shelf) { throw 'backups needs -Shelf' }
        $shelfData = Get-GSShelf -Shelf $Shelf -SkipSize
        $storePath = Get-GSSaveStore -Shelf $Shelf -Store $Store

        $items = @($shelfData.Items)
        if ($Name -or $Target) {
            $items = @(Select-GSShelfEntry -Items $shelfData.Items -Name $Name -Target $Target)
            if ($items.Count -eq 0) {
                $what = "named '$Name'"
                if ($Target) { $what = "pointing at '$Target'" }
                throw "No shelf entry $what."
            }
        }

        $any = $false
        Write-Host ''
        foreach ($e in $items) {
            $found = @(Get-GSSaveBackup -EntryName $e.Name -Store $storePath)
            if ($found.Count -eq 0) { continue }
            $any = $true
            Write-Host ("  " + $e.Name) -ForegroundColor White
            foreach ($b in $found) {
                $colour = 'Gray'
                if ($b.Safe) { $colour = 'DarkYellow' }
                Write-Host ("      {0,-34} {1,10}  {2,6} files   {3}" -f `
                        $b.Id, (Format-GSSize $b.Bytes), $b.Files, $b.Kind) -ForegroundColor $colour
            }
        }
        if (-not $any) { Write-Host '  no backups yet' -ForegroundColor DarkGray }
        Write-Host ''
        Write-Info ("store : " + $storePath)
        Write-Host ''
    }

    'restore' {
        if (-not $Shelf) { throw 'restore needs -Shelf' }
        if (-not $Name -and -not $Target) { throw 'restore needs -Name or -Target' }

        $shelfData = Get-GSShelf -Shelf $Shelf -SkipSize
        $map = Import-GSSaveMap -Shelf $Shelf
        $storePath = Get-GSSaveStore -Shelf $Shelf -Store $Store

        $e = @(Select-GSShelfEntry -Items $shelfData.Items -Name $Name -Target $Target) | Select-Object -First 1
        if (-not $e) {
            $what = "named '$Name'"
            if ($Target) { $what = "pointing at '$Target'" }
            throw "No shelf entry $what."
        }
        if (-not $map.ContainsKey($e.Name)) { throw "'$($e.Name)' has no save paths configured." }

        # Not $all: the script's own -All switch is [switch], and PowerShell variable
        # names are case-insensitive, so a local $all is an assignment to that
        # parameter and throws "cannot convert to SwitchParameter".
        $allBackups = @(Get-GSSaveBackup -EntryName $e.Name -Store $storePath)
        $real = @($allBackups | Where-Object { -not $_.Safe })
        if ($real.Count -eq 0) { throw "No backup found for '$($e.Name)'." }
        $pick = $real[0]
        if ($Backup) {
            $pick = $null
            foreach ($b in $real) { if ($b.Id -eq $Backup) { $pick = $b; break } }
            if (-not $pick) { throw "Backup '$Backup' not found for '$($e.Name)'." }
        }

        Write-Host ''
        Write-Host ("  Restoring '$($e.Name)' from " + $pick.Id) -ForegroundColor Cyan
        Write-Info ("{0} / {1} files - the current saves are written aside first" -f (Format-GSSize $pick.Bytes), $pick.Files)
        if (-not $Force) {
            try {
                $go = $PSCmdlet.ShouldContinue('Overwrite the live save files with this backup?', 'Confirm restore')
            } catch {
                throw 'Non-interactive session: refusing to restore without confirmation. Re-run with -Force.'
            }
            if (-not $go) { return }
        }

        $res = Restore-GSSave -EntryName $e.Name -Target $e.Path -RawPaths $map[$e.Name] `
            -Store $storePath -BackupId $pick.Id
        Write-Ok ("{0} path(s) restored from {1}" -f $res.Restored, $res.From)
        if ($res.SafetyCopy) { Write-Info ("previous state kept at " + (Split-Path -Leaf $res.SafetyCopy)) }
        Write-Host ''
    }

    'adopt' {
        if (-not $Shelf) { throw 'adopt needs -Shelf' }
        if (-not $All -and -not $Name -and -not $Target) { throw 'adopt needs -All, -Name or -Target' }
        if ($Title -and -not $Name) { throw 'adopt -Title pins a single entry, so it needs -Name as well.' }

        $ludExe = Get-GSLudusaviExe -Exe $LudusaviExe
        if (-not $ludExe) {
            throw 'Ludusavi not found. Install it, or point at it with -LudusaviExe <path to ludusavi.exe>.'
        }

        $shelfData = Get-GSShelf -Shelf $Shelf -SkipSize
        $map = Import-GSSaveMap -Shelf $Shelf
        $ludMap = Import-GSLudusaviMap -Shelf $Shelf

        $items = @($shelfData.Items)
        if ($Name -or $Target) {
            $items = @(Select-GSShelfEntry -Items $shelfData.Items -Name $Name -Target $Target)
            if ($items.Count -eq 0) {
                $what = "named '$Name'"
                if ($Target) { $what = "pointing at '$Target'" }
                throw "No shelf entry $what."
            }
        }

        # Pinning a title is recorded whether or not it leads to paths this time:
        # it is the user telling us what the game is called, and that answer does
        # not expire.
        if ($Title) { $ludMap[$Name] = $Title }

        $todo = @($items | Where-Object { -not $map.ContainsKey($_.Name) })
        if ($todo.Count -eq 0) {
            Write-Host ''
            Write-Info 'Every selected entry is already mapped - the curated map wins, nothing to add.'
            if ($Title) {
                $n = Add-GSLudusaviMapEntry -Shelf $Shelf -Map $ludMap -WhatIf:$WhatIfPreference
                if (-not $WhatIfPreference -and $n -gt 0) {
                    Write-Ok ("recorded title: {0} -> {1}" -f $Name, $Title)
                }
            }
            Write-Host ''
            return
        }

        $info = Test-GSLudusavi -Exe $ludExe
        $ludNote = $info.Note
        if ($UpdateManifest -and -not $info.ManifestPath) {
            $ludNote = 'no manifest cached; -UpdateManifest fetches it with the first query'
        }
        Write-Host ''
        Write-Host '  GameShelf adopt - save locations Ludusavi knows' -ForegroundColor Cyan
        Write-Host ("  ludusavi: " + $ludNote) -ForegroundColor DarkGray
        Write-Host ''

        $props = @(Get-GSLudusaviProposal -Entry $todo -Exe $ludExe -Titles $ludMap `
                -MinScore $MinScore -AllowManifestUpdate:$UpdateManifest -Progress {
                    param($who, $what)
                    if ($who) { Write-Verbose "ludusavi: $who - $what" } elseif ($what) { Write-Verbose "ludusavi: $what" }
                })

        $adopted = @{}
        foreach ($p in $props) {
            Write-GSLudusaviProposal -Proposal $p -RawPaths
            if ($p.Ok) { $adopted[$p.Entry] = $p.Paths }
        }

        $paths = 0
        foreach ($k in $adopted.Keys) { $paths += @($adopted[$k]).Count }

        Write-Host ''
        if ($adopted.Count -eq 0) {
            Write-Host '  Nothing to adopt.' -ForegroundColor Yellow
            Write-Info ("-MinScore is {0:N2}; lower it to accept weaker name matches, or pin one with -Name <entry> -Title <title>." -f $MinScore)
            Write-Host ''
            return
        }

        if (-not $PSCmdlet.ShouldProcess($Shelf, "adopt $($adopted.Count) entr(ies), $paths path(s) into the save map")) {
            Write-Host ''
            return
        }

        $newEntries = Add-GSSaveMapEntry -Shelf $Shelf -Entry $adopted
        $newTitles = Add-GSLudusaviMapEntry -Shelf $Shelf -Map $ludMap
        Write-Ok ("{0} entr(ies), {1} path(s) added to the save map" -f $newEntries, $paths)
        if ($newTitles -gt 0) { Write-Info ("title override(s) recorded: " + (Get-GSLudusaviMapPath -Shelf $Shelf)) }
        Write-Info ("map   : " + (Get-GSSaveMapPath -Shelf $Shelf))
        Write-Info 'Review it, then: backup -Shelf <folder> -All'
        Write-Host ''
    }

    'playnite' {
        if ($Install) {
            $src = Join-Path $PSScriptRoot 'integrations\playnite\GameShelf'
            if (-not (Test-Path -LiteralPath $src)) { throw "Bundled extension not found: $src" }
            # Not $root: this script's own -Root parameter is [string[]], and
            # PowerShell variable names are case-insensitive, so assigning to
            # $root would silently retype that parameter and then fail to bind
            # back into a [string] parameter further down. Same trap as the $all
            # and $name locals noted below.
            $extRoot = Get-GSPlayniteExtensionRoot -Root $PlayniteRoot
            $res = Install-GSPlayniteExtension -Source $src -Root $extRoot -Force:$Force -WhatIf:$WhatIfPreference
            if ($WhatIfPreference) { return }
            Write-Host ''
            Write-Ok ("extension '{0}' installed" -f $res.Id)
            Write-Info ("{0} file(s) in {1}" -f $res.Files, $res.Path)
            if ($env:APPDATA) {
                $settings = Write-GSPlayniteSettingsTemplate -Cli (Join-Path $PSScriptRoot 'gameshelf.cmd')
                Write-Info ("settings : " + $settings)
            }
            Write-Host ''
            Write-Info 'Restart Playnite, then: Extensions > GameShelf > Export library'
            Write-Host ''
            return
        }

        $export = Get-GSPlayniteExportPath -File $File
        if (-not $export -or -not (Test-Path -LiteralPath $export -PathType Leaf)) {
            throw ("No Playnite export at '$export'. Run 'playnite -Install', start Playnite and use " +
                "'Export library for GameShelf' from its main menu, or pass a copy with -File <json>.")
        }

        $lib = Import-GSPlayniteLibrary -Path $export
        $stamp = ''
        if ($lib.Generated) { $stamp = ' exported ' + $lib.Generated }
        if ($lib.PlayniteVersion) { $stamp += ' (Playnite ' + $lib.PlayniteVersion + ')' }

        Write-Host ''
        Write-Host ("  Playnite library: {0} game(s)" -f $lib.Games.Count) -ForegroundColor Cyan
        if ($stamp) { Write-Info $stamp.Trim() }

        if ($Shelf) {
            $m = Get-GSPlayniteMatch -Shelf $Shelf -Games $lib.Games
            Write-Host ''
            Write-Host ("  {0} of {1} shelf entries matched a Playnite game" -f $m.Matched, $m.Total) -ForegroundColor White

            $loose = @($m.OnShelf | Where-Object { $_.Matched -and $_.MatchKind -eq 'name' })
            foreach ($r in $loose) {
                Write-Host ("    name match  {0} -> {1}" -f $r.Name, $r.Game.Name) -ForegroundColor DarkYellow
            }
            # Capped: on a shelf of 60 games against a library of 4, an uncapped
            # list buries the two lines above it that anyone actually asked for.
            $show = 15
            $unmatched = @($m.OnShelf | Where-Object { -not $_.Matched })
            if ($unmatched.Count -gt 0) {
                Write-Host ''
                Write-Host '  on the shelf, not in Playnite:' -ForegroundColor DarkYellow
                foreach ($r in ($unmatched | Select-Object -First $show)) {
                    Write-Host ("    " + $r.Name) -ForegroundColor DarkYellow
                }
                if ($unmatched.Count -gt $show) { Write-Info ("and $($unmatched.Count - $show) more") }
            }
            $absent = @($m.Unmatched | Where-Object { $_.IsInstalled })
            if ($absent.Count -gt 0) {
                Write-Host ''
                Write-Host '  installed in Playnite, not on the shelf:' -ForegroundColor DarkYellow
                foreach ($g in ($absent | Sort-Object Name | Select-Object -First $show)) {
                    $hours = '{0:N1} h' -f ($g.PlaytimeSeconds / 3600.0)
                    Write-Host ("    {0,-40} {1,8}" -f $g.Name, $hours) -ForegroundColor DarkYellow
                }
                if ($absent.Count -gt $show) { Write-Info ("and $($absent.Count - $show) more") }
            }
        }

        if ($Out) {
            $items = @(New-GSPlayniteManifest -Games $lib.Games -CategorySource $CategorySource `
                    -OnlyInstalled:$OnlyInstalled -SkipLauncherManaged:$SkipLauncherManaged)
            Write-Host ''
            if ($items.Count -eq 0) {
                Write-Warn2 'Nothing to write: every game was filtered out.'
                Write-Info 'A game needs an install folder; -OnlyInstalled and -SkipLauncherManaged remove more.'
                Write-Info ("This library has {0} game(s) in total." -f $lib.Games.Count)
            } else {
                Export-GSManifest -Path $Out -Items $items -Meta @{
                    generated = (Get-Date -Format 's')
                    source    = 'playnite'
                    note      = 'Draft from the Playnite library. Set the category column to your own grouping, then run build.'
                }
                Write-Ok ("draft manifest written: {0}" -f $Out)
                Write-Info ("{0} entries, categories from {1}" -f $items.Count, $CategorySource)
                Write-Info 'Delete what you do not want on the shelf, then build -Manifest <file>.'
            }
        }

        if (-not $Shelf -and -not $Out) {
            Write-Host ''
            $byCat = @(New-GSPlayniteManifest -Games $lib.Games -CategorySource $CategorySource -OnlyInstalled:$OnlyInstalled)
            foreach ($group in ($byCat | Group-Object Category | Sort-Object Count -Descending | Select-Object -First 12)) {
                Write-Host ("    {0,-28} {1,4}" -f $group.Name, $group.Count) -ForegroundColor Gray
            }
            Write-Host ''
            Write-Info ("{0} of {1} games have an install folder" -f $byCat.Count, $lib.Games.Count)
            Write-Info 'Next: -Out draft.txt to draft a manifest, or -Shelf <folder> to compare with a shelf.'
        }
        Write-Host ''
    }

    'roots' {
        if (-not $Shelf) { throw 'roots needs -Shelf' }

        if ($Set) {
            # "label=folder,label=folder" as well as an array: cmd.exe and
            # `powershell -File` (which is what gameshelf.cmd uses) hand the whole
            # thing over as one string, so the array syntax only works from a
            # PowerShell prompt. Only split when every part looks like label=folder,
            # so a root whose path contains a comma survives.
            $pairs = New-Object System.Collections.Generic.List[string]
            foreach ($raw in $Set) {
                $parts = @($raw -split ',')
                $allPairs = ($parts.Count -gt 1) -and (@($parts | Where-Object { $_ -notmatch '=' }).Count -eq 0)
                if ($allPairs) { foreach ($p in $parts) { $pairs.Add($p) } }
                else { $pairs.Add($raw) }
            }

            $bound = Import-GSRoots -Shelf $Shelf
            $n = 0
            foreach ($pair in $pairs) {
                $i = $pair.IndexOf('=')
                if ($i -lt 1) { throw "roots -Set takes <label>=<folder>, got '$pair'." }
                $rootLabel = $pair.Substring(0, $i).Trim()
                $dir = $pair.Substring($i + 1).Trim().TrimEnd('\')
                if ($rootLabel -eq '' -or $dir -eq '') { throw "roots -Set takes <label>=<folder>, got '$pair'." }
                if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "Not a folder: $dir" }
                $bound[$rootLabel] = $dir
                $n++
            }
            if (-not $WhatIfPreference) {
                # On a fresh machine the shelf folder may not exist yet, and the
                # roots file is exactly what build needs before it can make anything.
                if (-not (Test-Path -LiteralPath $Shelf)) {
                    New-Item -ItemType Directory -Path $Shelf -Force | Out-Null
                }
                Export-GSRoots -Shelf $Shelf -Roots $bound
            }
            Write-Host ''
            Write-Ok ("{0} root(s) written to {1}" -f $n, (Get-GSRootsPath -Shelf $Shelf))
        }

        if ($Portable) {
            $conv = ConvertTo-GSPortableShelf -Shelf $Shelf -WhatIf:$WhatIfPreference
            Write-Host ''
            if ($conv.Changed -eq 0) {
                Write-Ok ("Nothing to convert: {0} entr(ies), none under a bound root." -f $conv.Total)
            } else {
                Write-Host ("  {0} target(s) can become portable:" -f $conv.Changed) -ForegroundColor White
                foreach ($c in ($conv.Items | Select-Object -First 15)) {
                    Write-Host ("    {0,-40} {1}" -f $c.Name, $c.Target) -ForegroundColor Gray
                }
                if ($conv.Changed -gt 15) { Write-Info ("and $($conv.Changed - 15) more") }
                Write-Host ''
                if ($conv.Written) {
                    Write-Ok ("{0} target(s) recorded as portable" -f $conv.Changed)
                    Write-Info 'The junctions are untouched - only _shelf.txt was rewritten.'
                }
            }
            Write-Host ''
        }

        # What the manifest asks for, and what this machine has bound.
        $bound = Import-GSRoots -Shelf $Shelf
        $wanted = @{}
        $mapPath = Join-Path $Shelf '_shelf.txt'
        if (Test-Path -LiteralPath $mapPath) {
            foreach ($i in (Import-GSManifest -Path $mapPath)) {
                $r = Resolve-GSTarget -Target $i.Target
                if (-not $r.Label) { continue }
                if ($r.Why -ne 'shelf root' -and -not $r.Unresolved) { continue }
                if (-not $wanted.ContainsKey($r.Label)) { $wanted[$r.Label] = 0 }
                $wanted[$r.Label]++
            }
        }

        Write-Host ''
        Write-Host ("  GameShelf roots - " + $Shelf) -ForegroundColor Cyan
        Write-Host ("  " + (Get-GSRootsPath -Shelf $Shelf)) -ForegroundColor DarkGray
        Write-Host ''
        $labels = @($bound.Keys + $wanted.Keys | Sort-Object -Unique)
        if ($labels.Count -eq 0) {
            Write-Info 'none bound, and no target in the manifest uses one.'
        }
        foreach ($l in $labels) {
            $used = 0
            if ($wanted.ContainsKey($l)) { $used = $wanted[$l] }
            if ($bound.ContainsKey($l)) {
                $exists = Test-Path -LiteralPath $bound[$l] -PathType Container
                $line = "  {0,-12} {1,-44} {2} entr(ies)" -f $l, $bound[$l], $used
                if ($exists) { Write-Host $line -ForegroundColor White }
                else { Write-Host ($line + '   <- folder is missing here') -ForegroundColor Yellow }
            } else {
                Write-Host ("  {0,-12} {1,-44} {2} entr(ies)" -f $l, '(not bound)', $used) -ForegroundColor Yellow
            }
        }
        $unbound = @($wanted.Keys | Where-Object { -not $bound.ContainsKey($_) })
        if ($unbound.Count -gt 0) {
            Write-Host ''
            Write-Info 'Bind them so this machine can build the shelf:'
            foreach ($l in $unbound) {
                Write-Info ("  gameshelf.ps1 roots -Shelf `"$Shelf`" -Set $l=<folder>")
            }
        }
        Write-Host ''
    }

    'sync' {
        if (-not $Shelf) { throw 'sync needs -Shelf' }

        if ($Unregister) {
            $off = Unregister-GSSyncTask -TaskName $TaskName -WhatIf:$WhatIfPreference
            Write-Host ''
            if (-not $off.Found) { Write-Info ("no scheduled task named '" + $TaskName + "'") }
            elseif ($off.Removed) { Write-Ok ("scheduled task '" + $TaskName + "' removed") }
            Write-Host ''
            return
        }

        # Which roots to scan: what was asked for, else every root this machine has
        # bound. %label% is accepted anywhere a folder is, so a scheduled task can
        # say %main% and stay valid whatever the drive is called here.
        $bound = Import-GSRoots -Shelf $Shelf
        $scanRoots = @()
        if ($Root) { $scanRoots = @($Root) }
        else { foreach ($k in ($bound.Keys | Sort-Object)) { $scanRoots += ('%' + $k + '%') } }

        if ($Label -and $Root -and @($Root).Count -eq 1 -and $Root[0] -notmatch '^%') {
            # -Label names the root being scanned, so new targets come out portable.
            $dir = (Resolve-Path -LiteralPath $Root[0]).Path
            $bound[$Label] = $dir
            $scanRoots = @('%' + $Label + '%')
            if (-not $WhatIfPreference) { Export-GSRoots -Shelf $Shelf -Roots $bound }
        }

        if ($scanRoots.Count -eq 0) {
            throw ("sync needs somewhere to look. Pass -Root <folder> (or -Root %label%)," + "`n" +
                "or bind a root first:  gameshelf.ps1 roots -Shelf `"$Shelf`" -Set main=<folder>")
        }

        $res = Invoke-GSSync -Shelf $Shelf -Root $scanRoots -Category $Category -Depth $Depth `
            -MinSizeGB $MinSizeGB -SkipSize:$SkipSize

        Write-Host ''
        Write-Host ("  Scanned {0} root(s): {1} already on the shelf, {2} skipped as launcher libraries" -f `
                $res.Roots, $res.Known, $res.Ignored) -ForegroundColor Cyan
        Write-Host ''

        if ($res.Added.Count -eq 0) {
            Write-Ok 'Nothing new.'
        } else {
            Write-Host ("  {0} new game(s):" -f $res.Added.Count) -ForegroundColor White
            foreach ($a in $res.Added) {
                Write-Host ("    {0,-44} {1}" -f $a.Name, $a.Target)
            }
            Write-Host ''
            $built = New-GSShelf -Shelf $Shelf -Items $res.Added -Mode Link `
                -WhatIf:$WhatIfPreference -Confirm:$false
            if (-not $WhatIfPreference) {
                Write-Ok ("{0} entr(ies) added under '{1}'" -f $built.Created, $Category)
                if ($built.Failed -gt 0) { Write-Warn2 ("{0} could not be placed" -f $built.Failed) }
                Write-Info ("review the category: " + (Join-Path $Shelf $Category))
            }
        }
        if ($res.Broken -gt 0) {
            Write-Info ("{0} entr(ies) on the shelf point at a folder that is gone - run verify" -f $res.Broken)
        }

        if ($Commit) {
            $msg = 'Shelf: sync'
            if ($res.Added.Count -gt 0) { $msg = 'Shelf: sync (+{0} game(s))' -f $res.Added.Count }
            $git = Invoke-GSShelfCommit -Shelf $Shelf -Message $msg -Push:$Push -WhatIf:$WhatIfPreference
            Write-Host ''
            if ($git.IgnoreWritten) { Write-Info 'wrote .gitignore (ignore everything, allow the shelf text back)' }
            if (-not $git.Committed) {
                Write-Info 'no changes to commit'
            } else {
                Write-Ok ("committed {0} file(s)" -f $git.Changed.Count)
                if ($Push -and -not $git.Pushed) { Write-Info 'nothing to push to (no git remote)' }
                elseif ($git.Pushed) { Write-Ok 'pushed' }
            }
        }

        if ($Register) {
            $task = Register-GSSyncTask -Shelf $Shelf -Cli (Join-Path $PSScriptRoot 'gameshelf.ps1') `
                -Root $scanRoots -At $At -Push:$Push -TaskName $TaskName -WhatIf:$WhatIfPreference
            Write-Host ''
            if ($task.Registered) {
                Write-Ok ("scheduled task '{0}' will sync daily at {1}" -f $task.Task, $task.At)
                if (-not $Commit) { Write-Warn2 'the task runs without -Commit, so it will only report' }
            }
            Write-Info ("remove it with: gameshelf.ps1 sync -Shelf `"$Shelf`" -Unregister")
        }
        Write-Host ''
    }
}
