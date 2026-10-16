# 项目结构与上手路线（桌面壁纸）

> 给想改代码的人：**15 分钟看懂这个项目从哪进、改哪儿、改完怎么验。**
> 作者：海风（kele551） · 仓库：https://gitee.com/kele551/ms-wallpaper-assistant

---

## 一、一句话架构

一个 **Python 启动器**（`launcher.py` → 打包成 `壁纸助手.exe`）负责"落地、升级、后台自启"，
真正的业务逻辑是两份 **PowerShell 脚本**（`core.ps1` 换壁纸、`menu.ps1` 交互菜单），
首次运行时由启动器释放到用户数据目录，之后可以**热更新**（不换 exe 也能更新脚本）。

```
壁纸助手.exe (launcher.py)
   ├─ 首次运行：把内嵌的 core.ps1 / menu.ps1 释放到 %LOCALAPPDATA%\壁纸助手 并记版本
   ├─ 双击      ：开控制台 → 调 menu.ps1（菜单）
   ├─ 定时/后台  ：调 core.ps1 -Cycle（换下一张壁纸，不建任何窗口）
   └─ 升级      ：读线上 version.json → 比对 → 下载并校验 sha256 → 换 exe / 热更脚本
```

---

## 二、目录与文件职责

| 文件 | 职责 | 改它的场景 |
|---|---|---|
| `launcher.py` | 唯一入口：落地、数据目录、菜单/后台调度、热更新与升级校验、自启 | 改升级流程、启动行为、数据目录规则 |
| `core.ps1` | 核心库：图源下载、保存位置、库上限与清理、设壁纸 | 改图源、改换图逻辑、改清理规则 |
| `menu.ps1` | 交互菜单（状态、换位置、看日志 `[L]`、检查更新…） | 改菜单文案与选项 |
| `version.json` | **升级源**：版本号 + `core.ps1`/`menu.ps1` 的 sha256 + `launcher` 指纹 | 发版脚本自动生成，**不要手改** |
| `build-exe.py` | 打包（PyInstaller 6.22.3，产物 `壁纸助手.exe`） | 改打包参数、内嵌资源 |
| `tools/make_version_json.py` | 生成 `version.json`（脚本指纹） | 发版链路 |
| `tools/publish.py` | 一键发布：改版本号 → 打包 → 生成升级源 → 双平台提交/发行版 → 验真 | 发版链路 |
| `tools/preflight_release.py` | **发版前自检闸门**（版本一致性、冷启动、完整升级演练、失败分支、还原） | 发版前必跑；新增检查项 |
| `tests/test_all.py`、`tests/syn.ps1`、`tests/gen_ps_test.py` | 端到端与菜单层测试、脚本同步 | 改逻辑后回归 |
| `docs/` | 治理文档（合规 / 安全 / 贡献 / 签名政策 / 行为准则 / 更新记录 / 英文说明） | 文档类改动 |

**运行时数据目录**（不随程序放，删掉这个目录 = 彻底卸载）：
`%LOCALAPPDATA%\壁纸助手\` —— 里面有 `config.json`、`state.json`、`wallpaper.log`、`dl_ledger.log`。
在该目录放一个空的 `portable.txt`，就切回"数据跟着 exe 走"（做 U 盘便携版用）。

---

## 三、想改一个功能，该动哪里

| 我想… | 去哪 |
|---|---|
| 加一个新图源 | `core.ps1` 的图源定义与下载段（现有：必应每日一图、Windows 聚焦） |
| 改"图片存哪里"的挑选规则 | `core.ps1` 顶部 `Get-BwPickRoot` / `Get-BwDefaults` 一带（规则：优先本地固定磁盘里可用空间最大的非系统盘） |
| 改库上限 / 清理策略 | `core.ps1` 里上限与 `Remove-BwFile`（超限时把**已经看过的、最老的**移进回收站，绝不删没看过的） |
| 改菜单文字或选项 | `menu.ps1` |
| 改升级 / 自启 / 闪窗行为 | `launcher.py` |
| 改打包产物名或内嵌文件 | `build-exe.py` |
| 改门面与文档 | `README.md`、`docs/*.md` |

---

## 四、本地跑起来 & 提交前要跑的

```powershell
# 1) 只跑源码（不需要打包）
python launcher.py            # 双击 exe 的等价物：控制台 + 菜单
python launcher.py --daemon   # 后台守护（不建窗口）

# 2) 语法检查（改过 .ps1 必做，PowerShell 解析 0 错误才算过）
powershell -NoProfile -Command "[void][System.Management.Automation.Language.Parser]::ParseFile('core.ps1',[ref]$null,[ref]$errs); $errs.Count"

# 3) 端到端测试（会启动真程序，注意它可能换掉你当前桌面壁纸）
python tests/test_all.py

# 4) 发版前自检（发布/替换发行版附件前**必须全绿**）
python tools/preflight_release.py
```

**改完请照着这几条自查**：`.ps1` 存成 **UTF-8 带 BOM**（丢了 BOM，PowerShell 5.1 会按 ANSI 读 → 中文乱码 → 解析失败）；
行尾保持仓库现状（**LF**）；对外文案不要出现"绕过 / 翻墙 / 梯子 / 科学上网 / 墙 / 破解 / 屏蔽"这类词。

---

## 五、贡献怎么提

1. 先开 Issue 说清你想改什么（或认领已有任务）；
2. 小步提交，一次一件事，提交信息用中文写清"改了什么、为什么"；
3. PR 里说明**你验证过什么**（跑了哪些测试、在什么机器/系统上跑过）—— 这个项目的闸门是 `tools/preflight_release.py`，能全绿最好；
4. 详细约定见 [CONTRIBUTING.md](CONTRIBUTING.md)。
