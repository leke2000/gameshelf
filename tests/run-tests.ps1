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

# ---------------------------------------------------------------- ludusavi

Write-Host ''
Write-Host 'ludusavi bridge' -ForegroundColor White

Test-Case 'process arguments are quoted the way Windows parses them' {
    Assert-Equal 'plain' (ConvertTo-GSProcessArgument -Argument 'plain')
    Assert-Equal '"two words"' (ConvertTo-GSProcessArgument -Argument 'two words')
    # real titles look like this, and the star must survive as a literal
    Assert-Equal '"Senren * Banka"' (ConvertTo-GSProcessArgument -Argument 'Senren * Banka')
    # a quote is escaped with a backslash...
    Assert-Equal '"a\"b"' (ConvertTo-GSProcessArgument -Argument 'a"b')
    # ...and a trailing backslash is doubled so it cannot escape the closing quote
    Assert-Equal '"C:\path with space\\"' (ConvertTo-GSProcessArgument -Argument 'C:\path with space\')
    Assert-Equal '""' (ConvertTo-GSProcessArgument -Argument '')
}

Test-Case 'find output is parsed into titles and scores' {
    $json = '{"games":{"Hollow Knight":{"score":1.0},"Hollow Knight Deluxe":{"score":0.42}}}'
    $m = @(ConvertFrom-GSLudusaviFind -Json $json)
    Assert-Equal 2 $m.Count
    Assert-Equal 'Hollow Knight' $m[0].Title 'the best match must come first'
    Assert-Equal 1.0 $m[0].Score
    Assert-Equal 0.42 $m[1].Score
}

Test-Case 'empty or blank find output is not an error' {
    $empty = @(ConvertFrom-GSLudusaviFind -Json '{"games":{}}')
    $blank = @(ConvertFrom-GSLudusaviFind -Json '')
    Assert-Equal 0 $empty.Count
    Assert-Equal 0 $blank.Count
}

Test-Case 'a title ludusavi has never heard of is an answer, not a failure' {
    # Verbatim from ludusavi 0.31.0 for a game it does not know: exit code 1, this
    # on stdout, "No info for these games" on stderr. A shelf with doujin games on
    # it is full of these, so the exit code alone cannot mean "something broke".
    $json = '{"errors":{"unknownGames":["Akujo no Eikan"]},"games":{}}'
    $unknown = @(Get-GSLudusaviUnknown -Json $json)
    Assert-Equal 1 $unknown.Count
    Assert-Equal 'Akujo no Eikan' $unknown[0]

    $matches = @(ConvertFrom-GSLudusaviFind -Json $json)
    Assert-Equal 0 $matches.Count 'no match, and that must not be read as one'

    $none = @(Get-GSLudusaviUnknown -Json '{"games":{}}')
    Assert-Equal 0 $none.Count 'a reply with no errors block names no unknown titles'
    $none2 = @(Get-GSLudusaviUnknown -Json '')
    Assert-Equal 0 $none2.Count
}

Test-Case 'preview output is parsed, ignored entries skipped' {
    # Built with ConvertTo-Json rather than hand-written: save paths contain
    # backslashes, which a JSON literal would need escaped.
    $roam = $env:APPDATA
    $payload = @{
        games = @{
            'Exact Game' = @{
                files    = @{
                    (Join-Path $roam 'ExactGame\slot1.sav') = @{ bytes = 10; ignored = $false }
                    (Join-Path $roam 'ExactGame\slot2.sav') = @{ bytes = 20; ignored = $false }
                    (Join-Path $roam 'ExactGame\bak\x.sav') = @{ bytes = 99; ignored = $true }
                }
                registry = @{ 'HKEY_CURRENT_USER/SOFTWARE/Exact' = @{} }
            }
        }
    }
    $p = @(ConvertFrom-GSLudusaviPreview -Json ($payload | ConvertTo-Json -Depth 8))
    Assert-Equal 1 $p.Count
    Assert-Equal 2 $p[0].Files 'the ignored file must not be counted'
    Assert-Equal 30 $p[0].Bytes 'bytes of ignored files must not be counted'
    Assert-Equal 1 @($p[0].Registry).Count
    Assert-True (-not $p[0].Unknown)
}

Test-Case 'a title ludusavi does not know is reported, not dropped' {
    $p = @(ConvertFrom-GSLudusaviPreview -Json '{"games":{},"errors":{"unknownGames":["Ghost Game"]}}')
    Assert-Equal 1 $p.Count
    Assert-True $p[0].Unknown
    Assert-Equal 'Ghost Game' $p[0].Title
    Assert-Equal 0 $p[0].Files
}

Test-Case 'sibling save files collapse onto their folder' {
    $roam = $env:APPDATA
    $c = @(Group-GSPathCluster -Paths @(
            (Join-Path $roam 'GameA\slot1.sav'),
            (Join-Path $roam 'GameA\slot2.sav'),
            (Join-Path $roam 'GameA\deep\slot3.sav')
        ) -Bytes @{ (Join-Path $roam 'GameA\slot1.sav') = 10 })
    Assert-Equal 1 $c.Count
    Assert-Equal (Join-Path $roam 'GameA') $c[0].Root
    Assert-Equal 3 $c[0].Keys
    Assert-Equal 10 $c[0].Bytes 'the size table is keyed case-insensitively'
}

Test-Case 'unrelated folders never collapse onto a token root' {
    # The guard that matters: a map entry of bare %APPDATA% would back up the
    # whole roaming profile.
    $roam = $env:APPDATA
    $c = @(Group-GSPathCluster -Paths @(
            (Join-Path $roam 'GameA\x.sav'),
            (Join-Path $roam 'GameB\y.sav')
        ))
    Assert-Equal 2 $c.Count
    Assert-Equal (Join-Path $roam 'GameA\x.sav') $c[0].Root
    Assert-True (-not (Test-GSPathIsSpecific -Path $roam)) 'a bare token root is not specific enough'
    Assert-True (Test-GSPathIsSpecific -Path (Join-Path $roam 'GameA')) 'one level below it is'
}

Test-Case 'folders on one path merge, unrelated ones do not' {
    $a = 'Q:\Saves\GameA'
    $b = 'Q:\Saves\GameA\sub'
    $c = 'Q:\Other\GameB'
    Assert-Equal 'Q:\Saves\GameA' (Get-GSPathClusterRoot -A $a -B $b)
    # only the drive is shared, and a cluster root of 'Q:\' is exactly what the
    # specificity guard then refuses to merge
    Assert-Equal 'Q:\' (Get-GSPathClusterRoot -A $a -B $c)
    Assert-Equal 'Q:\' (Get-GSPathClusterRoot -A 'Q:\x.sav' -B 'Q:\y.sav')
    # boundary aware: 'GameAB' is not inside 'GameA'
    Assert-Equal $null (Get-GSRelativeTo -Child 'Q:\GameAB' -Ancestor 'Q:\GameA')
}

Test-Case 'absolute save paths are rewritten with map tokens' {
    $roam = $env:APPDATA
    Assert-Equal '%APPDATA%\Team Cherry\Hollow Knight' `
        (ConvertTo-GSSaveMapPath -Absolute (Join-Path $roam 'Team Cherry\Hollow Knight'))
    Assert-Equal '%LOCALLOW%\Studio\Game' `
        (ConvertTo-GSSaveMapPath -Absolute (Join-Path $env:USERPROFILE 'AppData\LocalLow\Studio\Game'))
    Assert-Equal 'GAME\saves' (ConvertTo-GSSaveMapPath -Absolute 'D:\Games\GameB\saves' -Target 'D:\Games\GameB')
    Assert-Equal 'Q:\Elsewhere\saves' (ConvertTo-GSSaveMapPath -Absolute 'Q:\Elsewhere\saves' -Target 'D:\Games\GameB')
}

Test-Case 'proposals are decided from matches and previews' {
    # The decision half of the bridge, exercised without Ludusavi installed.
    $roam = $env:APPDATA
    $payload = @{
        games = @{
            'Exact Game' = @{
                files    = @{
                    (Join-Path $roam 'ExactGame\slot1.sav') = @{ bytes = 10; ignored = $false }
                    (Join-Path $roam 'ExactGame\slot2.sav') = @{ bytes = 20; ignored = $false }
                }
                registry = @{}
            }
        }
    }
    $preview = @{}
    foreach ($pv in (ConvertFrom-GSLudusaviPreview -Json ($payload | ConvertTo-Json -Depth 8))) {
        $preview[$pv.Title] = $pv
    }

    $entry = @(
        [pscustomobject]@{ Name = 'Exact Game'; Target = 'D:\Games\Exact' }
        [pscustomobject]@{ Name = 'Weak Match'; Target = 'D:\Games\Weak' }
        [pscustomobject]@{ Name = 'Silent Preview'; Target = 'D:\Games\Silent' }
        [pscustomobject]@{ Name = 'Truly Unknown'; Target = 'D:\Games\Unknown' }
        [pscustomobject]@{ Name = 'No Match At All'; Target = 'D:\Games\None' }
    )
    $match = @{
        'Exact Game'      = [pscustomobject]@{ Title = 'Exact Game'; Match = 'exact'; Score = 1.0; Candidates = 1 }
        'Weak Match'      = [pscustomobject]@{ Title = 'Exact Game'; Match = 'fuzzy'; Score = 0.4; Candidates = 3 }
        # find resolved a title the preview then said nothing about - ludusavi does
        # this for titles containing non-ASCII characters
        'Silent Preview'  = [pscustomobject]@{ Title = 'God of War Ragnar' + [char]246 + 'k'; Match = 'fuzzy'; Score = 0.92; Candidates = 1 }
        # ...whereas this one the preview explicitly reported as unknown
        'Truly Unknown'   = [pscustomobject]@{ Title = 'Ghost'; Match = 'fuzzy'; Score = 0.95; Candidates = 1 }
    }
    $preview['Ghost'] = [pscustomobject]@{
        Title = 'Ghost'; Unknown = $true; Paths = @(); Sizes = @{}
        Files = 0; Bytes = [long]0; Ignored = 0; Registry = @(); Decision = $null
    }

    $props = @(ConvertTo-GSLudusaviProposal -Entry $entry -Match $match -Preview $preview -MinScore 0.8)
    Assert-Equal 5 $props.Count

    Assert-True $props[0].Ok 'an exact match with paths is adoptable'
    Assert-Equal '%APPDATA%\ExactGame' $props[0].Paths[0] 'and its path is tokenised'
    Assert-Equal 1 $props[0].Clusters
    Assert-Equal 2 $props[0].Files

    Assert-True (-not $props[1].Ok) 'a weak fuzzy match is not adoptable'
    Assert-True ($props[1].Reason -like 'below -MinScore*') "got: $($props[1].Reason)"

    Assert-True (-not $props[2].Ok)
    Assert-True (-not $props[2].Unknown) 'a title find resolved is not an unknown title'
    Assert-True ($props[2].Reason -like 'ludusavi resolved no paths*') "got: $($props[2].Reason)"

    Assert-True (-not $props[3].Ok)
    Assert-True $props[3].Unknown 'a title the preview called unknown is flagged'
    Assert-Equal 'ludusavi does not know this title' $props[3].Reason

    Assert-True (-not $props[4].Ok)
    Assert-Equal 'no ludusavi match' $props[4].Reason
}

Test-Case 'adopting appends to the save map instead of rewriting it' {
    $tmp = Join-Path $sandbox 'adoptshelf'
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $mapFile = Join-Path $tmp '_saves.txt'
    # a hand-written map: a comment of the user's own, and an entry they curated
    @('# my own note about this map', 'Game A|GAME\save', '') |
    Set-Content -LiteralPath $mapFile -Encoding UTF8

    $n = Add-GSSaveMapEntry -Shelf $tmp -Entry @{
        'Game A' = @('%APPDATA%\ShouldNotReplace')
        'Game B' = @('%APPDATA%\GameB', 'GAME\save')
    }
    Assert-Equal 1 $n 'only the unmapped entry is appended'

    $text = [System.IO.File]::ReadAllText($mapFile, [System.Text.Encoding]::UTF8)
    Assert-True ($text -match 'my own note about this map') 'the user''s comment must survive'
    $back = Import-GSSaveMap -Shelf $tmp
    Assert-Equal 'GAME\save' ($back['Game A'] -join ';') 'the curated path must win'
    Assert-Equal '%APPDATA%\GameB;GAME\save' ($back['Game B'] -join ';')
}

Test-Case 'title overrides are appended without disturbing existing ones' {
    $tmp = Join-Path $sandbox 'adoptshelf'
    @('# pinned by hand', 'Old Game|Old Title') |
    Set-Content -LiteralPath (Join-Path $tmp '_ludusavi.txt') -Encoding UTF8

    $n = Add-GSLudusaviMapEntry -Shelf $tmp -Map @{ 'Old Game' = 'Different'; '新游戏' = 'New Game' }
    Assert-Equal 1 $n 'an entry already pinned must not be rewritten'
    $m = Import-GSLudusaviMap -Shelf $tmp
    Assert-Equal 2 $m.Keys.Count
    Assert-Equal 'Old Title' $m['Old Game']
    Assert-Equal 'New Game' $m['新游戏'] 'non-ASCII entry names must survive'
}

Test-Case 'appending keeps the file''s own line endings and BOM' {
    # A real shelf map, curated in an editor that writes LF: rewriting it as CRLF
    # turns one appended entry into a sixty-line diff, which is not what "adopt
    # only ever adds" is supposed to mean.
    $tmp = Join-Path $sandbox 'lfmap'
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $p = Join-Path $tmp '_saves.txt'
    [System.IO.File]::WriteAllText($p, "# mine`nGame A|GAME\save`n", (New-Object System.Text.UTF8Encoding($false)))

    Add-GSSaveMapEntry -Shelf $tmp -Entry @{ 'Game B' = @('%APPDATA%\B') } | Out-Null

    $bytes = [System.IO.File]::ReadAllBytes($p)
    $cr = 0
    $bom = ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    foreach ($b in $bytes) { if ($b -eq 13) { $cr++ } }
    Assert-Equal 0 $cr 'an LF file must stay LF'
    Assert-True (-not $bom) 'a file without a BOM must not gain one'

    $back = Import-GSSaveMap -Shelf $tmp
    Assert-Equal 2 $back.Keys.Count 'the new entry still lands'
    Assert-Equal '%APPDATA%\B' $back['Game B'][0]

    # and the other way round: a CRLF file stays CRLF
    $tmp2 = Join-Path $sandbox 'crlfmap'
    New-Item -ItemType Directory -Path $tmp2 -Force | Out-Null
    $p2 = Join-Path $tmp2 '_saves.txt'
    [System.IO.File]::WriteAllLines($p2, @('# mine', 'Game A|GAME\save'), (New-Object System.Text.UTF8Encoding($true)))
    Add-GSSaveMapEntry -Shelf $tmp2 -Entry @{ 'Game B' = @('GAME\b') } | Out-Null
    $text2 = [System.IO.File]::ReadAllText($p2)
    Assert-True ($text2 -match "`r`n") 'a CRLF file must stay CRLF'
}

Test-Case 'a named ludusavi.exe that does not exist is an error' {
    $threw = $false
    try { Get-GSLudusaviExe -Exe (Join-Path $sandbox 'no-such-ludusavi.exe') } catch { $threw = $true }
    Assert-True $threw 'a typo must not silently fall back to another binary'
}

Test-Case 'ludusavi is reported as optional when it is not installed' {
    $fake = Join-Path $sandbox 'ludufake'
    New-Item -ItemType Directory -Path $fake -Force | Out-Null
    # A portable install keeps its config beside the exe; the marker file decides.
    Set-Content -LiteralPath (Join-Path $fake 'ludusavi.portable') -Value 'x'
    Set-Content -LiteralPath (Join-Path $fake 'ludusavi.exe') -Value 'not really an executable'
    Set-Content -LiteralPath (Join-Path $fake 'manifest.yaml') -Value 'x'

    $info = Test-GSLudusavi -Exe (Join-Path $fake 'ludusavi.exe') -TimeoutSec 5
    Assert-True $info.Available
    Assert-Equal (Join-Path $fake 'manifest.yaml') $info.ManifestPath 'the portable marker must redirect the app folder'
    Assert-Equal 'ready' $info.Note
}

# ---------------------------------------------------------------- playnite

Write-Host ''
Write-Host 'playnite bridge' -ForegroundColor White

$plGameDir = Join-Path $sandbox 'pl_games\ByPath'
$plNameDir = Join-Path $sandbox 'pl_games\By Name Game'
New-Item -ItemType Directory -Path $plGameDir -Force | Out-Null
New-Item -ItemType Directory -Path $plNameDir -Force | Out-Null
$plShelf = Join-Path $sandbox 'pl_shelf'
$plManifest = Join-Path $sandbox 'pl.txt'
@(
    "Action|Renamed On Shelf|$plGameDir|"
    "Action|By Name Game|$plNameDir|"
) | Set-Content -LiteralPath $plManifest -Encoding UTF8
New-GSShelf -Manifest $plManifest -Shelf $plShelf -Mode Link -Confirm:$false | Out-Null

Test-Case 'the shipped extension manifest agrees with its folder' {
    $src = Join-Path $repoRoot 'integrations\playnite\GameShelf'
    $meta = Import-GSPlayniteExtensionManifest -Path (Join-Path $src 'extension.yaml')
    Assert-Equal 'GameShelf' $meta['Id']
    Assert-Equal 'Script' $meta['Type']
    $module = $meta['Module']
    Assert-True ($module -and (Test-Path -LiteralPath (Join-Path $src $module))) `
        "Module names a file that must exist, got '$module'"
    Assert-True ([bool]$meta['Version']) 'Version must be set'
}

Test-Case 'the extension installs into an extensions folder' {
    $src = Join-Path $repoRoot 'integrations\playnite\GameShelf'
    $root = Join-Path $sandbox 'playnite\Extensions'
    $res = Install-GSPlayniteExtension -Source $src -Root $root -Confirm:$false
    Assert-True $res.Installed
    Assert-Equal 'GameShelf' $res.Id
    Assert-True (Test-Path -LiteralPath (Join-Path $root 'GameShelf\extension.yaml'))
    Assert-True (Test-Path -LiteralPath (Join-Path $root 'GameShelf\GameShelfExtension.psm1'))

    # idempotent, but only with -Force
    $threw = $false
    try { Install-GSPlayniteExtension -Source $src -Root $root -Confirm:$false } catch { $threw = $true }
    Assert-True $threw 'installing over itself needs -Force'
    $again = Install-GSPlayniteExtension -Source $src -Root $root -Force -Confirm:$false
    Assert-True $again.Installed
}

Test-Case 'installing over a different extension is refused' {
    $root = Join-Path $sandbox 'playnite2\Extensions'
    $dest = Join-Path $root 'GameShelf'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $dest 'extension.yaml') -Value 'Id: SomeOtherThing' -Encoding UTF8

    $threw = $false
    try {
        Install-GSPlayniteExtension -Source (Join-Path $repoRoot 'integrations\playnite\GameShelf') -Root $root -Force -Confirm:$false
    } catch { $threw = $true }
    Assert-True $threw 'must refuse to replace a different extension'
    Assert-True (Test-Path -LiteralPath (Join-Path $dest 'extension.yaml')) 'and must not have deleted it'
}

Test-Case 'the extension writes a library the CLI can read back' {
    # The contract between the two halves, tested without Playnite: the writer is
    # fed plain objects shaped like the SDK's Game, and the reader must understand
    # what came out. This also pins down the single-game case, where PowerShell
    # 5.1 unwraps a one-element JSON array into a bare object.
    $mod = Join-Path $repoRoot 'integrations\playnite\GameShelf\GameShelfExtension.psm1'
    Import-Module $mod -Force

    $games = @(
        [pscustomobject]@{
            Id              = 'aaaa-bbbb'
            Name            = 'Elden Ring'
            InstallDirectory = 'D:\Games\ELDEN RING'
            IsInstalled     = $true
            Playtime          = 36000
            PlayCount         = 12
            LastActivity      = [datetime]'2026-09-20T21:00:00'
            Added             = [datetime]'2026-01-02T10:00:00'
            Categories        = @([pscustomobject]@{ Name = 'Action' })
            Genres            = @([pscustomobject]@{ Name = 'RPG' })
            Tags              = @()
            Source            = [pscustomobject]@{ Name = 'Steam' }
            Platforms         = @([pscustomobject]@{ Name = 'PC (Windows)' })
            Hidden            = $false
            Favorite          = $true
        }
    )

    $out = Join-Path $sandbox 'playnite-library.json'
    $res = Export-GSPLLibrary -Games $games -Path $out -PlayniteVersion '10.35'
    Assert-Equal 1 $res.Count
    Assert-True (Test-Path -LiteralPath $out) 'the export must be written'

    $lib = Import-GSPlayniteLibrary -Path $out
    Assert-Equal 1 $lib.Games.Count 'a one-game export must still arrive as a list'
    Assert-Equal 'Elden Ring' $lib.Games[0].Name
    Assert-Equal 'D:\Games\ELDEN RING' $lib.Games[0].InstallDir
    Assert-Equal 36000 $lib.Games[0].PlaytimeSeconds
    Assert-Equal 'Steam' $lib.Games[0].Source
    Assert-Equal 'Action' $lib.Games[0].Categories[0]
    Assert-True ($null -ne $lib.Games[0].LastActivityAt) 'the timestamp must parse'
    Assert-Equal '10.35' $lib.PlayniteVersion
}

Test-Case 'an export from a newer schema is refused, not guessed at' {
    $bad = Join-Path $sandbox 'newer.json'
    '{"schema":"gameshelf.playnite.library/99","games":[]}' |
    Set-Content -LiteralPath $bad -Encoding UTF8
    $threw = $false
    try { Import-GSPlayniteLibrary -Path $bad } catch { $threw = $true }
    Assert-True $threw 'a newer schema must not be silently interpreted'

    $notOurs = Join-Path $sandbox 'notours.json'
    '{"games":[]}' | Set-Content -LiteralPath $notOurs -Encoding UTF8
    $threw = $false
    try { Import-GSPlayniteLibrary -Path $notOurs } catch { $threw = $true }
    Assert-True $threw 'a file with no schema is not an export'
}

Test-Case 'a manifest is drafted from the library' {
    $lib = Import-GSPlayniteLibrary -Path (Join-Path $sandbox 'playnite-library.json')
    $items = @(New-GSPlayniteManifest -Games $lib.Games)
    Assert-Equal 1 $items.Count
    Assert-Equal 'Action' $items[0].Category
    Assert-Equal 'Elden Ring' $items[0].Name
    Assert-Equal 'D:\Games\ELDEN RING' $items[0].Target
    Assert-True ($items[0].Note -like '*h played*') "the note should carry playtime, got: $($items[0].Note)"
    Assert-True ($items[0].Note -like '*Steam*')
    Assert-True ($items[0].Note -like '*folder missing*') 'the folder does not exist in the sandbox'
}

Test-Case 'games without an install folder are skipped' {
    $games = @(
        [pscustomobject]@{ Name = 'Not Installed'; InstallDir = ''; IsInstalled = $false; PlaytimeSeconds = 0; LastActivityAt = $null; Categories = @(); Genres = @(); Tags = @(); Source = ''; Hidden = $false }
        [pscustomobject]@{ Name = 'Hidden One'; InstallDir = 'D:\g\h'; IsInstalled = $true; PlaytimeSeconds = 0; LastActivityAt = $null; Categories = @(); Genres = @(); Tags = @(); Source = ''; Hidden = $true }
    )
    $items = @(New-GSPlayniteManifest -Games $games)
    Assert-Equal 0 $items.Count 'no target, nothing to build'
}

Test-Case 'category falls back to genres, then to Unsorted' {
    $base = @{
        InstallDir = 'D:\g\x'; IsInstalled = $true; PlaytimeSeconds = 0; LastActivityAt = $null
        Tags = @(); Source = ''; Hidden = $false
    }
    $g = [pscustomobject]($base + @{ Name = 'G'; Categories = @(); Genres = @('RPG') })
    $byGenre = @(New-GSPlayniteManifest -Games @($g) -CategorySource Genres)
    $byDefault = @(New-GSPlayniteManifest -Games @($g))
    Assert-Equal 'RPG' $byGenre[0].Category
    Assert-Equal 'Unsorted' $byDefault[0].Category
}

Test-Case 'launcher-managed games are labelled and can be skipped' {
    $g = [pscustomobject]@{
        Name = 'Steam Game'; InstallDir = 'D:\g\s'; IsInstalled = $true; PlaytimeSeconds = 0
        LastActivityAt = $null; Categories = @('Action'); Genres = @(); Tags = @(); Source = 'Steam'; Hidden = $false
    }
    $with = @(New-GSPlayniteManifest -Games @($g))
    Assert-Equal 1 $with.Count
    Assert-True ($with[0].Note -like '*launcher-managed*') "got: $($with[0].Note)"
    $skipped = @(New-GSPlayniteManifest -Games @($g) -SkipLauncherManaged)
    Assert-Equal 0 $skipped.Count
}

Test-Case 'a shelf is matched to the library by path, then by name' {
    $games = @(
        [pscustomobject]@{ Id = '1'; Name = 'Original Name'; InstallDir = $plGameDir; IsInstalled = $true; PlaytimeSeconds = 7200; LastActivityAt = $null; Source = 'Steam'; Hidden = $false }
        [pscustomobject]@{ Id = '2'; Name = 'By Name Game'; InstallDir = ''; IsInstalled = $true; PlaytimeSeconds = 0; LastActivityAt = $null; Source = ''; Hidden = $false }
    )
    $m = Get-GSPlayniteMatch -Shelf $plShelf -Games $games
    Assert-Equal 2 $m.Total
    Assert-Equal 2 $m.Matched
    Assert-Equal 'path' $m.OnShelf[0].MatchKind 'the folder identifies it even when the labels differ'
    Assert-Equal 'name' $m.OnShelf[1].MatchKind
    Assert-Equal 2.0 $m.OnShelf[0].Hours

    # The result must be one object, not an array of them: List.Remove returns a
    # bool, and leaking it here would make $m.Unmatched collapse to $null, i.e.
    # @(...).Count would report a phantom unmatched game.
    Assert-True (-not ($m -is [array])) "Get-GSPlayniteMatch must return a single object, got $($m.GetType().Name)"
    $leftover = @($m.Unmatched)
    Assert-Equal 0 $leftover.Count ("left over: " + (($leftover | ForEach-Object { $_.Name }) -join ', '))
}

Test-Case 'an entry can be addressed by the folder it points at' {
    $data = Get-GSShelf -Shelf $plShelf -SkipSize
    $byTarget = @(Select-GSShelfEntry -Items $data.Items -Target $plGameDir)
    Assert-Equal 1 $byTarget.Count
    Assert-Equal 'Renamed On Shelf' $byTarget[0].Name
    $byName = @(Select-GSShelfEntry -Items $data.Items -Name 'By Name Game')
    Assert-Equal 1 $byName.Count
    $missing = @(Select-GSShelfEntry -Items $data.Items -Target 'Q:\nowhere')
    Assert-Equal 0 $missing.Count
}

Test-Case 'the extension exports the functions Playnite calls' {
    foreach ($fn in @('GetMainMenuItems', 'GetGameMenuItems',
            'Invoke-GSPLExportLibrary', 'Invoke-GSPLOpenShelf',
            'Invoke-GSPLBackupSaves', 'Invoke-GSPLShowSaves')) {
        Assert-True ($null -ne (Get-Command $fn -ErrorAction SilentlyContinue)) "the extension must export $fn"
    }
    # and the module must be importable without Playnite present, or nothing above
    # could be tested at all
    Assert-True ($null -ne (Get-Command 'Export-GSPLLibrary' -ErrorAction SilentlyContinue))
}

# ---------------------------------------------------------------- roots + sync

Write-Host ''
Write-Host 'roots and sync' -ForegroundColor White

$libRoot = Join-Path $sources 'lib'
New-FakeGame -Name 'lib\Alpha' | Out-Null
$rtShelf = Join-Path $sandbox 'rtshelf'
$rtManifest = Join-Path $sandbox 'rt.txt'

Test-Case 'a target resolves through the shelf roots' {
    $roots = @{ main = $libRoot }
    $r = Resolve-GSTarget -Target '%main%\Alpha' -Roots $roots
    Assert-True (-not $r.Unresolved)
    Assert-Equal (Join-Path $libRoot 'Alpha') $r.Path
    Assert-Equal 'main' $r.Label

    # a plain path is passed through, so absolute manifests keep working untouched
    $plain = Resolve-GSTarget -Target 'Q:\games\X' -Roots $roots
    Assert-Equal 'Q:\games\X' $plain.Path
    Assert-Equal '' $plain.Label
    Assert-True (-not $plain.Unresolved)

    # %APPDATA% in a target means what it means in a save path
    $env1 = Resolve-GSTarget -Target '%APPDATA%\Games\X'
    Assert-Equal (Join-Path $env:APPDATA 'Games\X') $env1.Path
    Assert-True (-not $env1.Unresolved)
}

Test-Case 'an unbound label says so instead of pretending' {
    $r = Resolve-GSTarget -Target '%elsewhere%\Alpha' -Roots @{}
    Assert-True $r.Unresolved
    Assert-Equal 'elsewhere' $r.Label
    Assert-True ($r.Why -like '*not bound*') "got: $($r.Why)"
}

Test-Case 'root map round-trips' {
    $tmp = Join-Path $sandbox 'rootmap'
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    Export-GSRoots -Shelf $tmp -Roots @{ main = 'H:\@game'; games = 'D:\MyGame' }
    $back = Import-GSRoots -Shelf $tmp
    Assert-Equal 2 $back.Keys.Count
    Assert-Equal 'H:\@game' $back['main']
    $missing = Import-GSRoots -Shelf (Join-Path $sandbox 'noroots')
    Assert-Equal 0 $missing.Keys.Count 'a shelf with no roots file is not an error'
}

Test-Case 'a shelf builds from a portable manifest and keeps it portable' {
    Export-GSRoots -Shelf $rtShelf -Roots @{ main = $libRoot }
    "Action|Alpha|%main%\Alpha|portable" | Set-Content -LiteralPath $rtManifest -Encoding UTF8

    $res = New-GSShelf -Manifest $rtManifest -Shelf $rtShelf -Mode Link -Confirm:$false
    Assert-Equal 1 $res.Created
    Assert-Equal 0 $res.Failed
    Assert-True (Test-Path -LiteralPath (Join-Path $rtShelf 'Action\Alpha\Game.exe')) 'the junction must resolve'

    $data = Get-GSShelf -Shelf $rtShelf -SkipSize
    Assert-Equal '%main%\Alpha' $data.Items[0].Target 'the manifest must keep the portable form'
    Assert-Equal (Join-Path $libRoot 'Alpha') $data.Items[0].Path 'and resolve it for this machine'
    Assert-Equal 'Link' $data.Items[0].Status
}

Test-Case 'an entry whose root is unbound is Unresolved, not Broken' {
    $tmp = Join-Path $sandbox 'unboundshelf'
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    "Action|Ghost|%nowhere%\Ghost|" | Set-Content -LiteralPath (Join-Path $tmp '_shelf.txt') -Encoding UTF8

    $data = Get-GSShelf -Shelf $tmp -SkipSize
    Assert-Equal 'Unresolved' $data.Items[0].Status

    $ver = Test-GSShelf -Shelf $tmp
    Assert-Equal 'Unresolved' $ver.Report[0].Status
    Assert-Equal 1 $ver.Bad 'it still needs attention - it is just not breakage'
}

Test-Case 'building against an unbound label fails with a usable message' {
    $tmp = Join-Path $sandbox 'unboundshelf'
    $mf = Join-Path $sandbox 'unbound.txt'
    "Action|Ghost|%nowhere%\Ghost|" | Set-Content -LiteralPath $mf -Encoding UTF8
    $res = New-GSShelf -Manifest $mf -Shelf $tmp -Mode Link -Confirm:$false -WarningAction SilentlyContinue
    Assert-Equal 1 $res.Failed
    Assert-Equal 0 $res.Created
}

Test-Case 'sync finds a game that appeared, and writes it portably' {
    New-FakeGame -Name 'lib\Beta' | Out-Null
    $res = Invoke-GSSync -Shelf $rtShelf -Root @('%main%') -SkipSize
    Assert-Equal 1 $res.Added.Count 'only the new game'
    Assert-Equal 'Beta' $res.Added[0].Name
    Assert-Equal '%main%\Beta' $res.Added[0].Target 'the root was a label, so the target is portable'
    Assert-Equal 1 $res.Known 'Alpha is already on the shelf'
}

Test-Case 'sync adds them to the shelf when asked to' {
    $res = Invoke-GSSync -Shelf $rtShelf -Root @('%main%') -SkipSize
    Assert-True (@($res.Added).Count -eq 1) 'the fixture expects one new game'
    Assert-True (-not ($res -is [array])) 'Invoke-GSSync must return a single object'
    $built = New-GSShelf -Shelf $rtShelf -Items $res.Added -Mode Link -Confirm:$false
    Assert-Equal 1 $built.Created
    Assert-True (Test-Path -LiteralPath (Join-Path $rtShelf 'Unsorted\Beta\Game.exe')) 'the new entry must be on the shelf'
    $data = Get-GSShelf -Shelf $rtShelf -SkipSize
    Assert-Equal 2 $data.Items.Count
    # and a second sync has nothing left to do
    $again = Invoke-GSSync -Shelf $rtShelf -Root @('%main%') -SkipSize
    Assert-Equal 0 $again.Added.Count
    Assert-Equal 2 $again.Known
}

Test-Case 'sync refuses an unbound root with the command to fix it' {
    $threw = $false
    $msg = ''
    try { Invoke-GSSync -Shelf $rtShelf -Root @('%elsewhere%') -SkipSize } catch { $threw = $true; $msg = $_.Exception.Message }
    Assert-True $threw
    Assert-True ($msg -like '*roots*') "the message should say what to run, got: $msg"
}

Test-Case 'the shelf gitignore lets the shelf text through and nothing else' {
    Assert-True (Export-GSShelfGitIgnore -Shelf $rtShelf) 'writes when there is none'
    Assert-True (-not (Export-GSShelfGitIgnore -Shelf $rtShelf)) 'never overwrites one that exists'
    $text = [System.IO.File]::ReadAllText((Join-Path $rtShelf '.gitignore'))
    # \r? because the file is CRLF: in .NET, $ in multiline mode matches before \n,
    # and the \r is part of the line for the pattern's purposes.
    Assert-True ($text -match '(?m)^\*\r?$') 'everything is ignored by default'
    Assert-True ($text -match '(?m)^!\*\.txt\r?$') 'the shelf text is allowed back'
    # ...but the roots are the one thing that is supposed to differ per machine, and
    # git applies the LAST matching pattern, so the re-ignore has to come after.
    $allowed = $text.IndexOf('!*.txt')
    $reignored = $text.LastIndexOf('_roots.txt')
    Assert-True ($reignored -gt $allowed) '_roots.txt must be re-ignored after !*.txt'
}

Test-Case 'committing a shelf cannot pull game data in' {
    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Host '        (git not available, skipped)' -ForegroundColor DarkGray
    } else {
        & git -C $rtShelf init -b main 2>&1 | Out-Null
        & git -C $rtShelf config user.email 'test@example.invalid' | Out-Null
        & git -C $rtShelf config user.name 'GameShelf Test' | Out-Null

        # a hand-written note in the shelf root: it should travel to the other machine
        Set-Content -LiteralPath (Join-Path $rtShelf 'NOTES.txt') -Value 'shelf notes' -Encoding UTF8

        $res = Invoke-GSShelfCommit -Shelf $rtShelf -Message 'Shelf: test'
        Assert-True $res.Committed 'the shelf files should be committed'
        Assert-True ($res.Changed -contains '_shelf.txt')

        $tracked = @(& git -C $rtShelf ls-files)
        Assert-True ($tracked -contains '_shelf.txt') 'the manifest is tracked'
        Assert-True ($tracked -contains '.gitignore') 'and so is the ignore file itself'
        Assert-True ($tracked -contains 'NOTES.txt') 'a hand-written note travels with the shelf'
        # The point: the junction points at a real game folder, and none of it may
        # end up in the repository.
        $leaked = @($tracked | Where-Object { $_ -like '*Game.exe' -or $_ -like 'Action/*' -or $_ -like 'Unsorted/*' })
        Assert-Equal 0 $leaked.Count ("game data must not be tracked, got: " + ($leaked -join ', '))
        # A hand-written note in the shelf travels; the roots binding does not, or
        # the second machine would inherit the first machine's drive letters.
        Assert-True (-not ($tracked -contains '_roots.txt')) '_roots.txt must never be committed'

        $again = Invoke-GSShelfCommit -Shelf $rtShelf -Message 'Shelf: test'
        Assert-True (-not $again.Committed) 'nothing changed, so nothing to commit'
    }
}

Test-Case 'committing outside a repository explains how to start one' {
    $tmp = Join-Path $sandbox 'notarepo'
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    "Action|X|Q:\x|" | Set-Content -LiteralPath (Join-Path $tmp '_shelf.txt') -Encoding UTF8
    Assert-True (-not (Test-GSShelfGitRepo -Shelf $tmp))
    $threw = $false
    $msg = ''
    try { Invoke-GSShelfCommit -Shelf $tmp } catch { $threw = $true; $msg = $_.Exception.Message }
    Assert-True $threw
    Assert-True ($msg -like '*git*init*') "the message should name the commands, got: $msg"
}

Test-Case 'a repository without a git identity says how to fix it' {
    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Host '        (git not available, skipped)' -ForegroundColor DarkGray
    } else {
        $tmp = Join-Path $sandbox 'noidentity'
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        "Action|X|Q:\x|" | Set-Content -LiteralPath (Join-Path $tmp '_shelf.txt') -Encoding UTF8
        & git -C $tmp init -b main 2>&1 | Out-Null

        # Hide every identity git could find, the way a fresh machine has none.
        $blank = Join-Path $sandbox 'blank.gitconfig'
        Set-Content -LiteralPath $blank -Value '' -Encoding ASCII
        $savedGlobal = $env:GIT_CONFIG_GLOBAL
        $savedSystem = $env:GIT_CONFIG_SYSTEM
        try {
            $env:GIT_CONFIG_GLOBAL = $blank
            $env:GIT_CONFIG_SYSTEM = $blank
            & git -C $tmp config --local --unset user.email 2>&1 | Out-Null
            & git -C $tmp config --local --unset user.name 2>&1 | Out-Null

            $threw = $false
            $msg = ''
            try { Invoke-GSShelfCommit -Shelf $tmp -Message 'x' } catch { $threw = $true; $msg = $_.Exception.Message }
            Assert-True $threw 'the commit cannot succeed without an identity'
            Assert-True ($msg -like '*user.name*' -and $msg -like '*user.email*') "the message should name the commands, got: $msg"
        } finally {
            $env:GIT_CONFIG_GLOBAL = $savedGlobal
            $env:GIT_CONFIG_SYSTEM = $savedSystem
        }
    }
}

Test-Case 'the first push sets its own upstream' {
    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-Host '        (git not available, skipped)' -ForegroundColor DarkGray
    } else {
        $tmp = Join-Path $sandbox 'pushtest'
        $bare = Join-Path $sandbox 'pushtest.git'
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        "Action|X|Q:\x|" | Set-Content -LiteralPath (Join-Path $tmp '_shelf.txt') -Encoding UTF8
        & git -C $tmp init -b main 2>&1 | Out-Null
        & git -C $tmp config user.email 'test@example.invalid' | Out-Null
        & git -C $tmp config user.name 'GameShelf Test' | Out-Null
        # -b main: a bare repo initialised with the system default (master) would
        # have a HEAD pointing at a branch the push never created.
        & git init --bare -b main $bare 2>&1 | Out-Null
        & git -C $tmp remote add origin $bare 2>&1 | Out-Null

        # Plain `git push` fails here: the branch has no upstream yet.
        $res = Invoke-GSShelfCommit -Shelf $tmp -Message 'Shelf: first' -Push
        Assert-True $res.Committed
        Assert-True $res.Pushed 'the first push must set the upstream itself'

        $tree = @(& git -C $bare ls-tree -r --name-only HEAD)
        Assert-True ($tree -contains '_shelf.txt') 'the manifest reached the remote'

        # A commit that was made but never pushed - because the network was down, or
        # because -Push was not asked for - must go up on the next run even though
        # there is nothing new to commit. A scheduled sync depends on it.
        Set-Content -LiteralPath (Join-Path $tmp '_shelf.txt') -Value '# changed' -Encoding UTF8
        $queued = Invoke-GSShelfCommit -Shelf $tmp -Message 'Shelf: no push yet'
        Assert-True $queued.Committed
        Assert-True (-not $queued.Pushed) 'that call did not ask to push'

        $retry = Invoke-GSShelfCommit -Shelf $tmp -Message 'Shelf: nothing new' -Push
        Assert-True (-not $retry.Committed) 'there is nothing new to commit'
        Assert-True $retry.Pushed 'but the queued commit should have been pushed'
        $head = @(& git -C $bare log -1 --pretty=%s)
        Assert-True (($head -join ' ') -like '*no push yet*') 'the remote is up to date now'
    }
}

Test-Case 'scheduling sync is a described command, not a surprise' {
    if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        Write-Host '        (ScheduledTasks module not available, skipped)' -ForegroundColor DarkGray
    } else {
        $t = Register-GSSyncTask -Shelf $rtShelf -Cli 'C:\tools\gameshelf.ps1' -Root @('%main%') `
            -At '20:00' -WhatIf
        Assert-True (-not $t.Registered) '-WhatIf must not register anything'
        Assert-True ($t.Command -like '*sync -Shelf*') 'the command it would run is reported'
        Assert-True ($t.Command -like '*%main%*') 'the root keeps its portable form'
        Assert-True ($t.Command -like '* -Commit*')
    }
}

Test-Case 'an existing shelf can be made portable' {
    $tmp = Join-Path $sandbox 'portme'
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    Export-GSRoots -Shelf $tmp -Roots @{ main = $libRoot }
    @(
        '# gameshelf v1'
        "Action|Alpha|$(Join-Path $libRoot 'Alpha')|"
        "Action|Elsewhere|Q:\games\Elsewhere|"
    ) | Set-Content -LiteralPath (Join-Path $tmp '_shelf.txt') -Encoding UTF8

    $conv = ConvertTo-GSPortableShelf -Shelf $tmp
    Assert-Equal 1 $conv.Changed 'only the entry that sits under a bound root'
    Assert-True $conv.Written

    $items = Import-GSManifest -Path (Join-Path $tmp '_shelf.txt')
    Assert-Equal '%main%\Alpha' $items[0].Target
    Assert-Equal 'Q:\games\Elsewhere' $items[1].Target 'a target outside every root is left exactly as it was'

    $again = ConvertTo-GSPortableShelf -Shelf $tmp
    Assert-Equal 0 $again.Changed 'running it twice changes nothing the second time'
}

Test-Case 'converting without roots explains what to do' {
    $tmp = Join-Path $sandbox 'norootconv'
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    "Action|Alpha|$(Join-Path $libRoot 'Alpha')|" | Set-Content -LiteralPath (Join-Path $tmp '_shelf.txt') -Encoding UTF8
    $threw = $false
    $msg = ''
    try { ConvertTo-GSPortableShelf -Shelf $tmp } catch { $threw = $true; $msg = $_.Exception.Message }
    Assert-True $threw
    Assert-True ($msg -like '*roots*') "the message should name the command, got: $msg"
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
