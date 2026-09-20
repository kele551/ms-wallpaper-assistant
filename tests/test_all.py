# -*- coding: utf-8 -*-
"""微软壁纸助手 - 打包后必跑的一套端到端测试.

用法:
    python _test_all.py            测 F:\wp-src\微软壁纸助手.exe
    python _test_all.py <其他exe>

覆盖:
   1. 全新安装: exe 旁边不许多出任何东西, 数据必须落在 %LOCALAPPDATA%
   2. 旧数据搬迁: exe 旁边的旧数据要自动搬走, 且搬完字节一致
   3. 便携模式: portable.txt 时数据跟着 exe 走
   4. payload 释放: core.ps1 / menu.ps1 / 说明 / ico 与源码逐字节一致
   5. 版本资源: exe 里写的版本号要和 launcher.py 里的一致
   6. 图标: exe 内嵌的大图要和源码 .ico 里那张是同一张
"""
import hashlib
import os
import shutil
import struct
import subprocess
import sys
import tempfile

sys.stdout.reconfigure(encoding='utf-8')

SRC = r'F:\wp-src'
EXE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(SRC, '微软壁纸助手.exe')
DATA_DIR_NAME = '微软壁纸助手数据'
PAYLOAD = ['core.ps1', 'menu.ps1', '使用说明.txt', '微软壁纸助手.ico', '刷新图标缓存.bat']

ok_all = True


def md5f(p):
    return hashlib.md5(open(p, 'rb').read()).hexdigest()


def check(name, cond, extra=''):
    global ok_all
    ok_all = ok_all and bool(cond)
    print(('  [通过] ' if cond else '  [失败] ') + name + (('  ' + str(extra)) if extra else ''))


def title(t):
    print('-' * 70)
    print(t)


def run_exe(exe, args, lad):
    env = dict(os.environ)
    env['LOCALAPPDATA'] = lad
    r = subprocess.run([exe] + args, env=env, capture_output=True,
                       timeout=120, creationflags=0x08000000)
    return r


root = tempfile.mkdtemp(prefix='bwexe_')
print('测试 exe:', EXE)
print('临时目录:', root)

# ============ 1. 全新安装 ============
title('1. 全新安装 -> 数据落 LOCALAPPDATA, exe 旁边不多出任何东西')
lad1 = os.path.join(root, 'lad1'); os.makedirs(lad1)
prog1 = os.path.join(root, 'prog1'); os.makedirs(prog1)
exe1 = os.path.join(prog1, '微软壁纸助手.exe')
shutil.copy2(EXE, exe1)
r = run_exe(exe1, ['--stop'], lad1)
check('exe 退出码 0', r.returncode == 0, r.returncode)
want1 = os.path.join(lad1, '微软壁纸助手')
check('数据目录建在 LOCALAPPDATA 下', os.path.isdir(want1), want1)
check('exe 旁边没有数据目录', not os.path.exists(os.path.join(prog1, DATA_DIR_NAME)))
check('exe 旁边只有 exe 自己', sorted(os.listdir(prog1)) == ['微软壁纸助手.exe'], sorted(os.listdir(prog1)))
check('daemon.stop 写在数据目录里(不在 exe 旁)', os.path.isfile(os.path.join(want1, 'daemon.stop')))

# ============ 2. payload 释放 ============
title('2. payload 释放 -> 与源码逐字节一致')
for f in PAYLOAD:
    a = os.path.join(want1, f)
    b = os.path.join(SRC, f)
    check('%-16s 与源码一致' % f, os.path.isfile(a) and md5f(a) == md5f(b))
ver = open(os.path.join(want1, '.version'), encoding='utf-8').read().strip()
launcher_ver = ''
for line in open(os.path.join(SRC, 'launcher.py'), encoding='utf-8'):
    if line.startswith('VERSION ='):
        launcher_ver = line.split("'")[1]
        break
check('.version 与 launcher.py 一致', ver == launcher_ver, '%s / %s' % (ver, launcher_ver))
txt = open(os.path.join(want1, 'launcher.txt'), encoding='utf-8').read().strip()
check('launcher.txt 指向当前 exe', os.path.abspath(txt) == os.path.abspath(exe1), txt)

# ============ 3. 旧数据搬迁 ============
title('3. exe 旁边有旧数据 -> 自动搬走, 内容一致, 旧目录清掉')
lad3 = os.path.join(root, 'lad3'); os.makedirs(lad3)
prog3 = os.path.join(root, 'prog3'); os.makedirs(prog3)
exe3 = os.path.join(prog3, '微软壁纸助手.exe')
shutil.copy2(EXE, exe3)
old = os.path.join(prog3, DATA_DIR_NAME); os.makedirs(old)
open(os.path.join(old, 'config.json'), 'w', encoding='utf-8').write('{"migrated":true}')
open(os.path.join(old, 'state.json'), 'w', encoding='utf-8').write('{"q":[7,8]}')
open(os.path.join(old, 'core.ps1'), 'w', encoding='utf-8').write('老版本的脚本')
r = run_exe(exe3, ['--stop'], lad3)
check('exe 退出码 0', r.returncode == 0, r.returncode)
want3 = os.path.join(lad3, '微软壁纸助手')
check('config.json 搬过来且内容一致',
      os.path.isfile(os.path.join(want3, 'config.json'))
      and open(os.path.join(want3, 'config.json'), encoding='utf-8').read() == '{"migrated":true}')
check('state.json 搬过来且内容一致',
      os.path.isfile(os.path.join(want3, 'state.json'))
      and open(os.path.join(want3, 'state.json'), encoding='utf-8').read() == '{"q":[7,8]}')
check('旧版脚本没被搬(新版重放)',
      open(os.path.join(want3, 'core.ps1'), encoding='utf-8', errors='replace').read() != '老版本的脚本')
check('exe 旁旧目录已清掉', not os.path.exists(old))
check('exe 旁只剩 exe', sorted(os.listdir(prog3)) == ['微软壁纸助手.exe'], sorted(os.listdir(prog3)))

# ============ 4. 便携模式 ============
title('4. 便携模式 -> 数据跟着 exe 走, 不搬进 LOCALAPPDATA')
lad4 = os.path.join(root, 'lad4'); os.makedirs(lad4)
prog4 = os.path.join(root, 'prog4'); os.makedirs(prog4)
exe4 = os.path.join(prog4, '微软壁纸助手.exe')
shutil.copy2(EXE, exe4)
pd = os.path.join(prog4, DATA_DIR_NAME); os.makedirs(pd)
open(os.path.join(pd, 'portable.txt'), 'w', encoding='utf-8').write('')
r = run_exe(exe4, ['--stop'], lad4)
check('exe 退出码 0', r.returncode == 0, r.returncode)
check('数据留在 exe 旁边', os.path.isfile(os.path.join(pd, '.version')))
check('LOCALAPPDATA 里没建数据目录', not os.path.isdir(os.path.join(lad4, '微软壁纸助手')))

# ============ 5. 版本资源 ============
title('5. exe 版本资源')
try:
    import ctypes
    from ctypes import wintypes
    V = ctypes.windll.version
    size = V.GetFileVersionInfoSizeW(EXE, None)
    buf = ctypes.create_string_buffer(size)
    V.GetFileVersionInfoW(EXE, 0, size, buf)
    got = ''
    for k in ['FileVersion', 'ProductName']:
        lpu = ctypes.c_void_p(); lpc = wintypes.UINT()
        if V.VerQueryValueW(buf, '\\StringFileInfo\\080404b0\\' + k, ctypes.byref(lpu), ctypes.byref(lpc)):
            val = ctypes.wstring_at(lpu, lpc.value - 1)
            print('     %-14s %s' % (k, val))
            if k == 'FileVersion':
                got = val
    check('FileVersion 与源码版本一致', got == launcher_ver, '%s / %s' % (got, launcher_ver))
except Exception as e:
    check('读版本资源', False, e)

# ============ 6. 图标 ============
title('6. exe 内嵌图标 vs 源码 .ico')


def png_chunks(blob):
    """把数据里所有完整的 PNG 抠出来"""
    out = []
    i = 0
    while True:
        i = blob.find(b'\x89PNG\r\n\x1a\n', i)
        if i < 0:
            break
        j = blob.find(b'IEND\xaeB`\x82', i)
        if j < 0:
            break
        out.append(blob[i:j + 8])
        i = j + 8
    return out


exe_png = png_chunks(open(EXE, 'rb').read())
ico_png = png_chunks(open(os.path.join(SRC, '微软壁纸助手.ico'), 'rb').read())
exe_md5 = set(hashlib.md5(x).hexdigest() for x in exe_png)
ico_md5 = set(hashlib.md5(x).hexdigest() for x in ico_png)
check('exe 里找得到图标 PNG 帧', bool(exe_png), '%d 个' % len(exe_png))
check('ico 里有 %d 帧' % len(ico_png), len(ico_png) >= 1)
# exe 里除了图标还有别的 PNG (PyInstaller 自己带的), 所以不能比"最大的那个",
# 要判断的是: 源码 ico 的每一帧都应该原样出现在 exe 里
missing = ico_md5 - exe_md5
check('ico 的每一帧都原样进了 exe', not missing,
      ('缺 %d 帧' % len(missing)) if missing else ('%d 帧全在' % len(ico_md5)))

print('-' * 70)
print('全部通过' if ok_all else '有用例失败 —— 别发布')
shutil.rmtree(root, ignore_errors=True)
sys.exit(0 if ok_all else 1)
