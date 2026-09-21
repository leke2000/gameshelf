# GameShelf Launcher

An Xbox-style front end for a GameShelf. Turns the shelf's plain folder tree into
a browsable game library: hero banner, tiled category sections, focus states, one
click to play.

```
┌──────────────────────────────────────────────────────────────────┐
│  ▶ 游戏库        [ 搜索游戏 ]                    ─  □  ✕        │
├──────┬───────────────────────────────────────────────────────────┤
│ ALL  │  ┌─────────────────────────────────────────────────────┐  │
│ 全部 │  │  最近游玩                                            │  │
│      │  │  ELDEN RING                     ▓▓▓▓▓  EL          │  │
│ RP   │  │  艾尔登法环 · RPG                                    │  │
│ 角色 │  │  ┌──────────┐                                       │  │
│      │  │  │ ▶  启动  │                                       │  │
│ SH   │  │  └──────────┘                                       │  │
│ 射击 │  └─────────────────────────────────────────────────────┘  │
│ ...  │                                                          │
│      │  动作冒险                                        7 款      │
│      │  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐   │
│      │  │  RDR │ │  HK  │ │  SF  │ │  SN  │ │  SR  │ │  CB  │   │
│      │  └──────┘ └──────┘ └──────┘ └──────┘ └──────┘ └──────┘   │
│      │  Red Dead  Hollow   Split    Subnau   Subnau2  Cyber    │
│      │  ┌──────┐                                                │
│      │  │  ER  │   ← wraps to the next row, no sideways drag   │
│      │  └──────┘                                                │
│      │                                                          │
│      │  角色扮演                                        6 款      │
│      │  ┌──────┐ ┌──────┐ ...                                  │
└──────┴───────────────────────────────────────────────────────────┘
```

## Requirements

- Windows, Windows PowerShell 5.1 or PowerShell 7+
- A shelf built by [GameShelf](../README.md) (a folder containing `_shelf.txt`)
- No admin rights, no dependencies

## Install

```powershell
cd launcher
.\install.ps1 -ShelfPath H:\Games
```

That copies the launcher into `<shelf>\_ui\`, generates a matching icon, writes a
no-console `.vbs` entry point, and puts a shortcut on the Desktop. Use
`-ShortcutName 'Games'` to name it something else, or `-NoShortcut` to skip it.

For a shelf kept somewhere else, point `-ShelfPath` at it; the launcher finds its
shelf by walking up from its own folder.

## Using it

| Action | What happens |
|---|---|
| Double-click a tile | Starts the game |
| Hero button | Starts the most recently played game; before anything has been played it shows the first entry on the shelf, and the kicker says so (`开始游玩` instead of `最近游玩`). The label follows what the click will do: `启动`, `打开目录` for a collection or archive, `未设置启动程序` when the entry has no executable yet |
| Hover a tile | Shows the entry's note and its real folder, which is what the context menu copies |
| Type in the search box | Filters every entry by name, original name and category; the status line switches to the result count |
| Click a nav rail entry | Shows just that category |
| Right-click a tile | Open folder · copy real path · **set launcher** · switch to open-folder |
| Click the shortcut while it is open | Restores and focuses the existing window instead of opening a second one |

Games are started through the **shelf path**, never the recorded target, so an
entry whose real folder sits on a non-ASCII path still launches from an
all-ASCII one.

Launching a game records it in `<shelf>\_ui\_recent.txt`, which drives the hero
banner and the **最近游玩** section.

Only one window runs per shelf. A named mutex keyed on the shelf path decides who
owns it; the owner writes its pid to `_ui\_instance.pid`, and a second launch
reads that, calls `ShowWindow(SW_RESTORE)` plus `SetForegroundWindow` on the
running window and exits. A stale pid file — from a run that was killed rather
than closed — is harmless: no window answers, so the new process takes over.

## Why `_launch.txt` exists

Guessing which executable inside a game folder is the game does not work
reliably. Across one real 62-game shelf, heuristics picked the wrong file about
half the time:

| Game | What heuristics picked | Why |
|---|---|---|
| Cyberpunk 2077 | `setup_redlauncher.exe` (536 MB) | The largest exe in the folder is a repack installer, not the game |
| Wizard of Legend 2 | `Wizard of Legend 2.exe` (3.1 GB) | A self-extracting repack; the game is `Zeus\Binaries\Win64\WOL2-Win64-Shipping.exe` |
| Elden Ring | `ELDEN RING Digital Artbook & Soundtrack.exe` | The folder also ships an artbook and a soundtrack player |
| Forza Horizon 5 | `msedgewebview2.exe` | A WebView2 runtime ships next to the game |

So the launcher reads an explicit map, `<shelf>\_launch.txt`:

```
# <shelf entry name>|<path to exe, relative to that game's folder>
Elden Ring|Ring\Game\eldenring.exe
Forza Horizon 5|ForzaHorizon5.exe
God of War Ragnarok archive|FOLDER
```

`FOLDER` means "there is no executable, open the folder" — used for collections
and for archives that have not been extracted yet. Anything not listed falls back
to the heuristic, and right-click → **设置启动程序…** writes the correction back
to this file.

## Design notes

The layout follows the Xbox app: a thin left nav rail, a hero banner, then a
tiled section per category. Tiles are square with the title and the
original-language name underneath, and the focus state is a white outline plus a
small lift, which is what makes a console library feel navigable rather than
dense.

Sections are `WrapPanel`s inside the one vertically scrolling surface, so a
library is browsed by scrolling down and nothing needs sideways dragging. On a
1440-wide window that settles at seven tiles per row; a 25-game category becomes
four rows.

Everything is drawn from the shelf's own data — there is no cover art to fetch.
Each tile gets a stable gradient derived from an FNV-1a hash of the entry name,
with the game's real icon read from its executable, so a library of 60-odd
unfamiliar names still reads as 60-odd distinct things.

`-Sakura` overlays drifting petals if you want the pastel look; the default is
monochrome.

## Checking a UI change without eyes

Two switches build the whole window off-screen and report on it, so a layout or
colour change can be argued about with numbers instead of taste — and reviewed on a
machine with no display.

`-Diag` writes `<shelf>\_ui\_layout.log` and exits. It reports the grid geometry
(which confirms tiles really wrap into rows instead of forming one long horizontal
strip), then audits the text:

```
window            : 1,440 x 900
scroll viewport   : 1,337 wide
horizontal scroll : Collapsed
top-level blocks  : 25
  grid: 25 tiles   7 columns   4 rows   panel 1,301 x 844

hero              : Akujo no Eikan
  kicker / action : 最近游玩 / 启动

text blocks       : 326
  ellipsised      : 4   (by design, TextTrimming is set)
  clipped         : 0   (no room and no trimming - text is cut)

contrast (WCAG AA: 4.5 body, 3.0 large)
  all readable

hit targets < 32px : 0
```

- **clipped** is text that needs more width than it was given and has no
  `TextTrimming`, so it is silently cut. It found two glyphs sitting one pixel
  inside their border.
- **contrast** is WCAG AA against the surface each label is really drawn on: the
  backgrounds between the text and the window are blended, alpha included, and each
  failing line prints the layer chain it measured so the number can be checked. It
  found three dim greys on near-black (3.2:1 to 4.0:1 against a required 4.5:1).
  Text over a gradient reports against the window colour instead of the gradient, so
  those readings are optimistic — the audit under-reports rather than crying wolf.

`-Shot` renders the same window to a PNG and exits:

```powershell
.\GameLauncher.ps1 -ShelfPath H:\Games -Shot H:\Games\_ui\shelf.png
```

Geometry and ratios cannot tell you whether a gradient is muddy or the spacing looks
right. This is the same window, drawn into a file, so it can be looked at, sent to
someone, or diffed against the previous one after a change.

## On a shelf that travels

If the manifest uses `%label%` targets (see [One shelf, several
machines](../README.md#one-shelf-several-machines)), the launcher resolves them
through `<shelf>\_roots.txt` exactly as the CLI does. The reader is duplicated on
purpose: `install.ps1` copies this script into `<shelf>\_ui\` on its own, which is
what makes the launcher portable, so it cannot import the module — the same reason
it already parses `_shelf.txt` and `_launch.txt` itself.

Only entries this machine actually has are shown, and the status line says how many
are elsewhere (`另有 N 款不在本机`). When none of them are here — a fresh clone whose
roots are not bound yet — the window says so and points at the `roots` command
instead of drawing sixty dead tiles. The tooltip, "copy real path" and the launcher
picker all use the resolved folder, never the portable form.

## One Windows gotcha worth recording

`launch.vbs` starts PowerShell through `WScript.Shell.Run(cmd, 0, False)` so no
console window flashes. That `0` is `SW_HIDE`, and it is passed to the process as
its **startup show-state** — which WPF's first top-level window inherits. The
result is a launcher that runs, renders, and reports `IsWindowVisible = True`
while sitting minimized at `-16000,-16000`.

The fix is to force the window back with a Win32 call once the handle exists:

```powershell
[GameShelf.Native]::ShowWindow($h, 9)      # SW_RESTORE
[GameShelf.Native]::SetForegroundWindow($h)
```

`WindowState = 'Normal'` alone is not enough — WPF still believes the window is
visible, so nothing changes.
