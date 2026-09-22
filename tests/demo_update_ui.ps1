# 演示升级界面（不会真的升级任何东西）
# 用法: powershell -ExecutionPolicy Bypass -File 演示升级界面.ps1
$ErrorActionPreference = 'Continue'
$repo = 'F:\Harness\projects\微软壁纸助手\repo'
$sb   = Join-Path $env:TEMP 'bwui-demo'
$feed = Join-Path $env:TEMP 'bwui-feed'
Remove-Item $sb, $feed -Recurse -Force -ErrorAction SilentlyContinue
New-Item $sb, $feed -ItemType Directory -Force | Out-Null
foreach ($nm in 'core.ps1', 'menu.ps1') { Copy-Item (Join-Path $repo $nm) $sb -Force }
foreach ($nm in 'core.ps1', 'menu.ps1') {
  $txt = [System.IO.File]::ReadAllText((Join-Path $repo $nm))
  [System.IO.File]::WriteAllText((Join-Path $feed $nm), $txt + "`n# 演示", (New-Object System.Text.UTF8Encoding($true)))
}
$sc = @{}
foreach ($nm in 'core.ps1', 'menu.ps1') {
  $p = Join-Path $feed $nm
  $sc[$nm] = @{ sha256 = (Get-FileHash $p -Algorithm SHA256).Hash; url = ('file:///' + $p.Replace('\', '/')) }
}
$ver = (Select-String -Path (Join-Path $repo 'launcher.py') -Pattern "^VERSION\s*=\s*'([^']+)'").Matches[0].Groups[1].Value
$parts = $ver.Split('.'); $parts[-1] = [string]([int]$parts[-1] + 1); $new = ($parts -join '.')
$vj = [pscustomobject]@{ version = $new; min_launcher = $ver; notes = '演示'; scripts = $sc; launcher = @{ sha256 = ''; url = ''; size = 0 } }
$vj | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $feed 'version.json') -Encoding UTF8
Set-Content (Join-Path $sb '.version') $ver -NoNewline -Encoding ASCII
Set-Content (Join-Path $sb '.launcher-version') $ver -NoNewline -Encoding ASCII
$cfg = [pscustomobject]@{ update_url = (Join-Path $feed 'version.json'); cycle_minutes = 30; bing_save_dir = (Join-Path $sb '必应'); spotlight_save_dir = (Join-Path $sb '聚焦'); spotlight_per_cycle = 6; lib_cap = 0 }
$cfg | ConvertTo-Json | Set-Content (Join-Path $sb 'config.json') -Encoding UTF8
Write-Host ''
Write-Host ('  演示: 假装本机是 v' + $ver + ', 升级源上是 v' + $new) -ForegroundColor DarkGray
. (Join-Path $sb 'core.ps1')
Start-Sleep -Seconds 1
[void](Invoke-BwScriptUpdate -Force -Animated)
Write-Host '  (演示结束; 真实升级会在校验通过后自动替换脚本)' -ForegroundColor DarkGray
Remove-Item $sb, $feed -Recurse -Force -ErrorAction SilentlyContinue