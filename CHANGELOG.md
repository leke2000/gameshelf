# Changelog

All notable changes to GameShelf are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/).

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
