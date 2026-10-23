# 作者: 海风（kele551）
# 用途: 给"任意一份 version.json"签名（升级演练用）。
#   发版走 tools/make_version_json.py 就自带签名; 这个脚本是给 drill_upgrade.ps1 用的:
#   演练要把 version.json 里的下载地址换成 http://127.0.0.1:端口/，地址变了签名就失效，
#   必须重新签一次，否则老客户端会正确地拒绝升级（那样演练测的就不是升级，而是验签）。
#
# 私钥取值: --key 参数 → 环境变量 MWA_ED25519_KEY → ~/.mwa-publish.json 的 ed25519_key
#   （与 make_version_json.py 同一套顺序，不在这里硬编码任何本机路径）
import argparse
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_version_json as mv  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('version_json', help='要签名的 version.json 路径')
    ap.add_argument('--key', default='', help='私钥文件路径（64 个十六进制字符 = 32 字节种子）')
    a = ap.parse_args()

    key = a.key or os.environ.get('MWA_ED25519_KEY', '')
    if not key:
        cfgp = os.path.join(os.path.expanduser('~'), '.mwa-publish.json')
        if os.path.exists(cfgp):
            try:
                import json
                key = json.load(io.open(cfgp, encoding='utf-8')).get('ed25519_key') or ''
            except Exception:
                key = ''
    if not key or not os.path.exists(key):
        print('没有可用的私钥（--key / MWA_ED25519_KEY / ~/.mwa-publish.json）')
        return 2

    raw = io.open(a.version_json, 'rb').read()
    sig = mv.sign_file(raw, a.version_json, key)
    print('已签名: %s.sig（%d 个十六进制字符，前 8: %s）' % (a.version_json, len(sig), sig[:8]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
