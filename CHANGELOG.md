# Changelog

All notable changes to GameShelf are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/).

## [1.4.0] - 2026-09-22

One shelf, several machines, and games that add themselves.

### Added

- **Portable targets.** A manifest target may be written `%label%\rest`, and the
  label is bound to a real folder per machine in `<shelf>\_roots.txt`:

  ```
  # <label>|<folder>
  main|H:\@game
  games|D:\MyGame
  ```

  One `_shelf.txt` then describes the same library on a machine whose drives are
  laid out differently, which is what makes the shelf worth keeping in git.
  Absolute targets are untouched, so a single-machine shelf never notices the
  feature exists. `%APPDATA%`-style tokens work in a target too, through the same
  table the save map uses.

- `roots` — lists what this machine has bound, how many entries use each label, and
  prints the exact `-Set` command for the ones that are still missing.
  `roots -Set main=H:\@game` binds one; `roots -Portable` rewrites the drive letters
  of an existing shelf into `%label%` paths (longest root wins when roots nest,
  targets outside every root are left alone, and the junctions on disk are not
  touched). `-Set` also accepts the whole list as one string, because cmd.exe and
  `powershell -File` do not parse array syntax.
- `sync` — scans the roots, finds games that are not on the shelf yet, and adds
  them. Comparison is on the resolved target, so a renamed entry is still
  recognised. New entries land under `-Category` (default `Unsorted`) with the note
  `自动加入，待分类`, and `sync -Root %main%` keeps their targets portable.
- `sync -Commit` and `-Push` keep the shelf in git, with `Export-GSShelfGitIgnore`
  writing the shape that makes it safe: ignore everything, allow back the shelf's
  own text (`*.txt`, `*.md`, `*.csv`, `.gitignore` at the root, so a hand-written
  note travels too) and re-ignore `_roots.txt` after that, because git applies the
  last matching pattern and the roots are the one file that is *supposed* to differ
  per machine. Git does not descend into an ignored directory, so the junctions —
  which point at tens of GB of game folders — cannot be committed, and staging is
  done by name, at the root and without recursing, so a wrong .gitignore cannot turn
  a one-line change into a commit of somebody's game library. Tested for exactly
  that, including that `_roots.txt` never lands in the repository.
- `sync -Register [-At 20:00]` schedules the same command as a per-user task
  (interactive logon type, so no password is stored and no admin rights are
  needed); `-Unregister` removes it. The task is a trigger, not a policy.
- An entry whose label this machine has not bound is reported as `Unresolved`
  rather than `Broken`: the shelf is fine, this machine just has not been told
  where that root lives. `verify` counts them, prints the `roots` command, and
  `build` skips them with a message naming the label.
- The launcher resolves targets through `_roots.txt` too, shows only the entries
  this machine actually has, and says how many are elsewhere (`另有 N 款不在本机`).
  When none of them are here it explains why instead of showing an empty window.
  The tile tooltip, "copy real path" and the launcher picker all use the resolved
  folder.
- `Get-GSShelf` rows carry `Path` (resolved here) alongside `Target` (as written),
  and the save commands use `Path`, since `GAME\` save paths can only be resolved
  against a real folder.

### Fixed

- **The shelf .gitignore allowed `_roots.txt` through**, which the documentation
  right next to it said should stay local: committing it would hand the second
  machine the first machine's drive letters, silently. Caught while publishing a
  real shelf to a repository, where it would have been committed.
- **`New-GSShelf`'s `-Items` never worked**: it assigned to a local `$items`, which
  is the `-Items` parameter as far as PowerShell is concerned (variable names are
  case-insensitive), so the guard at the top read a variable it had just set to
  `$null`. Third time this family of bug has bitten this codebase; the CLI's
  `$label` locals, which would have shadowed the new `-Label` parameter, were
  renamed in the same pass.
- `Invoke-GSShelfGit` let git's stderr become a terminating `NativeCommandError`
  under `$ErrorActionPreference = 'Stop'`, so asking "is this a git repo?" about a
  folder that is not one threw git's message instead of answering the question.
- `Export-GSRoots` now creates the shelf folder if it is missing: on a second
  machine the roots file is the first thing written, before anything else exists.
- `-Shot` created its parent folder with `New-Item`, which refuses a drive root;
  `Directory.CreateDirectory` is a no-op there.

### Notes

- Another PowerShell trap for the collection, found by `sync` returning one item
  made of both: **`@(Some-Function ...)` nests the result when that function
  returns its list through a leading comma** (`return , $list`), so `foreach`
  iterates once over the whole list and every `.Name` becomes an array. Assign
  first, then iterate. `@($variable)` on a `List[object]` still throws, as recorded
  in 1.3.0 — the two are different traps with the same smell.

## [1.3.0] - 2026-09-21

Two integrations, both optional at runtime. Nothing in either is needed for a shelf
to work, and neither changes what an existing shelf does.

### Added

- **Ludusavi integration** ([github.com/mtkennerly/ludusavi](https://github.com/mtkennerly/ludusavi)),
  which turns save-location guessing into data. `saves -Ludusavi` reports what
  Ludusavi knows for entries that are not mapped yet; `adopt -All` (or `-Name`)
  writes it into `_saves.txt`. Ludusavi is asked rather than its manifest parsed —
  `ludusavi backup --preview --api` resolves placeholders, globs, store user ids
  and registry keys exactly as a real backup would, and `--no-manifest-update` is
  passed by default so a first run reports a missing manifest instead of quietly
  fetching 17 MB.
- `Group-GSPathCluster` collapses Ludusavi's per-file answer onto the smallest set
  of folders covering it, and `ConvertTo-GSSaveMapPath` rewrites the result with
  the tokens `_saves.txt` already uses. `Test-GSPathIsSpecific` is the guard that
  stops two unrelated folders under `%APPDATA%` from merging into a bare
  `%APPDATA%` entry, which would back up the whole roaming profile.
- `_ludusavi.txt`, a `<shelf entry name>|<ludusavi title>` map, for shelves whose
  labels are not the games' titles. Consulted before fuzzy matching; a match below
  `-MinScore` (default 0.8) is reported but not adopted.
- **Playnite integration** ([playnite.link](https://playnite.link)): a bundled
  PowerShell script extension in `integrations/playnite/` exports the library to
  `%APPDATA%\GameShelf\playnite-library.json`, and `playnite` reads it —
  `-Out draft.txt` drafts a manifest with Playnite's own categories and playtime,
  `-Shelf <folder>` reports shelf entries Playnite does not know and installed
  games that are not on the shelf yet, `-Install` copies the extension into
  Playnite. The extension also adds two game-menu entries that address the shelf by
  install folder.
- `-Target <folder>` on `saves`, `backup` and `restore`, plus `Select-GSShelfEntry`
  behind it: an entry can be addressed by the folder it points at rather than by
  its label, which is what a launcher has to hand. The Playnite game-menu actions
  rely on it.
- `doctor` reports both integrations. Absent is the normal case and is not counted
  as a failure; only a `-LudusaviExe` the user named that does not exist is.
- 26 tests (73 total): argument quoting for Windows, the JSON shapes the Ludusavi
  CLI answers with, path clustering and its specificity guard, token rewriting,
  the append-only map writers, the extension manifest agreeing with its own folder,
  the Playnite export round-trip, and matching a shelf against a library by path
  and by name. (75 after the two fixes below.)

### Changed

- **The launcher can be checked without eyes, further than before.** `-Diag` grew
  from a grid-geometry dump into a layout audit: it measures whether each text block
  actually fits (flagging silent clipping), computes WCAG AA contrast for every
  label against the surface it is really drawn on — blending the backgrounds in
  between, alpha included, and printing the layer chain for any failure — and
  reports hit targets under 32px. New `-Shot <png>` renders the same composed window
  to a file and exits, because geometry and ratios cannot tell you whether a
  gradient is muddy or the spacing looks right. That is also how the two fixes below
  were found, on a machine with no display.
- **The launcher's hero says what it is doing.** With nothing played yet the banner
  showed the first entry on the shelf under a `最近游玩` kicker, which claimed a
  history that did not exist; it now says `开始游玩`. The button label follows the
  click: `打开目录` for a collection or archive, `未设置启动程序` when the entry has
  no executable yet — before, all three cases read `启动`. The status line reports
  what is on screen (`搜索：3 个结果`) rather than the whole library next to a
  heading that says something else, and tiles carry a hover tooltip with their note
  and real folder.
- `playnite -Shelf` caps each of its two lists at 15 entries with an "and N more"
  line. On a 63-entry shelf against a 4-game library the uncapped list pushed the
  matching summary off the screen, which is the part anyone asked for.

### Fixed

- **The launcher cut two `▶` glyphs.** Each measured a pixel wider than the box it
  was given, with no trimming, so the right edge of the triangle was sliced off —
  invisible until the audit started comparing required width against available
  width. `MinWidth` gives them room, and the audit reports `clipped : 0`.
- **Three launcher labels were below WCAG AA**: the status line at 3.76:1 and the
  search hint at 3.23:1 against a required 4.5:1 for their size, plus a nav label.
  Lightened until the audit says `all readable`.
- The launcher wrote its single-instance pid file next to the script instead of in
  `<shelf>\_ui`, where the README documents it and where `_recent.txt` and
  `_layout.log` already live. Identical when installed into a shelf; running from a
  checkout, two copies now find each other's marker instead of each writing its own.
- **`adopt` rewrote a hand-curated save map's line endings.** `WriteAllLines`
  writes CRLF, so appending one entry to an LF file turned a one-line change into a
  sixty-line diff — observed on the first real shelf it ran against. The map
  writers now keep the file's own newline style and BOM (`Write-GSLineFile`), and
  `Export-GSSaveMap`-written files stay CRLF unchanged. Tested both ways.
- **A resolved title the preview said nothing about was reported as "no such title
  in its manifest"**, which was wrong in a way that mattered: Ludusavi omits a game
  from `--preview` whenever it resolves no paths for it, and that is the ordinary
  outcome for a game it cannot locate — an archive copy, a repack, a portable build
  in an unexpected folder — or one whose manifest entry lists no files at all.
  Checked against the real manifest to confirm that is what those entries look
  like. The proposal now says "ludusavi resolved no paths for '<title>'", and a
  title the preview explicitly calls unknown is reported separately.
- `restore` carried its backup-selection block twice, verbatim. The second copy is
  gone; behaviour is unchanged.
- `playnite -Out` reported "no game has an install folder" when the real reason was
  that every game had been filtered out, which is what `-SkipLauncherManaged` does
  to a library that is all Steam and Epic. It now says so and names the filters.

### Notes

- Three PowerShell traps this hit, all now written down where they bit:
  - `@($list)` **throws** "parameter type mismatch" when the list is a
    `List[object]` — a `List[string]` is fine, which is exactly what makes it easy
    to walk into. Use `.ToArray()`.
  - a local named `$root` is the CLI's `[string[]]$Root` parameter, because
    PowerShell variable names are case-insensitive. Assigning a string to it
    retypes it, and it then refuses to bind back into a `[string]` parameter
    further down. Same family as the `$all` and `$name` notes from 1.2.0.
  - `[Parameter(Mandatory)][string[]]` **rejects an array containing an empty
    string**, so rebinding a file's lines through such a parameter fails on any map
    with a blank line in it. `[AllowEmptyString()]` is required.

## [1.2.0] - 2026-09-20

### Added

- **Save-data backup and restore**, as CLI commands: `saves`, `backup`, `backups`,
  `restore`. Sources come from a curated `<shelf>\_saves.txt` map (the same idea as
  `_launch.txt`: guessing is unreliable), backups land in
  `<shelf>\_saves\<entry>\<timestamp>\` with a manifest per set, and `-Store` can
  move the store to a roomier drive.
- `Find-GSSaveCandidate` suggests save locations for unmapped games by looking for
  save-named folders inside the game and probing per-user locations using the
  executable's company/product metadata and its own file name.
- Restores are reversible: the live saves are written to a `_prerestore_*` folder
  before being overwritten.
- 15 tests covering map round-trips, token expansion, backup/list/prune, a byte-exact
  restore with its safety copy, and candidate discovery.

### Fixed

- **`Get-GSShelf` and `Test-GSShelf` returned `List` values, which makes `@()` throw
  "parameter type mismatch"** for callers even though `.Count` and `foreach` work.
  Both now return plain arrays.
- `Resolve-GSSavePath` left a bare relative path untouched, so it resolved against
  the current directory instead of the game's folder.
- Two variables in `gameshelf.ps1` shadowed its own parameters, because PowerShell
  variable names are case-insensitive: a local `$all` assigned to the `-All` switch
  (throwing "cannot convert to SwitchParameter") and a local `$name` assigned to
  `-Name`. Renamed. Worth knowing if you write more commands into this script.

## [1.1.1] - 2026-09-20

### Changed

- **Launcher layout is tiled instead of railed.** The per-category horizontally
  scrolling rails were awkward to browse — every category needed sideways
  dragging. Sections are now `WrapPanel`s inside the single vertical scroll, so a
  library is browsed by scrolling down only. On a 1440-wide window that settles at
  seven tiles per row; a 25-game category becomes four rows. Verified with
  `-Diag`, which reports `horizontal scroll : Collapsed`.
- **Icon is crisp at every size.** It now carries 16, 24, 32, 48, 64, 128 and 256
  pixel frames, each drawn at its own resolution rather than downscaled from one
  big bitmap, and uses gradients (tile, green button, rims) instead of flat fills.

### Added

- **Single instance per shelf.** Clicking the shortcut again restores and focuses
  the running window instead of opening a second copy. A named mutex keyed on the
  shelf path decides ownership, the owner records its pid in
  `<shelf>\_ui\_instance.pid`, and a later launch forwards to it. A stale pid file
  from a killed run is detected and taken over.
- `-Diag` on the launcher: builds the window, writes the measured grid geometry
  (columns, rows, panel size) to `<shelf>\_ui\_layout.log` and exits without
  showing anything. Useful for checking a layout change on a machine you cannot
  look at.

## [1.1.0] - 2026-09-20

Adds a graphical front end. The CLI is unchanged.

### Added

- **`launcher/GameLauncher.ps1`** — an Xbox-style window onto a shelf: left nav
  rail, hero banner for the most recently played game, a tiled section per
  category, square tiles with white-outline focus states, and a green play
  action.
- **`launcher/install.ps1`** — copies the launcher into `<shelf>\_ui\`, generates
  a matching icon, writes a no-console `.vbs` entry point and creates a Desktop
  shortcut.
- **`_launch.txt`** — an explicit map from shelf entry to executable. Heuristic
  detection picks the wrong file roughly half the time on a real library (the
  largest executable in a Cyberpunk 2077 folder is a repack installer, the one in
  Wizard of Legend 2 is a 3 GB self-extractor, Elden Ring ships an artbook
  player), so the curated map is the source of truth and the heuristic is only a
  fallback. Right-click a tile to correct one; it is written back.
- **Recently played** tracking in `<shelf>\_ui\_recent.txt`, driving the hero
  banner and a dedicated section.
- `-Sakura` for drifting petals; the default look is monochrome.

### Fixed

- A launcher started via `WScript.Shell.Run(..., 0, ...)` inherits `SW_HIDE` as
  its startup show-state, so WPF's first window came up minimized at
  `-16000,-16000` while reporting `IsWindowVisible = True`. The window is now
  forced back with `ShowWindow(SW_RESTORE)` plus `SetForegroundWindow` once its
  handle exists; setting `WindowState = 'Normal'` alone does not help.
- Card subtitles rendered the rating tag for entries whose note begins with one,
  so fifteen tiles read `18+` instead of the game's original name.

## [1.0.0] - 2026-09-20

First release.

### Added

- `doctor` — environment check that creates and removes a real junction in the
  temp directory, so "can this machine do it" is answered by evidence rather
  than by version numbers.
- `scan` — read-only sweep of one or more roots. Detects games from executables
  and engine markers (Unity, Unreal, GameMaker, Godot, KiriKiri, Ren'Py,
  RPG Maker, LiveMaker, BepInEx, NW.js, Steam stub), penalises folders that are
  mostly media, and labels launcher libraries separately. Emits a draft manifest
  plus an optional CSV report explaining every decision.
- `build` — materialise a shelf in `Link`, `Move` or `Copy` mode. Merges into an
  existing shelf by default so games can be added incrementally; `-Replace`
  switches to the manifest being the single source of truth.
- `list`, `verify`, `index` (Markdown + CSV catalogue), `remove`.
- Manifest format: pipe-delimited text or CSV, UTF-8, with `#` comments and an
  optional metadata header.
- Self-describing shelf: `_shelf.txt` next to the links doubles as the manifest
  and as a backup.
- Test suite (`tests/run-tests.ps1`), 32 cases, no Pester dependency.

### Safety properties

- `Remove-GSLink` uses `Directory.Delete(path, recursive: $false)`, so removing a
  shelf entry unlinks the reparse point and cannot follow it into the target.
- `Remove-GSLink` refuses to act on a path that is not a reparse point.
- `Remove-GSShelf` refuses outright on `Move`/`Copy` shelves, where entries are
  real data.
- Folder size walks do not follow junctions, so a shelf never double-counts.
- Junctions are verified after creation; every `verify` re-checks that targets
  still exist.

### Notes

- `Read-GSManifest`, `Write-GSManifest` and `Build-GSShelf` were renamed to
  `Import-GSManifest`, `Export-GSManifest` and `New-GSShelf` so the module uses
  only approved PowerShell verbs and imports without warnings.
