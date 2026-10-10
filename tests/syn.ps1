# 2026-10-10: 路径不再写死作者机器的 F:\wp-src，改成按脚本自身位置推导
# （core.ps1 / menu.ps1 就在 tests 的上一级）。
# 另外这个文件原本**没有 UTF-8 BOM** —— 本仓库的规矩是 .ps1 必须带 BOM
# （PS 5.1 对无 BOM 的文件按 ANSI 读，中文会乱码并解析失败），已一并补上。
$root = Split-Path -Parent $PSScriptRoot
$p = Join-Path $PSScriptRoot 'syn_out.txt'
Set-Content -LiteralPath $p -Value @('start') -Encoding UTF8
try {
  Add-Content -LiteralPath $p -Value ('PSVersion ' + $PSVersionTable.PSVersion.ToString()) -Encoding UTF8
  Add-Content -LiteralPath $p -Value ('LanguageMode ' + $ExecutionContext.SessionState.LanguageMode) -Encoding UTF8
  foreach ($f in @((Join-Path $root 'core.ps1'), (Join-Path $root 'menu.ps1'))) {
    $t = $null
    $e = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$t, [ref]$e)
    if ($e -and ($e.Count -gt 0)) {
      Add-Content -LiteralPath $p -Value ('ERR ' + $f + ' count=' + $e.Count) -Encoding UTF8
      foreach ($x in $e) { Add-Content -LiteralPath $p -Value ('    ' + $x.Message) -Encoding UTF8 }
    } else {
      Add-Content -LiteralPath $p -Value ('OK  ' + $f) -Encoding UTF8
    }
  }
} catch {
  Add-Content -LiteralPath $p -Value ('EXC ' + $_.Exception.Message) -Encoding UTF8
}
