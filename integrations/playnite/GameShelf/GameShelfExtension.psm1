<#
    GameShelf - Playnite script extension.

    The file is GameShelfExtension.psm1 rather than GameShelf.psm1 so its module
    name cannot collide with GameShelf's own module: PowerShell keys importable
    modules by file name, and the test suite imports both - a second 'GameShelf'
    would silently replace the first one's commands.

    Runs inside Playnite (Windows PowerShell 5.1, in-process) and does two things:

      * exports the library to %APPDATA%\GameShelf\playnite-library.json, which is
        the file GameShelf reads to draft a shelf manifest or to line an existing
        shelf up against what Playnite knows;
      * puts GameShelf commands on the main menu and the game menu.

    This module is deliberately thin and standalone. It does not import anything
    from src/ - Playnite loads it into its own process, and an extension that
    reaches into a checkout would break the moment the folder moved. The
    interesting logic (matching, manifest drafting, path clustering) lives in
    GameShelf itself.

    It is also written so the export half can run outside Playnite: every function
    that touches the Playnite API is separate from the ones that shape data, so
    the test suite can feed ConvertTo-GSPLGame plain objects and check the JSON
    contract without Playnite installed.

    Note for the future: Playnite 11 drops PowerShell script extensions. Keeping
    the format in one small function means the C# replacement only has to write
    the same JSON.
#>

$script:GSPLExportSchema = 'gameshelf.playnite.library/1'
$script:GSPLSettingsFile = 'playnite-extension.json'

function Get-GSPLDataDir {
    <#
    .SYNOPSIS
        %APPDATA%\GameShelf - shared with the CLI, which defaults to reading the
        export from the same place.
    #>
    $dir = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'GameShelf'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-GSPLExportPath {
    <#
    .SYNOPSIS
        Where the library export is written.
    #>
    return (Join-Path (Get-GSPLDataDir) 'playnite-library.json')
}

function Get-GSPLSettingsPath {
    <#
    .SYNOPSIS
        Where the extension's own settings live.
    #>
    return (Join-Path (Get-GSPLDataDir) $script:GSPLSettingsFile)
}

function Get-GSPLSettings {
    <#
    .SYNOPSIS
        Read the extension settings, writing a template the first time.
    .DESCRIPTION
        Two keys: 'shelf' (the folder GameShelf built) and 'cli' (gameshelf.cmd
        from the checkout). Both are needed before any menu action can do
        anything, and a template file with the real path in it is a much better
        first run than a dialog that asks for a path the user has to go and look up.
    #>
    $path = Get-GSPLSettingsPath
    $defaults = [pscustomobject]@{ Path = $path; Shelf = ''; Cli = ''; Complete = $false }

    if (-not (Test-Path -LiteralPath $path)) {
        $template = [ordered]@{
            _comment = "Point 'cli' at gameshelf.cmd in your GameShelf checkout, and 'shelf' at the folder you built. Restart Playnite afterwards."
            cli      = 'D:\path\to\gameshelf\gameshelf.cmd'
            shelf    = 'H:\Games'
        }
        [System.IO.File]::WriteAllText($path, ($template | ConvertTo-Json -Depth 4),
            (New-Object System.Text.UTF8Encoding($false)))
        return $defaults
    }

    $data = $null
    try { $data = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { return $defaults }
    if ($null -eq $data) { return $defaults }

    $shelf = ''; $cli = ''
    $p = $data.PSObject.Properties['shelf']; if ($p -and $p.Value) { $shelf = ([string]$p.Value).Trim() }
    $p = $data.PSObject.Properties['cli']; if ($p -and $p.Value) { $cli = ([string]$p.Value).Trim() }

    # The template's placeholder values are not settings, they are instructions.
    if ($cli -like 'D:\path\to\*') { $cli = '' }
    if ($shelf -eq 'H:\Games') { $shelf = '' }

    return [pscustomobject]@{
        Path     = $path
        Shelf    = $shelf
        Cli      = $cli
        Complete = [bool]($shelf -and $cli)
    }
}

function ConvertTo-GSPLGame {
    <#
    .SYNOPSIS
        Shape one Playnite game object into the export's record.
    .DESCRIPTION
        Every field is read defensively: these are SDK objects whose properties
        differ between Playnite versions, and a reference field that is null (a
        game with no genres) must not throw and must not become the string
        'System.Object[]' either.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Game)

    $read = {
        param($Object, [string]$Name)
        if ($null -eq $Object) { return $null }
        $p = $Object.PSObject.Properties[$Name]
        if ($null -eq $p) { return $null }
        return $p.Value
    }

    $names = {
        param($List)
        $out = New-Object System.Collections.Generic.List[string]
        foreach ($x in @($List)) {
            if ($null -eq $x) { continue }
            $n = ''
            $p = $x.PSObject.Properties['Name']
            if ($null -ne $p) { $n = [string]$p.Value }
            else { $n = [string]$x }
            if ($n) { $out.Add($n) }
        }
        return $out.ToArray()
    }

    $id = & $read $Game 'Id'
    $last = & $read $Game 'LastActivity'
    $added = & $read $Game 'Added'
    $source = & $read $Game 'Source'

    $sourceName = ''
    if ($null -ne $source) {
        $p = $source.PSObject.Properties['Name']
        if ($null -ne $p) { $sourceName = [string]$p.Value } else { $sourceName = [string]$source }
    }

    return [pscustomobject]@{
        id              = [string]$id
        name            = [string](& $read $Game 'Name')
        installDir      = [string](& $read $Game 'InstallDirectory')
        isInstalled     = [bool](& $read $Game 'IsInstalled')
        playtimeSeconds = [long](& $read $Game 'Playtime')
        playCount       = [long](& $read $Game 'PlayCount')
        lastActivity    = $(if ($last) { ([datetime]$last).ToString('s') } else { '' })
        added           = $(if ($added) { ([datetime]$added).ToString('s') } else { '' })
        categories      = & $names (& $read $Game 'Categories')
        genres          = & $names (& $read $Game 'Genres')
        tags            = & $names (& $read $Game 'Tags')
        source          = $sourceName
        platforms       = & $names (& $read $Game 'Platforms')
        hidden          = [bool](& $read $Game 'Hidden')
        favorite        = [bool](& $read $Game 'Favorite')
    }
}

function Export-GSPLLibrary {
    <#
    .SYNOPSIS
        Write the library export GameShelf reads.
    .DESCRIPTION
        Games with no name are dropped; everything else is kept, including games
        that are not installed, because deciding what belongs on a shelf is
        GameShelf's job and it should see the whole library.

        The schema string is the contract. GameShelf refuses to read an export it
        does not recognise rather than guessing at fields that may have moved.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Games,
        [string]$Path,
        [string]$PlayniteVersion = ''
    )

    if (-not $Path) { $Path = Get-GSPLExportPath }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($g in @($Games | Where-Object { $_ })) {
        $r = ConvertTo-GSPLGame -Game $g
        if (-not $r.name) { continue }
        $records.Add($r)
    }

    $payload = [ordered]@{
        schema          = $script:GSPLExportSchema
        generated       = (Get-Date).ToString('s')
        playniteVersion = $PlayniteVersion
        count           = $records.Count
        # .ToArray(), never @(): wrapping a List[object] in an array subexpression
        # throws "parameter type mismatch" in PowerShell (a List[string] happens to
        # be fine, which is exactly what makes this trap so easy to walk into).
        games           = $records.ToArray()
    }

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, ($payload | ConvertTo-Json -Depth 5),
        (New-Object System.Text.UTF8Encoding($false)))

    return [pscustomobject]@{ Path = $Path; Count = $records.Count }
}

function Quote-GSPLArgument {
    <#
    .SYNOPSIS
        Quote one argument for a command line.
    #>
    param([AllowEmptyString()][string]$Argument)

    if ($Argument -eq '') { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }
    return '"' + ($Argument -replace '"', '\"') + '"'
}

function Start-GSPLCli {
    <#
    .SYNOPSIS
        Run a GameShelf command in its own console window.
    .DESCRIPTION
        Started visibly rather than captured: the CLI's output is full of Chinese
        and Japanese folder names, and a redirected PowerShell pipe would decode
        them with the OEM codepage and hand back mojibake. A console window also
        shows progress on a backup, which is the point of running one by hand.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments)

    $s = Get-GSPLSettings
    if (-not $s.Complete) {
        throw ("GameShelf extension is not configured yet. Edit " + $s.Path +
            " and set 'cli' to gameshelf.cmd and 'shelf' to your shelf folder, then restart Playnite.")
    }

    $line = (@($Arguments) | ForEach-Object { Quote-GSPLArgument -Argument $_ }) -join ' '
    if ($s.Cli -like '*.ps1') {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -File " + (Quote-GSPLArgument -Argument $s.Cli) + ' ' + $line) `
            -WorkingDirectory $s.Shelf | Out-Null
    } else {
        Start-Process -FilePath $s.Cli -ArgumentList $line -WorkingDirectory $s.Shelf | Out-Null
    }
}

# ------------------------------------------------------------------ Playnite glue
#
# Everything below this line is only reachable from inside Playnite. It is kept
# to argument massaging and menu wiring so that the untestable surface stays as
# small as possible.

function Get-GSPLApi {
    <#
    .SYNOPSIS
        The Playnite API object Playnite injects into this extension.
    .DESCRIPTION
        Playnite sets $PlayniteAPI in the extension's own scope, which for a module
        is its script scope rather than the global one. Both scopes are checked, and
        both spellings - the documentation uses $PlayniteAPI and $PlayniteApi in
        different places - so the handlers below cannot fail with a null reference
        depending on how it was injected.
    #>
    foreach ($scope in @('Script', 'Global')) {
        foreach ($name in @('PlayniteAPI', 'PlayniteApi')) {
            $v = Get-Variable -Name $name -Scope $scope -ErrorAction SilentlyContinue
            if ($null -ne $v -and $null -ne $v.Value) { return $v.Value }
        }
    }
    return $null
}

function Get-GSPLArgGame {
    <#
    .SYNOPSIS
        Pull the game out of whatever Playnite handed a menu handler.
    .DESCRIPTION
        The handler argument has carried the selection under more than one name
        across versions, so all the shapes seen in the wild are accepted.
    #>
    param($Arguments)

    if ($null -eq $Arguments) { return $null }
    foreach ($name in @('Game', 'Games', 'SelectedGames')) {
        $p = $Arguments.PSObject.Properties[$name]
        if ($null -eq $p -or $null -eq $p.Value) { continue }
        $v = $p.Value
        if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) {
            foreach ($one in $v) { if ($one) { return $one } }
        } else {
            return $v
        }
    }
    return $null
}

function GetMainMenuItems {
    param($menuArgs)

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($spec in @(
            @{ Text = 'Export library for GameShelf'; Function = 'Invoke-GSPLExportLibrary' },
            @{ Text = 'Open GameShelf folder'; Function = 'Invoke-GSPLOpenShelf' }
        )) {
        $item = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
        $item.Description = $spec.Text
        $item.FunctionName = $spec.Function
        $items.Add($item)
    }
    # An array, matching the documented example: Playnite enumerates whatever it is
    # given, but there is no reason to hand it a type the docs do not use.
    return $items.ToArray()
}

function GetGameMenuItems {
    param($menuArgs)

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($spec in @(
            @{ Text = 'GameShelf: back up saves'; Function = 'Invoke-GSPLBackupSaves' },
            @{ Text = 'GameShelf: show save locations'; Function = 'Invoke-GSPLShowSaves' }
        )) {
        $item = New-Object Playnite.SDK.Plugins.ScriptGameMenuItem
        $item.Description = $spec.Text
        $item.FunctionName = $spec.Function
        $items.Add($item)
    }
    return $items.ToArray()
}

function Invoke-GSPLExportLibrary {
    param($args)

    $api = Get-GSPLApi
    try {
        $games = @($api.Database.Games)
        $version = ''
        try { $version = [string]$api.ApplicationVersion } catch { }
        $res = Export-GSPLLibrary -Games $games -PlayniteVersion $version
        $api.Dialogs.ShowMessage(
            ("Exported {0} game(s) to:`n{1}`n`nNow run:  gameshelf.cmd playnite -Out draft.txt" -f $res.Count, $res.Path),
            'GameShelf')
    } catch {
        $api.Dialogs.ShowMessage("Export failed: $($_.Exception.Message)", 'GameShelf', 'OK', 'Error')
    }
}

function Invoke-GSPLOpenShelf {
    param($args)

    $api = Get-GSPLApi
    $s = Get-GSPLSettings
    if (-not $s.Shelf -or -not (Test-Path -LiteralPath $s.Shelf)) {
        $api.Dialogs.ShowMessage("No shelf configured yet. Edit $($s.Path).", 'GameShelf', 'OK', 'Error')
        return
    }
    Start-Process -FilePath 'explorer.exe' -ArgumentList (Quote-GSPLArgument -Argument $s.Shelf) | Out-Null
}

function Invoke-GSPLBackupSaves {
    param($args)

    $api = Get-GSPLApi
    $game = Get-GSPLArgGame -Arguments $args
    if (-not $game) {
        $api.Dialogs.ShowMessage('No game selected.', 'GameShelf', 'OK', 'Error')
        return
    }

    $dir = [string]$game.InstallDirectory
    if (-not $dir) {
        $api.Dialogs.ShowMessage("'$($game.Name)' has no install folder in Playnite, so GameShelf cannot match it.", 'GameShelf', 'OK', 'Error')
        return
    }

    # Matched on the folder rather than the name: the shelf label is GameShelf's
    # own and need not be the title Playnite shows.
    try {
        $s = Get-GSPLSettings
        Start-GSPLCli -Arguments @('backup', '-Shelf', $s.Shelf, '-Target', $dir)
    } catch {
        $api.Dialogs.ShowMessage("$($_.Exception.Message)", 'GameShelf', 'OK', 'Error')
    }
}

function Invoke-GSPLShowSaves {
    param($args)

    $api = Get-GSPLApi
    $game = Get-GSPLArgGame -Arguments $args
    if (-not $game) {
        $api.Dialogs.ShowMessage('No game selected.', 'GameShelf', 'OK', 'Error')
        return
    }
    try {
        $s = Get-GSPLSettings
        Start-GSPLCli -Arguments @('saves', '-Shelf', $s.Shelf, '-Target', [string]$game.InstallDirectory)
    } catch {
        $api.Dialogs.ShowMessage("$($_.Exception.Message)", 'GameShelf', 'OK', 'Error')
    }
}

Export-ModuleMember -Function @(
    'GetMainMenuItems', 'GetGameMenuItems',
    'Invoke-GSPLExportLibrary', 'Invoke-GSPLOpenShelf',
    'Invoke-GSPLBackupSaves', 'Invoke-GSPLShowSaves',
    'Export-GSPLLibrary', 'ConvertTo-GSPLGame',
    'Get-GSPLSettings', 'Get-GSPLExportPath'
)
