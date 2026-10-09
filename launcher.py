# -*- coding: utf-8 -*-
"""
微软壁纸助手 - 绿色单文件版启动器。

作者: 海风（kele551）   https://gitee.com/kele551/ms-wallpaper-assistant

设计要点
--------
* 本 exe 是 **GUI 子系统**（PyInstaller --windowed）。所以:
    - 双击           -> 自己 AllocConsole() 开一个控制台, 显示菜单。
                        没有"先建控制台再隐藏"的闪窗问题。
    - 开机后台自启    -> 完全不创建控制台, 一个窗口都不会闪。

* 数据放用户目录 (%LOCALAPPDATA%\\微软壁纸助手), 程序 exe 旁边**不放任何东西** ——
  放在 Program Files 也不会在旁边生出一个数据文件夹。删掉那个目录 = 彻底卸载,
  不写自启动注册表项、不装服务与计划任务、不需要管理员。
  (唯一的例外与对外文档一致: 设壁纸时按 Windows 标准做法调 SystemParametersInfo,
   填充方式 WallpaperStyle / TileWallpaper 写在 HKCU\\Control Panel\\Desktop,
   写前先比对, 值相同就不写。)
  真要带着数据一起走 (U 盘), 在数据目录里放一个空的 portable.txt 就切回"跟着 exe 走"。

* 首次运行会把内嵌的 core.ps1 / menu.ps1 释放到数据目录, 并记录版本号;
  换新版 exe 后会自动重新释放 (按版本号比对)。
  从旧版升上来时, exe 旁边那份旧数据会自动搬进用户目录 (复制+校验后才删旧的)。

命令行
------
  (无参数)     打开菜单
  --daemon     后台常驻, 按 config.json 的 cycle_minutes 自动换壁纸 (给"开机自启"用)
  --once       不常驻, 只跑一轮 (调试用)
  --stop       通知正在跑的 --daemon 退出
"""
import io
import json
import msvcrt
import os
import shutil
import hashlib
import subprocess
import sys
import time
import datetime
import ctypes

VERSION = '2.0.10'
APP_NAME = '微软壁纸助手'
DATA_DIR_NAME = '微软壁纸助手数据'
PAYLOAD_FILES = ['core.ps1', 'menu.ps1', '使用说明.txt', '微软壁纸助手.ico']
MUTEX_NAME = 'Local\\MSWallpaperAssistantDaemon'
CREATE_NO_WINDOW = 0x08000000
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value

PS_EXE = os.path.join(
    os.environ.get('SystemRoot', r'C:\Windows'),
    r'System32\WindowsPowerShell\v1.0\powershell.exe')

K32 = ctypes.windll.kernel32
# GetTickCount 是 32 位、开机满 49.7 天回绕一次。ctypes 默认按 c_int 解释返回值,
# 超过 2^31(约 24.85 天)就变成负数 —— 减出负值再被 max(0, ...) 夹成 0, 于是"永远判人在",
# 空闲检测(人不在就不换图)整个静默失效(审查 C1)。这里先声明成无符号, 再用
# ticks_diff_ms 按 2^32 取模算差值, 双保险。
K32.GetTickCount.restype = ctypes.c_uint32


# ---------------------------------------------------------------- 路径
def here():
    """exe 所在目录 (源码直跑时是脚本目录)。"""
    if getattr(sys, 'frozen', False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


def payload_src():
    base = getattr(sys, '_MEIPASS', None) or here()
    return os.path.join(base, 'payload')


def writable(d):
    try:
        os.makedirs(d, exist_ok=True)
        t = os.path.join(d, '.wtest_' + str(os.getpid()))
        with open(t, 'w') as f:
            f.write('x')
        os.remove(t)
        return True
    except Exception:
        return False


# 程序自己重新生成的文件 —— 搬家时不用搬, 新版会自动重放 / 重写
GENERATED = set(PAYLOAD_FILES) | {'.version', '.files.json', 'launcher.txt'}
# 老布局 (数据直接摊在 exe 旁边) 时, 清理只认这些名字, 绝不碰别的 —— exe 也在那个目录里
LEGACY_FILES = {'config.json', 'state.json', 'wallpaper.log', 'desktop_shortcut.json',
                'daemon.stop', '.version', '.files.json', 'launcher.txt'} | set(PAYLOAD_FILES)


def _md5(p):
    h = hashlib.md5()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(65536), b''):
            h.update(b)
    return h.hexdigest()


# ── 不阻止系统睡眠 (2026-10-05 有用户反馈「用完之后电脑不进睡眠」) ──────────────
# 本程序从来没有调用过 SetThreadExecutionState 去要「保持唤醒」, 也没有改过用户的电源设置;
# 这里再显式声明一次 ES_CONTINUOUS, 作用是把本线程上**可能**被第三方库设过的唤醒请求清掉
# (纯声明, 不占资源)。以后再有人加相关调用, 这一句也能兜住。
ES_CONTINUOUS = 0x80000000


def keep_sleep_allowed():
    """告诉 Windows: 本线程不要求系统保持唤醒。调用成功返回 True。"""
    try:
        return bool(K32.SetThreadExecutionState(ctypes.c_uint(ES_CONTINUOUS)))
    except Exception:
        return False


# ── 用户是不是在电脑前（空闲检测） ──────────────────────────────────────────────
# 2026-10-07 用户反馈「用了这个工具后电脑无法进入睡眠」。本程序不申请任何唤醒请求
# （见上面的 keep_sleep_allowed），但"没人看着也照点换壁纸"这件事本身会在系统准备
# 休眠的节骨眼上插一脚：拉起 PowerShell、下载图片、并向所有窗口广播系统设置变更。
# 所以新规矩：**用户离开超过 IDLE_SKIP_S 就不换图，等他回来再换** ——
# 人不在，换了也没人看；顺带把这段时间的动静降到最低。
IDLE_SKIP_S = 600       # 10 分钟没有任何键鼠输入 -> 视为"人不在"
AWAY_RECHECK_S = 300    # 人不在时每 5 分钟回来看一眼（回来就立刻换）
# 逃生口: 想让它"人不在也照换"(例如拿它当展示屏), 把环境变量设小或设 0 即可:
#   MWA_IDLE_SKIP_S=0   -> 永不因空闲跳过
try:
    _env_skip = (os.environ.get('MWA_IDLE_SKIP_S') or '').strip()
    if _env_skip.isdigit():
        IDLE_SKIP_S = int(_env_skip)
except Exception:
    pass


class _LASTINPUTINFO(ctypes.Structure):
    _fields_ = [('cbSize', ctypes.c_uint), ('dwTime', ctypes.c_uint)]


TICK_MASK = 0xFFFFFFFF


def ticks_diff_ms(now_tick, then_tick):
    """两个 32 位 tick 计数之间过了多少毫秒 —— 回绕安全（纯函数，好测）。

    GetTickCount 和 GetLastInputInfo.dwTime 都是 32 位、每 49.7 天回绕一次。
    直接相减的话, 开机满 24.85 天(2^31 毫秒)之后 ctypes 会给出负数, 被 max(0, ...)
    夹成 0 —— 于是"永远判人在", 空闲检测静默失效(审查 C1)。
    按 2^32 取模得到的才是真实差值(只要两次采样间隔远小于 49.7 天, 实际就是几十秒)。
    """
    return (int(now_tick) - int(then_tick)) & TICK_MASK


def idle_seconds():
    """距上次键鼠输入过了多少秒。取不到就返回 0（= 当作人在，宁可正常换图）。

    注意: GetLastInputInfo 在 **user32.dll**, 不在 kernel32 ——
    2026-10-07 一开始调错了 DLL, 取不到值退化成 0, 等于这个功能没生效（单测抓出来的）。
    注意 2: 差值走 ticks_diff_ms（回绕安全），不要图省事直接相减 —— 那是 C1 那个坑。
    """
    try:
        li = _LASTINPUTINFO()
        li.cbSize = ctypes.sizeof(li)
        if not ctypes.windll.user32.GetLastInputInfo(ctypes.byref(li)):
            return 0.0
        return ticks_diff_ms(K32.GetTickCount(), li.dwTime) / 1000.0
    except Exception:
        return 0.0


def should_skip_swap(idle, threshold=None):
    """纯函数（好测）：空闲到阈值就不换图。

    阈值 <= 0 表示**关闭**这个功能（人不在也照换）—— 别写成 `idle >= 0`，
    那会变成"永远跳过"，正好反了（这个坑也是单测抓出来的）。
    """
    t = IDLE_SKIP_S if threshold is None else threshold
    if t <= 0:
        return False
    return idle >= t


DESKTOP_SWITCHDESKTOP = 0x0100


LOCK_PROBE_FAILS = 3      # 连续几次拿不到输入桌面, 就认定"这个会话判断不了锁屏"
_lock_fail = 0            # 连续失败次数（守护进程长跑时才有意义）
_lock_degraded = False    # 是否已经降级成"当作没锁屏"（给日志用）


def _open_input_desktop():
    """单独拎出来是为了能单测：测试里把它换掉就能模拟 API 一直失败。"""
    return ctypes.windll.user32.OpenInputDesktop(0, False, DESKTOP_SWITCHDESKTOP)


def session_locked():
    """当前会话是不是锁屏了（锁屏 = 肯定没人在看）。

    锁屏时 OpenInputDesktop 打不开（进不去当前输入桌面）-> 拿不到句柄。
    但拿不到句柄还有另一种可能: 这个会话根本判断不了锁屏(非交互会话、权限受限、远程/服务场景)。
    原来是"拿不到句柄一律当锁屏", 于是那种环境下程序**永远不换壁纸**, 用户看到的就是
    "这软件坏了", 日志里却只有一行"屏幕已锁"(审查 C2)。
    现在: 连续 LOCK_PROBE_FAILS 次拿不到就降级成"当作没锁屏", 并只记一次 WARN ——
    宁可多换几张图, 也不要无声停摆。"人不在就不换图"由空闲检测独立兜底:
    真锁屏走了人, 空闲 10 分钟后照样安静下来, 休眠友好的效果不受影响。
    """
    global _lock_fail, _lock_degraded
    h = 0
    try:
        h = _open_input_desktop()
    except Exception:
        h = 0
    if h:
        try:
            ctypes.windll.user32.CloseDesktop(h)
        except Exception:
            pass
        _lock_fail = 0
        _lock_degraded = False
        return False
    _lock_fail += 1
    if _lock_fail <= LOCK_PROBE_FAILS:
        return True
    _lock_degraded = True
    return False


def lock_check_degraded():
    """锁屏判定是不是已经降级（守护进程据此写一行 WARN，只写一次）。"""
    return _lock_degraded


def stay_quiet(idle, locked):
    """该不该"安静待着、这一轮不换图"：人不在（空闲超阈值）**或**锁屏了。"""
    return bool(locked) or should_skip_swap(idle)


def _note(dst, msg):
    """搬家的过程记到数据目录的日志里 —— 真搬错了有据可查。"""
    try:
        with open(os.path.join(dst, 'wallpaper.log'), 'a', encoding='utf-8') as fp:
            fp.write('%s  %s\n' % (datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S'), msg))
    except Exception:
        pass


def legacy_dirs():
    """exe 旁边可能存在的旧数据位置 (以前的版本留下的)。"""
    h = here()
    out = []
    d = os.path.join(h, DATA_DIR_NAME)
    if os.path.isdir(d):
        out.append(d)
    if any(os.path.isfile(os.path.join(h, f)) for f in ('config.json', 'state.json')):
        out.append(h)
    return out


def _cleanup_legacy(src, dst):
    """搬完并校验通过才敢删。两种旧布局分开处理:
         * 「微软壁纸助手数据」子目录 -> 整个删掉
         * 数据直接摊在 exe 旁边    -> 只删本程序认识的那几个文件, 别的碰都不碰
    """
    try:
        if os.path.basename(src.rstrip('\\/')) == DATA_DIR_NAME:
            shutil.rmtree(src)
        else:
            for f in os.listdir(src):
                if f in LEGACY_FILES:
                    p = os.path.join(src, f)
                    if os.path.isfile(p):
                        os.remove(p)
    except Exception as e:
        _note(dst, '数据已搬到新位置, 但旧目录没删掉 (%s): %s' % (src, e))
        return False
    return True


def migrate_into(dst):
    """把 exe 旁边的旧数据搬进 dst。

    顺序是: 复制 -> 逐文件比对大小+MD5 -> 全部一致才删旧的。
    任何一个文件对不上就整个停手, 旧目录原样留着, 下次再试 —— 宁可多一个文件夹, 不冒丢配置的风险。
    """
    for src in legacy_dirs():
        if os.path.abspath(src) == os.path.abspath(dst):
            continue
        try:
            names = [f for f in os.listdir(src)
                     if os.path.isfile(os.path.join(src, f)) and f not in GENERATED]
        except Exception:
            continue
        ok = True
        moved = 0
        for f in names:
            s = os.path.join(src, f)
            t = os.path.join(dst, f)
            try:
                if os.path.isfile(t):
                    # 目标已经有同名文件: 内容一样就跳过, 不一样就以目标为准, 绝不覆盖
                    if os.path.getsize(t) == os.path.getsize(s):
                        if _md5(t) == _md5(s):
                            continue
                    continue
                shutil.copy2(s, t)
                if os.path.getsize(t) != os.path.getsize(s) or _md5(t) != _md5(s):
                    ok = False
                    break
                moved += 1
            except Exception as e:
                ok = False
                _note(dst, '搬家中断: %s -> %s (%s), 旧目录保留' % (s, t, e))
                break
        if not ok:
            continue
        if _cleanup_legacy(src, dst):
            _note(dst, '数据目录已搬到 %s (搬了 %d 个文件, 旧位置 %s 已清掉)' % (dst, moved, src))


def appdata_dir():
    return os.path.join(os.environ.get('LOCALAPPDATA') or os.path.expanduser('~'), APP_NAME)


def data_dir():
    """数据放哪, 按这个顺序定:
       1) 便携模式: exe 旁边的「微软壁纸助手数据」里放着 portable.txt -> 跟着 exe 走
       2) 正常:     %LOCALAPPDATA%\\微软壁纸助手
                    —— 程序爱放哪放哪 (Program Files 也行), 旁边不会多出任何东西
       3) LOCALAPPDATA 写不进去 (极罕见) -> 才退回 exe 旁边
       发现 exe 旁边有旧数据 -> 自动搬进 2), 校验通过后再删掉旧的。
    """
    h = here()
    pd = os.path.join(h, DATA_DIR_NAME)
    if os.path.isfile(os.path.join(pd, 'portable.txt')) and writable(pd):
        return pd
    d = appdata_dir()
    if writable(d):
        migrate_into(d)
        return d
    if writable(pd):
        return pd
    if writable(h):
        return h
    return d


# ---------------------------------------------------------------- 释放内嵌脚本
def ver_tuple(v):
    """把 '2.0.5' 变成 (2,0,5)。比不了就当成 0 —— 宁可不升级, 也不能因为版本号怪就乱覆盖。"""
    try:
        # 2026-10-05 修: 必须去掉 BOM。core.ps1 用 PowerShell 的 Set-Content -Encoding UTF8
        # 写 `.version` 时, PS 5.1 会**在开头加上 UTF-8 BOM**(EF BB BF), 而 Python 用
        # encoding='utf-8' 读出来是 '\ufeff2.0.8', int('\ufeff2') 抛异常 ->
        # 版本号被当成 (0,) -> launcher 判定"数据目录的脚本比 exe 旧" -> 下次启动就把
        # 刚升级好的脚本覆盖回旧版。现象: 提示升级成功, 重启又变回旧版本。
        v = str(v).strip().lstrip('\ufeff').strip()
        return tuple(int(x) for x in v.split('.'))
    except Exception:
        return (0,)


def sync_payload(d):
    src = payload_src()
    ver_file = os.path.join(d, '.version')
    cur = ''
    if os.path.isfile(ver_file):
        try:
            # 顺带把 BOM 也去掉, 让 cur 直接能跟 VERSION 做字符串比较
            cur = open(ver_file, encoding='utf-8').read().strip().lstrip('\ufeff').strip()
        except Exception:
            cur = ''
    # 2026-09-22 自动升级(core.ps1 Invoke-BwScriptUpdate): `.version` 记的是
    # **数据目录里脚本的版本**, 脚本可以被程序自己升到比 exe 内嵌版本更新。
    # 那种情况必须原样保留 —— 否则每次启动都把新脚本盖回旧的, 自动升级等于白做。
    try:
        with open(os.path.join(d, '.launcher-version'), 'w', encoding='utf-8') as fp:
            fp.write(VERSION)
    except Exception:
        pass
    missing = [f for f in PAYLOAD_FILES if not os.path.isfile(os.path.join(d, f))]
    if not missing and ver_tuple(cur) > ver_tuple(VERSION):
        return d, False
    if cur == VERSION and not missing:
        return d, False

    if cur and cur != VERSION:
        # 版本变了: 清掉上一版释放过的脚本文件 (不碰 config/state/日志/壁纸)
        try:
            old = json.load(open(os.path.join(d, '.files.json'), encoding='utf-8'))
        except Exception:
            old = []
        for f in old:
            p = os.path.join(d, f)
            if os.path.isfile(p):
                try:
                    os.remove(p)
                except Exception:
                    pass

    for f in PAYLOAD_FILES:
        s = os.path.join(src, f)
        if os.path.isfile(s):
            shutil.copy2(s, os.path.join(d, f))
    with open(ver_file, 'w', encoding='utf-8') as fp:
        fp.write(VERSION)
    with open(os.path.join(d, '.files.json'), 'w', encoding='utf-8') as fp:
        json.dump(PAYLOAD_FILES, fp)
    # 把 exe 的绝对路径留给菜单, 菜单靠它开/关"开机自动换"
    with open(os.path.join(d, 'launcher.txt'), 'w', encoding='utf-8') as fp:
        fp.write(os.path.abspath(sys.executable if getattr(sys, 'frozen', False) else __file__))
    return d, True


# ---------------------------------------------------------------- 控制台
def ensure_console():
    """GUI 子系统进程没有控制台。双击进来时自己开一个, 当菜单用。"""
    if K32.GetConsoleWindow():
        return True
    if not K32.AllocConsole():
        if not K32.AttachConsole(0xFFFFFFFF):   # 从 cmd 之类已有控制台的父进程启动
            return False
    try:
        K32.SetConsoleOutputCP(936)
        K32.SetConsoleCP(936)
        K32.SetConsoleTitleW('{} v{}'.format(APP_NAME, VERSION))
    except Exception:
        pass
    rw, open_existing = 0xC0000000, 3
    h_in = K32.CreateFileW('CONIN$', rw, 3, None, open_existing, 0, None)
    h_out = K32.CreateFileW('CONOUT$', rw, 3, None, open_existing, 0, None)
    if h_in in (None, INVALID_HANDLE_VALUE) or h_out in (None, INVALID_HANDLE_VALUE):
        return False
    K32.SetStdHandle(-10, h_in)
    K32.SetStdHandle(-11, h_out)
    K32.SetStdHandle(-12, h_out)
    try:
        fd_in = msvcrt.open_osfhandle(h_in, os.O_RDONLY)
        fd_out = msvcrt.open_osfhandle(h_out, os.O_WRONLY)
        sys.stdin = io.open(fd_in, 'r', encoding='cp936', errors='replace', buffering=1)
        sys.stdout = io.open(fd_out, 'w', encoding='cp936', errors='replace', buffering=1)
        sys.stderr = sys.stdout
    except Exception:
        pass
    # 菜单字体大一号: conhost 默认 16px 高, 中文长标题挤成一团看不清。
    # 用 SetCurrentConsoleFontEx 把字高提到 20px, 失败就保持默认(无害)。
    try:
        _set_console_font_size(20, u'新宋体')
    except Exception:
        pass
    return True


def _set_console_font_size(height, face):
    """SetCurrentConsoleFontEx: Win10+ 才有, 失败静默 —— 字体大小是体验项不是功能项。"""
    import ctypes
    from ctypes import wintypes

    class COORD(ctypes.Structure):
        _fields_ = [('X', wintypes.SHORT), ('Y', wintypes.SHORT)]

    class CONSOLE_FONT_INFO_EX(ctypes.Structure):
        _fields_ = [('cbSize', wintypes.ULONG),
                    ('nFont', wintypes.ULONG),
                    ('dwFontSize', COORD),
                    ('FontFamily', wintypes.UINT),
                    ('FontWeight', wintypes.UINT),
                    ('FaceName', wintypes.WCHAR * 32)]

    rw, open_existing = 0xC0000000, 3
    h_out = K32.CreateFileW('CONOUT$', rw, 3, None, open_existing, 0, None)
    if h_out in (None, INVALID_HANDLE_VALUE):
        return False
    f = CONSOLE_FONT_INFO_EX()
    f.cbSize = ctypes.sizeof(f)
    f.dwFontSize = COORD(0, height)      # X=0: 宽度让 conhost 按字体自己算
    f.FontFamily = 54                    # FIXED_PITCH | FF_MODERN | TMPF_TRUETYPE
    f.FontWeight = 400
    f.FaceName = face
    # SetCurrentConsoleFontEx 没被 ctypes 默认封装, 手动取函数指针; argtypes 必须显式,
    # 否则 64 位下指针被截断, 直接闪退。
    k32 = ctypes.WinDLL('kernel32', use_last_error=True)
    fn = k32.SetCurrentConsoleFontEx
    fn.argtypes = [wintypes.HANDLE, wintypes.BOOL, ctypes.POINTER(CONSOLE_FONT_INFO_EX)]
    fn.restype = wintypes.BOOL
    ok = fn(h_out, False, ctypes.byref(f))
    K32.CloseHandle(h_out)
    return bool(ok)


def say(msg):
    try:
        print(msg)
        sys.stdout.flush()
    except Exception:
        pass


# ---------------------------------------------------------------- 跑 PowerShell
def clean_env():
    """剥掉 PyInstaller 单文件模式留给子进程的环境变量。

    为什么: 菜单里按 [A] 拉起后台, 链路是 菜单exe -> powershell -> Start-Process,
    环境变量一路继承。里面带着 PyInstaller 的 _PYI_* / _MEIPASS2 标记, 后台 exe
    拿到后会误判自己是"单文件父进程的子进程", 不自建临时目录, 直接复用菜单的
    Temp\\_MEIxxx。于是关掉菜单窗口时, 菜单要回收这个目录, 后台还占着 ——
    删不掉就弹「Failed to remove temporary directory」。
    现象恰好是: 每个新版本第一次使用(第一次按 [A])之后弹一次;
    以后自动换一直开着, 后台由系统开机独立拉起, 没这些标记, 就不再弹。
    参考 PyInstaller 官方文档 "spawn subprocesses that outlive the application" 一节。
    """
    drop_prefix = ('_PYI_', 'PYINSTALLER_')
    drop_exact = {'_MEIPASS2'}
    env = {}
    for k, v in os.environ.items():
        if k in drop_exact or k.startswith(drop_prefix):
            continue
        env[k] = v
    return env


def ps(script, args=(), no_window=True, wait=True):
    cmd = [PS_EXE, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script]
    cmd.extend(args)
    flags = CREATE_NO_WINDOW if no_window else 0
    if wait:
        return subprocess.run(cmd, creationflags=flags, env=clean_env()).returncode
    return subprocess.Popen(cmd, creationflags=flags, env=clean_env())


def run_cycle(d):
    return ps(os.path.join(d, 'core.ps1'), ['-Cycle'], no_window=True)


# 换图间隔的允许范围(分钟), 与 core.ps1 里的 $global:BwLimit.cycle_minutes 保持一致。
# 给上限不只是"讲道理": gap 超过约 41.9 亿分钟(≈7978 年)时, 算 target 会越过
# datetime 的上限(9999-12-31)抛 OverflowError, 守护进程直接退出,
# 表现出来就是"壁纸再也不换了"。与 core.ps1 的 $global:BwLimit.cycle_minutes 对齐。
CYCLE_MIN, CYCLE_MAX, CYCLE_DEF = 5, 1440, 30


def read_interval(d):
    """读"每多少分钟换一张", 越界一律夹回 [CYCLE_MIN, CYCLE_MAX]。"""
    try:
        with open(os.path.join(d, 'config.json'), encoding='utf-8-sig') as f:
            n = int(json.load(f).get('cycle_minutes') or CYCLE_DEF)
    except Exception:
        return CYCLE_DEF
    if n < CYCLE_MIN:
        return CYCLE_MIN
    if n > CYCLE_MAX:
        return CYCLE_MAX
    return n


def read_last_swap(d):
    """上次真正换图的时刻, 读不到返回 None。

    这是节拍的唯一依据: 菜单上「下次自动换」显示的就是 last_swap + 间隔,
    core.ps1 判断该不该换也用它。daemon 必须跟着同一个数走, 否则
    显示的时刻到了却不换 (最多错一整轮)。
    """
    try:
        with open(os.path.join(d, 'state.json'), encoding='utf-8-sig') as f:
            v = (json.load(f).get('last_swap') or '').strip()
        if not v:
            return None
        return datetime.datetime.strptime(v, '%Y-%m-%d %H:%M:%S')
    except Exception:
        return None


SLEEP_SLICE_S = 1.0     # 分片睡的粒度：停止信号最迟 1 秒内被看到（审查 H-12）


def sleep_watching_stop(stop_file, seconds, sleep=time.sleep, isfile=os.path.isfile):
    """分片睡最多 seconds 秒；期间一发现停止信号就立刻返回 True。

    原来这里一睡就是 AWAY_RECHECK_S(300 秒), 而 daemon.stop 只有睡醒才看 ——
    于是 --stop 最坏要 5 分钟才生效(审查 H-12): 菜单里按 [B] 关掉自动换, 界面立刻说
    "已关闭"、后台其实还在换; 部署流程 "--stop -> 等进程消失 -> 覆盖 exe" 在锁屏时会踩空。
    现在按 1 秒粒度分片, 停止信号最迟 1 秒内被看到。
    sleep / isfile 可注入, 便于单测（不真睡、不碰真文件）。
    """
    t0 = time.time()
    while True:
        if isfile(stop_file):
            return True
        left = seconds - (time.time() - t0)
        if left <= 0:
            return False
        sleep(min(SLEEP_SLICE_S, left))


# ---------------------------------------------------------------- 各模式
def mode_menu(d):
    if not ensure_console():
        return 1
    return ps(os.path.join(d, 'menu.ps1'), (), no_window=False)


def mode_daemon(d):
    # 单实例: 已经有一个在跑就安静退出
    K32.CreateMutexW(None, False, MUTEX_NAME)
    if K32.GetLastError() == 183:      # ERROR_ALREADY_EXISTS
        return 0
    stop_file = os.path.join(d, 'daemon.stop')
    if os.path.isfile(stop_file):
        try:
            os.remove(stop_file)
        except Exception:
            pass

    # 声明"我不阻止系统睡眠"。用户反馈过"用了这个工具后电脑不进睡眠",
    # 而本程序从不申请保持唤醒; 这一句把可能的残留请求清掉, 并留一条日志备查。
    if keep_sleep_allowed():
        _note(d, '守护进程: 已声明不阻止系统睡眠 (SetThreadExecutionState ES_CONTINUOUS)')

    # 节拍跟着「上次换图时刻」走, 不跟着本进程的启动时刻走。
    # 老写法是"跑一轮 -> 睡满 30 分钟 -> 再跑一轮", 于是:
    #   手动换一张 -> last_swap 前移 -> 菜单显示的下次时间前移,
    #   但 daemon 还在按老节拍睡, 醒来一算没到点就又睡一整轮,
    #   表现就是"菜单说的时间到了却不换"。
    CHECK_S = 30    # 多久看一眼 state.json: 感知手动换图 / 停止信号
    LEAD_S = 2      # 到点后多等 2 秒, 避开 core.ps1 那边"差一点点没到"的边界

    prev = read_last_swap(d)
    hold_until = 0.0     # 这轮没换成图时的兜底: 至少等到这个时刻, 免得空转
    away_logged = False  # "用户离开"这条日志只写一次, 免得刷屏
    lock_warned = False  # "锁屏判定不可用"也只写一次
    while True:
        if os.path.isfile(stop_file):
            try:
                os.remove(stop_file)
            except Exception:
                pass
            return 0

        gap = read_interval(d)
        ls = read_last_swap(d)
        if ls is not None and (prev is None or ls != prev):
            # 换过图了 (自己换的、菜单里手动换的、重启换的都算) -> 从这一刻重新计时
            hold_until = 0.0
            prev = ls
        # 注意 hold_until 必须参与, 不能写成 `0.0 if ls is None else ...`:
        # 全新安装(或 state.json 刚被重置)时 last_swap 是空的, 而这时若"人不在",
        # 每轮都会 due -> 安静 -> hold_until = now+300 -> 回到这里又被算成 0.0 ->
        # 又是一轮 due …… 中间一次 sleep 都没有, 就是 100% CPU 空转一整夜。
        base = 0.0 if ls is None else (ls.timestamp() + gap * 60)
        target = max(base, hold_until)

        # 分片睡到目标时刻。**人不在/锁屏时就睡大觉**（5 分钟一次），
        # 人在时才用 CHECK_S（30 秒）保持灵敏 —— 既少打扰系统，退出/改设置又不迟钝。
        due = False
        while True:
            left = target + LEAD_S - time.time()
            if left <= 0:
                due = True
                break
            step = AWAY_RECHECK_S if stay_quiet(idle_seconds(), session_locked()) else CHECK_S
            # 分片睡: 停止信号每一片都看(1 秒粒度); state.json / config.json 的重读
            # 仍按原来的节拍(30 秒 / 5 分钟)发生, 不会整夜每秒去读盘。
            if sleep_watching_stop(stop_file, min(step, left)):
                try:
                    os.remove(stop_file)
                except Exception:
                    pass
                return 0
            if read_last_swap(d) != prev:
                # 有人换过图了 (多半是用户在菜单里按了 [1]):
                # 这时候**不能**跟着换一张 —— 那会把人家刚挑的图顶掉。
                # 什么都不做, 回到外层按新的换图时刻重新算。
                break
            # 间隔被改了(设置 [1] 换图间隔): 回外层按新间隔重算目标时刻。
            # 以前这里只盯 last_swap / 停止信号, 不看 config, 于是:
            #   把 30 分钟改小成 5 分钟, 还得按旧的 30 分钟睡满这一觉才轮到下一次判断,
            #   体感就是"改了半天一点反应都没有"。改大同理, 要白跑一轮才纠正过来。
            if read_interval(d) != gap:
                break

        if not due:
            continue

        # 人不在 / 锁屏就不换图（2026-10-07 用户反馈「无法进入睡眠/休眠」）：
        # 换图会拉起 PowerShell、下载、并向所有窗口广播设置变更 ——
        # 别在系统准备休眠的节骨眼上插一脚。人一回来（或解锁）立刻补上。
        idle = idle_seconds()
        locked = session_locked()
        if lock_check_degraded() and not lock_warned:
            _note(d, '锁屏判定不可用（OpenInputDesktop 连续 %d 次取不到句柄），已降级为'
                     '"当作没锁屏"，不再因此停摆；"人不在就不换图"仍由空闲检测兜底'
                     % LOCK_PROBE_FAILS)
            lock_warned = True
        if stay_quiet(idle, locked):
            if not away_logged:
                if locked:
                    _note(d, '屏幕已锁，暂停换图，解锁后立刻换')
                else:
                    _note(d, '用户离开（已空闲 %.0f 分钟），暂停换图，回来再换'
                             % (idle / 60.0))
                away_logged = True
            hold_until = time.time() + AWAY_RECHECK_S
            continue
        if away_logged:
            _note(d, '用户回来了（已解锁/有操作），恢复换图')
            away_logged = False

        run_cycle(d)
        after = read_last_swap(d)
        if after is None or after == ls:
            # 这轮没换成 (网络不通 / 库是空的 / 必应还没发新图):
            # 不空转, 隔一整轮再试
            hold_until = time.time() + gap * 60
        prev = after


def mode_once(d):
    return run_cycle(d)


def mode_stop(d):
    try:
        with open(os.path.join(d, 'daemon.stop'), 'w', encoding='ascii') as f:
            f.write('stop')
    except Exception:
        pass
    return 0


def main():
    args = set(a.lower().lstrip('-').lstrip('/') for a in sys.argv[1:])
    d, _ = sync_payload(data_dir())
    if args & {'daemon', 'd'}:
        return mode_daemon(d)
    if args & {'stop', 'x'}:
        return mode_stop(d)
    if args & {'once', 'o'}:
        return mode_once(d)
    return mode_menu(d)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
