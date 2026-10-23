# 作者: 海风（kele551）
# 用途: 真正的升级演练 —— 拿 v2.3.3 的旧脚本当"老客户端"，用本地 http 升级源升到当前版本，
#       验证：① 老客户端能升上来 ② 升上来之后网页控制台能用 ③ 升级源被改坏时必须拒绝并保留旧版。
#       全程在临时目录里，不碰用户真实数据（MWA_DATA 也只在这一份副本上生效）。
param(
  [string]$Repo = (Split-Path $PSScriptRoot -Parent)
)
$ErrorActionPreference = 'Stop'
$git = 'git'
$node = 'python'

$root = Join-Path $env:TEMP ('mwa_drill_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$old = Join-Path $root 'client'
$web = Join-Path $root 'web'
New-Item -ItemType Directory -Force -Path $old, $web, (Join-Path $old 'bing'), (Join-Path $old '聚焦') | Out-Null

function SayOk($m) { Write-Host "  [PASS] $m" }
function SayBad($m) { Write-Host "  [FAIL] $m" }
$fails = 0
function Assert($cond, $m) {
  if ($cond) { SayOk $m } else { SayBad $m; $script:fails++ }
}

try {
  # ── 1) 造"老客户端"：v2.3.3 的两份脚本 + 数据 ──
  & $git -C $Repo show 'v2.3.3:core.ps1' | Out-File (Join-Path $old 'core.ps1') -Encoding utf8
  & $git -C $Repo show 'v2.3.3:menu.ps1' | Out-File (Join-Path $old 'menu.ps1') -Encoding utf8
  # git show 经管道会加 BOM/换行差异，这里改用字节直出，保证是"真旧版"
  & $git -C $Repo show 'v2.3.3:core.ps1' > (Join-Path $old 'core.ps1')
  & $git -C $Repo show 'v2.3.3:menu.ps1' > (Join-Path $old 'menu.ps1')
  # 2026-10-16 起升级要先验签; 验签要调主程序 --verify-update, 所以老客户端也得有 exe + launcher.txt
  $oldExe = Get-ChildItem $Repo -Filter '*.exe' | Where-Object { $_.Name -like '*2.3.3*' } | Select-Object -First 1
  if ($oldExe) {
    Copy-Item $oldExe.FullName (Join-Path $old '壁纸助手.exe') -Force
    # 必须 UTF-8（-Encoding ASCII 会把中文 exe 名写成问号，程序就找不到主程序、拒绝升级）
    [System.IO.File]::WriteAllText((Join-Path $old 'launcher.txt'), (Join-Path $old '壁纸助手.exe'), (New-Object System.Text.UTF8Encoding($false)))
  } else {
    SayBad '找不到 v2.3.3 的 exe（升级验签要用）'
    $script:fails++
  }
  Set-Content -LiteralPath (Join-Path $old '.version') -Value '2.3.3' -Encoding ASCII
  Set-Content -LiteralPath (Join-Path $old '.launcher-version') -Value '2.3.3' -Encoding ASCII

  $enc = New-Object System.Text.UTF8Encoding($false)
  $cfg = @{
    bing_save_dir = (Join-Path $old 'bing'); spotlight_save_dir = (Join-Path $old '聚焦')
    resolution_mode = 'auto'; spotlight_per_cycle = 6; cycle_minutes = 30
    wallpaper_style = 'fill'; desktop_shortcut = 'off'; lib_cap = 200; bing_cap = 200
    fetch_round_cap = 6; fetch_day_cap = 20; recycle_min_days = 30
    art_fit_mode = 'off'; src_timeout_sec = 20; auto_fetch = $false; fav_only = $false
  } | ConvertTo-Json -Depth 4
  [System.IO.File]::WriteAllText((Join-Path $old 'config.json'), $cfg, $enc)
  [System.IO.File]::WriteAllText((Join-Path $old 'state.json'),
    (@{ schema = 8; history = @(); favorites = @(); queue = @(); last_wall = ''
        last_swap = ''; shown = 0; dl_total = 0; dl_filled = 0; strangers = @(); refills = 0 } | ConvertTo-Json -Depth 4), $enc)

  if (-not $env:MWA_ED25519_KEY) { Write-Host '  [SKIP] 没给 MWA_ED25519_KEY（升级验签要私钥才能签演练源），跳过演练'; exit 0 }
  $oldCoreSha = (Get-FileHash (Join-Path $old 'core.ps1') -Algorithm SHA256).Hash
  $oldMenuSha = (Get-FileHash (Join-Path $old 'menu.ps1') -Algorithm SHA256).Hash
  Write-Host "老客户端就绪：.version=2.3.3  core.ps1=$($oldCoreSha.Substring(0,12))"

  # ── 2) 本地升级源：当前版本的 version.json + 两个脚本（只绑回环）──
  $port = 0
  $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
  $l.Start(); $port = ([System.Net.IPEndPoint]$l.LocalEndpoint).Port; $l.Stop()
  $base = "http://127.0.0.1:$port/"

  $ver = (Get-Content (Join-Path $Repo 'version.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version
  Copy-Item (Join-Path $Repo 'core.ps1') $web -Force
  Copy-Item (Join-Path $Repo 'menu.ps1') $web -Force
  $vj = @{
    version = $ver
    min_launcher = '2.3.3'          # 演练只换脚本，不换 exe（真发版是 2.4.0，会自动覆盖主程序）
    notes = ''
    scripts = @{
      'core.ps1' = @{ sha256 = (Get-FileHash (Join-Path $Repo 'core.ps1') -Algorithm SHA256).Hash; url = $base + 'core.ps1' }
      'menu.ps1' = @{ sha256 = (Get-FileHash (Join-Path $Repo 'menu.ps1') -Algorithm SHA256).Hash; url = $base + 'menu.ps1' }
    }
  }
  [System.IO.File]::WriteAllText((Join-Path $web 'version.json'), ($vj | ConvertTo-Json -Depth 6), $enc)
  # 升级源必须先验签(2.3.3 起), 所以这份演练用的 version.json 也要用真私钥签一次
  & $node (Join-Path $PSScriptRoot 'sign_version_json.py') (Join-Path $web 'version.json') | Out-Null
  Assert (Test-Path (Join-Path $web 'version.json.sig')) '演练用的 version.json 已签名'

  $srv = Start-Process $node -ArgumentList @('-m','http.server',"$port",'--bind','127.0.0.1','--directory',$web) -PassThru -WindowStyle Hidden
  Start-Sleep -Milliseconds 800
  try {
    $probe = Invoke-WebRequest -Uri ($base + 'version.json') -UseBasicParsing -TimeoutSec 5
    Assert ($probe.StatusCode -eq 200) "本地升级源可访问（127.0.0.1:$port）"
  } catch { Assert $false "本地升级源起不来：$($_.Exception.Message)" }

  # ── 3) 老客户端执行升级 ──
  $drv = @'
$ErrorActionPreference = 'Stop'
$dir = $args[0]; $url = $args[1]
. (Join-Path $dir 'core.ps1')
$global:BWUpdateUrls = @($url + 'version.json')
$ok = Invoke-BwScriptUpdate -Quiet -Force
"升级函数返回: $ok"
'@
  $drvFile = Join-Path $root 'drive_update.ps1'
  [System.IO.File]::WriteAllText($drvFile, $drv, (New-Object System.Text.UTF8Encoding($true)))
  & powershell -NoProfile -ExecutionPolicy Bypass -File $drvFile $old $base 2>&1 | ForEach-Object { "    $_" }

  if (((Get-Content (Join-Path $old '.version') -Raw -Encoding ASCII).Trim()) -ne $ver) {
    $lg = Join-Path $old 'wallpaper.log'
    if (Test-Path $lg) {
      Write-Host '    老客户端日志尾（用来判断为什么没升成）:'
      Get-Content $lg -Tail 14 -Encoding UTF8 | ForEach-Object { Write-Host "      $_" }
    }
  }
  $newVer = (Get-Content (Join-Path $old '.version') -Raw -Encoding ASCII).Trim()
  $newCoreSha = (Get-FileHash (Join-Path $old 'core.ps1') -Algorithm SHA256).Hash
  $newMenuSha = (Get-FileHash (Join-Path $old 'menu.ps1') -Algorithm SHA256).Hash
  Assert ($newVer -eq $ver) "老客户端的 .version 从 2.3.3 升到 $newVer"
  Assert ($newCoreSha -ne $oldCoreSha) "core.ps1 真的被换掉了"
  Assert ($newCoreSha -eq (Get-FileHash (Join-Path $Repo 'core.ps1') -Algorithm SHA256).Hash) "换上去的 core.ps1 与当前版本逐字节一致"
  Assert ($newMenuSha -eq (Get-FileHash (Join-Path $Repo 'menu.ps1') -Algorithm SHA256).Hash) "换上去的 menu.ps1 与当前版本逐字节一致"

  # ── 4) 升上来的客户端能开控制台 ──
  $env:BWPANEL_NOBROWSER = '1'
  $env:BWPANEL_NOUPDATE = '1'
  $log = Join-Path $old 'wallpaper.log'
  $before = 0
  if (Test-Path $log) { $before = @(Get-Content $log -Encoding UTF8 | Where-Object { $_ -match '本地服务已启动' }).Count }
  $proc = Start-Process 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$(Join-Path $old 'menu.ps1')`"") -PassThru -WindowStyle Hidden
  $url2 = ''
  try {
    for ($i = 0; $i -lt 60; $i++) {
      Start-Sleep -Milliseconds 300
      if (-not (Test-Path $log)) { continue }
      $ls = @(Get-Content $log -Encoding UTF8 | Where-Object { $_ -match '本地服务已启动' })
      if ($ls.Count -gt $before) { $url2 = ($ls[-1] -split '-> ')[-1].Trim(); break }
    }
    Assert ([bool]$url2) "升级后的客户端把控制台起起来了"
    if ($url2) {
      $page = Invoke-WebRequest -Uri $url2 -UseBasicParsing -TimeoutSec 10
      $html = [System.Text.Encoding]::UTF8.GetString($page.RawContentStream.ToArray())
      Assert ($html -match '桌面壁纸 · 控制台') "控制台页面能打开（有新界面）"
      $tok = ([regex]::Match($html, 'var TOKEN = "([a-f0-9]{32})"')).Groups[1].Value
      Assert ([bool]$tok) "页面里注入了一次性令牌"
      $b2 = ($url2 -split '\?')[0].TrimEnd('/')
      $st = Invoke-WebRequest -Uri "$b2/api/state?t=$tok" -UseBasicParsing -TimeoutSec 10
      $sj = [System.Text.Encoding]::UTF8.GetString($st.RawContentStream.ToArray()) | ConvertFrom-Json
      Assert ($sj.scriptVer -eq $ver) "控制台报的脚本版本 = $ver（实际 $($sj.scriptVer)）"
      [void](Invoke-WebRequest -Uri "$b2/api/do?t=$tok&do=quit" -UseBasicParsing -TimeoutSec 10)
    }
  } finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
  }

  # ── 5) 失败分支：升级源被改坏，必须拒绝并保留当前版本 ──
  $bad = Join-Path $root 'badweb'
  New-Item -ItemType Directory -Force -Path $bad | Out-Null
  Copy-Item (Join-Path $web 'core.ps1') $bad -Force
  Copy-Item (Join-Path $web 'menu.ps1') $bad -Force
  $vj2 = $vj.Clone()
  $vj2.version = '9.9.9'
  $vj2.scripts = @{
    'core.ps1' = @{ sha256 = ('0' * 64); url = $base + 'core.ps1' }
    'menu.ps1' = @{ sha256 = ('0' * 64); url = $base + 'menu.ps1' }
  }
  [System.IO.File]::WriteAllText((Join-Path $bad 'version.json'), ($vj2 | ConvertTo-Json -Depth 6), $enc)
  # 坏版本号那份也要签名 —— 要测的是"指纹对不上就拒绝", 不是"没签名就拒绝"
  & $node (Join-Path $PSScriptRoot 'sign_version_json.py') (Join-Path $bad 'version.json') | Out-Null
  $shaBefore = (Get-FileHash (Join-Path $old 'core.ps1') -Algorithm SHA256).Hash
  $verBefore = (Get-Content (Join-Path $old '.version') -Raw -Encoding ASCII).Trim()
  $drv2 = @'
$ErrorActionPreference = 'Stop'
$dir = $args[0]; $url = $args[1]
. (Join-Path $dir 'core.ps1')
$global:BWUpdateUrls = @($url + 'version.json')
try { $r = Invoke-BwScriptUpdate -Quiet -Force; "返回: $r" } catch { "抛错: $($_.Exception.Message)" }
'@
  $drvFile2 = Join-Path $root 'drive_bad.ps1'
  [System.IO.File]::WriteAllText($drvFile2, $drv2, (New-Object System.Text.UTF8Encoding($true)))
  # 把坏掉的 version.json 放到同一个升级源上（脚本文件不动），再来一次升级
  Copy-Item (Join-Path $bad 'version.json') (Join-Path $web 'version.json') -Force
  & powershell -NoProfile -ExecutionPolicy Bypass -File $drvFile2 $old $base 2>&1 | ForEach-Object { "    $_" }
  $shaAfter = (Get-FileHash (Join-Path $old 'core.ps1') -Algorithm SHA256).Hash
  $verAfter = (Get-Content (Join-Path $old '.version') -Raw -Encoding ASCII).Trim()
  Assert ($shaAfter -eq $shaBefore) "指纹对不上时 core.ps1 一个字节都没被改"
  Assert ($verAfter -eq $verBefore) "指纹对不上时 .version 保持在 $verBefore（不会被写成 9.9.9）"

} finally {
  if ($srv) { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue }
  Remove-Item Env:BWPANEL_NOBROWSER -ErrorAction SilentlyContinue
  Remove-Item Env:BWPANEL_NOUPDATE -ErrorAction SilentlyContinue
  if (Test-Path $root) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($fails -gt 0) {
  Write-Host "升级演练: $fails 项失败" -ForegroundColor Red
  exit 1
}
Write-Host "升级演练: 全部通过" -ForegroundColor Green
exit 0
