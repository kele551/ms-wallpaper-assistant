# -*- coding: utf-8 -*-
"""
一键打包: 把 launcher.py + core.ps1 + menu.ps1 + 使用说明.txt + 图标
打成一个单文件绿色 exe。

用法
----
    python build-exe.py              只出一份 (日常用)
    python build-exe.py --release    额外再出一份带版本号的 (要往 GitHub 发的时候)

前置条件
--------
    Python 3.9 以上, 并且装过 pyinstaller:
        python -m pip install pyinstaller

产物
----
    微软壁纸助手.exe       固定名字, 日常就用这一份。
                          「开机自动换壁纸」和桌面快捷方式都指向这个名字,
                          以后升级直接同名覆盖, 链接不会断。

    微软壁纸助手-vX.Y.Z.exe  只有加 --release 时才生成。名字带版本号,
                             是往 GitHub Release 上传用的那一份。
                             (平时不生成, 免得目录里摆两个看不出该点哪个。)

    --release 还会打一个发给客户的 zip (名字纯 ASCII, GitHub 不会因为中文
    把文件名剥掉), 里面就两样: 微软壁纸助手.exe + 使用说明.txt。
    客户下载下来解压, 双击 exe 就能用 —— 不用挑, 不用装, 不用管别的。
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
APP_NAME = '微软壁纸助手'
PAYLOAD_FILES = ['core.ps1', 'menu.ps1', '使用说明.txt', '微软壁纸助手.ico']
ICON = '微软壁纸助手.ico'


def read_version():
    """版本号以 launcher.py 里的 VERSION 为唯一来源, 免得三处各写各的。"""
    src = os.path.join(HERE, 'launcher.py')
    with open(src, 'r', encoding='utf-8') as f:
        m = re.search(r"^VERSION\s*=\s*['\"]([^'\"]+)['\"]", f.read(), re.M)
    if not m:
        raise SystemExit('launcher.py 里找不到 VERSION, 没法确定版本号')
    return m.group(1)


def make_version_file(path, version):
    """给 exe 写一份 Windows 版本资源: 右键 - 属性 - 详细信息里能看到版本号。

    语言 0804 = 简体中文, 代码页 1200 = Unicode。
    """
    parts = [int(x) for x in re.findall(r'\d+', version)]
    while len(parts) < 4:
        parts.append(0)
    vtuple = '({})'.format(', '.join(str(p) for p in parts[:4]))
    text = """# UTF-8
VSVersionInfo(
  ffi=FixedFileInfo(
    filevers={vt}, prodvers={vt},
    mask=0x3f, flags=0x0, OS=0x40004, fileType=0x1, subtype=0x0, date=(0, 0)
  ),
  kids=[
    StringFileInfo([
      StringTable(
        '080404b0',
        [
          StringStruct('CompanyName', 'kele551'),
          StringStruct('FileDescription', '微软壁纸助手 - 必应每日一图 + Windows 聚焦'),
          StringStruct('FileVersion', '{v}'),
          StringStruct('InternalName', 'MSWallpaperAssistant'),
          StringStruct('LegalCopyright', 'MIT License'),
          StringStruct('OriginalFilename', '微软壁纸助手.exe'),
          StringStruct('ProductName', '微软壁纸助手'),
          StringStruct('ProductVersion', '{v}')
        ]
      )
    ]),
    VarFileInfo([VarStruct('Translation', [2052, 1200])])
  ]
)
""".format(vt=vtuple, v=version)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)


def main():
    missing = [f for f in PAYLOAD_FILES + ['launcher.py'] if not os.path.isfile(os.path.join(HERE, f))]
    if missing:
        print('缺文件, 没法打包: ' + ', '.join(missing))
        return 1

    version = read_version()
    print('版本号: ' + version)

    work = tempfile.mkdtemp(prefix='mwa-build-')
    try:
        payload = os.path.join(work, 'payload')
        os.makedirs(payload, exist_ok=True)
        for f in PAYLOAD_FILES:
            shutil.copy2(os.path.join(HERE, f), os.path.join(payload, f))
        shutil.copy2(os.path.join(HERE, 'launcher.py'), os.path.join(work, 'launcher.py'))

        vfile = os.path.join(work, 'file_version.txt')
        make_version_file(vfile, version)

        cmd = [
            sys.executable, '-m', 'PyInstaller',
            '--noconfirm', '--onefile', '--windowed',
            '--icon', os.path.join(HERE, ICON),
            '--version-file', vfile,
            '--add-data', 'payload;payload',
            '--name', APP_NAME,
            '--distpath', os.path.join(work, 'dist'),
            '--workpath', os.path.join(work, 'build'),
            '--specpath', work,
            'launcher.py',
        ]
        print('正在打包, 大概半分钟...')
        r = subprocess.run(cmd, cwd=work)
        if r.returncode != 0:
            print('打包失败。')
            return r.returncode

        out = os.path.join(work, 'dist', APP_NAME + '.exe')
        if not os.path.isfile(out):
            print('打包完了但没找到产物: ' + out)
            return 1
        # 默认只出固定名这一份 -- 拿到手不用挑, 双击就是它。
        # 带版本号那份只有 --release 时才出, 专供 GitHub Release 上传。
        plain = os.path.join(HERE, APP_NAME + '.exe')
        shutil.copy2(out, plain)
        outs = [plain]
        if '--release' in sys.argv:
            tagged = os.path.join(HERE, '{}-v{}.exe'.format(APP_NAME, version))
            shutil.copy2(out, tagged)
            outs.append(tagged)
            # 发给客户的 zip: 解压后双击 exe 就能用, 里面不放任何需要挑的东西
            zp = os.path.join(HERE, 'MSWallpaperAssistant-v{}.zip'.format(version))
            with zipfile.ZipFile(zp, 'w', zipfile.ZIP_DEFLATED) as z:
                z.write(tagged, APP_NAME + '.exe')          # 包内用固定名, 客户不用挑
                z.write(os.path.join(HERE, '使用说明.txt'), '使用说明.txt')
            outs.append(zp)
        print('')
        for dst in outs:
            print('好了: ' + dst)
        print('大小: {:.1f} MB'.format(os.path.getsize(outs[0]) / 1024.0 / 1024.0))
        if len(outs) == 1:
            print('(只有一份。要往 GitHub 发的时候跑: python build-exe.py --release)')
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
