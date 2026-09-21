# 微软壁纸助手 - 核心库 (by 海风 & Cindy)
param([switch]$Update, [switch]$Cycle, [switch]$DryRun)
$global:BWRoot = $PSScriptRoot
$global:CfgPath = Join-Path $global:BWRoot 'config.json'
$global:BWLog = Join-Path $global:BWRoot 'wallpaper.log'
$global:BWState = Join-Path $global:BWRoot 'state.json'
# 下载流水账 (v1.6.3): 每成功下载一张就追加一行「图片编号」。
# 独立于 state.json 的原因见 Read-BwDlLedger 上方的注释 —— state 会被
# 菜单/后台的整份写回覆盖, 追加写不会。它同时充当「程序下载清单」。
$global:BWDlLedger = Join-Path $global:BWRoot 'dl_ledger.log'
$global:BWDry = [bool]$DryRun
$ProgressPreference = 'SilentlyContinue'
function Log([string]$m) {
  Add-Content -Path $global:BWLog -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8
  $fi = Get-Item $global:BWLog -ErrorAction SilentlyContinue
  if ($fi -and $fi.Length -gt 256KB) { Set-Content -Path $global:BWLog -Value (Get-Content $global:BWLog -Tail 200 -Encoding UTF8) -Encoding UTF8 }
}
# ---- 保存位置: 不再写死 D 盘 ----
# 分享给朋友的机器可能只有 C 盘, 盘符也可能乱七八糟。定位置的规则:
#   1) 本地固定磁盘里挑可用空间最大的"非系统盘"
#   2) 只有 C 盘就用 C 盘
#   3) 连固定磁盘都读不到(极罕见)才退到 用户的"图片"文件夹
# 首次运行定一次并写进 config.json, 之后一直用那个位置, 不会自己漂。
# 结果在单次运行里缓存 —— Get-BwConfig 被调用得很频繁, 不能每次都去枚举磁盘。
#
# 盘根**能不能建文件夹**是独立的一件事, 必须每台机器单独实测, 不能写死。
# Windows 装机时会给数据盘根目录写上 `Authenticated Users:(M)`, 这样普通用户能建目录;
# 但用第三方分区/格式化工具做出来的盘常常只有 `Users:(OI)(CI)(RX)`, 于是:
#   - 这个盘的可用空间再大, 普通用户也建不出 <盘>\微软壁纸助手;
#   - 盘上**别的**已有目录可能反而是可写的 (权限是按目录给的, 不是按盘给的)。
# 所以"能不能用这个盘"必须现场探。探出来不能用的盘, 不是"坏盘", 是本机权限设置,
# 用户随时可以用管理员权限补一次 —— 见 Repair-BwBaseDir。
# 建目录统一走 .NET, 不用 New-Item: 本机 PowerShell 5.1 的 New-Item 参数表里
# **没有 -LiteralPath** (实测 Get-Command New-Item 只列 Path/Name/ItemType/Value/Force...),
# 传它会抛 ParameterBindingException。那是环境差异不是权限问题, 会让"能写的盘"
# 被误判成"写不进去"。.NET API 没有这个坑。
function New-BwDir([string]$dir) {
  if (-not $dir) { return $false }
  if (Test-Path -LiteralPath $dir) { return $true }
  try { [void][System.IO.Directory]::CreateDirectory($dir); return $true } catch { return $false }
}
# ---- 图片格式的统一口径 ----
# 程序自己下载的只有 .jpg; 但用户往库里丢的照片什么格式都有
# (手机原图 .jpeg、截图 .png、网页存的 .webp ...)。
# 认外来图、浏览库列表都按 $BWImgExt 这个集合认 —— 只认 .jpg 的话,
# 用户丢的 png/webp 会完全隐形: 不标记、不提示、也没人管。
# 「能设成壁纸」的格式是另一个更小的集合 (Windows 换壁纸接口只认这几种)。
$script:BWImgExt  = @('.jpg','.jpeg','.png','.webp','.bmp','.gif','.tif','.tiff')
$script:BWWallExt = @('.jpg','.jpeg','.png','.bmp')
function Test-BwImgFile([string]$name) {
  if (-not $name) { return $false }
  return $script:BWImgExt -contains [System.IO.Path]::GetExtension([string]$name).ToLower()
}
function Test-BwWallFile([string]$name) {
  if (-not $name) { return $false }
  return $script:BWWallExt -contains [System.IO.Path]::GetExtension([string]$name).ToLower()
}
# 列出一个库目录里的图片文件 (不递归, 子目录不算 —— 和 jpg 口径一致)。
function Get-BwPicFiles([string]$dir) {
  if (-not ($dir -and (Test-Path -LiteralPath $dir))) { return @() }
  return @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { Test-BwImgFile $_.Name })
}
function Test-BwRootWritable([string]$root) {
  if (-not $root) { return $false }
  if (-not $global:BWWriteCache) { $global:BWWriteCache = @{} }
  $k = $root.ToUpper()
  if ($global:BWWriteCache.ContainsKey($k)) { return $global:BWWriteCache[$k] }
  $ok = $false
  $probe = Join-Path $root ('.wbwtest_' + [guid]::NewGuid().ToString('N'))
  try {
    [void][System.IO.Directory]::CreateDirectory($probe)
    $ok = $true
  } catch { $ok = $false }
  if ($ok) { try { [System.IO.Directory]::Delete($probe, $true) } catch {} }
  $global:BWWriteCache[$k] = $ok
  return $ok
}
# 「这个盘现在能不能拿来存壁纸」—— 这才是向导真正要回答的问题。
# 判据不是"盘根可写吗", 而是"本程序能不能在这个盘上用自己那个文件夹":
#   * 盘根可写                -> 能 (标准数据盘, 多数机器都是这样)
#   * 盘根不可写但库目录可写  -> 也能 (之前用管理员权限建过一次并已授权; 不该再提示)
#   * 两个都不行              -> 不能, 但可以一键修 (见 Repair-BwBaseDir)
# 分开判很重要: 用户修过一次之后, 不该每次运行都被再问一遍"这个盘要不要修"。
function Test-BwDriveUsable([string]$root) {
  if (-not $root) { return $false }
  $r = $root.TrimEnd('\') + '\'
  if (Test-BwRootWritable $r) { return $true }
  return (Test-BwWritable (Join-Path $r '微软壁纸助手'))
}
# 盘根写不进去时的一次性修复。
#
# 做法: 用管理员权限(弹一次 UAC) 建出 <盘>\微软壁纸助手\必应 和 \聚焦, 再把"修改"
# 权限**只**给这一个文件夹 —— `Authenticated Users:(OI)(CI)(M)`, 与 Windows 装机时
# 给数据盘根目录写的那条一模一样。
#
# 为什么必须提权: 建这个文件夹本身就要对盘根的写权限, 普通用户没有。
# 为什么授权范围只到这一个文件夹: 不动盘根, 不动盘上任何别的目录 —— 把
# <盘>\微软壁纸助手 删掉就等于完全回退, 不留任何权限改动。这也是它比
# `icacls <盘>\ /grant "Authenticated Users:(M)"` 那种"改整个盘根"做法克制的地方。
#
# 只处理本地盘符; UNC 网络路径这里修不了, 让用户自己先建好文件夹。
# 返回 $true 表示修完并且实测能写。
function Repair-BwBaseDir([string]$base) {
  if (-not $base) { return $false }
  $b = $base.TrimEnd('\')
  if ($b -notmatch '^[A-Za-z]:\\.') { return $false }   # 只认本地盘符 + 至少一层目录
  $bing = Join-Path $b '必应'
  $spot = Join-Path $b '聚焦'
  # 单引号字符串字面量, 顺带把路径里可能出现的单引号转义掉
  $lit = { param($s) "'" + ($s -replace "'", "''") + "'" }
  # 顺序要紧: 先建 $b -> 给 $b 授权 -> 再建子目录。
  # 反过来的话子目录会先继承盘根那条"只读"ACE, 之后还得靠 icacls /T 补救。
  $lines = @(
    '$ErrorActionPreference = ''Stop'''
    ('try { [void][System.IO.Directory]::CreateDirectory(' + (& $lit $b) + ') } catch { exit 2 }')
    ('$null = icacls ' + (& $lit $b) + ' /grant ' + (& $lit 'Authenticated Users:(OI)(CI)(M)'))
    'if ($LASTEXITCODE -ne 0) { exit 3 }'
    ('try { [void][System.IO.Directory]::CreateDirectory(' + (& $lit $bing) + ') } catch { exit 4 }')
    ('try { [void][System.IO.Directory]::CreateDirectory(' + (& $lit $spot) + ') } catch { exit 4 }')
    'exit 0'
  )
  # 提权那一侧的命令行转义太容易出错, 所以落成临时 .ps1 再 -File 执行。
  # 必须带 UTF-8 BOM: 不带 BOM 时 PowerShell 5.1 按 ANSI 读, 中文路径会乱码。
  $tmp = Join-Path $env:TEMP ('wbwfix_' + [guid]::NewGuid().ToString('N') + '.ps1')
  try {
    [System.IO.File]::WriteAllText($tmp, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
  } catch { return $false }
  $code = -1
  try {
    $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
         -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tmp)
    if ($p) { $code = $p.ExitCode }
  } catch {
    Log ('盘权限修复: 提权被取消或起不来 - ' + $_.Exception.Message)
    $code = -1
  }
  try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch {}
  if ($code -ne 0) { Log ('盘权限修复: 退出码 ' + $code + ' (2/3/4=建目录或授权失败, -1=提权被取消)'); return $false }
  # 盘根那条 ACL 是进程外改的, 进程内缓存里的旧结论作废, 重新实测
  if ($global:BWWriteCache) { $global:BWWriteCache.Remove(($b.Substring(0, 3)).ToUpper()) }
  $ok = ((Test-BwWritable $bing) -and (Test-BwWritable $spot))
  Log ('盘权限修复: ' + $b + ' -> 实测可写=' + $ok)
  return $ok
}
function Get-BwPickRoot {
  if ($global:BWPickRoot) { return $global:BWPickRoot }
  $sys = ''
  try { $sys = ([string]$env:SystemDrive).TrimEnd('\') } catch {}
  $fixed = @(); $net = @()
  try {
    foreach ($dr in [System.IO.DriveInfo]::GetDrives()) {
      try {
        if (-not $dr.IsReady) { continue }
        $n = ([string]$dr.Name).TrimEnd('\')
        if ((-not $n) -or ($n -eq 'A:') -or ($n -eq 'B:')) { continue }
        # 必须是 [PSCustomObject]。写成 [psobject]@{} 或 @{} 得到的是 Hashtable,
        # Sort-Object 取不到 .Free 属性 -> 排序**静默失效**, 结果按枚举顺序倒着来,
        # 实测恒返回 F: (哪怕 E: 的可用空间是它的两倍)。
        $item = [PSCustomObject]@{
          Name     = $n
          Free     = [long]$dr.AvailableFreeSpace
          Sys      = ($n -eq $sys)
          Writable = (Test-BwDriveUsable ($n + '\'))
        }
        if ($dr.DriveType -eq [System.IO.DriveType]::Fixed) { $fixed += $item }
        elseif ($dr.DriveType -eq [System.IO.DriveType]::Network) { $net += $item }
      } catch {}
    }
  } catch {}
  # 优先级: 非系统盘且可写 > 非系统盘 > 任意本地盘 > 可写网络盘 > 任意网络盘
  $pick = @($fixed | Where-Object { -not $_.Sys -and $_.Writable } | Sort-Object Free -Descending)
  if ($pick.Count -eq 0) { $pick = @($fixed | Where-Object { -not $_.Sys } | Sort-Object Free -Descending) }
  if ($pick.Count -eq 0) { $pick = @($fixed | Sort-Object Free -Descending) }
  if ($pick.Count -eq 0) { $pick = @($net | Where-Object { $_.Writable } | Sort-Object Free -Descending) }
  if ($pick.Count -eq 0) { $pick = @($net | Sort-Object Free -Descending) }
  if ($pick.Count -gt 0) { $global:BWPickRoot = ($pick[0].Name + '\') }
  else { $global:BWPickRoot = (Join-Path $env:USERPROFILE 'Pictures') }
  return $global:BWPickRoot
}
# 给首次运行向导用: 列出能拿来存壁纸的盘, 非系统盘排在前面, 同档按可用空间从大到小。
# 只要盘还在、能访问就算候选 —— C 盘以外任何一个盘都可以, 用户自己挑。
function Get-BwDriveChoices {
  $sys = ''
  try { $sys = ([string]$env:SystemDrive).TrimEnd('\') } catch {}
  $list = @()
  try {
    foreach ($dr in [System.IO.DriveInfo]::GetDrives()) {
      try {
        if (-not $dr.IsReady) { continue }
        $n = ([string]$dr.Name).TrimEnd('\')
        if ((-not $n) -or ($n -eq 'A:') -or ($n -eq 'B:')) { continue }
        $net = ($dr.DriveType -eq [System.IO.DriveType]::Network)
        if ((-not $net) -and ($dr.DriveType -ne [System.IO.DriveType]::Fixed)) { continue }
        $list += [PSCustomObject]@{
          Name     = $n
          Free     = [long]$dr.AvailableFreeSpace
          Sys      = ($n -eq $sys)
          Net      = $net
          Writable = (Test-BwDriveUsable ($n + '\'))
        }
      } catch {}
    }
  } catch {}
  if ($list.Count -eq 0) { return @() }
  # 能用的排前面, 其次非系统盘, 同档按可用空间从大到小 —— 第一个就是推荐值。
  # 排序只决定"谁排前面", **不筛掉任何盘**: 所有盘都要在向导里让用户自己选。
  # 原因是"这个盘能不能写"是每台机器各自的权限设置, 不是程序的产品规则;
  # 把用不了的盘从列表里剔除, 用户会以为"这程序不支持我的盘", 那是误导。
  # (v1.2.2 就是这么干的, 属于过度纠正, v1.2.3 改回来。)
  return @($list | Sort-Object @{ Expression = { if ($_.Writable) { 0 } else { 1 } } },
                                  @{ Expression = { if ($_.Sys) { 1 } else { 0 } } },
                                  @{ Expression = { $_.Free }; Descending = $true })
}
# ---- 盘符: 统一只留一个大写字母 ----
# 各处比较盘符时, 一会儿拿到 "C:" 一会儿拿到 "C", 于是 "C" -ne "C:" 恒为真 ——
# 系统盘从来没被排除过。表现是: 明明「图片」文件夹还在系统盘上, 程序却判定
# "你的图片文件夹本来就在系统盘以外", 老老实实把壁纸往 C 盘里塞 ——
# 而那正是绝大多数用户的默认情况 (也是壁纸越攒越多撑满系统盘的由来)。
# 以后比盘符一律走这两个函数, 别再手写 TrimEnd。
# 系统「图片」文件夹自己的名字: 你这台叫「我的图片」, 别人那台可能叫「图片」/「Pictures」。
# 兜底要造文件夹时跟着这台机器的叫法走, 不一刀切写成「图片」——
# 不然明明你自己的图片文件夹叫「我的图片」, 程序却在盘根另造一个「图片」跟它并列。
function Get-BwPicturesLeaf {
  $p = ''
  try { $p = Split-Path (Get-BwPicturesDir) -Leaf } catch { $p = '' }
  if (-not $p) { $p = '图片' }
  return $p
}

function Get-BwSysDriveLetter {
  try { return (([string]$env:SystemDrive).TrimEnd('\').TrimEnd(':')).ToUpper() } catch { return '' }
}
function Get-BwDriveLetter([string]$p) {
  if (-not $p) { return '' }
  if ($p -match '^([A-Za-z]):') { return $Matches[1].ToUpper() }
  return ''
}

# ---- 系统「图片」文件夹的真实位置 ----
# 这个文件夹是可以被改到别处的 (资源管理器里右键「图片」- 属性 - 位置 - 移动),
# 所以不能写死 C:\Users\xxx\Pictures。三档兜底: .NET -> 注册表 -> 主目录下的 Pictures。
function Get-BwPicturesDir {
  if ($global:BWPicturesDir) { return $global:BWPicturesDir }
  $p = ''
  try { $p = [string][Environment]::GetFolderPath('MyPictures') } catch { $p = '' }
  if (-not $p) {
    try {
      $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -Name 'My Pictures' -ErrorAction Stop).'My Pictures'
      if ($v) { $p = [Environment]::ExpandEnvironmentVariables([string]$v) }
    } catch {}
  }
  if (-not $p) { $p = (Join-Path $env:USERPROFILE 'Pictures') }
  $global:BWPicturesDir = $p
  return $global:BWPicturesDir
}
# ---- 在非系统盘上找「已经存在的图片文件夹」 ----
# 用户的规矩(2026-09-20): C 盘以外只要已经有放图片的文件夹, 就先定位到那里 ——
#   不要让用户自己挑, 更不要凭空在盘根再造一个「图片」出来。
#   以前的做法是挑一个非系统盘然后建 <盘>\图片\壁纸, 于是明明 F 盘上就有
#   「我的图片」, 盘根还是多出一个空的「图片」—— 用户的话: "它要造反吗?"。
# 只读扫描: 只看每个非系统盘的**根目录一层**, 只用"里面有没有 jpg"下判断,
# 全程不建任何目录 (Test-BwWritable 会建目录, 这里一个都不许调)。
function Test-BwHasJpg([string]$dir) {
  if (-not $dir) { return $false }
  if (-not (Test-Path -LiteralPath $dir)) { return $false }
  # 只看第一张就够: 上万张图的文件夹也能瞬间给结论, 不用把目录数完
  $one = @(Get-ChildItem -LiteralPath $dir -File -Filter *.jpg -ErrorAction SilentlyContinue | Select-Object -First 1)
  return ($one.Count -gt 0)
}
function Find-BwExistingBase {
  $sys = Get-BwSysDriveLetter
  $picNames = @('图片', '我的图片', 'Pictures', '照片', 'Images', '图库')
  $best = ''; $bestScore = -1; $bestWhy = ''
  try {
    foreach ($dr in [System.IO.DriveInfo]::GetDrives()) {
      try {
        if (-not $dr.IsReady) { continue }
        if ($dr.DriveType -ne [System.IO.DriveType]::Fixed) { continue }
        $root = ([string]$dr.Name).TrimEnd('\')          # 形如 F:
        $drv  = $root.TrimEnd(':').ToUpper()
        if (-not $drv -or ($drv -eq $sys)) { continue }   # 系统盘不参与
        # 1) 盘根就有个「壁纸」并且里面有图 -> 那已经是现成的库, 直接用
        $wp = Join-Path $root '壁纸'
        if ((Test-BwHasJpg $wp) -and 110 -gt $bestScore) {
          $bestScore = 110; $best = $wp
          $bestWhy = $drv + ': 上已经有放壁纸的文件夹'
        }
        # 2) 这一档: 盘上散着图片文件, 但没专门建图片文件夹 —— 那这个盘就是拿来放图的,
        #    壁纸归到它的「图片\壁纸」下。用户的意思: 一个现成的图片文件夹都没有时,
        #    程序自己造一个, 而不是退回系统盘。
        if (Test-BwHasJpg $root) {
          if (20 -gt $bestScore) {
            $bestScore = 20
            $best = (Join-Path $root ((Get-BwPicturesLeaf) + '\壁纸'))
            $bestWhy = $drv + ': 上散着图片文件, 但没有专门的图片文件夹'
          }
        }
        # 3) 已有的图片文件夹: 下面带「壁纸」子目录且里面有图 > 里面有图 > 空文件夹
        foreach ($nm in $picNames) {
          $p = Join-Path $root $nm
          if (-not (Test-Path -LiteralPath $p)) { continue }
          $sub = Join-Path $p '壁纸'
          $sc = 10
          $why = $drv + ': 上本来就有「' + $nm + '」文件夹'
          # 库是两层: <图片>\壁纸\必应 / \聚焦。只数「壁纸」这一层会漏 ——
          # 那层只有两个子目录, 一张图都没有, 于是真正存着图的库被当成空文件夹。
          $hasLib = ((Test-BwHasJpg $sub) -or (Test-BwHasJpg (Join-Path $sub '必应')) -or (Test-BwHasJpg (Join-Path $sub '聚焦')))
          if ($hasLib) { $sc = 100; $why = $why + ', 里面还留着以前下载的壁纸' }
          elseif (Test-BwHasJpg $p) { $sc = 50 }
          if ($sc -gt $bestScore) { $bestScore = $sc; $best = (Join-Path $p '壁纸'); $bestWhy = $why }
        }
        # 深度 2: 盘根下面一层里再找一遍 —— 很多人把图片收在 <盘>\我的资料\图片 这种位置,
        # 只扫盘根会漏。只取前 40 个子目录, 免得碰上文件特别多的盘把启动拖慢。
        # 分数刻意比深度 1 低一点: 盘根那个更可能是"这台机器的图片文件夹"。
        $subs = @(Get-ChildItem -LiteralPath ($root + '\') -Directory -ErrorAction SilentlyContinue | Select-Object -First 40)
        foreach ($sd in $subs) {
          foreach ($nm in $picNames) {
            $p2 = Join-Path $sd.FullName $nm
            if (-not (Test-Path -LiteralPath $p2)) { continue }
            $sub2 = Join-Path $p2 '壁纸'
            $sc2 = 5
            $why2 = $drv + ': 上的「' + $sd.Name + '\' + $nm + '」'
            $hasLib2 = ((Test-BwHasJpg $sub2) -or (Test-BwHasJpg (Join-Path $sub2 '必应')) -or (Test-BwHasJpg (Join-Path $sub2 '聚焦')))
            if ($hasLib2) { $sc2 = 95; $why2 = $why2 + ', 里面还留着以前下载的壁纸' }
            elseif (Test-BwHasJpg $p2) { $sc2 = 45 }
            if ($sc2 -gt $bestScore) { $bestScore = $sc2; $best = (Join-Path $p2 '壁纸'); $bestWhy = $why2 }
          }
        }
      } catch {}
    }
  } catch {}
  if ($bestScore -lt 0) { return $null }
  return [PSCustomObject]@{ Base = $best; Why = $bestWhy }
}
# ---- 壁纸默认放「图片」文件夹里的「壁纸」----
# 用户的安排: 壁纸就该归在图片库里, 不要再往盘根丢一个 X:\微软壁纸助手。
# 但有个现实问题: 图片文件夹默认就在系统盘 (C:\Users\xxx\Pictures),
#   壁纸每天都攒, 几年下来好几个 GB, 会把系统盘撑满。所以:
#     * 图片文件夹在系统盘以外 -> 直接用 <图片>\壁纸 (尊重用户自己的安排)
#     * 图片文件夹在系统盘     -> 先找 C 盘以外**已经存在**的图片文件夹, 用它下面的「壁纸」;
#                                 一个都找不到, 才挑一个非系统盘用 <盘>\图片\壁纸
#     * 这台机器只有系统盘     -> 只能用 <图片>\壁纸, 并在向导里说清楚
# 挑盘的规则沿用 Get-BwPickRoot (非系统盘优先、可写优先、可用空间降序)。
function Get-BwDefaultBase {
  if ($global:BWDefaultBase) { return $global:BWDefaultBase }
  $pic = Get-BwPicturesDir
  $sys = Get-BwSysDriveLetter
  $drv = Get-BwDriveLetter $pic
  if ($drv -and ($drv -ne $sys)) {
    $global:BWDefaultBase = (Join-Path $pic '壁纸')
    $global:BWBaseReason  = '你的「图片」文件夹本来就在系统盘以外'
  } else {
    $found = Find-BwExistingBase
    if ($found) {
      $global:BWDefaultBase = $found.Base
      $global:BWBaseReason  = '「图片」文件夹在系统盘上, 而' + $found.Why + ' —— 壁纸归到它下面, 不再多造一个文件夹'
    } else {
      # 一个现成的图片文件夹都没有: 就放在「图片」文件夹自己的位置下面, 不再另起一条路径。
      # (以前这里是挑一个非系统盘凭空造 <盘>\图片\壁纸 —— 那正是用户说的"它要造反吗":
      #  明明盘上就有「我的图片」, 盘根却多出一个空的「图片」跟它并列。)
      # 目录不存在没关系, 建库的时候会自己创建出来。
      $global:BWDefaultBase = (Join-Path $pic '壁纸')
      $global:BWBaseReason  = '这台机器上没找到别的现成图片文件夹, 就放在你的「图片」文件夹里, 不再另外造一个'
    }
  }
  return $global:BWDefaultBase
}
function Get-BwDefaults {
  if ($global:BWDefaults) { return $global:BWDefaults }
  $base = Get-BwDefaultBase
  $global:BWDefaults = [PSCustomObject]@{
    base      = $base
    bing      = (Join-Path $base '必应')
    spotlight = (Join-Path $base '聚焦')
    reason    = $global:BWBaseReason
  }
  return $global:BWDefaults
}
# 目录不存在就建。建不成(权限/盘被拔了)返回 $false, 让调用方说人话, 而不是抛一堆栈。
function Ensure-BwDirs {
  $c = Get-BwConfig
  [void](New-BwDir $c.bing_save_dir)
  [void](New-BwDir $c.spotlight_save_dir)
  return [bool](Test-Path -LiteralPath $c.bing_save_dir)
}
# 真写一个临时文件再删, 比只看目录能不能访问准。
# 全程 .NET —— 之前用 New-Item/Set-Content/Remove-Item 的 -LiteralPath,
# 本机 New-Item 没这个参数会抛异常, 于是所有目录都被判成不可写(假阴性)。
function Test-BwWritable([string]$dir) {
  if (-not $dir) { return $false }
  if (-not (New-BwDir $dir)) { return $false }
  try {
    $t = Join-Path $dir ('.wtest_' + [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($t, 'x', [System.Text.Encoding]::ASCII)
    [System.IO.File]::Delete($t)
    return $true
  } catch { return $false }
}
function Get-BwConfig {
  $c = $null
  if (Test-Path $global:CfgPath) { try { $c = Get-Content $global:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
  $d = Get-BwDefaults
  if (-not $c) {
    $c = New-Object PSObject
    Add-Member -InputObject $c NoteProperty bing_save_dir $d.bing -Force
    Add-Member -InputObject $c NoteProperty spotlight_save_dir $d.spotlight -Force
    Add-Member -InputObject $c NoteProperty resolution_mode 'uhd' -Force
  }
  if (-not $c.bing_save_dir) { Add-Member -InputObject $c NoteProperty bing_save_dir $d.bing -Force }
  if (-not $c.spotlight_save_dir) {
    # 默认放必应库旁边; 必应库要是在盘根, 就退回 "<盘>\聚焦"
    $par = Split-Path $c.bing_save_dir -Parent
    if ($par) { Add-Member -InputObject $c NoteProperty spotlight_save_dir (Join-Path $par '聚焦') -Force }
    else { Add-Member -InputObject $c NoteProperty spotlight_save_dir $d.spotlight -Force }
  }
  if (-not $c.resolution_mode) { Add-Member -InputObject $c NoteProperty resolution_mode 'uhd' -Force }
  if (-not $c.spotlight_per_cycle) { Add-Member -InputObject $c NoteProperty spotlight_per_cycle 6 -Force }
  if (-not $c.cycle_minutes) { Add-Member -InputObject $c NoteProperty cycle_minutes 30 -Force }
  # 壁纸填充方式。默认 fill(填充) —— 与 v1.3.0 及更早的行为一致, 老用户升级后桌面不会变样。
  if (-not $c.wallpaper_style) { Add-Member -InputObject $c NoteProperty wallpaper_style 'fill' -Force }
  # 只在收藏里轮换。默认关。
  if (-not $c.fav_only) { Add-Member -InputObject $c NoteProperty fav_only $false -Force }
  if (-not $c.PSObject.Properties['desktop_shortcut']) { Add-Member -InputObject $c NoteProperty desktop_shortcut 'on' -Force }
  # 图库上限: 聚焦库最多留多少张。超了就把**已经看过**的最老的几张移进回收站。
  # 没看过的一律不动 —— 那是等着换的, 删了就得重新下载。
  # 0 = 不限(老样子, 只增不减)。默认 100 张(约 200 MB)。
  if (-not $c.PSObject.Properties['lib_cap']) { Add-Member -InputObject $c NoteProperty lib_cap 100 -Force }
  # 队列里的图换完之后, 要不要自动下一批新图? 默认**关**:
  # 库里现有的图轮着用就够了, 不过程序自己跑去下载一堆, 库越攒越大。
  # 想要不断有新图就到菜单里打开它。
  if (-not $c.PSObject.Properties['auto_fetch']) { Add-Member -InputObject $c NoteProperty auto_fetch $false -Force }
  return $c
}
function Save-BwConfig([psobject]$c) {
  [System.IO.File]::WriteAllText($global:CfgPath, ($c | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}
# ---- 自动轮换进度 (state.json): 每次运行是独立进程, 靠这个文件把节奏串起来 ----
# 只记三件事: 今天切过必应没有 / 上次换壁纸是什么时候 / 上次开机时间。
# 聚焦的"不重复"靠 queue —— 把库里所有图洗一次牌按顺序发, 发完再下载 6 张重洗一轮。
function Get-BwState {
  $existed = Test-Path -LiteralPath $global:BWState
  $s = $null
  if ($existed) {
    try { $s = Get-Content $global:BWState -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  }
  $ver = 0
  $needImport = $false
  $needDl = $false
  if ($s) { try { $ver = [int]$s.schema } catch { $ver = 0 } }
  if ($ver -lt 3) {
    # 3 以前的结构不一样, 没法迁, 重置
    if ($existed) { Log ('节奏进度文件版本 ' + $ver + ' -> 5, 结构变了, 已重置 (下一次运行会重新切一次必应当日图)') }
    $s = New-Object PSObject
  } elseif ($ver -eq 3) {
    # 3 -> 4 只是多了两个字段, 原有的换图进度全部保留
    Log '节奏进度文件 3 -> 4: 保留原有进度, 新增必应水位线'
  } elseif ($ver -eq 4) {
    # 4 -> 5 多了收藏名单, 换图进度、队列、水位线一律保留
    Log '节奏进度文件 4 -> 5: 保留原有进度, 新增收藏名单'
  } elseif ($ver -eq 5) {
    # 5 -> 6 多了"看过"名单, 换图进度、队列、收藏一律保留
    Log '节奏进度文件 5 -> 6: 保留原有进度, 新增「看过」名单(用来避免重洗时又排回老图)'
    # 名单是新东西, 以前换过的图一张都没记过。不回填的话那批图重洗时照样排回来,
    # 等于换了版本照样重复。日志里每次换图都有记录, 从那儿捞回来。
    $needImport = $true
  } elseif ($ver -eq 6) {
    # 6 -> 7 多了「累计下载张数」(菜单首页要显示), 进度/队列/收藏/看过名单一律保留
    Log '节奏进度文件 6 -> 7: 新增累计下载张数 (菜单首页显示, 只增不减)'
    $needDl = $true
  }
  # bing_high_date : 必应补漏的水位线, 只往前不后退 (详见 Get-BwHighDate)
  # favorites      : 收藏的图片文件名, 只记名字 (和 queue 一个口径); 图被删掉也
  #                  留着, 取用时自然剔除, 不必提前清理 —— 万一手滑删了还能加回来。
  # history        : **看过**的图的唯一标识(不是文件名, 见 Get-BwNameKey)。
  #                  有了它, 队列洗牌时才能把看过的挑出去 —— 不然每洗一轮,
  #                  昨天看过的 18 张又排回来, 客户看到的就是"这张我昨天不是刚看过吗"。
  # dl_total       : 从装上那天起**累计下载过多少张**。只增不减 —— 图被删掉、
  #                  被移走、被库上限清进回收站, 这个数都不往回退(那是"下载过",
  #                  不是"现在还有")。删掉之后重新下载算新的一张, 如实再加一次。
  # dl_filled      : 老版本升级上来时做过回填没有(0/1)。回填只做一次。
  # strangers      : 库里"不是本程序下载的图"的图片编号 (见 Update-BwStrangers)。
  #                  只做记号, 图原地不动; 自动轮换时跳过它们。
  $def = [ordered]@{
    schema = 7; last_bing_date = ''; last_swap = ''; last_boot = ''
    queue = @(); refills = 0; shown = 0; last_wall = ''
    bing_high_date = ''; favorites = @(); history = @()
    dl_total = 0; dl_filled = 0; strangers = @()
  }
  foreach ($k in $def.Keys) {
    $p = $s.PSObject.Properties[$k]
    if ((-not $p) -or ($null -eq $p.Value)) { Add-Member -InputObject $s NoteProperty $k $def[$k] -Force }
  }
  # schema 要**强制**写成当前版本: 上面那个循环只在"字段缺失或为空"时才补,
  # 而 schema 永远是 3 (有值), 于是升完级还是 3, 每次进来都要再"升级"一遍。
  Add-Member -InputObject $s NoteProperty schema 7 -Force
  # 这时候 history 字段已经补齐了, 回填才安全
  if ($needImport) {
    $n = Import-BwHistFromLog $s
    if ($n -gt 0) { Log ('  从日志回填了 ' + $n + ' 张「看过」的图 (以前换过的现在也认得出来了)') }
  }
  if ($needDl -and ([int]$s.dl_filled -eq 0)) {
    # 老版本从没记过"下载过几张"。装上新版第一次进来时补一个基数:
    # 库里还剩下的 + 「看过」名单里记着的(删掉的图名字还留着) + 日志里能翻到的
    # 下载记录, 三处按图片编号去重后取并集 —— 能追溯到的都算上。
    $n2 = Fill-BwDlBase $s
    if ($n2 -gt 0) {
      $s.dl_filled = 1
      Log ('  累计下载张数: 按现有痕迹回填了 ' + $n2 + ' 张 (更早就下载过、又已经被清出名单的, 查不到了)')
      # 当场落盘: 回填只该做一次, 不落盘的话下次进来又要重算一遍。
      # 走 KeepFav 合并写, 免得把用户正在菜单里改的东西覆盖掉。
      Save-BwStateKeepFav $s
    }
  }
  return $s
}

# ---- 累计下载张数 ----
# 用户要的是「从装上那天起一共下载过多少张」, 而且删掉的、被清走的都要算。
# v1.6.3 之前它只记在 state.json 的 dl_total 字段里 —— 有个致命漏洞:
# 菜单进程一直握着自己那份旧快照, 之后任何一次 Save-BwState 整份写回,
# 都会把下载时刚 +1 落盘的数打回旧值 (实测: 一天连下 6 张, 6 次 +1 全被
# 吞掉, 累计显示 53, 库里却有 59 张 —— 账对不上)。
# 现在改成**独立流水文件**: 每下载一张追加一行图片编号, 追加写不会被任何
# 进程覆盖; state.json 里的 dl_total 降级为显示缓存, 谁覆盖都不影响真账。
# 这份流水同时就是「程序下载清单」: 编号在流水里的 = 程序下载的;
# 库里出现编号不在流水里的图, 就是后来混进来的; 程序每次巡检会自动把它们移到各自库的「_外来待确认」, 不用用户动手校验。
# 读流水: 返回 @($总行数, $编号HashSet)。总行数 = 累计下载张数
# (删掉重下同一张会有两行, 如实算两张 —— "下载过"是次数, 不是品种);
# 编号集合 = 下载清单 (判断一张图是不是程序下的, 用它)。
function Read-BwDlLedger {
  $keys = New-Object 'System.Collections.Generic.HashSet[string]'
  $lines = 0
  try {
    if (Test-Path -LiteralPath $global:BWDlLedger) {
      foreach ($ln in @(Get-Content -LiteralPath $global:BWDlLedger -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $k = ([string]$ln).Trim()
        if (-not $k) { continue }
        $lines++
        [void]$keys.Add($k)
      }
    }
  } catch {}
  return @($lines, $keys)
}
# 从现有痕迹建一次流水 (只在流水文件不存在时发生, 幂等):
#   1) 两个库里现在还剩下的图   2) 「看过」名单 —— 删掉的图编号还留着
# 查不到的部分不猜: 数字只会**偏小**, 不会凭空变大。之后每下载一张都真记一行。
function New-BwDlLedgerFromTraces($s) {
  try {
    if (Test-Path -LiteralPath $global:BWDlLedger) {
      $r = Read-BwDlLedger
      return [int]$r[0]
    }
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    try {
      $c = Get-BwConfig
      foreach ($d in @([string]$c.bing_save_dir, [string]$c.spotlight_save_dir)) {
        if ($d -and (Test-Path -LiteralPath $d)) {
          foreach ($f in @(Get-ChildItem -LiteralPath $d -File -Filter *.jpg -ErrorAction SilentlyContinue)) {
            $k = Get-BwNameKey $f.Name
            if ($k) { [void]$set.Add($k) }
          }
        }
      }
    } catch {}
    foreach ($h in @(Get-BwHist $s)) { if ($h) { [void]$set.Add([string]$h) } }
    $sb = New-Object System.Text.StringBuilder
    foreach ($k in $set) { [void]$sb.AppendLine($k) }
    [System.IO.File]::WriteAllText($global:BWDlLedger, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    Log ('下载流水账初始化: 登记了 ' + $set.Count + ' 张 (库里现有 + 看过名单; 更早下载、又被清出痕迹的查不到)')
    return $set.Count
  } catch { return 0 }
}
function Get-BwDlTotal($s) {
  # 流水文件在就以它为准 —— 哪怕里面是 0 行。少了这道判断, 库是空的
  # (新装的机器) 时每次显示"累计下载"都要把两个库重扫一遍。
  if (Test-Path -LiteralPath $global:BWDlLedger) { $r = Read-BwDlLedger; return [int]$r[0] }
  # 流水文件缺失: 从痕迹补建一次 (老版本升级 / 用户手动删过数据目录)
  try { $n = New-BwDlLedgerFromTraces $s; if ($n -gt 0) { return $n } } catch {}
  if ($s) { try { return [int]$s.dl_total } catch { return 0 } }
  return 0
}
# 下载清单 (编号集合)。自动校验图库 (Repair-BwVerifyLibrary) 用它分辨
# 「程序下载的」和「混进来的」。
function Get-BwDlKeys {
  if (-not (Test-Path -LiteralPath $global:BWDlLedger)) { New-BwDlLedgerFromTraces $null | Out-Null }
  $r = Read-BwDlLedger
  return $r[1]
}
# 图库里"不是本程序下载的那些图" —— **只做记号, 不动文件**。
#
# 依据: 每张程序下载的图都在 dl_ledger.log 登记了编号 (见 Add-BwDlCount)。
# 库里有、清单里没有的 = 你自己放进去的 / 改过名的 / 更老版本下的(痕迹查不到)。
#
# 记号记在 state.json 的 strangers 里 (只存图片编号, 和「看过」名单一个口径)。
# 打完记号的效果有两个, 都**不碰文件**:
#   1) 自动轮换时跳过它们 —— 程序只换自己下过的图, 你自己的图不会被换到桌面上;
#   2) 菜单里能看见: 首页报个数, 库列表里 [4] 那张标一个「外」字。
# 图本身原地不动、不改名、不删 —— 图库是你的地盘。
#
# 全程不用你管: 每次后台巡检自动跑一遍, 进了新的图自己就认出来了。
# -DryRun 时只算不写 —— 试运行的意思就是"什么都不改"。
# 返回做了记号的张数。
function Update-BwStrangers {
  try {
    $c = Get-BwConfig
    $keys = Get-BwDlKeys
    $list = @()
    foreach ($d in @([string]$c.bing_save_dir, [string]$c.spotlight_save_dir)) {
      if (-not ($d -and (Test-Path -LiteralPath $d))) { continue }
      foreach ($f in @(Get-BwPicFiles $d)) {
        $k = Get-BwNameKey $f.Name
        if ($k -and -not $keys.Contains($k)) { $list += $k }
      }
    }
    $list = @($list | Select-Object -Unique)
    if ($global:BWDry) {
      if ($list.Count -gt 0) { Log ('试运行: 认出 ' + $list.Count + ' 张不在下载清单里的图 (本应做记号, 不写盘)') }
      return $list.Count
    }
    $s = Get-BwState
    if (-not $s) { return $list.Count }
    $before = @(@($s.strangers) | Where-Object { $_ }).Count
    $s.strangers = $list
    if ($list.Count -ne $before) {
      Log ('图库记号: 不在下载清单里的图 ' + $before + ' -> ' + $list.Count + ' 张 (原地不动, 不参与自动轮换)')
    }
    Save-BwStateKeepFav $s
    return $list.Count
  } catch { return 0 }
}
# 老版本升级路径保留原函数名: 算痕迹并集, 回填 state 里的显示缓存。
function Fill-BwDlBase($s) {
  $n = New-BwDlLedgerFromTraces $s
  if ($n -gt (Get-BwDlTotal $s)) { $s.dl_total = $n }
  return (Get-BwDlTotal $s)
}
# 成功下载一张 +1: 往流水追加一行图片编号。追加写不怕并发,
# 也不会被任何整份写回覆盖 —— 这是它比记在 state.json 里可靠的根本原因。
function Add-BwDlCount([int]$n = 1, [string]$key) {
  if ($n -le 0) { return }
  try {
    # 流水还没建过的话先按痕迹建一次 (幂等) —— 别让第一行下载记录顶掉基数。
    # 判断"建过没有"看文件在不在, 不能看行数: 库是空的时流水本来就是 0 行,
    # 看行数的话每下载一张都要把两个库重扫一遍。
    if (-not (Test-Path -LiteralPath $global:BWDlLedger)) { New-BwDlLedgerFromTraces $null | Out-Null }
    if (-not $key) { $key = 'unknown-' + (Get-Date -Format 'yyyyMMddHHmmss') }
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $n; $i++) { [void]$sb.AppendLine($key) }
    [System.IO.File]::AppendAllText($global:BWDlLedger, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
  # state 里的 dl_total 只是显示缓存, 尽力同步一下 (失败不影响真账)
  try {
    $s = Get-BwState
    if ($s) {
      $s.dl_total = Get-BwDlTotal $s
      Save-BwStateKeepFav $s
    }
  } catch {}
}
# ---- 图库上限 ----
# 库只增不减的话, 用几个月就攒到上千张好几个 GB。设个上限, 超了就把
# **已经看过**的最老的几张清走; 没看过的一律不动(那是等着换的, 删了还得重新下)。
function Get-BwLibCap {
  $c = Get-BwConfig
  $v = 0
  try { $v = [int]$c.lib_cap } catch { $v = 0 }
  return $v
}
# 移进回收站(能还原)。走不通就退到「已看过」文件夹 —— 绝不直接删文件。
function Move-BwToRecycle([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  try {
    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path,
      [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
      [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
    return $true
  } catch {}
  try {
    $c = Get-BwConfig
    $par = Split-Path ([string]$c.spotlight_save_dir) -Parent
    if ($par) {
      $d2 = Join-Path $par '已看过'
      [void](New-BwDir $d2)
      Move-Item -LiteralPath $path -Destination (Join-Path $d2 (Split-Path $path -Leaf)) -Force -ErrorAction Stop
      return $true
    }
  } catch {}
  return $false
}
# 换完一张之后调一次: 库超上限就淘汰看过的最老的, 直到降到上限以内。
function Trim-BwLibrary($s) {
  $cap = Get-BwLibCap
  if ($cap -le 0) { return 0 }
  $c = Get-BwConfig
  $dir = [string]$c.spotlight_save_dir
  if (-not $dir) { return 0 }
  if (-not (Test-Path -LiteralPath $dir)) { return 0 }
  $files = @(Get-ChildItem -LiteralPath $dir -File -Filter *.jpg -ErrorAction SilentlyContinue)
  $over = $files.Count - $cap
  if ($over -le 0) { return 0 }
  $hist = @(Get-BwHist $s)
  if ($hist.Count -eq 0) { return 0 }
  # 当前正显示的那张不能动
  $curKey = ''
  if ($s.last_wall) { $curKey = Get-BwNameKey (Split-Path ([string]$s.last_wall) -Leaf) }
  $cand = @()
  foreach ($h in $hist) {
    if ($h -eq $curKey) { continue }
    $f = @($files | Where-Object { (Get-BwNameKey $_.Name) -eq $h } | Select-Object -First 1)
    if ($f.Count -gt 0) { $cand += $f[0] }
    if ($cand.Count -ge $over) { break }
  }
  $moved = 0
  foreach ($f in $cand) {
    if (Move-BwToRecycle $f.FullName) { $moved++ }
  }
  if ($moved -gt 0) {
    Log ('图库上限 ' + $cap + ' 张: 库里 ' + $files.Count + ' 张超了, 已把看过的最老的 ' + $moved + ' 张移进回收站')
  }
  return $moved
}

# 从 wallpaper.log 把"以前换过哪些图"捞回来填进「看过」名单。
# 名单是 v1.5.4 才有的, 老用户升级上来时名单是空的 —— 不回填的话,
# 那批以前看过的图重洗队列时照样排回来, 换了个版本照样重复。
function Import-BwHistFromLog($s) {
  $n = 0
  if (-not $s) { return 0 }
  if (-not (Test-Path -LiteralPath $global:BWLog)) { return 0 }
  try {
    foreach ($line in @(Get-Content -LiteralPath $global:BWLog -Encoding UTF8 -ErrorAction SilentlyContinue)) {
      if ($line -match '->\s*(.+?)\s*\(ok=') {
        $nm = $matches[1].Trim()
        if ($nm) { Add-BwHist $s $nm; $n++ }
      }
    }
  } catch {}
  return $n
}

# ---- 「看过」名单 ----
# 记**图的唯一标识**, 不是文件名。原因: 聚焦图的文件名带下载日期前缀
# (2026-09-19_标题_slug.jpg), 同一张图换个日子再下载一次, 文件名就变了 ——
# 只比文件名会当成两张不同的图, 于是又下载一遍、又排进队列, 客户又看一次。
# 而文件名末尾那截 slug 是图片本身在微软那边的唯一编号, 换个日期也不变。
# 必应图没有 slug, 用完整文件名(日期+标题, 本身就唯一)。
function Get-BwNameKey([string]$name) {
  if (-not $name) { return '' }
  $n = [string]$name
  $b = [System.IO.Path]::GetFileNameWithoutExtension($n)
  $i = $b.LastIndexOf('_')
  if ($i -gt 0) {
    $tail = $b.Substring($i + 1)
    # 聚焦的 slug 是纯小写英文数字(如 lakemisurinaitaly), 长度至少 6
    if ($tail -match '^[a-z0-9]{6,}$') { return $tail }
  }
  return $b
}
function Get-BwHist($s) {
  if (-not $s) { return @() }
  return @(@($s.history | Where-Object { $_ }) | ForEach-Object { [string]$_ })
}
# 记一张"看过了"。名单有上限(400), 老的自然淘汰, 免得 state.json 越攒越大。
function Add-BwHist($s, [string]$name) {
  $k = Get-BwNameKey $name
  if (-not $k) { return }
  $h = @(Get-BwHist $s)
  if ($h -contains $k) { return }
  $h = @(@($h) + @($k))
  if ($h.Count -gt 400) { $h = @($h | Select-Object -Last 400) }
  $s.history = $h
}
function Save-BwState($s) {
  $s.queue = @($s.queue | Where-Object { $_ })
  # dl_total 是显示缓存, 真账在流水文件里。写回前按流水同步一次:
  # 这样菜单进程哪怕握着旧快照整份覆盖, 带出去的也是当前真值,
  # 不会再把后台刚 +1 的数打回去 (v1.6.2 丢计数就是这个路子)。
  try { $s.dl_total = Get-BwDlTotal $s } catch {}
  [System.IO.File]::WriteAllText($global:BWState, ($s | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
}
# 后台巡检 / 补漏写回 state 时必须走这里, 不能直接 Save-BwState 整份覆盖。
#
# 为什么: 后台是"开头读一次 state, 跑几分钟(下载、补漏)之后整份写回"。
# 这期间用户很可能正在菜单里操作 —— 按 [F] 收藏、手动挑一张设为壁纸,
# 改的是同一份文件。后台手里是几分钟前的旧快照, 一覆盖就把用户刚做的事
# 无声吞掉: 不报错、不写日志, 用户只会觉得"这软件有毛病", 根本查不出原因。
#
# 三条原则(每一条都对应一个上面互通不了的字段):
#   收藏夹   —— 后台从不主动改它, 写回时一律以磁盘为准(否则刚取消的收藏会被还原)
#   当前壁纸 —— 谁最后动过听谁的(比 last_swap), 菜单挑的那张不会被旧值顶回去
#   看过名单 —— 两边都可能往里加(后台换图 + 用户手动挑图), 取并集而不是覆盖
function Save-BwStateKeepFav($s) {
  $disk = Get-BwState
  if (-not $disk) { Save-BwState $s; return }
  $s.favorites = @(@($disk.favorites) | Where-Object { $_ })
  $dT = Get-BwTime ([string]$disk.last_swap)
  $sT = Get-BwTime ([string]$s.last_swap)
  if ($dT -and $sT -and ($dT -gt $sT)) {
    if ($disk.last_wall) { $s.last_wall = [string]$disk.last_wall }
    $s.last_swap = [string]$disk.last_swap
  }
  # 累计显示数不许倒退: 两边都可能在对方跑长任务时自增过, 取大的那个
  if ([int]$disk.shown -gt [int]$s.shown) { $s.shown = [int]$disk.shown }
  # 累计下载数: 真账在流水文件里, 这里只把显示缓存刷成当前真值
  # (旧的"取大的那个"是在救 state 字段, 现在真账不怕覆盖, 直接同步)
  try { $s.dl_total = Get-BwDlTotal $s } catch {}
  $dh = @(@($disk.history) | Where-Object { $_ })
  $sh = @(@($s.history) | Where-Object { $_ })
  if ($dh.Count -gt 0) {
    $u = @(@($sh) + @($dh | Where-Object { $sh -notcontains $_ })) | Select-Object -Unique
    $s.history = @($u | Select-Object -Last 400)
  }
  Save-BwState $s
}
function Get-BwTime([string]$t) {
  try { return [DateTime]::ParseExact($t, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}
function Set-BwWall([string]$path) {
  # 已经是这张就不重复调 API, 少一次桌面重绘
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  if ($global:BWDry) { Log ('试运行: 本应设为壁纸 -> ' + $path); return $true }
  $cur = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue).Wallpaper
  if ($cur -and ($cur -eq $path)) { return $true }
  return (Set-BwDesktopWallpaper $path)
}
# ---- 聚焦库 ----
# 一律返回"普通数组"。不要写 `return ,@(...)` —— 它在 @(f).Count / f | Where-Object
# 下会把整个数组当成一个元素, 导致"库里有 60 张"被看成"1 张"、过滤整个失效。
# 只认库根目录下这一层的 .jpg, 不往子目录里钻。
# 用户会自己整理图片 (建子目录、挪地方、删掉), 程序得给一个稳定可预期的口径:
# 「库里有几张」== 「能轮换到几张」。递归的话这两个数会对不上 ——
# 菜单显示 124 张, 队列里却只有 100 张能用, 看着像程序漏了图。
function Get-BwSpotlightAll {
  $c = Get-BwConfig
  return @(Get-ChildItem -LiteralPath $c.spotlight_save_dir -File -Filter *.jpg -ErrorAction SilentlyContinue)
}
function Get-BwSpotlightWant {
  $c = Get-BwConfig
  if ($c.spotlight_per_cycle) { return [int]$c.spotlight_per_cycle }
  return 6
}
# 把库里的图洗一次牌。
# 注意: 光"洗牌"只能保证**一轮之内**不重复 —— 队列发完再洗一轮时, 库里所有图
# (包括上一轮全看过的)都会被重新洗进来, 客户就会又看到昨天那张。
# 所以洗牌前先把「看过」名单里的挑出去, 只排没看过的。
# 开了「只看收藏」就只洗收藏里那几张; 收藏里一张都用不了(还没收藏、或全被删了)时
# 退回洗整个库 —— 不然会卡在"挑不出图"上, 永远不换壁纸。
function Get-BwFreshQueue($s) {
  $c = Get-BwConfig
  $names = @()
  if ([bool]$c.fav_only) {
    foreach ($f in @(Get-BwFavFiles $s)) { $names += [string]$f.Name }
    if ($names.Count -eq 0) {
      Log '只看收藏: 收藏里没有能用的图, 这一轮先从整个库里挑'
      foreach ($f in @(Get-BwSpotlightAll)) { $names += [string]$f.Name }
    }
  } else {
    foreach ($f in @(Get-BwSpotlightAll)) { $names += [string]$f.Name }
  }
  if ($names.Count -eq 0) { return @() }
  $allNames = @($names)

  # 挑掉看过的
  $seen = @{}
  foreach ($h in @(Get-BwHist $s)) { if ($h) { $seen[[string]$h] = $true } }
  if ($seen.Count -gt 0) {
    $fresh = @($names | Where-Object { -not $seen.ContainsKey((Get-BwNameKey $_)) })
    if ($fresh.Count -gt 0) {
      Log ('重洗队列: 库里 ' + $names.Count + ' 张, 看过 ' + ($names.Count - $fresh.Count) + ' 张 -> 这一轮只排没看过的 ' + $fresh.Count + ' 张')
      $names = $fresh
    } else {
      # 库里全都看过: 历史清零重来一轮。但留最近 20 条,
      # 免得刚看完那张翻个身又排到队首。
      $s.history = @(@(Get-BwHist $s) | Select-Object -Last 20)
      Log ('重洗队列: 库里 ' + $names.Count + ' 张全都看过 -> 历史清零重来(留最近 20 条防连着重复)')
    }
  }
  # 再挑掉"做了记号的外来图" —— 程序只换自己下过的图。
  # 兜底: 万一库里**全是**外来图 (用户自己的照片放了一堆进来), 挑完就一张不剩了,
  # 那还不如照常用 —— 总不能因为认出来了就一张都不给换。
  $mark = @{}
  foreach ($k in @(@($s.strangers) | Where-Object { $_ })) { $mark[[string]$k] = $true }
  if ($mark.Count -gt 0) {
    $own = @($names | Where-Object { -not $mark.ContainsKey((Get-BwNameKey $_)) })
    if ($own.Count -gt 0) {
      $names = $own
      Log ('重洗队列: 跳过 ' + ($allNames.Count - $own.Count) + ' 张做了记号的外来图')
    } else {
      $names = $allNames
      Log '重洗队列: 库里全是做了记号的外来图, 这一轮照常用它们换 (总得有图可换)'
    }
  }
  return @($names | Sort-Object { Get-Random })
}

# ---- 收藏 ----
# 名单存在 state.json 里(和 queue 一个口径, 只记文件名), 不在壁纸目录写 sidecar ——
# 那样用户整理图片时会看到一堆额外的小文件, 平白把壁纸文件夹弄脏。
# 图被删掉或挪走后, 收藏项会指向不存在的图; 取用时剔除就行, 不提前清理
# (万一手滑删了, 把图拷回来收藏还在)。
function Get-BwFav($s) {
  if (-not $s) { return @() }
  return @(@($s.favorites | Where-Object { $_ }) | ForEach-Object { [string]$_ })
}
function Test-BwFav($s, [string]$name) {
  if (-not $name) { return $false }
  $n = [string]$name
  foreach ($f in (Get-BwFav $s)) { if ($f -eq $n) { return $true } }
  return $false
}
# 返回是否真的新增了 —— 已经收藏过的返回 False, 不重复记, 也不重复提示。
function Add-BwFav($s, [string]$name) {
  if (-not $name) { return $false }
  $n = [string]$name
  if (Test-BwFav $s $n) { return $false }
  # 必须写成 @(Get-BwFav $s) + @($n), 两边都是数组。
  # 单元素数组从函数返回时会被**展开成标量字符串**, 这时 `字符串 + 数组` 走的是
  # 字符串拼接而不是数组连接 —— 结果是收藏第二张时两个文件名首尾相连变成一条,
  # 收藏夹里就只剩一个拼坏的名字, 两张都不生效 (实测: 加第 2 张后 favcount 仍是 1)。
  $s.favorites = @(@(Get-BwFav $s) + @($n))
  return $true
}
function Remove-BwFav($s, [string]$name) {
  if (-not $name) { return $false }
  $n = [string]$name
  $before = @(Get-BwFav $s).Count
  $s.favorites = @(@(Get-BwFav $s) | Where-Object { $_ -ne $n })
  return (@(@($s.favorites)).Count -lt $before)
}
# 收藏里**现在还在库里**的文件 (必应、聚焦两个库都算)。不在库里的直接跳过。
function Get-BwFavFiles($s) {
  $want = @{}
  foreach ($n in (Get-BwFav $s)) { $want[$n] = $true }
  if ($want.Count -eq 0) { return @() }
  $out = @()
  foreach ($f in @(Get-BwSpotlightAll)) { if ($want.ContainsKey([string]$f.Name)) { $out += $f } }
  foreach ($f in @(Get-BwBingAll))      { if ($want.ContainsKey([string]$f.Name)) { $out += $f } }
  return @($out)
}
# 队列里存的是文件名, 而图随时可能被用户自己删掉或挪到别处 —— 这是完全正常的操作,
# 不是故障。所以每次取图之前先把"已经不在库里"的名字一次性剔掉, 而不是等轮到它
# 才发现不存在、一张一张慢慢淘汰 (队列上百张时能明显感到卡)。
# 注意: 库目录整个不见了 (移动硬盘没插、网络盘没连上) 时**不动队列** ——
# 那种情况只是暂时读不到, 清掉队列等于把用户的轮换进度白丢了。
function Sync-BwQueue($s) {
  $c = Get-BwConfig
  $dir = $c.spotlight_save_dir
  if (-not (Test-Path -LiteralPath $dir)) { return 0 }
  $live = @{}
  foreach ($f in @(Get-BwSpotlightAll)) { $live[[string]$f.Name] = $true }
  # 开了「只看收藏」时队列里会混进必应库的图, 把它们也算作"还在",
  # 否则这些图会在每次取图前被当成"已被删掉"剔得一干二净。
  if ([bool]$c.fav_only) { foreach ($f in @(Get-BwBingAll)) { $live[[string]$f.Name] = $true } }
  $before = @($s.queue | Where-Object { $_ }).Count
  if ($before -eq 0) { return 0 }
  $s.queue = @($s.queue | Where-Object { $_ -and $live.ContainsKey([string]$_) })
  $gone = $before - @($s.queue).Count
  if ($gone -gt 0) { Log ('队列里有 ' + $gone + ' 张已经不在库里 (被删除或移到别处), 已剔除') }
  return $gone
}
# 取队列里下一张。队列空了(或剩下的图被手动删了) -> 下载一批新的重洗。
# 好处: 洗牌后的队列总有图可取, 所以不需要"抓不到新图就清空历史"那种兜底分支,
# 也就不会有"挑不出图 -> 永远不换壁纸"的死局。
# 后台补货 (v1.6.5): 把新图下到库里, 并重洗队列让下一张就能轮到。
# 在隐藏进程里由 Start-BwBackfill 调用, 前台换图不干等。
# (名字带 Spot: 1295 行附近那个不带参数的 Invoke-BwBackfill 是必应补漏, 别混)
function Invoke-BwSpotBackfill([int]$count, [switch]$Force) {
  try {
    if ($count -le 0) { return }
    $c = Get-BwConfig
    # -Force = 恢复模式: 库被清空过, 前台先下 1 张之后库就不空了,
    # 光靠"库是空的"这个判断后台就再也不肯下(实测只补回 1 张), 所以显式穿透开关。
    if ($c.auto_fetch -or $Force -or (@(Get-BwSpotlightAll).Count -eq 0)) {
      $one = @(Invoke-SpotlightFetch -count $count -Quiet)
    }
    # 不管下到几张, 都重洗一次队列, 让新图进轮换
    $s = Get-BwState
    if ($s) {
      $s.queue = @(Get-BwFreshQueue $s)
      Save-BwState $s
    }
    Log ('后台补货结束: 库中现有 ' + @(Get-BwSpotlightAll).Count + ' 张, 队列已重洗')
  } catch { Log ('后台补货异常: ' + $_.Exception.Message) }
}
# 起一个脱离的隐藏 powershell 进程去跑 Invoke-BwSpotBackfill。
# 锁文件防止菜单和后台 daemon 同时各起一个补货进程; 锁 15 分钟自动过期,
# 进程崩了也不会把补货永久卡死。
function Start-BwBackfill([int]$count, [switch]$Force) {
  if ($count -le 0) { return }
  if ($global:BWDry) { Log ('试运行: 本应后台补货 ' + $count + ' 张聚焦壁纸'); return }
  try {
    $lock = Join-Path $global:BWRoot 'backfill.lock'
    if (Test-Path -LiteralPath $lock) {
      $age = 999.0
      try { $age = ((Get-Date) - (Get-Item -LiteralPath $lock).LastWriteTime).TotalMinutes } catch {}
      if ($age -lt 15) { Log ('后台补货已在进行, 不重复启动 (锁龄 ' + [int]$age + ' 分钟)'); return }
    }
    [System.IO.File]::WriteAllText($lock, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), (New-Object System.Text.UTF8Encoding($false)))
    $core = Join-Path $global:BWRoot 'core.ps1'
    $forceTxt = ''
    if ($Force) { $forceTxt = ' -Force' }
    # 用 -EncodedCommand 传命令: Start-Process 拼 -Command 参数时不给带空格的
    # 值加引号, 长命令会被拆碎 —— 实测子进程"删了锁却什么都没干"。base64 免疫。
    $cmd = ". '$core'; Invoke-BwSpotBackfill -count $count$forceTxt; Remove-Item -LiteralPath '$lock' -Force -ErrorAction SilentlyContinue"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand', $b64) | Out-Null
    Log ('换图不再等: 已转后台补货 ' + $count + ' 张')
  } catch { Log ('后台补货启动失败(不影响本次换图): ' + $_.Exception.Message) }
}
function Get-BwNextWall($s) {
  $c = Get-BwConfig
  for ($round = 1; $round -le 2; $round++) {
    [void](Sync-BwQueue $s)
    $q = @($s.queue | Where-Object { $_ })
    while ($q.Count -gt 0) {
      $name = [string]$q[0]
      $q = @($q | Select-Object -Skip 1)
      $p = Join-Path $c.spotlight_save_dir $name
      # 收藏里可能有必应库的图, 聚焦目录里找不到就再去必应目录找一次
      if (-not (Test-Path -LiteralPath $p)) { $p = Join-Path $c.bing_save_dir $name }
      if (Test-Path -LiteralPath $p) { $s.queue = $q; return (Get-Item -LiteralPath $p) }
      # 这张被删了, 丢掉接着取下一张
    }
    $s.queue = @()
    # 队列空了要不要下一批新图? 默认**不下** —— 库里现有的图轮着用就行,
    # 想让程序自己补新图的话去菜单 [S] 设置 - [0] 打开。
    # 例外: 库整个被清空(0 张)属于异常状态, 不论开关都自动补救 ——
    # 总不能让用户手动按 [3] 才有图可换。
    $libCount = @(Get-BwSpotlightAll).Count
    $recover = ($libCount -eq 0)
    if (($c.auto_fetch -or $recover) -and ($round -eq 1)) {
      $want = Get-BwSpotlightWant
      if ($recover) { Log ('聚焦库是空的, 自动补救 (不等用户手动), 先下 1 张立刻换, 其余后台补') }
      else { Log ('队列已空 (库中现有 ' + $libCount + ' 张), 先下 1 张立刻换, 其余后台补') }
      $one = @()
      if (-not $global:BWDry) { $one = @(Invoke-SpotlightFetch -count 1 -Quiet) }
      if ($one.Count -gt 0) {
        $newName = Split-Path $one[0] -Leaf
        $newKey = Get-BwNameKey $newName
        # 新下的这张直接拿去换, 不再排回队列(不然稍后会重复看到它);
        # 其余的照常洗牌排成新队列
        $s.queue = @(Get-BwFreshQueue $s | Where-Object { (Get-BwNameKey $_) -ne $newKey })
        # 恢复模式下前台这一张让库"不空"了, 后台必须穿透 auto_fetch 开关才肯继续补
        if ($recover) { Start-BwBackfill ($want - 1) -Force }
        else { Start-BwBackfill ($want - 1) }
        return (Get-Item -LiteralPath $one[0])
      }
      # 1 张都没下到 (网络不通/接口的图收干了) -> 不硬等整批, 直接重洗现有库
      Log ('先下的 1 张没下到, 不再硬等, 直接重洗现有库')
    } elseif ($c.auto_fetch -or $recover) {
      Log ('队列又空了: 这一轮已经补过货, 直接重洗现有库')
    } else {
      Log ('队列已空: 按设置不下载新图, 直接把库里现有的 ' + $libCount + ' 张重新洗一遍')
    }
    $s.refills = [int]$s.refills + 1
    $s.queue = @(Get-BwFreshQueue $s)
    if (@($s.queue).Count -eq 0) { return $null }
  }
  return $null
}
# 换一张聚焦壁纸并记账。返回是否成功。
function Invoke-BwSwap($s, [DateTime]$now, [string]$why) {
  $f = Get-BwNextWall $s
  if (-not $f) { Log ($why + ': 取不到聚焦图 (库是空的且下载失败), 稍后重试'); return $false }
  $ok = Set-BwWall $f.FullName
  $s.last_wall = $f.FullName
  $s.shown = [int]$s.shown + 1
  $s.last_swap = $now.ToString('yyyy-MM-dd HH:mm:ss')
  Add-BwHist $s $f.Name
  Log ($why + ' -> ' + $f.Name + ' (ok=' + $ok + '; 队列还剩 ' + @($s.queue | Where-Object { $_ }).Count + ' 张)')
  # 库超上限就顺手淘汰看过的最老的(移进回收站, 能还原)
  [void](Trim-BwLibrary $s)
  # v1.6.5: 队列快空(剩 2 张或更少)就提前后台补一整批 —— 补货在后台跑,
  # 等下次换图时新图已经躺在库里, 前台零等待。
  # 库被清空时不论 auto_fetch 开关都补 (恢复模式)。
  try {
    $left = @($s.queue | Where-Object { $_ }).Count
    $cfg = Get-BwConfig
    $empty = (@(Get-BwSpotlightAll).Count -eq 0)
    if (($left -le 2) -and ($cfg.auto_fetch -or $empty)) {
      if ($empty) { Start-BwBackfill (Get-BwSpotlightWant) -Force }
      else { Start-BwBackfill (Get-BwSpotlightWant) }
    }
  } catch {}
  return $true
}
# 用户在菜单里手动挑一张设为壁纸 —— 也必须走同一套记账。
# 以前手动选图只调 Set-BwDesktopWallpaper, last_wall / history / shown 全都不写,
# 后果是三重的: 主菜单显示的"当前壁纸"停在上次自动换的那张; 按 [F] 收藏,
# 收藏到的是另一张图; 手动选的那张不进"看过"名单, 很快又被洗回来。
function Set-BwWallManual($s, [string]$path, [string]$why) {
  if (-not $path) { return $false }
  if (-not (Test-Path -LiteralPath $path)) { Write-Host '  这张图已经不在库里了'; return $false }
  $ok = Set-BwWall $path
  $s.last_wall = $path
  $s.shown = [int]$s.shown + 1
  $s.last_swap = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  Add-BwHist $s (Split-Path $path -Leaf)
  Log ($why + ' -> ' + (Split-Path $path -Leaf) + ' (ok=' + $ok + ')')
  Save-BwState $s
  return $ok
}
function Get-BwMeta([int]$idx) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  for ($i = 1; $i -le 3; $i++) {
    try { return (Invoke-RestMethod -Uri "https://cn.bing.com/HPImageArchive.aspx?format=js&idx=$idx&n=1&mkt=zh-cn" -TimeoutSec 20 -UseBasicParsing).images[0] }
    catch { Start-Sleep -Seconds 5 }
  }
  return $null
}
function Get-BwDisplayDate($meta) {
  # 官方字段: enddate=这张图展示到哪天 (就是"今天是哪张"), startdate=开始展示的日期。
  # 别用 fullstartdate: 接口给的是 12 位 yyyyMMddHHmm (没有秒), 老代码按 14 位
  # yyyyMMddHHmmss 去 ParseExact, 每次必然抛异常 -> 掉进兜底分支返回"今天"。
  # 结果就是日期永远等于下载当天, 补漏时永远对不上目标日期。
  # 只取前 8 位当 yyyyMMdd, 稳。
  foreach ($cand in @($meta.enddate, $meta.startdate)) {
    $s = [string]$cand
    if ($s.Length -lt 8) { continue }
    $d = $null
    try { $d = [DateTime]::ParseExact($s.Substring(0, 8), 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture) } catch {}
    if ($d) { return $d.ToString('yyyy-MM-dd') }
  }
  return (Get-Date -Format 'yyyy-MM-dd')
}
function Get-BwName($meta) {
  $titlePart = ($meta.copyright -replace '\s*[(（]©.*$','') -replace '[，,]','_'
  $n = ('{0}_{1}_{2}.jpg' -f (Get-BwDisplayDate $meta), $meta.title, $titlePart)
  return ($n -replace '[\\/:*?\"<>| ]','')
}
# 屏幕**物理**像素。
# Screen::PrimaryScreen.Bounds 给的是逻辑像素: 4K 屏开 150% 缩放时它只报 2560x1440,
# 拿去判断"要不要下 4K 图"就会挑成 1080p —— 图存下来是缩水的, 还看不出为什么。
# 乘上系统 DPI 还原成物理像素; 拿不到 DPI(老系统)就按 96(100%) 走, 与旧行为一致。
function Get-BwScreenPhysical {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $dpi = 96
    if (-not ('BwDpi' -as [type])) {
      Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class BwDpi { [DllImport("user32.dll")] public static extern uint GetDpiForSystem(); }'
    }
    try { $d = [int][BwDpi]::GetDpiForSystem(); if ($d -gt 0) { $dpi = $d } } catch {}
    return @([int]($b.Width * $dpi / 96), [int]($b.Height * $dpi / 96))
  } catch { return @(0, 0) }
}
function Get-BwCandidates($meta, $mode) {
  $ub = "https://cn.bing.com$($meta.urlbase)"
  $suf = @()
  if ($mode -eq 'auto') {
    $w = 0; $h = 0
    $ph = @(Get-BwScreenPhysical)
    if ($ph.Count -ge 2) { $w = [int]$ph[0]; $h = [int]$ph[1] }
    if ($w -le 0) {
      # DPI 那条路走不通, 退回逻辑像素, 至少还能挑个大概
      try {
        Add-Type -AssemblyName System.Windows.Forms
        $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $w = $b.Width; $h = $b.Height
      } catch {}
    }
    if ($w -ge 3840) { $suf += '_UHD' }
    elseif ($h -ge 1200) { $suf += '_1920x1200'; $suf += '_UHD' }
    elseif ($w -ge 1920) { $suf += '_1920x1080'; $suf += '_1920x1200'; $suf += '_UHD' }
    else { $suf += '_1366x768'; $suf += '_1920x1080'; $suf += '_UHD' }
  } else { $suf = @('_UHD') }
  $suf += '_1920x1080'
  $urls = @($suf | Select-Object -Unique | ForEach-Object { "$ub$_.jpg" })
  $urls += "$ub.jpg"
  # 不要写 `return ,$urls` —— 那会把整个数组当成一个元素, 调用方一旦写成
  # @(Get-BwCandidates ...) 就只看到 1 个。(文件里另一处注释专门讲过这个坑。)
  return $urls
}
function Get-BwTargetPath([string]$date, [string]$name) {
  $c = Get-BwConfig
  return (Join-Path $c.bing_save_dir $name)
}
# 壁纸填充方式。注册表两个值配合: WallpaperStyle + TileWallpaper。
#   fill 填充 10/0   保持比例铺满, 多出来的裁掉 (v1.3.0 及更早的写死值, 保持默认不动)
#   fit 适应   6/0   保持比例完整显示, 两边留黑边
#   stretch 拉伸 2/0 拉满屏幕, 比例会变形
#   center 居中 0/0  原尺寸居中
#   tile 平铺  0/1   原尺寸铺满
#   span 跨区  22/0  多显示器横跨 (单屏效果同填充)
# 以前这里硬写 10 —— 用户自己在系统设置里选的"适应"会被每次换图覆盖回去。
# 那是用户的设置, 程序不该反复改它; 现在按 config 走, 且只在值不同时才写。
function Get-BwWallStyle {
  $c = Get-BwConfig
  $k = 'fill'
  if ($c.wallpaper_style) { $k = ([string]$c.wallpaper_style).ToLower() }
  switch ($k) {
    'fit'     { return @{ Style = '6';  Tile = '0'; Label = '适应' } }
    'stretch' { return @{ Style = '2';  Tile = '0'; Label = '拉伸' } }
    'center'  { return @{ Style = '0';  Tile = '0'; Label = '居中' } }
    'tile'    { return @{ Style = '0';  Tile = '1'; Label = '平铺' } }
    'span'    { return @{ Style = '22'; Tile = '0'; Label = '跨区' } }
    default   { return @{ Style = '10'; Tile = '0'; Label = '填充' } }
  }
}
function Set-BwDesktopWallpaper([string]$path) {
  if (-not ('WinWall' -as [type])) {
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class WinWall { [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool SystemParametersInfo(uint a, uint p, string v, uint f); }'
  }
  $w = Get-BwWallStyle
  $k = 'HKCU:\Control Panel\Desktop'
  $cur = Get-ItemProperty $k -ErrorAction SilentlyContinue
  if ([string]$cur.WallpaperStyle -ne $w.Style) { Set-ItemProperty $k -Name WallpaperStyle -Value $w.Style }
  if ([string]$cur.TileWallpaper -ne $w.Tile)   { Set-ItemProperty $k -Name TileWallpaper -Value $w.Tile }
  return [WinWall]::SystemParametersInfo(0x0014, 0, $path, 3)
}
# 只改填充方式、不换图时, 得把当前这张再设一次才能立刻看到效果。
# 返回是否成功; 当前壁纸不存在就返回 False。
function Apply-BwWallStyle {
  $cur = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue).Wallpaper
  if (-not $cur) { return $false }
  if (-not (Test-Path -LiteralPath $cur)) { return $false }
  $w = Get-BwWallStyle
  Log ('填充方式改为 ' + $w.Label + ', 重设当前壁纸使其立刻生效')
  return [bool](Set-BwDesktopWallpaper $cur)
}
function Remove-BwFile([string]$path) {
  # 走 .NET 删: 本机 Remove-Item 走回收站, 中文路径下会报 trash 失败
  if ($path -and (Test-Path -LiteralPath $path)) { try { [System.IO.File]::Delete($path) } catch {} }
}
function Save-BwFile([string[]]$urls, [string]$path) {
  # 试运行: 只说一声, 一张都不下。-DryRun 的意思就是"什么都不改",
  # 少了这道闸, 后台补漏 (Invoke-BwBackfill) 在试运行时照样会真去下载。
  if ($global:BWDry) { Log ('试运行: 本应下载 -> ' + (Split-Path $path -Leaf)); return $false }
  # 先落地成 .part, 确认是张能用的图再改名进库。
  # 以前直接写到目标名: 下载到一半被截断 / 拿到的是 HTML 错误页(同样超过 100KB),
  # 半成品会留在图库里, 被计入库容, 甚至被挑去设为壁纸 —— 桌面直接黑掉或花掉。
  $tmp = $path + '.part'
  Remove-BwFile $tmp
  foreach ($u in $urls) {
    try {
      Invoke-WebRequest -Uri $u -OutFile $tmp -TimeoutSec 300 -UseBasicParsing
      if ((Get-Item $tmp -ErrorAction SilentlyContinue).Length -gt 100KB) {
        Add-Type -AssemblyName System.Drawing
        $im = $null; $dim = ''
        try { $im = [System.Drawing.Image]::FromFile($tmp); $dim = "$($im.Width)x$($im.Height)" } catch {}
        finally { if ($im) { $im.Dispose() } }
        # 大小够了但解码失败 = 坏图。以前这种情况带着文件照样返回 True, 脏图就留下了。
        if (-not $dim) {
          Log ('下载的不是能用的图, 已丢弃: ' + (Split-Path $path -Leaf))
          Remove-BwFile $tmp
          continue
        }
        Remove-BwFile $path
        Move-Item -LiteralPath $tmp -Destination $path -Force
        Log "下载成功: $(Split-Path $path -Leaf) ($dim)"
        # 记一笔: 从装上那天起一共下载过多少张(删掉的、清走的都不往回减)。
        # 带上图片编号 —— 流水文件同时是「程序下载清单」, 菜单 [9] 校验图库靠它。
        Add-BwDlCount 1 (Get-BwNameKey (Split-Path $path -Leaf))
        return $true
      }
      Remove-BwFile $tmp
    } catch {
      Log ('下载失败: ' + $_.Exception.Message)
      Remove-BwFile $tmp
    }
  }
  Remove-BwFile $tmp
  return $false
}# ---- 归档源: niumoo/bing-wallpaper (2021-02 至今, 4K UHD, 用户要求批量下载近几年壁纸) ----
function Get-BwRawUrls([string]$rawPath) {
  $p = "https://raw.githubusercontent.com/$rawPath"
  return @("https://ghfast.top/$p", "https://gh-proxy.com/$p", $p)
}
function Get-BwMonthItems([string]$ym) {
  $items = @(); $md = $null
  foreach ($u in (Get-BwRawUrls "niumoo/bing-wallpaper/master/picture/$ym/README.md")) {
    try { $md = (Invoke-WebRequest -Uri $u -TimeoutSec 60 -UseBasicParsing).Content; if ($md) { break } } catch {}
  }
  if (-not $md) { return $null }
  foreach ($m in [regex]::Matches($md, '(\d{4}-\d{2}-\d{2}) \[download 4k\]\((https://cn\.bing\.com/th\?id=[^)]+)\)')) {
    $code = [regex]::Match($m.Groups[2].Value, 'OHR\.([A-Za-z0-9]+)_').Groups[1].Value
    $items += [psobject]@{ date = $m.Groups[1].Value; code = $code; url = $m.Groups[2].Value }
  }
  return $items
}
function Get-BwMonthName($item) { '{0}_{1}.jpg' -f $item.date, $item.code }
function Invoke-BwArchiveBatch([string]$ym) {
  $items = Get-BwMonthItems $ym
  if (-not $items -or $items.Count -eq 0) { Write-Host ('  未取到 ' + $ym + ' 的清单(检查网络)'); return }
  Write-Host ('  共 ' + $items.Count + ' 张, 开始批量下载(跳过已有)...')
  $ok = 0; $skip = 0; $fail = 0
  foreach ($it in $items) {
    $path = Get-BwTargetPath $it.date (Get-BwMonthName $it)
    if (Test-Path $path) { $skip++; continue }
    $dir = Split-Path $path -Parent
    [void](New-BwDir $dir)
    if (Save-BwFile @($it.url) $path) { $ok++ } else { $fail++ }
    Start-Sleep -Milliseconds 400
  }
  Write-Host ('  完成: 成功 ' + $ok + ', 跳过 ' + $skip + ', 失败 ' + $fail)
  Log ("归档批量 $ym : 成功$ok 跳过$skip 失败$fail")
}
function Invoke-BwArchiveSingle([string]$ym, [string]$date, [switch]$SetWall) {
  $items = Get-BwMonthItems $ym
  $it = $items | Where-Object { $_.date -eq $date } | Select-Object -First 1
  if (-not $it) { Write-Host '  该日期不存在于当月清单'; return }
  $path = Get-BwTargetPath $it.date (Get-BwMonthName $it)
  $dir = Split-Path $path -Parent
  [void](New-BwDir $dir)
  if (-not (Test-Path $path)) { if (-not (Save-BwFile @($it.url) $path)) { Write-Host '  下载失败'; return } }
  if ($SetWall) { $ok = Set-BwDesktopWallpaper $path; Write-Host ("  已设为壁纸: ok=$ok") } else { Write-Host ("  已保存: $path") }
}
function Invoke-BwRandom {
  $c = Get-BwConfig
  $all = @(Get-ChildItem -LiteralPath $c.bing_save_dir -File -Filter *.jpg -ErrorAction SilentlyContinue) +
         @(Get-ChildItem -LiteralPath $c.spotlight_save_dir -File -Filter *.jpg -ErrorAction SilentlyContinue)
  if ($all.Count -eq 0) { Write-Host '  两个壁纸库都是空的'; return }
  $f = $all | Get-Random -Count 1
  # 走 Set-BwWallManual 而不是直接设壁纸: 随机这一张也得记账。
  # 直接设的话 last_wall / history 都不写, 主菜单"当前壁纸"停在上一张,
  # 按 [F] 收藏会收藏到别的图, 而且这张很快又被洗回来。
  $s = Get-BwState
  $ok = Set-BwWallManual $s $f.FullName '随便来一张'
  Write-Host ('  已随机设置: ' + $f.Name + ' (ok=' + $ok + ')')
}
# ---- 补漏: 几天没开机, 错过的必应壁纸一张不少 ----
# 原理: 必应库文件名都以日期开头。找出库里最新的日期, 它和昨天之间缺的日子全部补下载。
# 近 7 天的缺口走必应官方接口 (idx=相差天数); 更早的走 niumoo 归档源。
# 只下载不切壁纸; 文件在就跳过, 幂等, 补完之后每次自检秒过。
function Get-BwLatestDate([string]$dir) {
  $latest = $null
  foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Filter *.jpg -ErrorAction SilentlyContinue)) {
    if ($f.Name -match '^(\d{4}-\d{2}-\d{2})') {
      $d = $null
      try { $d = [DateTime]::ParseExact($Matches[1], 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) } catch {}
      if ($d -and (($null -eq $latest) -or ($d -gt $latest))) { $latest = $d }
    }
  }
  return $latest
}
function Get-BwBingAll {
  $c = Get-BwConfig
  return @(Get-ChildItem -LiteralPath $c.bing_save_dir -File -Filter *.jpg -ErrorAction SilentlyContinue)
}
# 补漏的起点 = 「库里最新日期」和「水位线」里更晚的那个。
#
# 为什么需要水位线: 用户把最近几天的必应图删掉或者挪走, 是很正常的操作。
# 只按"库里最新"算的话, 水位会跟着往回退好几天, 于是程序会把用户刚删掉的那些天
# 再下载一遍 —— 删了又自己回来, 等于变相不许人删。
# 水位线只往前不后退, 所以删图不会引起重复下载; 它记的是"这件事已经办到哪天了",
# 不是"现在库里还有多少张"。
function Get-BwHighDate($s, [string]$dir) {
  $latest = Get-BwLatestDate $dir
  $high = $null
  if ($s.bing_high_date) {
    try { $high = [DateTime]::ParseExact([string]$s.bing_high_date, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) } catch { $high = $null }
  }
  if (-not $high) {
    # 水位线还是空的 (从老版本升级上来的): 就地用库里最新日期把它立起来,
    # 这样"删掉最新那几张"从这一刻起也不会引起回退。
    if ($latest) { $s.bing_high_date = $latest.ToString('yyyy-MM-dd') }
    return $latest
  }
  if ((-not $latest) -or ($high -gt $latest)) { return $high }
  return $latest
}
# 水位只往前推。'yyyy-MM-dd' 的字典序等于时间序, 直接比字符串就行。
function Set-BwHighDate($s, [string]$day) {
  if (-not $day) { return }
  $cur = ''
  if ($s.bing_high_date) { $cur = [string]$s.bing_high_date }
  if ($day -gt $cur) { $s.bing_high_date = $day }
}
function Invoke-BwBackfill($s) {
  if (-not $s) { $s = Get-BwState }
  $c = Get-BwConfig
  $today = Get-Date
  $latest = Get-BwHighDate $s $c.bing_save_dir
  if (-not $latest) { return }
  $first = $latest.AddDays(1)
  $yesterday = $today.AddDays(-1)
  $missing = @()
  # 一轮最多补 30 天。以前一口气把整段缺口全列出来: 半年没开机就是 180 张 4K 图,
  # 一次巡检跑十几分钟, 计划任务的时限一到直接被掐断, 水位线还推不动,
  # 于是"每次都从头开始补" —— 永远补不完还每次都卡。分批补, 每轮都能往前推。
  $leftBehind = 0
  for ($d = $first; $d.Date -le $yesterday.Date; $d = $d.AddDays(1)) {
    if ($missing.Count -ge 30) { $leftBehind++; continue }
    $missing += $d.Date
  }
  if ($leftBehind -gt 0) {
    Log ('补漏: 缺口超过 30 天, 这一轮先补最近这批 (' + $missing.Count + ' 天), 更早的 ' + $leftBehind + ' 天往后接着补')
  }
  if ($missing.Count -eq 0) { return }
  $gotThrough = $null
  $monthCache = @{}
  $ok = 0; $skip = 0; $fail = 0
  foreach ($day in $missing) {
    $daysAgo = ($today.Date - $day).Days
    $path = $null; $urls = $null
    if ($daysAgo -le 7) {
      $meta = Get-BwMeta $daysAgo
      $bday = ''
      if ($meta) { $bday = Get-BwDisplayDate $meta }
      if ($bday -ne $day.ToString('yyyy-MM-dd')) { $fail++; continue }
      $path = Get-BwTargetPath $bday (Get-BwName $meta)
      $urls = Get-BwCandidates $meta ($c.resolution_mode)
    } else {
      $ym = $day.ToString('yyyy-MM')
      if (-not $monthCache.ContainsKey($ym)) { $monthCache[$ym] = (Get-BwMonthItems $ym) }
      $it = $null
      $items = $monthCache[$ym]
      if ($items) { $it = @($items | Where-Object { $_.date -eq $day.ToString('yyyy-MM-dd') })[0] }
      if (-not $it) { $fail++; continue }
      $path = Get-BwTargetPath $it.date (Get-BwMonthName $it)
      $urls = @($it.url)
    }
    if (Test-Path -LiteralPath $path) { $skip++; $gotThrough = $day; continue }
    if (Save-BwFile $urls $path) { $ok++; $gotThrough = $day } else { $fail++ }
    Start-Sleep -Milliseconds 400
  }
  if (($ok + $skip + $fail) -gt 0) {
    Log ('补漏 ' + $missing[0].ToString('yyyy-MM-dd') + ' ~ ' + $missing[$missing.Count - 1].ToString('yyyy-MM-dd') + ': 新增 ' + $ok + ' 已有 ' + $skip + ' 失败 ' + $fail)
  }
  # 水位只推到"确实拿到过的那天"。以前不看成败一律推到最后一天,
  # 于是断一次网那几天的图就永久漏了, 而且再也不会补。
  if ($gotThrough) {
    Set-BwHighDate $s $gotThrough.ToString('yyyy-MM-dd')
    Save-BwState $s
  }
}
# ---- Windows 聚焦图源 (微软官方桌面聚焦, 3840x2160, 与 Bing 壁纸同一壁纸团队) ----
function Get-SpotlightOne {
  # 单次请求 -> @{title,url,copyright,slug,id}; 失败返回 $null
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
  $u = 'https://fd.api.iris.microsoft.com/v4/api/selection?placement=88000820&aid=1195280&country=cn&locale=zh-CN&fmt=json'
  try { $j = Invoke-RestMethod -Uri $u -UserAgent $ua -TimeoutSec 20 -UseBasicParsing } catch { return $null }
  $ad = $j.ad
  if (-not $ad) { return $null }
  $img = $ad.landscapeImage.asset
  if (-not $img) { return $null }
  $parts = (($img -split '/')[-1]) -split '_'
  $id = $parts[0]
  $slug = ''
  for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
    if ($parts[$i] -eq 'ds') { $slug = $parts[$i + 1]; break }
  }
  if (-not $slug) { $slug = $id.Substring(0, 8) }
  $title = $ad.title
  if (-not $title) { $title = 'Spotlight' }
  return [psobject]@{ title = $title; url = $img; copyright = $ad.copyright; slug = $slug; id = $id }
}
function Get-SpotlightName($it) {
  $t = ($it.title -replace '[\\/:*?"<>|\s？：＊＜＞｜]', '')
  if ($t.Length -gt 28) { $t = $t.Substring(0, 28) }
  return ('{0}_{1}_{2}.jpg' -f (Get-Date -Format 'yyyy-MM-dd'), $t, $it.slug)
}
function Test-SpotlightDup([string]$dir, $it) {
  if (-not (Test-Path -LiteralPath $dir)) { return $false }
  if ($it.slug) {
    # 必须 -LiteralPath: 库路径里带 [ ] 这类字符时, 默认 -Path 会把它当通配符,
    # 于是"库里明明有这张图"查不出来, 同一张被反复下载。
    $hit = Get-ChildItem -LiteralPath $dir -Filter "*_$($it.slug).jpg" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $true }
  }
  return $false
}
function Invoke-SpotlightFetch([int]$count, [switch]$SetWall, [switch]$Quiet) {
  # 聚焦接口每次请求几乎都返回一张不同的图(实测 40 次 / 39 张唯一), 因此可批量刷。
  # 返回本次新增的文件全名数组, 调用方可以立刻把它们排进轮换队列。
  $c = Get-BwConfig
  $dir = $c.spotlight_save_dir
  [void](New-BwDir $dir)
  $ok = 0; $skip = 0; $fail = 0; $first = $null
  $newFiles = @()
  $tries = 0
  $maxTries = [Math]::Max($count * 5, 20)
  # 循环只看**真的新增了几张**。以前把"已存在"也算进配额, 于是库一大(几十张),
  # 连着抽到的全是库里已有的图, 配额被"已存在"耗尽 -> 一张新图都不下,
  # 客户就一直轮换那批老图, 越用越觉得"怎么老是这几张"。
  # 另: 「看过」名单也拦一道 —— 客户把库里的图备份到网盘(本地删掉)之后,
  # 本地查不到, 光靠文件去重会把同一张图再下一遍。
  $seen = @{}
  foreach ($h in @(Get-BwHist (Get-BwState))) { if ($h) { $seen[[string]$h] = $true } }
  # 试了大半还一张新图都没拿到 -> 说明这个接口的图基本收全了, 放开拦截,
  # 宁可重复下载也不能没图可换。
  $allowSeen = $false
  while (($ok -lt $count) -and ($tries -lt $maxTries)) {
    $tries++
    if (($ok -eq 0) -and ($tries -gt [Math]::Min([Math]::Floor($maxTries / 2), 10))) { $allowSeen = $true }
    $it = Get-SpotlightOne
    if (-not $it) { Start-Sleep -Milliseconds 800; continue }
    if ((-not $allowSeen) -and $it.slug -and $seen.ContainsKey([string]$it.slug)) {
      $skip++
      Start-Sleep -Milliseconds 400
      continue
    }
    if (Test-SpotlightDup $dir $it) {
      $skip++
      if (-not $first) { $first = (Get-ChildItem -LiteralPath $dir -Filter "*_$($it.slug).jpg" -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }
      Start-Sleep -Milliseconds 400
      continue
    }
    $path = Join-Path $dir (Get-SpotlightName $it)
    if (Save-BwFile @($it.url) $path) {
      $ok++
      $newFiles += $path
      if (-not $first) { $first = $path }
      if (-not $Quiet) { Write-Host ('    OK  ' + (Split-Path $path -Leaf)) }
    } else { $fail++ }
    Start-Sleep -Milliseconds 600
  }
  Write-Host ("  完成: 新增 $ok, 已存在 $skip, 失败 $fail")
  Log ("聚焦抓取: 新增$ok 跳过$skip 失败$fail")
  if ($SetWall -and $first) {
    $r = Set-BwDesktopWallpaper $first
    Write-Host ("  已设为壁纸 (ok=$r): " + (Split-Path $first -Leaf))
  }
  return $newFiles
}
# ---- 巡检: 跟随官方更新节奏 (官方出了新图就下载并切换; 没出则秒退, 完全幂等) ----
function Invoke-BwUpdate {
  try {
    $c = Get-BwConfig
    $meta = $null
    for ($i = 1; $i -le 4; $i++) {
      $meta = Get-BwMeta 0
      if ($meta) { break }
      Log ("巡检: 网络未就绪, 第${i}次等待..."); Start-Sleep -Seconds 10
    }
    if (-not $meta) { Log '巡检: 元数据失败, 退出'; return }
    $name = Get-BwName $meta
    $path = Get-BwTargetPath (Get-BwDisplayDate $meta) $name
    $dir = Split-Path $path -Parent
    [void](New-BwDir $dir)
    if (-not (Test-Path $path)) {
      if (-not (Save-BwFile (Get-BwCandidates $meta ($c.resolution_mode)) $path)) { Log '巡检: 下载失败, 下次再试'; return }
      Log ('巡检: 官方已更新 -> ' + $name)
    }
    $cur = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue).Wallpaper
    if ($cur -ne $path) {
      $ok = Set-BwDesktopWallpaper $path
      Log ('巡检: 切换壁纸 ok=' + $ok + ' -> ' + $name)
    } else {
      Log ('巡检: ' + $name + ' 已经是当前壁纸, 不用重设')
    }
    # 手动切必应也要记账。以前这一步只换壁纸不写 state, 于是 15 分钟后
    # 后台巡检看到 last_bing_date 还是昨天, 又插一张必应进来 ——
    # 用户刚挑的聚焦图被顶掉, 还以为程序没听他的。
    $s = Get-BwState
    if ($s) {
      $s.last_wall = $path
      $s.last_bing_date = (Get-Date).ToString('yyyy-MM-dd')
      $s.last_swap = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
      Add-BwHist $s $name
      Save-BwStateKeepFav $s
    }
  } catch { Log ('巡检异常: ' + $_.Exception.Message) }
}

# ==================== 自动轮换 ====================
# 三条规则 + 一个补漏, 装完不用管:
#   0) 补漏: 几天没开机, 错过的必应壁纸全部补下载 (只下载, 不切壁纸)
#   1) 每天第一次进入桌面 -> 换【必应当前官方图】, 顺手确认它在库里
#   2) 每次重启电脑       -> 立刻换一张【聚焦】(不重复)
#   3) 每 30 分钟         -> 换一张【聚焦】(不重复)
# 聚焦的"不重复"靠 queue: 库里所有图洗一次牌按顺序发, 发完自动再下载 6 张重洗一轮。
# 必应只在"每天第一次"出现, 所以手动换的壁纸不会被必应抢回去。
function Invoke-BwCycle {
  try {
    $c = Get-BwConfig
    $null = Ensure-BwDirs
    # 每次巡检顺带认一遍: 库里哪些图不是本程序下载的。只打记号, 不动文件。
    [void](Update-BwStrangers)
    $s = Get-BwState
    $now = Get-Date
    $today = $now.ToString('yyyy-MM-dd')
    $gap = 30
    if ($c.cycle_minutes) { $gap = [int]$c.cycle_minutes }

    $boot = ''
    try { $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss') } catch {}
    $rebooted = [bool]($boot -and $s.last_boot -and ($s.last_boot -ne $boot))
    if ($boot) { $s.last_boot = $boot }
    $last = Get-BwTime $s.last_swap
    $due = $true
    if ($last) { $due = ((($now - $last).TotalMinutes) -ge $gap) }

    # ---- 补漏: 错过日子的必应壁纸 (只下载, 不切壁纸) ----
    Invoke-BwBackfill $s

    # ---- 规则 1: 每天第一次 -> 必应当日壁纸 ----
    # 拿不到元数据就不记账, 让下面的规则照常走, 15 分钟后自然再试一次 ——
    # 不会把整条节奏卡死在这一步, 也不会漏下载。
    if ($s.last_bing_date -ne $today) {
      $meta = $null
      for ($i = 1; $i -le 4; $i++) {
        $meta = Get-BwMeta 0
        if ($meta) { break }
        Log ("必应: 网络未就绪, 第${i}次等待..."); Start-Sleep -Seconds 10
      }
      $bday = ''
      if ($meta) { $bday = Get-BwDisplayDate $meta }
      # 不再要求"接口日期 == 今天": 必应下午 16:00 才发新图, 卡这个闸门会整天不切也不下载。
      # 现在只要拿到"官方当前这张"就入库并切换, 一张不漏。
      if ($meta) {
        $name = Get-BwName $meta
        $path = Get-BwTargetPath $bday $name
        $dir = Split-Path $path -Parent
        [void](New-BwDir $dir)
        if ($global:BWDry) {
          Log ('试运行: 本应换必应当日壁纸 -> ' + $name + ' (库中已存在=' + (Test-Path -LiteralPath $path) + ')')
        } else {
          if (-not (Test-Path -LiteralPath $path)) {
            if (-not (Save-BwFile (Get-BwCandidates $meta ($c.resolution_mode)) $path)) { $path = $null }
          }
          if (-not $path) {
            # 这里必须直接 return 且不记账。以前下载失败也照样把 last_bing_date 写成今天,
            # 而 15 分钟后要不要重试恰恰是看这个字段 —— 当天就再也不会重试了,
            # 上面那句"15 分钟后再试"的日志其实是假的。
            Log '必应当日壁纸下载失败, 15 分钟后再试'
            Save-BwState $s
            return
          }
          $ok = Set-BwWall $path
          $s.last_wall = $path
          Log ('今日首次 -> 必应当日壁纸 ' + $name + ' (ok=' + $ok + ')')
        }
        $s.last_bing_date = $today
        # 用"此刻"而不是进入本轮的时刻: 下载当天必应图可能花几分钟,
        # 时间戳要是记成开始时间, 下一次轮换就会提前触发。
        $s.last_swap = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Save-BwStateKeepFav $s
        return
      }
      Log '必应元数据取不到, 15 分钟后再试'
      # 故意不 return: 继续往下走, 免得整条节奏卡在这里
    }

    # ---- 规则 2: 重启电脑 -> 立刻换一张聚焦 ----
    # 写回一律走 KeepFav: 换图要花几分钟(下载/补货), 这期间用户很可能正在菜单里
    # 收藏、挑图。整份覆盖会把人家刚做的事无声吞掉 —— 规则 1 早就这么写了,
    # 这两条却还在用 Save-BwState, 属于漏改。
    if ($rebooted) {
      Invoke-BwSwap $s (Get-Date) '重启电脑进入桌面' | Out-Null
      Save-BwStateKeepFav $s
      return
    }

    # ---- 规则 3: 半小时到点 -> 换一张聚焦 ----
    if ($due) {
      Invoke-BwSwap $s (Get-Date) '半小时到点' | Out-Null
      Save-BwStateKeepFav $s
      return
    }

    # 未到点: 静默, 只把开机时间存下来
    Save-BwStateKeepFav $s
  } catch { Log ('轮换异常: ' + $_.Exception.Message) }
}
# 注意: -Update 与 -Cycle 走同一套逻辑。
# 老版本的开机自启动作是 -Update; 让 -Update 也进新节奏, 老用户不用重装就能零提权生效。
if ($Cycle -or $Update) { Invoke-BwCycle }
