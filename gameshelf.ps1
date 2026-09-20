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
        'saves', 'backup', 'backups', 'restore', 'help')]
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
    [string]$Backup
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
        Write-Host '    backup  -Shelf <folder>       Copy saves into the backup store.'
        Write-Host '            -All | -Name <game>   [-Store <folder>] [-Keep 10]'
        Write-Host '    backups -Shelf <folder>       List stored backups. [-Name <game>]'
        Write-Host '    restore -Shelf <folder>       Put a backup back. [-Backup <id>] [-Force]'
        Write-Host '            -Name <game>          The live saves are kept aside first.'
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
            $label = $f.Name + $kind
            if ($label.Length -gt 41) { $label = $label.Substring(0, 38) + '...' }
            Write-Host ("  {0,-42} {1,10} {2,6}  {3}" -f $label, $gb, $f.Score, $f.Reasons)
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
            $label = "$($r.Category)\$($r.Name)"
            if ($r.Status -eq 'Link' -and $r.Readable) {
                Write-Verbose "ok $label"
            } elseif ($r.Status -ne 'Link') {
                Write-Bad ("{0,-46} {1}" -f $label, $r.Status)
            } else {
                Write-Bad ("{0,-46} not readable: {1}" -f $label, $r.Detail)
            }
        }
        Write-Host ''
        if ($res.Bad -eq 0) { Write-Host "  All $($res.Total) entries are healthy." -ForegroundColor Green }
        else { Write-Host "  $($res.Bad) of $($res.Total) entries need attention (run with -Verbose for the healthy ones)." -ForegroundColor Yellow }
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
        if ($Name) { $items = @($items | Where-Object { $_.Name -eq $Name }) }
        if ($items.Count -eq 0) { throw "No entry named '$Name'." }

        $mapped = 0; $candidates = 0; $nothing = 0
        Write-Host ''
        foreach ($e in $items) {
            $hasMap = $map.ContainsKey($e.Name)
            if ($hasMap) {
                $mapped++
                Write-Host ("  " + $e.Name) -ForegroundColor White
                foreach ($t in (Get-GSSaveTarget -Target $e.Target -RawPaths $map[$e.Name])) {
                    if ($t.Exists) {
                        $st = Get-GSFileStat -Path $t.Path
                        Write-Host ("      [ok]      {0,10}  {1,6} files  {2}" -f `
                                (Format-GSSize $st.Bytes), $st.Files, $t.Path) -ForegroundColor Green
                    } else {
                        Write-Host ("      [missing]                        " + $t.Path) -ForegroundColor DarkGray
                    }
                }
            } else {
                $exe = Get-GSLaunchExe -Shelf $Shelf -EntryName $e.Name -Target $e.Target
                $found = @(Find-GSSaveCandidate -EntryName $e.Name -Target $e.Target -ExePath $exe)
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
        Write-Host ''
    }

    'backup' {
        if (-not $Shelf) { throw 'backup needs -Shelf' }
        if (-not $All -and -not $Name) { throw 'backup needs -All or -Name' }

        $shelfData = Get-GSShelf -Shelf $Shelf -SkipSize
        $map = Import-GSSaveMap -Shelf $Shelf
        if ($map.Keys.Count -eq 0) { throw "No save map at $(Get-GSSaveMapPath -Shelf $Shelf)." }
        $storePath = Get-GSSaveStore -Shelf $Shelf -Store $Store

        $items = @($shelfData.Items)
        if ($Name) { $items = @($items | Where-Object { $_.Name -eq $Name }) }
        if ($items.Count -eq 0) { throw "No entry named '$Name'." }

        $done = 0; $skipped = 0; $failed = 0
        $totalBytes = [long]0; $totalFiles = 0
        foreach ($e in $items) {
            if (-not $map.ContainsKey($e.Name)) { $skipped++; continue }
            if (-not $PSCmdlet.ShouldProcess($e.Name, 'Back up saves')) { continue }
            try {
                $res = Backup-GSSave -EntryName $e.Name -Target $e.Target -RawPaths $map[$e.Name] `
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
        if ($Name) { $items = @($items | Where-Object { $_.Name -eq $Name }) }

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
        if (-not $Name) { throw 'restore needs -Name' }

        $shelfData = Get-GSShelf -Shelf $Shelf -SkipSize
        $map = Import-GSSaveMap -Shelf $Shelf
        $storePath = Get-GSSaveStore -Shelf $Shelf -Store $Store

        $e = @($shelfData.Items | Where-Object { $_.Name -eq $Name }) | Select-Object -First 1
        if (-not $e) { throw "No entry named '$Name'." }
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

        $res = Restore-GSSave -EntryName $e.Name -Target $e.Target -RawPaths $map[$e.Name] `
            -Store $storePath -BackupId $pick.Id
        Write-Ok ("{0} path(s) restored from {1}" -f $res.Restored, $res.From)
        if ($res.SafetyCopy) { Write-Info ("previous state kept at " + (Split-Path -Leaf $res.SafetyCopy)) }
        Write-Host ''
    }
}
