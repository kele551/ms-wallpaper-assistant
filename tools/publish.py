# -*- coding: utf-8 -*-
"""
微软壁纸助手 —— 一键发布流水线

依赖: 一枚 Gitee 私人令牌(仅勾 projects 权限), 存一次, 之后长期复用。
GitHub 侧走工作区里的 REST 脚本 F:\\Harness\\tools\\github_push.py（用 gh 的令牌），
不需要 github.com 的 git 端口 —— 那条线路时通时断。

用法:
    python tools/publish.py set-token <令牌>         # 存令牌并验证
    python tools/publish.py whoami                   # 看令牌是否有效
    python tools/publish.py release 2.1.1            # 只发 Gitee
    python tools/publish.py release 2.1.1 --github   # 双平台(用户要求两个都发)
    python tools/publish.py release 2.1.1 --skip-build   # 已有 exe, 只做发布
    python tools/publish.py release 2.1.1 --notes 文件.md # 指定发布说明

release 子命令依次做:
    ① 改三处版本号 (core.ps1 / menu.ps1 / launcher.py)
    ② 打包 (build-exe.py --release)  ->  exe / 带版本号 exe / ASCII 名 zip
    ③ 生成升级源 version.json (必须与本次 exe 同一份, 否则老客户端校验不过)
    ④ 提交 + 打 tag + 推 Gitee
    ⑤ Gitee 建发行版 + 上传附件(zip / exe / version.json)
    ⑥ README 下载链接指向新版 -> 提交推送
    ⑦ 同步 GitHub (代码 + tag + Release + 附件, 走 REST)
    ⑧ 验真: 每个附件从两个平台下载回来比对 SHA256
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
from urllib.parse import quote
from pathlib import Path

import requests

REPO_DIR = Path(__file__).resolve().parent.parent
OWNER, REPO = 'kele551', 'ms-wallpaper-assistant'
BRANCH = 'main'
GITEE_API = 'https://gitee.com/api/v5'
GITEE_WEB = 'https://gitee.com'
TOKEN_CANDIDATES = [
    r'F:\Harness\secrets\raw\workbuddy-secrets\gitee_token',   # 工作区备份(首选)
    r'C:\Users\kele551\.workbuddy\secrets\gitee_token',        # 旧位置(退回)
]
TOKEN_FILE = Path(TOKEN_CANDIDATES[0])
PY = r'F:\Harness\toolchain\python\envs\default\Scripts\python.exe'
GIT_EXEC_PATH = r'F:/Harness/toolchain/PortableGit/versions/1.2.0/mingw64/bin'
GIT_EXE = GIT_EXEC_PATH + '/git.exe'              # 绝对路径: 有的执行环境按名字找不到 git(WinError 2)
GH_PUSH = r'F:\Harness\tools\github_push.py'      # 纯 API 推 GitHub(含附件), 2026-09-22 重写
ZIP_TPL = 'MSWallpaperAssistant-v%s.zip'
APP_NAME = '微软壁纸助手'
EXE_NAME = '微软壁纸助手.exe'                      # version.json 里写的就是这个名字, 必须传上去

# 版本常量所在的三个文件
VER_FILES = [
    ('core.ps1', re.compile(r"(\$global:BWVersion\s*=\s*')[0-9.]+(')"),
     lambda v: r"\g<1>%s\g<2>" % v),
    ('menu.ps1', re.compile(r"(\$global:BWVersion\s*=\s*')[0-9.]+(')"),
     lambda v: r"\g<1>%s\g<2>" % v),
    ('launcher.py', re.compile(r"(VERSION\s*=\s*')[0-9.]+(')"),
     lambda v: r"\g<1>%s\g<2>" % v),
    ('README.md', re.compile(r'(version-v)[0-9.]+(-blue)'),
     lambda v: r"\g<1>%s\g<2>" % v),
]


# ---------- 令牌 ----------
def save_token(tok):
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    TOKEN_FILE.write_text(tok.strip(), encoding='utf-8')
    print('令牌已存到', TOKEN_FILE)


def load_token():
    t = os.environ.get('GITEE_TOKEN')
    if t:
        return t.strip()
    for c in TOKEN_CANDIDATES:
        p = Path(c)
        if p.exists():
            return p.read_text(encoding='utf-8').strip()
    return None


def api(method, path, token, **kw):
    p = dict(kw.get('params') or {})
    p['access_token'] = token
    kw['params'] = p
    kw.setdefault('timeout', 60)
    r = requests.request(method, GITEE_API + path, **kw)
    if r.status_code >= 400:
        raise RuntimeError('API %s %s -> %s %s' % (method, path, r.status_code, r.text[:300]))
    return r.json() if r.text.strip() else {}


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
    """从 CHANGELOG 取该版本的条目, 去掉项目符号前缀, 保持 Markdown 可读。"""
    cl = (REPO_DIR / 'CHANGELOG.md').read_text(encoding='utf-8')
    m = re.search(r'^- \*\*v%s\*\*(.+?)(?=^- \*\*v|\Z)' % re.escape(ver),
                  cl, re.S | re.M)
    if not m:
        return None
    body = m.group(1).strip()
    body = re.sub(r'\s+\n', '\n', body)
    body = body.replace('\n- ', '\n- ')
    return '## v%s\n\n%s' % (ver, body)


def run(cmd, cwd=REPO_DIR, env=None, check=True):
    e = os.environ.copy()
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


def git_commit_push(ver, files):
    run(['git', 'add'] + files)
    msg = 'release: v%s' % ver
    if run(['git', 'diff', '--cached', '--name-only']).strip():
        run(['git', '-c', 'user.name=kele551', '-c', 'user.email=75219857@qq.com',
             'commit', '-m', msg])
    else:
        print('   工作区没有新改动, 跳过本次提交(只补发版)')
    if not run(['git', 'tag', '-l', 'v%s' % ver]).strip():
        run(['git', '-c', 'user.name=kele551', '-c', 'user.email=75219857@qq.com',
             'tag', '-a', 'v%s' % ver, '-m', 'v%s' % ver])   # 打 tag 同样要显式带身份
        run(['git', 'push', 'origin', 'v%s' % ver])
    else:
        print('   tag v%s 已存在, 不重复创建' % ver)
    run(['git', 'push', 'origin', BRANCH])
    print('③ 代码与 tag 已推 Gitee')


def update_readme(ver):
    f = REPO_DIR / 'README.md'
    txt = f.read_text(encoding='utf-8')
    new = txt
    new = re.sub(r'releases/download/v[0-9.]+/', 'releases/download/v%s/' % ver, new)
    new = re.sub(r'version-v[0-9.]+', 'version-v%s' % ver, new)
    new = re.sub(r'当前最新：v[0-9.]+', '当前最新：v%s' % ver, new)
    if new != txt:
        f.write_text(new, encoding='utf-8')
        run(['git', 'add', 'README.md'])
        run(['git', '-c', 'user.name=kele551', '-c', 'user.email=75219857@qq.com',
             'commit', '-m', 'docs: README 指向 v%s' % ver])
        run(['git', 'push', 'origin', BRANCH])
        print('⑤ README 已更新并推送')
    else:
        print('⑤ README 无变化')


# ---------- 发行版 ----------
def gitee_release(ver, token, assets, notes):
    tag = 'v%s' % ver
    # 已存在则复用
    rel = None
    try:
        rel = api('GET', '/repos/%s/%s/releases/tags/%s' % (OWNER, REPO, tag), token)
    except Exception:
        rel = None
    if rel and rel.get('id'):
        print('④ 发行版已存在, id =', rel['id'])
    else:
        rel = api('POST', '/repos/%s/%s/releases' % (OWNER, REPO), token, json={
            'tag_name': tag,
            'name': tag,
            'body': notes or ('v%s' % ver),
            'target_commitish': BRANCH,
            'prerelease': False,
        })
        print('④ 发行版已创建, id =', rel.get('id'))
    rid = rel['id']

    # 同名附件先删, 避免重复；然后逐个上传
    exist = api('GET', '/repos/%s/%s/releases/%s/attach_files' % (OWNER, REPO, rid),
                token)
    have = {a.get('name'): a['id'] for a in (exist if isinstance(exist, list) else [])}
    for path in assets:
        name = os.path.basename(str(path))
        if name in have:
            api('DELETE', '/repos/%s/%s/releases/%s/attach_files/%s'
                % (OWNER, REPO, rid, have[name]), token)
            print('   旧附件已删:', name)
        with open(str(path), 'rb') as f:
            r = requests.post(
                '%s/repos/%s/%s/releases/%s/attach_files' % (GITEE_API, OWNER, REPO, rid),
                params={'access_token': token},
                files={'file': (name, f, 'application/octet-stream')},
                timeout=1800)
        if r.status_code >= 400:
            raise RuntimeError('附件上传失败 %s %s %s' % (name, r.status_code, r.text[:200]))
        print('   附件已上传:', name, os.path.getsize(str(path)), 'B')


def make_version_json():
    """生成升级源 version.json（要提交到 main，并作为发行版附件上传）。"""
    out = run([PY, os.path.join('tools', 'make_version_json.py')])
    print('   升级源 version.json 已生成:', out.strip().splitlines()[-1] if out.strip() else '')
    return REPO_DIR / 'version.json'


def sync_github(ver, assets, notes_file):
    """代码 + tag + Release + 附件，全部走 api.github.com / uploads.github.com。"""
    cmd = [PY, GH_PUSH, '--dir', str(REPO_DIR), '--repo', '%s/%s' % (OWNER, REPO),
           '--branch', BRANCH, '--tag', 'v%s' % ver,
           '--message', 'release: v%s' % ver]
    for a in assets:
        cmd += ['--asset', str(a)]
    if notes_file and os.path.exists(notes_file):
        cmd += ['--notes-file', str(notes_file)]
    run(cmd)
    print('⑥ GitHub 代码 / tag / Release / 附件 已同步')


def _download(url):
    for _ in range(3):
        try:
            r = requests.get(url, timeout=900)
            if r.status_code == 200:
                return r.content
        except Exception:
            pass
        time.sleep(4)
    return None


def verify(ver, assets):
    """逐个附件从 Gitee / GitHub 下载回来比对 SHA256（中文名要 percent-encode）。"""
    ok = True
    for p in assets:
        p = str(p)
        name = os.path.basename(p)
        want = hashlib.sha256(open(p, 'rb').read()).hexdigest()
        for label, url in (
                ('Gitee ', '%s/%s/%s/releases/download/v%s/%s'
                 % (GITEE_WEB, OWNER, REPO, ver, quote(name))),
                ('GitHub', 'https://github.com/%s/%s/releases/download/v%s/%s'
                 % (OWNER, REPO, ver, quote(name)))):
            data = _download(url)
            if data is None:
                print('  [FAIL] %s %-32s 下载失败' % (label, name))
                ok = False
                continue
            same = hashlib.sha256(data).hexdigest() == want
            ok = ok and same
            print('  [%s] %s %-32s %9d B  一致=%s'
                  % ('PASS' if same else 'FAIL', label, name, len(data), same))
    print('   下载页:', '%s/%s/%s/releases/tag/v%s' % (GITEE_WEB, OWNER, REPO, ver))
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
        notes = Path(notes_file).read_text(encoding='utf-8')
    else:
        notes = extract_notes(ver)
    if not notes:
        print('!! CHANGELOG 里没有 v%s 的条目, 发布说明会是空的' % ver)

    bump_version(ver)
    if not skip_build:
        out = run([PY, 'build-exe.py', '--release'])
        print('② 打包完成:', out.strip().splitlines()[-1] if out.strip() else '')
    if not zip_path.exists():
        sys.exit('找不到 %s, 打包可能失败了' % zip_path)
    print('   zip =', zip_path, zip_path.stat().st_size, 'B')

    # ③ 升级源：必须和本次 exe 同一份，否则自动升级会校验不过
    plain_exe = REPO_DIR / EXE_NAME
    tagged_exe = REPO_DIR / ('%s-v%s.exe' % (APP_NAME, ver))
    if not skip_build and not plain_exe.exists():
        sys.exit('找不到 %s' % plain_exe)
    vj = make_version_json()
    assets = [zip_path, vj] + [p for p in (plain_exe, tagged_exe) if p.exists()]

    git_commit_push(ver, ['CHANGELOG.md', 'README.md', 'core.ps1', 'menu.ps1',
                          'launcher.py', '使用说明.txt', 'version.json'])
    gitee_release(ver, token, assets, notes)
    update_readme(ver)
    if with_github:
        nf = notes_file or (REPO_DIR / '_notes.md')
        if not notes_file:
            nf.write_text(notes or 'v%s' % ver, encoding='utf-8')
        sync_github(ver, assets, nf)
        if not notes_file and nf.exists():
            nf.unlink()
    else:
        print('⑥ 跳过 GitHub (默认只发 Gitee; 加 --github 才同步)')
    ok = verify(ver, assets)   # 原来这一步没被执行, 且下一行引用了未定义的 ok 会抛 NameError
    print('全部完成, 用时 %.0f 秒, 验真=%s' % (time.time() - t0, ok))


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
    elif a == 'release' and len(sys.argv) > 2:
        ver = sys.argv[2]
        cmd_release(ver,
                    skip_build='--skip-build' in sys.argv,
                    with_github='--github' in sys.argv,
                    notes_file=(sys.argv[sys.argv.index('--notes') + 1]
                                if '--notes' in sys.argv else None))
    else:
        print(__doc__)


if __name__ == '__main__':
    main()
