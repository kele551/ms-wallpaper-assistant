# -*- coding: utf-8 -*-
# 作者: 海风（kele551）
# 用途: 面板「最近换过」这一排取的是哪 12 张 —— 判据单测（2026-10-25 用户截图反馈）。
#
# 用户看到的现场：标题写着「最近换过」，里面却是 2026-10-23_荒野伙伴 / 2023-01-01_在北极附近
# 打盹 / 01-02 / 01-03 / 01-04 这一批，而 14:58 刚换上的那张（blueparrotfish）根本不在里面。
# 根因在 core.ps1 的 Get-BwPanelState：`history` 是**追加表**（越靠后越新），原来却从
# 下标 0 往后取 12 条 —— 等于把"最早换过、文件恰好还在库里"的那批端上去了。
# 这个用例钉四件事：
#   ① 从最新往旧取（第一条 = 当前正显示的那张）；
#   ② 文件已经不在库里的条目跳过（不破图）；
#   ③ 每条带上 hist_at 的"换上时间"，面板角标才能和栏目标题同一个口径
#      （以前角标是**图片自己的发布日期**，标题却说"最近换过"，读起来就是自相矛盾）；
#   ④ history 里记的是"图片编号"（聚焦图 = 文件名末尾 slug）时也要能查回那张图，
#      并且回给面板的是真实文件名 —— 不然刚换上的图根本不出现在这一排里。
#
# 安全: 全程只动 tests\_t4 下的临时目录（core.ps1 点源进临时 BWRoot），
#       真实图库 / state.json / 注册表 / 回收站一个字节都不碰。
import os
import shutil
import subprocess
import sys

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
T = os.path.join(HERE, '_t4')

# 仓库根在模板里用 @ROOT@ 占位, 写出前统一换成实际路径(同 gen_ps_test.py)。
# 2026-10-25: 这里原本把本机绝对路径直接写死在 PS 里 —— 公开仓库里带上作者机器的目录结构
# 不合适, 而且换台机器/换个盘必然找不到 core.ps1。以前用占位符时踩过的是 python 源码里
# 手写双反斜杠(结果 PS 收到的是 `F:\\Harness\\...`), 值由 os.path 给就没这个问题。
PS = r'''
$ErrorActionPreference = 'Stop'
$T = '@ROOT@\tests\_t4'
$data = Join-Path $T 'data'
$lib  = Join-Path $T 'lib'
New-Item -ItemType Directory -Force -Path $data | Out-Null
New-Item -ItemType Directory -Force -Path $lib  | Out-Null
Copy-Item '@ROOT@\core.ps1' (Join-Path $data 'core.ps1') -Force

$out = @()
function chk($n, $c, $x) {
  if ($c) { $script:out += ('  [通过] ' + $n) }
  else { $script:out += ('  [失败] ' + $n + '  -> ' + [string]$x) }
}

# --- 临时数据目录里的假图库 + 假 state/config（不读真实目录） ---
# 口径照真实数据：`history` / `hist_at` 记的都是**整文件名去掉扩展名**
# （聚焦图 = `日期_中文标题_hash_slug`，必应图 = 去掉 `-Ewo` 后缀那一段），
# Resolve-BwPanelName 拿它补上 .jpg/.png… 去目录里找真文件。
$mk = @(
  @('2026-10-20_第一张_a0000001_oldone', '2026-10-20 08:00:00'),
  @('2026-10-21_第二张_a0000002_second', '2026-10-21 10:00:00'),
  @('2026-10-22_第三张_a0000003_third',  '2026-10-22 11:00:00'),
  @('2026-10-23_第四张_a0000004_fourth', '2026-10-23 12:00:00'),
  @('2026-10-24_第五张_a0000005_fifth',  '2026-10-24 14:58:42')
)
foreach ($m in $mk) { Set-Content -LiteralPath (Join-Path $lib ($m[0] + '.jpg')) -Value 'x' -Encoding ASCII }

[ordered]@{
  bing_save_dir      = $lib
  spotlight_save_dir = $lib
  local_src_dir      = ''
  cycle_minutes      = 30
  auto_fetch         = $false
  desktop_shortcut   = 'off'
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $data 'config.json') -Encoding UTF8

# history = 追加表(越靠后越新)；中间塞一条"文件已经不在库里"的 ghost，验证会被跳过
$histNames = @($mk[0][0], '2026-10-21_早就删掉的_ghostimg', $mk[1][0], $mk[2][0], $mk[3][0], $mk[4][0])
$atMap = [ordered]@{}
for ($i = 0; $i -lt 5; $i++) { $atMap[$mk[$i][0]] = $mk[$i][1] }
$atMap['2026-10-21_早就删掉的_ghostimg'] = '2026-10-21 09:00:00'
[ordered]@{
  schema    = 8
  favorites = @()
  queue     = @()
  shown     = 5
  last_wall = (Join-Path $lib ($mk[4][0] + '.jpg'))
  last_swap = '2026-10-25 14:58:42'
  history   = $histNames
  hist_at   = $atMap
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $data 'state.json') -Encoding UTF8

. (Join-Path $data 'core.ps1')
chk '临时数据目录生效(没读到真实 %LOCALAPPDATA%\壁纸助手)' ($global:BWRoot -eq $data) ($global:BWRoot + ' vs ' + $data)

$s = Get-BwPanelState
chk 'Get-BwPanelState 正常返回' ($s.ok -eq $true) ($s | ConvertTo-Json -Depth 1 -Compress)

$h = @($s.history)
$names = @($h | ForEach-Object { [string]$_.name })
$short = @($names | ForEach-Object { Split-Path $_ -Leaf })
$out += ('名单(应为从新到旧): ' + ($short -join ' | '))

chk '第一条就是最新换上的那张(fifth)' ($names.Count -gt 0 -and $names[0] -like '*fifth') ($short -join ',')
chk '顺序是从新到旧, 不是从旧到新' ($names -join ',' -eq (($mk[4][0], $mk[3][0], $mk[2][0], $mk[1][0], $mk[0][0]) -join ',')) ($short -join ',')
chk '文件已不在库里的 ghostimg 被跳过' (@($names | Where-Object { $_ -like '*ghostimg*' }).Count -eq 0) ($short -join ',')
chk '只回真实存在的 5 张' ($names.Count -eq 5) $names.Count

$at = @{}
foreach ($x in $h) { $at[[string]$x.name] = [string]$x.at }
chk '每条都带上了 hist_at 的换上时间' ($at[$mk[4][0]] -eq '2026-10-24 14:58:42') $at[$mk[4][0]]
chk '面板角标能直接切出 MM-DD' ($at[$mk[4][0]].Substring(5, 5) -eq '10-24') $at[$mk[4][0]]
chk '最旧那条也有时间(角标不会再退回图片日期)' ($at[$mk[0][0]].Length -eq 19) $at[$mk[0][0]]

# --- 2026-10-25 第二半: history 记的其实是"图片编号"(末尾 slug), 不是文件名 ---
# 真实现场: 15:40 刚换上的那张(文件 2026-10-08_一片极度干旱的海岸_…_skeletoncoastnamibia.jpg,
# history 里记的是 skeletoncoastnamibia)在「最近换过」里查不到, 排第一的还是上一张。
# 根因: state.json 的 history 存的是 Get-BwNameKey 的输出(聚焦图 = 文件名末尾那段 slug),
# 而面板只按"文件名 -> 路径"的索引去查, 聚焦图那几条永远查不到。
$mk2 = @(
  @('2026-10-06_蓝色鹦嘴鱼_a0000008_blueparrotfish',      'blueparrotfish',      '2026-10-25 14:58:42'),
  @('2026-10-08_一片极度干旱的海岸_a0000009_skeletoncoastnamibia', 'skeletoncoastnamibia', '2026-10-25 15:40:03')
)
foreach ($m in $mk2) { Set-Content -LiteralPath (Join-Path $lib ($m[0] + '.jpg')) -Value 'x' -Encoding ASCII }
# 必应图没有 slug, history 记的就是整个文件名 —— 两种口径混在同一份名单里, 得同时吃下
$bingName = '2026-10-24_湖畔的秋'
Set-Content -LiteralPath (Join-Path $lib ($bingName + '.jpg')) -Value 'x' -Encoding ASCII

$at2 = [ordered]@{}
foreach ($m in $mk2) { $at2[$m[1]] = $m[2] }
$at2[$bingName] = '2026-10-24 16:00:00'
[ordered]@{
  schema    = 8
  favorites = @()
  queue     = @()
  shown     = 3
  last_wall = (Join-Path $lib ($mk2[1][0] + '.jpg'))
  last_swap = '2026-10-25 15:40:03'
  history   = @($bingName, $mk2[0][1], $mk2[1][1])
  hist_at   = $at2
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $data 'state.json') -Encoding UTF8
$global:BwPanelIdxCache = $null
$s4 = Get-BwPanelState
$n4 = @($s4.history | ForEach-Object { [string]$_.name })
$out += ('名单(编号也能查图): ' + ($n4 -join ' | '))
chk '最新那张聚焦图(只记了 slug)现在能出现在第一位' ($n4.Count -gt 0 -and $n4[0] -like '*skeletoncoastnamibia') (($n4 -join ','))
chk '回给面板的 name 是真实文件名(点"设为壁纸"才找得回这张)' ($n4[0] -eq $mk2[1][0]) $n4[0]
chk '第二条也是聚焦图的 slug, 同样补成了文件名' ($n4.Count -gt 1 -and $n4[1] -eq $mk2[0][0]) (($n4 -join ','))
chk '必应图(整文件名口径)不受影响' ($n4.Count -gt 2 -and $n4[2] -eq $bingName) (($n4 -join ','))
$at4 = @{}
foreach ($x in @($s4.history)) { $at4[[string]$x.name] = [string]$x.at }
chk 'slug 查出来的那条也带上了 hist_at 的时间' ($at4[$mk2[1][0]] -eq '2026-10-25 15:40:03') $at4[$mk2[1][0]]
chk '路径真的指向库里的文件' (Test-Path -LiteralPath ([string]@($s4.history)[0].path)) ([string]@($s4.history)[0].path)

# --- 回归: 空 history 不能炸 ---
$null = Remove-Item -LiteralPath (Join-Path $data 'state.json') -Force
@{ schema = 8; favorites = @(); queue = @(); history = @() } | ConvertTo-Json -Depth 4 |
  Set-Content -LiteralPath (Join-Path $data 'state.json') -Encoding UTF8
$global:BwPanelIdxCache = $null
try {
  $s2 = Get-BwPanelState
  chk '空 history 也正常返回(history 为空表)' (@($s2.history).Count -eq 0) (@($s2.history).Count)
} catch {
  chk '空 history 也正常返回(history 为空表)' $false $_.Exception.Message
}

# --- 回归: 老 state 里根本没有 hist_at 这个键（history 仍是"越靠后越新"） ---
@{ schema = 8; favorites = @(); queue = @(); history = @($mk[3][0], $mk[4][0]) } | ConvertTo-Json -Depth 4 |
  Set-Content -LiteralPath (Join-Path $data 'state.json') -Encoding UTF8
$global:BwPanelIdxCache = $null
try {
  $s3 = Get-BwPanelState
  $n3 = @($s3.history | ForEach-Object { [string]$_.name })
  chk '没有 hist_at 的旧 state 仍能出图(按新到旧)' ($n3 -join ',' -eq (($mk[4][0], $mk[3][0]) -join ',')) (($n3 | ForEach-Object { Split-Path $_ -Leaf }) -join ',')
  chk '没有 hist_at 时 at 给空串(面板据此回落图片日期)' ([string]@($s3.history)[0].at -eq '') ([string]@($s3.history)[0].at)
} catch {
  chk '没有 hist_at 的旧 state 仍能出图(按新到旧)' $false $_.Exception.Message
}

# 结果写文件再读：这台机器的控制台是 GBK，中文直接 print 会花屏（同 gen_state_test.py）
$out | Set-Content -LiteralPath (Join-Path $T 'out.txt') -Encoding UTF8
exit 0
'''


def main():
    if os.path.isdir(T):
        shutil.rmtree(T, ignore_errors=True)
    os.makedirs(os.path.join(T, 'data'), exist_ok=True)
    os.makedirs(os.path.join(T, 'lib'), exist_ok=True)
    run = os.path.join(T, 'run.ps1')
    # .ps1 必须带 UTF-8 BOM：PS 5.1 对无 BOM 文件按 ANSI 读中文 -> 解析失败（本项目踩过）
    with open(run, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(PS.replace('@ROOT@', ROOT))
    p = subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', run],
                       capture_output=True, cwd=ROOT)
    err = (p.stderr or b'').decode('utf-8', 'replace')
    if not err.strip():
        err = (p.stderr or b'').decode('gbk', 'replace')
    if p.returncode != 0:
        print('PowerShell 退出码 %s\n%s' % (p.returncode, err.strip()[:2000]))
    outp = os.path.join(T, 'out.txt')
    fails = 0
    if os.path.isfile(outp):
        with open(outp, encoding='utf-8-sig') as f:
            for line in f:
                line = line.rstrip('\n')
                if not line.strip():
                    continue
                if '[失败]' in line:
                    fails += 1
                print(line)
    else:
        print('没生成 out.txt（脚本没跑完）')
        fails = 1
    print('')
    print('未通过 %d 项' % fails if fails else '全部通过')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
