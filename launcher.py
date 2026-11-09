# -*- coding: utf-8 -*-
"""
壁纸助手 - 绿色单文件版启动器。

作者: 海风（kele551）   https://github.com/kele551/ms-wallpaper-assistant

设计要点
--------
* 本 exe 是 **GUI 子系统**（PyInstaller --windowed）。所以:
    - 双击           -> 自己 AllocConsole() 开一个控制台, 显示菜单。
                        没有"先建控制台再隐藏"的闪窗问题。
    - 开机后台自启    -> 完全不创建控制台, 一个窗口都不会闪。

* 数据放用户目录 (%LOCALAPPDATA%\\壁纸助手), 程序 exe 旁边**不放任何东西** ——
  (2026-10-12 改名: 产品旧名「微软壁纸助手」, 旧名数据目录里的东西会在新版第一次
   启动时**复制**过来 —— 校验通过才算数, 旧目录**保留不删**, 留作回滚兜底。)
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
  (无参数)     打开独立控制面板窗口（原生窗口，不依赖浏览器）
  --daemon     后台常驻, 按 config.json 的 cycle_minutes 自动换壁纸 (给"开机自启"用)
  --once       不常驻, 只跑一轮 (调试用)
  --browser    用浏览器打开原来的网页控制台（独立窗口不可用时手动回退）
  --stop       通知正在跑的 --daemon 退出
"""
import io
import json
import msvcrt
import os
import re
import shutil
import hashlib
import subprocess
import sys
import time
import datetime
import panel_gui
import ctypes

VERSION = '2.4.5'
# 【2026-10-16 升级通道加固】内置的 Ed25519 **公钥**（离线生成，公开无妨、本来就要随程序分发）。
# 升级源 version.json 必须带一份同目录的 `version.json.sig`（128 个十六进制字符 = 64 字节签名），
# 用这把公钥验过才认；验不过 / 没签名 / 签名格式不对，一律**拒绝**（fail-closed，见 mode_verify_update）。
# 没有私钥就签不出合法签名，所以即便 GitCode / GitHub 账号被盗、有人推了恶意 version.json + 恶意 exe，
# 客户端也不会装。私钥只在维护者机器上、绝不入库（见 docs/SECURITY.md）。
# 能力边界（别夸大）：这挡的是"升级源被篡改 / 中间人换包"；挡不住维护者机器上的私钥本身被偷，
# 也不等于 Windows 代码签名证书。
UPDATE_PUBKEY = 'cdb8bb7a545ca55a92f4e6744dada5c80437ade25eb0dfc5c8a2b8f177f39ef1'
# 2026-10-12 产品改名: 「微软壁纸助手」->「壁纸助手」(去掉他人商标前缀)。
# 旧名常量**刻意保留**, 只做兼容探测:
#   * 新数据目录 %LOCALAPPDATA%\壁纸助手; 老目录第一次启动时整体**复制**过来
#     (复制 -> 逐文件校验 -> 旧目录保留不删, 回滚有据);
#   * 便携 U 盘模式: exe 旁边若还是老名「微软壁纸助手数据」(里面有 portable.txt),
#     就**继续用老目录**, 不搬家不分裂;
#   * 互斥体名 Local\MSWallpaperAssistantDaemon 不改 —— 改名过渡期新老 exe
#     可能同时在跑, 守护进程必须继续互斥, 只能有一个。
APP_NAME = '壁纸助手'
# 【2026-10-25 文件名更正】exe 文件名 = 显示名「桌面壁纸」, 不再用 APP_NAME 推。
# APP_NAME 从此只管数据目录(%LOCALAPPDATA%\壁纸助手)和随包 .ico 文件名 —— 那两处改名
# 要把老用户的 config / state / 图片索引整个搬家, 风险对不上收益。
# 成品文件名以这一处为准 (build-exe.py 的 EXE_STEM、发版自检 tools/preflight_release.py 都读它)。
EXE_STEM = '桌面壁纸'
LEGACY_APP_NAME = '微软壁纸助手'
DATA_DIR_NAME = '壁纸助手数据'
LEGACY_DATA_DIR_NAME = '微软壁纸助手数据'
PAYLOAD_FILES = ['core.ps1', 'menu.ps1', '使用说明.txt', '壁纸助手.ico']
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
    for _nm in (DATA_DIR_NAME, LEGACY_DATA_DIR_NAME):   # 2026-10-12: 新老两个便携目录名都认
        d = os.path.join(h, _nm)
        if os.path.isdir(d):
            out.append(d)
    if any(os.path.isfile(os.path.join(h, f)) for f in ('config.json', 'state.json')):
        out.append(h)
    return out


def _cleanup_legacy(src, dst):
    """搬完并校验通过才敢删。两种旧布局分开处理:
         * 「壁纸助手数据 / 微软壁纸助手数据」子目录 -> 整个删掉
         * 数据直接摊在 exe 旁边    -> 只删本程序认识的那几个文件, 别的碰都不碰
    """
    try:
        if os.path.basename(src.rstrip('\\/')) in (DATA_DIR_NAME, LEGACY_DATA_DIR_NAME):
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


def legacy_appdata_dir():
    """改名前的老用户数据目录 (%LOCALAPPDATA%\\微软壁纸助手)。"""
    return os.path.join(os.environ.get('LOCALAPPDATA') or os.path.expanduser('~'), LEGACY_APP_NAME)


def migrate_from_legacy_appdata(dst):
    """2026-10-12 改名迁移: 把老名 appdata 目录**复制**进新目录。

    口径跟 exe 旁边旧数据搬家一个样: 复制 -> 逐文件比大小+MD5 -> 全对才算成。
    两点不同: ① 老目录**保留不删**(它是回滚兜底, 用户在菜单 [S]->[7] 看过新目录
    没问题后自己删); ② 新目录已有 config.json = 已经在新名下跑过, 直接跳过。
    新目录里已存在的同名文件一律以新目录为准, 绝不覆盖。
    """
    src = legacy_appdata_dir()
    if not os.path.isdir(src) or os.path.abspath(src) == os.path.abspath(dst):
        return
    if os.path.isfile(os.path.join(dst, 'config.json')):
        return
    moved = 0
    try:
        names = os.listdir(src)
    except Exception:
        return
    for f in names:
        s = os.path.join(src, f)
        t = os.path.join(dst, f)
        try:
            if os.path.isdir(s):
                if not os.path.isdir(t):
                    shutil.copytree(s, t)
                    moved += 1
                continue
            if not os.path.isfile(s):
                continue
            if os.path.isfile(t):
                continue
            shutil.copy2(s, t)
            if os.path.getsize(t) != os.path.getsize(s) or _md5(t) != _md5(s):
                _note(dst, '改名迁移中断: %s 校验不一致, 老目录原样保留' % f)
                return
            moved += 1
        except Exception as e:
            _note(dst, '改名迁移中断: %s (%s), 老目录原样保留' % (s, e))
            return
    _note(dst, '改名迁移: 从老数据目录(%s)复制了 %d 项过来; 老目录保留, 确认新目录没问题后可在菜单 [S]->[7] 删除' % (LEGACY_APP_NAME, moved))


def data_dir():
    """数据放哪, 按这个顺序定:
       0) 演练隔离: 环境变量 MWA_DATA 直接指定数据目录 (优先于下面一切; 不设时行为不变) ——
          2026-10-16 加, 类比狐径 FOXPATH_DATA: 发版前升级演练用独立目录, 绝不碰用户真实数据
       1) 便携模式: exe 旁边的「壁纸助手数据」(或老名「微软壁纸助手数据」)里放着 portable.txt -> 跟着 exe 走
       2) 正常:     %LOCALAPPDATA%\\壁纸助手  (老名目录第一次启动时复制迁移, 老目录保留)
                    —— 程序爱放哪放哪 (Program Files 也行), 旁边不会多出任何东西
       3) LOCALAPPDATA 写不进去 (极罕见) -> 才退回 exe 旁边
       发现 exe 旁边有旧数据 -> 自动搬进 2), 校验通过后再删掉旧的。
    """
    _ov = (os.environ.get('MWA_DATA') or '').strip()
    if _ov:
        try:
            os.makedirs(_ov, exist_ok=True)
        except Exception:
            pass
        return _ov
    h = here()
    pd = os.path.join(h, DATA_DIR_NAME)
    if os.path.isfile(os.path.join(pd, 'portable.txt')) and writable(pd):
        return pd
    pd_old = os.path.join(h, LEGACY_DATA_DIR_NAME)   # 2026-10-12: 便携 U 盘上还是老目录名 -> 继续用它
    if os.path.isfile(os.path.join(pd_old, 'portable.txt')) and writable(pd_old):
        return pd_old
    d = appdata_dir()
    if writable(d):
        migrate_from_legacy_appdata(d)
        migrate_into(d)
        return d
    if writable(pd):
        return pd
    if writable(h):
        return h
    return d


# ---------------------------------------------------------------- 释放内嵌脚本
def _write_launcher_txt(d):
    """2026-10-12 (审查 P1): 每次启动都把 launcher.txt 校正成当前 exe 路径。
    原来只在"版本变更全量重放"时写 —— 用户挪动/改名 exe(正是这次改名的现场)后,
    launcher.txt 还指着老路径, 主程序自动升级报"找不到主程序路径"、菜单自启修复失效,
    而且全是静默的。先比对再写(内容一样不碰盘), 写走临时文件+原子替换。"""
    p = os.path.join(d, 'launcher.txt')
    want = os.path.abspath(sys.executable if getattr(sys, 'frozen', False) else __file__)
    try:
        cur = open(p, encoding='utf-8', errors='replace').read().strip()
    except Exception:
        cur = ''
    if cur == want:
        return
    try:
        tmp = p + '.tmp%d' % os.getpid()
        with open(tmp, 'w', encoding='utf-8') as fp:
            fp.write(want)
        os.replace(tmp, p)
    except Exception:
        pass


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


def _sha256_file(p):
    try:
        h = hashlib.sha256()
        with open(p, 'rb') as f:
            for chunk in iter(lambda: f.read(65536), b''):
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return ''


def _payload_manifest(d):
    try:
        return json.load(open(os.path.join(d, '.payload_sha.json'), encoding='utf-8'))
    except Exception:
        return {}


def _save_payload_manifest(d, m):
    try:
        tmp = os.path.join(d, '.payload_sha.json.tmp')
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump(m, f)
        os.replace(tmp, os.path.join(d, '.payload_sha.json'))
    except Exception:
        pass


def sync_payload(d):
    _write_launcher_txt(d)   # 2026-10-12: 见 _write_launcher_txt —— 所有 return 分支之前都过这一道
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
    # 2026-10-10: 脚本比 exe 新（程序自己热更过，.version 记的是数据目录里脚本的版本）
    # 时必须原样保留。原写法是 `if not missing and ver_tuple(cur) > ver_tuple(VERSION)`，
    # 只要数据目录里少**任何一个** payload 文件 —— 用户很容易把"使用说明.txt"或图标
    # 当垃圾删掉 —— 这个守卫就不成立，直接落到下面那段：按 .files.json 删旧文件、
    # 把 exe 内嵌的旧 core.ps1/menu.ps1 拷回去、.version 写回 exe 版本。热更状态被
    # 静默回退，界面与行为退回旧版且毫无提示。
    # 现在拆开：处于热更状态时，只补真正缺失的文件，绝不覆盖已存在的、绝不动 .version。
    if ver_tuple(cur) > ver_tuple(VERSION):
        for f in missing:
            s = os.path.join(src, f)
            if os.path.isfile(s):
                shutil.copy2(s, os.path.join(d, f))
        return d, False
    if cur == VERSION:
        # 2026-11-09: 同版本重打包（修 bug / 换页面）时 exe 内嵌脚本变了、.version 没变，
        # 旧的「只补缺失」会让真实数据目录永远跑旧脚本 —— 实测表现：面板还是旧版、
        # /api/state 没有 nextSwapAt、倒计时根本不出现。
        # 用「上次由本 exe 释放出去的哈希」区分两种改动：
        #   数据目录 == 旧释放哈希 且 != 本次内嵌 -> exe 换了，覆盖；
        #   数据目录与两者都不同 -> 热更/外部修改，原样保留（绝不覆盖，保住热更语义）。
        man = _payload_manifest(d)
        legacy = not bool(man)   # 旧安装从没写过清单：按「同版本 exe 重建」一次性迁移
        for f in PAYLOAD_FILES:
            dst = os.path.join(d, f)
            s = os.path.join(src, f)
            if not os.path.isfile(s):
                continue
            if not os.path.isfile(dst):
                shutil.copy2(s, dst)
                man[f] = _sha256_file(s)
                continue
            h_src = _sha256_file(s)
            h_dst = _sha256_file(dst)
            if h_dst == h_src:
                man[f] = h_src
            elif legacy or (man.get(f) and h_dst == man[f]):
                # 无清单的历史安装 / 清单记录的正是上次由 exe 释放的哈希 -> exe 重建了，
                # 同步到内嵌版本。有清单但本文件无记录 = 热更/外部改动，落到 else 保留。
                shutil.copy2(s, dst)
                man[f] = h_src
                _note(d, '启动器: 同版本检测到脚本已更新, 已同步 ' + f)
            else:
                man.pop(f, None)   # 热更/外部改动: 保留且不纳入下次比对
        _save_payload_manifest(d, man)
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
    _save_payload_manifest(d, {f: _sha256_file(os.path.join(src, f))
                               for f in PAYLOAD_FILES if os.path.isfile(os.path.join(src, f))})
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


def quick_swap(d):
    """到点准时换图：core.ps1 -Quick 纯本地选图，绝不联网/下载/删图。成功返回 0。"""
    return ps(os.path.join(d, 'core.ps1'), ['-Quick'], no_window=True)


def run_cycle_async(d):
    """维护（升级检查 / 补漏 / 补货）丢后台，不阻塞守护节拍与倒计时。"""
    return ps(os.path.join(d, 'core.ps1'), ['-Cycle'], no_window=True, wait=False)


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


def read_last_bing_date(d):
    """state.json 里「最后一次换上必应当日图是哪一天」(core.ps1 规则 1 的记账)。

    读不到就返回空串 —— 空串 != 今天, 于是守护进程会立刻跑一轮, 让 core.ps1
    自己去补这张当日图。宁可多跑一轮空转的轮换, 也不要"今天这张永远不上墙"。
    """
    try:
        with open(os.path.join(d, 'state.json'), encoding='utf-8-sig') as f:
            return (json.load(f).get('last_bing_date') or '').strip()
    except Exception:
        return ''


def compute_target(now_ts, cycle_ts, daily_pending, daily_ts, boot_pending, boot_ts):
    """守护进程下一轮该在什么时刻跑。纯函数, 喂假时间就能测, 不碰磁盘不睡真觉。

    cycle_ts      : 「上次换图 + 间隔」—— 原来唯一的依据
    daily_pending : 今天还没换上必应当日图 (core.ps1 规则 1「每天第一次 -> 必应当日图」)
    daily_ts      : 上面这条没办成时的退避下限 (断网不许每几十秒重试一轮)
    boot_pending  : 本次开机还没跑过任何一轮轮换 (守护进程只在登录时被拉起,
                    所以进程刚起来 == 本次开机第一次)。开机校对填充方式、
                    必应模式重启贴回当日图 都只在轮换里做, 得给它一次机会。
    boot_ts       : 同上, 人不在时的退避下限

    【2026-11-05 用户反馈】"前一天手动选了一张别的时间的必应图, 今早开机不换当日图,
    要先切聚焦再切必应才换得动"。根因就在原来这里只看 cycle_ts: 必应模式把间隔钉成
    1440 分钟, 前一天 17:20 手动挑图把 last_swap 推到 17:20 -> 下一轮排到"第二天 17:20",
    早上开机那一轮压根不跑, 规则 1 与开机校对全都没机会执行。面板上那两个模式按钮
    会当场跑一次换图(bingnow), 所以"切一下就好了"。
    """
    t = cycle_ts
    if daily_pending:
        t = min(t, max(now_ts, daily_ts))
    if boot_pending:
        t = min(t, max(now_ts, boot_ts))
    return t


# 「今天还没换上必应当日图」没试成时的阶梯退避: 5 -> 15 -> 30 -> 60 分钟封顶。
# 阶梯是为了断网: 必应接口挂一天的话, 固定 5 分钟就是全天 288 轮空转(每轮还要
# 联网取元数据 + 补漏 + 查升级)。换成功一次就把阶梯归零。
DAILY_RETRY_STEPS_S = (5 * 60, 15 * 60, 30 * 60, 60 * 60)


def daily_retry_seconds(fails):
    """第 fails 次失败后该退避多久 (只增不减到 1 小时封顶)。"""
    if fails < 0:
        fails = 0
    return DAILY_RETRY_STEPS_S[min(fails, len(DAILY_RETRY_STEPS_S) - 1)]


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
    # 2026-10-23 用户要求：「每次点开快捷图标，小黑窗不能弹出」。
    # v2.4.5 起默认走 panel_gui 的独立原生窗口；这里只作 --browser / 组件缺失时的回退。
    # 不需要控制台窗口；所以这里**不申请控制台**、也不建新窗口（CREATE_NO_WINDOW）。
    # 出错时 menu.ps1 会弹 WinForms 消息框，不依赖控制台。
    return ps(os.path.join(d, 'menu.ps1'), (), no_window=True)


def _write_next_swap(d, at, reason=''):
    """守护把权威的下次换图时刻落盘，供面板倒计时读取。

    只在这个值真的变化时才写（临时文件 + 原子替换），每 30 秒一轮的循环
    不会变成每秒写盘。面板读它，前端就不必再猜后台的 hold_until / 空闲暂停。
    """
    p = os.path.join(d, 'next_swap.json')
    rec = {'at': int(at * 1000), 'reason': reason, 'pid': os.getpid()}
    try:
        cur = json.load(open(p, encoding='utf-8'))
        if cur.get('at') == rec['at'] and cur.get('reason') == reason:
            return
    except Exception:
        pass
    try:
        tmp = p + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump(rec, f)
        os.replace(tmp, p)
    except Exception:
        pass


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
    RETRY_S = 60    # 本地无图时的补图重试间隔（真实写进倒计时，不假等）

    prev = read_last_swap(d)
    hold_until = 0.0     # 这轮没换成图时的兜底: 至少等到这个时刻, 免得空转
    daily_hold = 0.0     # 「今天还没换上必应当日图」的退避下限
    boot_hold = 0.0      # 「本次开机还没跑过轮换」的退避下限
    boot_pending = True  # 守护进程只在登录时被拉起 -> 进程刚起来就是本次开机第一次
    boot_logged = False  # "本次开机先跑一轮"这句日志每次启动只说一次
    daily_fails = 0      # 上面这条连续失败几次, 决定阶梯退避到第几档
    away_logged = False  # "用户离开"这条日志只写一次, 免得刷屏
    lock_warned = False  # "锁屏判定不可用"也只写一次
    # 2026-10-23: 起来/收工都留一行日志。以前后台被 --stop 停掉时**一行都没有**,
    # 事后没法区分"它自己崩了"和"有人叫它停" —— 用户看到的现象却完全一样:
    # 到点不换图, 日志里最后那句"下次 xx:xx"永远不兑现。
    _note(d, '守护进程: 已启动 (PID %d, 每 %d 分钟换一张)' % (os.getpid(), read_interval(d)))
    while True:
        # 2026-10-23: 整轮包一层兜底。以前主循环没有任何 try —— 一个没预料到的异常
        # 就把整个后台静默带走: 壁纸从此不再自动换, 而没有任何人能把它拉回来
        # (开机自启只在登录时生效一次)。现在出错只丢这一轮, 睡一分钟接着跑。
        try:
            if os.path.isfile(stop_file):
                try:
                    os.remove(stop_file)
                except Exception:
                    pass
                _note(d, '守护进程: 收到停止信号, 已退出')
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
            # 节拍之外还有两个"到点"条件(见 compute_target 的说明):
            #   今天还没换上必应当日图 / 本次开机还没跑过一轮轮换。
            today_str = datetime.date.today().strftime('%Y-%m-%d')
            daily_pending = (read_last_bing_date(d) != today_str)
            target = compute_target(time.time(), max(base, hold_until),
                                    daily_pending, daily_hold,
                                    boot_pending, boot_hold)
            # 权威时刻只由「上次换图 + 间隔」与 hold_until 决定。
            # boot_pending / daily_pending 是**维护触发**（开机校对、跨天补当日图），
            # 不是换图时刻 —— 拿 target 当倒计时会让守护一重启就归零，
            # 10 分钟间隔被缩短成「重启即换」，实测确实提前换了图。
            swap_at = max(base, hold_until) + LEAD_S
            _write_next_swap(d, max(swap_at, time.time()), 'normal')
            if boot_pending and not boot_logged and target < max(base, hold_until):
                # 只在本机第一次开机时说一句, 免得日志里刷屏
                _note(d, '守护进程: 本次开机先跑一轮轮换 (必应当日图/填充方式要在这里校对)')
                boot_logged = True

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
                    _note(d, '守护进程: 收到停止信号, 已退出')
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
                # 三个"到点"条件一起往后推, 不然开机/跨天这两个触发会把
                # hold_until 的 5 分钟觉顶掉 —— 变成人不在时每几秒空跑一轮。
                away_until = time.time() + AWAY_RECHECK_S
                hold_until = away_until
                daily_hold = away_until
                boot_hold = away_until
                # 人不在时后台确实要等，那就把真实等待时刻写出去：倒计时显示
                # 的是"还有多久会再尝试"，而不是虚假地归零后干等。
                _write_next_swap(d, away_until, 'away')
                continue
            if away_logged:
                _note(d, '用户回来了（已解锁/有操作），恢复换图')
                away_logged = False

            # ---- 2026-11-09：到点必须换，且不能有任何等待 ----
            # 旧链路直接跑 core.ps1 -Cycle：它先升级检查、补漏、联网抓图，
            # 网络卡住时十几分钟都换不了图，倒计时却早已归零。
            # 现在：先用纯本地通道 -Quick 在秒级内换完 -> 立刻发布下一轮权威时刻
            # -> 维护动作丢后台，绝不占着节拍。倒计时与真实换图时刻严格同一刻。
            # 只有真正到了「上次换图 + 间隔」才换图；开机校对/跨天补图这类
            # 维护触发只跑后台巡检，不能提前换壁纸、也不能把倒计时清零。
            wall_due = (ls is None) or (time.time() + LEAD_S >= max(base, hold_until))
            if not wall_due:
                boot_pending = False
                if read_last_bing_date(d) == datetime.date.today().strftime('%Y-%m-%d'):
                    daily_fails = 0
                    daily_hold = 0.0
                else:
                    daily_hold = time.time() + daily_retry_seconds(daily_fails)
                    daily_fails += 1
                try:
                    run_cycle_async(d)
                except Exception:
                    pass
                prev = ls
                _write_next_swap(d, max(base + LEAD_S, time.time()), 'normal')
                continue
            ok = (quick_swap(d) == 0)
            after = read_last_swap(d)
            # 跨天/必应当日图的退避照旧维护，别让 compute_target 每轮都判定「立刻到点」。
            if read_last_bing_date(d) == datetime.date.today().strftime('%Y-%m-%d'):
                daily_fails = 0
                daily_hold = 0.0
            else:
                daily_hold = time.time() + daily_retry_seconds(daily_fails)
                daily_fails += 1
            boot_pending = False
            try:
                run_cycle_async(d)   # 升级检查 / 补漏 / 补货，后台跑，不阻塞倒计时
            except Exception:
                pass
            if ok and after is not None and (prev is None or after != prev):
                prev = after
                hold_until = 0.0
                # 换图完成即归零重置：倒计时从这一刻重新按间隔走，后台再慢也不影响。
                _write_next_swap(d, time.time() + gap * 60 + LEAD_S, 'normal')
                continue
            # 本地一张可用图都没有：不假装换过，给出真实的短重试时刻，
            # 倒计时显示「还有多久再试」而不是永远停在 00:00:00。
            hold_until = time.time() + RETRY_S
            _write_next_swap(d, hold_until, 'retry')
            _note(d, '准时换图失败(本地无可用图), %d 秒后重试, 补货已转后台' % RETRY_S)
            prev = after
        except Exception as e:
            _note(d, '守护进程: 这一轮出错, 已自动继续 (%s: %s)' % (type(e).__name__, e))
            if sleep_watching_stop(stop_file, 60):
                try:
                    os.remove(stop_file)
                except Exception:
                    pass
                return 0


def mode_once(d):
    return run_cycle(d)


def mode_stop(d):
    try:
        with open(os.path.join(d, 'daemon.stop'), 'w', encoding='ascii') as f:
            f.write('stop')
    except Exception:
        pass
    return 0


def mode_verify_update(argv):
    """只读子命令: 桌面壁纸.exe --verify-update <version.json> <version.json.sig>

    给 core.ps1 的升级流程在「相信 version.json 之前」调用的验签闸门:
      · 用内置公钥 UPDATE_PUBKEY 对 version.json 的**原始字节**验签;
      · 通过退出 0, 缺失 / 格式错 / 不匹配打印人话并退出非 0;
      · 纯读纯计算 —— 不联网、不写文件、不改任何状态(所以必须在 sync_payload 之前执行)。
    import _ed25519 用 try/except 包住, 失败也走拒绝(fail-closed)。
    """
    idx = -1
    for _i, _a in enumerate(argv):
        if _a.lower().lstrip('-').lstrip('/') == 'verify-update':
            idx = _i
            break
    if idx < 0:
        return 2
    _paths = [a for a in argv[idx + 1:] if not a.startswith(('-', '/'))]
    if len(_paths) != 2:
        say('用法: %s.exe --verify-update <version.json> <version.json.sig>' % EXE_STEM)
        return 2
    vj_path, sig_path = _paths[0], _paths[1]
    try:
        import _ed25519
    except Exception as _e:
        say('验签失败: 验签模块缺失(%s), 拒绝信任升级源' % type(_e).__name__)
        return 1
    try:
        with open(vj_path, 'rb') as _f:
            raw = _f.read()
    except Exception as _e:
        say('验签失败: 读不到 version.json (%s)' % type(_e).__name__)
        return 1
    try:
        with open(sig_path, 'rb') as _f:
            sig_hex = _f.read().decode('utf-8', 'replace').strip()
    except Exception as _e:
        say('验签失败: 读不到签名文件 (%s)' % type(_e).__name__)
        return 1
    if not re.fullmatch(r'[0-9a-fA-F]{128}', sig_hex):
        say('验签失败: 签名格式不对(应为 128 个十六进制字符, 实际 %d 个字符)' % len(sig_hex))
        return 1
    try:
        _pub = bytes.fromhex(UPDATE_PUBKEY)
        _sig = bytes.fromhex(sig_hex)
    except Exception as _e:
        say('验签失败: 公钥/签名不是合法十六进制 (%s)' % type(_e).__name__)
        return 1
    if _ed25519.checkvalid(_sig, raw, _pub):
        say('验签通过')
        return 0
    say('验签失败: 签名与 version.json 不匹配, 拒绝信任升级源')
    return 1


def main():
    argv = sys.argv[1:]
    # 2026-10-16: --verify-update 是纯读纯计算子命令, 必须在 sync_payload(会写数据目录)之前处理,
    # 否则"验签"这个只读动作也会去释放脚本/写 launcher.txt, 违背"绝不写文件/改状态"。
    if any(a.lower().lstrip('-').lstrip('/') == 'verify-update' for a in argv):
        return mode_verify_update(argv)
    args = set(a.lower().lstrip('-').lstrip('/') for a in argv)
    d, _ = sync_payload(data_dir())
    if args & {'daemon', 'd'}:
        return mode_daemon(d)
    if args & {'stop', 'x'}:
        return mode_stop(d)
    if args & {'once', 'o'}:
        return mode_once(d)
    if args & {'browser', 'b'} or os.environ.get('BWPANEL_BROWSER') == '1':
        return mode_menu(d)
    # 2026-11-09: 双击默认开独立 GUI 窗口，不再拉起浏览器；失败由 panel_gui 自己回退。
    return panel_gui.run(d, mode_menu, _note, clean_env, PS_EXE, CREATE_NO_WINDOW)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
