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
vs. replace semantics, and the guarantee that removal never touches data.

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

所有命令都支持 `-WhatIf` 和 `-Verbose`。

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
数据」这条保证。

## 许可

MIT，见 [LICENSE](LICENSE)。
