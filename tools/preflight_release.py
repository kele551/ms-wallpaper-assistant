# -*- coding: utf-8 -*-
# 作者: 海风（kele551）   https://gitee.com/kele551/ms-wallpaper-assistant
"""桌面壁纸（壁纸助手）—— 发版前自检闸门（必须全绿才允许发布）

为什么这个文件在仓库里：
    用户 2026-10-08 明确要求「测试成功再发布」「以后都这样」，狐径 FoxPath 那边先有了
    这道闸门，本项目也要求「发版前自检闸门随仓库提供」。
    可这份脚本此前只躺在维护者工作区里，仓库里没有 —— 外人克隆下来无门可跑，
    那句话就不成立。这个文件把闸门补进仓库：**克隆 → `python tools/preflight_release.py`
    → 逐项 [PASS]/[FAIL]/[SKIP] → 给出退出码**，不需要任何本机绝对路径。

这个脚本盯的就是本项目历史上真出过事的地方：
  ① 版本号散在 launcher.py / menu.ps1 / version.json / README / 使用说明 / CHANGELOG
     —— 历史上就出过「只改了部分文件」；
  ② `.ps1` 少了 UTF-8 BOM → PowerShell 5.1 按 ANSI 读 → 中文乱码、解析失败
     —— 历史上真发生过（Fix-GitHub.ps1 因此从未成功运行过）；
  ③ version.json 里的脚本指纹与仓库里的 core.ps1 / menu.ps1 对不上 → 老用户热更必然校验不过；
  ④ README / 使用说明 里的下载链接还指着旧版本；对外文档里混进私人邮箱；
  ⑤ 产品更名后旧名（微软壁纸助手）被当成**当前文件名**引用 —— 差一个字老用户就 404。

这个脚本的分工（重要）：
    · 只用**标准库**就能查的（语法、版本一致性、version.json 与仓库文件对齐、治理文件、
      文档体检）一律自己查，不依赖第三方包，也不依赖维护者本机；
    · 需要**已打包的 exe**（成品指纹、exe 文件版本、tests/test_all.py）、需要
      **PowerShell**、需要**联网**的检查，条件不满足时打印 [SKIP] 并说明原因
      —— **跳过不算失败**；
    · 远端平台、网络这类我们控制不了的事只算 [WARN]，不阻断发布。

用法：
  python tools/preflight_release.py [exe路径] [--offline] [--no-links] [-h]

  exe路径     候选成品（默认 <仓库>/壁纸助手.exe；仓库里不带成品，所以默认会 SKIP 那一节）
  --offline   完全不联网（跳过「链接与徽章」「线上升级源对齐」两节）
  --no-links  只跳过「链接与徽章」一节
  -h, --help  只打印这段说明就退出（不联网、不写任何文件）

会动到系统的地方：只有 tests/test_all.py 那一节（它在临时目录里跑候选 exe，
把 LOCALAPPDATA 重定向过去，不改你的桌面壁纸）；没有候选 exe 时那一节直接 SKIP。

判据：红项（FAIL）一条都不许有 —— 有一条就不许发布；
      跳过（SKIP）与警告（WARN）不阻断发布，但会在结尾单独列出来，发布前应当看一眼。

退出码：全绿（允许 SKIP/WARN）= 0；有 [FAIL] = 1；开关写错 = 2。
"""
import base64
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# 控制台编码可能是 GBK（Windows 中文默认）：结论行的 ✅/❌ 会让 print 抛
# UnicodeEncodeError，于是"检查明明全绿"却以 traceback + 退出码 1 收场 ——
# 2026-10-09 在本项目实跑复现过（把自检输出存 logs\ 时必踩）。
try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

# 仓库根：本脚本既可能躺在**仓库**里的 <仓库>\tools\（随仓库入库的那份，源码就在上一级），
# 也可能躺在**维护者工作区**的 <项目>\tools\（源码在旁边 <项目>\repo）。
# 判据用 launcher.py 这个只在仓库根才有的文件 —— 两种布局都自己认出来。
_HERE = os.path.dirname(os.path.abspath(__file__))
_UP = os.path.dirname(_HERE)
REPO = _UP if os.path.exists(os.path.join(_UP, 'launcher.py')) else os.path.join(_UP, 'repo')

VJSON = os.path.join(REPO, 'version.json')
README = os.path.join(REPO, 'README.md')
CHANGELOG = os.path.join(REPO, 'docs', 'CHANGELOG.md')
MANUAL = os.path.join(REPO, '使用说明.txt')

GITEE_REPO = 'https://gitee.com/kele551/ms-wallpaper-assistant'
GITHUB_REPO = 'https://github.com/kele551/ms-wallpaper-assistant'
UA = 'MSWallpaperPreflight/1.0 (+%s)' % GITEE_REPO

# 旧名：产品 2026-10-12 更名「微软壁纸助手」→「壁纸助手」。文档里**允许**按兼容说明提及旧名，
# 但不许把旧名当成当前文件名/链接引用（差一个字，老用户点下载就 404）。
LEGACY_NAME = '微软壁纸助手'
LEGACY_QUALIFIERS = ('旧', '老', '原名', '更名', '改名', '历史', '撤回', '回到',
                     '沿用', '保留', '升级上来')

USAGE = """桌面壁纸发版前自检 —— 用法

  python tools/preflight_release.py [候选exe路径] [开关]

  候选exe路径        默认 <仓库>/壁纸助手.exe（仓库里不带成品，默认那一节会 SKIP）

开关:
  -h, --help   只打印这段说明就退出（不联网、不写任何文件）
      --offline   完全不联网：跳过「链接与徽章」「线上升级源对齐」两节
      --no-links  只跳过「链接与徽章」一节

看什么（逐项打印 [PASS] / [FAIL] / [SKIP]）:
  ① 仓库位置与治理文件（LICENSE / README / CONTRIBUTING / COMPLIANCE / SECURITY /
     CODE_OF_CONDUCT / CODE_SIGNING_POLICY / CHANGELOG / requirements.txt / CI 与 Issue 模板）
  ② Python 语法（标准库 compile，不落 __pycache__）
  ③ 版本一致性：launcher.py / menu.ps1 / version.json / README / 使用说明 / CHANGELOG
  ④ version.json 与仓库文件对齐（脚本指纹、附件名；成品指纹与 exe 版本需要成品）
  ⑤ PowerShell 脚本的 BOM 与语法（需要 powershell）
  ⑥ 对外文档体检（私人邮箱、旧名只能在兼容说明里、署名、依赖清单）
  ⑦ 测试套件 tests/test_all.py（需要已打包的成品 exe）
  ⑧ 链接与徽章可访问性（需要联网，--no-links/--offline 可跳过）
  ⑨ 线上升级源版本号对齐（只算 WARN）

判据: 红项（FAIL）一条都不许有 —— 有一条就不许发布；
      跳过（SKIP）与警告（WARN）不阻断发布，但结尾会单独列出来，发布前看一眼。
退出码: 全绿 = 0；有 FAIL = 1；开关写错 = 2。
"""

results = []      # [(名称, 是否通过, 说明)]  —— 红项进这里
skips = []        # [(名称, 为什么跳过)]      —— 跳过不算失败，但必须说清原因
warnings = []     # [(名称, 是否通过, 说明)]  —— 远端/网络这类只警告
_T0 = time.time()


def say(s=''):
    print(s)
    sys.stdout.flush()


def check(name, ok, detail=''):
    results.append((name, bool(ok), detail))
    say('  [%s] %s%s' % ('PASS' if ok else 'FAIL', name, ('  ' + str(detail)) if detail else ''))
    return bool(ok)


def skip(name, why):
    """条件不满足（缺依赖 / 缺成品 / 没有 PowerShell / 网络不可用）时用：不计入失败。"""
    skips.append((name, why))
    say('  [SKIP] %s  （%s）' % (name, why))
    return True


def check_warn(name, ok, detail=''):
    """警告级检查：不计入红项、不阻断发布。给"远端平台/网络"这类控制不了的事用。"""
    warnings.append((name, bool(ok), detail))
    say('  [%s] %s%s' % ('PASS' if ok else 'WARN', name, ('  ' + str(detail)) if detail else ''))
    return bool(ok)


def finish():
    """统一出口：打印汇总（红项 + 跳过 + 警告）并给出结论与退出码。"""
    say()
    say('=' * 74)
    bad = [n for n, ok, _ in results if not ok]
    warn = [(n, d) for n, ok, d in warnings if not ok]
    say('自检结果: %d 项，通过 %d，失败 %d；跳过 %d；警告 %d（耗时 %.0f 秒）'
        % (len(results), len(results) - len(bad), len(bad), len(skips), len(warn),
           time.time() - _T0))
    for n in bad:
        say('   FAIL -> %s' % n)
    for n, why in skips:
        say('   SKIP -> %s（%s）' % (n, why))
    for n, d in warn:
        say('   WARN -> %s%s' % (n, ('  ' + str(d)) if d else ''))
    if skips:
        say('   （跳过项不算失败：多半是没装依赖、没有成品 exe，或没联网 —— 请在能做到的环境里再跑一遍）')
    if warn:
        say('   （警告项不阻断发布：通常是"线上还没传/还没发布"，发布前看一眼即可）')
    if bad:
        say('结论: ❌ 有红项，禁止发布')
    else:
        say('结论: ✅ 全绿，可以发布')
    sys.exit(1 if bad else 0)


def read(path, enc='utf-8-sig'):
    try:
        return io.open(path, encoding=enc, errors='replace', newline='').read()
    except OSError:
        return None


def sha(path):
    return hashlib.sha256(open(path, 'rb').read()).hexdigest().upper()


def ver_tuple(v):
    """版本号按**元组**比，不按字符串比 —— '2.10' <= '2.9' 的字符串比较是错的（本项目踩过）。"""
    try:
        return tuple(int(x) for x in str(v).strip().lstrip('v').split('.'))
    except Exception:
        return (0,)


def ps(cmd, timeout=120):
    """跑一句 PowerShell 并把输出取回来；环境没有 powershell 时返回 None。"""
    try:
        r = subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                            '-Command', cmd], capture_output=True, text=True,
                           encoding='utf-8', errors='replace', timeout=timeout)
        return (r.stdout or '').strip()
    except Exception:
        return None


HAVE_PS = False      # 有没有可用的 powershell（非 Windows / 精简系统可能没有）；下面解析开关后再探


# ══════════════════════════════════════════════════════════════════════════
# 命令行开关（写法与狐径 tools/preflight_release.py:441-456 一致）
# ══════════════════════════════════════════════════════════════════════════
KNOWN_ARGS = ('-h', '--help', '--offline', '--no-links')
ARGS = list(sys.argv[1:])
if '-h' in ARGS or '--help' in ARGS:
    say(USAGE)
    say('   （本次运行脚本所在仓库: %s）' % REPO)
    sys.exit(0)
_unknown = [a for a in ARGS if a.startswith('-') and a not in KNOWN_ARGS]
if _unknown:
    say('不认识的开关: %s' % ' '.join(_unknown))
    say()
    say(USAGE)
    sys.exit(2)
OFFLINE = '--offline' in ARGS
NO_LINKS = OFFLINE or '--no-links' in ARGS
_positional = [a for a in ARGS if not a.startswith('-')]
HAVE_PS = ps("'ok'") == 'ok'      # --help 已经先返回了，这里才真的去探 PowerShell

say('=' * 74)
say('桌面壁纸（壁纸助手）发版前自检%s' % ('（--offline：不联网）' if OFFLINE else ''))
say('=' * 74)
say('  仓库: %s' % REPO)
say()

# ══════════════════════════════════════════════════════════════════════════
# ① 仓库位置与治理文件（自包含：只看文件在不在）
# ══════════════════════════════════════════════════════════════════════════
say('① 仓库位置与治理文件（克隆下来就该有；这一节就是仓库治理清单）')
if not check('在仓库里运行（上一级找得到 launcher.py）',
             os.path.exists(os.path.join(REPO, 'launcher.py')),
             '解析出的仓库 = %s（脚本应放在 <仓库>/tools/ 下）' % REPO):
    finish()

GOVERNANCE = (
    ('LICENSE', '许可'),
    ('README.md', '门面与使用说明'),
    ('docs/CONTRIBUTING.md', '贡献指南'),
    ('docs/COMPLIANCE.md', '合规声明'),
    ('docs/SECURITY.md', '安全报告渠道'),
    ('docs/CODE_OF_CONDUCT.md', '行为准则'),
    ('docs/CODE_SIGNING_POLICY.md', '签名与校验说明'),
    ('docs/CHANGELOG.md', '更新记录'),
    ('requirements.txt', '依赖清单'),
    ('.github/PULL_REQUEST_TEMPLATE.md', 'PR 模板'),
    ('.github/ISSUE_TEMPLATE/bug_report.yml', 'Bug Issue 模板'),
    ('.github/ISSUE_TEMPLATE/feature_request.yml', '功能 Issue 模板'),
    ('.github/ISSUE_TEMPLATE/config.yml', 'Issue 模板配置'),
    ('.github/workflows/build.yml', 'CI 构建'),
    ('docs/README_EN.md', '英文说明'),
    ('docs/demo/index.html', '演示页'),
    ('tools/preflight_release.py', '本自检脚本（随仓库提供）'),
)
_missing = [p for p, _ in GOVERNANCE if not os.path.exists(os.path.join(REPO, p))]
check('治理与协作文件齐全（%d 项）' % len(GOVERNANCE), not _missing,
      ('缺: ' + '、'.join(_missing)) if _missing else
      'LICENSE / CONTRIBUTING / COMPLIANCE / SECURITY / CI 模板都在')

SOURCE_FILES = ('launcher.py', 'core.ps1', 'menu.ps1', 'build-exe.py',
                '壁纸助手.ico', '使用说明.txt', 'version.json',
                'tests/test_all.py', 'tests/syn.ps1', 'tests/gen_ps_test.py',
                'tools/publish.py', 'tools/make_version_json.py',
                'docs/icon.png', 'docs/qr-sponsor.png', 'download-stats.html')
_missing2 = [p for p in SOURCE_FILES if not os.path.exists(os.path.join(REPO, p))]
check('源码与资源文件齐全（%d 项）' % len(SOURCE_FILES), not _missing2,
      ('缺: ' + '、'.join(_missing2)) if _missing2 else '')

# ══════════════════════════════════════════════════════════════════════════
# ② Python 语法（标准库 compile，不落 __pycache__）
# ══════════════════════════════════════════════════════════════════════════
say()
say('② Python 语法：launcher.py / build-exe.py / tools / tests 全部 compile')
_py_files = []
for _root, _dirs, _fs in os.walk(REPO):
    _dirs[:] = [d for d in _dirs if d not in {'.git', '__pycache__', 'dist', 'build', 'build_tmp', 'docs'}]
    for _f in sorted(_fs):
        if _f.endswith('.py'):
            _py_files.append(os.path.join(_root, _f))
_syntax_bad = []
for _p in _py_files:
    _src = read(_p, enc='utf-8-sig')
    if _src is None:
        _syntax_bad.append('%s（读不出来）' % os.path.relpath(_p, REPO))
        continue
    try:
        compile(_src, _p, 'exec')
    except SyntaxError as _e:
        _syntax_bad.append('%s:%s %s' % (os.path.relpath(_p, REPO), _e.lineno, _e.msg))
check('全部 .py 语法通过（%d 个文件）' % len(_py_files), not _syntax_bad,
      ('；'.join(_syntax_bad[:3])) if _syntax_bad else '')

# ══════════════════════════════════════════════════════════════════════════
# ③ 版本一致性（launcher.py 是源码里的唯一出处，version.json 是对外口径）
# ══════════════════════════════════════════════════════════════════════════
say()
say('③ 版本一致性：launcher.py / menu.ps1 / version.json / README / 使用说明 / CHANGELOG')
_src_launcher = read(os.path.join(REPO, 'launcher.py')) or ''
_m = re.search(r"VERSION\s*=\s*'([0-9.]+)'", _src_launcher)
VER = _m.group(1) if _m else ''
check('能读出 launcher.py 的 VERSION', bool(VER), 'VERSION=%r' % VER)
if not VER:
    finish()

# 产品名与成品名：从 launcher.py 的 APP_NAME 推导（不再写死，改名时少一处漏改）
_m = re.search(r"APP_NAME\s*=\s*'([^']+)'", _src_launcher)
APP_NAME = _m.group(1) if _m else ''
EXE_NAME = (APP_NAME + '.exe') if APP_NAME else '壁纸助手.exe'
check('能读出 launcher.py 的 APP_NAME', bool(APP_NAME), 'APP_NAME=%r → 成品名 %s' % (APP_NAME, EXE_NAME))
EXE = _positional[0] if _positional else os.path.join(REPO, EXE_NAME)

_src_menu = read(os.path.join(REPO, 'menu.ps1')) or ''
_m = re.search(r"\$global:BWVersion\s*=\s*'([0-9.]+)'", _src_menu)
check('menu.ps1 的 $global:BWVersion == %s' % VER,
      bool(_m) and _m.group(1) == VER, '实际=%s' % (_m.group(1) if _m else '没找到'))

# core.ps1 没有版本常量（2026-10-08 自检查明）：版本只在 launcher.py 与 menu.ps1 定义，
# publish.py 的"改三处版本号"对 core.ps1 其实是空操作。这里如实记录；将来若真加了常量，
# 下面的分支会自动开始校验它。
_src_core = read(os.path.join(REPO, 'core.ps1')) or ''
_m = re.search(r"\$global:BWVersion\s*=\s*'([0-9.]+)'", _src_core)
if _m is None:
    check('core.ps1 没有写死的版本常量（版本只在 launcher.py 与 menu.ps1）', True,
          '如实记录：现状如此，不是缺陷')
else:
    check('core.ps1 的 BWVersion == %s' % VER, _m.group(1) == VER, '实际=%s' % _m.group(1))

if not os.path.exists(VJSON):
    check('version.json 存在', False, VJSON)
    vj = {}
else:
    vj = json.loads(read(VJSON) or '{}')
    check('version.json 版本号 == launcher.py', vj.get('version') == VER,
          'json=%s' % vj.get('version'))
    check('min_launcher 不高于当前版本',
          ver_tuple(vj.get('min_launcher') or '0') <= ver_tuple(VER),
          'min_launcher=%s' % vj.get('min_launcher'))

_rm = read(README) or ''
# 徽章：动态徽章（shields.io 现读线上 release，永远不过期）优先，没有才回落到静态徽章。
_DYN_BADGE = re.compile(r'img\.shields\.io/github/v/release/', re.I)
if _DYN_BADGE.search(_rm):
    check('README 版本徽章 == v%s' % VER, True,
          '用动态徽章（shields.io 现读线上 release，不会停在旧版本）')
else:
    _badge = re.findall(r'version-v([0-9.]+)-blue', _rm)
    check('README 版本徽章 == v%s' % VER, _badge == [VER], '实际=%s' % (_badge or '没找到'))

# 下载链接不许指着旧版本 —— 2026-10-05 就是把 v2.0.7 的下载说明推上了线。
_links = set(re.findall(r'releases/download/v([0-9.]+)/', _rm))
check('README 里的下载链接都是 v%s' % VER, _links <= {VER},
      '出现=%s' % (sorted(_links) or '无'))
_dl = re.findall(r'点这里下载[^\n]*', _rm)
if _dl:
    check('README 的「点这里下载」文案带当前版本号',
          all(('v' + VER) in x for x in _dl), _dl[0][:70])
else:
    check('README 的「点这里下载」文案带当前版本号', True, '（没有该文案，跳过）')

# 使用说明.txt：里面提到的最高版本号必须就是当前版本（停在上一版就是没跟上）。
_man = read(MANUAL) or ''
_man_all = re.findall(r'v([0-9]+\.[0-9]+\.[0-9]+)', _man)
_man_top = max(_man_all, key=ver_tuple) if _man_all else None
check('使用说明.txt 里提到的版本 == v%s（不能停在上一版）' % VER,
      _man_top == VER,
      '实际最高=%s（出现过的: %s）' % (_man_top or '无',
                                   '、'.join(sorted(set(_man_all), key=ver_tuple)) or '无'))
if _man_top != VER:
    say('     → 修法：把 使用说明.txt 里落后于 v%s 的版本字样改成 v%s' % (VER, VER))

_cl_txt = read(CHANGELOG) or ''
check('CHANGELOG 里有 v%s 段落' % VER,
      bool(re.search(r'^##\s+v?%s\b' % re.escape(VER), _cl_txt, re.M)),
      '（发布说明从这里取；CHANGELOG 里留有已撤回版本的段落属正常）')

# ══════════════════════════════════════════════════════════════════════════
# ④ version.json 与仓库文件对齐
# ══════════════════════════════════════════════════════════════════════════
say()
say('④ version.json 与仓库文件对齐（自动升级的命根子）')
for _fname in ('core.ps1', 'menu.ps1'):
    _node = (vj.get('scripts') or {}).get(_fname) or {}
    _real = sha(os.path.join(REPO, _fname))
    check('version.json 里 %s 的 sha256 == 仓库文件' % _fname,
          str(_node.get('sha256') or '').upper() == _real,
          'json=%s 实际=%s' % (str(_node.get('sha256'))[:12], _real[:12]))
    _su = str(_node.get('url') or '')
    check('version.json 里 %s 的 url 文件名 == %s' % (_fname, _fname),
          bool(_su) and _su.split('/')[-1] == _fname, _su[-32:] if _su else '空')

# 附件名必须就是本次成品名 —— 改名发布最容易出的错：打包改了名、version.json 还指老附件名，
# 全体老用户静默 404。
_lu = str((vj.get('launcher') or {}).get('url') or '')
check('version.json.launcher.url 文件名 == 成品 exe 文件名（%s）' % EXE_NAME,
      bool(_lu) and os.path.basename(urllib.parse.unquote(_lu.split('/')[-1])) == EXE_NAME,
      'url 尾=%r 成品名=%r' % (_lu.split('/')[-1] if _lu else '', EXE_NAME))

# 成品与升级源必须同一份 —— 需要已打包的 exe；仓库里按规矩不带成品（.gitignore）。
if not os.path.exists(EXE):
    skip('version.json 的 launcher.sha256 / size == 候选 exe',
         '仓库里不带成品 exe（%s）；把打包好的 exe 放在仓库根再跑，或显式传路径' % EXE_NAME)
    skip('候选 exe 的文件版本属性 == %s' % VER, '同上：没有候选 exe')
else:
    _exe_sha, _exe_size = sha(EXE), os.path.getsize(EXE)
    say('     候选 exe: %d B  %s' % (_exe_size, _exe_sha[:16]))
    _node = (vj.get('launcher') or {})
    check('version.json.launcher.sha256 == 候选 exe 指纹',
          str(_node.get('sha256') or '').upper() == _exe_sha,
          'json=%s' % str(_node.get('sha256'))[:16])
    check('version.json.launcher.size == 候选 exe 大小',
          int(_node.get('size') or 0) == _exe_size,
          'json=%s 实际=%s' % (_node.get('size'), _exe_size))
    if HAVE_PS:
        _fv = ps("(Get-Item -LiteralPath '%s').VersionInfo.FileVersion" % EXE)
        check('候选 exe 的文件版本属性 == %s' % VER, _fv == VER, '实际=%s' % _fv)
    else:
        skip('候选 exe 的文件版本属性 == %s' % VER, '本机没有可用的 powershell')

# ══════════════════════════════════════════════════════════════════════════
# ⑤ PowerShell 脚本的 BOM 与语法
# ══════════════════════════════════════════════════════════════════════════
say()
say('⑤ PowerShell 脚本（BOM + 语法）—— 历史上就栽在没 BOM 上')
_ps1 = []
for _root, _dirs, _fs in os.walk(REPO):
    _dirs[:] = [d for d in _dirs if d not in {'.git', '__pycache__', 'dist', 'build', 'build_tmp'}]
    for _f in sorted(_fs):
        if _f.endswith('.ps1'):
            _ps1.append(os.path.join(_root, _f))
_bom_bad = []
for _p in _ps1:
    _raw = open(_p, 'rb').read(3)
    if _raw[:3] != b'\xef\xbb\xbf':
        _bom_bad.append('%s（首三字节=%s）' % (os.path.relpath(_p, REPO), _raw.hex()))
check('全部 .ps1 都是 UTF-8 带 BOM（%d 个文件）' % len(_ps1), not _bom_bad,
      '；'.join(_bom_bad[:3]))
if not HAVE_PS:
    skip('全部 .ps1 语法解析通过', '本机没有可用的 powershell（PS 5.1 只随 Windows 提供）')
else:
    _parse_bad = []
    for _p in _ps1:
        _out = ps("$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile("
                  "'%s',[ref]$null,[ref]$e);if($e -and $e.Count){'ERR: ' + $e[0].Message + "
                  "' @L' + $e[0].Extent.StartLineNumber}else{'OK'}" % _p)
        if _out != 'OK':
            _parse_bad.append('%s: %s' % (os.path.relpath(_p, REPO), (_out or '没输出')[:70]))
    check('全部 .ps1 语法解析通过（%d 个文件）' % len(_ps1), not _parse_bad,
          '；'.join(_parse_bad[:2]))

# ══════════════════════════════════════════════════════════════════════════
# ⑥ 对外文档体检（自包含）
# ══════════════════════════════════════════════════════════════════════════
say()
say('⑥ 对外文档体检（私人邮箱 / 旧名语境 / 署名 / 依赖清单）')
DOCS = ('README.md', '使用说明.txt', 'docs/CHANGELOG.md', 'docs/CONTRIBUTING.md', 'docs/COMPLIANCE.md',
        'docs/SECURITY.md', 'docs/CODE_OF_CONDUCT.md', 'docs/CODE_SIGNING_POLICY.md',
        'docs/README_EN.md', '.github/PULL_REQUEST_TEMPLATE.md')
_texts = {}
for _f in DOCS:
    _t = read(os.path.join(REPO, _f))
    if _t is not None:
        _texts[_f] = _t
check('对外文档读得到（%d 份）' % len(DOCS), len(_texts) == len(DOCS),
      '缺: %s' % '、'.join(f for f in DOCS if f not in _texts))

# 私人邮箱：先把正文归一化（去空白与零宽字符、全角转半角）再匹配 ——
# 旧版直接抓正则，**抓不到"加空格规避"的写法**（README 里真实存在过 `75219857 @qq.com`）。
FULLWIDTH = {0x3000: ' ', 0xFF20: '@', 0xFF0E: '.', 0xFF0B: '+', 0xFF0D: '-'}
for _i in range(0xFF10, 0xFF1A):
    FULLWIDTH[_i] = chr(_i - 0xFF10 + ord('0'))
for _i in range(0xFF21, 0xFF3B):
    FULLWIDTH[_i] = chr(_i - 0xFF21 + ord('A'))
for _i in range(0xFF41, 0xFF5B):
    FULLWIDTH[_i] = chr(_i - 0xFF41 + ord('a'))
MAIL_OK_DOMAINS = ('github.com', 'gitee.com', 'users.noreply.github.com',
                   'signpath.org', 'signpath.io')
MAIL_BARE_KEYWORDS = ('qq.com', 'foxmail', 'gmail', '163.com', '126.com',
                      'outlook.com', 'hotmail', 'sina.com', 'aliyun.com')


def flatten(t):
    return ''.join(FULLWIDTH.get(ord(c), c)
                   for c in t if c not in ' \t\r\n\u00a0\u200b\u200c\u200d\ufeff')


for _f, _t in sorted(_texts.items()):
    _flat = flatten(_t)
    _mails = [m for m in re.findall(r'[\w.+-]+@[\w-]+\.[\w.]+', _flat)
              if not any(d in m.lower() for d in MAIL_OK_DOMAINS)]
    check('%s 里没有私人邮箱（已归一化空格/全角；允许 GitHub noreply 与签名服务域名）' % _f,
          not _mails, str(_mails[:3]))
_bare = []
for _f, _t in sorted(_texts.items()):
    for _k in MAIL_BARE_KEYWORDS:
        if _k in flatten(_t).lower():
            _bare.append('%s: %s' % (_f, _k))
check('对外文档里没有私人邮箱域名关键字（连 @ 被拆掉也躲不过）', not _bare,
      '；'.join(_bare[:3]))

# 旧名只在"兼容/更名说明"的语境里出现；**任何链接里不得出现旧名**。
for _f in ('README.md', '使用说明.txt'):
    _bad = []
    for _ln in (_texts.get(_f) or '').splitlines():
        if LEGACY_NAME in _ln:
            if re.search(r'https?://\S*' + re.escape(LEGACY_NAME), _ln):
                _bad.append('链接带旧名: ' + _ln.strip()[:60])
            elif not any(q in _ln for q in LEGACY_QUALIFIERS):
                _bad.append('裸旧名: ' + _ln.strip()[:60])
    check('%s 里旧名（%s）只出现在兼容说明里' % (_f, LEGACY_NAME), not _bad,
          '；'.join(_bad[:2]))

check('README 里有署名「海风（kele551）」与仓库地址',
      ('海风（kele551）' in _rm) and ('gitee.com/kele551/ms-wallpaper-assistant' in _rm))
check('使用说明.txt 里有署名与仓库地址',
      ('海风（kele551）' in _man) and ('gitee.com/kele551/ms-wallpaper-assistant' in _man))

_req = read(os.path.join(REPO, 'requirements.txt')) or ''
_lack = [d for d in ('pyinstaller', 'requests') if d.lower() not in _req.lower()]
check('requirements.txt 列出打包与发版工具依赖（pyinstaller / requests）', not _lack,
      '缺: %s' % '、'.join(_lack))
check('requirements.txt 写明运行本体零第三方依赖',
      '不需要安装任何第三方' in _req or '零第三方' in _req)
check('README 有「第三方组件与许可」小节', '第三方组件与许可' in _rm)
check('docs/CONTRIBUTING.md 写明发版前必须跑本自检（tools/preflight_release.py）',
      'preflight_release.py' in (_texts.get('docs/CONTRIBUTING.md') or ''),
      '（贡献指南里要有这条，别人才知道有门可跑）')
skip('对外文案红线词 0 命中',
     'CONTRIBUTING「对外文案有禁用词清单」一节明确要求**不在仓库里逐词列举**'
     '（清单自身会被内容扫描命中），所以这条判据不放进仓库脚本；'
     '维护者工作区有专门的检查清单')

# ══════════════════════════════════════════════════════════════════════════
# ⑦ 测试套件（需要已打包的成品 exe）
# ══════════════════════════════════════════════════════════════════════════
say()
say('⑦ 端到端测试套件 tests/test_all.py（需要已打包的成品 exe）')
_tests = os.path.join(REPO, 'tests', 'test_all.py')
if not os.path.exists(EXE):
    skip('tests/test_all.py 全绿',
         '仓库里不带成品 exe（%s）—— 先 python build-exe.py --release 再跑这一节' % EXE_NAME)
elif not os.path.exists(_tests):
    check('tests/test_all.py 存在', False, _tests)
else:
    say('     正在跑 tests/test_all.py（可能要一两分钟，它只在临时目录里折腾）…')
    try:
        _r = subprocess.run([sys.executable, _tests, EXE], capture_output=True, text=True,
                            encoding='utf-8', errors='replace', cwd=REPO, timeout=900)
        _rc = _r.returncode
        _tail = ((_r.stdout or '') + (_r.stderr or '')).strip().splitlines()[-8:]
    except Exception as _e:
        _rc, _tail = -1, ['%s: %s' % (type(_e).__name__, _e)]
    check('tests/test_all.py 全绿', _rc == 0, '退出码=%s' % _rc)
    if _rc != 0:
        for _l in _tail:
            say('     | %s' % _l)

# ══════════════════════════════════════════════════════════════════════════
# ⑧ 链接与徽章的可访问性（需要联网；不可用就 SKIP）
# ══════════════════════════════════════════════════════════════════════════
say()
say('⑧ 链接与徽章可访问性（README 里的 http(s) 链接，含徽章图）')


def http_status(url, timeout=15):
    """只取状态码。

    两个真实的坑（都踩过，才写成这样）：
      · README 里的徽章地址带**原始中文**（`img.shields.io/badge/形态-单文件exe-blue`），
        浏览器会自动百分号编码，urllib 不会 —— 直接请求会抛 UnicodeEncodeError，
        于是好好的徽章被误报成"主机不可达"。所以先 quote 一遍。
      · GitHub 对某些 HTML 路径的 **HEAD** 回 404，浏览器里其实是能打开的
        （实测 /stargazers 就是），拿 HEAD 的 404 当死链会假红。所以 2xx 之外的
        结果一律再用 GET 确认一次，以 GET 为准。
    """
    def _one(method):
        u = urllib.parse.quote(url, safe=':/?#[]@!$&\'()*+,;=%~')
        try:
            req = urllib.request.Request(u, method=method,
                                         headers={'User-Agent': UA, 'Accept': '*/*'})
            if method == 'GET':
                req.add_header('Range', 'bytes=0-0')
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return getattr(r, 'status', 200), ''
        except urllib.error.HTTPError as e:
            return e.code, ''
        except Exception as e:
            return None, type(e).__name__

    st, note = _one('HEAD')
    if st is not None and st < 400:
        return st, ''
    st2, note2 = _one('GET')
    if st2 is not None:
        return st2, ''
    return st, (note or note2)


def net_alive():
    """先探一个"一直通"的域名（api.github.com）判断这台机器有没有网。"""
    return http_status('https://api.github.com')[0] is not None


_LINK_LIMIT_OTHER = 18      # 普通链接（仓库页/发行版页/下载链接…）最多查这么多
_LINK_LIMIT_BADGE = 8       # 徽章图最多查这么多（README 里往往有二十几个，全查既慢又没必要）
_BADGE_RX = re.compile(r'(shields\.io|hits\.sh|\.svg(\?|$))', re.I)


def pick_links(urls):
    """挑要检查的链接：**先普通链接、后徽章**，各自限量。

    不这么挑的话，README 开头的二十几个徽章会把名额全占了，真正要命的
    下载链接 / 发行版页 / 仓库页一个都查不到。
    """
    badges = [u for u in urls if _BADGE_RX.search(u)]
    others = [u for u in urls if u not in badges]
    return others[:_LINK_LIMIT_OTHER] + badges[:_LINK_LIMIT_BADGE]


if NO_LINKS:
    skip('README 链接与徽章可访问性', '已按 %s 跳过' % ('--offline' if OFFLINE else '--no-links'))
elif not net_alive():
    skip('README 链接与徽章可访问性',
         '本机网络不可用（连 api.github.com 都不通）—— 请在能联网的机器上重跑，或加 --no-links')
else:
    _urls = []
    # README 里的地址有三种写法：HTML 属性（src="..."）、Markdown 链接、以及**行内代码**
    # （`` `https://...` ``）。最后那种如果直接抓，会把结尾的反引号和紧跟的中文说明
    # 一起吃进来 → 变成一条不存在的地址、假报死链。办法：把反引号一律换成引号，
    # 让正则的"引号/空白即终止"规则一并管住它。
    for _u in re.findall(r'https?://[^\s"\'<>\)\]]+', _rm.replace('`', '"')):
        _u = _u.rstrip('.,;:、。）】`"\'')
        # 非徽章站点的地址一定是纯 ASCII（徽章那几种确实会把中文写在路径里），
        # 所以截到第一个中日韩字符为止：既保住徽章，又不会把后面的中文说明吃进来。
        if not re.search(r'(shields\.io|hits\.sh)', _u):
            _mm = re.match(r'https?://[^\u2e80-\u9fff\u3000-\u303f\uff00-\uffef]+', _u)
            if _mm:
                _u = _mm.group(0).rstrip('.,;:、。）】`"\'')
        if _u and _u not in _urls:
            _urls.append(_u)
    _total_urls = len(_urls)
    _urls = pick_links(_urls)
    if _total_urls > len(_urls):
        say('     （README 共 %d 条链接，本次按"先普通链接、后徽章"的上限查 %d 条）'
            % (_total_urls, len(_urls)))
    _dead, _netfail = [], []
    for _i, _u in enumerate(_urls):
        _st, _note = http_status(_u)
        # GitHub 对**脚本请求**的这几个页面一律回 404（实测连 torvalds/linux/stargazers
        # 都是 404），浏览器里其实打得开 —— 拿它判死链会假红，只打印、不计红。
        _bot404 = bool(re.search(r'github\.com/[^/]+/[^/]+/(stargazers|watchers|graphs/.*)$', _u))
        if _st in (404, 410) and _bot404:
            say('     · HTTP %s  %s（GitHub 对脚本请求的已知 404）' % (_st, _u))
        elif _st in (404, 410):
            _dead.append('%s -> HTTP %s' % (_u, _st))
            say('     · HTTP %s  %s' % (_st, _u))
        elif _st is None:
            _netfail.append('%s -> %s' % (_u, _note))
            say('     · 网络失败(%s)  %s' % (_note, _u))
        else:
            say('     · HTTP %s  %s' % (_st, _u))
        # 平台限速：Gitee 侧间隔拉到 3 秒（2026-10-08 密集抓 Gitee 自己抓出过 451）
        if _i < len(_urls) - 1:
            time.sleep(3.0 if 'gitee.com' in _u else 0.5)
    check('README 里 %d 条链接都不存在 404/410（这些才是死链）' % len(_urls), not _dead,
          '；'.join(_dead[:3]))
    check_warn('README 里的链接主机都连得上（有没有 DNS/连接层面的失效）', not _netfail,
               '；'.join(_netfail[:3]))

# ══════════════════════════════════════════════════════════════════════════
# ⑨ 线上升级源版本号对齐（只算 WARN）
# ══════════════════════════════════════════════════════════════════════════
say()
say('⑨ 线上升级源版本号对齐（只警告，不阻断：发布前本来就会"仓库比线上新"）')
if OFFLINE:
    skip('线上升级源 version.json 的版本号', '已按 --offline 跳过')
elif not net_alive():
    skip('线上升级源 version.json 的版本号', '本机网络不可用')
else:
    def _remote_ver(label, url, headers=None):
        try:
            req = urllib.request.Request(url, headers=headers or {'User-Agent': UA})
            with urllib.request.urlopen(req, timeout=20) as r:
                j = json.loads(r.read().decode('utf-8', 'replace'))
            if isinstance(j, dict) and j.get('content'):
                return json.loads(base64.b64decode(j['content']).decode('utf-8', 'replace')).get('version')
            return (j or {}).get('version')
        except Exception as e:
            check_warn('%s 上的 version.json 能读到' % label, False,
                       '%s（网络抽风/还没发布都可能，属正常）' % type(e).__name__)
            return None

    _ghv = _remote_ver('GitHub(main)',
                       'https://api.github.com/repos/kele551/ms-wallpaper-assistant/contents/version.json?ref=main',
                       headers={'User-Agent': UA, 'Accept': 'application/vnd.github+json'})
    if _ghv:
        check_warn('GitHub main 的 version.json 版本 == 本地 v%s' % VER,
                   str(_ghv).lstrip('v') == VER,
                   '线上=%s 本地=%s（发布前"仓库更新"属正常）' % (_ghv, VER))
    time.sleep(3.0)   # Gitee 限速：任何两次请求之间 ≥3 秒
    _gtv = _remote_ver('Gitee(main)',
                       'https://gitee.com/api/v5/repos/kele551/ms-wallpaper-assistant/contents/version.json?ref=main')
    if _gtv:
        check_warn('Gitee main 的 version.json 版本 == 本地 v%s' % VER,
                   str(_gtv).lstrip('v') == VER, '线上=%s 本地=%s' % (_gtv, VER))

finish()
