# -*- coding: utf-8 -*-
"""生成升级源 version.json（发版时用）
用法: python tools/make_version_json.py [--exe <exe路径>]
它读 launcher.py 的 VERSION，算出 core.ps1 / menu.ps1 / exe 的 SHA256，
脚本地址指向 Gitee raw(main 分支)，exe 地址指向 Gitee 发行版附件。
发布时把 version.json 一并上传到发行版，并提交到仓库 main 分支（脚本下载走 raw）。
"""
import argparse, hashlib, io, json, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

def sha256(p):
    with open(p, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest().upper()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--exe', default=os.path.join(REPO, '微软壁纸助手.exe'))
    ap.add_argument('--out', default=os.path.join(REPO, 'version.json'))
    a = ap.parse_args()
    with io.open(os.path.join(REPO, 'launcher.py'), encoding='utf-8') as f:
        ver = re.search(r"^VERSION\s*=\s*'([^']+)'", f.read(), re.M).group(1)
    raw = 'https://gitee.com/kele551/ms-wallpaper-assistant/raw/main/'
    rel = 'https://gitee.com/kele551/ms-wallpaper-assistant/releases/download/v%s/' % ver
    out = {
        'version': ver,
        'min_launcher': ver,
        'notes': '',
        'scripts': {
            'core.ps1': {'sha256': sha256(os.path.join(REPO, 'core.ps1')), 'url': raw + 'core.ps1'},
            'menu.ps1': {'sha256': sha256(os.path.join(REPO, 'menu.ps1')), 'url': raw + 'menu.ps1'},
        },
        'launcher': {'sha256': sha256(a.exe), 'url': rel + '微软壁纸助手.exe',
                     'size': os.path.getsize(a.exe)},
    }
    with io.open(a.out, 'w', encoding='utf-8', newline='') as f:
        f.write(json.dumps(out, ensure_ascii=False, indent=2) + '\n')
    print('已写出 %s (version=%s)' % (a.out, ver))

if __name__ == '__main__':
    main()
