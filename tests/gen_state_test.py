# -*- coding: utf-8 -*-
# 作者: 海风（kele551）
# 用途: 「库裁剪保住收藏」+「后台写回不吞用户操作」两条判据的 PowerShell 单测
#       （2026-10-25 待办 #64）。
#
# 为什么要单独一套：tests/test_all.py 测的是打包后的 exe（安装、搬迁、payload 一致），
# 这两条是 core.ps1 里**纯逻辑**的判断（谁该被裁掉、两份 state 怎么合并），
# 只能把 core.ps1 点源进一个临时数据目录，喂假数据、把回收站那一步 stub 掉才测得动。
#
# 安全: 全程只动 tests\_t3 下的临时目录；真正移进回收站的 Move-BwToRecycle 被换成
#       "只记名字不删文件"的桩，真实图库与回收站一个字节都不碰。
import os
import subprocess
import sys

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
T = os.path.join(HERE, '_t3')

PS = r'''
$ErrorActionPreference = 'Stop'
$T = '@T@'
$data = Join-Path $T 'data'
$lib = Join-Path $T 'lib'
New-Item -ItemType Directory -Force -Path $data | Out-Null
New-Item -ItemType Directory -Force -Path $lib | Out-Null
Copy-Item '@ROOT@\core.ps1' (Join-Path $data 'core.ps1') -Force

$out = @()
function chk($n, $c, $x) {
  if ($c) { $script:out += ('  [通过] ' + $n) }
  else { $script:out += ('  [失败] ' + $n + '  -> ' + [string]$x) }
}

. (Join-Path $data 'core.ps1')
chk 'core.ps1 已点源进临时目录(没碰真实数据目录)' ($global:BWRoot -eq $data) $global:BWRoot

# 回收站这一步换成桩：只记账, 文件留在原地（真实库与真实回收站不受影响）
$script:moved = @()
function Move-BwToRecycle([string]$path) { $script:moved += [System.IO.Path]::GetFileName($path); return $true }

# ============ 场景 A: 库超上限裁剪, 收藏/当前壁纸必须保住 ============
# 聚焦的文件名口径是 `日期_中文标题_hash_slug.jpg`，而「看过」名单存的是 Get-BwNameKey
# 折出来的 **slug**，收藏夹存的是**整文件名** —— 两边口径不一样，这个用例就是专门盯这个。
$names = @()
for ($i = 1; $i -le 10; $i++) {
  $n = ('2026-10-{0:D2}_第{1}张_{2:D6}.jpg' -f $i, $i, $i)
  Set-Content -LiteralPath (Join-Path $lib $n) -Value 'x' -Encoding ASCII
  $names += $n
}
$sA = [PSCustomObject]@{
  schema = 8
  # 收藏：一张按整文件名存（面板/菜单就是这么写的）、一张按裸 slug 存（老数据口径）
  favorites = @($names[2], '000007')
  history = @('000001', '000002', '000003', '000004', '000005', '000007')
  queue = @()
  last_wall = (Join-Path $lib $names[4])   # 当前正显示的是 000005
  last_swap = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  shown = 1
  hist_at = @{}
}
$script:moved = @()
$null = Trim-BwOneDir $sA $lib 4 '测试库'
# 桩记的是文件名，而判据里比对的是 Get-BwNameKey 折出来的 slug —— 先归一化再比，
# 不然 `-contains '000003'` 永远为假，"收藏被裁掉了"这种失败会被断言自己吞掉。
$mv = @($script:moved | ForEach-Object { Get-BwNameKey $_ })
chk 'A 本轮裁掉 6 张(10 张 - 上限 4)' ($mv.Count -eq 6) ($mv.Count)
chk 'A 收藏的那张(整文件名口径)没被裁' (-not ($mv -contains '000003')) ($mv -join ',')
chk 'A 收藏的那张(裸 slug 口径)没被裁' (-not ($mv -contains '000007')) ($mv -join ',')
chk 'A 当前壁纸那张没被裁' (-not ($mv -contains '000005')) ($mv -join ',')
chk 'A 先看过的先淘汰(000001/000002/000004 在列)' (($mv -contains '000001') -and ($mv -contains '000002') -and ($mv -contains '000004')) ($mv -join ',')
chk 'A 没看过的按名字补位(000006/000008/000009)' (($mv -contains '000006') -and ($mv -contains '000008') -and ($mv -contains '000009')) ($mv -join ',')
chk 'A 库里文件没真被删(stub 生效)' (@(Get-ChildItem -LiteralPath $lib -File).Count -eq 10) (@(Get-ChildItem -LiteralPath $lib -File).Count)

# 上限设 0 = 不裁
$script:moved = @()
$null = Trim-BwOneDir $sA $lib 0 '测试库'
chk 'A 上限 0 = 不限制, 一张都不动' ($script:moved.Count -eq 0) ($script:moved -join ',')

# ============ 场景 A2: 必应库口径 ============
# 必应图叫 `bing001abc-Ewo1.jpg`，Get-BwNameKey 折出来是**去掉扩展名的整名**
# （名字里没有"下划线 + 6 位以上小写"那种 slug），收藏夹存的却是带 .jpg 的名字 ——
# 和聚焦一样是两套口径，同样得护住。
$libB = Join-Path $T 'libB'
New-Item -ItemType Directory -Force -Path $libB | Out-Null
$bnames = @()
for ($i = 1; $i -le 5; $i++) {
  $n = ('bing{0:D3}abc-Ewo{1}.jpg' -f $i, $i)
  Set-Content -LiteralPath (Join-Path $libB $n) -Value 'x' -Encoding ASCII
  $bnames += $n
}
$sB = [PSCustomObject]@{
  schema = 8
  favorites = @($bnames[1])                 # 带 .jpg 的收藏（面板/菜单写进去的就是这个口径）
  history = @('bing001abc-Ewo1', 'bing002abc-Ewo2', 'bing003abc-Ewo3')
  queue = @(); last_wall = ''; last_swap = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  shown = 1; hist_at = @{}
}
$script:moved = @()
$null = Trim-BwOneDir $sB $libB 2 '必应测试库'
$mvB = @($script:moved | ForEach-Object { Get-BwNameKey $_ })
chk 'A2 收藏的那张必应图没被裁' (-not ($mvB -contains 'bing002abc-Ewo2')) ($mvB -join ',')
chk 'A2 其余看过的照旧裁(001/003 在列)' (($mvB -contains 'bing001abc-Ewo1') -and ($mvB -contains 'bing003abc-Ewo3')) ($mvB -join ',')

# ============ 场景 B: 后台写回 state 不能吞掉用户刚做的事 ============
$fmt = 'yyyy-MM-dd HH:mm:ss'
$old = (Get-Date).AddHours(-2).ToString($fmt)
$new = (Get-Date).ToString($fmt)

# 磁盘上这份 = 用户刚刚在菜单里操作过的那份
$disk = [PSCustomObject]@{
  schema = 8
  favorites = @('用户刚收藏的.jpg')
  history = @('h1', 'h2')
  queue = @('q1.jpg', 'q2.jpg')
  last_wall = 'Z:\壁纸\用户刚挑的.jpg'
  last_swap = $new
  shown = 50
  dl_total = 7
  hist_at = @{ h1 = $new; h2 = $new }
}
Save-BwJsonAtomic $global:BWState $disk | Out-Null

# 手里这份 = 后台几分钟前读的旧快照 + 它自己这几分钟干的活
$mem = [PSCustomObject]@{
  schema = 8
  favorites = @('旧快照里的收藏.jpg')
  history = @('h2', 'h3')
  queue = @('q1.jpg', '', $null, 'q2.jpg')
  last_wall = 'Z:\壁纸\后台换的那张.jpg'
  last_swap = $old
  shown = 10
  dl_total = 0
  hist_at = @{ h2 = $old; h9 = $old }
}
Save-BwStateKeepFav $mem
$back = Get-BwState

chk 'B 收藏夹以磁盘为准(用户刚收藏的还在)' ((@(Get-BwFav $back)).Count -eq 1) ((@(Get-BwFav $back)) -join ',')
chk 'B 用户刚收藏的那张没被旧快照顶掉' ([string](@($back.favorites)[0]) -eq '用户刚收藏的.jpg') (@($back.favorites) -join ',')
chk 'B 旧快照里的收藏没混进来' (-not (@($back.favorites) -contains '旧快照里的收藏.jpg')) (@($back.favorites) -join ',')
$hist = @($back.history)
chk 'B 看过名单取并集(h1/h2/h3 都在)' (($hist -contains 'h1') -and ($hist -contains 'h2') -and ($hist -contains 'h3')) ($hist -join ',')
chk 'B 累计显示数不倒退(取磁盘那份的 50)' ([int]$back.shown -eq 50) ([string]$back.shown)
chk 'B 当前壁纸听更新的那个(磁盘 last_swap 更新)' ([string]$back.last_wall -eq 'Z:\壁纸\用户刚挑的.jpg') ([string]$back.last_wall)
chk 'B 队列里的空洞被裁掉(只剩 2 项)' (@(@($back.queue | Where-Object { $_ })).Count -eq 2) (@($back.queue) -join '|')
$at = Get-BwHistAt $back
chk 'B 每张图时间戳只留还在名单里的(h1/h2 在)' ($at.ContainsKey('h1') -and $at.ContainsKey('h2')) (($at.Keys) -join ',')
chk 'B 名单外的时间戳被摘掉(h9 不留在 state 里)' (-not $at.ContainsKey('h9')) (($at.Keys) -join ',')

# B2: 内存这份才是最新的(后台刚换了图) -> 当前壁纸该听后台的
$disk2 = [PSCustomObject]@{ schema = 8; favorites = @(); history = @(); queue = @()
  last_wall = 'Z:\壁纸\旧的.jpg'; last_swap = $old; shown = 3; dl_total = 0; hist_at = @{} }
Save-BwJsonAtomic $global:BWState $disk2 | Out-Null
$mem2 = [PSCustomObject]@{ schema = 8; favorites = @(); history = @(); queue = @()
  last_wall = 'Z:\壁纸\后台刚换的.jpg'; last_swap = $new; shown = 2; dl_total = 0; hist_at = @{} }
Save-BwStateKeepFav $mem2
$back2 = Get-BwState
chk 'B2 后台更新时当前壁纸听后台的' ([string]$back2.last_wall -eq 'Z:\壁纸\后台刚换的.jpg') ([string]$back2.last_wall)
chk 'B2 即便后台的 shown 更小也不许倒退' ([int]$back2.shown -eq 3) ([string]$back2.shown)

Set-Content -LiteralPath (Join-Path $T 'out.txt') -Value $out -Encoding UTF8
'跑完: ' + (@($out | Where-Object { $_ -like '*[失败]*' }).Count) + ' 项失败'
'''

PS = PS.replace('@ROOT@', ROOT).replace('@T@', T)


def main():
    if os.path.isdir(T):
        import shutil
        shutil.rmtree(T, ignore_errors=True)
    os.makedirs(os.path.join(T, 'data'), exist_ok=True)
    os.makedirs(os.path.join(T, 'lib'), exist_ok=True)
    run = os.path.join(T, 'run.ps1')
    # PS 5.1 按 ANSI 读无 BOM 的 .ps1 —— 本仓库的规矩：.ps1 必须 UTF-8 BOM
    with open(run, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(PS)
    p = subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', run],
                       capture_output=True, cwd=ROOT)
    try:
        err = p.stderr.decode('utf-8', 'replace')
        if not err.strip():
            err = p.stderr.decode('gbk', 'replace')
    except Exception:
        err = repr(p.stderr[:400])
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
