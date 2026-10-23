# 作者: 海风（kele551）
# 用途: 演练「老客户端连主程序一起自动替换」这条路（v2.3.3 -> 2.4.0）。
#   与 drill_upgrade.ps1 的区别：那个只换脚本（min_launcher 设成 2.3.3）；
#   这个把 min_launcher 设成当前版本，逼它走 Invoke-BwLauncherUpdate：
#     下载新 exe -> 写 <exe>.new -> 起隐藏小助手 -> 等旧进程退出 -> 覆盖 exe -> 用新版本重启。
#   全程在临时目录 + MWA_DATA 隔离，不碰用户真实数据目录与真实 exe。
param(
  # 默认取脚本所在目录的上一级（仓库根），换台机器也能跑
  [string]$Repo = (Split-Path $PSScriptRoot -Parent)
)
$ErrorActionPreference = 'Stop'
# 一律用 PATH 里的 git / python（仓库里不许写本机路径）
$git = 'git'
$py = 'python'

$root = Join-Path $env:TEMP ('mwa_launcher_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$client = Join-Path $root 'client'
$web = Join-Path $root 'web'
New-Item -ItemType Directory -Force -Path $client, $web, (Join-Path $client 'bing'), (Join-Path $client '聚焦') | Out-Null

$fails = 0
function Assert($cond, $m) {
  if ($cond) { Write-Host "  [PASS] $m" } else { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }
}

$oldExe = Get-ChildItem $Repo -Filter '*2.3.3.exe' | Select-Object -First 1
if (-not $oldExe) { Write-Host '找不到 v2.3.3 的 exe，演练中止' -ForegroundColor Red; exit 2 }
$newExe = Join-Path $Repo '壁纸助手.exe'
if (-not (Test-Path $newExe)) { Write-Host '找不到新 exe（先打包）'; exit 2 }

try {
  # ── 1) 造老客户端：v2.3.3 脚本 + v2.3.3 exe（名字用老的）──
  & $git -C $Repo show 'v2.3.3:core.ps1' > (Join-Path $client 'core.ps1')
  & $git -C $Repo show 'v2.3.3:menu.ps1' > (Join-Path $client 'menu.ps1')
  Copy-Item $oldExe.FullName (Join-Path $client '微软壁纸助手.exe') -Force
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText((Join-Path $client 'launcher.txt'), (Join-Path $client '微软壁纸助手.exe'), $enc)
  Set-Content -LiteralPath (Join-Path $client '.version') -Value '2.3.3' -Encoding ASCII
  Set-Content -LiteralPath (Join-Path $client '.launcher-version') -Value '2.3.3' -Encoding ASCII
  [System.IO.File]::WriteAllText((Join-Path $client 'config.json'), (@{
    bing_save_dir = (Join-Path $client 'bing'); spotlight_save_dir = (Join-Path $client '聚焦')
    resolution_mode = 'auto'; spotlight_per_cycle = 6; cycle_minutes = 30
    wallpaper_style = 'fill'; desktop_shortcut = 'off'; lib_cap = 200; bing_cap = 200
    fetch_round_cap = 6; fetch_day_cap = 20; recycle_min_days = 30
    art_fit_mode = 'off'; src_timeout_sec = 20; auto_fetch = $false; fav_only = $false
  } | ConvertTo-Json -Depth 4), $enc)
  [System.IO.File]::WriteAllText((Join-Path $client 'state.json'), (@{ schema = 8; history = @(); favorites = @(); queue = @(); last_wall = ''; last_swap = ''; shown = 0; dl_total = 0; dl_filled = 0; strangers = @(); refills = 0 } | ConvertTo-Json -Depth 4), $enc)

  $oldSha = (Get-FileHash (Join-Path $client '微软壁纸助手.exe') -Algorithm SHA256).Hash
  Write-Host "老客户端就绪：exe=$($oldSha.Substring(0,12))  .version=2.3.3"

  # ── 2) 本地升级源：新脚本 + 新 exe，min_launcher 设成当前版本（逼它换主程序）──
  $port = 0
  $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
  $l.Start(); $port = ([System.Net.IPEndPoint]$l.LocalEndpoint).Port; $l.Stop()
  $base = "http://127.0.0.1:$port/"
  Copy-Item (Join-Path $Repo 'core.ps1') $web -Force
  Copy-Item (Join-Path $Repo 'menu.ps1') $web -Force
  Copy-Item $newExe (Join-Path $web 'new-exe.bin') -Force
  $ver = (Get-Content (Join-Path $Repo 'version.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version
  $vj = @{
    version = $ver
    min_launcher = $ver
    notes = ''
    scripts = @{
      'core.ps1' = @{ sha256 = (Get-FileHash (Join-Path $Repo 'core.ps1') -Algorithm SHA256).Hash; url = $base + 'core.ps1' }
      'menu.ps1' = @{ sha256 = (Get-FileHash (Join-Path $Repo 'menu.ps1') -Algorithm SHA256).Hash; url = $base + 'menu.ps1' }
    }
    launcher = @{
      sha256 = (Get-FileHash (Join-Path $web 'new-exe.bin') -Algorithm SHA256).Hash
      url = $base + 'new-exe.bin'
      size = (Get-Item (Join-Path $web 'new-exe.bin')).Length
    }
  }
  [System.IO.File]::WriteAllText((Join-Path $web 'version.json'), ($vj | ConvertTo-Json -Depth 6), $enc)
  if (-not $env:MWA_ED25519_KEY) { Write-Host '  没设 MWA_ED25519_KEY，演练跳过' -ForegroundColor Yellow; exit 0 }
  & $py (Join-Path $Repo 'tools\sign_version_json.py') (Join-Path $web 'version.json') | Out-Null
  Assert (Test-Path (Join-Path $web 'version.json.sig')) '演练源已签名'

  $srv = Start-Process $py -ArgumentList @('-m', 'http.server', "$port", '--bind', '127.0.0.1', '--directory', $web) -PassThru -WindowStyle Hidden
  Start-Sleep -Milliseconds 900

  # ── 3) 老客户端执行升级（会走"换主程序"分支）──
  $env:MWA_DATA = $client
  $drv = @'
$ErrorActionPreference = 'Stop'
$dir = $args[0]; $url = $args[1]
. (Join-Path $dir 'core.ps1')
$global:BWUpdateUrls = @($url + 'version.json')
$r = Invoke-BwScriptUpdate -Quiet -Force
"升级函数返回: $r"
'@
  $drvFile = Join-Path $root 'drive.ps1'
  [System.IO.File]::WriteAllText($drvFile, $drv, (New-Object System.Text.UTF8Encoding($true)))
  & powershell -NoProfile -ExecutionPolicy Bypass -File $drvFile $client $base 2>&1 | ForEach-Object { "    $_" }

  # ── 4) 等小助手把 exe 换掉（最多 90 秒）──
  $target = Join-Path $client '微软壁纸助手.exe'
  $ok = $false
  for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Seconds 1
    $now = (Get-FileHash $target -Algorithm SHA256).Hash
    if ($now -eq (Get-FileHash (Join-Path $web 'new-exe.bin') -Algorithm SHA256).Hash) { $ok = $true; break }
  }
  Assert $ok ("主程序被自动替换成新版本（等了 $i 秒）")
  # 注意：.version / .launcher-version 是**新 exe 启动后**（sync_payload）才写的，
  # 所以这两个断言要放到第 5 步之后，别在这里断言（2026-10-23 第一次跑就是这么误报的）。
  $ulp = Join-Path $client 'update-launcher.log'
  $ulog = ''
  if (Test-Path $ulp) { $ulog = Get-Content $ulp -Raw -Encoding UTF8 }
  Assert ($ulog -match '已覆盖主程序') '小助手日志里有「已覆盖主程序」'
  Write-Host '    ---- update-launcher.log ----'
  if ($ulog) { $ulog -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { "    $_" } }

  # ── 5) 换完的主程序能开控制台 ──
  $env:BWPANEL_NOBROWSER = '1'
  $env:BWPANEL_NOUPDATE = '1'
  $log = Join-Path $client 'wallpaper.log'
  $before = 0
  if (Test-Path $log) { $before = @(Get-Content $log -Encoding UTF8 | Where-Object { $_ -match '本地服务已启动' }).Count }
  $p2 = Start-Process $target -PassThru -WindowStyle Hidden
  $url2 = ''
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 400
    if (-not (Test-Path $log)) { continue }
    $ls = @(Get-Content $log -Encoding UTF8 | Where-Object { $_ -match '本地服务已启动' })
    if ($ls.Count -gt $before) { $url2 = ($ls[-1] -split '-> ')[-1].Trim(); break }
  }
  Assert ([bool]$url2) '升级后的主程序把控制台起起来了'
  if ($url2) {
    $b2 = ($url2 -split '\?')[0].TrimEnd('/')
    $tok = ([regex]::Match($url2, 't=([a-f0-9]+)')).Groups[1].Value
    $st = Invoke-WebRequest -Uri "$b2/api/state?t=$tok" -UseBasicParsing -TimeoutSec 15
    $sj = [System.Text.Encoding]::UTF8.GetString($st.RawContentStream.ToArray()) | ConvertFrom-Json
    Assert ($sj.scriptVer -eq $ver) "控制台报的脚本版本 = $($sj.scriptVer)"
    Assert ($sj.launcherVer -eq $ver) "控制台报的主程序版本 = $($sj.launcherVer)"
    $vnow = (Get-Content (Join-Path $client '.version') -Raw -Encoding ASCII).Trim()
    Assert ($vnow -eq $ver) "数据目录 .version 升到 $vnow"
    $lnow = ''
    try { $lnow = (Get-Content (Join-Path $client '.launcher-version') -Raw -Encoding ASCII).Trim() } catch {}
    Assert ($lnow -eq $ver) "数据目录 .launcher-version 升到 $lnow"
    [void](Invoke-WebRequest -Uri "$b2/api/do?t=$tok&do=quit" -UseBasicParsing -TimeoutSec 10)
  }
  Stop-Process -Id $p2.Id -Force -ErrorAction SilentlyContinue
} finally {
  if ($srv) { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue }
  # 清掉演练拉起的进程（只认路径在本演练目录里的）
  foreach ($pn in @('微软壁纸助手.exe')) {
    Get-CimInstance Win32_Process -Filter ("Name='" + $pn + "'") | ForEach-Object {
      $path = $null
      try { $path = (Get-Process -Id $_.ProcessId).Path } catch {}
      if ($path -and $path.StartsWith($root)) { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
  }
  Remove-Item Env:MWA_DATA -ErrorAction SilentlyContinue
  Remove-Item Env:BWPANEL_NOBROWSER -ErrorAction SilentlyContinue
  Remove-Item Env:BWPANEL_NOUPDATE -ErrorAction SilentlyContinue
  if (Test-Path $root) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($fails -gt 0) { Write-Host "主程序替换演练: $fails 项失败" -ForegroundColor Red; exit 1 }
Write-Host '主程序替换演练: 全部通过' -ForegroundColor Green
exit 0
