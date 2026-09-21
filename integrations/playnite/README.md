# GameShelf for Playnite

A Playnite script extension that lets GameShelf see your library: the games, their
install folders, playtime, last-played dates and the categories you already sorted
them into.

It does two things.

| | |
|---|---|
| **Exports your library** to `%APPDATA%\GameShelf\playnite-library.json` | Main menu → `Extensions` → `GameShelf` → `Export library for GameShelf`. Then `gameshelf.ps1 playnite -Out draft.txt` drafts a shelf manifest from it, or `-Shelf <folder>` compares the two. |
| **Runs GameShelf on a game** | Right-click a game → `GameShelf: back up saves` / `GameShelf: show save locations`. Both address the shelf by install folder, so they work whatever the shelf calls the game. |

Nothing is written to your library, and nothing is read from Playnite's database.

## Install

```powershell
.\gameshelf.ps1 playnite -Install
```

That copies this folder into `%APPDATA%\Playnite\Extensions\GameShelf` and writes a
settings file. Restart Playnite afterwards.

Portable Playnite keeps extensions beside itself instead:

```powershell
.\gameshelf.ps1 playnite -Install -PlayniteRoot '<Playnite folder>\Extensions'
```

Or copy this folder to `<Extensions>\GameShelf` by hand — it is two files.

## Settings

`%APPDATA%\GameShelf\playnite-extension.json`, written on first install:

```json
{
  "cli": "D:\\path\\to\\gameshelf\\gameshelf.cmd",
  "shelf": "H:\\Games"
}
```

`cli` is filled in for you; **`shelf` is not**, because the installer cannot know
which folder you built. Set it, restart Playnite, and the game-menu entries work.
The export half needs neither — that is why it works before the settings are filled
in.

## Without the extension

Playnite can run a PowerShell script as a game action, which needs no extension at
all and will keep working after Playnite 11. Add a game action (`Script` type) or an
emulator profile that runs:

```powershell
& 'D:\path\to\gameshelf\gameshelf.cmd' backup -Shelf 'H:\Games' -Target $Game.InstallDirectory
```

The extension exists mostly because a menu item that appears on every game beats
configuring one per game.

## The file format

`playnite-library.json` is the contract between the two halves:

```json
{
  "schema": "gameshelf.playnite.library/1",
  "generated": "2026-09-21T23:18:05",
  "playniteVersion": "10.35",
  "count": 1,
  "games": [
    {
      "id": "…", "name": "Elden Ring",
      "installDir": "D:\\SteamLibrary\\steamapps\\common\\ELDEN RING",
      "isInstalled": true, "playtimeSeconds": 46800, "playCount": 30,
      "lastActivity": "2026-09-19T21:00:00", "added": "2026-03-21T10:00:00",
      "categories": ["Action"], "genres": ["RPG"], "tags": [],
      "source": "Steam", "platforms": ["PC (Windows)"],
      "hidden": false, "favorite": true
    }
  ]
}
```

GameShelf refuses an export whose `schema` it does not recognise rather than
guessing at fields that may have moved. If you write your own exporter, it only has
to produce this.

## Caveats

- **Playnite 11 drops PowerShell script extensions.** The format above is the part
  worth carrying forward: a C# plugin only has to write the same JSON, and the
  GameShelf side needs no change. Until then this works on Playnite 10.
- **Script extensions run inside Playnite with your full rights.** There is no
  sandbox, by design — that is also why the export can be written to `%APPDATA%`.
- **Playnite replaces the whole extension folder on update**, so do not keep
  anything of your own in it. Settings live in `%APPDATA%\GameShelf` for exactly
  this reason.
- If the menu entries do not appear: check Playnite's extension log (it names
  script errors by line), and confirm `Module:` in `extension.yaml` matches the
  file next to it. The module is `GameShelfExtension.psm1`, not `GameShelf.psm1`, so
  that importing it cannot shadow GameShelf's own module of that name.

---

# 中文说明

一个 Playnite 脚本扩展，让 GameShelf 能看到你的游戏库：装了哪些游戏、装在哪、玩了多久、
上次什么时候玩的，以及你早就分好的分类。

它做两件事：

| | |
|---|---|
| **导出游戏库** 到 `%APPDATA%\GameShelf\playnite-library.json` | 主菜单 → `扩展` → `GameShelf` → `Export library for GameShelf`，然后用 `gameshelf.ps1 playnite -Out draft.txt` 生成清单草稿，或 `-Shelf <文件夹>` 与现有文件架对照。 |
| **对单个游戏执行 GameShelf** | 右键游戏 → `GameShelf: back up saves` / `GameShelf: show save locations`。两项都用安装目录定位文件架条目，所以文件架上叫它什么名字都能用。 |

不会改动你的游戏库，也不会去读 Playnite 的数据库。

## 安装

```powershell
.\gameshelf.ps1 playnite -Install
```

它会把本目录复制到 `%APPDATA%\Playnite\Extensions\GameShelf`，并写好设置文件。之后重启
Playnite。

便携版 Playnite 的扩展放在自己旁边，用：

```powershell
.\gameshelf.ps1 playnite -Install -PlayniteRoot '<Playnite 目录>\Extensions'
```

也可以直接手动把本目录复制到 `<扩展目录>\GameShelf`——一共就两个文件。

## 设置

首次安装时会生成 `%APPDATA%\GameShelf\playnite-extension.json`：

```json
{
  "cli": "D:\\path\\to\\gameshelf\\gameshelf.cmd",
  "shelf": "H:\\Games"
}
```

`cli` 会自动填好；**`shelf` 不会**，因为安装程序不可能知道你把文件架建在了哪里。填上它、
重启 Playnite，右键菜单的两项就能用了。导出功能不依赖这两项——所以设置没填也能先导出。

## 不用扩展的做法

Playnite 支持把 PowerShell 脚本挂成游戏动作，这样完全不需要扩展，而且在 Playnite 11 之后
依然有效。新建一个 `Script` 类型的游戏动作（或模拟器配置），内容写：

```powershell
& 'D:\path\to\gameshelf\gameshelf.cmd' backup -Shelf 'H:\Games' -Target $Game.InstallDirectory
```

扩展的存在主要是因为「每个游戏右键都有菜单项」比「逐个游戏配置」省事得多。

## 文件格式

`playnite-library.json` 是两半之间的契约：

```json
{
  "schema": "gameshelf.playnite.library/1",
  "generated": "2026-09-21T23:18:05",
  "playniteVersion": "10.35",
  "count": 1,
  "games": [
    {
      "id": "…", "name": "艾尔登法环",
      "installDir": "D:\\SteamLibrary\\steamapps\\common\\ELDEN RING",
      "isInstalled": true, "playtimeSeconds": 46800, "playCount": 30,
      "lastActivity": "2026-09-19T21:00:00", "added": "2026-03-21T10:00:00",
      "categories": ["Action"], "genres": ["RPG"], "tags": [],
      "source": "Steam", "platforms": ["PC (Windows)"],
      "hidden": false, "favorite": true
    }
  ]
}
```

`schema` 不认识时 GameShelf 会直接拒绝，而不是去猜字段含义。如果你想自己写导出器，只要产出
这个格式即可。

## 注意事项

- **Playnite 11 会移除 PowerShell 脚本扩展。** 上面这个格式才是要留下来的东西：换成 C# 插件
  时只需要写出同样的 JSON，GameShelf 这边不用改。在此之前它在 Playnite 10 上工作。
- **脚本扩展在 Playnite 进程内以你的完整权限运行**，没有沙箱——导出能写进 `%APPDATA%` 也正是
  因为这个。
- **Playnite 更新扩展时会整个文件夹替换**，所以不要把自己的东西放在扩展目录里。设置文件放在
  `%APPDATA%\GameShelf` 就是这个原因。
- 菜单项没出现时：看 Playnite 的扩展日志（会按行指出脚本错误），并确认 `extension.yaml` 里的
  `Module:` 与旁边的文件名一致。模块名是 `GameShelfExtension.psm1` 而不是 `GameShelf.psm1`，
  这样导入它时不会把 GameShelf 自己的同名模块顶掉。
