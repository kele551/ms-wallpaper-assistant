# -*- coding: utf-8 -*-
"""桌面壁纸：独立 GUI 控制面板窗口。

作者: 海风（kele551）   https://github.com/kele551/ms-wallpaper-assistant

2026-11-09 用户要求「不依赖浏览器打开控制面板」。
做法不是重写界面：panel.html 内嵌在 core.ps1 里，几十项功能都在那儿，重写必然缩水。
这里只换「装页面的窗口」—— 用 Windows 自带的 WebView2 开一个独立原生窗口：
任务栏独立图标、无地址栏、无标签页，也不调用任何浏览器进程。

链路与原来的浏览器模式完全同一条：
    menu.ps1（BWPANEL_GUI=1，起服务但绝不开浏览器）
      -> core.ps1 写 panel.serve.json（port / token / pid）
      -> pywebview(edgechromium) 把 http://127.0.0.1:<port>/ 装进原生窗口
服务仍只绑 127.0.0.1、仍要令牌、仍 30 分钟闲置自动退出；关窗口不影响后台守护。

2026-11-09 追加三条体验要求：
  ① 页面按 150% 显示 —— 用 WebView2 引擎级 ZoomFactor（必须在 UI 线程设置，
     早先在事件回调里直接赋值被拒，会静默退化成 CSS zoom 并撑出滚动条）；
  ② 标题栏与深色页面浑然一体 —— DWM 沉浸式深色 + 标题栏/边框/文字配色，
     加载前的 WebView 底色也换成页面底色，启动不闪白；
  ③ 启动再快一点 —— 窗口先显示深色加载页，PowerShell 服务在后台同时起，
     两条原本串行的冷启动重叠；就绪后再导航到真实面板。

WebView2 运行时是 Win10/11 的系统组件（不是浏览器应用），没有它、服务起不来、
或 pywebview 组件缺失时，才回退到原来的浏览器路径，并明确记一行日志，不静默降级。
"""
import ctypes
import json
import os
import re
import socket
import subprocess
import time

PANEL_TITLE = '桌面壁纸 · 控制面板'
_READY_TIMEOUT = 30.0
_POLL_S = 0.05                 # 原 0.2s：服务就绪后最多白等 0.2 秒，没必要
_DEFAULT_ZOOM = 1.5
_BG = '#101318'                # 与 panel.html 的 dark 主题 --bg 一致
_BG_COLORREF = 0x00181310      # COLORREF 是 0x00BBGGRR（#101318 -> 10/13/18）
_TXT_COLORREF = 0x00F4EDE8     # 标题栏文字 #E8EDF4
_LOADING_HTML = (
    '<!doctype html><html lang="zh-CN" data-theme="dark"><head><meta charset="utf-8">'
    '<style>html,body{margin:0;height:100%;background:#101318;color:#8e99a8;'
    'font:15px/1.6 "Microsoft YaHei",sans-serif;display:grid;place-items:center}'
    '.b{text-align:center;letter-spacing:.05em}'
    '.m{width:36px;height:36px;margin:0 auto 16px;border-radius:10px;background:#3b82f6;'
    'color:#fff;font-size:19px;line-height:36px}</style></head>'
    '<body><div class="b"><div class="m">壁</div>正在打开控制面板…</div></body></html>'
)


def _zoom_factor():
    """默认 150%; 可用 BWPANEL_ZOOM 覆盖(0.5~3.0), 写错或越界一律退回 1.5。"""
    raw = (os.environ.get('BWPANEL_ZOOM') or '').strip()
    if not raw:
        return _DEFAULT_ZOOM
    try:
        v = float(raw)
        return v if 0.5 <= v <= 3.0 else _DEFAULT_ZOOM
    except Exception:
        return _DEFAULT_ZOOM


def _apply_dark_chrome(window, note, d):
    """标题栏/边框/文字染成页面深色。DWM 属性可以在任意线程调，但要显式声明
    argtypes，否则 64 位下 HWND 指针被截断，设置静默无效。"""
    try:
        hwnd = int(window.native.Handle.ToInt32())
        dwm = ctypes.windll.dwmapi
        dwm.DwmSetWindowAttribute.argtypes = [
            ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        dwm.DwmSetWindowAttribute.restype = ctypes.c_long

        def set_attr(attr, value):
            v = ctypes.c_int(value)
            dwm.DwmSetWindowAttribute(
                ctypes.c_void_p(hwnd), attr,
                ctypes.cast(ctypes.byref(v), ctypes.c_void_p), 4)

        set_attr(20, 1)                 # DWMWA_USE_IMMERSIVE_DARK_MODE
        set_attr(35, _BG_COLORREF)      # DWMWA_CAPTION_COLOR（Win11 22H2+）
        set_attr(34, _BG_COLORREF)      # DWMWA_BORDER_COLOR
        set_attr(36, _TXT_COLORREF)     # DWMWA_TEXT_COLOR
        return True
    except Exception:
        return False


def _apply_zoom(window, factor, note, d, once):
    """ZoomFactor 属 CoreWebView2Controller，只能在 UI 线程访问；事件回调在
    工作线程，必须用 WinForms 的 Invoke 把赋值切回 UI 线程。失败才降级 CSS，
    并把真实异常类型记进日志，不静默降级。"""
    try:
        import clr  # noqa: F401  (pythonnet 初始化，必须在 from System 之前)
        from System import Action

        form = window.native

        def _set():
            try:
                form.webview.ZoomFactor = factor
                if not once[0]:
                    once[0] = True
                    note(d, 'GUI: WebView2 引擎缩放 %.0f%%' % (factor * 100))
            except Exception as e:
                try:
                    window.evaluate_js(
                        "document.documentElement.style.zoom = '%s'" % factor)
                    if not once[0]:
                        once[0] = True
                        note(d, 'GUI: 原生缩放失败(%s)，已用 CSS 缩放 %.0f%%'
                             % (type(e).__name__, factor * 100))
                except Exception:
                    pass

        form.Invoke(Action(_set))
        return True
    except Exception as e:
        if not once[0]:
            once[0] = True
            note(d, 'GUI: 缩放调度失败(%s)' % type(e).__name__)
        return False


def _serve_record(d):
    """读 core.ps1 写下的服务记录，只认合法 port + 32 位十六进制令牌。"""
    try:
        with open(os.path.join(d, 'panel.serve.json'), 'r', encoding='utf-8-sig') as f:
            rec = json.load(f)
        port = int(rec.get('port') or 0)
        token = str(rec.get('token') or '')
        if port > 0 and re.fullmatch(r'[0-9a-f]{32}', token):
            return port, token
    except Exception:
        pass
    return None


def _port_open(port):
    """只探 TCP，不向服务发请求 —— 省得在日志里留下半截连接。"""
    s = socket.socket()
    s.settimeout(0.6)
    try:
        s.connect(('127.0.0.1', port))
        return True
    except Exception:
        return False
    finally:
        try:
            s.close()
        except Exception:
            pass


def _focus_existing():
    """再点一次图标：已有控制面板窗口就激活它，不叠第二个窗口。"""
    try:
        u = ctypes.windll.user32
        h = u.FindWindowW(None, PANEL_TITLE)
        if h:
            u.ShowWindow(h, 9)          # SW_RESTORE
            u.SetForegroundWindow(h)
            return True
    except Exception:
        pass
    return False


def _start_service(d, ps_exe, flags, clean_env):
    """起本地服务，绝不打开浏览器；menu.ps1 会复用已在跑的同一个服务。"""
    env = clean_env()
    env['BWPANEL_GUI'] = '1'
    env['BWPANEL_NOBROWSER'] = '1'      # 双保险：两条开关都指向「不开浏览器」
    cmd = [ps_exe, '-NoProfile', '-ExecutionPolicy', 'Bypass',
           '-File', os.path.join(d, 'menu.ps1')]
    return subprocess.Popen(cmd, creationflags=flags, env=env)


def _wait_url(d, proc):
    deadline = time.time() + _READY_TIMEOUT
    while time.time() < deadline:
        rec = _serve_record(d)
        if rec and _port_open(rec[0]):
            # 页面 HTML 是 core.ps1 启动时就载进内存的，端口在听就一定能出页面。
            return 'http://127.0.0.1:%d/' % rec[0]
        if proc is not None and proc.poll() not in (None, 0):
            break                       # menu.ps1 明确失败，不再干等 30 秒
        time.sleep(_POLL_S)
    return None


def _webview2_runtime():
    """本机是否装了 WebView2 运行时。

    2026-11-14 用户反馈（Issue #1）：「还要下载 EdgeWebView」。
    根因：pywebview 是打包进 exe 的，`import webview` 必然成功，真正缺的是**系统的
    WebView2 运行时**；一路走到 create_window 才报错，pywebview 顺手弹出安装提示。
    所以这里提前查一遍目录：缺运行时就直接走浏览器，用户永远不用为一块壁纸面板去装组件。
    """
    roots = [
        os.path.join(os.environ.get('ProgramFiles(x86)') or r'C:\Program Files (x86)',
                     'Microsoft', 'EdgeWebView', 'Application'),
        os.path.join(os.environ.get('ProgramFiles') or r'C:\Program Files',
                     'Microsoft', 'EdgeWebView', 'Application'),
    ]
    local = os.environ.get('LOCALAPPDATA')
    if local:
        roots.append(os.path.join(local, 'Microsoft', 'EdgeWebView', 'Application'))
    for r in roots:
        if not os.path.isdir(r):
            continue
        try:
            for name in os.listdir(r):
                if os.path.isfile(os.path.join(r, name, 'msedgewebview2.exe')):
                    return True
        except OSError:
            continue
    return False


def run(d, fallback, note, clean_env, ps_exe, flags):
    """打开控制面板。

    d         数据目录（core.ps1 / panel.serve.json / 图标都在这里）
    fallback  原来的浏览器模式（mode_menu），只在独立窗口不可用时调用
    note      写日志（launcher._note）
    clean_env / ps_exe / flags  启动器原来的 PowerShell 调用上下文，保持一致
    """
    if _focus_existing():
        return 0
    try:
        import webview
    except Exception as e:
        note(d, 'GUI: 独立窗口组件不可用(%s)，改用浏览器打开' % e)
        return fallback(d)
    # 2026-11-14: 先确认系统真的有 WebView2 运行时再开窗口。
    # 不查这一步的话，import 成功但运行时缺失，pywebview 会弹「下载 EdgeWebView」——
    # 用户反馈最烦的就是这一条（只想换个壁纸，不想装组件）。
    if not _webview2_runtime():
        note(d, 'GUI: 本机没有 WebView2 运行时，直接用浏览器打开（不提示下载组件）')
        return fallback(d)

    t0 = time.time()
    once = [False]                     # 缩放只在日志里记一次
    state = {'navigated': False, 'page_logged': False}
    icon = os.path.join(d, '壁纸助手.ico')
    storage = os.path.join(d, 'webview2')   # 缓存留在数据目录，删数据目录 = 彻底卸载

    try:
        # 150% 缩放会把 CSS 视口缩成「物理尺寸 / 1.5」。页面 .wrap 上限 1160px，
        # 且 CSS 视口 <=1000px 会触发响应式断点把两列塌成一列 —— 窗口物理宽必须
        # >1500px。1600x1000 -> 约 1067x667 CSS：双列保持、内容铺满、不出滚动条。
        # 只放大窗口不加缩放是没用的：字号不变，只是四周留白更多。窗口仍可拖大/最大化。
        win = webview.create_window(
            PANEL_TITLE, html=_LOADING_HTML,
            width=1600, height=1000, min_size=(960, 640),
            resizable=True, background_color=_BG, text_select=True)
        factor = _zoom_factor()

        def on_before_show():
            _apply_dark_chrome(win, note, d)
            note(d, 'GUI: 窗口显示 %.2fs' % (time.time() - t0))

        def on_loaded():
            # 加载页与面板页都会触发；导航/刷新后缩放不会悄悄回到 100%。
            _apply_dark_chrome(win, note, d)
            _apply_zoom(win, factor, note, d, once)
            if state['navigated'] and not state['page_logged']:
                state['page_logged'] = True
                note(d, 'GUI: 面板页面加载完成 %.2fs' % (time.time() - t0))

        win.events.before_show += lambda *_: on_before_show()
        win.events.loaded += lambda *_: on_loaded()

        def boot():
            # webview.start 把这个函数放到窗口启动后的独立线程：PowerShell 服务
            # 与 WebView2 冷启动并行，不再串行相加。
            proc = None
            try:
                proc = _start_service(d, ps_exe, flags, clean_env)
            except Exception as e:
                note(d, 'GUI: 本地服务没能启动(%s)' % e)
            url = _wait_url(d, proc)
            if not url:
                note(d, 'GUI: 本地服务 %d 秒内没就绪，改用浏览器打开'
                     % int(_READY_TIMEOUT))
                try:
                    win.destroy()
                except Exception:
                    pass
                fallback(d)
                return
            note(d, 'GUI: 服务就绪 %.2fs' % (time.time() - t0))
            state['navigated'] = True
            win.load_url(url)          # pywebview 内部会切回 UI 线程

        webview.start(
            boot,
            gui='edgechromium',
            icon=icon if os.path.isfile(icon) else None,
            private_mode=False,
            storage_path=storage)
        return 0
    except Exception as e:
        note(d, 'GUI: 原生窗口起不来(%s)，改用浏览器打开' % e)
        return fallback(d)
