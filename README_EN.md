<div align="center">
<img src="docs/icon.png" alt="桌面壁纸" height="120" width="120">

<h1>Desktop Wallpaper Assistant</h1>

<p><a href="README.md">简体中文</a> | English</p>

<img alt="License" src="https://img.shields.io/badge/license-MIT-blue?style=flat-square">
<img alt="Platform" src="https://img.shields.io/badge/platform-Windows-blue?style=flat-square">
<img alt="Version" src="https://img.shields.io/badge/version-v2.2.0-blue?style=flat-square">
<img alt="Downloads" src="https://img.shields.io/github/downloads/kele551/ms-wallpaper-assistant/total?style=flat-square&label=downloads&color=green">

</div>

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
