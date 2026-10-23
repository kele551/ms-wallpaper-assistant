# 桌面壁纸 - 控制台入口
# 作者: 海风（kele551）   https://gitcode.com/kele551/ms-wallpaper-assistant
#
# 2026-10-23（V2.4.0）: 界面从"文本菜单"整体改成"网页控制台"。
#   * 本文件只做三件事: 隐藏控制台窗口 → 起本地服务 → 打开浏览器。
#   * 界面在 core.ps1 内嵌的 panel.html 里；页面上的每一项都落到 Invoke-BwPanelAction，
#     改的是同一份 config.json / state.json —— 不是另做一套设置。
#   * 为什么页面必须内嵌在 core.ps1: 老客户端的升级循环只认 core.ps1 / menu.ps1 两个文件名，
#     多一个文件他们永远收不到。所以老用户点"检查更新"就能拿到整套控制台，不用换 exe。
#   * 后台守护（--daemon）本来就是 core.ps1 在跑，与本文件无关，不受影响。
param([switch]$DryRun)
. (Join-Path $PSScriptRoot 'core.ps1') -DryRun:$DryRun

# 版本常量: 发版脚本与发版自检都认这一行, 不要挪走、不要改格式。
$global:BWVersion = '2.4.0'

# 隐藏自己的控制台窗口: 界面已经是网页了，再留一个黑框就不伦不类。
# 隐藏失败也不要紧 —— 功能不受影响，只是那个窗口还在。
function Hide-BwConsole {
  try {
    if (-not ('BwWin32' -as [type])) {
      Add-Type -Name 'BwWin32' -Namespace '' -ErrorAction Stop -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
    }
    $h = [BwWin32]::GetConsoleWindow()
    if ($h -ne [IntPtr]::Zero) { [void][BwWin32]::ShowWindow($h, 0) }
  } catch {}
}

# 窗口已经藏起来了，起不来的时候只能弹框 —— 总得让用户看见原因。
function Show-BwPanelError([string]$text) {
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    [void][System.Windows.Forms.MessageBox]::Show($text, '桌面壁纸', 'OK', 'Error')
  } catch { Write-Host $text }
}

if ($DryRun) {
  Log '试运行: 不启动控制台（不占端口、不开浏览器）'
  exit 0
}

# 保存位置不可写时不要闷头失败: 说清楚, 并且照常打开控制台 —— 用户可以在里面换位置。
try {
  $c0 = Get-BwConfig
  $base0 = ''
  try { $base0 = [string](Split-Path ([string]$c0.bing_save_dir) -Parent) } catch {}
  if ($base0 -and -not (Test-BwWritable $base0)) {
    Log ('控制台: 保存位置不可写 -> ' + $base0) 'WARN'
    Show-BwPanelError ('保存位置写不进去：' + $base0 + "`n`n控制台会照常打开：可以在「高级 → 壁纸保存位置」里换一个目录；`n也可以把这个程序用管理员身份运行一次，让它把目录建好。")
  }
} catch {}

Hide-BwConsole

# 2026-10-23: 打开控制台时顺手确认后台还在跑。
# 起因: 用户报「手动挑了一张壁纸, 到 30 分钟不换」。查下来轮换逻辑本身没问题,
# 是**后台守护进程早就不在了** —— 开机自启只在登录时跑一次, 之后没有任何东西会把它拉回来
# (升级时的 --stop、清理工具关掉进程、意外退出都会留下这个状态),
# 用户看到的就是「到点了不换, 那个"下次自动换"的时间永远不兑现」。
# 所以每次打开控制台都把这一件事做掉: 开机自动换开着、后台却没在跑 -> 立刻拉起来。
try {
  if (Test-BwAutoStart) {
    if (-not (Test-BwDaemonRunning)) {
      $exe0 = Get-BwLauncherPath
      if (Start-BwDaemonNow $exe0) { Log ('控制台: 后台没在跑, 已自动拉起(到点照常换图)') }
      else { Log ('控制台: 后台没在跑, 自动拉起失败(找不到主程序: ' + $exe0 + ')') 'WARN' }
    }
  }
} catch { Log ('控制台: 检查后台失败: ' + $_.Exception.Message) 'WARN' }

# 顺手查一次更新（独立进程跑，不挡界面）
if ($env:BWPANEL_NOUPDATE -ne '1') {
try {
  $coreFile = Join-Path $PSScriptRoot 'core.ps1'
  Start-Process 'powershell.exe' -ArgumentList @(
    '-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $coreFile),'-PanelJob','update'
  ) -WindowStyle Hidden | Out-Null
} catch {}
}

# BWPANEL_NOBROWSER=1 只在自检/演练里用: 起服务但不开浏览器（不打扰正在用电脑的人）
$noBrowser = ($env:BWPANEL_NOBROWSER -eq '1')
try {
  [void](Start-BwPanelServer -IdleMinutes 30 -NoBrowser:$noBrowser)
  exit 0
} catch {
  Log ('控制台起不来: ' + $_.Exception.Message) 'ERROR'
  Show-BwPanelError ('控制台起不来：' + $_.Exception.Message + "`n`n常见原因：本机安全软件拦住了本地端口。可以把这段截图反馈。")
  exit 1
}
