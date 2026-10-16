# AGENTS.md —— 给 AI 编程助手的协作说明（桌面壁纸）

> 这份文件面向用 AI 助手（Claude Code / Codex / Cursor / DSH 等）改这个仓库的人。
> **动手前先读 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**（结构、改哪儿、怎么验）；人类贡献流程见 [CONTRIBUTING.md](docs/CONTRIBUTING.md)。

## 这是什么

Python 启动器（`launcher.py` → 打包成 `壁纸助手.exe`）+ 两份 PowerShell 脚本（`core.ps1` 换壁纸、`menu.ps1` 菜单），
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
- **产物文件名不带版本号**（固定 `壁纸助手.exe`，版本号只写进 exe 属性与界面）。
- **对外文案红线词**：绕过 / 翻墙 / 梯子 / 科学上网 / 墙 / 破解 / 屏蔽 —— 一个都不要出现在任何文件里。
- **署名不要改**：`海风（kele551）`（中文）/ `HaiFeng (kele551)`（ASCII）/ `Copyright (C) 2026 HaiFeng (kele551)`。
- **仓库里不许出现本机路径、私人邮箱、令牌**（`tools/preflight_release.py` 的 ⑥ 节会拦）。
- 升级/自启/还原这类系统行为，改动后要能说清**怎么退回去**。

## 提交与验收

- 提交信息：中文，`类型: 说明`（`fix:` / `feat:` / `docs:` / `chore:`），**一次一件事**；
- **版本号只在发版时改**（`tools/publish.py release <版本> --github` 会同时改三处版本常量并生成升级源）；
- 在 PR / 回复里写清**你跑过哪些命令、结果如何** —— 这个仓库的"契约"是 `tools/preflight_release.py`，能全绿最好；
- 测试会真的启动程序并换掉当前桌面壁纸，跑之前心里有数。

## 平台（三个，代码一致）

代码同时镜像到三处：**Gitee（主源）** / **GitHub（镜像）** / **AtomGit（代码镜像）**。
**二进制发行包只发 Gitee 与 GitHub** —— AtomGit 目前没有附件上传接口（它的 Release 只提供源码归档）。

```powershell
git push origin main --tags                     # Gitee（本仓库 origin 就是 Gitee）
git push atomgit main --tags                    # AtomGit（令牌走 GIT_ASKPASS，不会出现在命令行）
# GitHub 侧走工作区的纯 REST 工具（见维护者工作区工具说明）
```

三个平台改完都要推，**内容必须逐字节一致**（判定方法：`git diff atomgit/main origin/main` 应为空）。

## 任务从哪来

GitHub Issues 里带 `good first issue` / `help wanted` 标签的条目，每条都写了**验收标准**；
没有把握的大改动，先开 Issue 说方案再动手。仓库里还有一份机器可读的任务清单 [TASKS.md](TASKS.md)。

---

## English summary (for AI agents)

- **What it is**: a Python launcher (`launcher.py` → packaged as `壁纸助手.exe`) plus two PowerShell scripts
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
  - don't change the author strings (`海风（kele551）` / `HaiFeng (kele551)`).
- **Commits**: one change per commit, Chinese conventional prefixes (`fix:` / `feat:` / `docs:` / `chore:`),
  and state which commands you ran and what they printed. Version numbers change only at release time.
- **Backlog**: [TASKS.md](TASKS.md) and issues labelled `good first issue`.
