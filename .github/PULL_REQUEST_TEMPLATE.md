<!--
提 PR 之前请先读 CONTRIBUTING.md。这份模板不长，但每一栏都对应一次真实踩过的坑。
-->

## 改了什么

<!-- 一两句话说清"为什么改"，比"改了哪个文件"重要。 -->

- 

## 怎么验证的

<!-- 必填。写清你实际跑过的命令与看到的结果；"应该没问题"不算验证。 -->

```
# 例：
python build-exe.py --release
# 双击 微软壁纸助手.exe → 菜单能开、[2] 改「每轮抓几张」能存住
```

- [ ] 我自己从源码构建过（`python build-exe.py --release`），产物能双击打开菜单
- [ ] 改动涉及 `.ps1` 时：文件仍是 **UTF-8 带 BOM**（PS 5.1 对无 BOM 文件按 ANSI 读，中文会乱码并解析失败）

## 自查清单

- [ ] 提交信息符合 [Conventional Commits](https://www.conventionalcommits.org/) 风格（`fix:` / `feat:` / `docs:` / `chore:` …），正文中文
- [ ] **没有整文件重写行尾**：仓库文本文件是 **LF**，我的编辑器没把它变成 CRLF（`git diff --stat` 不应出现"整个文件都变了"）
- [ ] 没把私人邮箱、令牌、口令写进任何文件（对外文档里反馈入口一律用 Issues 链接）
- [ ] 没改动 `version.json` 的版本号/指纹，除非这就是一次发版（发版由维护者按 `tools/publish.py release` 流程走）
- [ ] 对外文案没有用禁用词，改用中性技术表述（清单见 [CONTRIBUTING.md](../blob/main/CONTRIBUTING.md)）
- [ ] 改了行为的话，README 的「常见问题」或《使用说明》对应段落一起改了 —— 文档与实现不能各说各话
- [ ] 没有新增第三方运行时依赖（本项目坚持：主程序只用标准库；打包只额外需要 pyinstaller）

## 关联 Issue

<!-- 例：Closes #12 -->
