# GameShelf Launcher

An Xbox-style front end for a GameShelf. Turns the shelf's plain folder tree into
a browsable game library: hero banner, category rails, focus states, one click to
play.

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
│      │  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐            │
│      │  │  RDR │ │  HK  │ │  SF  │ │  SN  │ │ ...  │  →         │
│      │  └──────┘ └──────┘ └──────┘ └──────┘ └──────┘            │
│      │  Red Dead  Hollow   Split    Subnau                       │
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
| Hero **启动** button | Starts the most recently played game |
| Type in the search box | Filters every entry by name, original name and category |
| Click a nav rail entry | Shows just that category |
| Right-click a tile | Open folder · copy real path · **set launcher** · switch to open-folder |

Games are started through the **shelf path**, never the recorded target, so an
entry whose real folder sits on a non-ASCII path still launches from an
all-ASCII one.

Launching a game records it in `<shelf>\_ui\_recent.txt`, which drives the hero
banner and the **最近游玩** rail.

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

The layout follows the Xbox app: a thin left nav rail, a hero banner, then one
horizontally scrolling rail per category. Tiles are square with the title and the
original-language name underneath, and the focus state is a white outline plus a
small lift, which is what makes a console library feel navigable rather than
dense.

Everything is drawn from the shelf's own data — there is no cover art to fetch.
Each tile gets a stable gradient derived from an FNV-1a hash of the entry name,
with the game's real icon read from its executable, so a library of 62 unfamiliar
names still reads as 62 distinct things.

`-Sakura` overlays drifting petals if you want the pastel look; the default is
monochrome.

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
