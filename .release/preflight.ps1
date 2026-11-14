# 桌面壁纸发版闸门 —— 由 .release/config.json 的 gates 驱动，逻辑通用。
# 任一条不符就 throw，release_run.py 会因此中止，不上传任何文件。
# 规则来源：原有的 version/署名/仓库地址三道闸门，这里只是把它们从 workflow 里搬出来，
# 让"校验"和"通用发版流程"分开：流程只有一份，校验规则归项目自己。

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$cfg = Get-Content -Raw -Encoding utf8 (Join-Path $root '.release/config.json') | ConvertFrom-Json
$gates = $cfg.gates
if (-not $gates) { Write-Host '未配置 gates，跳过闸门'; exit 0 }

# ---- 1. 源码版本 vs version.json ----
$srcRel, $const = $cfg.version_source -split ':', 2
$srcTxt = Get-Content -Raw -Encoding utf8 (Join-Path $root $srcRel)
if ($srcTxt -notmatch "$const\s*=\s*'([0-9.]+)'") { throw "在 $srcRel 里找不到 $const 常量" }
$srcVer = $Matches[1]
Write-Host "源码 $const = $srcVer"

$vj = Get-Content -Raw -Encoding utf8 (Join-Path $root 'version.json') | ConvertFrom-Json
Write-Host "version.json = $($vj.version)"
if ($srcVer -ne $vj.version) {
  throw "$srcRel 的 $const（$srcVer）与 version.json（$($vj.version)）不一致 —— 先对齐再发版"
}

# ---- 2. exe 文件版本 / 署名 ----
$exeName = ($cfg.outputs | Select-Object -First 1)
$exe = Get-Item (Join-Path $root $exeName)
$fv = "$($exe.VersionInfo.FileVersion)".Trim()
$company = "$($exe.VersionInfo.CompanyName)".Trim()
$comments = "$($exe.VersionInfo.Comments)".Trim()
Write-Host "exe 文件版本 = $fv | $($exe.Length) B"
Write-Host "CompanyName  = $company"
Write-Host "Comments     = $comments"

if (-not $fv.StartsWith($vj.version)) {
  throw "exe 文件版本（$fv）与 version.json（$($vj.version)）不一致"
}
if ($gates.expect_company -and $company -ne $gates.expect_company) {
  throw "CompanyName 署名不对：$company（应为 $($gates.expect_company)）"
}

# ---- 3. 仓库地址 ----
if ($gates.expect_repo_suffix) {
  if (-not $gates.repo_const_file) { throw 'gates 配了 expect_repo_suffix 但没给 repo_const_file' }
  $rf, $rc = $gates.repo_const_file -split ':', 2
  $rt = Get-Content -Raw -Encoding utf8 (Join-Path $root $rf)
  if ($rt -notmatch "$rc\s*=\s*'([^']+)'") { throw "在 $rf 里找不到 $rc" }
  $appRepo = $Matches[1]
  if ($appRepo -notmatch "^[a-z]+\.com/$([regex]::Escape($gates.expect_repo_suffix))$") {
    throw "$rf 的 $rc 不对（应为 *.$($gates.expect_repo_suffix) 的形式）：$appRepo"
  }
  if ($comments -ne $appRepo) {
    throw "exe 注释里的仓库地址（$comments）与 $rf 的 $rc（$appRepo）不一致"
  }
  Write-Host "仓库地址 = $appRepo（与 exe 注释一致）"
}

Write-Host '三道闸门全部通过'
