# Desktop Wallpaper Assistant（桌面壁纸）

**Auto-rotating desktop wallpapers from Bing and Windows Spotlight.**

A small, free, open-source Windows utility — a single portable `.exe` — that downloads
public wallpaper sources (the **Bing daily image** and **Windows Spotlight**) and rotates
them as your desktop wallpaper on a schedule. No installer, no administrator rights; all
images stay on your own machine.

> Not affiliated with, endorsed by, or sponsored by any image provider. "Bing" and "Windows
> Spotlight" are used only to describe where the images come from.

> 作者 / Author: **HaiFeng (kele551)** · Gitee（主）: <https://gitee.com/kele551/ms-wallpaper-assistant> · GitHub（镜像）: <https://github.com/kele551/ms-wallpaper-assistant>

## Features

- **Two sources**: the Bing daily image + Windows Spotlight (both 4K)
- **Automatic rotation** at an interval you choose (default: 30 minutes)
- **Never repeats**: it remembers which images you have already seen, and keeps a favourites list
- **Catches up**: if your PC was off for days, missed Bing images are backfilled automatically
- **Green / portable**: one `.exe`; no installer, **no administrator rights, no autostart
  registry entry, no service, no scheduled task**. The only registry value it may write is
  Windows' own wallpaper settings under `HKCU\Control Panel\Desktop`
  (`WallpaperStyle` / `TileWallpaper`), and only when you change the wallpaper fit mode
- **Quiet**: no window flash, no popups; it also skips swapping while your screen is locked
  or you are away from the computer
- **Sleep-friendly**: it requests no wake state, changes no power settings, plays no audio,
  and (since v2.0.10) stays completely quiet while you are away or locked
- **Private by design**: images are stored locally; no user data is collected or uploaded
- **Self-updating**: it checks the release feed and upgrades itself — no manual downloads

## Download

- GitHub Releases: <https://github.com/kele551/ms-wallpaper-assistant/releases>
- Gitee Releases (main, China): <https://gitee.com/kele551/ms-wallpaper-assistant/releases>

Unzip the archive and double-click `微软壁纸助手.exe` (Windows 10/11 x64). The UI is a
console menu in Chinese; press `Q` to quit, `B` to toggle automatic rotation.
Version: right-click the exe → Properties → Details.

## Build from source

The executable is built entirely from the source code in this repository, with PyInstaller:

```powershell
pip install "pyinstaller==6.22.3"
python build-exe.py --release      # produces 微软壁纸助手.exe
```

Entry point: `launcher.py`; bundled payload: `core.ps1`, `menu.ps1`, `使用说明.txt`, icon.
The build script refuses to package a payload whose `.ps1` files are not UTF-8 with BOM.

## Antivirus false positives

The executable is currently **unsigned**, and it is packaged as a single-file PyInstaller
bundle which extracts PowerShell scripts at runtime for its auto-update feature.
Antivirus heuristic engines can therefore report a **false positive** (Kaspersky has done so).
You can verify the file yourself against the SHA256 published on the release page:

```powershell
certutil -hashfile 微软壁纸助手.exe SHA256
```

The full source code is public and reviewable, and the program contains no malicious
functionality: it downloads images from Microsoft's public image services and sets them
as the desktop wallpaper.

## Privacy

This program collects and uploads **no** user data. It only requests wallpaper images from
Microsoft's public image services (Bing, Windows Spotlight) and stores them on the user's
own computer. Apart from those image requests it transfers no information to other
networked systems unless the user explicitly asks it to.

## Code signing policy

See the "Code signing policy（代码签名政策）" section below.

## License

MIT — see [LICENSE](LICENSE).

---

> 以下是中文原始说明（内容与上面一致，更详细）。
# 桌面壁纸

> 作者：**海风（kele551）** · 仓库：https://gitee.com/kele551/ms-wallpaper-assistant （GitHub 同名镜像）

![License](https://img.shields.io/badge/license-MIT-blue) ![Platform](https://img.shields.io/badge/platform-Windows-blue) ![Version](https://img.shields.io/badge/version-v2.1.0-blue) ![Downloads](https://img.shields.io/github/downloads/kele551/ms-wallpaper-assistant/total?label=downloads&color=green)

**让电脑桌面壁纸自己换，你不用管。**

Windows 桌面壁纸自动轮换工具。图来自两个公开图源（只下到你自己电脑上，不随程序分发）：

| 图源 | 说明 |
|---|---|
| **必应每日一图** | 微软必应每天换的那张，4K 原图 |
| **Windows 聚焦** | 微软官方聚焦图库，一次能刷一批，也是 4K |

> 本项目与任何图源厂商无隶属关系；「必应」「Windows 聚焦」等名称只用于描述图片来源。
> 图片版权归原提供方，仅供个人桌面使用，请遵守各图源的使用条款。

它有几个地方跟别的壁纸软件不一样：

- **不用安装** —— 下载一个 exe，双击就用
- **不要管理员权限**，不写自启动注册表项、不装服务与计划任务
- **改写系统的只有一件事**：设壁纸走 Windows 标准做法
  （`SystemParametersInfo(SPI_SETDESKWALLPAPER)`），其中「壁纸填充方式」写在 Windows 自己的
  `HKCU\Control Panel\Desktop`（`WallpaperStyle` / `TileWallpaper`，与系统「个性化」是同一个位置），
  **写前先比对，值相同就不写；不改系统代理、不改 DNS、不改 hosts**
- **后台换图时一个窗口都不闪**，你根本感觉不到它在跑
- **几天没开机也不漏图** —— 错过的必应壁纸会自动补齐
- **图片都存在你自己电脑上**，不上传任何东西

---

## 目录

- [下载](#下载)
- [三步用起来](#三步用起来)
- [菜单上都有什么](#菜单上都有什么)
- [壁纸存哪？能自己删吗？](#壁纸存哪能自己删吗)
- [常见问题](#常见问题)
- [版本迭代](#版本迭代)
- [代码签名政策](CODE_SIGNING_POLICY.md)
- [贡献指南](CONTRIBUTING.md)　·　[安全政策](SECURITY.md)
- [路线图（Roadmap）](#路线图roadmap)　·　[参与贡献与治理](#参与贡献与治理)
- [许可](#许可)

---

## 下载

### 👉 [点这里下载 v2.0.10 安装包](https://gitee.com/kele551/ms-wallpaper-assistant/releases/download/v2.0.10/MSWallpaperAssistant-v2.0.10.zip)

> 7.3 MB 的 zip，实测可解压、可运行。当前云端最新版本：v2.0.10（打开即自动升级）。
> **杀软报毒是误报，可以放心。** 程序没有购买数字签名，又是「单文件自解压」打包，
> 加上自动升级会下载脚本再运行 —— 这三样最容易触发杀软的启发式误判。
> 想自己确认文件没被动过：发行页上写了安装包的 SHA256，下载后执行
> certutil -hashfile 微软壁纸助手.exe SHA256 比对即可；一致就说明是原版。
> 处理办法：把这个 exe 加进杀软的信任/排除名单。源码全部公开，可自行查阅。

下载下来是一个 zip，解压后里面就两样东西：

```
微软壁纸助手.exe     ← 双击这个
使用说明.txt         ← 一页纸说明
```

就这一个 exe，不用挑、不用装、不用下一步下一步。

---

## 三步用起来

**第 1 步** —— 解压，双击 `微软壁纸助手.exe`，菜单就出来了。

**第 2 步** —— 第一次打开，它会自动下载今天的必应图 + 一批聚焦图，屏幕上会告诉你壁纸存在哪。等几十秒就好。

**第 3 步** —— 想让它以后开机自己换，菜单里按一下 **[A]**。

```
想立刻看效果？菜单里按 [1]，马上换一张。
```

> 按 `[A]` 不用管理员。它只是在 Windows「启动」文件夹里放一个快捷方式而已。

---

## 菜单上都有什么

```
  ============================================================
   桌面壁纸 v2.0.10    作者: 海风（kele551）
   gitee.com/kele551/ms-wallpaper-assistant
  ============================================================

  换图  下次自动换 21:30  ·  每 30 分钟  ·  后台在跑  ·  今日必应 已切
  图库  必应 128 张 · 聚焦 96 张 · 待换 12 张 · 累计下载 356 张
  位置  D:\图片\壁纸
  壁纸  2026-09-22-Bing-xxxxxxx-UHD.jpg

  ------------------------ 换图 ------------------------
   [1] 换一张壁纸          [2] 下载聚焦图片
   [3] 浏览壁纸库          [4] 下载必应图片
   [F] 收藏 / 取消当前这张
  --------------------- 后台与设置 ---------------------
   开机自动换: 开 · 后台正在跑
   [B] 关掉开机自动换
   [S] 设置        [U] 检查更新
  ------------------------ 其它 ------------------------
   [L] 查看日志   [R] 刷新   [Q] 退出
```

### 上面那几行状态

状态区就是三行：`换图` / `图库` / `位置`+`壁纸`。**只有开着「只在收藏里轮换」时才会多一行** `收藏`。

真出问题时，下面会多出一片黄字**提醒**——**平时一个字都不显示**。会冒出来的有：
坏图被隔离、聚焦库空、图库里混进了外来图、保存位置不安全、图库超上限、有新版本可升、
库里一张图都没有、程序位置变过。每条都写清了按哪个键处理。

> 状态是进菜单那一刻的快照，窗口一直开着不会自己更新 —— 想重算，按一下 `[R]`。

### 按键

| 键 | 做什么 | 子菜单 |
|---|---|---|
| `[1]` | 换一张壁纸 | — |
| `[2]` | 下载聚焦图片 | — |
| `[3]` | 浏览壁纸库 | 序号 = 设为壁纸 · `f`+序号 = 收藏/取消（如 `f3`）· `o` = 打开文件夹 · `q` = 返回 |
| `[4]` | 下载必应图片 | `[1]` 补齐（2021-02 至今，按年-月整月下）· `[2]` 补漏（只下载，不切壁纸）· `q` = 返回 |
| `[F]` | 收藏 / 取消当前这张 | — |
| `[A]` `[B]` | 开 / 关开机自动换 | 见下表，只显示当前能按的那一个 |
| `[S]` | 设置 | 见下 |
| `[U]` | 检查更新 | 有新版才会自动提醒；`[U]` 里能看进度 |
| `[L]` | 看日志末尾 40 行 | — |
| `[R]` | 重画菜单（重算状态） | — |
| `[Q]` | 退出（老的 `0` 也认） | — |

`[A]`/`[B]` 跟着状态走，**菜单上只出现当前能按的那一个**，不会按反：

| 现在什么状态 | 菜单上显示 |
|---|---|
| 开机自动换：关 | `[A] 打开开机自动换` |
| 开机自动换：开，后台正在跑 | `[B] 关掉开机自动换` |
| 开机自动换：开，但后台没在跑 | `[A] 现在就把后台跑起来` 和 `[B] 关掉开机自动换` 都给出来 |

> 「开」只管**下次开机起不起**；「后台在跑」是**这一会儿有没有进程** —— 两件事，菜单分开写。

### `[S]` 设置里能改什么

```
  [1] 换图间隔        每 30 分钟换一张          单位分钟，5 ~ 1440（1440 = 一天一张）
  [2] 每轮抓几张      一次抓 6 张聚焦备用        1 ~ 50（实际还受"单轮/每天"上限约束，见下）
  [3] 壁纸保存位置    D:\图片\壁纸              换位置时会问要不要把已有的图一起搬过去
  [4] 壁纸填充方式    填充                     填充 / 适应 / 拉伸 / 居中 / 平铺 / 跨区
  [5] 收藏夹          8 张 · 只在收藏里轮换 关   数字 = 设为壁纸 · x+数字 = 移出（如 x3）· s = 开关
  [6] 桌面快捷方式    开                       关掉会把桌面那个图标一起删掉
  [7] 数据目录        %LOCALAPPDATA%\微软壁纸助手   按 o 直接打开这个文件夹
  [8] 图库上限        200 张 · 现在库里 96 张    0 = 不限，或 5 ~ 2000；超了把看过的最老的移进回收站
  [9] 重新抓取源池    清空下载记录（不动图片）   用于清空库/还原回收站后想重新收一遍图
  [0] 自动补新图      关                        关着就只在现有这些图里轮换
  [t] 单张下载超时    20 秒                     慢图床到点就放弃、换下一张（给图源用）
  [q] 返回
```

> `[8]` 的新装默认值已从 100 张调整到 **200 张**（**已有的 `config.json` 不受影响**，想改就在 `[8]` 里填）。
> 库越大，同一张图轮回来得越慢：200 张 + 30 分钟一轮 ≈ 4 天才轮一遍。

### 聚焦源池有多大？会不会"没图可换"？

说清楚一件事，免得看着"怎么老是这几张"以为坏了：**微软聚焦的图源总量是有限的**
（当前大约 800+ 张），而**官方每天只新增几张**。程序这边为了不重复，下载过一次的图默认不再下第二遍。

所以程序做了三件事，让这个池子能撑很久、而且永远不会枯竭：

| 机制 | 默认值 | 说明 |
|---|---|---|
| 单轮 / 单日抓取上限 | 单轮 6 张 · 每天 20 张 | 按需要慢慢补，不把池子一次抽干（`fetch_round_cap` / `fetch_day_cap`） |
| 库满了就不补 | 库 ≥ 图库上限时跳过 | 下回来立刻被上限清掉纯属浪费（只在库低于阈值时补货） |
| 耗尽退避 | 连续 3 轮"新增 0"后 | 改为每 24 小时只在官方更新时间点附近试一轮；哪天有新图会自动恢复正常频率 |
| 老图回收 | 间隔 ≥ 30 天 | 没看过的图不足 20 张时，把够久没出现的老图重新排进轮换（本地还在就直接用，零下载） |

主菜单和 `[S]` 设置里都有一行「源池状态」，直接告诉你现在是**还有新图**、**进入老图循环**还是
**源池已抓到尽头（等官方更新，下次尝试 时间）**。想重新从源池收一遍图（比如你把库清空了），
在设置里用 `[9] 重新抓取源池` —— 它只清下载记录（流水会留档一份），**不动任何图片文件**。

### 图片源：授权怎么说、会不会"没图可换"？

程序内部是**可插拔图源**结构：每个源各自一个目录、各自的去重记录、各自的容量上限（0 = 不限），
抓取纪律和聚焦**完全同一套**。目前接入的是上面那两个源：

| 机制 | 默认值 | 说明 |
|---|---|---|
| 单轮 / 单日抓取上限 | 每源单轮 6 张 · 每天 20 张 | 每个源各记一份账（换天归零），不把源池一次抽干 |
| 库满不补 | 库 ≥ 该源上限时跳过 | 补回来也只会挤掉别的图 |
| 耗尽退避 | 连续 3 轮"新增 0"后 | 改成每天只试一轮；日志每天只留一行聚合，不再每轮刷屏 |
| 老图回收 | 间隔 ≥ 30 天 | 够久没出现的老图重新排回轮换（本地还在就直接用，零下载）；文件已经不在了才重新下 |

**说清楚一件事**：任何源池都会"抓到头"（聚焦约 800+ 张、官方每天只新增几张）。所以才有上面这四道
机制 —— 抓到头不会报错、也不会空转，而是**退避 + 用老图循环**，永远有图可换；哪天源上有了新图，
下一轮就会自己恢复正常频率。

**授权（重要）**：

- 图只**下载到你自己电脑上**，不随发行版打包分发，也不上传到任何地方；
- 接入**公版库**类图源时，程序**逐张校验公版标记**，非公域的一律不看；
- 图片版权归**原提供方**，仅供个人桌面使用，请遵守各图源的使用条款；
- 本项目与各图源厂商**均无隶属关系**，名称只用于描述图片来源。

`[4]` 填充方式改完**立刻应用到当前这张壁纸**，当场就能看到效果。

> 退出请按 `[Q]`。老版本里 `o` 也能退出，现在 `o` 只用来「打开文件夹」，不会关掉程序了。

看到喜欢的图，主菜单按 `[F]` 就收下了，再按一次取消。收藏够了到 `[S]` → `[5]` 里打开
「只在收藏里轮换」，以后换出来的都是你自己挑过的图。

---

## 壁纸存哪？能自己删吗？

默认存在**「图片」文件夹里的「壁纸」**，下面两个子目录：

```
<图片文件夹>\壁纸\必应     必应每日一图
<图片文件夹>\壁纸\聚焦     Windows 聚焦
```

如果你的「图片」在 C 盘，它会挪到别的盘去 —— 壁纸天天攒，几年下来好几个 GB，
放系统盘容易把 C 盘撑满。

**库里的图你随便删、随便挪、随便拷走，程序完全不受影响：**

| 你做的事 | 它的反应 |
|---|---|
| 删掉几张 | 不再排进轮换，也不会被重新下载回来 |
| 整个库挪走 | 菜单会提醒你，到设置里把位置指过去就行 |
| 正在用的那张被移走了 | 如实写出来，换一张就更新了 |

---

## 常见问题

| 问 | 答 |
|---|---|
| **双击没反应？** | 多半是安全软件拦了，把它加入信任就行。程序只从 bing.com 和微软官方接口下图，没有任何上传行为。 |
| **中文显示成乱码？** | 系统「非 Unicode 程序语言」要设成「中文(简体, 中国)」。 |
| **会不会拖慢电脑？** | 只有「开机自动换」开着时后台才有一个进程，平时占 30 MB 左右，绝大多数时间在睡觉。关掉就完全不占。 |
| **提示某个盘「写不进去」？** | 那是这台机器那个盘的权限设置（常见于用第三方分区工具格的盘），不是程序不支持它。按提示选 `[1]` 一键修好，或者换个盘 —— 壁纸放哪个盘都能用。 |
| **不想用了怎么卸？** | 菜单按 `[B]` 关掉自动换 → 删掉 exe → 想连配置也清掉就再删数据目录（`[S]` 设置 `[7]` 里能看到位置）。**下载的壁纸一张都不会被删。** |

---

## 用了之后，跟我说说感受

好不好用、哪儿别扭、还想要什么功能 —— 都欢迎说，一句两句也行：

- **提 Issue**（推荐）：[GitHub Issues](https://github.com/kele551/ms-wallpaper-assistant/issues)　·　[Gitee Issues](https://gitee.com/kele551/ms-wallpaper-assistant/issues)
- 也可以直接在 [Gitee 仓库](https://gitee.com/kele551/ms-wallpaper-assistant) 留言

顺手带上这几样，能省一轮来回：

1. Windows 版本（设置 → 系统 → 关于）
2. 程序版本号（菜单标题上就有，比如 `v2.0.10`）
3. `wallpaper.log` 末尾十几行（菜单 `[L]` 能看到）

---

## 构建方式（Build from source）

本项目**完全从本仓库源码构建**，产物只有一个 exe，任何人可复现：

```powershell
pip install "pyinstaller==6.22.3"
# 在仓库根目录执行：脚本会先检查所有 .ps1 都是 UTF-8 带 BOM，再开始打包
python build-exe.py --release
# 产出：微软壁纸助手.exe（单文件，内含 core.ps1 / menu.ps1 / 使用说明.txt / 图标）
```

- 入口程序：launcher.py　负载：core.ps1、menu.ps1、使用说明.txt、微软壁纸助手.ico
- 打包脚本：build-exe.py（写入 exe 版本信息与图标）
- 发布脚本：tools/publish.py（生成升级源 version.json、Gitee + GitHub 双平台发布与下载验真）
- 发布历史：CHANGELOG.md

Releases are built from the source code in this repository; the build command is the one above.

## Code signing policy（代码签名政策）

**Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org).**

（本项目正在申请上述免费代码签名服务；通过之后，发布的可执行文件在构建流程中自动签名，
签名即表示该文件由本仓库的源码自动构建而来。）

**团队角色（Team roles）**

| 角色 | 成员 |
|---|---|
| 提交者与审查者 Committers and reviewers | [@kele551](https://github.com/kele551) |
| 签名批准者 Approvers | [@kele551](https://github.com/kele551) |

本项目目前由作者一人维护，上述角色由同一人承担；所有成员均已启用两步验证（MFA）。

**隐私声明（Privacy policy）**

本程序只在需要时**从微软官方图源**（必应每日一图、Windows 聚焦）下载壁纸图片，
所有图片都保存在用户自己的电脑上；**不收集、不上传任何用户数据**。
除这些图片请求之外，本程序**不会向其它联网系统传输信息，
除非用户（或安装、操作它的人）明确提出要求**。

**卸载（Uninstallation）**

见《使用说明》的「卸载」一节：菜单 [S] → [6] 关闭自动换并删除桌面快捷方式，
再删除 exe 与数据目录即可 —— 不写自启动注册表项、不装服务与计划任务、不改系统代理/DNS/hosts。
（「壁纸填充方式」写在 `HKCU\Control Panel\Desktop` 的那两个值属于 Windows 自己的壁纸设置，
程序退出时不会去动它；想恢复默认，在系统「个性化 → 背景」里改一次即可。）

## 版本迭代

每次改版都会打一个版本号、发一版下载。**当前最新：v2.0.10**

小版本的改动都归到同一个大版本下面说，一行一个版本：

| 版本 | 日期 | 改了什么 |
|---|---|---|
| **v2.0** | 09-21~09-30 | 代码质量改进（升级源调整、自动备份、日志分级）；添加本地下载统计页面。 |
| **v1.6** | 09-17~09-21 | 程序不再替你做决定：外来图只做记号不动文件、库目录被删自己建回来；提示不再指错路；换图不用干等下载 |
| **v1.5** | 09-19 | 双击就能用：只出一份 exe、数据搬出程序目录、开机自动换不会再按反、看过的壁纸不再排回来、图库不再越攒越大 |
| v1.4 | 09-19 | 壁纸填充方式可以自己选；新增收藏夹；自动建桌面图标（只建一次，之后跟着你放的位置走） |
| v1.3 | 09-18 | 壁纸默认存到「图片\壁纸」；图片被删掉或移走后照常工作 |
| v1.2 | 09-18 | 改成绿色单文件版：双击即用、不安装、不要管理员、后台零窗口 |
| v1.1 | 09-18 | 单层菜单、启动不闪黑窗、错过的必应图自动补 |
| v1.0 | 09-17 | 第一个版本 |

v1.6 里面各小版本都改了什么：

- **v1.6.6** 一轮全量代码复核后的十处修补，重点是**程序不再替你做决定**：① 外来图（不是本程序下载的）从 v1.6.4 的「悄悄移进待确认文件夹」改成**只做记号**——图原地不动、不改名、不删，自动轮换跳过它，菜单首页报个数、`[4]` 列表标「外」；② 手动切必应不再被后台顶掉；③ 后台换图写回不再吞掉你在菜单里的收藏；④ 补漏一轮最多 30 天，半年没开机也不会一次列 180 张补不完；⑤ `-DryRun` 真的什么都不下；⑥ 顺手修掉 `[3]` 抓来的新图被当已删除剔掉、随机换一张不记账等小毛病；⑦ **认得 jpg 以外的图片了**——以前扫描全线写死 `*.jpg`，往库里丢一张 webp/png 程序完全看不见，现在统一按图片格式口径识别；⑧ **库目录被删自己建回来**，聚焦库空了自动后台补一批，必应库只建目录、历史图由你自己用 `[7]`/`[8]` 恢复；⑨ 菜单字体大一号；⑩ 清掉死代码
- **v1.6.5** 换图不再让你干等：队列快空就先在**后台**补满（前台零等待），真空了也只先下 1 张就回来换；并且把「聚焦库被清空」当成异常状态，不论「自动补新图」开关是否打开都自动补一批，不用手动按 `[3]`
- **v1.6.4** 「[9] 校验图库」这个手动按钮去掉，改由程序在后台每次巡检时静默完成（这条做法在 v1.6.6 已被改成"只做记号、不动文件"）
- **v1.6.3** 修「累计下载」越用越小的 bug：改成记在独立的流水文件里，谁覆盖都动不了真账（实测一天连下 6 张、6 次 +1 全被吞的老毛病）；同一份流水顺带成了「程序下载清单」
- **v1.6.2** 壁纸存哪**自己找现成的**，不再凭空造空文件夹：C 盘以外只要已经有放图片的文件夹，就直接定位到它下面的「壁纸」；设置 `[3]` 改位置时终于带上建议项（以前列表里没有建议标记，只能自己猜着挑）。措辞也改了：「后台还没启动」改成「后台这会儿没在跑」——菜单开着不等于后台在跑；并且开机自动换开着、后台却没跑时，`[A]` 把后台拉起来和 `[B]` 整个关掉会同时给出来
- **v1.6.1** 菜单首页新增「累计下载：N 张」——从装上那天算起一共下载过多少张壁纸，**删掉的、被库上限清进回收站的都还在这个数里**，不会因为你整理图库就往回缩。老版本升级上来会自动按「库里现存的 + 看过名单 + 日志里的下载记录」去重补一个基数（更早下载过、痕迹已经找不到的补不回来，所以老用户看到的起点可能偏小）；从这版起每成功下载一张就真记一次
- **v1.6.0** 设置 `[8] 刷新图标缓存` 失灵时给的备用脚本是真能找到的那个（以前它压根没打进 exe）；主菜单按 `o` 不再退出程序（退出请按 `Q`）；首运行里"改保存位置"的提示由 `[1]` 改正为 `[3]`、"再按 `[A]` 关掉"改正为 `[B]`；使用说明补齐设置 `[8]`，并修正卸载步骤里 `[A]`/`[B]` 写反的问题

v1.5 里面各小版本都改了什么：

- **v1.5.5** 修掉几处悄悄出错、界面上却看不出来的问题：下载到的半成品／错误页不再留在图库里（更不会被设成壁纸）；补漏时某天没联网，那天留着下次重试，不再永久判死；当日必应图没拿到就真的 15 分钟后再试，不再假装成功；后台巡检不再无声覆盖你在菜单里的收藏和手动挑的图；手动挑图开始记账，按 `[F]` 收藏到的就是眼前这张
- **v1.5.4** 图库设上限（默认 100 张），超了把**已经看过**的最老的移进回收站；新增「自动补新图」开关（默认关，只在现有图里轮换）
- **v1.5.3** 看过的壁纸不再排回来（另记一份「看过」名单，按图片编号比对而不是文件名）；按 `[A]` 开自动换**当场**就生效，不用等下次开机
- **v1.5.2** 「开机自动换」拆成 `[A]` 打开 / `[B]` 关掉两个键，不会再按反
- **v1.5.1** 只出一份 exe，不用挑该点哪个；第一次打开不再追问壁纸存哪
- **v1.5.0** 配置和收藏搬到用户目录，exe 旁边不再多出任何文件夹 |

逐条改动记录见 [CHANGELOG.md](CHANGELOG.md)。

> **一句说明**：v1.2.0 以前是「安装版」（要双击 bat 装计划任务），那个做法已经作废。
> 现在的版本是绿色单文件，老的安装脚本不再提供 —— 直接下最新版就行。

---

## 许可

MIT

## 路线图（Roadmap）

按优先级从高到低，都是已经排进计划、能落到代码上的事：

1. **代码签名**：README 已公开[代码签名政策](#code-signing-policy代码签名政策)（申请 SignPath 免费签名）。
   通过之后产物在构建流程中自动签名，用于缓解"单文件自解压 + 自动升级"被安全软件误报的问题。
   现状说明：**目前发布的 exe 没有数字签名**，所以杀软可能报毒 —— 请以发行页上的 SHA256 自行核对。
2. **更多图源评估**：现在只有必应每日一图与 Windows 聚焦两个微软官方图源。
   程序内部已经是可插拔图源结构（加一个源只需加一条定义 + 它的搜索/取图两个函数），
   评估新图源的标准是"本地优先、失败可回退、不收集数据"，外加一条**出图必须适合当壁纸**
   （接近 16:9：方形图铺满会裁掉主体，超宽长卷铺满会留两条空）——
   2026-10-09 就因为这个原因摘掉了两个试过的图源。宁可不加也不塞一个会拖慢启动、或出的图不能看的源。
3. **安装体验优化**：保持绿色单文件（不引入安装器），把"首次运行"再做省心一点 ——
   减少第一次双击时的等待与提示条数，让"下载 → 双击 → 有壁纸"这条路上没有需要读文档的步骤。

> 路线图只列真实在办的事，做完一项改一项；临时想到的、还没验证的想法不写在这里。

## 参与贡献与治理

| 项目 | 说明 |
| --- | --- |
| 维护者 | [@kele551](https://github.com/kele551)（海风），一人维护，同时担任提交者、审查者与发布批准者 |
| 响应预期 | Issue / PR 一般 **7 天内**给第一次答复；安全类问题按 [SECURITY.md](SECURITY.md) 私下走，**3 天内**响应 |
| 许可 | MIT（见 [LICENSE](LICENSE)）；提交贡献即表示同意按同一许可发布 |
| 怎么参与 | 提 Issue / PR 之前先看 [CONTRIBUTING.md](CONTRIBUTING.md)：Issue 模板、PR 流程、代码风格、本地构建与自查、提交信息规范都在里面 |
| 安全 | 漏洞请**不要**开公开 Issue，按 [SECURITY.md](SECURITY.md) 私下报告 |
| 持续集成 | [.github/workflows/build.yml](.github/workflows/build.yml) 在 Windows runner 上真实打包并输出 SHA256（每天构建只需 `pyinstaller`，运行主程序**零第三方依赖**） |
| 发布纪律 | 发版前必须跑发版前自检并全绿（版本一致性、成品与升级源同源、`.ps1` 的 BOM 与语法、对外文档不含私人邮箱），红一条不许发 |
