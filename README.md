# GameShelf

**One browsable folder for everything scattered across your drives — without moving a single byte.**

You have games on `C:`, `D:`, `G:`, an old folder on `H:`. Consolidating them
physically needs free space you may not have, and moving game folders breaks
desktop shortcuts, Steam libraries and save files that hard-code their path.

GameShelf gives you the consolidated view without the move. It builds a
categorised folder tree out of **NTFS directory junctions** (and can genuinely
`Move`/`Copy` if you do have the space). Junctions are transparent to
applications: games launch normally, saves keep working, shortcuts are untouched,
and the shelf costs zero bytes.

```
H:\Games\                     <- 0 bytes, nothing moved
├─ Action\
│  ├─ Hollow Knight\          -> junction to G:\Hollow.Knight
│  └─ Elden Ring\             -> junction to D:\SteamLibrary\...\ELDEN RING
├─ Visual Novel\
│  └─ 千恋万花\                -> junction to H:\@game\...
├─ CATALOG.md                 <- generated index with real paths
├─ index.csv
└─ _shelf.txt                 <- the shelf's own manifest, plain text
```

[中文说明在下面 ⬇](#中文说明)

---

## Two parts

| | What it does |
|---|---|
| **GameShelf** (this folder) | Builds and maintains the shelf — a categorised tree of junctions. CLI. |
| **[GameShelf Launcher](launcher/)** | An Xbox-style window onto that shelf: hero banner, tiled categories, one click to play. |

The CLI also backs up and restores game saves — see [Save data](#save-data) — and
can take its save locations from [Ludusavi](#ludusavi) and its game list from
[Playnite](#playnite).

```
launcher\install.ps1 -ShelfPath H:\Games
```

---

## Requirements

- Windows (NTFS junctions are a Windows feature)
- Windows PowerShell 5.1 or PowerShell 7+
- **No administrator rights needed** — junction creation is unprivileged

## Install

```powershell
git clone https://github.com/<you>/gameshelf.git
cd gameshelf
.\gameshelf.ps1 doctor
```

If PowerShell blocks the script:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

There is nothing to install: it is one module and one script, no dependencies.

## Quick start

```powershell
# 1. Make sure this machine can do it
.\gameshelf.ps1 doctor

# 2. Look for games, read-only. Writes a draft manifest you then edit.
.\gameshelf.ps1 scan -Root D:\, E:\, F:\ -Out draft.txt

# 3. Edit draft.txt: set the first column to your own categories,
#    delete anything you don't want on the shelf. Then:
.\gameshelf.ps1 build -Manifest draft.txt -Shelf H:\Games

# 4. Browse H:\Games. Generate the catalogue, or check health later:
.\gameshelf.ps1 index  -Shelf H:\Games
.\gameshelf.ps1 verify -Shelf H:\Games
```

`scan` never guesses categories for you — it emits everything as `Unsorted` and
prints *why* each folder was detected, so you review before anything is built.

## Commands

| Command | What it does |
|---|---|
| `doctor` | Check PowerShell version, Windows, and that junction creation actually works |
| `scan` | Walk roots, detect games by engine markers + executables, emit a draft manifest |
| `build` | Materialise the shelf from a manifest (`Link` / `Move` / `Copy`) |
| `list` | Show what is on the shelf, grouped by category, with sizes |
| `verify` | Check every entry exists, is a junction, and is readable |
| `index` | Regenerate `CATALOG.md` and `index.csv` |
| `remove` | Take entries off the shelf (`-All`, `-Name`, `-Category`) |
| `adopt` | Ask Ludusavi where the unmapped games keep their saves, and record it |
| `playnite` | Read Playnite's library export: draft a manifest, or compare with the shelf |

Every command supports `-WhatIf` and `-Verbose`.

### scan

```powershell
.\gameshelf.ps1 scan -Root D:\ E:\ `
    -Depth 2 `             # how deep to descend (1-4)
    -MinSizeGB 0.05 `      # ignore anything smaller
    -Exclude '*Backup*' `  # extra folder-name globs to skip
    -SkipSize `            # much faster: skip size calculation
    -Out draft.txt `       # draft manifest
    -Csv report.csv        # detection report with reasons
```

Detection is heuristic and deliberately explainable. A folder scores points for
containing executables and for engine markers, and loses points for being mostly
video/image files:

| Signal | Score |
|---|---|
| Contains one or more `.exe` | +2 |
| Unity / Unreal / GameMaker / Godot / KiriKiri / Ren'Py / RPG Maker / LiveMaker / BepInEx / NW.js / Steam stub | +3 each |
| 90%+ media files and no executable | −4 |

A score of 2 or more is reported as a candidate. Launcher libraries
(`steamapps`, `WeGameApps`, `XboxGames`, `Epic Games`, …) are reported
separately and labelled, because re-shelving them breaks the launcher.

### build

```powershell
.\gameshelf.ps1 build -Manifest shelf.txt -Shelf H:\Games -Mode Link
.\gameshelf.ps1 build -Manifest shelf.txt -Shelf H:\Games -Mode Link -WhatIf
```

Building into a shelf that already exists **merges**: entries from earlier
manifests keep their place, so you can add games a few at a time. Pass
`-Replace` to make the current manifest the single source of truth instead.

### remove

```powershell
.\gameshelf.ps1 remove -Shelf H:\Games -Name 'Hollow Knight'
.\gameshelf.ps1 remove -Shelf H:\Games -Category 'Visual Novel'
.\gameshelf.ps1 remove -Shelf H:\Games -All -WhatIf
```

`remove` deletes **junctions only**. It refuses to touch a folder that is not a
reparse point, and on a `Move`/`Copy` shelf it refuses entirely — those entries
are real data and it will not pretend otherwise.

## Save data

A game's saves can be inside the game folder, under `%APPDATA%`, under
`%LOCALAPPDATA%\..\LocalLow`, in `Documents\My Games`, in `Saved Games`, or in a
Steam emulator's own store. Guessing which is unreliable, so the same rule as
launch targets applies: a curated map is the source of truth and detection is a
hint.

```powershell
.\gameshelf.ps1 saves   -Shelf H:\Games              # what is mapped, and candidates for the rest
.\gameshelf.ps1 backup  -Shelf H:\Games -All         # copy saves into the store
.\gameshelf.ps1 backup  -Shelf H:\Games -Name Elden Ring
.\gameshelf.ps1 backups -Shelf H:\Games              # list what is stored
.\gameshelf.ps1 restore -Shelf H:\Games -Name Elden Ring [-Backup <id>]
```

Every one of those also takes `-Target <folder>`, which addresses an entry by the
folder it points at instead of by its label on the shelf. A launcher knows the
folder and not the label, which is why it exists:

```powershell
.\gameshelf.ps1 backup -Shelf H:\Games -Target 'D:\SteamLibrary\...\ELDEN RING'
```

The map is `<shelf>\_saves.txt`:

```
# <shelf entry name>|<path>[;<path>...]
Subnautica|GAME\SNAppData
Cyberpunk 2077|%SAVEDGAMES%\CD Projekt Red\Cyberpunk 2077
Elden Ring|%APPDATA%\EldenRing
```

Paths accept `%APPDATA%`, `%LOCALAPPDATA%`, `%USERPROFILE%`, `%DOCUMENTS%`,
`%SAVEDGAMES%`, `%LOCALLOW%`, a `GAME\` prefix, or a bare relative path — the last
two resolve against the game's own folder.

Backups land in `<shelf>\_saves\<entry>\<timestamp>\` as `p0`, `p1`, … with a
`_backup.txt` manifest recording what each one came from. `-Store` puts the store
somewhere else, which matters when the shelf is on a small system drive: a full
set runs to a couple of GB and `-Keep` (default 10) multiplies that.

**Restoring is undoable.** The live saves are copied to a `_prerestore_*` folder
first, so a mistaken restore can be walked back. Live paths are cleared before the
copy, so the result reflects the backup rather than merging with it.

### Detection, and why it is only a hint

`saves` reports candidates for games that are not mapped yet. It looks for
save-named folders inside the game, then probes the usual per-user locations using
the executable's company and product metadata and its own file name (Unreal names
its user folder after the project, which is the executable). On one real 63-game
shelf that found something for 44 of them — useful, but it also produced misses
and false positives, which is why the curated map exists.

## Ludusavi

[Ludusavi](https://github.com/mtkennerly/ludusavi) keeps a curated manifest of save
locations for 19,000+ games, compiled from PCGamingWiki. The section above ends on
"44 of 63, useful but imperfect"; this replaces that guesswork with data.

```powershell
.\gameshelf.ps1 saves -Shelf H:\Games -Ludusavi   # what Ludusavi knows. writes nothing
.\gameshelf.ps1 adopt -Shelf H:\Games -All        # write it into the save map
.\gameshelf.ps1 adopt -Shelf H:\Games -Name '千恋万花' -Title 'Senren * Banka'
```

Ludusavi is *asked* rather than its manifest parsed: GameShelf runs
`ludusavi backup --preview --api`, which resolves placeholders, globs, store user
ids and registry keys exactly as a real backup would and answers in JSON. Nothing
is backed up. `--no-manifest-update` is passed by default, so a first run reports
that the manifest is missing instead of quietly downloading 17 MB.

The reply lists files, which is the wrong shape for a save map, so they are
collapsed onto the smallest set of folders that covers them and rewritten with the
tokens the map already uses (`%APPDATA%\…`, `GAME\saves`). Two games whose saves
live in unrelated subfolders of `%APPDATA%` are kept apart rather than merged into
a `%APPDATA%` entry, which would mean backing up the whole roaming profile.

Adopting only ever adds. An entry already in `_saves.txt` is never touched and the
file is appended to rather than rewritten, so comments you left in it survive. When
a shelf label is not the game's title, pin it once in `_ludusavi.txt`:

```
# <shelf entry name>|<ludusavi title>
千恋万花|Senren * Banka
```

That map is consulted first; otherwise the best fuzzy match is used, and a match
below `-MinScore` (default 0.8) is reported but not adopted. Registry keys Ludusavi
also covers are counted and said out loud — GameShelf backs up files only.

Ludusavi only answers for games it can work out paths for. One it cannot locate —
an archive copy, a repack, a portable build sitting in a folder nobody told it
about — or one whose manifest entry defines no save files at all comes back with no
paths, and `adopt` says `resolved no paths for '<title>'` rather than inventing
something. On the shelf this was tested against, one of eight unmapped entries
could be resolved; the rest were archived or repacked copies. `-Title` does not
help there, because the title was already right.

Needs `ludusavi.exe`: put it on `PATH`, or pass `-LudusaviExe <path>` / set
`$env:LUDUSAVI_EXE`. `doctor` reports what it finds.

## Playnite

[Playnite](https://playnite.link) already knows what is installed, where, how long
it has been played and how you sorted it. The extension in
[`integrations/playnite/`](integrations/playnite/) exports that library; the CLI
reads the export.

```powershell
.\gameshelf.ps1 playnite -Install           # copy the extension into Playnite
# restart Playnite, then: Extensions > GameShelf > Export library
.\gameshelf.ps1 playnite -Out draft.txt     # draft a shelf manifest from the library
.\gameshelf.ps1 playnite -Shelf H:\Games    # the shelf vs what Playnite has
```

`-Out` drafts a manifest of the same shape `scan` produces, except the categories
are your own Playnite categories (falling back to genres), the note carries
playtime, last-played and store, and nothing had to be guessed by walking drives.
`-Shelf` reports both directions: shelf entries Playnite does not know, and
installed games that are not on the shelf yet.

Matching is on the install path first — a shelf entry's target is literally the
folder Playnite launches from — and on the name second, which is reported
separately because a shelf label can be a rename. Games from a launcher store
(Steam, Epic, GOG, Xbox, …) are labelled, since the warning about launcher-managed
libraries applies to them; `-SkipLauncherManaged` leaves them out.

The extension also adds two entries to Playnite's game menu — back up this game's
saves, show its save locations — and those address the shelf with `-Target`, so
they work whatever the shelf calls the game.

The seam is a JSON file rather than a reading of Playnite's database on purpose:
`games.db` is LiteDB, its maintainer asks third-party tools not to read it
("If you want to access game library data, you need to make a plugin for
Playnite"), and the format is due to change. It also keeps the extension thin
enough to port — Playnite 11 drops PowerShell script extensions, and only the
export writer would have to move.

## Manifest format

Plain text, one entry per line, UTF-8. Pipe-separated:

```
category|name|target|note
```

```
# lines starting with # are ignored
Action|Hollow Knight|G:\Hollow.Knight|includes save editor
Visual Novel|千恋万花|H:\@game\千恋万花|18+
```

`name` is the label on the shelf and does not have to match the folder on disk —
which is handy for renaming folders whose real name is a serial number.
`note` is free text and shows up in `CATALOG.md`.

A `.csv` file with columns `category,name,target,note` works too, so the manifest
round-trips through Excel.

## Safety

The design assumes your data is more important than tidiness.

- **Nothing is deleted, ever.** The only delete operation is
  `Directory.Delete(path, recursive: $false)`, which unlinks the reparse point
  itself. Recursive deletion APIs are deliberately avoided: they can follow a
  junction and destroy the target folder.
- **Real folders are never removed.** `Remove-GSLink` throws if the path is not
  a junction.
- **A junction is verified after creation**, and its target re-checked on every
  `verify`. Broken links are reported, not hidden.
- **`-WhatIf` on everything**, and `remove` asks for confirmation.
- **The shelf is self-describing.** `_shelf.txt` next to the links is plain text
  and doubles as a backup of the manifest. No database, no hidden state.
- **Sizes never double-count.** Folder size walks do not follow junctions.

## Modes, and when not to use Link

| Mode | Cost | Use when |
|---|---|---|
| `Link` (default) | 0 bytes, instant | You want one view across drives and don't need to free space |
| `Move` | Hours; needs no extra space within a volume | You want the data physically together and have space |
| `Copy` | Needs free space equal to the payload | You want a backup copy |

**Link mode is not a backup.** The data still lives on its original drive. If
that drive dies, the shelf entry dies with it. And never delete a target folder
"because it's on the shelf too" — the shelf *is* the target.

Two cases where Link mode is the wrong tool:

- **Online games with anti-cheat** (most live-service titles). They verify their
  own install path and may refuse to launch or demand a re-download. Leave them
  where the launcher put them.
- **Launcher-managed libraries** (Steam, Epic, WeGame, Xbox). Move installs
  through the launcher, which updates its own manifests, rather than through the
  filesystem.

Neither is a limitation of GameShelf; both are properties of how those games
verify themselves.

## Tests

No Pester needed:

```powershell
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

32 cases covering manifest round-trips (including non-ASCII), junction safety,
detection heuristics, the full build/list/verify/index/remove lifecycle, merge
vs. replace semantics, and the guarantee that removal never touches data —
plus the save-data suite and the integration suite: argument quoting, the JSON
shapes the Ludusavi CLI answers with, path clustering and its specificity guard,
the append-only map writers, the Playnite export round-trip, and matching a shelf
against a library by path and by name. 73 in total.

## Notes on writing PowerShell for this project

`.ps1`/`.psm1` files are **UTF-8 with BOM** and CRLF, because Windows PowerShell
5.1 reads BOM-less files as the system ANSI codepage and mangles non-ASCII
strings — a real problem for a tool that handles Japanese and Chinese folder
names. See `.editorconfig`.

## License

MIT. See [LICENSE](LICENSE).

---

# 中文说明

**把散落在各个盘里的游戏汇总到一个文件夹，一个字节都不用搬。**

你的游戏可能散在 `C:`、`D:`、`G:`，还有 `H:` 上某个旧目录里。想合并到一处，
要么空间不够，要么搬动之后桌面快捷方式失效、Steam 库认不出来、写死路径的存档
找不到。

GameShelf 给你合并后的视图，但不搬文件。它用 **NTFS 目录联接（junction）**
搭出一棵分类目录树，也支持真正搬移（`Move`）/ 复制（`Copy`）。联接对程序完全
透明：游戏照常启动，存档照常工作，快捷方式原样有效，而整个「文件架」占用 0 字节。

## 两个部分

| | 作用 |
|---|---|
| **GameShelf**（本目录） | 建立和维护文件架本身——一棵分类联接目录树，命令行工具 |
| **[GameShelf Launcher](launcher/)** | 仿 Xbox 的图形界面：主推位、平铺分类、最近游玩，双击即启动 |

```
launcher\install.ps1 -ShelfPath H:\Games
```

## 环境要求

- Windows（目录联接是 Windows 的特性）
- Windows PowerShell 5.1 或 PowerShell 7+
- **不需要管理员权限**

## 快速上手

```powershell
.\gameshelf.ps1 doctor                                            # 先自检
.\gameshelf.ps1 scan   -Root D:\, E:\, F:\ -Out draft.txt         # 只读扫描，产出草稿
# 打开 draft.txt，把第一列改成你自己的分类，删掉不想收录的
.\gameshelf.ps1 build  -Manifest draft.txt -Shelf H:\Games        # 建立文件架
.\gameshelf.ps1 list   -Shelf H:\Games                            # 查看
.\gameshelf.ps1 index  -Shelf H:\Games                            # 生成 CATALOG.md
.\gameshelf.ps1 verify -Shelf H:\Games                            # 体检
```

`scan` 不会替你猜分类，一律先标成 `Unsorted`，并且会打印**为什么**判定它是游戏，
方便你逐条核对后再建架。

## 命令一览

| 命令 | 作用 |
|---|---|
| `doctor` | 检查 PowerShell 版本、系统、以及目录联接能否真正创建 |
| `scan` | 扫描指定盘，按引擎特征 + 可执行文件识别游戏，产出草稿清单 |
| `build` | 按清单生成文件架（`Link` / `Move` / `Copy`） |
| `list` | 按分类列出文件架内容与体积 |
| `verify` | 逐个校验条目是否存在、是否为联接、是否可读取 |
| `index` | 重新生成 `CATALOG.md` 和 `index.csv` |
| `remove` | 取下条目（`-All` / `-Name` / `-Category`） |
| `adopt` | 让 Ludusavi 指出未映射游戏的存档位置并记录下来 |
| `playnite` | 读取 Playnite 的游戏库导出：生成清单，或与文件架对照 |

所有命令都支持 `-WhatIf` 和 `-Verbose`。

## 存档备份

游戏的存档可能在游戏自己目录里，也可能在 `%APPDATA%`、`%LOCALAPPDATA%\..\LocalLow`、
`Documents\My Games`、`Saved Games`，或者某个 Steam 模拟器的目录里。猜不准，所以和启动
目标一个原则：**以手工核对的映射表为准，自动识别只作提示**。

```powershell
.\gameshelf.ps1 saves   -Shelf H:\Games              # 看已映射的，以及未映射游戏的候选位置
.\gameshelf.ps1 backup  -Shelf H:\Games -All         # 全量备份
.\gameshelf.ps1 backup  -Shelf H:\Games -Name 艾尔登法环
.\gameshelf.ps1 backups -Shelf H:\Games              # 列出已有备份
.\gameshelf.ps1 restore -Shelf H:\Games -Name 艾尔登法环 [-Backup <id>]
```

这几条命令都支持 `-Target <文件夹>`：用条目指向的真实目录来定位它，而不是用文件架上的
名字。启动器只知道目录、不知道你给它起的名字，这个参数就是为这种场景准备的：

```powershell
.\gameshelf.ps1 backup -Shelf H:\Games -Target 'D:\SteamLibrary\...\ELDEN RING'
```

映射表是 `<文件架>\_saves.txt`：

```
# <条目名>|<路径>[;<路径>...]
Subnautica|GAME\SNAppData
Cyberpunk 2077|%SAVEDGAMES%\CD Projekt Red\Cyberpunk 2077
Elden Ring|%APPDATA%\EldenRing
```

路径支持 `%APPDATA%` `%LOCALAPPDATA%` `%USERPROFILE%` `%DOCUMENTS%` `%SAVEDGAMES%`
`%LOCALLOW%` 这些记号，也支持 `GAME\` 前缀或直接写相对路径——后两者都相对游戏自己的目录。

备份放在 `<文件架>\_saves\<游戏>\<时间戳>\`，内含 `p0`、`p1`… 和一份 `_backup.txt`
清单（记录每个 pN 来自哪里）。`-Store` 可以把备份库放到别处——文件架在小容量系统盘上
时这点很重要：全量备份约 2GB，`-Keep`（默认 10）再乘上去就顶爆了。

**恢复是可回退的。** 恢复前会先把当前存档完整复制到 `_prerestore_*` 目录，所以恢复错了
还能退回恢复前的状态。覆盖前会清空目标，保证结果是"备份的样子"而不是与现有内容混合。

### 自动识别为什么只作提示

`saves` 会给未映射的游戏列出候选位置：先找游戏目录里名字像存档的文件夹，再用 exe 的
公司名/产品名和 exe 自身文件名去探测常见的用户目录（虚幻引擎的用户目录就是用项目名，
也就是 exe 名）。在一份真实的 63 游戏文件架上，这样能对 44 个找到线索——有用，但既有漏
也有误报，所以最终仍然依赖手工核对的映射表。

## Ludusavi

[Ludusavi](https://github.com/mtkennerly/ludusavi) 维护着一份从 PCGamingWiki 整理的
存档位置清单，覆盖 19000 多款游戏。上一节说「63 个里能猜到 44 个，有用但不完善」，
这一节就是用数据替掉那部分猜测。

```powershell
.\gameshelf.ps1 saves -Shelf H:\Games -Ludusavi   # 看 Ludusavi 知道什么，不写任何文件
.\gameshelf.ps1 adopt -Shelf H:\Games -All        # 写进存档映射表
.\gameshelf.ps1 adopt -Shelf H:\Games -Name '千恋万花' -Title 'Senren * Banka'
```

这里不是去解析 Ludusavi 的清单文件，而是**直接问它**：GameShelf 调用
`ludusavi backup --preview --api`，由 Ludusavi 按真实备份的方式展开占位符、通配符、
商店用户 ID 和注册表项，再用 JSON 回话；全程不会真的备份。默认会附加
`--no-manifest-update`，所以第一次运行时它会老实告诉你清单还没缓存，而不是偷偷下载 17MB。

返回的是一堆文件路径，这对存档映射表来说形状不对，所以会先聚合成「能覆盖它们的最小目录
集合」，再改写成映射表本来的记号（`%APPDATA%\…`、`GAME\saves`）。两款游戏的存档如果分别
在 `%APPDATA%` 下互不相干的子目录里，它们会各自成条，而不会被合并成一条 `%APPDATA%`
——那等于把整个漫游配置目录都备份了。

采纳只做加法：`_saves.txt` 里已有的条目绝不改动，文件是**追加**而不是重写，所以你手写的
注释会保留。文件架上的名字和游戏标题对不上时（比如「千恋万花」对「Senren * Banka」），
在 `_ludusavi.txt` 里钉一次即可：

```
# <文件架条目名>|<ludusavi 标题>
千恋万花|Senren * Banka
```

这张对照表优先于模糊匹配；模糊匹配低于 `-MinScore`（默认 0.8）的会被报出来但不会采纳。
Ludusavi 同时覆盖的注册表项会被统计并明确说明——GameShelf 只备份文件。

Ludusavi 只为它能算出路径的游戏作答。它定位不到的游戏——归档留存版、重打包版、放在它
不知道的目录里的便携版——以及清单条目里压根没定义存档文件的游戏，都会返回空路径，
`adopt` 会如实写「resolved no paths for '<标题>'」，而不是凭空造一条。在实测的那份文件架上，
8 个未映射条目里只有 1 个能解析出来，其余都是归档或重打包的副本。这种情况 `-Title`
也帮不上忙，因为标题本来就是对的。

需要 `ludusavi.exe`：放进 `PATH`，或用 `-LudusaviExe <路径>` / `$env:LUDUSAVI_EXE` 指定。
`doctor` 会检查并报告。

## Playnite

[Playnite](https://playnite.link) 本来就知道装了哪些游戏、装在哪、玩了多久、怎么分类的。
[`integrations/playnite/`](integrations/playnite/) 里的扩展负责把游戏库导出，命令行这边
负责读。

```powershell
.\gameshelf.ps1 playnite -Install           # 把扩展装进 Playnite
# 重启 Playnite，然后：扩展 > GameShelf > Export library
.\gameshelf.ps1 playnite -Out draft.txt     # 用游戏库生成清单草稿
.\gameshelf.ps1 playnite -Shelf H:\Games    # 文件架与 Playnite 互相对照
```

`-Out` 产出的清单和 `scan` 的形状一样，区别在于：分类直接用你在 Playnite 里分的类
（没有则退回类型），备注里带游玩时长、最近游玩和来源平台，而且完全不需要扫盘去猜。
`-Shelf` 会双向报告：Playnite 不认识的条目，以及已安装但还没上架的游戏。

匹配先看安装目录（文件架条目的目标就是 Playnite 启动游戏用的那个目录），再看名字；
名字匹配会单独标注，因为文件架上的名字可能是改过的。来自商店启动器（Steam、Epic、GOG、
Xbox 等）的游戏会被标注出来，因为 README 里关于「启动器管理的游戏库」的提醒对它们适用；
`-SkipLauncherManaged` 可以把它们排除在外。

扩展还会在 Playnite 的游戏右键菜单里加两项——备份这款游戏的存档、查看它的存档位置——
它们用 `-Target` 定位文件架条目，所以无论你在文件架上叫它什么名字都能用。

两边之间的交接文件是 JSON，而不是直接读 Playnite 的数据库，这是有意的：`games.db` 是
LiteDB 格式，作者明确请求第三方工具不要直接读（"If you want to access game library data,
you need to make a plugin for Playnite"），而且这个格式即将变动。这样做也让扩展足够薄、
便于迁移——Playnite 11 会移除 PowerShell 脚本扩展，到时候只需要把导出那部分改写掉。

## 清单格式

纯文本，每行一条，UTF-8，竖线分隔：

```
分类|名称|实际路径|备注
```

```
Action|空洞骑士|G:\Hollow.Knight|含修改器
Visual Novel|千恋万花|H:\@game\千恋万花|18+
```

「名称」是文件架上显示的名字，**不必**和磁盘上的文件夹同名 —— 这对那些真实
文件名是一串乱码或编号的情况特别有用。也可以直接用 `.csv`（列名
`category,name,target,note`），方便用 Excel 编辑。

## 安全设计

这工具的前提是：你的数据比整洁重要。

- **绝不删除任何文件。** 唯一的删除操作是
  `Directory.Delete(path, recursive: $false)`，它只摘掉联接本身。刻意回避了
  递归删除接口 —— 它们可能顺着联接把你的原始目录整个删掉。
- **绝不删除真实目录。** 路径不是联接时，`Remove-GSLink` 直接报错拒绝。
- **联接建完立即校验**，`verify` 每次都会重新确认目标还在。死链会被报出来，
  不会被藏起来。
- **所有命令支持 `-WhatIf`**，`remove` 还会二次确认。
- **文件架自带说明。** 根目录的 `_shelf.txt` 是纯文本，同时就是清单的备份。
  没有数据库，没有隐藏状态。
- **体积不会重复计算。** 统计大小时不跟随联接。

## 三种模式，以及什么时候不该用 Link

| 模式 | 代价 | 适用 |
|---|---|---|
| `Link`（默认） | 0 字节，瞬时 | 想跨盘统一查看，且不需要腾出空间 |
| `Move` | 耗时较长；同盘内不额外占空间 | 想让文件真正集中到一起 |
| `Copy` | 需要等量的空闲空间 | 想额外留一份副本 |

**Link 模式不是备份。** 文件仍在原来的盘上，那块盘坏了，文件架里的入口也就
跟着废了。也**千万不要**因为「文件架里也有一份」就去删原始目录 —— 文件架指向
的就是它本身。

两种情况不适合用 Link：

- **带反作弊的网游**（绝大多数在线服务型游戏）。它们会校验自己的安装路径，
  可能拒绝启动或要求重新下载。留在启动器放的位置就好。
- **启动器管理的游戏库**（Steam、Epic、WeGame、Xbox）。要挪就在启动器里挪，
  它会同步更新自己的清单；直接动文件系统会让它认不出来。

这两条不是 GameShelf 的缺陷，而是这些游戏自我校验的方式决定的。

## 测试

不需要 Pester：

```powershell
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

32 个用例，覆盖清单读写（含中日文非 ASCII 名称）、联接安全、识别启发式、
build/list/verify/index/remove 全流程、合并与替换语义，以及「取下条目绝不碰
数据」这条保证；再加上存档与集成两部分：参数引用、Ludusavi CLI 的 JSON 结构、
路径聚类及其「不许塌缩到根目录」的安全线、只追加的映射表写入、Playnite 导出的往返，
以及按目录和按名字匹配文件架。合计 73 个。

## 许可

MIT，见 [LICENSE](LICENSE)。
