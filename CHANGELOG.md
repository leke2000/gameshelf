# Changelog

All notable changes to GameShelf are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/).

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
