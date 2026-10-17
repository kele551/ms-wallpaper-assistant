# -*- coding: utf-8 -*-
"""生成升级源 version.json + version.json.sig（发版时用）
用法: python tools/make_version_json.py [--exe <exe路径>]
它读 launcher.py 的 VERSION，算出 core.ps1 / menu.ps1 / exe 的 SHA256，
脚本地址指向 Gitee raw(main 分支)，exe 地址指向 Gitee 发行版附件。
发布时把 version.json 与 version.json.sig 一并上传到发行版，并提交到仓库 main 分支。

2026-10-16 升级通道加固: 写完 version.json 后**立即**用 Ed25519 私钥给它的**原始字节**
签名, 同目录写出 `version.json.sig`（128 个十六进制字符）。客户端（launcher.py --verify-update）
用内置公钥验签, 验不过一律拒绝升级。
私钥取值顺序: ① 环境变量 MWA_ED25519_KEY → ② ~/.mwa-publish.json 的 "ed25519_key" →
③ 找不到就**明确报错**。私钥只在签名这一刻读一次, 不打印、不复制、不进仓库;
本文件里也不写任何本机路径。
"""
import argparse, hashlib, io, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

def sha256(p):
    with open(p, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest().upper()

def load_ed25519():
    """加载仓库根的 _ed25519.py（纯 Python 实现，零第三方依赖）。"""
    if REPO not in sys.path:
        sys.path.insert(0, REPO)
    import _ed25519
    return _ed25519

def load_seed(path):
    """读私钥种子（64 个十六进制字符 = 32 字节）。只读、不打印、不复制到别处。

    单独写成一个函数是为了"读错文件/文件坏了"当场说清楚 —— 宁可不发版，
    也不要发一份签得不对的 version.json.sig（客户端会一律拒绝，等于把升级通道弄断）。
    """
    with io.open(path, encoding='utf-8') as f:
        txt = f.read().strip()
    if not re.fullmatch(r'[0-9a-fA-F]{64}', txt):
        raise SystemExit('私钥文件内容不是 64 个十六进制字符（32 字节种子），拒绝签名: %s' % path)
    return bytes.fromhex(txt)

def resolve_sign_key():
    """确定本次签名用哪把私钥；拿不到就报清楚"该怎么办"，绝不静默跳过签名。

    为什么宁可不生成：客户端**只认验过签的升级源**。要是这次漏了签名，线上就会多出
    一份"新版本号但签名为空/不匹配"的 version.json —— 已装用户一律被拒绝，等于升级通道断掉。
    """
    key = os.environ.get('MWA_ED25519_KEY')
    if not key:
        try:
            cfgp = os.path.join(os.path.expanduser('~'), '.mwa-publish.json')
            if os.path.isfile(cfgp):
                key = json.load(io.open(cfgp, encoding='utf-8')).get('ed25519_key') or ''
        except Exception:
            key = ''
    if not key or not os.path.isfile(key):
        raise SystemExit('找不到 Ed25519 签名私钥 —— 拒绝生成签名（客户端只认验过签的升级源）。\n'
                         '任选一种方式告诉本脚本私钥在哪（私钥本身**不要**放进仓库）：\n'
                         '  ① 环境变量:  set MWA_ED25519_KEY=<私钥文件路径>\n'
                         '  ② 本机私有配置 ~/.mwa-publish.json 里加一行:  "ed25519_key": "<私钥文件路径>"\n'
                         '私钥文件的内容是 64 个十六进制字符（32 字节种子）。')
    return key

def sign_file(raw, out_path, key_path):
    """给 raw 字节签名，把 128 个十六进制字符写进 <out_path>.sig。"""
    ed = load_ed25519()
    sig = ed.signature(raw, load_seed(key_path)).hex()
    if not re.fullmatch(r'[0-9a-f]{128}', sig):
        raise SystemExit('签出来的东西长度不对（预期 128 个十六进制字符），拒绝写出: %d' % len(sig))
    # 2026-10-16 (坑①): 必须写 out_path + '.sig'，绝不能写 out_path —— 写错会把
    # version.json 覆盖成签名串，发布被闸门拦住（狐径第一版踩过）。
    with io.open(out_path + '.sig', 'w', encoding='utf-8', newline='') as f:
        f.write(sig)
    return sig

def main():
    ap = argparse.ArgumentParser()
    # 2026-10-12 改名: 成品/附件都叫 壁纸助手.exe (老名「微软壁纸助手.exe」是历史附件名,
    # 只存在于旧发行页; version.json 指向必须与本次上传的附件名一字不差, 否则全体老用户 404)
    ap.add_argument('--exe', default=os.path.join(REPO, '壁纸助手.exe'))
    ap.add_argument('--out', default=os.path.join(REPO, 'version.json'))
    a = ap.parse_args()
    with io.open(os.path.join(REPO, 'launcher.py'), encoding='utf-8') as f:
        ver = re.search(r"^VERSION\s*=\s*'([^']+)'", f.read(), re.M).group(1)
    raw = 'https://gitee.com/kele551/ms-wallpaper-assistant/raw/main/'
    # 2026-10-17: launcher(exe) 下载源切到 GitCode（国内、快、下载数可统计）；脚本仍走 Gitee raw（稳）。
    rel = 'https://gitcode.com/kele551/ms-wallpaper-assistant/releases/download/v%s/' % ver
    out = {
        'version': ver,
        'min_launcher': ver,
        'notes': '',
        'scripts': {
            'core.ps1': {'sha256': sha256(os.path.join(REPO, 'core.ps1')), 'url': raw + 'core.ps1'},
            'menu.ps1': {'sha256': sha256(os.path.join(REPO, 'menu.ps1')), 'url': raw + 'menu.ps1'},
        },
        'launcher': {'sha256': sha256(a.exe), 'url': rel + '壁纸助手.exe',
                     'size': os.path.getsize(a.exe)},
    }
    # ① 先写 version.json（签名对象是这份文件的**原始字节**，所以必须先落盘、再签名）
    raw_text = json.dumps(out, ensure_ascii=False, indent=2) + '\n'
    raw_bytes = raw_text.encode('utf-8')
    with io.open(a.out, 'w', encoding='utf-8', newline='') as f:
        f.write(raw_text)
    # ② 再给**刚写出的字节**签名，保证"盘上的 version.json"与"签名的内容"逐字节一致
    key_path = resolve_sign_key()
    sig = sign_file(raw_bytes, a.out, key_path)
    print('已写出 %s (version=%s)' % (a.out, ver))
    print('已写出 %s.sig (Ed25519 签名, %d 个十六进制字符, 前 16 位 %s…)'
          % (a.out, len(sig), sig[:16]))

if __name__ == '__main__':
    main()
