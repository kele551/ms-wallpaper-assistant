# -*- coding: utf-8 -*-
"""生成一个带 BOM 的 PowerShell 测试脚本 (PS 5.1 按 ANSI 读无 BOM 脚本会解析失败)。

测的是菜单这一层: 快捷方式的创建/更新/不再重建, 以及图标来源。
桌面用 Get-BwDesktopDir 换成临时目录, 真桌面一个字节都不碰。
"""
import os
import shutil
import sys

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)      # 仓库根：core.ps1 / menu.ps1 / 微软壁纸助手.ico 都在这里
T = os.path.join(HERE, '_t2')
if os.path.isdir(T):
    shutil.rmtree(T, ignore_errors=True)
os.makedirs(T, exist_ok=True)

PS = r'''
$T = 'F:\wp-src\tests\_t2'
$out = @()
function chk($n, $c, $x) {
  if ($c) { $script:out += ('  [通过] ' + $n) }
  else { $script:out += ('  [失败] ' + $n + ('  ' + [string]$x)) }
}

# 安全网: 真桌面上 .lnk 的数量, 测试前后必须一模一样
$realDesk = [Environment]::GetFolderPath('Desktop')
$before = @(Get-ChildItem -LiteralPath $realDesk -File -Filter '*.lnk' -ErrorAction SilentlyContinue).Count

# ---- 搭一个假的"程序目录": core.ps1 / menu.ps1(去掉主菜单) / ico / 假 exe ----
$data = Join-Path $T 'data'
New-Item -ItemType Directory -Force -Path $data | Out-Null
Copy-Item 'F:\wp-src\core.ps1' (Join-Path $data 'core.ps1') -Force
Copy-Item 'F:\wp-src\微软壁纸助手.ico' (Join-Path $data '微软壁纸助手.ico') -Force
$menuSrc = Get-Content -LiteralPath 'F:\wp-src\menu.ps1' -Raw -Encoding UTF8
$cut = $menuSrc.IndexOf('# ---------- 主菜单 ----------')
if ($cut -lt 1) { $cut = $menuSrc.Length }
$menuSrc.Substring(0, $cut) | Set-Content -LiteralPath (Join-Path $data 'menu_test.ps1') -Encoding UTF8
$fakeExe = Join-Path $data '微软壁纸助手.exe'
Set-Content -LiteralPath $fakeExe -Value 'fake' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $data 'launcher.txt') -Value $fakeExe -Encoding UTF8

. (Join-Path $data 'core.ps1')
. (Join-Path $data 'menu_test.ps1')
chk 'BWRoot 指向临时数据目录' ($global:BWRoot -eq $data) $global:BWRoot

# ---- 把"桌面"整个换成临时目录 ----
$desk = Join-Path $T 'desk'
New-Item -ItemType Directory -Force -Path $desk | Out-Null
function script:Get-BwDesktopDir { return $script:desk }
chk '桌面已被测试接管' ((Get-BwDesktopDir) -eq $desk) (Get-BwDesktopDir)

# ---- 图标来源 ----
$ico = Get-BwIconLocation $fakeExe
chk '图标取自独立的 .ico 文件' ($ico -like '*微软壁纸助手.ico*') $ico

# ---- 场景1: 从没建过 -> 建一次 ----
Ensure-BwConfig | Out-Null
$c = Get-BwConfig
Add-Member -InputObject $c NoteProperty desktop_shortcut 'on' -Force
Save-BwConfig $c
$r1 = Ensure-BwDesktopShortcut
$lnk = Get-BwDesktopLnk
chk '首次运行会建快捷方式' ($r1 -eq 'create') $r1
chk '快捷方式建在桌面上' (Test-Path -LiteralPath $lnk) $lnk
if (Test-Path -LiteralPath $lnk) {
  $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
  chk '目标指向 exe' ($sc.TargetPath -eq $fakeExe) $sc.TargetPath
  chk '图标指向 .ico' ($sc.IconLocation -like '*微软壁纸助手.ico*') $sc.IconLocation
  chk '描述里带版本号' ($sc.Description -like ('*v' + $global:BWVersion + '*')) $sc.Description
}
$i1 = Get-BwDeskInfo
chk '记下了"已经建过"' ($i1.created -eq 'yes') $i1.created

# ---- 场景2: 再来一次 -> 不该重复建 ----
$r2 = Ensure-BwDesktopShortcut
chk '第二次不重复创建' ($r2 -eq 'ok') $r2

# ---- 场景3: 用户把它收进文件夹 -> 就地更新, 桌面根不另建 ----
$sub = Join-Path $desk '图标'
New-Item -ItemType Directory -Force -Path $sub | Out-Null
Move-Item -LiteralPath $lnk -Destination (Join-Path $sub '微软壁纸助手.lnk') -Force
$r3 = Ensure-BwDesktopShortcut
chk '收进文件夹后就地更新' (@('ok','update') -contains $r3) $r3
chk '桌面根没有再冒一个' (-not (Test-Path -LiteralPath (Join-Path $desk '微软壁纸助手.lnk'))) $desk
$i3 = Get-BwDeskInfo
chk '记住了新位置' ($i3.path -eq (Join-Path $sub '微软壁纸助手.lnk')) $i3.path

# ---- 场景4: 用户删掉它 -> 不再自动建 ----
Remove-Item -LiteralPath (Join-Path $sub '微软壁纸助手.lnk') -Force
$r4 = Ensure-BwDesktopShortcut
chk '删掉之后不再重建' ($r4 -eq 'gone') $r4
chk '桌面根确实还是空的' (-not (Test-Path -LiteralPath (Join-Path $desk '微软壁纸助手.lnk'))) $desk

# ---- 场景5: 在设置里关掉再开 -> 允许重建一个 ----
#     (菜单 [S]-[6] 重新开启时做的正是: 清掉 path 和 created 这两个记号)
$c5 = Get-BwConfig
Add-Member -InputObject $c5 NoteProperty desktop_shortcut 'on' -Force
Save-BwConfig $c5
$i5 = Get-BwDeskInfo
$i5.path = ''
$i5.created = ''
Save-BwDeskInfo $i5
$r5 = Ensure-BwDesktopShortcut
chk '重新开启后能再建一个' ($r5 -eq 'create') $r5
if (Test-Path -LiteralPath (Join-Path $desk '微软壁纸助手.lnk')) {
  (Get-Item -LiteralPath (Join-Path $desk '微软壁纸助手.lnk')).LastWriteTime = (Get-Date).AddDays(-3)
  (Get-Item -LiteralPath $fakeExe).LastWriteTime = Get-Date
  $r5b = Ensure-BwDesktopShortcut
  chk 'exe 更新后会就地刷新图标' ($r5b -eq 'update') $r5b
}

# ---- 场景6: 设置里关掉 -> off ----
$c6 = Get-BwConfig
Add-Member -InputObject $c6 NoteProperty desktop_shortcut 'off' -Force
Save-BwConfig $c6
$r6 = Ensure-BwDesktopShortcut
chk '关掉之后返回 off' ($r6 -eq 'off') $r6

# ---- 场景7: 首次运行不该让客户做选择题 ----
# 把联网、建快捷方式、"让用户挑位置"这三件都 stub 掉, 单看它是不是自己定了位置。
$wall = Join-Path $T 'wallpaper'
$script:selCount = 0
function Get-BwDefaults {
  return [PSCustomObject]@{ base = $script:wall; bing = (Join-Path $script:wall '必应');
                            spotlight = (Join-Path $script:wall '聚焦'); reason = '测试用' }
}
function Select-BwBase { param($suggest, $suggestReason)
  $script:selCount++
  if ($script:selCount -gt 2) { return $suggest }
  return ''
}
function Invoke-BwUpdate { return $true }
function Invoke-SpotlightFetch { param($count, [switch]$Quiet) return @() }
function Ensure-BwDesktopShortcut { return 'ok' }
function Pause-Bw { }          # 末尾那句"按回车返回菜单", 测试里不该等人敲键盘

Invoke-BwFirstRun
chk '首次运行没有问"壁纸存哪"(没调用选择器)' ($script:selCount -eq 0) ('调用了 ' + $script:selCount + ' 次')
$c7 = Get-BwConfig
chk '保存位置自己定好了(推荐位置)' ($c7.bing_save_dir -eq (Join-Path $wall '必应')) $c7.bing_save_dir
chk '必应目录真的建出来了' (Test-Path -LiteralPath (Join-Path $wall '必应')) (Join-Path $wall '必应')
chk '聚焦目录真的建出来了' (Test-Path -LiteralPath (Join-Path $wall '聚焦')) (Join-Path $wall '聚焦')
chk '定义了新的首屏函数 Show-BwFirstRunHead' ((Get-Command Show-BwFirstRunHead -ErrorAction SilentlyContinue) -ne $null) ''

# ---- 安全网: 真桌面必须原样 ----
$after = @(Get-ChildItem -LiteralPath $realDesk -File -Filter '*.lnk' -ErrorAction SilentlyContinue).Count
chk '真实桌面一个快捷方式都没多/没少' ($before -eq $after) "$before -> $after"

Set-Content -LiteralPath (Join-Path $T 'out.txt') -Value $out -Encoding UTF8
'''

# 2026-10-10: 模板里的绝对路径原本写死作者机器的 F:\wp-src，换台机器必然找不到
# core.ps1 / menu.ps1 / ico。现在模板里只留这一个根，在这里统一换成实际仓库根
# （tests 的上一级）—— 注意替换后 $T 正好等于上面算出来的 <仓库>\tests\_t2。
PS = PS.replace(r'F:\wp-src', ROOT)

p = os.path.join(T, 'run.ps1')
with open(p, 'w', encoding='utf-8-sig') as f:
    f.write(PS)
print('已生成', p)
