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
ROOT = os.path.dirname(HERE)      # 仓库根：core.ps1 / menu.ps1 / 壁纸助手.ico 都在这里
T = os.path.join(HERE, '_t2')
if os.path.isdir(T):
    shutil.rmtree(T, ignore_errors=True)
os.makedirs(T, exist_ok=True)

# 模板里**不写任何本机绝对路径**：仓库根用占位符 @ROOT@ 表示，末尾统一替换成实际位置
# （换台机器、换个盘符都不会找不到 core.ps1 / menu.ps1 / 图标）。
PS = r'''
$T = '@ROOT@\tests\_t2'
$out = @()
# 2026-10-25: 一句写错的检查(比如 Join-Path 少给一个参数)原本只是"这条没记上",
# 屏幕上一片绿, 其实少验了一条。这里把错误提上来: 当场炸, 宁可见底也不假绿。
$ErrorActionPreference = 'Stop'
# 真炸了也别把前面跑完的检查丢掉: 当场把已有结果 + 炸在哪一句写进 out.txt, 再停下来。
trap {
  $script:out += ('  [炸] ' + $_.Exception.Message)
  Set-Content -LiteralPath (Join-Path $T 'out.txt') -Value $out -Encoding UTF8
  break
}
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
Copy-Item '@ROOT@\core.ps1' (Join-Path $data 'core.ps1') -Force
Copy-Item '@ROOT@\壁纸助手.ico' (Join-Path $data '壁纸助手.ico') -Force
$menuSrc = Get-Content -LiteralPath '@ROOT@\menu.ps1' -Raw -Encoding UTF8
# 2026-10-25 修: 锚点「# ---------- 主菜单 ----------」在 V2.4.0 界面搬进网页控制台之后就没有了,
# 于是 IndexOf 返回 -1 -> 落到"整份都拷"的兜底 -> 单测把 menu.ps1 **连起面板服务那一段**一起点源了,
# Start-BwPanelServer 是阻塞的 accept 循环, 结果这套单测一跑就挂 30 分钟(闲置超时)才回得来,
# 而且看起来像"测试卡死"。锚点换成还在的那一行, 并且**找不到就当场报错**, 不再静默兜底。
$cut = $menuSrc.IndexOf('# BWPANEL_NOBROWSER=1')
if ($cut -lt 1) { throw 'menu.ps1 里找不到截断锚点「# BWPANEL_NOBROWSER=1」, 别把起服务那一段也点源了' }
$menuSrc.Substring(0, $cut) | Set-Content -LiteralPath (Join-Path $data 'menu_test.ps1') -Encoding UTF8
$fakeExe = Join-Path $data '桌面壁纸.exe'
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
chk '图标取自独立的 .ico 文件' ($ico -like '*壁纸助手.ico*') $ico

# ---- 2026-10-25 文件名更正: 三个名字都算「固定名」, 新名优先, 老名不复制第二份 ----
$fn = Join-Path $T 'fixedname'
New-Item -ItemType Directory -Force -Path $fn | Out-Null
foreach ($nm in @('桌面壁纸.exe', '壁纸助手.exe', '微软壁纸助手.exe')) {
  Set-Content -LiteralPath (Join-Path $fn $nm) -Value 'fake' -Encoding ASCII
}
$lt = Join-Path $data 'launcher.txt'
$ltBak = ''
if (Test-Path -LiteralPath $lt) { $ltBak = (Get-Content -LiteralPath $lt -Raw -Encoding UTF8) }
Set-Content -LiteralPath $lt -Value (Join-Path $fn '微软壁纸助手.exe') -Encoding UTF8
chk '三个名字都在时取新名' ((Get-BwFixedExe) -eq (Join-Path $fn '桌面壁纸.exe')) (Get-BwFixedExe)
Remove-Item -LiteralPath (Join-Path $fn '桌面壁纸.exe') -Force
chk '只剩老名时也认(不给老用户复制第二份 exe)' ((Get-BwFixedExe) -eq (Join-Path $fn '壁纸助手.exe')) (Get-BwFixedExe)
Remove-Item -LiteralPath (Join-Path $fn '壁纸助手.exe') -Force
chk '最老的「微软壁纸助手.exe」同样认' ((Get-BwFixedExe) -eq (Join-Path $fn '微软壁纸助手.exe')) (Get-BwFixedExe)
if ($ltBak) { Set-Content -LiteralPath $lt -Value $ltBak -Encoding UTF8 }

# ---- 场景1: 从没建过 -> 建一次 ----
# (原来这里先调 Ensure-BwConfig, 那条函数早没了: Get-BwConfig 自己就能在没有
#  config.json 的时候兜底出默认值 —— 见下面重写过的场景7。)
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
  chk '图标指向 .ico' ($sc.IconLocation -like '*壁纸助手.ico*') $sc.IconLocation
  chk '描述里带版本号' ($sc.Description -like ('*v' + $global:BWVersion + '*')) $sc.Description
}
$i1 = Get-BwDeskInfo
chk '记下了"已经建过"' ($i1.created -eq 'yes') $i1.created

# ---- 场景2: 再来一次 -> 不该重复建 ----
$r2 = Ensure-BwDesktopShortcut
chk '第二次不重复创建' ($r2 -eq 'ok') $r2

# ---- 场景3: 用户把它收进文件夹 -> 就地更新, 桌面根不另建 ----
# 挪进去时故意用**老名字**的文件夹版: 顺手验一遍「老名字就地改成新名字」那条。
$sub = Join-Path $desk '图标'
New-Item -ItemType Directory -Force -Path $sub | Out-Null
$oldLnk = Join-Path $sub '微软壁纸助手.lnk'
$newLnk = Join-Path $sub '桌面壁纸.lnk'
Move-Item -LiteralPath $lnk -Destination $oldLnk -Force
$r3 = Ensure-BwDesktopShortcut
chk '收进文件夹后就地更新' (@('ok','update') -contains $r3) $r3
chk '桌面根没有再冒一个(新旧名字都不算)' ((-not (Test-Path -LiteralPath (Join-Path $desk '桌面壁纸.lnk'))) -and (-not (Test-Path -LiteralPath (Join-Path $desk '微软壁纸助手.lnk')))) $desk
chk '文件夹里那份改成了新名字' ((Test-Path -LiteralPath $newLnk) -and (-not (Test-Path -LiteralPath $oldLnk))) $newLnk
$i3 = Get-BwDeskInfo
chk '记住了新位置' ($i3.path -eq $newLnk) $i3.path

# ---- 场景4: 用户删掉它 -> 不再自动建 ----
Remove-Item -LiteralPath $newLnk -Force
$r4 = Ensure-BwDesktopShortcut
chk '删掉之后不再重建' ($r4 -eq 'gone') $r4
chk '桌面根确实还是空的' (-not (Test-Path -LiteralPath (Join-Path $desk '桌面壁纸.lnk'))) $desk

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
# 上一句没建出来时**当场报失败**, 别静默跳过 —— 以前这个 if 一走空,
# 「exe 更新后会就地刷新图标」这条就没跑过, 看着一片绿其实少验一条。
$root5 = Join-Path $desk '桌面壁纸.lnk'
if (Test-Path -LiteralPath $root5) {
  (Get-Item -LiteralPath $root5).LastWriteTime = (Get-Date).AddDays(-3)
  (Get-Item -LiteralPath $fakeExe).LastWriteTime = Get-Date
  $r5b = Ensure-BwDesktopShortcut
  chk 'exe 更新后会就地刷新图标' ($r5b -eq 'update') $r5b
} else {
  chk 'exe 更新后会就地刷新图标(拿不到快捷方式, 这条没跑成)' $false $root5
}

# ---- 场景6: 设置里关掉 -> off ----
$c6 = Get-BwConfig
Add-Member -InputObject $c6 NoteProperty desktop_shortcut 'off' -Force
Save-BwConfig $c6
$r6 = Ensure-BwDesktopShortcut
chk '关掉之后返回 off' ($r6 -eq 'off') $r6

# ---- 场景7 (2026-10-25 重写): 没建过 config.json 时, 保存位置由程序自己定 ----
# 原来这段测的是文本菜单里的 Invoke-BwFirstRun + Select-BwBase(让用户挑盘)。
# V2.4.0 界面搬进网页控制台后, 那两条一起删了 —— 现在"第一次存哪"完全由
# Get-BwDefaultBase / Get-BwDefaults 算, Get-BwConfig 直接拿它兜底, 全程不等键盘。
# 所以改测这三条, 并把"扫盘找图片文件夹"stub 掉: 自检不该去扫真盘(慢,
# 而且换台机器结果就变了)。
function Get-BwSysDriveLetter { return 'C' }
function Find-BwExistingBase { return $null }
function Reset-BwBaseCache { $global:BWDefaultBase = ''; $global:BWDefaults = $null }

$wall = Join-Path $T 'wallpaper'
Reset-BwBaseCache
function Get-BwPicturesDir { return (Join-Path $T '我的图片') }   # 「图片」在非系统盘(F:)
$g7a = Get-BwDefaults
chk '「图片」在非系统盘 -> 壁纸就存它下面' ($g7a.base -eq (Join-Path $T '我的图片\壁纸')) $g7a.base

Reset-BwBaseCache
function Get-BwPicturesDir { return 'C:\Users\tester\Pictures' }  # 「图片」被放回系统盘
$g7b = Get-BwDefaults
chk '「图片」在系统盘又没现成图库 -> 仍用它自己的位置, 不另造文件夹' ($g7b.base -eq 'C:\Users\tester\Pictures\壁纸') $g7b.base
chk '不会在盘根凭空造一个「图片」跟真「图片」并列' ($g7b.base -notmatch '^[A-Za-z]:\\[^\\/]+$') $g7b.base

# 没有 config.json: Get-BwConfig 该直接给出一套能用的位置, 而不是抛异常或等用户选。
$cfgBak = $global:CfgPath
$global:CfgPath = Join-Path $T '没有这个文件.json'
$c7 = Get-BwConfig
chk '没有 config.json 时也拿得到必应/聚焦位置' ($c7.bing_save_dir -eq $g7b.bing -and $c7.spotlight_save_dir -eq $g7b.spotlight) ($c7.bing_save_dir + ' / ' + $c7.spotlight_save_dir)
# 目录是"用的时候建": 把位置指回临时目录(config 另存一份, 不碰 data 里那份), 再验一次真建得出来。
Add-Member -InputObject $c7 NoteProperty bing_save_dir (Join-Path $wall '必应') -Force
Add-Member -InputObject $c7 NoteProperty spotlight_save_dir (Join-Path $wall '聚焦') -Force
$global:CfgPath = Join-Path $T 'probe_config.json'
Save-BwConfig $c7
[void](Ensure-BwDirs)
$global:CfgPath = $cfgBak
chk '必应目录建出来了' (Test-Path -LiteralPath (Join-Path $wall '必应')) (Join-Path $wall '必应')
chk '聚焦目录建出来了' (Test-Path -LiteralPath (Join-Path $wall '聚焦')) (Join-Path $wall '聚焦')
Reset-BwBaseCache

# ---- 安全网: 真桌面必须原样 ----
$after = @(Get-ChildItem -LiteralPath $realDesk -File -Filter '*.lnk' -ErrorAction SilentlyContinue).Count
chk '真实桌面一个快捷方式都没多/没少' ($before -eq $after) "$before -> $after"

Set-Content -LiteralPath (Join-Path $T 'out.txt') -Value $out -Encoding UTF8
'''

# 2026-10-10: 模板里原本写死作者机器上的仓库绝对路径，换台机器必然找不到
# core.ps1 / menu.ps1 / 壁纸助手.ico。现在模板里只留 @ROOT@ 这一个占位符，在这里统一
# 换成实际仓库根（tests 的上一级）—— 注意替换后 $T 正好等于 <仓库>\tests\_t2。
PS = PS.replace('@ROOT@', ROOT)

p = os.path.join(T, 'run.ps1')
with open(p, 'w', encoding='utf-8-sig') as f:
    f.write(PS)
print('已生成', p)
