# -*- coding: utf-8 -*-
"""
微软壁纸助手 —— 一键发布流水线

依赖: 一枚 Gitee 私人令牌(仅勾 projects 权限), 存一次, 之后长期复用。
GitHub 侧走已登录的 gh CLI / REST 脚本, 不需要额外凭据。

用法:
    python tools/publish.py set-token <令牌>         # 存令牌并验证
    python tools/publish.py whoami                   # 看令牌是否有效
    python tools/publish.py release 1.6.7            # 全自动发布一版
    python tools/publish.py release 1.6.7 --skip-build   # 已有 exe, 只做发布
    python tools/publish.py release 1.6.7 --notes 文件.md # 指定发布说明

release 子命令依次做:
    ① 改三处版本号 (core.ps1 / menu.ps1 / launcher.py)
    ② 打包 (build-exe.py --release)
    ③ 提交 + 打 tag + 推 Gitee
    ④ Gitee 建发行版 + 上传 zip 附件
    ⑤ README 下载链接指向新版 -> 提交推送
    ⑥ 同步 GitHub 代码 + 建 Release
    ⑦ 验真: 下载链接 200 / 大小 / zip 完整性
"""
import os
import re
import sys
import json
import time
import shutil
import zipfile
import io
import subprocess
from pathlib import Path

import requests

REPO_DIR = Path(__file__).resolve().parent.parent
OWNER, REPO = 'kele551', 'ms-wallpaper-assistant'
BRANCH = 'main'
GITEE_API = 'https://gitee.com/api/v5'
GITEE_WEB = 'https://gitee.com'
TOKEN_FILE = Path(os.environ.get('GITEE_TOKEN_FILE')
                  or r'C:\Users\kele551\.workbuddy\secrets\gitee_token')
PY = r'C:\Users\kele551\.workbuddy\binaries\python\envs\default\Scripts\python.exe'
GH = r'C:\Users\kele551\AppData\Local\Programs\gh\bin\gh.exe'
GIT_EXEC_PATH = r'C:/Users/kele551/.workbuddy/binaries/PortableGit/versions/1.2.0/mingw64/bin'
GH_PUSH = (r'C:\Users\kele551\.workbuddy\skills\publish-github-to-gitee'
           r'\scripts\github_rest_push.py')
ZIP_TPL = 'MSWallpaperAssistant-v%s.zip'

# 版本常量所在的三个文件
VER_FILES = [
    ('core.ps1', re.compile(r"(\$global:BWVersion\s*=\s*')[0-9.]+(')"),
     lambda v: r"\g<1>%s\g<2>" % v),
    ('menu.ps1', re.compile(r"(\$global:BWVersion\s*=\s*')[0-9.]+(')"),
     lambda v: r"\g<1>%s\g<2>" % v),
    ('launcher.py', re.compile(r"(VERSION\s*=\s*')[0-9.]+(')"),
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
    if TOKEN_FILE.exists():
        return TOKEN_FILE.read_text(encoding='utf-8').strip()
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
    if env:
        e.update(env)
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
    run(['git', '-c', 'user.name=kele551', '-c', 'user.email=75219857@qq.com',
         'commit', '-m', msg])
    run(['git', 'tag', '-a', 'v%s' % ver, '-m', 'v%s' % ver])
    run(['git', 'push', 'origin', BRANCH])
    run(['git', 'push', 'origin', 'v%s' % ver])
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
def gitee_release(ver, token, zip_path, notes):
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

    # 同名附件先删, 避免重复
    exist = api('GET', '/repos/%s/%s/releases/%s/attach_files' % (OWNER, REPO, rid),
                token)
    name = os.path.basename(zip_path)
    for a in exist if isinstance(exist, list) else []:
        if a.get('name') == name:
            api('DELETE', '/repos/%s/%s/releases/%s/attach_files/%s'
                % (OWNER, REPO, rid, a['id']), token)
            print('   旧附件已删:', name)

    with open(zip_path, 'rb') as f:
        r = requests.post(
            '%s/repos/%s/%s/releases/%s/attach_files' % (GITEE_API, OWNER, REPO, rid),
            params={'access_token': token},
            files={'file': (name, f, 'application/zip')},
            timeout=300)
    if r.status_code >= 400:
        raise RuntimeError('附件上传失败 %s %s' % (r.status_code, r.text[:300]))
    print('   附件已上传:', name)


def sync_github(ver, zip_path, notes_file):
    run([PY, GH_PUSH, '--dir', str(REPO_DIR), '--repo', '%s/%s' % (OWNER, REPO),
         '--branch', BRANCH, '--tag', 'v%s' % ver,
         '--message', 'release: v%s' % ver])
    print('⑥ GitHub 代码已同步')
    if os.path.exists(GH):
        run([GH, 'release', 'create', 'v%s' % ver, '-R', '%s/%s' % (OWNER, REPO),
             str(zip_path), '--title', 'v%s' % ver,
             '--notes-file', str(notes_file)], check=False)
        print('⑥ GitHub Release 已建')


def verify(ver):
    url = '%s/%s/%s/releases/download/v%s/%s' % (
        GITEE_WEB, OWNER, REPO, ver, ZIP_TPL % ver)
    r = requests.get(url, timeout=180)
    ok = r.status_code == 200
    info = {'status': r.status_code, 'bytes': len(r.content)}
    if ok:
        z = zipfile.ZipFile(io.BytesIO(r.content))
        info['zip_ok'] = z.testzip() is None
        info['entries'] = z.namelist()
    print('⑦ 验真:', json.dumps(info, ensure_ascii=False))
    print('   下载页:', '%s/%s/%s/releases/tag/v%s' % (GITEE_WEB, OWNER, REPO, ver))
    return ok and info.get('zip_ok', False)


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

    git_commit_push(ver, ['CHANGELOG.md', 'README.md', 'core.ps1', 'menu.ps1',
                          'launcher.py', '使用说明.txt'])
    gitee_release(ver, token, str(zip_path), notes)
    update_readme(ver)
    if with_github:
        nf = notes_file or (REPO_DIR / '_notes.md')
        if not notes_file:
            nf.write_text(notes or 'v%s' % ver, encoding='utf-8')
        sync_github(ver, zip_path, nf)
        if not notes_file and nf.exists():
            nf.unlink()
    else:
        print('⑥ 跳过 GitHub (默认只发 Gitee; 加 --github 才同步)')
    ok = verify(ver)          # 原来这一步没被执行, 且下一行引用了未定义的 ok 会抛 NameError
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
