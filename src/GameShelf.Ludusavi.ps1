<#
    GameShelf - Ludusavi bridge.

    Dot-sourced by GameShelf.psm1, so these functions live in the module scope
    and run under the module's StrictMode.

    Ludusavi (https://github.com/mtkennerly/ludusavi) keeps a curated manifest of
    save locations for 19,000+ games, compiled from PCGamingWiki. GameShelf's own
    Find-GSSaveCandidate guesses, and on a real 63-game shelf it guesses usefully
    for about two thirds of them; this bridge replaces the guessing with data.

    The manifest itself is never parsed here. Ludusavi already knows how to expand
    its own placeholders, globs, store user IDs and registry keys, so GameShelf
    asks the tool instead of reimplementing it:

        ludusavi find   --api --fuzzy "<shelf entry name>"   -> title + score
        ludusavi backup --preview --api "<title>" [...]      -> resolved paths

    --preview means nothing is written: it reports what a backup would include.
    Both replies are JSON, documented in the repo under docs/schema.

    What comes back is one entry per *file*, which is the wrong shape for a save
    map, so Group-GSPathCluster collapses them onto folders and
    ConvertTo-GSSaveMapPath rewrites them with %APPDATA% / GAME\ style tokens.

    Everything here is a proposal. Nothing is written to _saves.txt unless the
    caller asks for it, and the curated map still wins over anything Ludusavi says.
#>

$script:GSLudusaviMapName = '_ludusavi.txt'

function Get-GSLudusaviMapPath {
    <#
    .SYNOPSIS
        Path of the Ludusavi title map for a shelf.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Shelf)
    return (Join-Path $Shelf $script:GSLudusaviMapName)
}

function Import-GSLudusaviMap {
    <#
    .SYNOPSIS
        Read a shelf's Ludusavi title map.
    .DESCRIPTION
        Maps a shelf entry name to the title Ludusavi knows it by:

            # <shelf entry name>|<ludusavi title>
            艾尔登法环|Elden Ring

        A shelf label does not have to look like the game's canonical title -
        that is the point of renaming folders on the shelf - so this is where the
        mismatch is recorded once, instead of being re-guessed on every run.
        A missing map is not an error; it just yields an empty table.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Shelf)

    $map = @{}
    $path = Get-GSLudusaviMapPath -Shelf $Shelf
    if (-not (Test-Path -LiteralPath $path)) { return $map }

    foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('|')
        if ($i -lt 1) { continue }
        $name = $t.Substring(0, $i).Trim()
        $title = $t.Substring($i + 1).Trim()
        if ($name -eq '' -or $title -eq '') { continue }
        $map[$name] = $title
    }
    return $map
}

function Export-GSLudusaviMap {
    <#
    .SYNOPSIS
        Write a shelf's Ludusavi title map.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Shelf,
        [Parameter(Mandatory)][hashtable]$Map
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# GameShelf <-> Ludusavi title map.')
    $lines.Add('# <shelf entry name>|<ludusavi title>')
    $lines.Add('# Only needed when the shelf label and the Ludusavi title differ.')
    foreach ($k in ($Map.Keys | Sort-Object)) {
        $title = ([string]$Map[$k]).Trim()
        if ($title -eq '') { continue }
        $lines.Add($k + '|' + $title)
    }
    [System.IO.File]::WriteAllLines((Get-GSLudusaviMapPath -Shelf $Shelf), $lines,
        (New-Object System.Text.UTF8Encoding($true)))
}

function Add-GSLudusaviMapEntry {
    <#
    .SYNOPSIS
        Append title overrides to _ludusavi.txt without rewriting the file.
    .DESCRIPTION
        Same reasoning as Add-GSSaveMapEntry: this file is meant to be hand-edited
        (it is where a Chinese shelf label gets pinned to an English title), so
        recording one more override must not throw away the rest of it.

        Returns the number of entries that were (or, under -WhatIf, would be)
        appended.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Shelf,
        [Parameter(Mandatory)][hashtable]$Map
    )

    $existing = Import-GSLudusaviMap -Shelf $Shelf
    $path = Get-GSLudusaviMapPath -Shelf $Shelf

    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $path) {
        foreach ($l in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) { $lines.Add($l) }
    } else {
        $lines.Add('# GameShelf <-> Ludusavi title map.')
        $lines.Add('# <shelf entry name>|<ludusavi title>')
        $lines.Add('# Only needed when the shelf label and the Ludusavi title differ.')
    }

    $added = 0
    foreach ($k in ($Map.Keys | Sort-Object)) {
        if ($existing.ContainsKey($k)) { continue }
        $title = ([string]$Map[$k]).Trim()
        if ($title -eq '') { continue }
        $lines.Add($k + '|' + $title)
        $added++
    }

    if ($added -gt 0) {
        if ($PSCmdlet.ShouldProcess($path, "append $added title entr(ies)")) {
            Write-GSLineFile -Path $path -Lines $lines.ToArray()
        }
    }
    return $added
}

function Get-GSLudusaviExe {
    <#
    .SYNOPSIS
        Find ludusavi.exe, or $null when it is not installed.
    .DESCRIPTION
        An explicit -Exe that does not exist is an error rather than a reason to
        keep looking: silently using a different binary than the one asked for is
        how you end up reading someone else's manifest.
    #>
    [CmdletBinding()]
    param([string]$Exe)

    if ($Exe) {
        if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
            throw "ludusavi.exe not found: $Exe"
        }
        return (Resolve-Path -LiteralPath $Exe).Path
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:LUDUSAVI_EXE) { $candidates.Add($env:LUDUSAVI_EXE) }
    if ($env:LOCALAPPDATA) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\ludusavi.exe'))
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\ludusavi\ludusavi.exe'))
    }
    if ($env:USERPROFILE) { $candidates.Add((Join-Path $env:USERPROFILE 'scoop\shims\ludusavi.exe')) }
    $candidates.Add('C:\Program Files\ludusavi\ludusavi.exe')

    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { return (Resolve-Path -LiteralPath $c).Path }
    }

    $cmd = Get-Command 'ludusavi' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($cmd) { return $cmd.Source }

    return $null
}

function Get-GSLudusaviAppDir {
    <#
    .SYNOPSIS
        Ludusavi's own application folder, where it caches config and manifest.
    .DESCRIPTION
        A 'ludusavi.portable' file next to the executable switches Ludusavi to
        keeping everything beside itself, which matters here because a portable
        install would otherwise look like it had no cached manifest.
    #>
    [CmdletBinding()]
    param([string]$Exe)

    if ($Exe) {
        $dir = Split-Path -Parent $Exe
        if ($dir -and (Test-Path -LiteralPath (Join-Path $dir 'ludusavi.portable'))) { return $dir }
    }
    if ($env:APPDATA) { return (Join-Path $env:APPDATA 'ludusavi') }
    return $null
}

function Test-GSLudusavi {
    <#
    .SYNOPSIS
        What GameShelf can tell about the local Ludusavi install.
    .DESCRIPTION
        Reports the executable, its version, and whether it has a cached manifest
        yet. The cache matters: with no manifest, every query fails, and the fix
        ('ludusavi manifest update', or one run of the GUI) is worth saying out
        loud rather than surfacing as an empty result.
    #>
    [CmdletBinding()]
    param(
        [string]$Exe,
        [int]$TimeoutSec = 60
    )

    $resolved = Get-GSLudusaviExe -Exe $Exe
    if (-not $resolved) {
        return [pscustomobject]@{
            Available = $false; Exe = $null; Version = ''; AppDir = $null
            ManifestPath = $null; ManifestAgeDays = $null; Note = 'not installed (optional)'
        }
    }

    $version = ''
    try {
        $r = Invoke-GSLudusavi -Exe $resolved -Arguments @('--version') -TimeoutSec $TimeoutSec -SkipManifestFlag
        if ($r.ExitCode -eq 0) { $version = ([string]$r.Stdout).Trim() }
    } catch { }

    $appDir = Get-GSLudusaviAppDir -Exe $resolved
    $manifestPath = $null
    $ageDays = $null
    if ($appDir) {
        foreach ($cand in @((Join-Path $appDir 'manifest.yaml'), (Join-Path $appDir 'manifest.yml'))) {
            if (Test-Path -LiteralPath $cand -PathType Leaf) {
                $manifestPath = $cand
                $ageDays = [math]::Round(((Get-Date) - (Get-Item -LiteralPath $cand).LastWriteTime).TotalDays, 1)
                break
            }
        }
    }

    $note = 'ready'
    if (-not $manifestPath) {
        $note = 'no cached manifest yet - run "ludusavi manifest update" once (needs network)'
    } elseif ($ageDays -gt 60) {
        $note = "manifest is $ageDays days old"
    }

    return [pscustomobject]@{
        Available = $true; Exe = $resolved; Version = $version; AppDir = $appDir
        ManifestPath = $manifestPath; ManifestAgeDays = $ageDays; Note = $note
    }
}

function ConvertTo-GSProcessArgument {
    <#
    .SYNOPSIS
        Quote one argument for a Windows command line.
    .DESCRIPTION
        ProcessStartInfo.Arguments is a single string on .NET Framework, and
        ArgumentList does not exist there, so the quoting is ours to get right.
        Game titles make this matter: 'Senren * Banka' and 'NieR:Automata' are
        both real, and so are titles containing a double quote.

        Follows the CommandLineToArgvW rules: backslashes are literal unless they
        precede a quote, and a quote is escaped by an odd number of them.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Argument)

    $a = $Argument
    if ($a -eq '') { return '""' }
    if ($a -notmatch '[\s"]') { return $a }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $a.ToCharArray()) {
        if ($ch -eq '\') { $backslashes++; continue }
        if ($ch -eq '"') {
            [void]$sb.Append('\', ($backslashes * 2 + 1))
            [void]$sb.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$sb.Append('\', $backslashes)
            $backslashes = 0
        }
        [void]$sb.Append($ch)
    }
    if ($backslashes -gt 0) { [void]$sb.Append('\', ($backslashes * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Invoke-GSLudusavi {
    <#
    .SYNOPSIS
        Run the Ludusavi CLI and capture its streams.
    .DESCRIPTION
        --no-manifest-update is prepended by default. Without it a first run would
        fetch the 17 MB manifest in the middle of a command that the user thinks is
        about their own save files, and a sandboxed or offline machine would hang
        instead of reporting that the manifest is missing.

        Output is decoded as UTF-8 explicitly; game titles are not ASCII.

        Per Ludusavi's own documentation, stdout can legitimately be blank in some
        error conditions and warnings may still arrive on stderr with a zero exit
        code, so callers must check both rather than trusting either one alone.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [switch]$AllowManifestUpdate,
        [switch]$SkipManifestFlag,
        [int]$TimeoutSec = 120
    )

    $argv = New-Object System.Collections.Generic.List[string]
    if (-not $AllowManifestUpdate -and -not $SkipManifestFlag) { $argv.Add('--no-manifest-update') }
    foreach ($a in $Arguments) { $argv.Add($a) }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (($argv | ForEach-Object { ConvertTo-GSProcessArgument -Argument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = (New-Object System.Text.UTF8Encoding($false))
    $psi.StandardErrorEncoding = (New-Object System.Text.UTF8Encoding($false))
    $psi.WorkingDirectory = (Split-Path -Parent $Exe)

    $proc = [System.Diagnostics.Process]::Start($psi)
    # Read both streams before waiting: a child that fills a pipe buffer would
    # block forever while we sit in WaitForExit.
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch { }
        $proc.Dispose()
        throw "ludusavi did not finish within $TimeoutSec seconds: $($psi.Arguments)"
    }
    $stdout = $outTask.Result
    $stderr = $errTask.Result
    $code = $proc.ExitCode
    $proc.Dispose()

    return [pscustomobject]@{
        ExitCode = $code
        Stdout   = [string]$stdout
        Stderr   = [string]$stderr
        Command  = 'ludusavi ' + $psi.Arguments
    }
}

function ConvertFrom-GSLudusaviFind {
    <#
    .SYNOPSIS
        Parse `ludusavi find --api` output.
    .DESCRIPTION
        Shape (docs/schema/general-output.yaml): { "games": { "<title>": { "score": 0.0-1.0 } } }
        Emits one object per title, highest score first.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)

    if (-not $Json -or -not $Json.Trim()) { return }

    $data = $null
    try { $data = $Json | ConvertFrom-Json } catch { throw "ludusavi find returned unparseable JSON: $($_.Exception.Message)" }
    if ($null -eq $data) { return }

    $games = Get-GSJsonMember -Object $data -Name 'games'
    if ($null -eq $games) { return }

    $found = New-Object System.Collections.Generic.List[object]
    foreach ($p in $games.PSObject.Properties) {
        $score = 0.0
        $s = Get-GSJsonMember -Object $p.Value -Name 'score'
        if ($null -ne $s) { $score = [double]$s }
        $found.Add([pscustomobject]@{ Title = $p.Name; Score = $score })
    }
    return @($found | Sort-Object -Property Score -Descending)
}

function Get-GSLudusaviUnknown {
    <#
    .SYNOPSIS
        The titles Ludusavi reported as unknown in an --api reply.
    .DESCRIPTION
        Both find and backup --preview answer with errors.unknownGames, and the CLI
        exits 1 when it has any. An unknown title is an answer, not a failure - this
        shelf is full of doujin games Ludusavi has never heard of - so the exit code
        alone cannot decide whether something went wrong. This is how the two are
        told apart: if the reply names the titles it did not know, nothing is broken.

        Reading it out of the JSON rather than matching the "No info for these
        games" text keeps this working if Ludusavi rewords its messages.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)

    if (-not $Json -or -not $Json.Trim()) { return }

    $data = $null
    try { $data = $Json | ConvertFrom-Json } catch { return }
    if ($null -eq $data) { return }

    $errors = Get-GSJsonMember -Object $data -Name 'errors'
    if ($null -eq $errors) { return }
    foreach ($u in @(Get-GSJsonMember -Object $errors -Name 'unknownGames')) {
        if ($u) { [string]$u }
    }
}

function ConvertFrom-GSLudusaviPreview {
    <#
    .SYNOPSIS
        Parse `ludusavi backup --preview --api` output.
    .DESCRIPTION
        Shape: { "games": { "<title>": { "files": { "<path>": { "bytes": n,
        "ignored": bool, ... } }, "registry": { "<key>": {} } } },
        "errors": { "unknownGames": [ ... ] } }

        Emits one object per title, plus one per unknown title so a caller can say
        "Ludusavi does not know this game" rather than showing nothing. Entries
        flagged ignored are skipped: the user has already told Ludusavi to leave
        them alone, and a save map should not quietly disagree.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)

    if (-not $Json -or -not $Json.Trim()) { return }

    $data = $null
    try { $data = $Json | ConvertFrom-Json } catch { throw "ludusavi returned unparseable JSON: $($_.Exception.Message)" }
    if ($null -eq $data) { return }

    $unknown = @(Get-GSLudusaviUnknown -Json $Json)

    $games = Get-GSJsonMember -Object $data -Name 'games'
    if ($null -ne $games) {
        foreach ($p in $games.PSObject.Properties) {
            $files = Get-GSJsonMember -Object $p.Value -Name 'files'
            $registry = Get-GSJsonMember -Object $p.Value -Name 'registry'
            $decision = Get-GSJsonMember -Object $p.Value -Name 'decision'

            $paths = New-Object System.Collections.Generic.List[string]
            $sizes = @{}
            $bytes = [long]0
            $ignored = 0
            if ($null -ne $files) {
                foreach ($f in $files.PSObject.Properties) {
                    $entry = $f.Value
                    $flag = $null
                    if ($null -ne $entry) { $flag = Get-GSJsonMember -Object $entry -Name 'ignored' }
                    if ($flag -eq $true) { $ignored++; continue }

                    $paths.Add($f.Name)
                    $b = $null
                    if ($null -ne $entry) { $b = Get-GSJsonMember -Object $entry -Name 'bytes' }
                    if ($null -ne $b) {
                        $bytes += [long]$b
                        $sizes[$f.Name.ToLowerInvariant()] = [long]$b
                    }
                }
            }

            $regKeys = @()
            if ($null -ne $registry) { $regKeys = @($registry.PSObject.Properties | ForEach-Object { $_.Name }) }

            [pscustomobject]@{
                Title    = $p.Name
                Unknown  = $false
                Paths    = @($paths)
                Sizes    = $sizes
                Files    = $paths.Count
                Bytes    = $bytes
                Ignored  = $ignored
                Registry = $regKeys
                Decision = $decision
            }
        }
    }

    foreach ($u in $unknown) {
        if (-not $u) { continue }
        [pscustomobject]@{
            Title    = [string]$u
            Unknown  = $true
            Paths    = @()
            Sizes    = @{}
            Files    = 0
            Bytes    = [long]0
            Ignored  = 0
            Registry = @()
            Decision = $null
        }
    }
}

function Find-GSLudusaviTitle {
    <#
    .SYNOPSIS
        Ask Ludusavi which of its titles a name refers to.
    .DESCRIPTION
        Returns the best match with a Match field of 'exact' or 'fuzzy', or $null
        when Ludusavi has nothing at all.

        'exact' is decided by comparing the strings, not by the score. The score
        is a fuzzy-match confidence whose exact scale is Ludusavi's business, and
        no behaviour of ours should silently change if that scale does.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$Name,
        [switch]$AllowManifestUpdate,
        [int]$TimeoutSec = 120
    )

    $r = Invoke-GSLudusavi -Exe $Exe -Arguments @('find', '--api', '--fuzzy', $Name) `
        -AllowManifestUpdate:$AllowManifestUpdate -TimeoutSec $TimeoutSec

    $matches = @(ConvertFrom-GSLudusaviFind -Json $r.Stdout)
    if ($matches.Count -eq 0) {
        if ($r.ExitCode -ne 0) {
            # Ludusavi exits 1 for a title it has never heard of. That is a real
            # answer about a real shelf - not every game is in the manifest - so it
            # must not abort the run. Anything else is a failure worth stopping for.
            if (@(Get-GSLudusaviUnknown -Json $r.Stdout).Count -gt 0) { return $null }
            $detail = ([string]$r.Stderr).Trim()
            if (-not $detail) { $detail = ([string]$r.Stdout).Trim() }
            if (-not $detail) { $detail = 'no output' }
            throw "ludusavi find failed (exit $($r.ExitCode)): $detail"
        }
        return $null
    }

    $best = $matches[0]
    $kind = 'fuzzy'
    if ($best.Title -ieq $Name) { $kind = 'exact' }
    return [pscustomobject]@{ Title = $best.Title; Score = $best.Score; Match = $kind; Candidates = $matches.Count }
}

function Get-GSLudusaviPreview {
    <#
    .SYNOPSIS
        Resolve save paths for one or more Ludusavi titles.
    .DESCRIPTION
        Titles are passed as separate positionals, so a caller resolving twenty
        games pays for one process launch and one manifest load rather than
        twenty. Emits the parsed preview per title.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Titles,
        [switch]$AllowManifestUpdate,
        [int]$TimeoutSec = 180
    )

    $list = @($Titles | Where-Object { $_ })
    if ($list.Count -eq 0) { return }

    $argv = New-Object System.Collections.Generic.List[string]
    $argv.Add('backup')
    $argv.Add('--preview')
    $argv.Add('--api')
    foreach ($t in $list) { $argv.Add($t) }

    $r = Invoke-GSLudusavi -Exe $Exe -Arguments @($argv) `
        -AllowManifestUpdate:$AllowManifestUpdate -TimeoutSec $TimeoutSec

    $parsed = @(ConvertFrom-GSLudusaviPreview -Json $r.Stdout)

    if ($r.ExitCode -ne 0) {
        # Same reasoning as Find-GSLudusaviTitle: a reply that names the titles it
        # did not know is a usable answer about the titles it did know, so the
        # known ones are still returned. A failure with no such list stops the run.
        $unknown = @(Get-GSLudusaviUnknown -Json $r.Stdout)
        if ($parsed.Count -eq 0 -or $unknown.Count -eq 0) {
            $detail = ([string]$r.Stderr).Trim()
            if (-not $detail) { $detail = ([string]$r.Stdout).Trim() }
            if (-not $detail) { $detail = 'no output' }
            throw "ludusavi backup --preview failed (exit $($r.ExitCode)): $detail"
        }
    }

    $parsed
}

function ConvertTo-GSLudusaviProposal {
    <#
    .SYNOPSIS
        Turn resolved titles and previews into proposals.
    .DESCRIPTION
        The decision half of the bridge, split from the process half so it can be
        exercised without Ludusavi installed: everything here is a function of the
        match table and the preview table, both of which are plain data.

    .PARAMETER Match
        Entry name -> object with Title, Match ('override'/'exact'/'fuzzy'),
        Score and Candidates. A name that is absent means nothing was found for it.

    .PARAMETER Preview
        Ludusavi title -> a preview object, as ConvertFrom-GSLudusaviPreview emits.

    .PARAMETER MaxPaths
        Cap on how many locations one entry may contribute. A game whose saves are
        spread over a hundred folders should not silently become a hundred-line map
        entry; the surplus is counted so the caller can say so.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entry,
        [hashtable]$Match,
        [hashtable]$Preview,
        [double]$MinScore = 0.8,
        [int]$MaxPaths = 16
    )

    foreach ($e in @($Entry | Where-Object { $_ })) {
        $name = [string]$e.Name
        $target = [string]$e.Target

        $m = $null
        if ($Match -and $Match.ContainsKey($name)) { $m = $Match[$name] }

        $title = $null
        $kind = 'none'
        $score = 0.0
        $candidates = 0
        if ($m) {
            $title = [string]$m.Title
            if ($m.Match) { $kind = [string]$m.Match }
            $score = [double]$m.Score
            if ($null -ne $m.Candidates) { $candidates = [int]$m.Candidates }
        }

        $pv = $null
        if ($title -and $Preview -and $Preview.ContainsKey($title)) { $pv = $Preview[$title] }

        $paths = @()
        $clusters = 0
        $dropped = 0
        $reg = 0
        $files = 0
        $bytes = [long]0
        $unknown = $false
        $reason = ''

        if (-not $title) {
            $reason = 'no ludusavi match'
        } elseif ($null -eq $pv) {
            # find resolved a title and the preview then said nothing about it.
            # Ludusavi omits a game from --preview when it resolves no paths for it,
            # which is the ordinary outcome for a game that is not installed the way
            # its manifest entry expects - an archive copy, a repack, a portable
            # build in a folder nobody told it about - or whose entry lists no files
            # at all. Verified against the manifest: those entries have either no
            # 'files:' section or one rooted at <base>, the install folder.
            # Nothing to adopt, and nothing wrong with the title, so -Title will not
            # help here.
            $reason = "ludusavi resolved no paths for '$title'"
        } else {
            $unknown = [bool]$pv.Unknown
            $files = [int]$pv.Files
            $bytes = [long]$pv.Bytes
            $reg = @($pv.Registry).Count

            if ($unknown) {
                $reason = 'ludusavi does not know this title'
            } elseif ($files -gt 0) {
                $all = @(Group-GSPathCluster -Paths $pv.Paths -Target $target -Bytes $pv.Sizes)
                $clusters = $all.Count
                $take = @($all | Select-Object -First $MaxPaths)
                $dropped = $clusters - $take.Count
                $paths = @($take | ForEach-Object { ConvertTo-GSSaveMapPath -Absolute $_.Root -Target $target })
            } else {
                $reason = 'ludusavi lists no existing files for this game'
            }
        }

        if (-not $reason -and $kind -eq 'fuzzy' -and $score -lt $MinScore) {
            $reason = ('below -MinScore ({0:N2} < {1:N2})' -f $score, $MinScore)
        }

        $ok = ($paths.Count -gt 0) -and ($kind -eq 'override' -or $kind -eq 'exact' -or $score -ge $MinScore)

        [pscustomobject]@{
            Entry      = $name
            Target     = $target
            Title      = $title
            Match      = $kind
            Score      = $score
            Candidates = $candidates
            Ok         = $ok
            Unknown    = $unknown
            Reason     = $reason
            Paths      = $paths
            Clusters   = $clusters
            Dropped    = $dropped
            Registry   = $reg
            Files      = $files
            Bytes      = $bytes
        }
    }
}

function Get-GSLudusaviProposal {
    <#
    .SYNOPSIS
        Propose save-map entries for shelf entries that have none.
    .DESCRIPTION
        For each entry: an explicit title from the shelf's _ludusavi.txt if there
        is one, otherwise the best fuzzy match. All resolved titles are then
        previewed in a single Ludusavi call, and the reported files are clustered
        onto folders and rewritten with save-map tokens.

        Nothing here writes anything. The caller decides what to adopt, and only
        ever for entries the curated map does not already cover.

    .PARAMETER Entry
        Objects with Name and Target - i.e. items straight out of Get-GSShelf.

    .PARAMETER Progress
        Optional scriptblock invoked as (& $Progress <entry name> <status text>)
        so a slow run can report as it goes. One Ludusavi call per un-mapped
        entry is unavoidable: find takes a single query.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entry,
        [Parameter(Mandatory)][string]$Exe,
        [hashtable]$Titles,
        [double]$MinScore = 0.8,
        [int]$MaxPaths = 16,
        [switch]$AllowManifestUpdate,
        [int]$TimeoutSec = 180,
        [scriptblock]$Progress
    )

    $items = @($Entry | Where-Object { $_ })
    if ($items.Count -eq 0) { return }

    # ---- resolve a title per entry
    $match = @{}
    $wanted = New-Object System.Collections.Generic.List[string]
    foreach ($e in $items) {
        $name = [string]$e.Name
        $title = $null
        $kind = 'none'
        $score = 0.0
        $candidates = 0

        if ($Titles -and $Titles.ContainsKey($name)) {
            $title = [string]$Titles[$name]
            $kind = 'override'
            $score = 1.0
        } else {
            if ($Progress) { & $Progress $name 'asking ludusavi' }
            $found = Find-GSLudusaviTitle -Exe $Exe -Name $name `
                -AllowManifestUpdate:$AllowManifestUpdate -TimeoutSec $TimeoutSec
            if ($found) {
                $title = $found.Title
                $kind = $found.Match
                $score = $found.Score
                $candidates = $found.Candidates
            }
        }

        if ($title) { $wanted.Add($title) }
        $match[$name] = [pscustomobject]@{
            Title = $title; Match = $kind; Score = $score; Candidates = $candidates
        }
    }

    # ---- one preview call for every title we resolved
    $preview = @{}
    $unique = @($wanted | Sort-Object -Unique)
    if ($unique.Count -gt 0) {
        if ($Progress) { & $Progress '' "reading $($unique.Count) title(s) from ludusavi" }
        foreach ($pv in (Get-GSLudusaviPreview -Exe $Exe -Titles $unique `
                    -AllowManifestUpdate:$AllowManifestUpdate -TimeoutSec $TimeoutSec)) {
            $preview[$pv.Title] = $pv
        }
    }

    ConvertTo-GSLudusaviProposal -Entry $items -Match $match -Preview $preview `
        -MinScore $MinScore -MaxPaths $MaxPaths
}
