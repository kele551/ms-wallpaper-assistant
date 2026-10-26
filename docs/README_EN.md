<div align="center">
<img src="../docs/icon.png" alt="桌面壁纸" height="120" width="120">

<h1>Desktop Wallpaper Assistant</h1>

<p><a href="../README.md">简体中文</a> | English</p>

<a href="https://github.com/kele551/ms-wallpaper-assistant/releases" title="Download"><img alt="Downloads" src="https://img.shields.io/github/downloads/kele551/ms-wallpaper-assistant/total?style=flat-square&label=GitHub%20downloads&color=brightgreen" height="30"></a>

<a href="https://github.com/kele551/ms-wallpaper-assistant/blob/main/LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-blue?style=flat-square"></a>
<img alt="Platform" src="https://img.shields.io/badge/platform-Windows-blue?style=flat-square">
<a href="https://github.com/kele551/ms-wallpaper-assistant/releases"><img alt="Release" src="https://img.shields.io/github/v/release/kele551/ms-wallpaper-assistant?style=flat-square&label=release&color=blue"></a>
<img alt="Last Commit" src="https://img.shields.io/github/last-commit/kele551/ms-wallpaper-assistant?style=flat-square&label=last%20commit&color=blue">

<a href="https://github.com/kele551/ms-wallpaper-assistant/stargazers"><img alt="GitHub Star" src="https://img.shields.io/github/stars/kele551/ms-wallpaper-assistant?style=flat-square&logo=github&label=GitHub%20Star&color=gold"></a>
<a href="https://github.com/kele551/ms-wallpaper-assistant/network/members"><img alt="GitHub Fork" src="https://img.shields.io/github/forks/kele551/ms-wallpaper-assistant?style=flat-square&label=GitHub%20Fork&color=blue"></a>
<a href="https://github.com/kele551"><img alt="Follow Author" src="https://img.shields.io/github/followers/kele551?style=flat-square&logo=github&label=follow%20author&color=blue"></a>

<img alt="Category" src="https://img.shields.io/badge/category-application-blue?style=flat-square">
<img alt="No Admin" src="https://img.shields.io/badge/admin%20rights-not%20needed-brightgreen?style=flat-square">
<img alt="Local Only" src="https://img.shields.io/badge/images-stay%20local-brightgreen?style=flat-square">
<img alt="4K" src="https://img.shields.io/badge/quality-4K-blue?style=flat-square">

<a href="https://github.com/kele551/ms-wallpaper-assistant/releases"><img alt="Download from GitHub" src="https://img.shields.io/badge/%F0%9F%93%A5_Download-GitHub_primary-2f9e44?style=flat-square&logo=github&logoColor=white&labelColor=3d4552"></a>
<a href="https://gitcode.com/kele551/ms-wallpaper-assistant"><img alt="GitCode mirror" src="https://img.shields.io/badge/%F0%9F%90%9E_Source-GitCode_mirror-c71d24?style=flat-square&logo=gitee&logoColor=white&labelColor=3d4552"></a>
<a href="https://www.bilibili.com/video/BV1Tupx6kEBe"><img alt="Bilibili demo" src="https://img.shields.io/badge/%F0%9F%93%BA_Demo-Bilibili_video-00a1d6?style=flat-square&logo=bilibili&logoColor=white&labelColor=3d4552"></a>
<a href="https://github.com/kele551/ms-wallpaper-assistant/issues"><img alt="Issues" src="https://img.shields.io/badge/%F0%9F%90%9E_Feedback-Issues_welcome-0969da?style=flat-square&labelColor=3d4552"></a>
<a href="#support-the-project"><img alt="Sponsor" src="https://img.shields.io/badge/%E2%98%95_Buy%20me-Buy_me_a_coffee-ff69b4?style=flat-square&labelColor=3d4552"></a>

</div>

<details>
<summary>📊 <b>Repository stats</b> (click to expand)</summary>

<p align="center">
<img alt="Release Date" src="https://img.shields.io/github/release-date/kele551/ms-wallpaper-assistant?style=flat-square&label=release%20date">
<img alt="Commit Activity" src="https://img.shields.io/github/commit-activity/y/kele551/ms-wallpaper-assistant?style=flat-square&label=commits%2Fyear">
<img alt="Contributors" src="https://img.shields.io/github/contributors/kele551/ms-wallpaper-assistant?style=flat-square&label=contributors">
<a href="https://github.com/kele551/ms-wallpaper-assistant/issues"><img alt="Issues" src="https://img.shields.io/github/issues/kele551/ms-wallpaper-assistant?style=flat-square&label=issues"></a>
<img alt="Resolved" src="https://img.shields.io/github/issues-closed/kele551/ms-wallpaper-assistant?style=flat-square&label=resolved">
<img alt="Language" src="https://img.shields.io/github/languages/top/kele551/ms-wallpaper-assistant?style=flat-square">
<img alt="Code Size" src="https://img.shields.io/github/languages/code-size/kele551/ms-wallpaper-assistant?style=flat-square&label=code%20size">
<a href="https://github.com/kele551/ms-wallpaper-assistant/blob/main/docs/CONTRIBUTING.md"><img alt="PRs Welcome" src="https://img.shields.io/badge/PRs-welcome-brightgreen?style=flat-square"></a>
</p>

</details>

**Auto-rotating desktop wallpapers from Bing and Windows Spotlight.**

A small, free, open-source Windows utility — a single portable `.exe` — that downloads
public wallpaper sources (the **Bing daily image** and **Windows Spotlight**) and rotates
them as your desktop wallpaper on a schedule. No installer, no administrator rights; all
images stay on your own machine.

> Not affiliated with, endorsed by, or sponsored by any image provider. "Bing" and "Windows
> Spotlight" are used only to describe where the images come from.

> 作者 / Author: **HaiFeng (kele551)** · GitHub（主源 / primary）: <https://github.com/kele551/ms-wallpaper-assistant> · GitCode（镜像 / mirror）: <https://gitcode.com/kele551/ms-wallpaper-assistant> · AtomGit（镜像 / mirror, code）: <https://atomgit.com/kele551/ms-wallpaper-assistant>

---

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

---

## Download

- GitHub Releases (primary, always the newest): <https://github.com/kele551/ms-wallpaper-assistant/releases>
- GitCode Releases (mirror, China; may lag GitHub): <https://gitcode.com/kele551/ms-wallpaper-assistant/releases>

Unzip the archive and double-click `桌面壁纸.exe` (Windows 10/11 x64). Installs made before the 2026-10-12 rename (`微软壁纸助手.exe`) or before the 2026-10-25 file-name fix (`壁纸助手.exe`) keep their old file name — same program, and in-place upgrades preserve whatever name you already have. The UI is a
control panel in your browser (Chinese); click **立即换一张** to switch now, and the
**开机自动换** switch in 「更换节奏」 to turn automatic rotation on or off.
Version: right-click the exe → Properties → Details.

---

## Build from source

The executable is built entirely from the source code in this repository, with PyInstaller:

```powershell
pip install "pyinstaller==6.22.3"
python build-exe.py --release      # produces 桌面壁纸.exe
```

Entry point: `launcher.py`; bundled payload: `core.ps1`, `menu.ps1`, `使用说明.txt`, icon.
The build script refuses to package a payload whose `.ps1` files are not UTF-8 with BOM.

---

## Antivirus false positives

The executable is currently **unsigned**, and it is packaged as a single-file PyInstaller
bundle which extracts PowerShell scripts at runtime for its auto-update feature.
Antivirus heuristic engines can therefore report a **false positive** (Kaspersky has done so).
You can verify the file yourself against the SHA256 published on the release page:

```powershell
certutil -hashfile 桌面壁纸.exe SHA256
```

The full source code is public and reviewable, and the program contains no malicious
functionality: it downloads images from Microsoft's public image services and sets them
as the desktop wallpaper.

---

## Privacy

This program collects and uploads **no** user data. It only requests wallpaper images from
Microsoft's public image services (Bing, Windows Spotlight) and stores them on the user's
own computer. Apart from those image requests it transfers no information to other
networked systems unless the user explicitly asks it to.

---

## Code signing policy

**Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org).**

This project is applying for that free code-signing service; **the released exe is not signed yet**,
so please verify it against the SHA256 published on the release page. The full policy — privacy,
uninstall checklist, and how a release artifact can be verified — is in
[CODE_SIGNING_POLICY.md](CODE_SIGNING_POLICY.md)（代码签名政策）.

---

## Contributing and governance

- **Maintainer**: [@kele551](https://github.com/kele551) (海风) — a one-person project; the same person
  submits, reviews and approves releases. Issues and pull requests get a first reply within **7 days**;
  security reports go through [SECURITY.md](SECURITY.md) privately and are answered within **3 days**.
- **How to take part**: issue templates, PR flow, code style, building locally and self-checks are in
  [CONTRIBUTING.md](CONTRIBUTING.md).
- **Compliance**: feature boundaries, image sources and copyright, privacy, and third-party licences
  are in [COMPLIANCE.md](COMPLIANCE.md).
- **Release discipline**: before anything is published, `tools/preflight_release.py` must be all green
  (version consistency, artifact matches the update feed, `.ps1` BOM and syntax, no private e-mail in
  public docs) — one red item blocks the release.

---

## Support the project

If this tool helps you, a **Star ⭐ on the repo** is the best way to say thanks — it helps other people
find the project. Anything further is entirely optional and changes nothing about the features,
updates or issue replies.

---

<p align="center"><sub>© 2026 海风（kele551） · MIT License · <a href="https://github.com/kele551/ms-wallpaper-assistant">GitHub (primary)</a> · <a href="https://gitcode.com/kele551/ms-wallpaper-assistant">GitCode (mirror)</a></sub></p>

