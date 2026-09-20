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
    [ValidateSet('doctor', 'scan', 'build', 'list', 'verify', 'index', 'remove', 'help')]
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

    # remove
    [string]$Name,
    [string]$Category,
    [switch]$All
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
            $name = $f.Name + $kind
            if ($name.Length -gt 41) { $name = $name.Substring(0, 38) + '...' }
            Write-Host ("  {0,-42} {1,10} {2,6}  {3}" -f $name, $gb, $f.Score, $f.Reasons)
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
}
