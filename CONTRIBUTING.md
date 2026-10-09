# 参与贡献（Contributing）

> 微软壁纸助手 —— 作者：**海风（kele551）** · <https://github.com/kele551/ms-wallpaper-assistant>

先说清楚这个项目的脾气，能省掉双方很多时间：

- **它很小、也很克制。** 一个绿色单文件 exe，只管"把微软官方壁纸自动换到桌面上"这一件事。
  想加的功能如果会让它需要安装、需要管理员、或者需要联网上报数据，基本不会被接受。
- **版本号只给新功能用。** 修 bug 的改动会攒到下一个功能版一起发（详见 README「版本迭代」）。
  所以你的 PR 合了之后，不一定会立刻出现在下载页上 —— 这是有意的，不是被忘了。
- **没测过的东西不许发。** 这是硬规矩：任何要发布的改动都要先过发版前自检。

---

## 一、怎么提 Issue

遇到问题请走 [Issues](https://github.com/kele551/ms-wallpaper-assistant/issues)，那里有两个模板：

| 模板 | 什么时候用 | 会问你什么 |
|---|---|---|
| 🐞 报告问题 | 程序行为不对、报错、跟文档写的不一样 | 程序版本号、Windows 版本、安装方式、复现步骤、`wallpaper.log` 末尾十几行 |
| 💡 提功能建议 | 想要某个功能 / 觉得现在别扭 | 你的使用场景、期望效果、试过的替代做法 |

**提之前先做三件事**（模板里也会提醒，这里再说一遍，因为大部分 Issue 卡在这一步）：

1. 翻一下 README 的「常见问题」和《使用说明》—— 双击没反应、中文乱码、杀软报毒、壁纸存哪，答案都在里面；
2. 看一眼 README 末尾的「路线图（Roadmap）」，已经排进计划的不用重复提；
3. 把日志准备好：菜单按 `[L]` 打开 `wallpaper.log`，复制**末尾十几行**（日志里没有隐私信息）。

**安全问题不要开公开 Issue**，请按 [SECURITY.md](SECURITY.md) 私下报告。

---

## 二、PR 流程

1. **先开 Issue 对齐，再动手写代码。** 尤其是新增功能或改动对外行为 —— 免得写完发现方向不对。
   改错别字、改文档这类不涉及行为的，可以直接提 PR。
2. Fork → 开分支（建议 `fix/xxx`、`feat/xxx`、`docs/xxx`）→ 改 → 自测 → 提 PR。
3. PR 描述请用仓库自带的 [模板](.github/PULL_REQUEST_TEMPLATE.md)：**改了什么 / 怎么验证的 / 自查清单**。
   "怎么验证的"那一栏必须写你实际跑过的命令和看到的结果。
4. 维护者会**在 7 天内**给第一次答复（一般是：通过 / 要补什么 / 为什么不收）。

---

## 三、代码风格

### 通用

- **中文注释、中文提交信息。** 这个项目的读者是中文用户，注释写清"为什么这么做"，不要只写"做了什么"。
- **不引入第三方运行时依赖。** `launcher.py` 只用标准库；打包只额外需要 `pyinstaller`。这是"绿色单文件"的前提。
- **改动要能对得上文档。** 改了行为就顺手改 README / 《使用说明》里对应的话 —— 文档与实现各说各话是这个项目最不能接受的毛病。
- **不要在对外文档里写私人邮箱、令牌、口令。** 反馈入口一律用 Issues 链接。
- **对外文案有禁用词清单**：下面这七个词一律不要出现在仓库任何文件里（README、简介、发布说明、
  注释、Issue/PR 模板都算）—— Gitee 等平台会按这些词判内容违规，整页打不开。清单：
  凡涉及网络访问限制、内容获取方式或内容过滤的敏感说法一律不得出现。
（具体清单见项目维护者本地章程；**不要在本仓库里逐词列举**，否则清单自身会被内容扫描命中。）
  换成中性技术表述：**「不依赖域名解析」「本地网络分流」「连接优化」「DNS 解析异常」**。
  改完对外文案后，自己按这份清单搜一遍再提交。本清单以本文件为**唯一出处**，其它文件只引用不重复列举。

### Python（`launcher.py`、`build-exe.py`、`tools/*.py`）

- 缩进 4 空格；保持现有的 `# -*- coding: utf-8 -*-` 头；函数名 `snake_case`。
- 需要打包进 exe 的东西必须在 `build-exe.py` 的 `PAYLOAD_FILES` 里列出来。

### PowerShell（`core.ps1`、`menu.ps1`）

- ⚠ **`.ps1` 必须是 UTF-8 带 BOM**。PowerShell 5.1 对无 BOM 的文件按 ANSI 读，中文会变乱码、字符串被破坏后直接 ParserError ——
  打包脚本会在打包前检查这一条，缺 BOM 直接拒绝打包。
- 函数沿用现有的 `动-词` 命名（`Get-BwState`、`Set-BwWall`、`Save-BwState`…）。
- 界面文案用中文、说大白话；不要出现助手名之类的内部代号。

### 行尾与编码（这条最容易踩）

- 仓库文本文件是 **LF**，`.ps1` 里的 `core.ps1` 目前是 **CRLF**（历史原因，见 CHANGELOG）。
  **不要整文件重写行尾** —— 那会产生"整个文件都变了"的假 diff，评审时看不出真正改了什么。
- 提交前用 `git diff --stat` 扫一眼：如果一个只改了几行的文件显示几百行变动，八成是行尾被改了。

---

## 四、如何在本地构建与自查

### 构建

```powershell
pip install "pyinstaller==6.22.3"
python build-exe.py --release
```

产物：`微软壁纸助手.exe`（固定名，日常用）、`微软壁纸助手-v<版本>.exe`、`MSWallpaperAssistant-v<版本>.zip`。

### 自查（改完自己先过一遍）

```powershell
python -m py_compile launcher.py build-exe.py tools\publish.py    # Python 语法
powershell -NoProfile -Command "[void][System.Management.Automation.Language.Parser]::ParseFile('core.ps1',[ref]$null,[ref]$e); $e.Count"   # PowerShell 语法，应为 0
```

发版前自检（维护者跑，改动涉及版本链时也建议本地跑一次）：版本一致性、成品与升级源同源、
`.ps1` 的 BOM 与语法、对外文档不含私人邮箱，全绿才允许发布。

### 测试程序时的两条安全线

- 程序会用 `SystemParametersInfo(SPI_SETDESKWALLPAPER)` 换你的**真实桌面壁纸**，并把填充方式写进
  `HKCU\Control Panel\Desktop`。测试前先记下你原来的壁纸与填充方式，测完改回去。
- **不要**在跑着 `--daemon` 的情况下直接覆盖 exe：先 `--stop`，等进程真的退出，再覆盖。

---

## 五、提交信息规范

用 [Conventional Commits](https://www.conventionalcommits.org/) 的前缀，正文写中文：

```
fix: 后台换图不再覆盖你在菜单里的收藏

原因：后台巡检拿的是 249 行前读的 state 快照，中间跑了几分钟的补漏，
     你在这期间按 [F] 收藏的图会被整份覆盖掉。
改法：这一条分支改用 Save-BwStateKeepFav，只合并必要字段。
验证：本机模拟"补漏中收藏"，收藏不再丢失；core.ps1 语法解析 0 错误。
```

常用前缀：`fix:`（修缺陷）、`feat:`（新功能）、`docs:`（只改文档）、`chore:`（构建/杂务）、`release:`（发版）。

---

## 六、许可

本项目是 MIT（见 [LICENSE](LICENSE)）。你提交的贡献即表示同意按同一许可发布。
