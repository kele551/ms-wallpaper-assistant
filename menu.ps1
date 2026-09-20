# 微软壁纸助手 - 菜单 (by 海风 & 小腾)
. (Join-Path $PSScriptRoot 'core.ps1')

$global:BWVersion = '1.5.5'

# 把用户按键归一化: 去首尾空格 + 全角转半角 + 转小写。
# 中文输入法很容易把 o 打成全角 ｏ, 不归一化就变成"按了键没反应"。
function Normalize-BwKey([string]$s) {
  if (-not $s) { return '' }
  $out = foreach ($ch in $s.Trim().ToCharArray()) {
    $c = [int][char]$ch
    if ($c -eq 0x3000) { ' ' }
    elseif ($c -ge 0xFF01 -and $c -le 0xFF5E) { [char]($c - 0xFEE0) }
    else { $ch }
  }
  return ((-join $out).Trim()).ToLower()
}

function Pause-Bw { Write-Host ''; Read-Host '  按回车返回菜单' | Out-Null }
function Today-Str { return (Get-Date -Format 'yyyy-MM-dd') }
# 库的口径: 只数这一层的 .jpg, 不往子目录里钻。
# 用户会把图挪进子目录、删掉、或者搬到别处 —— 口径必须稳定可预期:
# "库里有几张" 就等于 "能轮换到几张", 两个数不会对不上。
function Count-Jpg([string]$dir) {
  return @(Get-ChildItem -LiteralPath $dir -File -Filter *.jpg -ErrorAction SilentlyContinue).Count
}
function Left-Queue($s) { return @($s.queue | Where-Object { $_ }).Count }

# 两个库通常放在同一个父目录下面 ("壁纸\必应" 和 "壁纸\聚焦"), 那就显示父目录;
# 万一被改成了两个分开的地方, 就分别显示, 不合并成一个看不出所以然的路径。
function Get-BwBaseOf($c) {
  $pb = ''
  $ps = ''
  try { $pb = Split-Path $c.bing_save_dir -Parent } catch {}
  try { $ps = Split-Path $c.spotlight_save_dir -Parent } catch {}
  if ($pb -and $ps -and ($pb -eq $ps)) { return $pb }
  return ''
}

# ---------- 工具: 必须是绝对路径, 免得用户输了相对路径后写到自己都不知道的地方 ----------
function Test-BwPathShape([string]$p) {
  if (-not $p) { return $false }
  if ($p -match '^[A-Za-z]:\\') { return $true }
  if ($p -match '^\\\\[^\\]+\\') { return $true }   # UNC \\server\share
  return $false
}
function Open-BwDir([string]$dir) {
  if (-not (Test-Path -LiteralPath $dir)) { $null = Ensure-BwDirs }
  if (Test-Path -LiteralPath $dir) {
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $dir) | Out-Null }
    catch { Write-Host ('  打不开文件夹: ' + $dir) }
  } else { Write-Host ('  文件夹还不存在: ' + $dir) }
}

# ---------- 挑一个盘: 只排序, 不筛选 ----------
# 这个向导只**排序**, 不**筛选**。
#
# "某个盘现在能不能写"是每台机器各自的权限设置, 不是本程序的产品规则 ——
# 所以每一个盘都要出现在列表里、每一个都能被选中。默认值只是"排在最前面的那个",
# 它不剥夺任何人选别的盘的权利。
# (v1.2.2 把写不进去的盘从编号列表里剔了出去, 那等于用我这一台机器的权限去替
#  所有 GitHub 用户做决定: 用户看到自己的盘不在列表里, 会以为程序不支持那个盘,
#  而实际只是那台机器上少了一条 ACL。v1.2.3 改回全列出, 不能写的当场给一键修复。)
#
# 排列方式: 非系统盘在前 (能用的在前, 同档按可用空间从大到小), 系统盘固定放最后。
function Get-BwOrderedDrives {
  $all  = @(Get-BwDriveChoices)
  $data = @($all | Where-Object { -not $_.Sys })
  $sys  = @($all | Where-Object { $_.Sys })
  return @($data + $sys)
}

# 用户挑了一个这台机器上写不进去的位置 -> 解释清楚 + 给两条路,
# 绝不静默退回默认位置 (那正是"用户以为程序不支持他的盘"的来源)。
# 返回修好之后的路径; 用户不修、或修不成, 返回空串。
function Resolve-BwUnwritableBase([string]$base) {
  $drive = ''
  if ($base -match '^([A-Za-z]):\\') { $drive = $Matches[1] + '\' }
  Write-Host ''
  Write-Host ('  ' + $base + ' 现在写不进去。') -ForegroundColor Yellow
  if ($drive) {
    Write-Host ('  最常见的原因: ' + $drive + ' 的根目录没给普通用户"新建文件夹"的权限。') -ForegroundColor DarkGray
    Write-Host '  那是这台机器的权限设置, 不是本程序不支持这个盘 —— 盘上别的目录也可能照样能写。' -ForegroundColor DarkGray
  } else {
    Write-Host '  可能原因: 路径不存在、没有权限, 或者网络盘没连上。' -ForegroundColor DarkGray
  }
  Write-Host ''
  Write-Host ('   [1] 现在就修好它 —— 用一次管理员权限建出 ' + $base) -ForegroundColor Gray
  Write-Host '       并只给这一个文件夹授权 (不动盘根, 不动盘上别的目录;' -ForegroundColor DarkGray
  Write-Host '       删掉这个文件夹就等于完全回退, 不留任何权限改动)' -ForegroundColor DarkGray
  Write-Host '   [2] 我自己换一个位置'
  Write-Host '   回车 = 返回'
  $k = Normalize-BwKey (Read-Host '  怎么处理')
  if ($k -eq '1') {
    if (-not $drive) {
      Write-Host '  非本地盘符的位置没法自动创建, 请先自己把文件夹建好。' -ForegroundColor Yellow
      Pause-Bw
      return ''
    }
    Write-Host '  正在修复, 会弹一次管理员授权框...' -ForegroundColor DarkGray
    if (Repair-BwBaseDir $base) {
      Write-Host ('  修好了: ' + $base) -ForegroundColor Green
      Pause-Bw
      return $base
    }
    Write-Host '  没修成 —— 可能是授权被取消了, 或者这个位置不允许自动创建。' -ForegroundColor Yellow
    Pause-Bw
    return ''
  }
  return ''
}

# ---------- 选择壁纸文件夹 (首次运行向导和「设置」共用) ----------
# 返回选中的路径; 返回空串表示"这轮没选出来, 重新问一遍"。
function Select-BwBase([string]$suggest, [string]$suggestReason) {
  $cands = @()
  # 第一项固定是系统「图片」文件夹 —— 用户要的就是"图片库里的壁纸文件夹"。
  # 顺带把那个盘的剩余空间也印上, 跟下面各盘那一列对齐, 好看也好比。
  $picPath = Join-Path (Get-BwPicturesDir) '壁纸'
  $picExtra = '系统「图片」文件夹'
  $pd = ''
  if ($picPath -match '^([A-Za-z]):') { $pd = $Matches[1].ToUpper() + ':' }
  $drives = @(Get-BwOrderedDrives)
  if ($pd) {
    foreach ($ch in $drives) {
      if (([string]$ch.Name).ToUpper() -eq $pd) { $picExtra = '系统「图片」文件夹    可用 ' + [math]::Round($ch.Free / 1GB, 1) + ' GB'; break }
    }
  }
  $cands += [PSCustomObject]@{ Path = $picPath; Extra = $picExtra }
  foreach ($ch in $drives) {
    $tags = @()
    if (-not $ch.Writable) { $tags += '这台机器上还没给写入权限, 选中可一键修' }
    if ($ch.Sys) { $tags += '系统盘, 不推荐' }
    $extra = '可用 ' + [math]::Round($ch.Free / 1GB, 1) + ' GB'
    if ($tags.Count -gt 0) { $extra += '   (' + ($tags -join '; ') + ')' }
    $cands += [PSCustomObject]@{ Path = ($ch.Name + '\图片\壁纸'); Extra = $extra }
  }
  $manual = $cands.Count + 1
  $i = 0
  foreach ($cd in $cands) {
    $i++
    $mark = ''
    if ($suggest -and ($cd.Path -eq $suggest)) { $mark = '   <-- 建议' }
    Write-Host ('   [' + $i + '] ' + $cd.Path + '     ' + $cd.Extra + $mark)
  }
  Write-Host ('   [' + $manual + '] 我自己输入完整路径')
  Write-Host ''
  if ($suggest) {
    Write-Host ('   建议: ' + $suggest) -ForegroundColor Green
    if ($suggestReason) { Write-Host ('         ' + $suggestReason) -ForegroundColor DarkGray }
    Write-Host '   回车 = 用建议位置 · 也可以输入序号 · 或直接粘贴完整路径'
  } else {
    Write-Host '   输入序号, 或直接粘贴完整路径'
  }
  $in = Read-Host '  壁纸存哪'
  $t = ''
  if ($in) { $t = $in.Trim().Trim('"') }
  if (-not $t) { return $suggest }
  if ($t -match '^\d+$') {
    $idx = [int]$t
    if (($idx -lt 1) -or ($idx -gt $manual)) {
      Write-Host ('  没有 [' + $idx + '] 这一项 (共 ' + $manual + ' 个), 请重新选。') -ForegroundColor Yellow
      Pause-Bw
      return ''
    }
    if ($idx -eq $manual) {
      $p = Read-Host '  输入完整路径 (比如 D:\我的壁纸, 网络盘写 \\服务器\共享\目录)'
      if (-not $p) { return '' }
      return $p.Trim().Trim('"').TrimEnd('\')
    }
    return $cands[$idx - 1].Path
  }
  if (-not (Test-BwPathShape $t)) {
    Write-Host ''
    Write-Host ('  「' + $t + '」不是完整路径。要写成像 D:\壁纸 这样。') -ForegroundColor Yellow
    Pause-Bw
    return ''
  }
  return $t.TrimEnd('\')
}

# 把壁纸文件夹定下来并写进 config。下面的「必应」「聚焦」两个子目录顺手建好。
# 返回是否成功。
function Set-BwBase([string]$base) {
  $b = $base.TrimEnd('\')
  if (-not (Test-BwPathShape $b)) {
    Write-Host ('  要写完整路径, 比如 D:\壁纸 —— 已保持不变')
    return $false
  }
  $bing = Join-Path $b '必应'
  $spot = Join-Path $b '聚焦'
  if (-not ((Test-BwWritable $bing) -and (Test-BwWritable $spot))) {
    $fixed = Resolve-BwUnwritableBase $b
    if (-not $fixed) { Write-Host '  已保持不变。'; return $false }
    $b = $fixed
    $bing = Join-Path $b '必应'
    $spot = Join-Path $b '聚焦'
  }
  $c = Get-BwConfig
  $c.bing_save_dir = $bing
  $c.spotlight_save_dir = $spot
  Save-BwConfig $c
  # 位置换了, 老队列里的文件名已经对不上新目录, 重洗一次
  $s = Get-BwState
  $s.queue = @(Get-BwFreshQueue $s)
  Save-BwState $s
  Log ('保存位置: ' + $b)
  Write-Host ('  已设为 ' + $b)
  return $true
}

# ---------- [4] 从库里挑一张 ----------
function Show-BrowseAll {
  $c = Get-BwConfig
  $s = Get-BwState
  $files = @()
  foreach ($pair in @(@('必应', $c.bing_save_dir), @('聚焦', $c.spotlight_save_dir))) {
    $files += @(Get-ChildItem -LiteralPath $pair[1] -File -Filter *.jpg -ErrorAction SilentlyContinue |
      ForEach-Object { [PSCustomObject]@{ src = $pair[0]; file = $_ } })
  }
  $files = @($files | Sort-Object { $_.file.LastWriteTime } -Descending | Select-Object -First 40)
  if ($files.Count -eq 0) {
    Write-Host '  两个壁纸库现在都是空的。'
    Write-Host ('  位置: ' + $c.bing_save_dir)
    Write-Host '  菜单 [1] 会顺手抓图, [7] 补必应, 开着自动换也会自己攒起来。'
    return
  }
  Write-Host ('  —— 壁纸库 (最近 ' + $files.Count + ' 张, [必应]/[聚焦] 标来源, ★ = 已收藏) ——')
  Write-Host ('  所在文件夹: ' + $c.bing_save_dir)
  $i = 0
  foreach ($f in $files) {
    $star = '  '
    if (Test-BwFav $s ([string]$f.file.Name)) { $star = '★ ' }
    Write-Host ("  [$i] $star[$($f.src)] $($f.file.Name)")
    $i++
  }
  Write-Host '  [o] 打开文件夹    [q] 返回'
  Write-Host '  f+序号 = 收藏 / 取消收藏 (如 f3)'
  $sel = Normalize-BwKey (Read-Host '  输入序号设为壁纸')
  if ($sel -eq '' -or $sel -eq 'q') { return }
  if ($sel -eq 'o') {
    Open-BwDir $c.bing_save_dir
    Open-BwDir $c.spotlight_save_dir
    return
  }
  if ($sel -match '^f(\d+)$') {
    $idx = [int]$Matches[1]
    if (($idx -ge 0) -and ($idx -lt $files.Count)) {
      $nm = [string]$files[$idx].file.Name
      if (Add-BwFav $s $nm) {
        Save-BwState $s
        Write-Host ('  已收藏 ★ ' + $nm)
        Log ('收藏: ' + $nm)
      } else {
        [void](Remove-BwFav $s $nm)
        Save-BwState $s
        Write-Host ('  已取消收藏 ' + $nm)
        Log ('取消收藏: ' + $nm)
      }
    } else { Write-Host '  没有这一项' }
    return
  }
  try {
    $p = $files[[int]$sel].file.FullName
    $ok = Set-BwWallManual $s $p '手动浏览设壁纸'
    Write-Host ('  已设为壁纸 (ok=' + $ok + '): ' + (Split-Path $p -Leaf))
  } catch { Write-Host '  序号无效' }
}

# ---------- [8] 下载往期必应 (niumoo/bing-wallpaper, 2021-02 至今 4K) ----------
function Show-Archive {
  Write-Host '  归档范围: 2021-02 至今 (开源仓库 niumoo/bing-wallpaper, 4K)'
  $ym = Read-Host '  输入年-月 (如 2024-08), 回车返回'
  if (-not $ym) { return }
  if ((Normalize-BwKey $ym) -eq 'q') { return }
  $items = Get-BwMonthItems $ym
  if (-not $items -or $items.Count -eq 0) { Write-Host '  没取到清单 (检查网络, 或这个月不存在)'; Pause-Bw; return }
  $items | ForEach-Object { Write-Host ("    $($_.date)  $($_.code)") }
  Write-Host '  [1] 把这一个月全下下来   [2] 只下一张并设成壁纸   [3] 只下一张存着   [q] 返回'
  $k = Normalize-BwKey (Read-Host '  选择')
  if ($k -eq '1') { Invoke-BwArchiveBatch $ym; Pause-Bw }
  elseif ($k -eq '2' -or $k -eq '3') {
    $d = Read-Host '  输入日期 (如 2024-08-15)'
    if ($d) { Invoke-BwArchiveSingle $ym $d ($k -eq '2'); Pause-Bw }
  }
}

# ---------- [1] 立刻换一张 ----------
function Invoke-BwManualSwap {
  $null = Ensure-BwDirs
  $s = Get-BwState
  if ($s.last_bing_date -ne (Today-Str)) {
    $s.last_bing_date = (Today-Str)
    Write-Host '  (顺手记下今天必应已切, 免得下次进桌面又插一张必应)'
  }
  Invoke-BwSwap $s (Get-Date) '手动: 立刻换一张' | Out-Null
  Save-BwState $s
  if ($s.last_wall) { Write-Host ('  已更换: ' + (Split-Path $s.last_wall -Leaf)) }
}

# ---------- [3] 再抓一批新聚焦 ----------
function Invoke-BwRefill {
  $c = Get-BwConfig
  $null = Ensure-BwDirs
  $s = Get-BwState
  $want = [int]$c.spotlight_per_cycle
  $new = @(Invoke-SpotlightFetch -count $want -Quiet)
  if ($new.Count -gt 0) {
    # 新下的图立刻排进队列, 不用干等一整轮
    $s.queue = @(@($s.queue | Where-Object { $_ }) + $new)
    Save-BwState $s
  }
  Write-Host ('  聚焦库现在 ' + (Count-Jpg $c.spotlight_save_dir) + ' 张, 待换队列还剩 ' + (Left-Queue $s) + ' 张')
}

# ---------- [7] 补下最近错过的必应 ----------
function Invoke-BwBackfillManual {
  $null = Ensure-BwDirs
  $c = Get-BwConfig
  $before = (Count-Jpg $c.bing_save_dir)
  Write-Host '  正在检查缺口并补下载 (只下载, 不切壁纸)...'
  Invoke-BwBackfill (Get-BwState)
  $after = (Count-Jpg $c.bing_save_dir)
  Write-Host ('  必应库: ' + $before + ' -> ' + $after + ' 张 (断网时补不了, 联网后再来)')
  Write-Host '  删掉或移走的旧图不会被补回来 —— 补的只是真正错过的那些天。'
}

# ---------- 收藏夹 ----------
# 收藏是个"白名单": 加进来容易, 退出来也容易, 一个图片文件都不动。
# 收藏的图被删掉之后, 名单里的名字会留着 —— 取用时自然跳过, 不提前清理
# (万一手滑删了图, 拷回来收藏还在)。
# 这里用 if/elseif 而不是 switch: PowerShell 的 switch 会把匹配到的子句**全部执行**,
# 而 '1' 同时能匹配纯数字和别的形式, 容易按下一次做两件事 (v1.2.1 修过同类问题)。
function Show-BwFavorites {
  $back = $false
  do {
    Clear-Host
    $c = Get-BwConfig
    $s = Get-BwState
    $files = @(Get-BwFavFiles $s)
    $allN = @(Get-BwFav $s).Count
    Write-Host '========== 收藏夹 ==========' -ForegroundColor Cyan
    Write-Host ''
    $onoff = '关 (从整个库里轮换)'
    if ([bool]$c.fav_only) { $onoff = '开 (只换收藏里的)' }
    Write-Host ('  [s] 只在收藏里轮换    ' + $onoff)
    Write-Host ''
    if ($files.Count -eq 0) {
      Write-Host '  还没有收藏。'
      Write-Host '  主菜单按 [F] 收藏当前这张; 或在 [4] 从库里挑一张里, 输入 f+序号 (如 f3) 收藏。'
    } else {
      Write-Host ('  —— 收藏 ' + $files.Count + ' 张 ——')
      $bb = ([string]$c.bing_save_dir).TrimEnd('\')
      $i = 0
      foreach ($f in $files) {
        $mark = '聚焦'
        $db = ''
        try { $db = ([string]$f.DirectoryName).TrimEnd('\') } catch {}
        if ($db -and ($db -eq $bb)) { $mark = '必应' }
        Write-Host ("  [$i] [$mark] $($f.Name)")
        $i++
      }
      if ($allN -gt $files.Count) {
        Write-Host ('  (另有 ' + ($allN - $files.Count) + ' 张收藏的图已经不在库里了)') -ForegroundColor DarkGray
      }
      Write-Host ''
      Write-Host '  数字 = 设为壁纸    r+数字 = 移出收藏 (如 r3)'
    }
    Write-Host '  [q] 返回'
    Write-Host ''
    $k = Normalize-BwKey (Read-Host '  操作')
    if ($k -eq 'q') { $back = $true }
    elseif ($k -eq 's') {
      $c = Get-BwConfig
      $c.fav_only = -not ([bool]$c.fav_only)
      Save-BwConfig $c
      # 队列是按旧模式洗好的, 切完开关立刻重洗一次
      $s = Get-BwState
      $s.queue = @(Get-BwFreshQueue $s)
      Save-BwState $s
      if ([bool]$c.fav_only) {
        $n = @(Get-BwFavFiles $s).Count
        if ($n -eq 0) {
          Write-Host '  已开启。但收藏里还没有图 —— 暂时先从整个库里挑, 收藏几张之后就只换收藏的了。' -ForegroundColor Yellow
        } else {
          Write-Host ('  已开启: 只在收藏的 ' + $n + ' 张里轮换。') -ForegroundColor Green
        }
      } else { Write-Host '  已关闭: 从整个库里轮换。' }
      Log ('设置: 只在收藏里轮换 -> ' + [bool]$c.fav_only)
      Pause-Bw
    }
    elseif ($k -match '^r(\d+)$') {
      $idx = [int]$Matches[1]
      if (($idx -ge 0) -and ($idx -lt $files.Count)) {
        $nm = [string]$files[$idx].Name
        if (Remove-BwFav $s $nm) { Save-BwState $s; Write-Host ('  已移出收藏: ' + $nm) }
      } else { Write-Host '  没有这一项' }
      Pause-Bw
    }
    elseif ($k -match '^(\d+)$') {
      $idx = [int]$Matches[1]
      if (($idx -ge 0) -and ($idx -lt $files.Count)) {
        $p = $files[$idx].FullName
        $ok = Set-BwWallManual $s $p '收藏夹设壁纸'
        Write-Host ('  已设为壁纸 (ok=' + $ok + '): ' + (Split-Path $p -Leaf))
      } else { Write-Host '  没有这一项' }
      Pause-Bw
    }
  } while (-not $back)
}

# ---------- 设置 ----------
function Show-BwSettings {
  $back = $false
  do {
    $c = Get-BwConfig
    Clear-Host
    Write-Host '========== 设置 ==========' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ('  [1] 换图间隔        每 ' + $c.cycle_minutes + ' 分钟换一张')
    Write-Host ('  [2] 每轮抓几张      一次抓 ' + $c.spotlight_per_cycle + ' 张聚焦备用')
    $base = Get-BwBaseOf $c
    if ($base) { Write-Host ('  [3] 壁纸保存位置    ' + $base) }
    else {
      Write-Host ('  [3] 壁纸保存位置    必应: ' + $c.bing_save_dir)
      Write-Host ('                      聚焦: ' + $c.spotlight_save_dir)
    }
    $favN = @(Get-BwFavFiles (Get-BwState)).Count
    $favOnly = '关'
    if ([bool]$c.fav_only) { $favOnly = '开' }
    Write-Host ('  [4] 壁纸填充方式    ' + (Get-BwWallStyle).Label)
    Write-Host ('  [5] 收藏夹          ' + $favN + ' 张 · 只在收藏里轮换 ' + $favOnly)
    $deskOn = '开'
    if ([string]$c.desktop_shortcut -eq 'off') { $deskOn = '关' }
    Write-Host ('  [6] 桌面快捷方式    ' + $deskOn)
    Write-Host ('  [7] 数据目录        ' + $global:BWRoot)
    Write-Host '  [8] 图标缓存        一键刷新 (图标显示成旧的样子时用)'
    $cap = 0
    try { $cap = [int]$c.lib_cap } catch { $cap = 0 }
    $capTxt = '不限'
    if ($cap -gt 0) { $capTxt = ($cap.ToString() + ' 张') }
    $libN = @(Get-ChildItem -LiteralPath ([string]$c.spotlight_save_dir) -File -Filter *.jpg -ErrorAction SilentlyContinue).Count
    Write-Host ('  [9] 图库上限        ' + $capTxt + ' · 现在库里 ' + $libN + ' 张')
    $afOn = '关'
    if ([bool]$c.auto_fetch) { $afOn = '开' }
    Write-Host ('  [0] 自动补新图      ' + $afOn + '  · 关着就只在现有这些图里轮换')
    Write-Host ''
    Write-Host '  [q] 返回'
    Write-Host ''
    $k = Normalize-BwKey (Read-Host '  要改哪一项')
    switch ($k) {
      '1' {
        Write-Host ''
        $m = Read-Host ('  多少分钟换一次? (现在 ' + $c.cycle_minutes + ', 回车不改)')
        if ($m -and ((Normalize-BwKey $m) -match '^\d+$') -and ([int]$m -gt 0)) {
          $c.cycle_minutes = [int]$m
          Save-BwConfig $c
          Write-Host ('  好了, 每 ' + $m + ' 分钟换一张。')
        } elseif ($m) { Write-Host '  要填一个大于 0 的数字, 没改。' }
        Pause-Bw
      }
      '2' {
        Write-Host ''
        $n = Read-Host ('  一次抓几张? (现在 ' + $c.spotlight_per_cycle + ', 回车不改)')
        if ($n -and ((Normalize-BwKey $n) -match '^\d+$') -and ([int]$n -gt 0)) {
          $c.spotlight_per_cycle = [int]$n
          Save-BwConfig $c
          Write-Host ('  好了, 一次抓 ' + $n + ' 张。')
        } elseif ($n) { Write-Host '  要填一个大于 0 的数字, 没改。' }
        Pause-Bw
      }
      '3' {
        Clear-Host
        Write-Host '========== 壁纸保存位置 ==========' -ForegroundColor Cyan
        Write-Host ''
        if ($base) { Write-Host ('  现在: ' + $base) }
        else {
          Write-Host ('  现在: 必应 ' + $c.bing_save_dir)
          Write-Host ('        聚焦 ' + $c.spotlight_save_dir)
        }
        Write-Host '  壁纸会放在这个文件夹下面的「必应」和「聚焦」两个子目录里。'
        Write-Host '  换位置不影响已经存好的图, 只是以后往新地方存。'
        Write-Host ''
        $sel = Select-BwBase '' ''
        if (-not $sel) { Write-Host '  没改。' }
        else { [void](Set-BwBase $sel) }
        Pause-Bw
      }
      '4' {
        Clear-Host
        Write-Host '========== 壁纸填充方式 ==========' -ForegroundColor Cyan
        Write-Host ''
        Write-Host ('  现在: ' + (Get-BwWallStyle).Label)
        Write-Host ''
        Write-Host '   [1] 填充   铺满屏幕, 按比例放大后多出来的裁掉 (默认)'
        Write-Host '   [2] 适应   整张完整显示, 不够的地方留黑边'
        Write-Host '   [3] 拉伸   拉满屏幕, 比例会变形'
        Write-Host '   [4] 居中   原尺寸放中间'
        Write-Host '   [5] 平铺   原尺寸反复铺满'
        Write-Host '   [6] 跨区   多显示器横跨 (单屏效果同填充)'
        Write-Host ''
        Write-Host '  [q] 返回'
        Write-Host ''
        $k2 = Normalize-BwKey (Read-Host '  选哪个')
        $map = @{ '1' = 'fill'; '2' = 'fit'; '3' = 'stretch'; '4' = 'center'; '5' = 'tile'; '6' = 'span' }
        if ($map.ContainsKey($k2)) {
          $c2 = Get-BwConfig
          $c2.wallpaper_style = $map[$k2]
          Save-BwConfig $c2
          $null = Apply-BwWallStyle
          Write-Host ('  好了: ' + (Get-BwWallStyle).Label + ' —— 已立刻应用到当前这张壁纸。')
          Log ('设置: 填充方式改为 ' + $map[$k2])
        }
        Pause-Bw
      }
      '5' { Show-BwFavorites }
      '6' {
        $c2 = Get-BwConfig
        if ([string]$c2.desktop_shortcut -eq 'off') {
          $c2.desktop_shortcut = 'on'
          Save-BwConfig $c2
          # 这里是用户主动要建 (可能之前自己删过), 所以把"已经建过"的记号清掉,
          # 不然程序会认为"你删了就不该再建", 结果什么也不做。
          $di = Get-BwDeskInfo
          $di.created = ''
          Save-BwDeskInfo $di
          $r = Ensure-BwDesktopShortcut
          if ($r -eq 'create' -or $r -eq 'update') {
            Write-Host ('  好了: ' + (Get-BwDesktopLnk))
          } elseif ($r -eq 'ok') {
            Write-Host ('  已经有了: ' + (Get-BwDesktopLnk))
          } else {
            Write-Host '  没建成 —— 找不到主程序或桌面不让写。'
          }
        } else {
          $c2.desktop_shortcut = 'off'
          Save-BwConfig $c2
          $lnk = Get-BwDesktopLnk
          if ($lnk -and (Test-Path -LiteralPath $lnk)) { Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue }
          $di = Get-BwDeskInfo
          $di.path = ''
          Save-BwDeskInfo $di
          Write-Host '  已关掉, 桌面上的快捷方式也删了。以后不会再自动建。' -ForegroundColor Yellow
        }
        Pause-Bw
      }
      '7' {
        Write-Host ''
        Write-Host ('  数据目录: ' + $global:BWRoot)
        Write-Host '  配置、收藏名单、换图进度、日志都在这一个文件夹里。'
        Write-Host '  它不在程序旁边 —— 程序放哪都不会多出一个数据文件夹。'
        Write-Host ''
        Write-Host '  [o] 打开这个文件夹    [回车] 返回'
        $k7 = Normalize-BwKey (Read-Host '  ')
        if ($k7 -eq 'o') { try { Start-Process -FilePath 'explorer.exe' -ArgumentList $global:BWRoot } catch {} }
      }
      '8' {
        Write-Host ''
        Write-Host '  正在刷新 Windows 图标缓存 ...' -ForegroundColor DarkGray
        $ie = Join-Path $env:SystemRoot 'System32\ie4uinit.exe'
        if (Test-Path -LiteralPath $ie) {
          try {
            $p = Start-Process -FilePath $ie -ArgumentList '-ClearIconCache' -Wait -PassThru -WindowStyle Hidden
            if ($p.ExitCode -eq 0) {
              Write-Host '  好了。还显示旧图标的话, 把那个文件夹窗口关掉重开一次。'
              Log ('设置: 刷新图标缓存 (ie4uinit -ClearIconCache) 完成')
            } else {
              Write-Host ('  没成功 (退出码 ' + $p.ExitCode + ')。可以用程序目录里的「刷新图标缓存.bat」。')
            }
          } catch {
            Write-Host ('  没跑成: ' + $_.Exception.Message)
          }
        } else {
          Write-Host '  这台机器没有 ie4uinit.exe。用程序目录里的「刷新图标缓存.bat」代替 (会重启一次资源管理器)。'
        }
        Pause-Bw
      }
      '9' {
        Write-Host ''
        Write-Host '  库里攒到这个数之后, 每换一张就把「已经看过」的最老的一张移进回收站。'
        Write-Host '  没看过的图不会动 —— 那是排队等着换的。移走的能从回收站还原。'
        Write-Host '  填 0 = 不限, 库只增不减。'
        Write-Host ''
        $v = Read-Host ('  最多留多少张? (现在 ' + $capTxt + ', 回车不改)')
        $vv = Normalize-BwKey $v
        if ($v -and ($vv -match '^\d+$')) {
          $c.lib_cap = [int]$v
          Save-BwConfig $c
          if ([int]$v -eq 0) { Write-Host '  好了, 不限张数。' }
          else { Write-Host ('  好了, 最多留 ' + $v + ' 张, 超了就把看过的最老的移进回收站。') }
          Log ('设置: 图库上限 -> ' + $v)
        } elseif ($v) { Write-Host '  要填一个数字 (0 = 不限), 没改。' }
        Pause-Bw
      }
      '0' {
        Write-Host ''
        Write-Host '  开着: 库里的图全换过一遍之后, 自动下一批新图补进来。'
        Write-Host '  关着: 只在现有这些图里轮换, 不下载新的(库不会自己变大)。'
        Write-Host ''
        $v = Read-Host ('  要开着吗? [y] 开 / [n] 关   (现在是' + $afOn + ', 回车不改)')
        $k2 = Normalize-BwKey $v
        if ($k2 -eq 'y') {
          $c.auto_fetch = $true; Save-BwConfig $c
          Write-Host '  好了, 以后换完一轮会自动补新图。'
          Log '设置: 自动补新图 -> 开'
        } elseif ($k2 -eq 'n') {
          $c.auto_fetch = $false; Save-BwConfig $c
          Write-Host '  好了, 只在现有的图里轮换, 不去下新的。'
          Log '设置: 自动补新图 -> 关'
        } elseif ($v) { Write-Host '  没看懂, 没改。' }
        Pause-Bw
      }
      'q' { $back = $true }
      default { }
    }
  } while (-not $back)
}

# ---------- 首次运行向导 ----------
function Show-BwFirstRunHead {
  Clear-Host
  Write-Host ('========== 微软壁纸助手 v' + $global:BWVersion + ' · 首次运行 ==========') -ForegroundColor Cyan
  Write-Host ''
  Write-Host '  它做三件事:'
  Write-Host '    1. 每天把「必应每日一图」存下来, 并设成桌面壁纸'
  Write-Host '    2. 每半小时换一张「Windows 聚焦」壁纸, 不重复'
  Write-Host '    3. 几天没开机也不漏图, 错过的必应壁纸会自动补齐'
  Write-Host ''
  Write-Host '  图片全部存在你自己电脑上, 不会上传到任何服务器。'
  Write-Host '  壁纸你随时可以自己删、自己挪到别处, 删了不影响它继续换图。'
  Write-Host ''
}

function Invoke-BwFirstRun {
  $d = Get-BwDefaults
  # 双击就能用: 直接用推荐位置, 不摆一堆选项让客户做选择题。
  # 只有推荐位置写不进去、一键修复也没修成时, 才回头让人自己挑(极少见)。
  $base = ''
  $try = [string]$d.base
  if ($try -and (Test-BwWritable (Join-Path $try '必应')) -and (Test-BwWritable (Join-Path $try '聚焦'))) {
    $base = $try
  } else {
    $fixed = Resolve-BwUnwritableBase $try
    if ($fixed) { $base = $fixed }
  }
  while (-not $base) {
    Show-BwFirstRunHead
    Write-Host '  这台机器上推荐的位置写不进去, 你自己挑一个:'
    Write-Host ''
    $sel = Select-BwBase $d.base $d.reason
    if (-not $sel) { continue }
    $base = $sel
    # 位置定了, 但"能写"才是真定了。不能写就地解释 + 给一键修复。
    if ((Test-BwWritable (Join-Path $base '必应')) -and (Test-BwWritable (Join-Path $base '聚焦'))) { break }
    $fixed2 = Resolve-BwUnwritableBase $base
    if ($fixed2) { $base = $fixed2; break }
    $base = ''    # 没修成 -> 回到列表重来, 而不是偷偷换到别的地方
  }

  Show-BwFirstRunHead
  Write-Host ('  壁纸保存在: ' + $base) -ForegroundColor Green
  if ($d.reason) { Write-Host ('             ' + $d.reason) -ForegroundColor DarkGray }
  Write-Host '  想换地方: 菜单里按 [S] 设置 - [1]'
  Write-Host ''

  $bing = Join-Path $base '必应'
  $spot = Join-Path $base '聚焦'
  [void](Set-BwBase $base)

  $c = Get-BwConfig
  Log ('首次运行: 保存位置 = ' + $base)

  Write-Host ''
  Write-Host '  正在下载今天的必应壁纸...' -ForegroundColor DarkGray
  Invoke-BwUpdate
  Write-Host ('  必应库: ' + (Count-Jpg $bing) + ' 张') -ForegroundColor DarkGray

  Write-Host '  正在抓几张聚焦壁纸备用...' -ForegroundColor DarkGray
  $null = Invoke-SpotlightFetch -count ([int]$c.spotlight_per_cycle) -Quiet
  Write-Host ('  聚焦库: ' + (Count-Jpg $spot) + ' 张') -ForegroundColor DarkGray

  $s = Get-BwState
  $s.last_bing_date = (Today-Str)
  $s.queue = @(Get-BwFreshQueue $s)
  $s.last_swap = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  Save-BwState $s

  Write-Host ''
  Write-Host ('  好了。壁纸保存在: ' + $base) -ForegroundColor Green
  # 第一次就把桌面快捷方式建好, 以后不用用户再动手
  $desk = Ensure-BwDesktopShortcut
  if ($desk -eq 'create') {
    Write-Host '  桌面上已经放了一个「微软壁纸助手」快捷方式, 以后双击它就能打开这里。' -ForegroundColor Green
  }
  Write-Host ''
  Write-Host '  想让它在后台自动换, 回到菜单按 [A] 打开「开机自动换壁纸」,'
  Write-Host '  不需要管理员权限, 也不装计划任务; 再按一次 [A] 就关掉。'
  Pause-Bw
}

# ---------- 开机自动换壁纸 (绿色做法: 往「启动」文件夹放个快捷方式, 不需要管理员) ----------
# 快捷方式指向 微软壁纸助手.exe --daemon。exe 是 GUI 子系统程序, 后台模式
# 一个控制台都不建, 所以开机拉起时不会闪任何窗口。
function Get-BwStartupLnk {
  return (Join-Path ([Environment]::GetFolderPath('Startup')) '微软壁纸助手.lnk')
}
# 快捷方式要指向**固定名**那份 exe (微软壁纸助手.exe), 而不是 微软壁纸助手-v1.4.0.exe。
# 指到带版本号的名字上, 下一次升级换了文件名, 开机自动换就无声失效了 ——
# 用户不打开菜单根本看不出来 (v1.3.0 就是这么断的: CHANGELOG 说了要用固定名,
# 但部署时只拷了带版本号的那份, 于是建快捷方式时直接用了当前 exe 路径)。
# 所以: 固定名存在就用它; 不存在就自己复制一份出来, 再不行才退回当前 exe。
function Get-BwFixedExe {
  $cur = ''
  $p = Join-Path $global:BWRoot 'launcher.txt'
  if (Test-Path -LiteralPath $p) { $cur = (Get-Content -LiteralPath $p -Raw -Encoding UTF8).Trim() }
  if (-not $cur) { return '' }
  if (-not (Test-Path -LiteralPath $cur)) { return '' }
  return (Join-Path (Split-Path $cur -Parent) '微软壁纸助手.exe')
}
function Ensure-BwFixedExe {
  $fixed = Get-BwFixedExe
  if (-not $fixed) { return '' }
  if (Test-Path -LiteralPath $fixed) { return $fixed }
  # 固定名那份还没拷过来 —— 从当前 exe 复制一份, 内容一模一样。
  # 只在本程序自己所在目录里操作, 不碰系统, 复制失败也无所谓(下面会退回当前 exe)。
  $cur = (Get-Content -LiteralPath (Join-Path $global:BWRoot 'launcher.txt') -Raw -Encoding UTF8).Trim()
  try { Copy-Item -LiteralPath $cur -Destination $fixed -Force; return $fixed } catch { return '' }
}
function Get-BwLauncherPath {
  $fixed = Ensure-BwFixedExe
  if ($fixed -and (Test-Path -LiteralPath $fixed)) { return $fixed }
  $p = Join-Path $global:BWRoot 'launcher.txt'
  if (Test-Path -LiteralPath $p) { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8).Trim() }
  return ''
}
# exe 换个地方放之后, 启动文件夹里的快捷方式还指着老位置 ——
# 菜单上却照样显示"开", 用户根本看不出来开机后其实什么都没拉起来。
# 所以每次进菜单都核对一下, 指错了就重新指到当前这份 exe。
# 顺带把老版本"指向带版本号文件名"的快捷方式也修正成固定名。
function Repair-BwAutoStart {
  $lnk = Get-BwStartupLnk
  if (-not (Test-Path -LiteralPath $lnk)) { return $false }
  $want = Get-BwLauncherPath
  if ((-not $want) -or (-not (Test-Path -LiteralPath $want))) { return $false }
  $sh = $null
  $cur = ''
  try {
    $sh = New-Object -ComObject WScript.Shell
    $cur = $sh.CreateShortcut($lnk).TargetPath
  } catch { return $false }
  if ($cur -and (Test-Path -LiteralPath $cur) -and ($cur -eq $want)) { return $false }
  try {
    $sc = $sh.CreateShortcut($lnk)
    $sc.TargetPath       = $want
    $sc.Arguments        = '--daemon'
    $sc.WorkingDirectory = (Split-Path $want -Parent)
    $sc.Description      = '微软壁纸助手 - 开机自动换壁纸'
    $sc.IconLocation     = (Get-BwIconLocation $want)
    $sc.Save()
    Log ('开机自动换: 快捷方式原先指向 [' + $cur + '], 已改指 [' + $want + ']')
    return $true
  } catch { return $false }
}
# ---------- 桌面快捷方式 ----------
# 桌面上要一直有一个能双击打开菜单的快捷方式, 不用用户自己动手建:
#   · 没有 -> 建一个 (首次运行就会有)
#   · exe 换了地方 -> 改指过去 (挪到哪个盘都跟着)
#   · exe 被新版本覆盖过 (文件比快捷方式新) -> 重写一遍, 顺带把图标刷新成新版的
# 在设置 [6] 里关掉之后就完全不动, 也不再自动建。
#   · 没有 -> 建一个, **只建这一次** (首次运行就会有)
#   · exe 换了地方 -> 改指过去 (挪到哪个盘都跟着)
#   · exe 被新版本覆盖过 (文件比快捷方式新) -> 重写一遍, 顺带把图标刷新成新版的
#
# 关键一条: **它建在哪儿, 以后就认哪儿**。
# 用户把快捷方式收进桌面上的文件夹 (比如「图标」) 是常事, 不能因为他挪了一下,
# 程序就在桌面根再冒一个出来 —— 那样每次打开菜单桌面上都会多一个。
# 所以位置记在 config.json 里; 记的位置没了, 先去桌面和一层子目录里找,
# 找不着且从来没建过才建; 建过又被删掉的, 就不建了 (尊重用户删掉它的决定)。
# 想重建: 设置 [6] 里关一次再开。
# 快捷方式的"建在哪儿 / 建没建过"单独存一个小文件, **不写进 config.json**。
# 理由: 主菜单靠"config.json 在不在"来判断要不要走首次运行向导。
# 要是建快捷方式时顺手把 config.json 也写了, 用户还没选保存目录, 向导就被跳过,
# 壁纸会默默存到默认位置 —— 那是替用户做了决定, 不能这么干。
function Get-BwDeskInfo {
  $p = Join-Path $global:BWRoot 'desktop_shortcut.json'
  $o = $null
  if (Test-Path -LiteralPath $p) {
    try { $o = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $o = $null }
  }
  if (-not $o) { $o = New-Object PSObject }
  if (-not $o.PSObject.Properties['path'])    { Add-Member -InputObject $o NoteProperty path '' -Force }
  if (-not $o.PSObject.Properties['created']) { Add-Member -InputObject $o NoteProperty created '' -Force }
  return $o
}
function Save-BwDeskInfo($o) {
  $p = Join-Path $global:BWRoot 'desktop_shortcut.json'
  try { [System.IO.File]::WriteAllText($p, ($o | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false))) } catch {}
}
function Get-BwDesktopLnk {
  $i = Get-BwDeskInfo
  if ($i.path) { return $i.path }
  return (Join-Path (Get-BwDesktopDir) '微软壁纸助手.lnk')
}
# 桌面在哪。抽成一个函数是因为测试要能把它换成临时目录 ——
# 不然"首次自动建快捷方式"那条分支只能往真桌面上建, 测试就没法隔离了。
function Get-BwDesktopDir {
  return ([Environment]::GetFolderPath('Desktop'))
}
# 桌面根目录找不到时, 再往桌面上的一层子目录里找一遍 (用户收进文件夹的情况)
function Find-BwDesktopLnk {
  $desk = Get-BwDesktopDir
  $hit = @()
  try { $hit = @(Get-ChildItem -LiteralPath $desk -File -Filter '微软壁纸助手.lnk' -ErrorAction SilentlyContinue) } catch { $hit = @() }
  if ($hit.Count -eq 0) {
    try {
      $subs = @(Get-ChildItem -LiteralPath $desk -Directory -ErrorAction SilentlyContinue)
      foreach ($s in $subs) {
        $f = @(Get-ChildItem -LiteralPath $s.FullName -File -Filter '微软壁纸助手.lnk' -ErrorAction SilentlyContinue)
        if ($f.Count -gt 0) { $hit = @($f[0]); break }
      }
    } catch {}
  }
  if ($hit.Count -gt 0) { return $hit[0].FullName }
  return ''
}
# 快捷方式的图标从哪取: 优先数据目录里那份独立的 .ico 文件, 没有才退回 exe 自己。
#
# 为什么不直接用 exe: Windows 的图标缓存是按「exe 的完整路径」记的。老版本 exe 占着
# 同一个路径时 (比如 D:\Program Files\微软壁纸助手.exe), 即使文件已经换成新版,
# 缓存里存的还是旧图标 —— 表现为"放桌面一个样、拖进文件夹又一个样"。
# 独立的 .ico 是另一条路径, 没被旧版本污染过, 显示出来的始终是这张图。
function Get-BwIconLocation([string]$exe) {
  $ico = Join-Path $global:BWRoot '微软壁纸助手.ico'
  if (Test-Path -LiteralPath $ico) { return ('{0},0' -f $ico) }
  return ('{0},0' -f $exe)
}
# 真正写盘的那一步: 返回 create / update / ok / fail
function Write-BwShortcut($sh, [string]$lnk, [string]$want) {
  $need = 'create'
  if (Test-Path -LiteralPath $lnk) {
    $need = ''
    $cur = ''
    try { $cur = [string]$sh.CreateShortcut($lnk).TargetPath } catch { return 'fail' }
    if ($cur -ne $want) {
      $need = 'update'      # 指错地方了 (挪过/换过版本)
    } else {
      # 指向没变, 但 exe 文件本身更新过 -> 重存一次, 让图标跟着新版刷新
      $tw = (Get-Item -LiteralPath $want).LastWriteTime
      $tl = (Get-Item -LiteralPath $lnk).LastWriteTime
      if ($tw -gt $tl) { $need = 'update' }
    }
  }
  if (-not $need) { return 'ok' }
  try {
    $sc = $sh.CreateShortcut($lnk)
    $sc.TargetPath       = $want
    $sc.Arguments        = ''
    $sc.WorkingDirectory = (Split-Path $want -Parent)
    $sc.Description      = ('微软壁纸助手 v' + $global:BWVersion + ' - 双击打开菜单')
    $sc.IconLocation     = (Get-BwIconLocation $want)
    $sc.Save()
    if ($need -eq 'create') { Log ('桌面快捷方式: 已创建 -> ' + $lnk) }
    else { Log ('桌面快捷方式: 已更新, 指向 [' + $want + ']') }
    return $need
  } catch { return 'fail' }
}
# 返回: create / update / ok / gone / off / fail
#   gone = 以前建过, 现在没了 (被用户删了) —— 不再自动建
function Ensure-BwDesktopShortcut {
  $c = Get-BwConfig
  if ([string]$c.desktop_shortcut -eq 'off') { return 'off' }
  $want = Get-BwLauncherPath
  if ((-not $want) -or (-not (Test-Path -LiteralPath $want))) { return 'fail' }
  $sh = $null
  try { $sh = New-Object -ComObject WScript.Shell } catch { return 'fail' }
  $info = Get-BwDeskInfo

  # 1) 记住的位置还在 -> 就地更新 (用户挪进文件夹也跟着走, 不在桌面根另建)
  #    顺手补上"已经建过"的记号: 老版本留下的 desktop_shortcut.json 只有 path 没有
  #    created, 不补的话以后这个快捷方式一旦被删, 会被当成"从来没建过"又在桌面根新建一个。
  if ($info.path -and (Test-Path -LiteralPath $info.path)) {
    if ([string]$info.created -ne 'yes') { $info.created = 'yes'; Save-BwDeskInfo $info }
    return (Write-BwShortcut $sh $info.path $want)
  }

  # 2) 记的位置没了 (被删/被挪) -> 桌面根和一层子目录里找, 找到了就接着用那个
  $found = Find-BwDesktopLnk
  if ($found) {
    $info.path = $found
    $info.created = 'yes'   # 找着了就说明确实建过, 别再当成"从来没建过"
    Save-BwDeskInfo $info
    return (Write-BwShortcut $sh $found $want)
  }

  # 3) 从来没自动建过 -> 建这一次
  if ([string]$info.created -ne 'yes') {
    $target = Join-Path (Get-BwDesktopDir) '微软壁纸助手.lnk'
    $r = Write-BwShortcut $sh $target $want
    if ($r -eq 'create') {
      $info.path = $target
      $info.created = 'yes'
      Save-BwDeskInfo $info
    }
    return $r
  }

  # 4) 建过, 但被删了 -> 不再打扰
  return 'gone'
}
function Test-BwAutoStart { return (Test-Path -LiteralPath (Get-BwStartupLnk)) }
# 后台到底有没有在跑? 只看"开机自动换开了没"是不够的 ——
# 那个开关只是往启动文件夹放了个快捷方式, **本次开机**并不会自己跑起来。
# 所以客户会看到「开机自动换: 开」+「下次自动换: 15:52」, 以为程序在换,
# 其实这次开机压根没后台进程, 那个 15:52 永远不会兑现 —— 这就是「时间不会变」的由来。
# 认进程命令行里带 --daemon 的那个, 那是真正在按节拍换图的那个。
function Test-BwDaemonRunning {
  try {
    $ps = @(Get-CimInstance Win32_Process -Filter "Name='微软壁纸助手.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and ($_.CommandLine -like '*--daemon*') })
    return ($ps.Count -gt 0)
  } catch { return $false }
}
# 立刻把后台拉起来(不等下次开机)。开机自启的快捷方式照建, 两件事一起办。
function Start-BwDaemonNow([string]$exe) {
  if ((-not $exe) -or (-not (Test-Path -LiteralPath $exe))) { return $false }
  try {
    Start-Process -FilePath $exe -ArgumentList '--daemon' -WorkingDirectory (Split-Path $exe -Parent) -WindowStyle Hidden
    return $true
  } catch { return $false }
}

# 开机自动换做成**两个按钮**, 不是一个会翻面的开关。
# 一个开关两面翻的问题是: 客户只看到「[A] 开机自动换壁纸 开/关」, 按下去到底是开还是关
# 得先记住现在是什么状态; 记反了就正好按成自己不想要的那一下 —— 而且后台进程会立刻停,
# 下次开机不换图, 他只会觉得"这软件不灵了"。
# 所以菜单上只摆当前**能做**的那一个动作: 关着就只显示 [A] 打开, 开着就只显示 [B] 关闭。
function Enable-BwAutoStart {
  $lnk = Get-BwStartupLnk
  $exe = Get-BwLauncherPath
  if ((-not $exe) -or (-not (Test-Path -LiteralPath $exe))) {
    Write-Host '  找不到主程序「微软壁纸助手.exe」。'
    Write-Host '  请直接双击那个 exe 打开本菜单, 再来开这个开关。'
    return $false
  }
  try {
    # 清掉可能残留的 daemon.stop —— 不清的话刚拉起来的后台会立刻自己退掉
    $sf = Join-Path $global:BWRoot 'daemon.stop'
    if (Test-Path -LiteralPath $sf) { Remove-Item -LiteralPath $sf -Force -ErrorAction SilentlyContinue }
    $sh = New-Object -ComObject WScript.Shell
    $sc = $sh.CreateShortcut($lnk)
    $sc.TargetPath       = $exe
    $sc.Arguments        = '--daemon'
    $sc.WorkingDirectory = (Split-Path $exe -Parent)
    $sc.Description      = '微软壁纸助手 - 开机自动换壁纸'
    $sc.IconLocation     = (Get-BwIconLocation $exe)
    $sc.Save()
    # 关键: 光放快捷方式, 本次开机不会自己跑起来。要等下一次开机才换图,
    # 客户当场看不到效果, 只会以为"按了没用"。所以顺手把后台立刻拉起来。
    $started = Start-BwDaemonNow $exe
    Write-Host '  已开启。下次登录后会在后台自动换壁纸, 一个窗口都不会闪。'
    Write-Host ('  启动项位置: ' + $lnk)
    Write-Host ('  指向: ' + $exe)
    if ($started) { Write-Host '  后台已经现在就跑起来了, 不用等下次开机 —— 到点就换。' -ForegroundColor Green }
    else { Write-Host '  (后台这次没拉起来, 下次开机才会自动跑)' -ForegroundColor DarkYellow }
    if ((Split-Path $exe -Leaf) -ne '微软壁纸助手.exe') {
      Write-Host '  (这份 exe 名字里带版本号, 以后换新版本要重开一次本开关)' -ForegroundColor DarkYellow
    }
    return $true
  } catch { Write-Host ('  开启失败: ' + $_.Exception.Message); return $false }
}
function Disable-BwAutoStart {
  $lnk = Get-BwStartupLnk
  if (-not (Test-Path -LiteralPath $lnk)) {
    Write-Host '  开机自动换本来就是关着的, 不用关。'
    return $false
  }
  try { Remove-Item -LiteralPath $lnk -Force } catch {}
  # 告诉还在后台跑的 daemon 收工
  try { Set-Content -LiteralPath (Join-Path $global:BWRoot 'daemon.stop') -Value 'stop' -Encoding ASCII } catch {}
  Write-Host '  已关闭开机自动换壁纸。想再开, 回来按 [A] 就行。'
  return $true
}

# ---------- [F] 收藏当前这张壁纸 ----------
# 取当前壁纸: 优先用 state 里程序自己记的那张, 读不到再回退注册表
# (用户可能自己手动换过壁纸, 那张也一样该能收藏)。
function Toggle-BwFavCurrent {
  $s = Get-BwState
  $p = [string]$s.last_wall
  if (-not $p) { $p = [string](Get-ItemProperty 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue).Wallpaper }
  if (-not $p) { Write-Host '  还不知道当前是哪张 —— 换一张之后就能收藏了。'; return }
  $nm = Split-Path $p -Leaf
  if (Add-BwFav $s $nm) {
    Save-BwState $s
    Write-Host ('  已收藏 ★ ' + $nm)
    if (-not (Test-Path -LiteralPath $p)) {
      Write-Host '  不过这张已经不在库里了, 收藏先记下 —— 图找回来就能用。' -ForegroundColor DarkYellow
    }
    Log ('收藏: ' + $nm)
    return
  }
  [void](Remove-BwFav $s $nm)
  Save-BwState $s
  Write-Host ('  已取消收藏 ' + $nm)
  Log ('取消收藏: ' + $nm)
}

# ---------- 主菜单 ----------
if (-not (Test-Path -LiteralPath $global:CfgPath)) { Invoke-BwFirstRun }

do {
  $c0 = Get-BwConfig
  $s0 = Get-BwState
  # 桌面快捷方式: 每次进菜单核对一遍, 没有就建, 指错就修, exe 更新过就刷新图标
  $desk = Ensure-BwDesktopShortcut
  $bingN = Count-Jpg $c0.bing_save_dir
  $spotN = Count-Jpg $c0.spotlight_save_dir
  Clear-Host
  Write-Host ('========== 微软壁纸助手 v' + $global:BWVersion + ' ==========') -ForegroundColor Cyan
  $bingDone = '待切'
  if ($s0.last_bing_date -eq (Today-Str)) { $bingDone = '已切' }
  $last = Get-BwTime $s0.last_swap
  $next = '还没换过'
  if ($last) { $next = $last.AddMinutes([int]$c0.cycle_minutes).ToString('HH:mm') }
  $auto = '关'
  $moved = $false
  if (Test-BwAutoStart) { $auto = '开'; $moved = Repair-BwAutoStart }
  # 「下次自动换」只有后台真跑着的时候才作数。
  # 后台没跑时还显示一个时间, 等于给个假承诺: 那个点到了也不会有人换图,
  # 而且数字纹丝不动(它是按"上次换图时刻+间隔"算的, 不会自己往前走)。
  $running = Test-BwDaemonRunning
  # 时间**始终显示** —— 拿掉时间之后客户第一反应是"程序坏了"。
  # 但后台没跑的时候得把话说清楚: 那个点到了也不会有人换图。
  if ($running) { $swapTxt = '下次自动换: ' + $next }
  elseif ($auto -eq '开') { $swapTxt = '下次自动换: ' + $next + '  (后台还没启动, 按 [A] 开)' }
  else { $swapTxt = '下次自动换: ' + $next + '  (自动换没开, 按 [A] 开)' }
  Write-Host (' 今日必应: ' + $bingDone + '    ' + $swapTxt + '    开机自动换: ' + $auto) -ForegroundColor DarkGray
  if ($moved) { Write-Host '  (程序位置变过, 开机自动换已重新指向当前这个 exe)' -ForegroundColor Yellow }
  if ($desk -eq 'create') { Write-Host '  已在桌面放了「微软壁纸助手」快捷方式 (不想要: 设置 [6] 里关)' -ForegroundColor DarkYellow }
  elseif ($desk -eq 'update') { Write-Host '  桌面快捷方式已指向当前这份程序, 图标也是新的' -ForegroundColor DarkYellow }
  Write-Host (' 壁纸库: 必应 ' + $bingN + ' 张 · 聚焦 ' + $spotN + ' 张 · 待换队列剩 ' + (Left-Queue $s0) + ' 张') -ForegroundColor DarkGray
  # 收藏只在开了「只看收藏」时才占一行 —— 平时不打扰
  if ([bool]$c0.fav_only) {
    Write-Host (' 收藏: ' + @(Get-BwFavFiles $s0).Count + ' 张 · 只在收藏里轮换: 开') -ForegroundColor DarkGray
  }
  $base0 = Get-BwBaseOf $c0
  if ($base0) { Write-Host (' 保存位置: ' + $base0) -ForegroundColor DarkGray }
  else {
    Write-Host (' 必应库: ' + $c0.bing_save_dir) -ForegroundColor DarkGray
    Write-Host (' 聚焦库: ' + $c0.spotlight_save_dir) -ForegroundColor DarkGray
  }
  if ($s0.last_wall) {
    $leaf = Split-Path $s0.last_wall -Leaf
    if (Test-Path -LiteralPath $s0.last_wall) {
      Write-Host (' 当前壁纸: ' + $leaf) -ForegroundColor DarkGray
    } else {
      # 图被用户删掉或挪走了 —— 这是正常操作, 如实说清楚, 不报错也不假装还在
      Write-Host (' 当前壁纸: ' + $leaf) -ForegroundColor DarkGray
      Write-Host '           这张已经不在库里了 (桌面还显示着它, 换一张就会更新)' -ForegroundColor DarkYellow
    }
  }
  if ((($bingN + $spotN) -eq 0) -and ([int]$s0.shown -gt 0)) {
    Write-Host ''
    Write-Host ' 注意: 库里现在一张图都没有, 但程序已经换过壁纸。' -ForegroundColor Yellow
    Write-Host '       图是不是被删掉或移到别处了? 想接着用那些图, 按 [S] 把保存位置指到新地方;' -ForegroundColor DarkGray
    Write-Host '       不管的话, 它会自动重新下载新图。' -ForegroundColor DarkGray
  }
  Write-Host ''
  Write-Host ' —— 换图 ——'
  Write-Host '  [1] 立刻换一张 (聚焦)'
  Write-Host '  [2] 换上今天的必应每日一图'
  Write-Host '  [3] 再抓一批新聚焦'
  Write-Host ' —— 壁纸库 ——'
  Write-Host '  [4] 从库里挑一张'
  Write-Host '  [5] 随便来一张'
  Write-Host '  [6] 打开壁纸文件夹'
  Write-Host ' —— 补图 ——'
  Write-Host '  [7] 补下最近错过的必应 (几天没开机)'
  Write-Host '  [8] 下载往期必应 (2021 年至今, 4K)'
  Write-Host ' —— 其他 ——'
  Write-Host '  [F] 收藏当前这张 / 取消收藏'
  Write-Host '  [S] 设置'
  # 只摆当前能做那一下: 关着就只给「打开」, 开着就只给「关闭」
  if (Test-BwAutoStart) { Write-Host '  [B] 关掉开机自动换壁纸   (现在: 开)' }
  else { Write-Host '  [A] 打开开机自动换壁纸   (现在: 关)' }
  Write-Host '  [L] 查看运行日志'
  Write-Host '  [Q] 退出'
  $k = Normalize-BwKey (Read-Host '请选择')
  $quit = $false
  # 注意: PowerShell 的 switch 对字符串大小写不敏感, 且匹配到的子句"每个都会执行"。
  # 所以这里每个键只写一条小写子句 —— 写 'a' 和 'A' 两条会让开关被切两次 (等于没切)。
  switch ($k) {
    '1' { Invoke-BwManualSwap; Pause-Bw }
    '2' { Invoke-BwUpdate; Pause-Bw }
    '3' { Invoke-BwRefill; Pause-Bw }
    '4' { Show-BrowseAll; Pause-Bw }
    '5' { Invoke-BwRandom; Pause-Bw }
    '6' { Open-BwDir $c0.bing_save_dir; Open-BwDir $c0.spotlight_save_dir }
    '7' { Invoke-BwBackfillManual; Pause-Bw }
    '8' { Show-Archive }
    'f' { Toggle-BwFavCurrent; Pause-Bw }
    's' { Show-BwSettings }
    'a' { [void](Enable-BwAutoStart); Pause-Bw }
    'b' { [void](Disable-BwAutoStart); Pause-Bw }
    'l' { Get-Content -LiteralPath $global:BWLog -Tail 40 -Encoding UTF8 -ErrorAction SilentlyContinue; Pause-Bw }
    # 退出: 主标识是 Q; 0 和 o 也认 —— 老菜单里那个 [0] 常被看成字母 O, 习惯不改
    'q' { $quit = $true }
    '0' { $quit = $true }
    'o' { $quit = $true }
    default {
      Write-Host ('  「' + $k + '」不是菜单里的选项, 请输入方括号里的数字或字母')
      Start-Sleep -Milliseconds 900
    }
  }
} while (-not $quit)
