# TASKS —— 可认领的任务清单（桌面壁纸）

> 这里的每一行都是**能独立做完、且有明确验收**的事。规则很简单：
> **一次一件事 → 先看「涉及文件」→ 做完贴出「验收命令」的输出 → 把状态改成 `done`**。
> 大改动先开 Issue 说方案；验收命令必须**真的跑过**，别只讲道理。
> 关联的 GitHub Issue 写在下表 `issue` 列（带 `good first issue` 标签的适合第一次上手）。

| id | 任务 | 难度 | 涉及文件 | 验收（跑什么） | issue | 状态 |
|---|---|---|---|---|---|---|
| W-01 | 英文说明（`docs/README_EN.md`）与中文 README 门面/内容对齐 | ★ | `docs/README_EN.md` | 徽章逐个 200 且是图片；文件内章节引用都有效；按键说明与中文一致 | #2 | open |
| W-02 | 核对 CHANGELOG 里「未发布」那段与 README 的口径矛盾，并清掉仓库外路径引用 | ★ | `docs/CHANGELOG.md`、`README.md` | `git grep -n "未发布" -- docs/CHANGELOG.md README.md` 两处口径一致；`git grep -n "logs\\\\" -- docs/CHANGELOG.md` 无命中 | #3 | open |
| W-03 | README 接上演示页，并在页面上标注录制版本 | ★ | `README.md`、`docs/demo/index.html` | `git grep -n "docs/demo" -- README.md` 有命中；页面出现「录制于 …」 | #4 | open |
| W-04 | 修 `tools/publish.py` 的版本号改写规则：`core.ps1` 那条正则匹配不到内容（死配置），README 那条也已失效 | ★★ | `tools/publish.py` | 在临时副本上跑一次「改版本号」逻辑，三处版本常量 + README 当前版本文字都被改到 | #5 | open |
| W-05 | `docs/CONTRIBUTING.md` 里"禁用词"那段三句话互相打架，统一成一处口径 | ★ | `docs/CONTRIBUTING.md` | 段落里不再出现"清单见维护者本地章程"这类指向仓库外的说法 | #6 | open |
| W-06 | `tests/gen_ps_test.py` 模板里仍写死 `F:\wp-src` 与旧图标名，改成中性占位符 | ★★ | `tests/gen_ps_test.py` | 把仓库整份复制到别处后按 README 跑测试，能直接跑通 | #7 | open |
| W-07 | 给 README 补一节独立的「从源码构建」（现在只指向 CONTRIBUTING 第四节） | ★ | `README.md` | README 里能直接看到构建命令与产物名 | #8 | open |

## 验收时请顺手遵守的约定

- **`.ps1` 改完必须做一次语法解析**（0 错误才算过），并确认仍是 **UTF-8 带 BOM**；
- 行尾保持 **LF**；对外文案不许出现 绕过 / 翻墙 / 梯子 / 科学上网 / 墙 / 破解 / 屏蔽；
- 详细约定见 [AGENTS.md](AGENTS.md)（AI 助手）/ [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md)（人类贡献者）。
