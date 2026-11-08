# -*- coding: utf-8 -*-
# 作者: 海风（kele551）
"""面板脚本语法闸门：panel.html 里每个 <script> 块都必须能被 JS 引擎解析。

现场（2026-11-06 真实事故）：一次字符串替换把 `setText("nextSub", …)` 那行的收尾引号
吃掉了，整块 <script> 变成 SyntaxError —— 浏览器里一个函数都不会执行，页面就停在
「正在读取本机状态…」，卡片全是占位符、栏位全挤在一起，用户看到的就是「排版全乱了」。
这种错 Python/PS 侧的语法检查都发现不了（HTML 里的 JS 谁都不管），只能用 JS 引擎自己判。

没有 node 就 [SKIP] 并打印原因（克隆出来的环境可能没装），不假装通过。

用法：
    python tests\\test_panel_js.py
    python tests\\test_panel_js.py <panel.html 路径>
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.dirname(HERE)
PANEL = sys.argv[1] if len(sys.argv) > 1 else os.path.join(SRC, 'panel.html')


def check_block(node, path):
    if node.lower().endswith(('.cmd', '.bat')):
        cmd = '"%s" --check "%s"' % (node, path)
        return subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8',
                              errors='replace', shell=True)
    return subprocess.run([node, '--check', path], capture_output=True, text=True,
                          encoding='utf-8', errors='replace')


def main():
    if not os.path.exists(PANEL):
        print('[FAIL] 找不到 panel.html：%s' % PANEL)
        return 1
    with open(PANEL, encoding='utf-8') as f:
        html = f.read()
    blocks = re.findall(r'(?s)<script>(.*?)</script>', html)
    if not blocks:
        print('[FAIL] panel.html 里没有 <script> 块（页面全靠它驱动）')
        return 1
    node = shutil.which('node') or shutil.which('node.exe')
    if not node:
        print('[SKIP] 这台机器没有 node，跳过 JS 语法检查（%d 个脚本块未验）' % len(blocks))
        return 0
    tmp = tempfile.mkdtemp(prefix='bwjs-')
    bad = 0
    try:
        for i, code in enumerate(blocks, 1):
            p = os.path.join(tmp, 'block%d.js' % i)
            with open(p, 'w', encoding='utf-8') as f:
                f.write(code)
            r = check_block(node, p)
            if r.returncode != 0:
                bad += 1
                print('[FAIL] 第 %d 个脚本块解析失败（%d 字符）' % (i, len(code)))
                for line in (r.stderr or '').strip().splitlines()[:8]:
                    print('   ' + line)
            else:
                print('[ok] 第 %d 个脚本块语法通过（%d 字符）' % (i, len(code)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if bad:
        print('未通过：%d 个脚本块有语法错误 —— 浏览器会整块不执行，页面只剩占位符，'
              '看起来像「排版全乱了」' % bad)
        return 1
    print('全部通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())
