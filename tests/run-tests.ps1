<#
.SYNOPSIS
    Dependency-free test suite for GameShelf. No Pester required.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\GameShelf.psm1') -Force

$script:Pass = 0
$script:Fail = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Pass++
        Write-Host ("  PASS  " + $Name) -ForegroundColor Green
    } catch {
        $script:Fail++
        $script:Failures.Add($Name + ' :: ' + $_.Exception.Message)
        Write-Host ("  FAIL  " + $Name) -ForegroundColor Red
        Write-Host ("        " + $_.Exception.Message) -ForegroundColor DarkGray
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message = 'assertion failed')
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = '')
    if ($Expected -ne $Actual) {
        throw ("expected <{0}> but got <{1}> {2}" -f $Expected, $Actual, $Message)
    }
}

# ---------------------------------------------------------------- sandbox

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('gameshelf_test_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$sources = Join-Path $sandbox 'sources'
$shelf = Join-Path $sandbox 'shelf'
New-Item -ItemType Directory -Path $sources -Force | Out-Null

function New-FakeGame {
    param([string]$Name, [string]$Marker = 'unity')
    $p = Join-Path $sources $Name
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    switch ($Marker) {
        'unity' {
            Set-Content -LiteralPath (Join-Path $p 'UnityPlayer.dll') -Value 'x'
            New-Item -ItemType Directory -Path (Join-Path $p 'Game_Data') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $p 'Game.exe') -Value 'x'
        }
        'gamemaker' {
            Set-Content -LiteralPath (Join-Path $p 'data.win') -Value 'x'
            Set-Content -LiteralPath (Join-Path $p 'runner.exe') -Value 'x'
        }
        'kirikiri' {
            Set-Content -LiteralPath (Join-Path $p 'data.xp3') -Value 'x'
            Set-Content -LiteralPath (Join-Path $p 'game.exe') -Value 'x'
        }
        'media' {
            foreach ($i in 1..12) {
                Set-Content -LiteralPath (Join-Path $p ("clip$i.mp4")) -Value 'x'
            }
            foreach ($i in 1..6) {
                Set-Content -LiteralPath (Join-Path $p ("img$i.jpg")) -Value 'x'
            }
        }
        'empty' { }
    }
    return $p
}

New-FakeGame -Name 'Hollow Knight' | Out-Null
New-FakeGame -Name 'A1130' -Marker 'gamemaker' | Out-Null
New-FakeGame -Name '終の空' -Marker 'kirikiri' | Out-Null
New-FakeGame -Name 'Some Video Dump' -Marker 'media' | Out-Null
New-FakeGame -Name 'Empty Folder' -Marker 'empty' | Out-Null

Write-Host ''
Write-Host 'GameShelf test suite' -ForegroundColor Cyan
Write-Host "sandbox: $sandbox" -ForegroundColor DarkGray
Write-Host ''

# ---------------------------------------------------------------- manifest

Write-Host 'manifest' -ForegroundColor White

Test-Case 'manifest round-trips through pipe format' {
    $items = @(
        [pscustomobject]@{ Category = 'Action'; Name = 'Hollow Knight'; Target = (Join-Path $sources 'Hollow Knight'); Note = 'note one' }
        [pscustomobject]@{ Category = 'Visual Novel'; Name = '終の空'; Target = (Join-Path $sources '終の空'); Note = '' }
    )
    $mf = Join-Path $sandbox 'm1.txt'
    Export-GSManifest -Path $mf -Items $items -Meta @{ mode = 'Link' }
    $back = Import-GSManifest -Path $mf
    Assert-Equal 2 $back.Count
    Assert-Equal 'Hollow Knight' $back[0].Name
    Assert-Equal '終の空' $back[1].Name 'non-ASCII names must survive'
    Assert-Equal 'Action' $back[0].Category
}

Test-Case 'manifest metadata header is readable' {
    $meta = Get-GSManifestMeta -Path (Join-Path $sandbox 'm1.txt')
    Assert-Equal 'Link' $meta['mode']
}

Test-Case 'malformed manifest lines are skipped, not fatal' {
    $mf = Join-Path $sandbox 'm2.txt'
    @('garbage-without-pipes', 'Cat|Name|C:\somewhere', '# comment', '') |
    Set-Content -LiteralPath $mf -Encoding UTF8
    $back = Import-GSManifest -Path $mf
    Assert-Equal 1 $back.Count
    Assert-Equal 'Name' $back[0].Name
}

Test-Case 'CSV manifest is accepted' {
    $mf = Join-Path $sandbox 'm3.csv'
    @('category,name,target,note', 'RPG,Test Game,C:\games\test,hello') |
    Set-Content -LiteralPath $mf -Encoding UTF8
    $back = Import-GSManifest -Path $mf
    Assert-Equal 1 $back.Count
    Assert-Equal 'RPG' $back[0].Category
    Assert-Equal 'hello' $back[0].Note
}

Test-Case 'missing manifest throws' {
    $threw = $false
    try { Import-GSManifest -Path (Join-Path $sandbox 'nope.txt') } catch { $threw = $true }
    Assert-True $threw 'should have thrown'
}

# ---------------------------------------------------------------- links

Write-Host ''
Write-Host 'junctions' -ForegroundColor White

Test-Case 'junction is created and resolves to the target' {
    $src = Join-Path $sources 'Hollow Knight'
    $lnk = Join-Path $sandbox 'link1'
    $resolved = New-GSLink -LinkPath $lnk -TargetPath $src
    Assert-True (Test-GSLink -Path $lnk) 'should be a reparse point'
    Assert-True (Test-Path -LiteralPath (Join-Path $lnk 'Game.exe')) 'contents must be reachable through the link'
    Assert-Equal $src $resolved
}

Test-Case 'link target can be read back' {
    $t = Get-GSLinkTarget -Path (Join-Path $sandbox 'link1')
    Assert-Equal (Join-Path $sources 'Hollow Knight') $t
}

Test-Case 'removing a link leaves the target untouched' {
    $src = Join-Path $sources 'Hollow Knight'
    $lnk = Join-Path $sandbox 'link1'
    $r = Remove-GSLink -LinkPath $lnk
    Assert-Equal 'removed' $r
    Assert-True (-not (Test-Path -LiteralPath $lnk)) 'link should be gone'
    Assert-True (Test-Path -LiteralPath (Join-Path $src 'Game.exe')) 'target data must survive'
}

Test-Case 'Remove-GSLink refuses to delete a real folder' {
    $real = Join-Path $sandbox 'realdir'
    New-Item -ItemType Directory -Path $real -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $real 'keep.txt') -Value 'precious'
    $threw = $false
    try { Remove-GSLink -LinkPath $real } catch { $threw = $true }
    Assert-True $threw 'must refuse a non-junction'
    Assert-True (Test-Path -LiteralPath (Join-Path $real 'keep.txt')) 'must not have deleted anything'
}

Test-Case 'creating a link over an existing path throws' {
    $lnk = Join-Path $sandbox 'link2'
    New-GSLink -LinkPath $lnk -TargetPath (Join-Path $sources 'A1130') | Out-Null
    $threw = $false
    try { New-GSLink -LinkPath $lnk -TargetPath (Join-Path $sources 'A1130') } catch { $threw = $true }
    Assert-True $threw 'duplicate link creation should throw'
    Remove-GSLink -LinkPath $lnk | Out-Null
}

Test-Case 'size of a junction-backed folder is not double counted' {
    $one = Get-GSFolderSize -Path (Join-Path $sources 'Hollow Knight')
    $lnk = Join-Path $sandbox 'link3'
    New-GSLink -LinkPath $lnk -TargetPath (Join-Path $sources 'Hollow Knight') | Out-Null
    $via = Get-GSFolderSize -Path $lnk
    Assert-Equal $one.Bytes $via.Bytes
    Assert-Equal $one.Files $via.Files
    Remove-GSLink -LinkPath $lnk | Out-Null
}

# ---------------------------------------------------------------- detection

Write-Host ''
Write-Host 'game detection' -ForegroundColor White

Test-Case 'Unity game scores high' {
    $s = Get-GSGameSignal -Path (Join-Path $sources 'Hollow Knight')
    Assert-True ($s.Score -ge 5) "expected >=5, got $($s.Score)"
}

Test-Case 'GameMaker game is detected' {
    $s = Get-GSGameSignal -Path (Join-Path $sources 'A1130')
    Assert-True ($s.Score -ge 2) "expected >=2, got $($s.Score)"
}

Test-Case 'KiriKiri galgame is detected' {
    $s = Get-GSGameSignal -Path (Join-Path $sources '終の空')
    Assert-True ($s.Score -ge 2) "expected >=2, got $($s.Score)"
}

Test-Case 'a pure media dump is rejected' {
    $s = Get-GSGameSignal -Path (Join-Path $sources 'Some Video Dump')
    Assert-True ($s.Score -lt 2) "media folder should not qualify, got $($s.Score)"
}

Test-Case 'an empty folder is rejected' {
    $s = Get-GSGameSignal -Path (Join-Path $sources 'Empty Folder')
    Assert-True ($s.Score -lt 2) "empty folder should not qualify, got $($s.Score)"
}

Test-Case 'scan finds the games and skips the media dump' {
    $found = Invoke-GSScan -Root $sources -Depth 2 -MinSizeGB 0 -SkipSize
    $names = @($found | ForEach-Object { $_.Name })
    Assert-True ($names -contains 'Hollow Knight') 'should find Hollow Knight'
    Assert-True ($names -contains 'A1130') 'should find A1130'
    Assert-True ($names -contains '終の空') 'should find 終の空'
    Assert-True (-not ($names -contains 'Some Video Dump')) 'should skip the media dump'
    Assert-True (-not ($names -contains 'Empty Folder')) 'should skip the empty folder'
}

# ---------------------------------------------------------------- shelf

Write-Host ''
Write-Host 'shelf lifecycle' -ForegroundColor White

Test-Case 'build creates the tree, the manifest and the index' {
    $mf = Join-Path $sandbox 'build.txt'
    @(
        "Action|Hollow Knight|$(Join-Path $sources 'Hollow Knight')|reviewed",
        "Indie|A1130|$(Join-Path $sources 'A1130')|",
        "Visual Novel|終の空|$(Join-Path $sources '終の空')|18+"
    ) | Set-Content -LiteralPath $mf -Encoding UTF8

    $res = New-GSShelf -Manifest $mf -Shelf $shelf -Mode Link -Confirm:$false
    Assert-Equal 3 $res.Created
    Assert-Equal 0 $res.Failed
    Assert-True (Test-Path -LiteralPath (Join-Path $shelf '_shelf.txt')) 'shelf manifest must exist'
    Assert-True (Test-Path -LiteralPath (Join-Path $shelf 'Action\Hollow Knight\Game.exe')) 'link must resolve'
}

Test-Case 'build is idempotent' {
    $mf = Join-Path $sandbox 'build.txt'
    $res = New-GSShelf -Manifest $mf -Shelf $shelf -Mode Link -Confirm:$false
    Assert-Equal 0 $res.Created
    Assert-Equal 3 $res.Skipped
}

Test-Case 'build skips a missing target without failing the run' {
    $mf = Join-Path $sandbox 'build2.txt'
    @(
        "Action|Hollow Knight|$(Join-Path $sources 'Hollow Knight')|",
        "Action|Ghost|$(Join-Path $sources 'does-not-exist')|"
    ) | Set-Content -LiteralPath $mf -Encoding UTF8
    $res = New-GSShelf -Manifest $mf -Shelf $shelf -Mode Link -Confirm:$false
    Assert-Equal 0 $res.Created
    Assert-Equal 1 $res.Skipped
    Assert-Equal 1 $res.Failed
    Assert-Equal 2 $res.Kept 'entries from the earlier manifest must be kept'
    Assert-Equal 3 $res.OnShelf
}

Test-Case 'a second manifest merges instead of wiping the shelf' {
    $data = Get-GSShelf -Shelf $shelf -SkipSize
    Assert-Equal 3 $data.Items.Count
}

Test-Case 'build -Replace makes the manifest the single source of truth' {
    $mf = Join-Path $sandbox 'build2.txt'
    $res = New-GSShelf -Manifest $mf -Shelf $shelf -Mode Link -Replace -Confirm:$false
    Assert-Equal 0 $res.Kept
    Assert-Equal 1 $res.OnShelf
    # put the full manifest back for the tests that follow
    New-GSShelf -Manifest (Join-Path $sandbox 'build.txt') -Shelf $shelf -Mode Link -Replace -Confirm:$false | Out-Null
    $data = Get-GSShelf -Shelf $shelf -SkipSize
    Assert-Equal 3 $data.Items.Count
}

Test-Case 'shelf reads back with per-entry status' {
    $data = Get-GSShelf -Shelf $shelf -SkipSize
    Assert-Equal 3 $data.Items.Count
    Assert-Equal 'Link' $data.Mode
    foreach ($i in $data.Items) { Assert-Equal 'Link' $i.Status }
}

Test-Case 'verify reports a healthy shelf' {
    $res = Test-GSShelf -Shelf $shelf
    Assert-Equal 3 $res.Total
    Assert-Equal 0 $res.Bad
}

Test-Case 'verify catches a broken link' {
    $brokenTarget = Join-Path $sources 'Breakable'
    New-FakeGame -Name 'Breakable' | Out-Null
    $mf = Join-Path $sandbox 'build3.txt'
    "Action|Breakable|$brokenTarget|" | Set-Content -LiteralPath $mf -Encoding UTF8
    $r2 = New-GSShelf -Manifest $mf -Shelf (Join-Path $sandbox 'shelf2') -Mode Link -Confirm:$false
    Assert-Equal 1 $r2.Created
    Remove-Item -LiteralPath $brokenTarget -Recurse -Force
    $res = Test-GSShelf -Shelf (Join-Path $sandbox 'shelf2')
    Assert-Equal 1 $res.Bad
}

Test-Case 'index writes Markdown and CSV with the right totals' {
    $res = Export-GSIndex -Shelf $shelf
    Assert-Equal 3 $res.Items
    Assert-True (Test-Path -LiteralPath $res.Markdown) 'CATALOG.md must exist'
    Assert-True (Test-Path -LiteralPath $res.Csv) 'index.csv must exist'
    $md = Get-Content -LiteralPath $res.Markdown -Raw -Encoding UTF8
    Assert-True ($md -match 'Hollow Knight') 'catalogue should list the game'
    Assert-True ($md -match '終の空') 'catalogue should preserve non-ASCII'
    $rows = @(Import-Csv -LiteralPath $res.Csv)
    Assert-Equal 3 $rows.Count
}

Test-Case 'remove -Name removes exactly one junction' {
    $res = Remove-GSShelf -Shelf $shelf -Name 'A1130' -Confirm:$false
    Assert-Equal 1 $res.Removed
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $shelf 'Indie\A1130'))) 'link should be gone'
    Assert-True (Test-Path -LiteralPath (Join-Path $sources 'A1130\data.win')) 'target data must survive'
}

Test-Case 'remove -Name drops the entry from the shelf manifest' {
    $data = Get-GSShelf -Shelf $shelf -SkipSize
    $names = @($data.Items | Select-Object -ExpandProperty Name)
    Assert-True (-not ($names -contains 'A1130')) 'A1130 should no longer be listed'
    Assert-Equal 2 $data.Items.Count
}

Test-Case 'remove -All clears junctions, keeps the data' {
    $res = Remove-GSShelf -Shelf $shelf -All -Confirm:$false
    Assert-Equal 2 $res.Removed 'two links left after the -Name test'
    Assert-Equal 0 $res.Absent
    Assert-True (Test-Path -LiteralPath (Join-Path $sources 'Hollow Knight\Game.exe')) 'data survives'
}

Test-Case 'remove refuses on a Move-mode shelf' {
    $mv = Join-Path $sandbox 'moveshelf'
    $mf = Join-Path $sandbox 'build4.txt'
    "Action|Hollow Knight|$(Join-Path $sources 'Hollow Knight')|" | Set-Content -LiteralPath $mf -Encoding UTF8
    New-GSShelf -Manifest $mf -Shelf $mv -Mode Move -Confirm:$false | Out-Null
    $threw = $false
    try { Remove-GSShelf -Shelf $mv -All -Confirm:$false } catch { $threw = $true }
    Assert-True $threw 'must refuse to delete real folders'
    Assert-True (Test-Path -LiteralPath (Join-Path $mv 'Action\Hollow Knight\Game.exe')) 'moved data still there'
    New-FakeGame -Name 'Hollow Knight' | Out-Null
}

Test-Case 'list output shape is stable' {
    $mf = Join-Path $sandbox 'build.txt'
    New-GSShelf -Manifest $mf -Shelf $shelf -Mode Link -Confirm:$false | Out-Null
    $data = Get-GSShelf -Shelf $shelf -SkipSize
    Assert-Equal 3 $data.Items.Count
    $cats = @($data.Items | Select-Object -ExpandProperty Category | Sort-Object -Unique)
    Assert-Equal 3 $cats.Count
}

# ---------------------------------------------------------------- saves

Write-Host ''
Write-Host 'save data' -ForegroundColor White

$saveStore = Join-Path $sandbox 'savestore'

Test-Case 'save map round-trips' {
    $mf = Join-Path $shelf '_saves.txt'
    Export-GSSaveMap -Shelf $shelf -Map @{
        'Hollow Knight' = @('%APPDATA%\TeamCherry', 'GAME\profile')
        'A1130'         = @('GAME\save')
    }
    Assert-True (Test-Path -LiteralPath $mf) 'map file must exist'
    $back = Import-GSSaveMap -Shelf $shelf
    Assert-Equal 2 $back.Keys.Count
    Assert-Equal 2 @($back['Hollow Knight']).Count
    Assert-Equal 'GAME\save' @($back['A1130'])[0]
}

Test-Case 'a missing save map is empty, not an error' {
    $tmp = Join-Path $sandbox 'noshelf'
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $m = Import-GSSaveMap -Shelf $tmp
    Assert-Equal 0 $m.Keys.Count
}

Test-Case 'GAME\ resolves against the game folder' {
    $p = Resolve-GSSavePath -Raw 'GAME\profile' -Target 'D:\games\HK'
    Assert-Equal 'D:\games\HK\profile' $p
}

Test-Case 'environment tokens expand without doubling backslashes' {
    $p = Resolve-GSSavePath -Raw '%APPDATA%\Foo\Bar' -Target 'D:\games\X'
    Assert-True ($p.StartsWith($env:APPDATA)) 'must start with APPDATA'
    Assert-True ($p -notmatch '\\\\') "backslashes must not be doubled, got: $p"
    Assert-True ($p.EndsWith('\Foo\Bar')) 'tail must survive'
}

Test-Case 'Get-GSSaveTarget reports existence' {
    $dir = Join-Path $sandbox 'savesrc'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'a.dat') -Value 'x'
    $t = @(Get-GSSaveTarget -Target $sandbox -RawPaths @('savesrc', 'nope'))
    Assert-Equal 2 $t.Count
    Assert-True $t[0].Exists 'first must exist'
    Assert-True (-not $t[1].Exists) 'second must not'
    Assert-Equal 'Folder' $t[0].Kind
    Assert-Equal 'Missing' $t[1].Kind
}

Test-Case 'Get-GSFileStat counts files and bytes' {
    $s = Get-GSFileStat -Path (Join-Path $sandbox 'savesrc')
    Assert-Equal 1 $s.Files
    Assert-True ($s.Bytes -gt 0) 'bytes must be counted'
}

Test-Case 'backing up captures the saves and a manifest' {
    $res = Backup-GSSave -EntryName 'SavedGame' -Target $sandbox -RawPaths @('savesrc') -Store $saveStore
    Assert-True ($null -ne $res) 'must return a result'
    Assert-Equal 1 $res.Files
    Assert-True (Test-Path -LiteralPath (Join-Path $res.Backup 'p0\a.dat')) 'file must be copied'
    Assert-True (Test-Path -LiteralPath (Join-Path $res.Backup '_backup.txt')) 'manifest must exist'
}

Test-Case 'backing up a game with no saves returns null' {
    $res = Backup-GSSave -EntryName 'Nothing' -Target $sandbox -RawPaths @('does-not-exist') -Store $saveStore
    Assert-True ($null -eq $res) 'must be null when nothing exists'
}

Test-Case 'backups list newest first' {
    Start-Sleep -Seconds 1
    Backup-GSSave -EntryName 'SavedGame' -Target $sandbox -RawPaths @('savesrc') -Store $saveStore | Out-Null
    $all = @(Get-GSSaveBackup -EntryName 'SavedGame' -Store $saveStore)
    Assert-Equal 2 $all.Count
    Assert-True ($all[0].Id -gt $all[1].Id) 'newest must come first'
    Assert-Equal 'Backup' $all[0].Kind
    Assert-Equal 1 $all[0].Files
    Assert-True ($all[0].Bytes -gt 0) 'bytes must be recorded in the manifest'
}

Test-Case 'pruning keeps the requested number' {
    foreach ($i in 1..3) {
        Start-Sleep -Milliseconds 1100
        Backup-GSSave -EntryName 'PruneMe' -Target $sandbox -RawPaths @('savesrc') -Store $saveStore -Keep 2 | Out-Null
    }
    $all = @(Get-GSSaveBackup -EntryName 'PruneMe' -Store $saveStore)
    Assert-Equal 2 $all.Count
}

Test-Case 'restore brings the bytes back and keeps a safety copy' {
    $live = Join-Path $sandbox 'savesrc\a.dat'
    $original = [System.IO.File]::ReadAllText($live)

    $b = Backup-GSSave -EntryName 'RestoreMe' -Target $sandbox -RawPaths @('savesrc') -Store $saveStore
    [System.IO.File]::WriteAllText($live, 'CORRUPTED')
    Assert-Equal 'CORRUPTED' ([System.IO.File]::ReadAllText($live))

    $r = Restore-GSSave -EntryName 'RestoreMe' -Target $sandbox -RawPaths @('savesrc') `
        -Store $saveStore -BackupId $b.Id
    Assert-Equal 1 $r.Restored
    Assert-Equal $original ([System.IO.File]::ReadAllText($live)) 'content must match the original'
    Assert-True ($null -ne $r.SafetyCopy) 'a safety copy must be made'

    # the safety copy holds what was live at restore time, i.e. the corrupted text
    $safeFile = Join-Path $r.SafetyCopy 'p0\a.dat'
    Assert-True (Test-Path -LiteralPath $safeFile) 'safety copy must contain the file'
    Assert-Equal 'CORRUPTED' ([System.IO.File]::ReadAllText($safeFile))
}

Test-Case 'restore refuses when there is no backup' {
    $threw = $false
    try {
        Restore-GSSave -EntryName 'NeverBackedUp' -Target $sandbox -RawPaths @('savesrc') -Store $saveStore
    } catch { $threw = $true }
    Assert-True $threw 'must throw'
}

Test-Case 'save candidates find an in-game save folder' {
    $g = Join-Path $sandbox 'candgame'
    New-Item -ItemType Directory -Path (Join-Path $g 'savedata') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $g 'savedata\s.dat') -Value 'x'
    $c = @(Find-GSSaveCandidate -EntryName 'Cand Game' -Target $g)
    Assert-True ($c.Count -ge 1) 'must find the savedata folder'
    Assert-True ($c[0].Path.EndsWith('savedata')) 'first hit should be the save folder'
}

Test-Case 'shelf Items is a plain array, usable with @()' {
    # A List here makes @() throw "parameter type mismatch" for callers, even
    # though .Count and foreach work - a trap worth pinning down.
    $data = Get-GSShelf -Shelf $shelf -SkipSize
    Assert-True ($data.Items -is [array]) 'Items must be an array, not a List'
    Assert-Equal 3 (@($data.Items)).Count
}

Test-Case 'launch map reads back an entry''s executable' {
    $mf = Join-Path $shelf '_launch.txt'
    @('Hollow Knight|hollow_knight.exe', 'Some Collection|FOLDER') |
    Set-Content -LiteralPath $mf -Encoding UTF8
    $map = Import-GSLaunchMap -Shelf $shelf
    Assert-Equal 2 $map.Keys.Count
    Assert-Equal 'FOLDER' $map['Some Collection']
    # the exe does not exist in the sandbox, so the resolver returns null
    Assert-True ($null -eq (Get-GSLaunchExe -Shelf $shelf -EntryName 'Hollow Knight' -Target $sandbox)) 'missing exe resolves to null'
    Assert-True ($null -eq (Get-GSLaunchExe -Shelf $shelf -EntryName 'Some Collection' -Target $sandbox)) 'FOLDER resolves to null'
}

# ---------------------------------------------------------------- env

Write-Host ''
Write-Host 'environment' -ForegroundColor White

Test-Case 'doctor reports junction capability' {
    $checks = Test-GSEnvironment
    $jc = $checks | Where-Object { $_.Check -eq 'Junction creation' }
    Assert-True ($null -ne $jc) 'junction capability check must be present'
    Assert-True $jc.Ok "junction creation failed: $($jc.Detail)"
}

# ---------------------------------------------------------------- done

Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ("  {0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
if ($script:Fail -gt 0) {
    Write-Host ''
    foreach ($f in $script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
Write-Host ''
exit 0
