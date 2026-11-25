# -*- coding: utf-8 -*-
"""
壁纸助手 —— 一键发布流水线（只发 GitHub 主源）

【2026-11-25 红线第 36 条】GitHub 是唯一对外主源：Release、附件、升级源 version.json/.sig、
源码/tag 推送一律只走 GitHub。GitCode（=AtomGit）只作 Pull 被动镜像，本脚本**完全不主动碰它**
（不建版、不传附件、不验真、不 push）；Gitee 早已禁推（451）。
GitHub 侧走本机登录态的 gh.exe（它自己会挑线路，比手搓 REST 稳）。

用法:
    python tools/publish.py release 2.4.2            # 发 GitHub
    python tools/publish.py release 2.4.2 --skip-build   # 已有 exe, 只做发布
    python tools/publish.py release 2.4.2 --notes 文件.md # 指定发布说明
    python tools/publish.py verify 2.4.2             # 只读：线上验真，什么都不发

release 子命令依次做:
    ① 改三处版本号 (core.ps1 / menu.ps1 / launcher.py)
    ② 打包 (build-exe.py --release)  ->  exe / 带版本号 exe / ASCII 名 zip
    ③ 生成升级源 version.json (必须与本次 exe 同一份, 否则老客户端校验不过)
    ③+ 提交 + 打 tag + **只推 tag**（main 留到最后，见下）
    ④ GitHub 建发行版 + 上传附件(zip / exe / version.json / .sig)
    ⑤ README 下载链接指向新版
    ⑥ 验真: 每个附件从 GitHub 下载回来比对 SHA256
    ⑦ **main 最后推** —— 升级源就是 main 上那份 version.json，它一上线全体老用户
       立刻开始提示升级，那时附件必须已经躺好；然后回读线上 version.json + .sig 真验一遍签
"""
import os
import re
import sys
import json
import time
import shutil
import zipfile
import socket
import hashlib
import subprocess
import urllib.error
import urllib.parse
from urllib import request as _rq
from pathlib import Path

quote = urllib.parse.quote          # 老代码里直接用 quote()，这里补个名字

# 2026-10-12 修(发布现场崩过一次): Windows 控制台默认 GBK ——
# build-exe.py 子进程按 GBK 打中文路径, 本脚本按 UTF-8 解码得到一个 �,
# 再把这行 print 回 GBK 控制台就 UnicodeEncodeError, 发布跑到一半当场崩。
# 父子两侧都钉成 UTF-8(与 preflight_release.py 同一套做法)。
try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

REPO_DIR = Path(__file__).resolve().parent.parent
OWNER, REPO = 'kele551', 'ms-wallpaper-assistant'
BRANCH = 'main'
GH_REPO = '%s/%s' % (OWNER, REPO)
# 【2026-11-25 红线第 36 条】GitHub 是唯一对外主源：Release、附件、升级源 version.json/.sig、
# 源码/tag 推送一律只走 GitHub。GitCode（=AtomGit）只作 Pull 被动镜像，本脚本**完全不主动碰它**
# （不建版、不传附件、不验真、不 push）；Gitee 早已禁推（451）。
# 本仓库 GitHub 的 remote 名字是历史遗留，叫 `github`。按 URL 认远端、不按名字写死，
# gitcode / gitee 永远不会被推到。
# ---- 本机私有配置（可选，永不进仓库）----------------------------------------
# 公开仓库里不写任何维护者本机路径。本机要用的解释器 / git / 推送脚本 / gh 位置，
# 一律按：① 环境变量 → ② 本机私有配置 ~/.mwa-publish.json → ③ 与机器无关的默认值。
# 私有配置文件示例（放在用户主目录，文件名前面有个点）：
#   {"python": "C:\\\\Python313\\\\python.exe", "git_dir": "C:\\\\Program Files\\\\Git\\\\mingw64\\\\bin",
#    "gh": "F:\\\\Harness\\\\toolchain\\\\gh\\\\bin\\\\gh.exe", "git_proxy": "http://127.0.0.1:8787"}
_CFG_PATH = Path.home() / '.mwa-publish.json'
_CFG = {}
if _CFG_PATH.is_file():
    try:
        _CFG = json.loads(_CFG_PATH.read_text(encoding='utf-8'))
    except Exception as _e:
        print('警告: %s 解析失败(%s)，按"没有本机配置"继续' % (_CFG_PATH, _e), file=sys.stderr)

# 打包 / 子脚本用的解释器：默认就用当前这个解释器
PY = os.environ.get('MWA_PY') or _CFG.get('python') or sys.executable


def _find_git_dir():
    """找 git.exe 所在目录：环境变量 → 本机配置 → PATH → 常见安装位置；找不到返回空串。"""
    for _c in (os.environ.get('MWA_GIT'), _CFG.get('git_dir')):
        if _c and Path(_c, 'git.exe').is_file():
            return str(_c).replace('\\', '/')
    _w = shutil.which('git')
    if _w:
        return str(Path(_w).parent).replace('\\', '/')
    for _c in (r'F:\Harness\toolchain\PortableGit\versions\1.2.0\mingw64\bin',
               r'C:\Program Files\Git\cmd', r'C:\Program Files (x86)\Git\cmd'):
        if Path(_c, 'git.exe').is_file():
            return _c.replace('\\', '/')
    return ''


GIT_EXEC_PATH = _find_git_dir()
# 有绝对路径就用绝对路径: 有的执行环境按名字找不到 git(WinError 2)
GIT_EXE = (GIT_EXEC_PATH + '/git.exe') if GIT_EXEC_PATH else 'git'
# GitHub 侧走本机登录态的 gh.exe(2026-10-26 起): 它自己会挑直连/端口, 比手搓 REST 稳,
# 也不依赖那个从没入库过的 tools/github_push.py。
GH = (os.environ.get('MWA_GH') or _CFG.get('gh') or shutil.which('gh')
      or (r'F:\Harness\toolchain\gh\bin\gh.exe' if os.path.exists(r'F:\Harness\toolchain\gh\bin\gh.exe') else 'gh'))  # 2026-11-16: 本机 gh 不在 Path（以前走到 gh release create 就 FileNotFoundError）
# 【2026-11-25 口径】只发 GitHub；GitCode/AtomGit 纯 Pull 被动镜像，不主动推。
# GitHub 推送线路：中转优先（_relay_proxy() 自动发现端口）→ 直连 → api.github.com 兜底（见 _push）。
# git 推送凭据只从本机只读凭据文件取；显式清空系统级 helper，避免残留凭据助手弹框（A 后台推 git 禁弹窗）。
GIT_CRED = Path(r'F:\Harness\secrets\git-credentials')
ZIP_TPL = 'MSWallpaperAssistant-v%s.zip'          # zip 的 ASCII 名不改(仓库英文标识稳定)


def _stem_from_launcher(name, fallback):
    """从 launcher.py 读一个字符串常量（APP_NAME / EXE_STEM），读不到就用 fallback。

    为什么从源码里读而不是在这儿再写一遍：2026-10-25 文件名改成 桌面壁纸.exe 时，
    发版脚本里 '壁纸助手.exe' 一共散在 5 个文件、十几处；version.json 的 launcher.url
    和实际上传的附件名差一个字，全体老用户的自动升级就 404。唯一来源放 launcher.py。
    """
    try:
        txt = (REPO_DIR / 'launcher.py').read_text(encoding='utf-8-sig')
        m = re.search(r"^%s\s*=\s*'([^']+)'" % name, txt, re.M)
        if m:
            return m.group(1)
    except Exception as _e:
        print('警告: 从 launcher.py 读 %s 失败(%s)，用默认值 %r' % (name, _e, fallback), file=sys.stderr)
    return fallback

# 2026-10-12 产品改名: 「微软壁纸助手」->「壁纸助手」。GitHub 侧的 ASCII 附件名
# (MSWallpaperAssistant-vX.Y.Z.exe)同样不改 —— 那条线路怕中文名被削。
# 2026-10-25 文件名更正: exe 文件名跟显示名一致 -> 桌面壁纸.exe。
# APP_NAME 继续表示数据目录名(%LOCALAPPDATA%\壁纸助手), 那个不随文件名改。
# 两个名字都从 launcher.py 推导(那处是唯一来源), 免得改名时漏改一处就 404。
APP_NAME = _stem_from_launcher('APP_NAME', '壁纸助手')
EXE_STEM = _stem_from_launcher('EXE_STEM', APP_NAME)
EXE_NAME = EXE_STEM + '.exe'                       # version.json 里写的就是这个名字, 必须传上去

# 版本常量所在的文件（发版时改这几处）
#   · core.ps1 **没有** $global:BWVersion（版本只在 launcher.py 与 menu.ps1 定义，
#     见 tools/preflight_release.py ③ 节），所以这里**不放 core.ps1** —— 放了就是一条
#     永远匹配不到的死规则，还会让人误以为"core.ps1 的版本号也改了"。
#   · README.md 改的是「**当前最新：vX.Y.Z**」这句正文；静态徽章 `version-vX.Y.Z-blue` 早已
#     换成动态徽章（img.shields.io/github/v/release），原来那条规则同样永远匹配不到。
VER_FILES = [
    ('menu.ps1', re.compile(r"(\$global:BWVersion\s*=\s*')[0-9.]+(')"),
     lambda v: r"\g<1>%s\g<2>" % v),
    ('launcher.py', re.compile(r"(VERSION\s*=\s*')[0-9.]+(')"),
     lambda v: r"\g<1>%s\g<2>" % v),
    ('README.md', re.compile(r'(\*\*当前最新：v)[0-9.]+(\*\*)'),
     lambda v: r"\g<1>%s\g<2>" % v),
    ('README.md', re.compile(r'(点这里下载 v)[0-9.]+'),
     lambda v: r"\g<1>%s" % v),
    ('使用说明.txt', re.compile(r'使用说明（v[0-9.]+ 起界面是独立控制面板窗口'),
     lambda v: r"使用说明（v%s 起界面是独立控制面板窗口" % v),
]

# ---------- 本地改动 ----------
def bump_version(ver):
    changed = []
    for name, pat, rep in VER_FILES:
        f = REPO_DIR / name
        txt = f.read_text(encoding='utf-8')
        new = pat.sub(rep(ver), txt, count=1)
        if new != txt:
            f.write_text(new, encoding='utf-8', newline='')   # 保住原行尾(LF), 别让 Windows 转成 CRLF
            changed.append(name)
    print('① 版本号已改:', ', '.join(changed) if changed else '(已是该版本)')
    return changed


def extract_notes(ver):
    """从 CHANGELOG 取该版本的条目, 去掉项目符号前缀, 保持 Markdown 可读。

    兼容两种写法:
      `- **v2.0.7** 一句话`        —— v1.6.x 及以前的格式
      `## v2.0.7 — 日期` + 多行正文 —— v2.x 起改用段落式, 以前这里匹配不到、发布说明会是空的
    """
    cl = (REPO_DIR / 'docs' / 'CHANGELOG.md').read_text(encoding='utf-8')
    m = re.search(r'^- \*\*v%s\*\*(.+?)(?=^- \*\*v|\Z)' % re.escape(ver),
                  cl, re.S | re.M)
    if m:
        body = m.group(1).strip()
        body = re.sub(r'\s+\n', '\n', body)
        body = body.replace('\n- ', '\n- ')
        return '## v%s\n\n%s' % (ver, body)

    m = re.search(r'^##\s*v%s(?![0-9.])[^\n]*\n(.+?)(?=^##\s|\Z)' % re.escape(ver),
                  cl, re.S | re.M)
    if m:
        return '## v%s\n\n%s' % (ver, m.group(1).strip())
    return None


def run(cmd, cwd=REPO_DIR, env=None, check=True):
    e = os.environ.copy()
    if GIT_EXEC_PATH:            # 没找到 git 目录就交给 PATH 上那个 git
        e['GIT_EXEC_PATH'] = GIT_EXEC_PATH
        # git.exe 不在系统 PATH 里, 得自己塞进去, 否则 subprocess 找不到 'git'
        e['PATH'] = GIT_EXEC_PATH.replace('/', os.sep) + os.pathsep + e.get('PATH', '')
    if env:
        e.update(env)
    cmd = list(cmd)
    if cmd and cmd[0] == 'git':                   # 不靠 PATH 找, 直接用绝对路径
        cmd[0] = GIT_EXE.replace('/', os.sep)
    print('   $', ' '.join(cmd))
    r = subprocess.run(cmd, cwd=str(cwd), env=e,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = r.stdout.decode('utf-8', 'replace')
    if check and r.returncode != 0:
        print(out)
        raise RuntimeError('命令失败: %s' % ' '.join(cmd))
    return out


GIT_ID = ['-c', 'user.name=海风（kele551）',
          '-c', 'user.email=kele551@users.noreply.github.com']
# 全局 git config 里没有身份（用户要求不改 config），所以每次提交/打标签都显式带上。


def _git_raw(args, extra_c=None):
    """跑一条 git，返回 (退出码, 输出)。推送成败只信退出码 + 远端 sha。

    extra_c: 命令行前置的 git -c 配置（凭据 helper / 代理），只在本次命令上生效，不落 config。
    """
    e = os.environ.copy()
    # 缺了这两条，git 在后台遇到需要凭据时可能弹 GUI，一直等到有人点（见 §0.1 A）。
    e['GIT_TERMINAL_PROMPT'] = '0'
    e['GCM_INTERACTIVE'] = 'never'
    if GIT_EXEC_PATH:
        e['GIT_EXEC_PATH'] = GIT_EXEC_PATH
        e['PATH'] = GIT_EXEC_PATH.replace('/', os.sep) + os.pathsep + e.get('PATH', '')
    args = list(args)
    # 在参数序列里找 'git' 项替换成绝对路径（extra_c 的 -c 会把 git 挤到非首元素）。
    for i, a in enumerate(args):
        if a == 'git':
            args[i] = GIT_EXE.replace('/', os.sep)
            break
    if extra_c:
        # -c 必须放在可执行文件之后：Windows CreateProcess 把列表首元素当 exe，
        # 若 -c 排在绝对路径 git 之前会被判成可执行文件而 WinError 2。
        args = [args[0]] + extra_c + args[1:]
    print('   $', ' '.join(args))
    # 加个总超时：凭据弹窗/网络黑洞时别再静默卡二十分钟（本机踩过）
    try:
        r = subprocess.run(args, cwd=str(REPO_DIR), env=e,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=900)
    except subprocess.TimeoutExpired:
        return 1, '超时 900 s: %s' % ' '.join(args)
    return r.returncode, r.stdout.decode('utf-8', 'replace')


def remotes_by_host():
    """按 **URL** 挑出要推的远端：**只推 GitHub 主源**。

    【2026-11-25 红线第 36 条】所有程序只发 GitHub：Release、附件、升级源、源码/tag 推送
    一律只走 GitHub。GitCode（=AtomGit）降为纯 Pull 被动镜像，**发版流水线不再主动 push
    GitCode**（不建版、不传附件、不验真、也不在推送列表里硬推）；Gitee 早已禁推（451）。
    按 URL 认远端、不按名字写死，gitcode / gitee 永远不会被推到。
    """
    got, other = {}, []
    for line in run(['git', 'remote', '-v']).splitlines():
        if '(fetch)' not in line:
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        name, low = parts[0], parts[1].lower()
        if 'gitcode.com' in low:
            got.setdefault('gitcode', name)
        elif 'github.com' in low:
            got.setdefault('github', name)
        else:
            other.append('%s(%s)' % (name, low.split('//')[-1].split('/')[0]))
    if 'github' not in got:
        raise RuntimeError('本仓库没有 GitHub 的 remote —— 拒绝发布（GitHub 是主源，必须在）')
    # GitCode 被动镜像，发版不主动推；其余历史入口一并跳过。
    skipped = [got['gitcode']] if 'gitcode' in got else []
    if other:
        skipped += other
    if skipped:
        print('   不推这些 remote（GitCode 被动镜像 / 已停更）:', ', '.join(skipped))
    return [got['github']]


def _remote_exists(remote):
    return remote in _git_raw(['git', 'remote'])[1]


def pick_remote_sha(ls_remote_output, ref):
    """从 `git ls-remote <remote> <ref>` 的输出里挑出**这个 ref 自己**的 sha。

    只吃字符串、不碰 git —— 这样"复核"这一步本身是能用假数据测的（2026-11-05 第一次
    用重构后的发布脚本发版就栽在这儿）：

    - annotated tag 会返回**两行**：`<tag 对象 sha>\trefs/tags/vX.Y.Z` 与
      `<指向的 commit sha>\trefs/tags/vX.Y.Z^{}`；而 `git rev-parse vX.Y.Z` 给的是
      **tag 对象**那一行的 sha。
    - 老写法把整段输出 `.split()` 摊平再取 `[1:2]`，取到的是**第一行的 ref 名**，
      永远等不上 sha —— tag 明明已经推上去（远端 ls-remote 看得见），脚本却当场
      RuntimeError 退出，等于"发布失败"。分支只有一行，取到的还是 ref 名。
    - 所以要按行拆、按 ref 认行，并且优先**不带 `^{}` 的那一行**（剥出来的 commit 只当兜底）。

    找不到就返回空串（让调用方报"远端取不到"，而不是悄悄比出一个假通过）。
    """
    def _same_name(name):
        # 传短名（main / v2.4.3）时远端给的是全名（refs/heads/main / refs/tags/v2.4.3），
        # 只能按结尾认；传全名时就逐字比，免得 "main" 误匹配 "refs/heads/domain"。
        if ref.startswith('refs/'):
            return name == ref
        return name == ref or name.endswith('/' + ref) or name.endswith(':' + ref)

    peeled = ''
    for line in (ls_remote_output or '').splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        sha, name = parts[0], parts[1]
        if name.endswith('^{}'):
            if _same_name(name[:-3]):
                peeled = peeled or sha   # 兜底：远端只给了剥出来的那一行
            continue
        if _same_name(name):
            return sha
    return peeled


def _cred_args():
    """把 git 的凭据来源钉死成「清空 helper + 只读凭据文件」，绝不弹 GUI 选择框。

    helper-selector 会弹「Select a credential helper」窗口，后台进程就卡在那里等点击
    （2026-11-14 实测：GitHub tag 推不出去、日志停在 push 之后没有任何输出）。
    """
    p = os.environ.get('MWA_GIT_CRED') or GIT_CRED.as_posix()
    if p and os.path.exists(p):
        return ['-c', 'credential.helper=', '-c',
                'credential.helper=store --file=%s' % p.replace('\\', '/')]
    return []


def _proxy_alive(proxy_url, timeout=1.0):
    """本地代理端口是否真的在监听。

    2026-11-14 下午的坑：代理进程没起，`push github` 被派去 8787 → 2081 ms 后
    `Could not connect to server`，这条日志被读成「GitHub 线路断了」，于是绕去 API 复刻，
    平白造出两平台 head 分歧。代理没在监听就不该派过去。
    """
    try:
        u = urllib.parse.urlparse(proxy_url)
        host, port = u.hostname, (u.port or 80)
        if not host or not port:
            return False
        socket.create_connection((host, port), timeout=timeout).close()
        return True
    except OSError:
        return False


def _relay_proxy(timeout=0.4):
    """找一个**真正在监听**的本地中转端口，返回 proxy url；都没有返回 ''。

    狐径(FoxPath)首选 8787，被占时按 (8789, 8797, 8897, 18787, 28787) 顺延 ——
    所以消费方不能死钉 8787：8787 常被 firefox.exe 占成 Bound（不 Listen），
    死钉它等于把每次 push 都送去撞墙（2026-11-14 下午就是这么连打两次假故障）。
    这里按「非 8787 优先」的次序试，命中第一个 Listen 的就用它。
    """
    for port in (8789, 8787, 8797, 8897, 18787, 28787):
        url = 'http://127.0.0.1:%d' % port
        if _proxy_alive(url, timeout=timeout):
            return url
    return ''


def _push_github_via_api(ref):
    """git 两条线路都断时，改走 api.github.com 精确推送（远端 sha 与本地逐位一致）。

    2026-11-14 17:50 实测：github.com:443 的 TCP 建连(0.14s)与 TLS(0.44s) 都成功，
    但请求数据发出后被掐、20 秒断开（curl 退出码 56）；同刻狐径日志写「经狐径 失败
    （代理隧道没建起来）」。也就是 git 传输线本身被掐，换端口/换代理都救不了，
    而 api.github.com 只有 159 ms。

    F:\\Harness\\tools\\github_push_exact.py 不是"复刻"：它按树逐文件补 blob、断言新
    tree sha == 本地 HEAD^{tree}，再用本地 author/committer/时间发 commit 并快进 ref，
    所以远端 commit sha 与本地完全相同，不制造两平台 head 分歧。
    """
    tool = r'F:\Harness\tools\github_push_exact.py'
    if not os.path.exists(tool):
        print('   没有 F:\\Harness\\tools\\github_push_exact.py，无法走 API 通道')
        return False
    # 按 URL 找 GitHub remote（不按名字写死）。
    gh_name = next((r for r in remotes_by_host()), None)
    url = _git_raw(['git', 'remote', 'get-url', gh_name])[1].strip() if gh_name else ''
    m = re.search(r'github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?$', url)
    if not m:
        print('   解析不出 GitHub owner/name：%s' % url)
        return False
    repo = '%s/%s' % (m.group(1), m.group(2))
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    # 2026-11-16: 以前这里一律把 ref 当**分支**去推（写死 /git/refs/heads/<ref>），
    # 兜底把 tag 当分支查 → 404 → 整版中止。
    # 现在先看本地这个 ref 是什么类型：annotated tag 走专门的 tag 推送工具（refs/tags）。
    kind = ''
    try:
        kind = _git_raw(['git', 'cat-file', '-t', ref])[1].strip()
    except Exception:
        kind = ''
    if kind == 'tag':
        tool = r'F:\Harness\tools\github_push_tag_exact.py'
        if not os.path.exists(tool):
            print('   没有 F:\\Harness\\tools\\github_push_tag_exact.py，无法按 tag 走 API 通道')
            return False
        # annotated tag 对象在远端必须指向一个已存在的 commit；commit 随 main 最后推，
        # 此刻还没上 GitHub，直接建 tag 对象会 422 "Could not verify object"。
        # 先把本地 commit 链经 API 精确送到 main（快进、sha 逐位一致），让 tag 有依赖对象；
        # 附件仍在 tag 之后上传、main 的 version.json 仍由 git_push_branch 在验真后收口，
        # 升级源生效顺序不变。
        head = _git_raw(['git', 'rev-parse', 'HEAD'])[1].split()[-1]
        print('   先把 commit %s… 经 API 送到 main（tag 对象的依赖）' % head[:10])
        push_tool = r'F:\Harness\tools\github_push_exact.py'
        if os.path.exists(push_tool):
            pc = subprocess.run([sys.executable, push_tool, '--dir', root, '--repo', repo,
                                 '--branch', BRANCH], capture_output=True)
            pout = (pc.stdout or b'').decode('utf-8', 'replace')
            if pc.returncode != 0:
                print('   先推 commit 链失败: %s'
                      % ((pc.stderr or b'').decode('utf-8', 'replace') or pout).strip()[-300:])
                return False
        print('   git 传输两条线路都断 —— 改走 api.github.com 精确推 tag（%s @ refs/tags/%s）'
              % (repo, ref))
        p = subprocess.run([sys.executable, tool, '--dir', root, '--repo', repo, '--tag', ref],
                           capture_output=True)
        out = (p.stdout or b'').decode('utf-8', 'replace')
        err = (p.stderr or b'').decode('utf-8', 'replace')
        for line in out.strip().splitlines()[-6:]:
            print('   ' + line)
        if p.returncode == 0 and ('与本地一致' in out or '不用动' in out):
            return True
        print('   API 通道失败: %s' % (err.strip()[-300:] or out.strip()[-300:]))
        return False
    print('   git 传输两条线路都断 —— 改走 api.github.com 精确推送（%s @ %s）' % (repo, ref))
    p = subprocess.run([sys.executable, tool, '--dir', root, '--repo', repo, '--branch', ref],
                       capture_output=True)
    out = (p.stdout or b'').decode('utf-8', 'replace')
    err = (p.stderr or b'').decode('utf-8', 'replace')
    for line in out.strip().splitlines()[-6:]:
        print('   ' + line)
    if p.returncode == 0 and ('现在指向' in out or '已经就是本地 HEAD' in out):
        return True
    print('   API 通道失败: %s' % (err.strip()[-300:] or out.strip()[-300:]))
    return False


def _same_sha(a, b, limit=16 * 1024 * 1024):
    """两个文件内容是否逐字节相同（按块比，13 MB 文件也只花几十毫秒）。"""
    try:
        if a.stat().st_size != b.stat().st_size:
            return False
        with open(str(a), 'rb') as fa, open(str(b), 'rb') as fb:
            while True:
                ca = fa.read(1048576)
                cb = fb.read(1048576)
                if ca != cb:
                    return False
                if not ca:
                    return True
    except Exception:
        return False


def _https_alive(host, timeout=3.0):
    """HTTPS 探活：拿得到响应才算这条线能用。

    只用 TCP 会误判 —— 2026-11-16 实测 github.com:443 能建连（TCP 通），
    但 git push 一次要空转 21 秒才报 Connection was reset。所以改成真发一个
    HTTPS 请求（robots.txt，最轻），3 秒内拿不到响应就认定不能走。
    """
    try:
        req = _rq.Request('https://%s/robots.txt' % host,
                          headers={'User-Agent': 'mwa-doctor'})
        opener = _rq.build_opener(_rq.ProxyHandler({}))
        with opener.open(req, timeout=timeout) as r:
            return 200 <= r.status < 500
    except Exception:
        return False


def _push(remote, ref):
    """推一个 ref，推完一律 ls-remote 复核远端 sha。

    线路规则（红线第 2 条：GitHub 推送中转优先，失败回退直连，再走 api.github.com 兜底）：
      · GitHub **中转优先**（本地狐径中转端口，`_relay_proxy()` 自动发现、不钉死 8787），
        中转只有在端口真的 LISTEN 时才派：被占着却没监听时直接连，不白等、也不留假故障日志；
      · 中转/直连都断，再走 api.github.com 精确推送兜底。
    凭据：显式清空系统级 helper-selector（避免残留凭据助手弹窗），只从本机只读凭据文件取。
    代理只在「这次推送」上用 -c 传进去（不落 git config）。退出码只说明「命令没崩」，
    说明不了「远端变了」（管道会把真实状态吞掉，踩过），所以最后一定用 ls-remote 复核。
    """
    if not _remote_exists(remote):
        print('   跳过 %s：本仓库没有这个 remote' % remote)
        return False
    want = _git_raw(['git', 'rev-parse', 'HEAD' if ref == BRANCH else ref])[1].split()[-1]
    relay = _relay_proxy()
    if not _https_alive('github.com'):
        # 直连探活失败时，仍要先试在监听的中转：直连被掐不等于中转隧道也不通
        # （2026-11-25 实测 github.com 5s 超时，但 8787 代理 200；旧逻辑探活一失败就
        # attempts=[]，把可用的中转一并跳过，直接落到 API 兜底，才引出 tag 422）。
        if relay:
            attempts = [relay]
            print('   github.com 直连 3 秒没响应，但中转 %s 在监听，先走中转重试' % relay)
        else:
            attempts = []
            print('   github.com HTTPS 3 秒没响应、也没有中转在监听，不派 git，直接走 api.github.com')
    elif relay:
        attempts = [relay, '']          # 中转优先，失败回退直连
    else:
        attempts = ['']
        print('   没有中转端口在监听（8789/8787/8797/8897/18787/28787），跳过中转、直接连（不派给死代理空等）')
    cred = _cred_args()
    pushed = False
    code = -1
    for px in attempts:
        code, out = _git_raw(['git'] + (['-c', 'http.proxy=' + px] if px else []) + cred
                             + ['push', remote, ref])
        if code == 0:
            pushed = True
            break
        print('   push %s（线路=%s）失败: %s —— 换下一条线路重试'
              % (remote, px or '直连', out.strip()[-160:]))
    api_pushed = False
    if not pushed and _push_github_via_api(ref):
        pushed, api_pushed = True, True
    if not pushed:
        raise RuntimeError('推送 %s -> %s 所有线路均失败' % (ref, remote))
    if api_pushed:
        print('   pushed %s -> %s（经 api.github.com，远端 sha %s… 与本地一致）'
              % (ref, remote, want[:10]))
        return True
    got = ''
    for _round in range(3):
        for px in attempts:
            got = pick_remote_sha(_git_raw(['git'] + (['-c', 'http.proxy=' + px] if px else []) + cred
                                           + ['ls-remote', remote, ref])[1], ref)
            if got:
                break
        if got:
            break
        if _round < 2:
            print('   复核 %s 的远端 sha 取不到（线路抖动），2 秒后重试' % remote)
            time.sleep(2)
    if got and got == want:
        print('   pushed %s -> %s（远端 sha %s… 与本地一致）' % (ref, remote, want[:10]))
        return True
    if got:
        raise RuntimeError('推送 %s -> %s 远端 sha 与本地不同：本地 %s，远端 %s'
                           % (ref, remote, want[:10], got[:10]))
    raise RuntimeError('推送 %s -> %s 的 push 已返回成功，但 ls-remote 连续三次取不到远端 sha'
                       '（线路抖动，**不代表失败**）：本地 %s\n'
                       '请先 `git ls-remote %s %s` 人工核对，核对通过再宣布发版成功。'
                       % (ref, remote, want[:10], remote, ref))


def git_commit_and_tag(ver, files):
    """提交 + 打 tag + **只推 tag**：升级源是 main 上那份 version.json，main 要等附件就位再推。"""
    run(['git', 'add'] + files)
    msg = 'release: v%s' % ver
    if run(['git', 'diff', '--cached', '--name-only']).strip():
        run(['git'] + GIT_ID + ['commit', '-m', msg])
    else:
        print('   工作区没有新改动, 跳过本次提交(只补发版)')
    tag = 'v%s' % ver
    if not run(['git', 'tag', '-l', tag]).strip():
        run(['git'] + GIT_ID + ['tag', '-a', tag, '-m', tag])   # 打 tag 同样要显式带身份
    else:
        print('   tag %s 已存在, 不重复创建' % tag)
    targets = remotes_by_host()
    for remote in targets:
        _push(remote, tag)
    print('④ 代码已提交、tag %s 已推 %s（main 还没推 —— 附件就位后再推，顺序是铁律）'
          % (tag, '+'.join(targets)))


def git_push_branch():
    """附件验真通过之后，才让升级源在 GitHub 上生效。"""
    targets = remotes_by_host()
    for remote in targets:
        _push(remote, BRANCH)
    print('③+ main 已推 %s —— 此刻起线上才开始提示升级' % '+'.join(targets))


def update_readme(ver, commit=True):
    """把 README 里所有版本字样改到 v<ver>。

    2026-10-05 修: 原来只改"网址里的版本"和两处文字, 于是发完版 README 上
    还写着「点这里下载 v2.0.7 安装包」、链接文件名也是 v2.0.7 —— 用户点进去 404,
    上一次就是这个问题被站长当面指出来的。现在**网址、文件名、链接文字、
    「当前最新」这类说明、菜单截图里的版本号**一网打尽。
    """
    f = REPO_DIR / 'README.md'
    txt = f.read_text(encoding='utf-8')
    new = txt
    new = re.sub(r'releases/download/v[0-9.]+/', 'releases/download/v%s/' % ver, new)
    new = re.sub(r'MSWallpaperAssistant-v[0-9.]+\.zip', 'MSWallpaperAssistant-v%s.zip' % ver, new)
    new = re.sub(r'%s-v[0-9.]+\.exe' % EXE_STEM, '%s-v%s.exe' % (EXE_STEM, ver), new)
    new = re.sub(r'version-v[0-9.]+', 'version-v%s' % ver, new)
    new = re.sub(r'下载 v[0-9.]+ 安装包', '下载 v%s 安装包' % ver, new)
    new = re.sub(r'当前云端最新版本：v[0-9.]+', '当前云端最新版本：v%s' % ver, new)
    new = re.sub(r'当前最新：v[0-9.]+', '当前最新：v%s' % ver, new)
    new = re.sub(r'%s v[0-9.]+' % EXE_STEM, '%s v%s' % (EXE_STEM, ver), new)
    new = re.sub(r'比如 `v[0-9.]+`', '比如 `v%s`' % ver, new)
    new = re.sub(r'桌面壁纸 v[0-9.]+', '桌面壁纸 v%s' % ver, new)   # 2026-10-12: 菜单截图标题行也带版本
    new = re.sub(r'例如 v[0-9.]+', '例如 v%s' % ver, new)
    if new != txt:
        # 2026-10-09 (审查 C11): 必须带 newline=''。
        # Windows 上 text 模式会把 '\n' 翻成 '\r\n', 而本仓库的 README.md 是 LF ——
        # 结果下一次发版会把 README **整份**改成 CRLF, 产生"整个文件都变了"的假 diff
        # (本工作区明令禁止)。上面 111 行读的时候就是 newline=''。
        f.write_text(new, encoding='utf-8', newline='')
        if not commit:
            print('⑤ README 已更新到 v%s (交给本次提交一起推)' % ver)
            return True
        # 2026-10-26: 这里原来会当场 `git push origin main` —— 那是"升级源先生效、附件还没就位"
        # 的窗口，用户点升级会 404。现在一律并进本次发布提交，由 git_push_branch() 最后统一推。
        run(['git', 'add', 'README.md'])
        run(['git'] + GIT_ID + ['commit', '-m', 'docs: README 指向 v%s' % ver])
        print('⑤ README 已更新并提交（推送留到附件验真之后）')
    else:
        print('⑤ README 无变化')
    return new != txt


# ---------- 发行版 ----------
def make_version_json():
    """生成升级源 version.json + version.json.sig（要提交到 main，并作为发行版附件上传）。"""
    out = run([PY, os.path.join('tools', 'make_version_json.py')])
    print('   升级源 version.json 已生成:', out.strip().splitlines()[-1] if out.strip() else '')
    vj = REPO_DIR / 'version.json'
    sig = Path(str(vj) + '.sig')
    txt = sig.read_text(encoding='utf-8').strip() if sig.is_file() else ''
    if not re.fullmatch(r'[0-9a-fA-F]{128}', txt):
        sys.exit('version.json.sig 没生成或格式不对（应为 128 个十六进制字符，实际 %d 个）—— 拒绝发布。\n'
                 '客户端只认验过签的升级源，发一份没签名的出去会让已装用户一律被拒绝。' % len(txt))
    print('   升级源 Ed25519 签名: %s（%d 个十六进制字符，前 16 位 %s…）'
          % (sig.name, len(txt), txt[:16]))
    return vj, sig


def _gh(args):
    cmd = [GH] + args
    print('   $', ' '.join(cmd[:7]), '...' if len(cmd) > 7 else '')
    # 2026-11-16：本机 gh 的登录态只存在 keyring 里，`gh auth status` 报"未登录"，
    # 但 `gh auth token` 能取到令牌 —— 子进程不带 GH_TOKEN 就会被 gh 当未登录拒掉
    # （v2.5.1 发版时 GitHub Release 就卡在这一步）。这里显式把令牌注入子进程环境。
    env = dict(os.environ)
    if not (env.get('GH_TOKEN') or env.get('GITHUB_TOKEN')):
        try:
            env['GH_TOKEN'] = gh_token()
        except Exception:
            pass
    r = subprocess.run(cmd, cwd=str(REPO_DIR), capture_output=True, text=True, env=env,
                       encoding='utf-8', errors='replace', timeout=1800)
    return r.returncode, ((r.stdout or '') + (r.stderr or ''))


def _gh_rest(method, path, token):
    """调 api.github.com 原生 REST（DELETE 删旧附件用）；返回 (状态码, 文本)。"""
    h = {'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json',
         'User-Agent': 'mwa-publish'}
    req = _rq.Request('https://api.github.com' + path, headers=h, method=method)
    try:
        with _rq.urlopen(req, timeout=60) as r:
            return r.status, r.read()[:200].decode('utf-8', 'replace')
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:200].decode('utf-8', 'replace')


def _purge_same_name(ver, want_names):
    """upload 前清掉同名旧附件（GitHub REST DELETE assets）。

    同名附件若线上是旧字节、`--clobber` 偶有覆盖不干净；这里先按名字列出 assets，
    名字在本次上传清单里、且字节不同的旧件直接 DELETE 掉，再让 upload 传新件。
    取不到发行版/令牌就跳过（上传阶段 --clobber 仍会兜底），不阻断发版。
    """
    try:
        tok = gh_token()
    except Exception:
        return
    h = {'Authorization': 'Bearer ' + tok, 'Accept': 'application/vnd.github+json',
         'User-Agent': 'mwa-publish'}
    try:
        rel = _api_json('https://api.github.com/repos/%s/%s/releases/tags/v%s'
                        % (OWNER, REPO, ver), h)
    except Exception:
        return
    for a in rel.get('assets', []):
        if a.get('name') in want_names and a.get('id'):
            st, _ = _gh_rest('DELETE', '/repos/%s/%s/releases/assets/%d'
                             % (OWNER, REPO, a['id']), tok)
            if st in (200, 204):
                print('   同名旧附件已删:', a.get('name'), a.get('size'), 'B')
            else:
                print('   删同名旧附件 %s 返回 %s（继续上传）' % (a.get('name'), st))


def sync_github(ver, assets, notes_file):
    """GitHub 侧走 gh.exe（本机登录态自己挑线路），不用 github.com 的 git 端口。

    两个写死的坑：`release create` 不能带 --target（tag 已推上去，带了报 already exists）；
    中文附件名会被 GitHub 削坏，所以 GitHub 那份一律用 ASCII 名（见 gh_assets）。
    """
    tag = 'v%s' % ver
    code, out = _gh(['release', 'create', tag, '--title', tag,
                     '--notes-file', str(notes_file), '--repo', GH_REPO])
    if code != 0 and 'already exists' not in out.lower():
        raise RuntimeError('gh release create 失败: %s' % out.strip()[-400:])
    if code != 0:
        print('   GitHub 发行版已存在, 继续补附件')
    want_names = {os.path.basename(str(a)) for a in assets}
    _purge_same_name(ver, want_names)
    code, out = _gh(['release', 'upload', tag, '--clobber'] +
                    [str(a) for a in assets] + ['--repo', GH_REPO])
    if code != 0:
        raise RuntimeError('gh release upload 失败: %s' % out.strip()[-400:])
    print('⑥ GitHub 代码 / tag / Release / 附件 已同步')


# 两条超时口径必须分开（2026-10-26 热点那边踩过，这里一起收掉，免得下次发版重演）：
#   SOCK_TMO  一条连接上「一次 recv」的上限 —— 链路断了 60 s 就该换下一条，
#             而不是像从前那样 900 s × 3 轮：那等于"卡死了也看不出来"。
#   DEADLINE  **总时长**预算 —— 本机走代理从 GitHub 取字节的实测速率只有 ~48 KB/s，
#             十几兆的附件本来就要五六分钟；慢不等于错，但到点必须收。
SOCK_TMO = int(os.environ.get('MWA_SOCK_TMO') or 60)
DEADLINE_SMALL = int(os.environ.get('MWA_DEADLINE_SMALL') or 180)
DEADLINE_BIG = int(os.environ.get('MWA_DEADLINE_BIG') or 900)


def _progress(label, got, expect, secs):
    print('  … %s 已取回 %.1f MB / %.1f MB（%.0f KB/s，用了 %d s）'
          % (label, got / 1048576.0, expect / 1048576.0 if expect else 0,
             got / max(secs, 1) / 1024.0, int(secs)))
    sys.stdout.flush()


def _download(url, timeout=SOCK_TMO, tries=2, headers=None, deadline=None, expect=0, label=''):
    """取一个 URL 的原始字节；失败重试，GitHub 那侧再借一次本地代理。

    边下边攒、每 15 秒报一次进度；超过 deadline **整条放弃**（重试只会再扔进去十分钟）。
    """
    relay = _relay_proxy()
    ops = [_rq.build_opener(_rq.ProxyHandler({}))]
    if relay and 'github' in url:
        ops.append(_rq.build_opener(_rq.ProxyHandler(
            {'http': relay, 'https': relay})))
    hd = {'User-Agent': 'mwa-verify', 'Accept-Encoding': 'identity'}
    hd.update(headers or {})
    for _ in range(tries):
        for op in ops:
            t0 = time.time()
            next_report = 15
            try:
                req = _rq.Request(url, headers=hd)
                with op.open(req, timeout=timeout) as r:
                    if r.status != 200:
                        continue
                    buf = bytearray()
                    over = False
                    while True:
                        # read1：有多少取多少。read(n) 会一直等到凑满 n 字节或连接关闭 ——
                        # 那种慢链路下 deadline 永远轮不到（2026-10-26 那 15 MB 就是这么空转到没人知道在跑还是卡死）。
                        chunk = (r.read1(262144) if hasattr(r, "read1") else r.read(262144))
                        if not chunk:
                            break
                        buf += chunk
                        spent = time.time() - t0
                        if spent >= next_report:
                            _progress(label or url.split('//')[-1][:52], len(buf), expect, spent)
                            next_report = spent + 15
                        if deadline and spent > deadline:
                            print('  x %s 总时长预算 %d s 用尽：只取回 %d B / 需要 %d B'
                                  '（这是链路慢，不代表包有问题；要等它就调大预算环境变量）'
                                  % (label or url.split('//')[-1][:52], deadline,
                                     len(buf), expect))
                            sys.stdout.flush()
                            over = True
                            break
                    if over:
                        return None
                    if buf:
                        return bytes(buf)
            except Exception:
                continue
        time.sleep(4)
    return None


def _api_json(url, headers=None, timeout=120):
    """GET api.github.com 并解析 JSON；遇 429 限流按指数退避重试。

    GitHub 限流返回 429（带 Retry-After 或 rate-limit 头），密集发版时容易撞上；
    这里统一退避重试，别让限流把验真/复核打断。tries 固定 4 次。
    """
    hd = headers or {'User-Agent': 'mwa-verify'}
    tries = 4
    for _attempt in range(tries):
        req = _rq.Request(url, headers=hd)
        try:
            with _rq.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read().decode('utf-8', 'replace'))
        except urllib.error.HTTPError as e:
            txt = e.read()[:300].decode('utf-8', 'replace')
            if (e.code == 429 or '429' in txt) and _attempt < tries - 1:
                wait = 20 * (_attempt + 1)
                print('   GitHub 限流(429)，等 %d 秒重试: %s' % (wait, url[:60]))
                time.sleep(wait)
                continue
            raise RuntimeError('API GET %s -> %s %s' % (url[:60], e.code, txt))


def _download_github_asset(ver, name):
    """从 GitHub 取回发行版附件内容（走 api.github.com 的 assets 接口）。

    2026-10-07 加：`github.com/.../releases/download/...` 在这条线路上时通时断，
    验真会误报「下载失败」。而 **api.github.com 一直通**，所以直连失败就改走
    API 的 assets 接口（Accept: application/octet-stream，拿到的是原始字节）。
    """
    try:
        tok = gh_token()
    except Exception:
        return None
    h = {'Authorization': 'Bearer ' + tok, 'Accept': 'application/vnd.github+json',
         'User-Agent': 'mwa-verify'}
    try:
        rel = _api_json('https://api.github.com/repos/%s/%s/releases/tags/v%s'
                        % (OWNER, REPO, ver), h)
        for a in rel.get('assets', []):
            if a.get('name') == name:
                hh = dict(h)
                hh['Accept'] = 'application/octet-stream'
                # 以前这里是 urlopen(timeout=1800) + r.read()：一次 recv 能等半小时，
                # 整条验真看不出在跑还是卡死。改走带进度与总预算的 _download。
                got = _download(a['url'], SOCK_TMO, 1, hh, deadline=DEADLINE_BIG,
                                expect=a.get('size') or 0,
                                label='GitHub %s（API 附件口）' % name)
                if got:
                    print('        （走 API 取回 %s）' % name)
                    return got
    except Exception:
        pass
    return None


def gh_token():
    """GitHub 令牌：优先环境变量，其次 gh CLI。"""
    t = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
    if t:
        return t.strip()
    # 2026-10-16: gh 的位置只认"环境变量 → 本机私有配置 → PATH"，公开脚本里不写本机路径。
    exe = os.environ.get('MWA_GH') or _CFG.get('gh') or shutil.which('gh')
    if exe and os.path.isfile(exe):
        import subprocess as _sp
        out = _sp.run([exe, 'auth', 'token'], capture_output=True)
        if out.returncode == 0:
            return out.stdout.decode('utf-8', 'replace').strip()
    raise RuntimeError('拿不到 GitHub 令牌：请设 GH_TOKEN（或 GITHUB_TOKEN）环境变量，'
                       '或让已登录的 gh 在 PATH 上')


def _github_assets_meta(ver):
    """取 GitHub 发行版附件的「文件名 -> (大小, sha256)」。

    GitHub 从 2024 起在 assets 里给 digest=sha256:...，有了它就不必把 12 MB
    从 30~40 KB/s 的链路上拽回来算指纹（2026-11-14 实测：整包下载 367 s，
    元数据比对不到 1 s）。取不到就返回空字典，回退成下载比对。
    """
    try:
        tok = gh_token()
    except Exception:
        return {}
    h = {'Authorization': 'Bearer ' + tok, 'Accept': 'application/vnd.github+json',
         'User-Agent': 'mwa-verify'}
    try:
        rel = _api_json('https://api.github.com/repos/%s/%s/releases/tags/v%s'
                        % (OWNER, REPO, ver), h)
    except Exception:
        return {}
    out = {}
    for a in rel.get('assets', []):
        d = (a.get('digest') or '').lower()
        if d.startswith('sha256:'):
            out[a.get('name')] = (a.get('size'), d.split(':', 1)[1])
    return out


def _pick_meta(meta, name, size):
    """在平台附件表里找本地文件对应项：先按名字，名字被平台改过就按大小唯一匹配。

    GitHub 会把中文名 ASCII 化成 `MSWallpaperAssistant-v2.5.0.exe`，本地名是
    `桌面壁纸.exe`，只按名字找必然 miss，进而回退下载、在断网时误报 FAIL。
    返回 (平台侧文件名, (大小, sha256))。
    """
    hit = meta.get(name)
    if hit and (hit[0] in (None, size)):
        return (name, hit)
    cands = [(k, v) for k, v in meta.items() if v[0] == size]
    if len(cands) == 1:
        return cands[0]
    return None


def verify(ver, assets, gh_assets=None):
    """逐个附件核对 SHA256：GitHub 优先用平台指纹，取不到才下载回来算。

    附件名可能与本地不一样（GitHub 会把中文名削成 ASCII/空名），先按名字、再按大小唯一匹配。
    """
    if gh_assets is None:
        gh_assets = assets
    ok = True
    gh_meta = _github_assets_meta(ver)
    targets = [('GitHub', os.path.basename(str(p)), str(p)) for p in gh_assets]
    for label, name, p in targets:
        size = os.path.getsize(p)
        want = hashlib.sha256(open(p, 'rb').read()).hexdigest()
        hit = _pick_meta(gh_meta, name, size)
        if hit:
            pname, (msize, msha) = hit
            same = msha == want and (msize in (None, size))
            ok = ok and same
            print('  [%s] %s %-32s %9d B  一致=%s（平台指纹比对，未下载）'
                  % ('PASS' if same else 'FAIL', label, pname, size, same))
            continue
        url = 'https://github.com/%s/%s/releases/download/v%s/%s' % (OWNER, REPO, ver,
                                                                     quote(name))
        data = _download(url, SOCK_TMO, 2,
                         deadline=DEADLINE_BIG if size > 2 * 1024 * 1024 else DEADLINE_SMALL,
                         expect=size, label='%s %s' % (label, name))
        if data is None:
            data = _download_github_asset(ver, name)   # github.com 不通时改走 API
        if data is None:
            print('  [FAIL] %s %-32s 下载失败' % (label, name))
            ok = False
            continue
        same = hashlib.sha256(data).hexdigest() == want
        ok = ok and same
        print('  [%s] %s %-32s %9d B  一致=%s'
              % ('PASS' if same else 'FAIL', label, name, len(data), same))
    print('   下载页: https://github.com/%s/%s/releases/tag/v%s' % (OWNER, REPO, ver))
    return ok


def _client_pubkey():
    """从**客户端源码** launcher.py 里解析出内置公钥 UPDATE_PUBKEY。

    故意解析源码、而不是在这里另写一份常量：签名的公钥和客户端内置的那把必须是同一把，
    解析得到就天然一致；哪天换了钥匙却忘了改客户端，这里当场就对不上。
    """
    src = (REPO_DIR / 'launcher.py').read_text(encoding='utf-8')
    m = re.search(r"""UPDATE_PUBKEY\s*=\s*['"]([0-9a-fA-F]{64})['"]""", src)
    if not m:
        sys.exit('从 launcher.py 里解析不到内置公钥 UPDATE_PUBKEY —— 拒绝发布')
    return m.group(1)


def _github_contents(path):
    """走 api.github.com 取仓库文件原文（raw 域名慢/不通时的兜底，0.5 秒级）。"""
    import base64
    try:
        tok = gh_token()
    except Exception:
        return None
    h = {'Authorization': 'Bearer ' + tok, 'Accept': 'application/vnd.github+json',
         'User-Agent': 'mwa-verify'}
    try:
        j = _api_json('https://api.github.com/repos/%s/%s/contents/%s?ref=%s'
                      % (OWNER, REPO, path, BRANCH), h, timeout=20)
    except Exception:
        return None
    c = (j.get('content') or '').replace('\n', '').replace('\r', '')
    if not c:
        return None
    try:
        return base64.b64decode(c)
    except Exception:
        return None


def verify_signature(vj, vsig):
    """回读两平台线上的 version.json + version.json.sig，用客户端内置公钥**真验一遍**。

    这一步验的是"用户点检查更新时到底能不能过"：
      · 线上 version.json 的原始字节 → 与本地发布的那份一致；
      · 同目录的 version.json.sig 拿得到、且用客户端内置公钥验得过。
    任何一条不过就返回 False（发版算失败，别让用户自己发现升级通道是断的）。
    """
    print('⑦ 线上升级源验签（用客户端内置公钥，GitHub 一次）:')
    if str(REPO_DIR) not in sys.path:
        sys.path.insert(0, str(REPO_DIR))
    try:
        import _ed25519
    except Exception as e:
        sys.exit('加载 _ed25519.py 失败(%s) —— 拒绝发布（没法自证签名可用）' % type(e).__name__)
    pub = bytes.fromhex(_client_pubkey())
    local_raw = open(str(vj), 'rb').read()
    ok = True
    # 客户端读的就是 GitHub 的 raw 地址；带时间戳参数是防 CDN 回半新半旧的缓存。
    bust = int(time.time())
    gh_base = 'https://raw.githubusercontent.com/%s/%s/%s' % (OWNER, REPO, BRANCH)

    def _gh_get(f):
        """GitHub 线上文件：直接走 api.github.com（0.5 秒级），API 不通才回退 raw 域名。

        2026-11-16 实测：raw.githubusercontent.com 在这条线路上时而 20 秒才出结果，
        一轮验真光等它就 20 秒；api.github.com 同一时刻 0.5 秒回，内容是同一份。
        raw 是否可达另有一条 3 秒探活提示（只提示，不判 FAIL）。
        """
        data = _github_contents(f)
        if data is None:
            data = _download('%s/%s?v=%d' % (gh_base, f, bust), 10, 1,
                             label='GitHub %s(回退 raw)' % f)
        return data

    # raw 域名单独探一次（最多 3 秒），只作提示：客户端升级读的就是它
    _rt = time.time()
    _rp = _https_alive('raw.githubusercontent.com')
    print('  … GitHub raw 域名探活：%s（%.1f s，只提示不改结论）'
          % ('通' if _rp else '3 秒未通，客户端升级可能取不到', time.time() - _rt))

    for label, mk in (('GitHub', _gh_get),):
        # 两个小文件（清单 806 B / 签名 128 B）：单次 recv 60 s、总预算 120 s、最多 3 轮，
        # 最坏三分钟出头就出结论，不会再把整轮验真拖到看不看在跑还是卡住。
        raw = mk('version.json')
        sig_raw = mk('version.json.sig')
        if raw is None or sig_raw is None:
            print('  [FAIL] %s 线上 version.json / .sig 取不到（GitHub 必须能取到）' % label)
            ok = False
            continue
        same_bytes = raw == local_raw
        sig_txt = sig_raw.decode('utf-8', 'replace').strip()
        sig_ok = False
        if re.fullmatch(r'[0-9a-fA-F]{128}', sig_txt):
            try:
                sig_ok = bool(_ed25519.checkvalid(bytes.fromhex(sig_txt), raw, pub))
            except Exception:
                sig_ok = False
        ok = ok and same_bytes and sig_ok
        print('  [%s] %s 线上 version.json 与本地一致=%s，Ed25519 验签=%s（公钥 %s…）'
              % ('PASS' if (same_bytes and sig_ok) else 'FAIL', label, same_bytes, sig_ok,
                 pub.hex()[:16]))
    return ok


# ---------- 入口 ----------
def cmd_release(ver, skip_build=False, notes_file=None):
    # 第 0 项：先问清这次能不能上传（3~5 秒），不通立刻停，不往下跑十几步再返工
    if '--skip-doctor' not in sys.argv:
        if not cmd_doctor():
            sys.exit('❌ 第 0 项通道体检没过：先修上面的项再发版'
                     '（急用可 --skip-doctor，但要在 logs\\ 写明原因）')
    t0 = time.time()
    zip_name = ZIP_TPL % ver
    zip_path = REPO_DIR / zip_name

    notes = None
    if notes_file:
        p = Path(notes_file)
        if not p.exists():
            sys.exit('--notes 指定的文件不存在: %s' % p)
        notes = p.read_text(encoding='utf-8')
    else:
        notes = extract_notes(ver)
    if not notes:
        sys.exit('docs/CHANGELOG.md 里找不到 v%s 的条目 —— 直接发会得到一个空白的发行页。\n'
                 '请先在 docs/CHANGELOG.md 里补上该版本段落（`## v%s — 日期`）并用它自动生成，'
                 '或用 --notes <文件> 指定发布说明。' % (ver, ver))
    print('   发布说明: %d 字' % len(notes))

    bump_version(ver)
    if not skip_build:
        out = run([PY, 'build-exe.py', '--release'])
        print('② 打包完成:', out.strip().splitlines()[-1] if out.strip() else '')
    if not zip_path.exists():
        sys.exit('找不到 %s, 打包可能失败了' % zip_path)
    print('   zip =', zip_path, zip_path.stat().st_size, 'B')

    # ③ 升级源：必须和本次 exe 同一份，否则自动升级会校验不过
    plain_exe = REPO_DIR / EXE_NAME
    tagged_exe = REPO_DIR / ('%s-v%s.exe' % (EXE_STEM, ver))
    if not skip_build and not plain_exe.exists():
        sys.exit('找不到 %s' % plain_exe)
    vj, vsig = make_version_json()
    # 带版本号那份 exe 与固定名同字节，README 也没有任何地方引用它 ——
    # 只在两份内容真的不同时才补挂，避免白传 26 MB。
    assets = [zip_path, vj, vsig] + ([plain_exe] if plain_exe.exists() else [])
    if tagged_exe.exists() and not _same_sha(tagged_exe, plain_exe):
        assets.append(tagged_exe)   # 万一某次真的不一样，仍要把两份都挂上
        print('   ! 带版本号 exe 与固定名 exe 内容不同，两份都上传（别让用户下到旧包）')

    # 2026-10-05 踩的坑: GitHub 会把中文附件名里的汉字**直接削掉** ——
    #   微软壁纸助手.exe      -> default.exe
    #   微软壁纸助手-v2.0.8.exe -> -v2.0.8.exe
    # 文件其实传上去了, 但名字改坏, 按原名下载必然 404。所以给 GitHub 单独准备一份 ASCII 名的 exe。
    ascii_exe = REPO_DIR / ('MSWallpaperAssistant-v%s.exe' % ver)
    if plain_exe.exists():
        shutil.copy2(str(plain_exe), str(ascii_exe))
    gh_assets = [zip_path, vj, vsig] + ([ascii_exe] if ascii_exe.exists() else [])

    # README 必须在**提交之前**改好, 否则本次推送里 README 还是旧版本号 ——
    # 2026-10-05 就是这么把「点这里下载 v2.0.7」推到线上的。
    update_readme(ver, commit=False)

    # ── 发版铁律：先自检、后发布（2026-10-08 用户要求「以后都这样」）──────
    # 位置：README 已改好、version.json 已生成之后，提交推送之前 ——
    # 这样自检校验的就是"即将推上去的那一份"。
    # 要跳过必须显式 --skip-preflight（只给线上事故紧急回滚用）。
    if '--skip-preflight' in sys.argv:
        print('   ⚠ 已显式跳过发版前自检（--skip-preflight）—— 请在 logs\\ 里写明原因')
    else:
        # 2026-10-10: 自检脚本两种布局都找 —— 工作区布局在 <项目>\tools\，
        # 仓库布局在 <仓库>\tools\。此前只认前者，别的机器照 README 跑
        # 会直接"找不到自检脚本"中止（fail-closed 是对的，但等于这套流程只在一台机器上可用）。
        pf = REPO_DIR.parent / 'tools' / 'preflight_release.py'
        if not pf.exists():
            pf = REPO_DIR / 'tools' / 'preflight_release.py'
        if not pf.exists():
            sys.exit('找不到发版前自检脚本（找过 %s 和 %s）—— 不许发布（铁律）'
                     % (REPO_DIR.parent / 'tools' / 'preflight_release.py',
                        REPO_DIR / 'tools' / 'preflight_release.py'))
        print('   ── 发版前自检（必须全绿）──')
        # 发版时带 --no-links：README 的下载链接指向"本次要发的 vX.Y.Z"，发版前它必然 404
        # （还没传附件），属于预期、不是死链；其余链接与徽章在每次改 README 后单独跑自检即可。
        r = subprocess.run([PY, str(pf), '--no-links'], cwd=str(pf.parent.parent))
        if r.returncode != 0:
            sys.exit('❌ 发版前自检未通过，已中止发布。修好再发（或 --skip-preflight 紧急跳过）')
        print('   ✅ 自检全绿，继续发布')

    # ── 发版顺序是铁律：tag 先推 → GitHub 建发行版传附件 → 附件验真 →
    #    **main 最后推**（升级源就是 main 上那份 version.json，它一上线全体老用户立刻
    #    开始提示升级，那时附件必须已经躺好，否则用户点了个 404）。
    git_commit_and_tag(ver, ['docs/CHANGELOG.md', 'README.md', 'core.ps1', 'menu.ps1',
                             'launcher.py', 'build-exe.py', '_ed25519.py', '使用说明.txt',
                             'version.json', 'version.json.sig',
                             'panel.html', 'tools/embed_panel.py', 'tools/sign_version_json.py',
                             'tools/drill_upgrade.ps1', 'tools/drill_launcher_update.ps1',
                             'tools/preflight_release.py', 'tools/publish.py',
                             'tools/downloads_badge.py', 'tools/make_version_json.py',
                             'docs/ARCHITECTURE.md', 'docs/CODE_OF_CONDUCT.md',
                             'docs/README_EN.md', 'docs/REVIEWING.md',
                             'docs/index.html', 'docs/demo/index.html',
                             'AGENTS.md', 'TASKS.md', 'requirements.txt',
                             '.github/workflows/build.yml', '.github/workflows/release.yml',
                             '.release/config.json'])
    nf = notes_file or (REPO_DIR / '_notes.md')
    if not notes_file:
        nf.write_text(notes or 'v%s' % ver, encoding='utf-8')
    sync_github(ver, gh_assets, nf)
    if not notes_file and nf.exists():
        nf.unlink()
    ok = verify(ver, assets, gh_assets)
    if not ok:
        sys.exit('❌ 附件验真没通过 —— main 先不推，线上仍是上一版；按上面的 [FAIL] 补齐后重跑。')
    git_push_branch()
    # 验签必须放在 main 推完之后：推之前线上那份 version.json 还是上一版的字节，
    # 拿它跟本次发布的本地文件比必然"不一致"，那是假警报。
    ok = verify_signature(vj, vsig) and ok
    # 2026-10-05 修: 这一步原来只是打印, 验真失败也照样 exit 0 —— 于是
    # 「GitHub 附件没换成新的」被当成发布成功。现在验真不过就是**失败退出**。
    if not ok:
        sys.exit('❌ 验真失败: GitHub 下载回来的东西和本地对不上, 这次发布不算成功, '
                 '请按上面的 [FAIL] 逐条补齐后重跑。')
    print('全部完成, 用时 %.0f 秒, 验真通过' % (time.time() - t0))


def cmd_doctor():
    """发版第 0 项：3~5 秒先问清「这次能不能上传」，不通就别往下跑。

    2026-11-16 定：以前发版中途卡在「找不到 powershell / git / gh 没登录 / 令牌没设」
    这类环境问题上，重试五六轮；这些全都能在动手前 5 秒内测出来。
    """
    import socket
    rows = []

    def chk(label, fn, fix='', fatal=True):
        try:
            rows.append((True, label, fn(), fix, fatal))
        except Exception as e:
            rows.append((False, label, '%s: %s' % (type(e).__name__, str(e)[:110]), fix, fatal))

    def _git_ver():
        code, out = _git_raw(['git', '--version'])
        if code != 0 or not out.strip():
            raise RuntimeError('git 调不起来（本机配置里 git_dir 没指对？）')
        return out.strip().splitlines()[0]

    def _gh():
        exe = GH
        if not exe or not os.path.isfile(exe):
            raise RuntimeError('gh 找不到')
        return gh_token()[:8] + '…（%s）' % os.path.basename(exe)

    def _key():
        p = os.environ.get('MWA_ED25519_KEY') or r'F:\Harness\secrets\raw\mwa-ed25519.key'
        if not os.path.isfile(p):
            raise RuntimeError('签名钥匙不在 %s' % p)
        return '就位'

    def _gh_api():
        tok = gh_token()
        j = _api_json('https://api.github.com/rate_limit',
                      {'Authorization': 'Bearer ' + tok, 'User-Agent': 'mwa-doctor'}, timeout=15)
        core = j['resources']['core']
        return '剩余 %d/%d 次' % (core['remaining'], core['limit'])

    def _gh_tcp():
        if not _https_alive('github.com'):
            raise RuntimeError('github.com 3 秒内没响应 → 走 api.github.com（不用手改）')
        return '通（git 直连可用）'

    chk('git', _git_ver, '把 PortableGit 的 mingw64\\bin 写进 ~/.mwa-publish.json 的 git_dir')
    chk('gh + 令牌', _gh, '在 ~/.mwa-publish.json 填 gh 绝对路径，并 gh auth login')
    chk('签名钥匙', _key, '把 Ed25519 私钥放回 secrets\\raw\\mwa-ed25519.key，或设 MWA_ED25519_KEY')
    chk('api.github.com', _gh_api, '检查网络 / 令牌权限')
    chk('github.com:443', _gh_tcp, '不通没关系：脚本自动走 api.github.com', fatal=False)

    print('=== 发版通道体检（第 0 项）===')
    bad = 0
    for ok, label, info, fix, fatal in rows:
        tag = 'OK ' if ok else ('提示' if not fatal else 'FAIL')
        print('  [%4s] %-16s %s' % (tag, label, info))
        if not ok:
            if fatal:
                bad += 1
            if fix:
                print('        修法: %s' % fix)
    if bad:
        print('结论: %d 项不通 —— 先修上面的，别往下跑（这一步只为省掉中途返工）' % bad)
        return False
    print('结论: 全部通 —— 可以发布')
    return True


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    a = sys.argv[1]
    if a == 'doctor':
        sys.exit(0 if cmd_doctor() else 1)
    elif a == 'verify' and len(sys.argv) > 2:
        cmd_verify(sys.argv[2])
    elif a == 'release' and len(sys.argv) > 2:
        ver = sys.argv[2]
        cmd_release(ver,
                    skip_build='--skip-build' in sys.argv,
                    notes_file=(sys.argv[sys.argv.index('--notes') + 1]
                                if '--notes' in sys.argv else None))
    else:
        print(__doc__)


def cmd_verify(ver):
    """只读验真：什么都不发，把线上那一版按用户的口径重跑一遍。

    什么时候用它：① 发完版想确认"用户点检查更新真的能过"；② 用户报"升级失败"时，
    先在这里分清是通道断了还是包坏了，别一上来就改代码发新版。
    """
    vj = REPO_DIR / 'version.json'
    vsig = REPO_DIR / 'version.json.sig'
    if not vj.is_file() or not vsig.is_file():
        sys.exit('找不到本地 %s / %s —— 先确认仓库里的升级源是不是这一版' % (vj, vsig))
    d = json.loads(vj.read_text(encoding='utf-8-sig'))
    exe_info = d.get('launcher') or d.get('exe') or {}
    print('① 清单: version=%s  size=%s  sha256=%s…'
          % (d.get('version'), exe_info.get('size'), (exe_info.get('sha256') or '')[:16]))
    if str(d.get('version')) != str(ver):
        print('⚠ 本地 version.json 是 v%s，你要验的是 v%s —— 清单可能对不上号'
              % (d.get('version'), ver))
    zip_path = REPO_DIR / (ZIP_TPL % ver)
    ascii_exe = REPO_DIR / ('MSWallpaperAssistant-v%s.exe' % ver)
    # 只验"GitHub 上真的挂了的那几个"。带版本号的 exe（桌面壁纸-vX.Y.Z.exe）是打包中间产物、
    # 并不作为附件发布，列进来只会得到一个假 FAIL。
    gh_assets = [p for p in (zip_path, ascii_exe, vj, vsig) if p.exists()]
    print('② 附件验真（GitHub 一次）:')
    ok = verify(ver, None, gh_assets)
    ok = verify_signature(vj, vsig) and ok
    print('验真结果:', 'PASS' if ok else 'FAIL')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
