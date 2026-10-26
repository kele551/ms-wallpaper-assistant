# -*- coding: utf-8 -*-
# 作者: 海风（kele551）
"""桌面壁纸 2026-10-26：控制台端口不许落在浏览器「不安全端口」禁行表里。

现场：本机 11:33 系统随机发到 6666，core.ps1 照常把服务起起来、日志写着
「面板: 本地服务已启动 -> http://127.0.0.1:6666/」，脚本直连取同一地址能拿到
完整 108,934 B 页面和 /api/state 200 —— 但浏览器**根本不发这个请求**，直接
ERR_UNSAFE_PORT，用户点图标就是「控制台打不开」。连点三次还被「已经在跑, 直接复用」
指回同一个死端口。

禁行表两家（本文件末尾 BANNED 就是这两张表的并集）：
  Firefox   netwerk/base/nsIOService.cpp  kRestrictedPorts   （83 项）
  Chromium  net/base/port_util.cc         kRestrictedPorts   （81 项，是前者的子集，
              只少 4190 sieve / 6679 osaut）
Edge 跟 Chromium 同一张表。

core.ps1 一执行就干活（513 KB，读配置、动壁纸），所以照四款一贯的做法只把要测的
几个定义摘出来（$global:BwBannedBrowserPorts / Test-BwBrowserSafePort /
Get-BwPanelOsPort / Get-BwPanelPort），补个 Log 桩交给 PowerShell 跑。
第 4 组把 Get-BwPanelOsPort 顶成桩（真机动态端口段会漂，拿运气当判据的测试时灵时不灵），
这样「系统发到 6666 时到底绕不绕」是每次都一样的。

用法：
    python tests\\test_panel_port.py
    python tests\\test_panel_port.py <core.ps1 路径>
"""
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.environ.get('BW_SRC') or os.path.dirname(HERE)
CORE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(SRC, 'core.ps1')

# 上游两家禁行表并集（少一个就是漏判，多一个就是把正常端口误杀）
BANNED = [
    0, 1, 7, 9, 11, 13, 15, 17, 19, 20, 21, 22, 23, 25, 37, 42, 43, 53, 69, 77, 79, 87, 95,
    101, 102, 103, 104, 109, 110, 111, 113, 115, 117, 119, 123, 135, 137, 139, 143, 161, 179,
    389, 427, 465, 512, 513, 514, 515, 526, 530, 531, 532, 540, 548, 554, 556, 563, 587, 601,
    636, 989, 990, 993, 995, 1719, 1720, 1723, 2049, 3659, 4045, 4190, 5060, 5061, 6000, 6566,
    6665, 6666, 6667, 6668, 6669, 6679, 6697, 10080,
]

FAILS = []


def check(name, cond, extra=''):
    if cond:
        print('[ok] %s' % name)
    else:
        print('[X ] %s  %s' % (name, extra))
        FAILS.append(name)


def extract():
    """从 core.ps1 里摘出三个定义，不写死行号。"""
    lines = open(CORE, encoding='utf-8', errors='replace').read().splitlines()
    try:
        start = next(i for i, l in enumerate(lines) if l.startswith('$global:BwBannedBrowserPorts'))
        stop = next(i for i, l in enumerate(lines) if l.startswith('function Send-BwPanelResponse'))
    except StopIteration:
        check('core.ps1 里有面板端口那三个定义', False, '没找到锚点（改过名字就同步改本测试）')
        return None
    blob = '\n'.join(lines[start:stop]).rstrip()
    check('摘到的块含三个函数',
          all(('function ' + f) in blob for f in
              ('Get-BwPanelPort', 'Get-BwPanelOsPort', 'Test-BwBrowserSafePort')), blob[:80])
    check('块位置对（第 %d 行起，到 Send-BwPanelResponse 前）' % (start + 1), bool(blob))
    return blob


def table_of(blob):
    seg = blob[blob.index('@('):blob.index(')\n\nfunction Test')]
    return sorted(set(int(x) for x in re.findall(r'\d+', seg)))


def main():
    print('被测: %s' % CORE)
    blob = extract()
    if blob is None:
        return 1

    print('---- 1) 禁行表内容与上游两家并集一致')
    tbl = table_of(blob)
    check('条数 %d' % len(tbl), tbl == sorted(BANNED), '得到 %d 条: %s' % (len(tbl), tbl))
    check('少了:', sorted(set(BANNED) - set(tbl)) == [], sorted(set(BANNED) - set(tbl)))
    check('多了:', sorted(set(tbl) - set(BANNED)) == [], sorted(set(tbl) - set(BANNED)))
    check('今天实际踩到的 6666 在表里', 6666 in tbl)

    print('---- 2) 判据本身（表里的、1024 以下都算不安全；正常端口不误杀）')
    harness = "$ErrorActionPreference = 'Stop'\nfunction Log($m, $lvl = '') { }\n" + blob + r"""
$bad = @()
foreach ($p in @(25,53,143,389,1719,1723,2049,4190,5060,5061,6000,6566,6665,6666,6667,6668,6669,6679,6697,10080)) {
  if (Test-BwBrowserSafePort $p) { Write-Host ('[X ] 禁行端口 ' + $p + ' 被放行'); $bad += ('ban' + $p) }
}
foreach ($p in @(1,80,443,900,1023)) {
  if (Test-BwBrowserSafePort $p) { Write-Host ('[X ] 低端口 ' + $p + ' 被放行'); $bad += ('low' + $p) }
}
foreach ($p in @(1024,8000,8787,8788,8906,45944,49152,63334)) {
  if (-not (Test-BwBrowserSafePort $p)) { Write-Host ('[X ] 正常端口 ' + $p + ' 被误杀'); $bad += ('ok' + $p) }
}
Write-Host ('判据不符条数: ' + $bad.Count)
if ($bad.Count -gt 0) { Write-Host ($bad -join ',') }
exit $bad.Count
"""
    tmp = tempfile.mkdtemp(prefix='bwport-')
    ps1 = os.path.join(tmp, 't.ps1')
    open(ps1, 'w', encoding='utf-8-sig').write(harness)   # PowerShell 要 BOM，否则中文注释打断解析
    r = subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps1],
                       capture_output=True)
    print((r.stdout.decode('gbk', 'ignore') or r.stderr.decode('gbk', 'ignore')).strip())
    check('判据全部符合', r.returncode == 0, r.returncode)

    print('---- 3) 连挑 200 次端口：一个禁行端口都不许出现，且当场真能 bind')
    loop = "$ErrorActionPreference = 'Stop'\nfunction Log($m, $lvl = '') { }\n" + blob + r"""
$picks = @()
for ($i = 0; $i -lt 200; $i++) { $picks += (Get-BwPanelPort) }
$hit = @($picks | Where-Object { $_ -le 0 -or ($_ -lt 1024) -or ($global:BwBannedBrowserPorts -contains $_) })
$rng = $picks | Measure-Object -Minimum -Maximum
Write-Host ('200 次取值区间 ' + $rng.Minimum + '-' + $rng.Maximum + '，踩雷 ' + $hit.Count + ' 次')
$one = Get-BwPanelPort
$ok = $false
try { $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $one); $l.Start(); $l.Stop(); $ok = $true } catch { }
Write-Host ('现挑 ' + $one + ' 当场可开: ' + $ok)
exit $(if ($hit.Count -eq 0 -and $ok) { 0 } else { 1 })
"""
    ps2 = os.path.join(tmp, 'loop.ps1')
    open(ps2, 'w', encoding='utf-8-sig').write(loop)
    r2 = subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps2],
                        capture_output=True)
    print((r2.stdout.decode('gbk', 'ignore') or r2.stderr.decode('gbk', 'ignore')).strip())
    check('200 次都不踩雷', r2.returncode == 0, r2.returncode)

    print('---- 4) 反证（确定性）：把系统取端口换成桩，禁行端口必须被绕开')
    # 本机动态端口段是会漂的（今天 11:33 压在 1254–1453 才会发到 6666，下午又跳到 52000+），
    # 所以「拿真机连发几千次看会不会撞雷」不能当判据 —— 改成把 Get-BwPanelOsPort 顶掉，
    # 让它一定发到禁行端口，看 Get-BwPanelPort 绕不绕。绕不动就是过滤没生效。
    stub = "$ErrorActionPreference = 'Stop'\n" + blob + r"""
function Log($m, $lvl = '') { $script:logs += $m }
$script:bad = @()
$script:Fake = 6666
function Get-BwPanelOsPort { return $script:Fake }

# 4a) 系统死发 6666：不许原样返回，必须走兜底，且兜底端口当场能 bind
foreach ($fake in @(6666, 6566, 10080, 5060, 4190, 143, 80, 1023, 0)) {
  $script:Fake = $fake; $script:logs = @()
  $p = Get-BwPanelPort
  if ($p -eq $fake) { $script:bad += ('原样返回了 ' + $fake) }
  if ($p -gt 0 -and -not (Test-BwBrowserSafePort $p)) { $script:bad += ('返回了禁行端口 ' + $p) }
  if ($script:logs.Count -lt 8) { $script:bad += ('' + $fake + ' 只试了 ' + $script:logs.Count + ' 次就放弃') }
  $bind = $false
  if ($p -gt 0) { try { $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p); $l.Start(); $l.Stop(); $bind = $true } catch { } }
  if ($p -gt 0 -and -not $bind) { $script:bad += ('兜底端口 ' + $p + ' 开不了') }
  Write-Host ('  桩发到 ' + $fake + ' -> 实得 ' + $p + '，可开 ' + $bind)
}

# 4b) 系统发的是安全端口：要立刻采纳，不许白绕一圈（否则说明过滤把正常路径也堵了）
$script:Fake = 45944; $script:logs = @()
$p = Get-BwPanelPort
if ($p -ne 45944) { $script:bad += ('安全端口没采纳，返回了 ' + $p) }
if ($script:logs.Count -ne 0) { $script:bad += ('安全端口却绕了 ' + $script:logs.Count + ' 圈') }
Write-Host ('  桩发到 45944 -> 实得 ' + $p + '（应当原样采纳）')

# 4c) 前几次撞雷、后面走运：要在第 4 次就收手，而不是一路兜底
$script:Seq = @(6666, 6667, 5060, 45000); $script:i = 0
function Get-BwPanelOsPort { $v = $script:Seq[$script:i]; $script:i++; return $v }
$p = Get-BwPanelPort
if ($p -ne 45000) { $script:bad += ('序列取端口返回了 ' + $p) }
Write-Host ('  桩发到 6666,6667,5060,45000 -> 实得 ' + $p + '（应当是 45000）')

foreach ($b in $script:bad) { Write-Host ('[X ] ' + $b) }
Write-Host ('反证不符条数: ' + $script:bad.Count)
exit $(if ($script:bad.Count -eq 0) { 0 } else { 1 })
"""
    ps3 = os.path.join(tmp, 'stub.ps1')
    open(ps3, 'w', encoding='utf-8-sig').write(stub)
    r3 = subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps3],
                        capture_output=True)
    print((r3.stdout.decode('gbk', 'ignore') or r3.stderr.decode('gbk', 'ignore')).strip())
    check('系统发到禁行端口一定被绕开', r3.returncode == 0, r3.returncode)

    # 4d) 真机连发仅供参考：本机动态端口段压在低区时才会撞雷，压在高区就一次不撞，
    #     所以这里只打印、不做判据（判据在上面的桩测里）。
    raw = r"""
$tbl = @(6000,6566,6665,6666,6667,6668,6669,6679,6697,10080,5060,5061,4190,2049,1719,1720,1723,389,143,53,25,1,7,9,11,13,15,17,19,20,21,22,23,37,42,43,77,79,87,95,101,102,103,104,109,110,111,113,115,117,119,123,135,137,139,161,179,427,465,512,513,514,515,526,530,531,532,540,548,554,556,563,587,601,636,989,990,993,995,3659,4045)
$n = 0; $banned = 0; $min = 99999; $max = 0
for ($i = 0; $i -lt 1500; $i++) {
  $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
  $l.Start(); $p = ([System.Net.IPEndPoint]$l.LocalEndpoint).Port; $l.Stop(); $n++
  if ($p -lt $min) { $min = $p }; if ($p -gt $max) { $max = $p }
  if ($tbl -contains $p) { $banned++ }
}
Write-Host ('（参考）系统裸发 ' + $n + ' 次：区间 ' + $min + '-' + $max + '，命中禁行表 ' + $banned + ' 次')
"""
    ps4 = os.path.join(tmp, 'raw.ps1')
    open(ps4, 'w', encoding='utf-8-sig').write(raw)
    r4 = subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps4],
                        capture_output=True)
    print((r4.stdout.decode('gbk', 'ignore') or r4.stderr.decode('gbk', 'ignore')).strip())

    print('---- 5) 整份 core.ps1 语法')
    syn = ("$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile('%s',[ref]$null,[ref]$e);"
           "Write-Host ('语法错误数: '+$e.Count);$e|Select-Object -First 3|ForEach-Object{Write-Host $_.Message}") % CORE.replace("'", "''")
    ps5 = os.path.join(tmp, 'syn.ps1')
    open(ps5, 'w', encoding='utf-8-sig').write(syn)
    r5 = subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps5],
                        capture_output=True)
    out5 = (r5.stdout.decode('gbk', 'ignore') or r5.stderr.decode('gbk', 'ignore')).strip()
    print(out5)
    check('core.ps1 语法通过', '语法错误数: 0' in out5, out5[:120])

    print('\n%s  失败 %d 条' % ('全部通过' if not FAILS else '有失败', len(FAILS)))
    return 0 if not FAILS else 1


if __name__ == '__main__':
    sys.exit(main())
