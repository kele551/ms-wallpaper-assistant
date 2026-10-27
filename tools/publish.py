# -*- coding: utf-8 -*-
"""
壁纸助手 —— 一键发布流水线（GitCode 主源 + GitHub 镜像）

依赖: 一枚 GitCode 私人令牌(存一次, 之后长期复用)。HTTP 层只用 Python 标准库 ——
本机没装第三方 HTTP 库, 以前那版依赖它, 结果在这台机器上整条流水线跑不起来,
只能临时手搓脚本发版（2026-10-26 就是这个坑）。
GitHub 侧走本机登录态的 gh.exe（它自己会挑线路，比手搓 REST 稳）。

2026-10-26 换目标: 老的那家已停更、客户端也不再从它取任何地址，所以发布目标定为
GitCode（国内主源）+ GitHub（国外镜像）。AtomGit 不用推 —— 它按分钟级自动镜像 GitHub。

用法:
    python tools/publish.py set-token <令牌>         # 存令牌并验证
    python tools/publish.py whoami                   # 看令牌是否有效
    python tools/publish.py release 2.4.2            # 只发 GitCode
    python tools/publish.py release 2.4.2 --github   # 双平台(用户要求两个都发)
    python tools/publish.py release 2.4.2 --skip-build   # 已有 exe, 只做发布
    python tools/publish.py release 2.4.2 --notes 文件.md # 指定发布说明
    python tools/publish.py verify 2.4.2             # 只读：线上验真，什么都不发

release 子命令依次做:
    ① 改三处版本号 (core.ps1 / menu.ps1 / launcher.py)
    ② 打包 (build-exe.py --release)  ->  exe / 带版本号 exe / ASCII 名 zip
    ③ 生成升级源 version.json (必须与本次 exe 同一份, 否则老客户端校验不过)
    ③+ 提交 + 打 tag + **只推 tag**（main 留到最后，见下）
    ④ GitCode 建发行版 + 上传附件(zip / exe / version.json / .sig)
    ⑤ README 下载链接指向新版
    ⑥ 同步 GitHub (代码 + tag + Release + 附件, 走 gh.exe)
    ⑦ 验真: 每个附件从两个平台下载回来比对 SHA256
    ⑧ **main 最后推** —— 升级源就是 main 上那份 version.json，它一上线全体老用户
       立刻开始提示升级，那时附件必须已经躺好；然后回读线上 version.json + .sig 真验一遍签
"""
import os
import re
import sys
import json
import time
import shutil
import zipfile
import io
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
GC_API = 'https://gitcode.com/api/v5'
GC_WEB = 'https://gitcode.com'
GH_REPO = '%s/%s' % (OWNER, REPO)
# 2026-10-26: 发布目标换成 GitCode(国内主源) + GitHub(国外镜像)。
# 老的那家已停更，客户端也不再从它取任何地址；工具里留着一个会写字节的主源，
# 迟早发出"线上取不到"的版本，所以整条链路一起换掉。
REMOTES = ('origin', 'github')          # 本仓库 origin 就是 GitCode
# ---- 本机私有配置（可选，永不进仓库）----------------------------------------
# 公开仓库里不写任何维护者本机路径。本机要用的解释器 / git / 推送脚本 / gh / 令牌位置，
# 一律按：① 环境变量 → ② 本机私有配置 ~/.mwa-publish.json → ③ 与机器无关的默认值。
# 私有配置文件示例（放在用户主目录，文件名前面有个点）：
#   {"python": "C:\\\\Python313\\\\python.exe", "git_dir": "C:\\\\Program Files\\\\Git\\\\mingw64\\\\bin",
#    "gh": "F:\\\\Harness\\\\toolchain\\\\gh\\\\bin\\\\gh.exe", "git_proxy": "http://127.0.0.1:8787",
#    "token_file": "D:\\\\private\\\\gitcode_token"}
_CFG_PATH = Path.home() / '.mwa-publish.json'
_CFG = {}
if _CFG_PATH.is_file():
    try:
        _CFG = json.loads(_CFG_PATH.read_text(encoding='utf-8'))
    except Exception as _e:
        print('警告: %s 解析失败(%s)，按"没有本机配置"继续' % (_CFG_PATH, _e), file=sys.stderr)

_ENV_TOKEN_FILE = os.environ.get('GITCODE_TOKEN_FILE') or _CFG.get('token_file')
# 都没给就落到仓库内的 .gitcode_token（已 gitignore）；也可以直接用环境变量 GITCODE_TOKEN 传令牌本身
TOKEN_CANDIDATES = [_ENV_TOKEN_FILE] if _ENV_TOKEN_FILE else [str(REPO_DIR / '.gitcode_token')]
TOKEN_FILE = Path(TOKEN_CANDIDATES[0])
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
    for _c in (r'C:\Program Files\Git\cmd', r'C:\Program Files (x86)\Git\cmd'):
        if Path(_c, 'git.exe').is_file():
            return _c.replace('\\', '/')
    return ''


GIT_EXEC_PATH = _find_git_dir()
# 有绝对路径就用绝对路径: 有的执行环境按名字找不到 git(WinError 2)
GIT_EXE = (GIT_EXEC_PATH + '/git.exe') if GIT_EXEC_PATH else 'git'
# GitHub 侧走本机登录态的 gh.exe(2026-10-26 起): 它自己会挑直连/端口, 比手搓 REST 稳,
# 也不依赖那个从没入库过的 tools/github_push.py。
GH = os.environ.get('MWA_GH') or _CFG.get('gh') or shutil.which('gh') or 'gh'
# GitHub 的 git 端口在这台机器上时通时断，失败时借本地代理重试（只在命令行 -c 上带，不改 config）
GIT_PROXY = os.environ.get('MWA_GIT_PROXY') or _CFG.get('git_proxy') or 'http://127.0.0.1:8787'
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
]


# ---------- 令牌 ----------
def save_token(tok):
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    TOKEN_FILE.write_text(tok.strip(), encoding='utf-8')
    print('令牌已存到', TOKEN_FILE)


def load_token():
    t = os.environ.get('GITCODE_TOKEN')
    if t:
        return t.strip()
    for c in TOKEN_CANDIDATES:
        p = Path(c)
        if p.exists():
            return p.read_text(encoding='utf-8').strip()
    return None


def api(method, path, token, payload=None, timeout=120, extra=None, headers=None):
    """GitCode v5 接口：令牌走 access_token 查询参数；HTTP 层只用标准库（本机没装第三方库）。

    2026-10-26 实测：GitCode 建发行版的响应里**没有 id 字段**，所以一切都按 tag 寻址；
    它也没有老平台那套 attach_files 接口（一律 404/405），附件要走 upload_url + PUT。
    """
    p = {'access_token': token}
    p.update(extra or {})
    url = GC_API + path + '?' + urllib.parse.urlencode(p)
    hd = {'User-Agent': 'mwa-publish'}
    hd.update(headers or {})
    data = None
    if payload is not None:
        data = json.dumps(payload).encode('utf-8')
        hd['Content-Type'] = 'application/json'
    req = _rq.Request(url, data=data, headers=hd, method=method)
    try:
        with _rq.urlopen(req, timeout=timeout) as r:
            body = r.read()
    except urllib.error.HTTPError as e:
        raise RuntimeError('API %s %s -> %s %s'
                           % (method, path, e.code, e.read()[:300].decode('utf-8', 'replace')))
    return json.loads(body.decode('utf-8', 'replace')) if body.strip() else {}


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


def _git_raw(args):
    """跑一条 git，返回 (退出码, 输出)。推送成败只信退出码 + 远端 sha。"""
    e = os.environ.copy()
    if GIT_EXEC_PATH:
        e['GIT_EXEC_PATH'] = GIT_EXEC_PATH
        e['PATH'] = GIT_EXEC_PATH.replace('/', os.sep) + os.pathsep + e.get('PATH', '')
    args = list(args)
    if args and args[0] == 'git':
        args[0] = GIT_EXE.replace('/', os.sep)
    print('   $', ' '.join(args))
    r = subprocess.run(args, cwd=str(REPO_DIR), env=e,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.returncode, r.stdout.decode('utf-8', 'replace')


def _push(remote, ref):
    """推一个 ref；GitHub 那条线本机时不时裸连不上，失败就带一次本地代理重试。

    代理只在"这次推送"上用 -c 传进去（不落 git config）。推完一律 ls-remote 复核远端 sha：
    退出码只说明"命令没崩"，说明不了"远端变了"（管道还会把真实状态吞掉，踩过）。
    """
    if remote not in _git_raw(['git', 'remote'])[1]:
        print('   跳过 %s：本仓库没有这个 remote' % remote)
        return False
    want = _git_raw(['git', 'rev-parse', 'HEAD' if ref == BRANCH else ref])[1].split()[-1]
    code, out = _git_raw(['git', 'push', remote, ref])
    if code != 0:
        print('   裸推失败(%s)，带本地代理 %s 再试一次' % (out.strip()[-160:], GIT_PROXY))
        code, out = _git_raw(['git', '-c', 'http.https://github.com/.proxy=' + GIT_PROXY,
                              'push', remote, ref])
        if code != 0:
            print('   带代理也失败:', out.strip()[-200:])
    got = (_git_raw(['git', 'ls-remote', remote, ref])[1].split() or ['', ''])[1:2]
    if got and got[0] == want:
        print('   pushed %s -> %s（远端 sha %s… 与本地一致）' % (ref, remote, want[:10]))
        return True
    raise RuntimeError('推送 %s -> %s 没生效：本地 %s，远端 %s'
                       % (ref, remote, want[:10], (got or ['(取不到)'])[0][:10]))


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
    for remote in REMOTES:
        _push(remote, tag)
    print('③ 代码已提交、tag %s 已推 %s（main 还没推 —— 附件就位后再推，顺序是铁律）'
          % (tag, '+'.join(REMOTES)))


def git_push_branch():
    """附件验真通过之后，才让升级源在两个平台上生效。"""
    for remote in REMOTES:
        _push(remote, BRANCH)
    print('③+ main 已推 %s —— 此刻起线上才开始提示升级' % '+'.join(REMOTES))


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
def _gc_get_release(tag, token):
    """按 tag 取发行版。GitCode 的响应里**没有 id 字段**，所以一切按 tag 寻址。"""
    try:
        return api('GET', '/repos/%s/%s/releases/tags/%s' % (OWNER, REPO, quote(tag)), token)
    except Exception:
        return None


def gitcode_release(ver, token, assets, notes):
    """GitCode：建发行版 + 逐个附件走"取上传地址 → PUT 原始字节"两步（2026-10-26 实测）。

    老平台那套 attach_files 接口在 GitCode 一律 404/405，别再试。
    同名附件：大小一致就当已传好跳过；**大小不同必须人工到网页上删掉旧的** ——
    GitCode 没有可靠的删除附件接口，宁可停下来也不能让线上留两份不同字节的同名包。
    """
    tag = 'v%s' % ver
    rel = _gc_get_release(tag, token)
    if rel and rel.get('tag_name') == tag:
        print('④ GitCode 发行版已存在:', tag, '| 附件', len(rel.get('assets') or []), '个')
    else:
        rel = api('POST', '/repos/%s/%s/releases' % (OWNER, REPO), token, payload={
            'tag_name': tag,
            'name': tag,
            'body': notes or ('v%s' % ver),
            'target_commitish': BRANCH,
            'prerelease': False,
        })
        if not rel or not rel.get('tag_name'):
            raise RuntimeError('GitCode 建发行版失败: %s' % json.dumps(rel, ensure_ascii=False)[:300])
        print('④ GitCode 发行版已创建:', rel.get('tag_name'))
    have = {a.get('name'): a for a in ((_gc_get_release(tag, token) or {}).get('assets') or [])}
    for path in assets:
        p = str(path)
        name = os.path.basename(p)
        size = os.path.getsize(p)
        old = have.get(name)
        if old and old.get('size') == size:
            print('   附件已在（同名同大小，跳过）:', name, size, 'B')
            continue
        if old:
            raise RuntimeError('GitCode 上同名附件字节不同（线上 %s B / 本地 %d B）：%s\n'
                               '请到 %s/%s/%s/releases/tag/%s 删掉旧附件再重发。'
                               % (old.get('size'), size, name, GC_WEB, OWNER, REPO, tag))
        j = api('GET', '/repos/%s/%s/releases/%s/upload_url' % (OWNER, REPO, quote(tag)),
                token, extra={'file_name': name}, timeout=120)
        up = (j or {}).get('url') or ((j or {}).get('data') or {}).get('url')
        hd = (j or {}).get('headers') or ((j or {}).get('data') or {}).get('headers') or {}
        if not up:
            raise RuntimeError('拿不到 GitCode 上传地址: %s' % json.dumps(j, ensure_ascii=False)[:200])
        data = io.open(p, 'rb').read()
        h = dict(hd)
        h['Content-Length'] = str(len(data))
        req = _rq.Request(up, data=data, headers=h, method='PUT')
        with _rq.urlopen(req, timeout=1800) as r:
            if r.status not in (200, 201, 204):
                raise RuntimeError('附件 PUT 失败 %s -> %s' % (name, r.status))
        print('   附件已上传:', name, size, 'B')
    chk = _gc_get_release(tag, token) or {}
    names = [a.get('name') for a in (chk.get('assets') or [])]
    missing = [os.path.basename(str(p)) for p in assets if os.path.basename(str(p)) not in names]
    if missing:
        raise RuntimeError('GitCode 回读缺少附件（平台没登记上）: %s' % ', '.join(missing))
    print('   下载页:', '%s/%s/%s/releases/tag/%s' % (GC_WEB, OWNER, REPO, tag))


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
    r = subprocess.run(cmd, cwd=str(REPO_DIR), capture_output=True, text=True,
                       encoding='utf-8', errors='replace', timeout=1800)
    return r.returncode, ((r.stdout or '') + (r.stderr or ''))


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
    ops = [_rq.build_opener(_rq.ProxyHandler({}))]
    if GIT_PROXY and 'github' in url:
        ops.append(_rq.build_opener(_rq.ProxyHandler(
            {'http': GIT_PROXY, 'https': GIT_PROXY})))
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
    req = _rq.Request(url, headers=headers or {'User-Agent': 'mwa-verify'})
    with _rq.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode('utf-8', 'replace'))


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


def verify(ver, assets, gh_assets=None):
    """逐个附件从 GitCode / GitHub 下载回来比对 SHA256（中文名要 percent-encode）。

    两平台的**附件名可以不一样**（GitHub 会把中文名削成 ASCII/空名），
    所以两边分别按各自的名字下载：GitCode 用 assets，GitHub 用 gh_assets。
    """
    if gh_assets is None:
        gh_assets = assets
    ok = True
    targets = []
    for p in assets:
        targets.append(('GitCode', os.path.basename(str(p)), str(p), True))
    for p in gh_assets:
        targets.append(('GitHub', os.path.basename(str(p)), str(p), False))
    for label, name, p, is_gc in targets:
        size = os.path.getsize(p)
        want = hashlib.sha256(open(p, 'rb').read()).hexdigest()
        if is_gc:
            url = '%s/%s/%s/releases/download/v%s/%s' % (GC_WEB, OWNER, REPO, ver,
                                                         quote(name))
        else:
            url = 'https://github.com/%s/%s/releases/download/v%s/%s' % (OWNER, REPO, ver,
                                                                         quote(name))
        data = _download(url, SOCK_TMO, 1 if not is_gc else 2,
                         deadline=DEADLINE_BIG if size > 2 * 1024 * 1024 else DEADLINE_SMALL,
                         expect=size, label='%s %s' % (label, name))
        if data is None and not is_gc:
            data = _download_github_asset(ver, name)   # github.com 不通时改走 API
        if data is None:
            print('  [FAIL] %s %-32s 下载失败' % (label, name))
            ok = False
            continue
        same = hashlib.sha256(data).hexdigest() == want
        ok = ok and same
        print('  [%s] %s %-32s %9d B  一致=%s'
              % ('PASS' if same else 'FAIL', label, name, len(data), same))
    print('   下载页:', '%s/%s/%s/releases/tag/v%s' % (GC_WEB, OWNER, REPO, ver))
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


def verify_signature(vj, vsig):
    """回读两平台线上的 version.json + version.json.sig，用客户端内置公钥**真验一遍**。

    这一步验的是"用户点检查更新时到底能不能过"：
      · 线上 version.json 的原始字节 → 与本地发布的那份一致；
      · 同目录的 version.json.sig 拿得到、且用客户端内置公钥验得过。
    任何一条不过就返回 False（发版算失败，别让用户自己发现升级通道是断的）。
    """
    print('⑧ 线上升级源验签（用客户端内置公钥，两个平台各一次）:')
    if str(REPO_DIR) not in sys.path:
        sys.path.insert(0, str(REPO_DIR))
    try:
        import _ed25519
    except Exception as e:
        sys.exit('加载 _ed25519.py 失败(%s) —— 拒绝发布（没法自证签名可用）' % type(e).__name__)
    pub = bytes.fromhex(_client_pubkey())
    local_raw = open(str(vj), 'rb').read()
    ok = True
    # 客户端读的就是这两个地址：GitCode 的 raw 走 API（它没有老平台那种 /raw/分支 直链），
    # GitHub 用 raw.githubusercontent.com。带时间戳参数是防 CDN 回半新半旧的缓存。
    bust = int(time.time())
    gc_base = GC_API + '/repos/%s/%s/raw' % (OWNER, REPO)
    gh_base = 'https://raw.githubusercontent.com/%s/%s/%s' % (OWNER, REPO, BRANCH)
    for label, mk in (
            ('GitCode', lambda f: '%s/%s?ref=%s&t=%d' % (gc_base, f, BRANCH, bust)),
            ('GitHub', lambda f: '%s/%s?v=%d' % (gh_base, f, bust))):
        # 两个小文件（清单 806 B / 签名 128 B）：单次 recv 60 s、总预算 120 s、最多 3 轮，
        # 最坏三分钟出头就出结论，不会再把整轮验真拖到看不看在跑还是卡住。
        raw = _download(mk('version.json'), SOCK_TMO, 3, deadline=120,
                        label='%s version.json' % label)
        sig_raw = _download(mk('version.json.sig'), SOCK_TMO, 3, deadline=120,
                            label='%s version.json.sig' % label)
        if raw is None or sig_raw is None:
            print('  [FAIL] %s 线上 version.json / .sig 取不到（GitCode 与 GitHub 都必须能取到）' % label)
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
def cmd_set_token(tok):
    save_token(tok)
    u = api('GET', '/user', tok.strip())
    print('令牌有效, 用户 =', u.get('login') or u.get('name'))


def cmd_release(ver, skip_build=False, notes_file=None, with_github=False):
    token = load_token()
    if not token:
        sys.exit('没有令牌, 先跑: python tools/publish.py set-token <令牌>')
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
    assets = [zip_path, vj, vsig] + [p for p in (plain_exe, tagged_exe) if p.exists()]

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

    # 2026-10-23: 网页控制台上线, 新增/改动的文件都必须列进来 ——
    # 这个清单是**固定**的(不是 git add -A), 漏一个就不会被提交, 别人克隆下来是残缺的。
    # ── 发版顺序是铁律（2026-10-26 定）：tag 先推 → 两平台建发行版传附件 → 附件验真 →
    #    **main 最后推**（升级源就是 main 上那份 version.json，它一上线全体老用户立刻
    #    开始提示升级，那时附件必须已经躺好，否则用户点了个 404）。
    git_commit_and_tag(ver, ['docs/CHANGELOG.md', 'README.md', 'core.ps1', 'menu.ps1',
                             'launcher.py', 'build-exe.py', '_ed25519.py', '使用说明.txt',
                             'version.json', 'version.json.sig',
                             'panel.html', 'tools/embed_panel.py', 'tools/sign_version_json.py',
                             'tools/drill_upgrade.ps1', 'tools/drill_launcher_update.ps1',
                             'tools/preflight_release.py', 'tools/publish.py',
                             'docs/ARCHITECTURE.md', 'docs/CODE_OF_CONDUCT.md',
                             'docs/README_EN.md', 'docs/index.html', 'docs/demo/index.html'])
    gitcode_release(ver, token, assets, notes)
    if with_github:
        nf = notes_file or (REPO_DIR / '_notes.md')
        if not notes_file:
            nf.write_text(notes or 'v%s' % ver, encoding='utf-8')
        sync_github(ver, gh_assets, nf)
        if not notes_file and nf.exists():
            nf.unlink()
    else:
        print('⑥ 跳过 GitHub (默认只发 GitCode; 加 --github 才同步)')
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
        sys.exit('❌ 验真失败: 两平台下载回来的东西和本地对不上, 这次发布不算成功, '
                 '请按上面的 [FAIL] 逐条补齐后重跑。')
    print('全部完成, 用时 %.0f 秒, 验真通过' % (time.time() - t0))


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    a = sys.argv[1]
    if a == 'set-token' and len(sys.argv) > 2:
        cmd_set_token(sys.argv[2])
    elif a == 'whoami':
        t = load_token()
        if not t:
            sys.exit('没有存过令牌')
        u = api('GET', '/user', t)
        print('用户 =', u.get('login') or u.get('name'))
    elif a == 'verify' and len(sys.argv) > 2:
        cmd_verify(sys.argv[2])
    elif a == 'release' and len(sys.argv) > 2:
        ver = sys.argv[2]
        cmd_release(ver,
                    skip_build='--skip-build' in sys.argv,
                    with_github='--github' in sys.argv,
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
    plain_exe = REPO_DIR / EXE_NAME
    ascii_exe = REPO_DIR / ('MSWallpaperAssistant-v%s.exe' % ver)
    # 只验"平台上真的挂了的那几个"。带版本号的 exe（桌面壁纸-vX.Y.Z.exe）是打包中间产物、
    # 并不作为附件发布，列进来只会得到一个假 FAIL（2026-10-26 实测两平台附件清单：
    # GitCode = zip + 桌面壁纸.exe + version.json(+.sig)，GitHub = ASCII 名 exe + zip + 清单）。
    assets = [p for p in (zip_path, plain_exe, vj, vsig) if p.exists()]
    gh_assets = [p for p in (zip_path, ascii_exe, vj, vsig) if p.exists()]
    print('② 附件验真（两个平台各一次）:')
    ok = verify(ver, assets, gh_assets)
    ok = verify_signature(vj, vsig) and ok
    print('验真结果:', 'PASS' if ok else 'FAIL')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
