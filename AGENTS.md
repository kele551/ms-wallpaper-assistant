# AGENTS.md —— 给 AI 编程助手的协作说明（桌面壁纸）

> 这份文件面向用 AI 助手（Claude Code / Codex / Cursor / DSH 等）改这个仓库的人。
> **动手前先读 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**（结构、改哪儿、怎么验）；人类贡献流程见 [CONTRIBUTING.md](docs/CONTRIBUTING.md)。

## 这是什么

Python 启动器（`launcher.py` → 打包成 `桌面壁纸.exe`）+ 两份 PowerShell 脚本（`core.ps1` 换壁纸、`menu.ps1` 菜单），
首次运行释放脚本到 `%LOCALAPPDATA%\壁纸助手`，之后可按 `version.json` 里的指纹热更新。**不需要管理员权限。**

## 环境与命令

```powershell
python -m pip install -r requirements.txt      # 只有打包/发布用得到
python launcher.py                             # 跑起来（等价于双击 exe）
python -m py_compile launcher.py build-exe.py  # 改过 .py 必做
python build-exe.py --release                  # 打包
python tools/preflight_release.py              # 发版前自检（发布前必须全绿）
```

改过 `.ps1` 后必须做一次**语法解析**（0 错误才算过）：

```powershell
$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile("core.ps1",[ref]$null,[ref]$e);$e.Count
```

## 禁区（先看这里，再改）

- **不要手改 `version.json`**。它是在线升级源，由 `tools/make_version_json.py` 在发版时生成；
  里面 `scripts.core.ps1.sha256` / `scripts.menu.ps1.sha256` 必须与仓库里那两个脚本的实际指纹一致 ——
  改了脚本又不动它，热更校验就对不上了（发版时一起重新生成才正确）。
- **`.ps1` 一律 UTF-8 带 BOM**。丢 BOM → PowerShell 5.1 按 ANSI 读 → 中文乱码 → ParserError（历史上真发生过）。
- **行尾**：本仓库入库/检出**一律 LF**；不要整文件重写行尾（会产生"整个文件都变了"的假 diff）。
- **产物文件名不带版本号**（固定 `桌面壁纸.exe`，版本号只写进 exe 属性与界面）。
  文件名唯一来源是 `launcher.py` 的 `EXE_STEM`；老名 `壁纸助手.exe` / `微软壁纸助手.exe` 在
  `core.ps1` 的 `$global:BWExeNamesFixed` 里继续当固定名认，老用户原地升级不会被复制出第二份 exe。
- **对外文案红线词**：绕过 / 翻墙 / 梯子 / 科学上网 / 墙 / 破解 / 屏蔽 —— 一个都不要出现在任何文件里。
- **代码托管只走 GitHub（主仓库）+ GitCode（镜像），Gitee 已废弃（2026-11-06 用户确认永久废弃）**：
  绝不 `git push` 到 gitee.com、绝不把 gitee.com 地址写进任何文件或文档；Gitee 那条线上是 v2.3.2 之前的旧代码，写了也没人收。详见下方「平台」表。
- **面板图片名一律中文（2026-11-05 定的硬规矩）**：凡是显示在面板上的图片 —— 必应 / 聚焦 /
  万象 / 随拍四个在线源、本地文件夹图源、用户手动导入或任何外来图片 —— 都必须显示为
  **描述画面内容的中文名字**。禁止把英文原名、哈希、日期编号、随机串直接暴露给用户；
  磁盘文件名可以保留哈希去重键，但**显示层不许透出来**。
  实现上统一走 `displayName(it)`（panel.html）：优先后端给的中文显示名 → 从文件名提取中文主题
  → 按文件名哈希给一个稳定的中文场景名，任何分支都不许返回非中文结果。
  新图落盘由 `Get-BwSrcName` + `Get-BwSubjectName` / `Get-BwGeoLabel` /
  `Get-BwFlowName` 生成中文名；`Set-BwSrcDescriptiveName` 只作老图兜底
  （已成句的名字直接跳过，不再叠画面色调词）。新增图源、新增面板显示入口
  （图库 / 当前壁纸 / 最近换过 / 收藏 / 统计）时必须一起接这个函数，没接就视为功能未完成。
- **命名 = 一句通顺中文短句，国家 / 地理必须显式写出来（2026-11-06 定的硬规矩）**：
  用户口径原话：「图片太海量了，你不标注国家，地理元素，根本不知道是哪里」；
  「没有必要非要按照必应的方式命名，只要通顺，说明内容就行了，你可以发挥想象力」；
  「要比必应的命名更好」。
  两个 Commons 源的名字是**单段成句**的中文短句，不用 `·` 标签串联、也不用必应新版
  下划线多段式：`丹麦奥胡斯码头落日下的天际线`、`冰岛戈达福斯夏日瀑布的水雾`、
  `摩洛哥撒哈拉沙丘上的骆驼队`。国家放最前、具体地名随后、画面内容收尾。
  **比必应好在哪**：本机盘点必应 150 张只有 16 张带地名(11%)、聚焦 200 张只有
  11 张(6%)，大量「渴了吗」「谁在打盹儿？」这类谜语；必应新版多段式在面板上又只
  显示第一段，地名被吞掉。这里每张都带国家+地名+画面，且单段能被面板整句显示。
  国家和地名**只能来自 Commons 原始元数据**（作品名 / 描述 / 分类），
  经 `Get-BwGeoLabel` 离线词典翻成中文；**「发挥想象力」只用于措辞与句式，
  不用于编造地名或画面主体**。原始英文文件名不展示给用户，但地理信息必须译进中文名。
  `Get-BwFlowName` 把「国家·城市」+ 主体 + 光景拼成通顺短句（如「落日时分的」「…下的」）；
  离线词典的天花板是「达标但平实」，需要文采时可逐张润色，不硬凑。
  **禁止在原名带地理信息时退回看图编**；候选按「有地理标签」优先排序，
  只调顺序、不硬排除（精确 16:9 合格率低，硬排除会拖慢补货）。
- **例外：原名没有国家地理元素时，只能看图编文件名（2026-11-06 用户补充）**：
  「如果文件名字没有国家地理元素，只能看图编文件名」。当 Commons 原始作品名 /
  描述 / 分类里确实**不含任何国家、城市、地标**，且连画面主体也认不出时
  （典型是 `DSC_1234.jpg`、`Sunset.jpg` 这类），才允许看图编中文名 ——
  由 `Set-BwSrcDescriptiveName -VisualFallback` 调用 `Get-BwVisualCaption`
  读落盘后的真实像素，写成一句通顺短句（如 `暮霞暖金中的城市夜景`），
  与正式命名同一口径，不再用 `·` 标签。
  全程本地 System.Drawing、零成本、不联网。**绝不硬编一个不存在的地名，
  绝不编造画面主体**；有地名候选时一律走直译、不叠看图词。
  实现上：万象 / 随拍候选都带 `geo` 字段，`Invoke-BwSrcFetch` 仅在
  `geo` 为空时传 `-VisualFallback`；已带 `·` 的直译名一律跳过。
- **随拍源只用 Commons，不要 Picsum 原图（2026-11-06 定的硬规矩）**：`picsum` 只是内部键名
  （改名会牵动 state.json / sources.json / 面板 DOM id，故保留），但它的图源实现是
  Wikimedia Commons 的**城市 / 人文 / 生活**摄影，与万象的自然 / 野生动物 / 地理主题错开。
  不许再引入 `picsum.photos` 直链或 `Unsplash` 署名。原因：Picsum 官方固定清单只有 993 张、
  静态不增长，且不带任何内容描述，做不到主体级中文名，按"永不重复"约 20 天就轮空。
  新图必须满足：精确 16:9、原图宽 ≥1920、自由授权、Commons 合规署名、连拍组去重、
  主题词持久分页（`picsum_pages.json`）保证池子不枯竭。
- **日期 = 作者拍摄日，不是下载日（2026-11-06 定的硬规矩）**：用户原话
  「我们应该尊重作者的拍摄时间」「加上日期，你也好识别和管理」。
  万象 / 随拍一律取 Commons `extmetadata.DateTimeOriginal`，经 `Get-BwShotDate`
  归一成 `yyyy-MM-dd`，用于**文件名前缀 / 图片内嵌元数据 `date` + `shot_date` /
  面板副行「摄于 YYYY-MM-DD」**。本机实测 30/30 张都有值，格式四类
  （ISO / ISO+时分秒 / `Taken on D Month YYYY` / `D Month YYYY`）。
  取不到拍摄日的候选**直接跳过、不落盘**，绝不拿下载当天冒充；`added_date`
  单独记本机入库日。必应 / 聚焦的前缀仍是微软发布日、副行仍写
  「YYYY-MM-DD 的图」，两套口径不要混。
- **完整署名一行小字（2026-11-06 用户「尊重作者」）**：万象 / 随拍在当前壁纸卡
  下方显示「摄影：完整作者名　·　摄于 日期　·　许可　·　来源」，
  `Get-BwPanelState` 的 `credit` 从图片内嵌元数据读出，前端 `heroCredit`
  用 `muted xs` 小字渲染，只在当前壁纸属于这两个模式时出现，不抢画面、
  **不改中文短句命名**。**不许用作者英文缩写**：CC BY / CC BY-SA 要求完整
  署名标识，缩写不构成合规署名；非商用 / 纯欣赏也不免除署名义务
  （SA 只在改编后再分发时触发）。`source_link` 只认 `commons.wikimedia.org`，
  作者名用 `textContent` 写入；图片内嵌元数据另存 `author`（完整名），
  不另建边车文件。
- **出处集中在主页 + 图库按钮指哪打哪（2026-11-06 定的硬规矩）**：用户原话
  「所有图片的出处，都集中在主页上反映」「三个按键必须指哪打开哪里，
  不能指向图片缩率图」。出处统一放在「当前」页的「图片出处」折叠卡（默认收起），
  `?panel=credits` 要令牌、只读 JPEG 文件头 64KB 的 COM 注释段取内嵌元数据，
  **绝不 `ReadAllBytes` 整张 4K 图**；必应 / 聚焦没有 Commons 详情页就不编链接，
  聚焦的 `© … / Getty Images` 原样保留、不写成「摄影」。不给图库缩略图加第 5 个按钮。
  图库每一项带 `src`（归属库）和仅在带令牌时回的 `path`（真图绝对路径，
  免令牌照旧不回）；`use` / `fav` / `del` 一律按 `src` 在**同一个目录**里定位，
  不跨库模糊搜第一个。「原图」只走 `/api/wall?p=<真图路径>` 或带令牌的
  `?panel=orig&name=`，**绝不退回 `?panel=thumb` 缩略图地址**；
  只有列表的 `<img>` 显示才用 thumb。
- **控制面板默认独立窗口（2026-11-09 定的硬规矩）**：用户原话「不依赖浏览器打开控制面板」。
  双击 exe 必须弹 `桌面壁纸 · 控制面板` 原生窗口（`launcher.py` + `panel_gui.py`，系统 WebView2 承载），
  **绝不打开浏览器**；页面本体仍是 `core.ps1` 内嵌的 `panel.html`，不要另写一套界面、不要砍功能。
  `--browser` / `BWPANEL_BROWSER=1` 是唯一的浏览器入口，只在独立窗口组件不可用时自动回退并记日志。
  `menu.ps1` 在 GUI 模式（`-Gui` / `BWPANEL_GUI=1`）只起服务、绝不开浏览器。
- **署名不要改**：`海风（kele551）`（中文）/ `HaiFeng (kele551)`（ASCII）/ `Copyright (C) 2026 HaiFeng (kele551)`。
- **仓库里不许出现本机路径、私人邮箱、令牌**（`tools/preflight_release.py` 的 ⑥ 节会拦）。
- 升级/自启/还原这类系统行为，改动后要能说清**怎么退回去**。

## 提交与验收

- 提交信息：中文，`类型: 说明`（`fix:` / `feat:` / `docs:` / `chore:`），**一次一件事**；
- **版本号只在发版时改**（`tools/publish.py release <版本> --github` 会同时改三处版本常量并生成升级源）；
- 在 PR / 回复里写清**你跑过哪些命令、结果如何** —— 这个仓库的"契约"是 `tools/preflight_release.py`，能全绿最好；
- 测试会真的启动程序并换掉当前桌面壁纸，跑之前心里有数。

## 平台（主仓库：GitHub）

**2026-10-26 起四款软件只往 GitHub 推**，所以 GitHub 是主仓库，其余三条是历史镜像：

| 平台 | git remote | 状态 |
| --- | --- | --- |
| GitHub `github.com/kele551/ms-wallpaper-assistant` | `github` | **主仓库**，永远是最新的一份 |
| GitCode `gitcode.com/kele551/ms-wallpaper-assistant` | `origin` | 镜像（2026-10-17～10-26 曾为主源），代码可能滞后 |
| AtomGit `atomgit.com/kele551/ms-wallpaper-assistant` | 未配 | 镜像；它会跟着 GitHub 把发行版**附件**一起镜像过来（2026-10-26 实测，早先"传不了附件"的说法已过期） |
| Gitee（kele551 / ms-wallpaper-assistant） | 未配 | **自 v2.3.2 起停止同步，2026-11-06 用户确认永久废弃** —— 那条线上是旧代码，别再写它的地址、也别再 push（连发版闸门都盯着这个） |

**二进制发行包发 GitHub 与 GitCode** 两处（AtomGit 不用手动传：它镜像 GitHub 的发行版与附件）。

```powershell
git push github main --tags                   # 主仓库，必推
git push origin main --tags                   # GitCode 镜像：推了才谈"代码一致"，不推就别在文档里承诺一致
```

⚠ 只推 GitHub 时有一条链路会脱节：`version.json` 里 `scripts` / `launcher` 的**下载地址**
目前由 `tools/make_version_json.py` 写成 GitCode 的绝对地址，而 GitHub 会把中文附件名削掉
（`桌面壁纸.exe` → 见 publish.py 里 `MSWallpaperAssistant-v*.exe` 那段）。
要在 GitHub 单独发布，得同时改那两处地址 —— 客户端读哪份 `version.json` 见 `core.ps1` 的
`$global:BWUpdateUrls`（已按"先 GitHub 后 GitCode"排）。

镜像与主仓库**内容不必逐字节一致**（镜像会滞后），但同一个 tag 的源码必须同源：
判定方法 `git diff github/main <镜像>/main` 只允许出现"镜像还没收到"的那些提交。

## 任务从哪来

GitHub Issues 里带 `good first issue` / `help wanted` 标签的条目，每条都写了**验收标准**；
没有把握的大改动，先开 Issue 说方案再动手。仓库里还有一份机器可读的任务清单 [TASKS.md](TASKS.md)。

---

## English summary (for AI agents)

- **What it is**: a Python launcher (`launcher.py` → packaged as `桌面壁纸.exe`) plus two PowerShell scripts
  (`core.ps1` cycles wallpapers, `menu.ps1` is the menu). Scripts are released into `%LOCALAPPDATA%\壁纸助手`
  and can be hot-updated according to the hashes in `version.json`. No admin rights needed.
- **Run / verify**: `python launcher.py` · `python -m py_compile launcher.py build-exe.py` ·
  `python tools/preflight_release.py` (the release gate — must be all green before publishing).
- **Never**:
  - don't hand-edit `version.json` (it is the online update source; `scripts.*.sha256` must match the scripts in the repo);
  - keep `.ps1` files as **UTF-8 with BOM** (dropping the BOM breaks PowerShell 5.1 parsing of Chinese text);
  - don't rewrite line endings wholesale (this repo stores **LF**);
  - never introduce local machine paths, private emails or tokens into the repo;
  - banned wording anywhere: 绕过 / 翻墙 / 梯子 / 科学上网 / 墙 / 破解 / 屏蔽;
  - don't push to or write gitee.com addresses — Gitee is deprecated since v2.3.2 and confirmed retired on 2026-11-06; the canonical repo is GitHub (`github` remote), mirror is GitCode (`origin`), nothing ever goes to Gitee;
  - **Chinese display names (hard rule, 2026-11-05)**: every image shown on the panel,
    from any source including user-imported files, must show a Chinese descriptive name.
    Never expose English titles, hashes or random tokens; all display paths go through
    `displayName()`. No repeat on rotation, and no re-downloading
    an image that was already downloaded or shown.
  - **One fluent Chinese sentence; country + place MUST be spelled out (hard rule,
    2026-11-06, both Commons sources)**: the user's words -- "with so many images,
    without country/geography labels you cannot tell where it is", "no need to copy
    Bing's style, just make it fluent and descriptive, use your imagination",
    "better than Bing's naming". Names are a SINGLE fluent Chinese sentence, not
    `·`-joined tags and not Bing's underscore multi-segment form:
    `丹麦奥胡斯码头落日下的天际线`, `冰岛戈达福斯夏日瀑布的水雾`.
    Country first, concrete place next, scene at the end. Why this beats Bing: on
    this machine only 16/150 Bing and 11/200 Spotlight names carry a place (11% / 6%),
    many are riddles like "渴了吗"; Bing's newer underscore form only shows its first
    segment on our panel, so the place is lost. Every name here carries country +
    place + scene and stays fully visible as one segment.
    Geography comes ONLY from Commons metadata (title / description / categories) via
    the offline `Get-BwGeoLabel` dictionary. "Imagination" applies to wording and
    sentence structure only -- never invent a place or a subject. English original
    filenames are never shown; their geography must be translated.
    `Get-BwFlowName` builds the fluent sentence; the offline dictionary's ceiling is
    "correct but plain", so hand-polish is allowed. Never fall back to visual captions
    when the original title carries geography. Geo-tagged candidates are sorted first,
    never hard-filtered (exact 16:9 yield is low; filtering slows refills).
  - **Exception: no geo in the original title -> look at the image (user, 2026-11-06)**:
    "If the file name has no country/geography element, the name can only be written
    by looking at the image." Only when Commons metadata contains no country, city or
    landmark AND no recognizable subject (e.g. `DSC_1234.jpg`, `Sunset.jpg`),
    `Set-BwSrcDescriptiveName -VisualFallback` uses `Get-BwVisualCaption` to read the
    real pixels and write one fluent sentence (e.g. `暮霞暖金中的城市夜景`), same
    style as normal naming, no `·` tags. Local System.Drawing, offline, zero cost.
    Never invent a place name or a subject.
    Both candidate lists carry a `geo` field; `Invoke-BwSrcFetch` passes
    `-VisualFallback` only when `geo` is empty; translated names already containing
    `·` are always skipped.
  - **Suipai uses Commons only (hard rule, 2026-11-06)**: `picsum` is just the internal key;
    the actual source is Wikimedia Commons urban / human / everyday photography, kept
    separate from Wanxiang's nature / wildlife / geography themes. Never reintroduce
    `picsum.photos` URLs or `Unsplash` credits. Picsum's static 993-image list has no
    content metadata and exhausts in ~20 days under the no-repeat rule. New files must be
    exact 16:9, >=1920px, freely licensed, Commons-credited, burst-deduplicated, and
    fetched with a persistent per-keyword page cursor.
  - **Date is the author's shooting day, not the download day (hard rule, 2026-11-06)**:
    user's words -- "we should respect the photographer's shooting time", "adding the
    date also makes them easier to identify and manage". Both Commons sources read
    `extmetadata.DateTimeOriginal`, normalized by `Get-BwShotDate` to `yyyy-MM-dd`,
    and use it for the filename prefix, the embedded metadata `date` + `shot_date`,
    and the panel subline "摄于 YYYY-MM-DD". All 30 local images had it, in four
    formats (ISO / ISO+time / `Taken on D Month YYYY` / `D Month YYYY`).
    Candidates without a shooting date are **skipped, never written to disk**;
    never pass the download day off as the shooting day. `added_date` separately
    records the local ingest day. Bing / Spotlight keep Microsoft's release date
    and the "YYYY-MM-DD 的图" wording -- do not mix the two conventions.
  - **One small credit line (user "respect the author", 2026-11-06)**: for Wanxiang /
    Suipai the current-wallpaper card shows "摄影: full author name · 摄于 date ·
    license · 来源". `Get-BwPanelState.credit` reads the embedded metadata; the
    frontend `heroCredit` renders it in `muted xs` small text, only for those two
    modes, unobtrusive, and **never alters the fluent Chinese name**.
    **No author initials/abbreviations**: CC BY / CC BY-SA require the full
    attribution identifier; abbreviations do not satisfy it, and non-commercial
    / pure viewing does NOT waive attribution (SA only triggers when distributing
    adaptations). Links are restricted to `commons.wikimedia.org`; author names
    go in via `textContent`. The full author is also stored as `author` in the
    embedded metadata -- no sidecar files.
  - **All credits on the home page; gallery buttons hit the exact file (hard rule,
    2026-11-06)**: "all image credits are reflected together on the home page",
    "the three buttons must open exactly what they point at, not the thumbnail".
    The home screen has a collapsed `图片出处` card listing every image in the
    current mode's library; `?panel=credits` requires the token and reads only the
    first 64KB of each JPEG (COM segment) -- never `ReadAllBytes` on a 4K file.
    Never add a fifth button to gallery tiles. Never invent a Commons detail link
    for Bing / Spotlight; keep Spotlight's `© ... / Getty Images` verbatim.
    Gallery rows carry `src` and, only for token-bearing requests, `path`;
    `use` / `fav` / `del` resolve inside that ONE directory, never a cross-library
    first match. "原图" uses `/api/wall?p=<real path>` or tokenized
    `?panel=orig&name=`, and must never fall back to `?panel=thumb`; thumbnails
    are for `<img>` display only.
  - don't change the author strings (`海风（kele551）` / `HaiFeng (kele551)`).
- **Commits**: one change per commit, Chinese conventional prefixes (`fix:` / `feat:` / `docs:` / `chore:`),
  and state which commands you ran and what they printed. Version numbers change only at release time.
- **Backlog**: [TASKS.md](TASKS.md) and issues labelled `good first issue`.
