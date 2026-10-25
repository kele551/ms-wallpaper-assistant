# 作者: 海风（kele551）
# 用途: 把 repo\panel.html 嵌进 core.ps1 的 PANEL_HTML_BEGIN/END 之间。
#   为什么必须内嵌: 老客户端的升级循环只认 core.ps1 / menu.ps1 两个文件名,
#   多一个 panel.html 他们永远收不到。所以页面源码留在 panel.html(好改好审),
#   发版前用这个脚本同步进 core.ps1。
import io
import os
import re
import sys

# 仓库根由脚本自己的位置推导：以前这里写死过维护者本机的绝对路径(旧目录名还在里面)，
# 项目目录一改名嵌面板就直接失败，而发版闸门只扫 panel.html、看不见工具脚本里的这种死路径。
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
PANEL = os.path.join(REPO, "panel.html")
CORE = os.path.join(REPO, "core.ps1")
BEGIN = "# >>> PANEL_HTML_BEGIN"
END = "# <<< PANEL_HTML_END"


def main():
    html = io.open(PANEL, encoding="utf-8").read()
    # 这里用单引号 here-string: 里面的 ${...}、$var 都不会被 PowerShell 展开。
    # 唯一的硬约束: 不能出现"行首的 '@", 否则 here-string 提前结束。
    for i, line in enumerate(html.splitlines(), 1):
        if line.startswith("'@"):
            print("PANEL_HTML 第 %d 行以 '@ 开头, 会截断 here-string, 请改行首" % i)
            return 2

    core = io.open(CORE, encoding="utf-8-sig").read()
    if BEGIN not in core or END not in core:
        print("core.ps1 里找不到 PANEL_HTML 标记, 先补标记再跑")
        return 2

    head, rest = core.split(BEGIN, 1)
    _, tail = rest.split(END, 1)
    block = (
        BEGIN + "（本段由 tools/embed_panel.py 从 panel.html 生成，勿手改）\n"
        "$global:BwPanelHtml = @'\n" + html + "\n'@\n" + END
    )
    out = head + block + tail

    with io.open(CORE, "w", encoding="utf-8-sig", newline="") as f:
        f.write(out)
    size = len(out.encode("utf-8"))
    print("已嵌入 panel.html: %d 字符 / core.ps1 现在 %d 字节" % (len(html), size))
    return 0


if __name__ == "__main__":
    sys.exit(main())
