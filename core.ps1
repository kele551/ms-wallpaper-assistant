# 微软壁纸助手 - 核心库 (by 海风 & Cindy)
param([switch]$Update, [switch]$Cycle, [switch]$DryRun)
$global:BWRoot = $PSScriptRoot
$global:CfgPath = Join-Path $global:BWRoot 'config.json'
$global:BWLog = Join-Path $global:BWRoot 'wallpaper.log'
$global:BWState = Join-Path $global:BWRoot 'state.json'
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
# ---- 壁纸默认放「图片」文件夹里的「壁纸」----
# 用户的安排: 壁纸就该归在图片库里, 不要再往盘根丢一个 X:\微软壁纸助手。
# 但有个现实问题: 图片文件夹默认就在系统盘 (C:\Users\xxx\Pictures),
#   壁纸每天都攒, 几年下来好几个 GB, 会把系统盘撑满。所以:
#     * 图片文件夹在系统盘以外 -> 直接用 <图片>\壁纸 (尊重用户自己的安排)
#     * 图片文件夹在系统盘     -> 挑一个非系统盘, 用 <盘>\图片\壁纸
#     * 这台机器只有系统盘     -> 只能用 <图片>\壁纸, 并在向导里说清楚
# 挑盘的规则沿用 Get-BwPickRoot (非系统盘优先、可写优先、可用空间降序)。
function Get-BwDefaultBase {
  if ($global:BWDefaultBase) { return $global:BWDefaultBase }
  $pic = Get-BwPicturesDir
  $sys = ''
  try { $sys = (([string]$env:SystemDrive).TrimEnd('\')).ToUpper() } catch {}
  $drv = ''
  if ($pic -match '^([A-Za-z]):') { $drv = $Matches[1].ToUpper() }
  if ($drv -and ($drv -ne $sys)) {
    $global:BWDefaultBase = (Join-Path $pic '壁纸')
    $global:BWBaseReason  = '你的「图片」文件夹本来就在系统盘以外'
  } else {
    $root = ''
    try { $root = ([string](Get-BwPickRoot)).TrimEnd('\') } catch {}
    $rd = ''
    if ($root -match '^([A-Za-z]):') { $rd = $Matches[1].ToUpper() }
    if ($rd -and ($rd -ne $sys)) {
      $global:BWDefaultBase = (Join-Path $root '图片\壁纸')
      $global:BWBaseReason  = '「图片」文件夹在系统盘上, 已经挪到系统盘以外, 免得壁纸越攒越多把系统盘撑满'
    } else {
      $global:BWDefaultBase = (Join-Path $pic '壁纸')
      $global:BWBaseReason  = '这台机器只有系统盘能用'
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
  }
  # bing_high_date : 必应补漏的水位线, 只往前不后退 (详见 Get-BwHighDate)
  # favorites      : 收藏的图片文件名, 只记名字 (和 queue 一个口径); 图被删掉也
  #                  留着, 取用时自然剔除, 不必提前清理 —— 万一手滑删了还能加回来。
  # history        : **看过**的图的唯一标识(不是文件名, 见 Get-BwNameKey)。
  #                  有了它, 队列洗牌时才能把看过的挑出去 —— 不然每洗一轮,
  #                  昨天看过的 18 张又排回来, 客户看到的就是"这张我昨天不是刚看过吗"。
  $def = [ordered]@{
    schema = 6; last_bing_date = ''; last_swap = ''; last_boot = ''
    queue = @(); refills = 0; shown = 0; last_wall = ''
    bing_high_date = ''; favorites = @(); history = @()
  }
  foreach ($k in $def.Keys) {
    $p = $s.PSObject.Properties[$k]
    if ((-not $p) -or ($null -eq $p.Value)) { Add-Member -InputObject $s NoteProperty $k $def[$k] -Force }
  }
  # schema 要**强制**写成当前版本: 上面那个循环只在"字段缺失或为空"时才补,
  # 而 schema 永远是 3 (有值), 于是升完级还是 3, 每次进来都要再"升级"一遍。
  Add-Member -InputObject $s NoteProperty schema 6 -Force
  return $s
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
  [System.IO.File]::WriteAllText($global:BWState, ($s | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
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
    $want = Get-BwSpotlightWant
    Log ('队列已空 (库中现有 ' + @(Get-BwSpotlightAll).Count + ' 张), 刷新下载 ' + $want + ' 张后重洗')
    if ($global:BWDry) { Log ('试运行: 本应刷新下载 ' + $want + ' 张聚焦壁纸') }
    else { Invoke-SpotlightFetch -count $want -Quiet | Out-Null }
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
  return $true
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
  return ,$urls
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
function Save-BwFile([string[]]$urls, [string]$path) {
  foreach ($u in $urls) {
    try {
      Invoke-WebRequest -Uri $u -OutFile $path -TimeoutSec 300 -UseBasicParsing
      if ((Get-Item $path -ErrorAction SilentlyContinue).Length -gt 100KB) {
        Add-Type -AssemblyName System.Drawing
        $im = [System.Drawing.Image]::FromFile($path); $dim = "$($im.Width)x$($im.Height)"; $im.Dispose()
        Log "下载成功: $(Split-Path $path -Leaf) ($dim)"
        return $true
      }
      # 走 .NET 删: 本机 Remove-Item 走回收站, 中文路径下会报 trash 失败
      if (Test-Path -LiteralPath $path) { try { [System.IO.File]::Delete($path) } catch {} }
    } catch { Log ('下载失败: ' + $_.Exception.Message) }
  }
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
  $ok = Set-BwDesktopWallpaper $f.FullName
  Write-Host ("  已随机设置: $($f.Name) (ok=$ok)")
  Log "随机回忆: $($f.FullName)"
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
  for ($d = $first; $d.Date -le $yesterday.Date; $d = $d.AddDays(1)) { $missing += $d.Date }
  if ($missing.Count -eq 0) { return }
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
    if (Test-Path -LiteralPath $path) { $skip++; continue }
    if (Save-BwFile $urls $path) { $ok++ } else { $fail++ }
    Start-Sleep -Milliseconds 400
  }
  if (($ok + $skip + $fail) -gt 0) {
    Log ('补漏 ' + $missing[0].ToString('yyyy-MM-dd') + ' ~ ' + $missing[$missing.Count - 1].ToString('yyyy-MM-dd') + ': 新增 ' + $ok + ' 已有 ' + $skip + ' 失败 ' + $fail)
  }
  # 补到哪天, 水位就记到哪天 —— 之后用户把这几张删了也不会再补一次
  Set-BwHighDate $s $missing[$missing.Count - 1].ToString('yyyy-MM-dd')
  Save-BwState $s
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
  if (-not (Test-Path $dir)) { return $false }
  if ($it.slug) {
    $hit = Get-ChildItem $dir -Filter "*_$($it.slug).jpg" -ErrorAction SilentlyContinue | Select-Object -First 1
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
      if (-not $first) { $first = (Get-ChildItem $dir -Filter "*_$($it.slug).jpg" -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }
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
# 浏览任意一个库, 选一张设为壁纸 (必应库 / 聚焦库共用)
function Show-Browse([string]$dir, [string]$title) {
  $files = @(Get-ChildItem -LiteralPath $dir -File -Filter *.jpg -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 40)
  if ($files.Count -eq 0) { Write-Host ('  ' + $title + '还是空的'); return }
  Write-Host ('  —— ' + $title + ' (最近 40 张) ——')
  $i = 0
  foreach ($f in $files) { Write-Host ("  [$i] $($f.Name)"); $i++ }
  $sel = Read-Host '  输入序号设为壁纸 (回车返回)'
  if ($sel -eq '') { return }
  try {
    $p = $files[[int]$sel].FullName
    $ok = Set-BwDesktopWallpaper $p
    Write-Host ("  已设为壁纸 (ok=$ok): " + (Split-Path $p -Leaf))
    Log ('手动浏览设壁纸: ' + $p)
  } catch { Write-Host '  序号无效' }
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
    if ($cur -eq $path) { return }
    $ok = Set-BwDesktopWallpaper $path
    Log ('巡检: 切换壁纸 ok=' + $ok + ' -> ' + $name)
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
          if ($path) {
            $ok = Set-BwWall $path
            $s.last_wall = $path
            Log ('今日首次 -> 必应当日壁纸 ' + $name + ' (ok=' + $ok + ')')
          } else { Log '必应当日壁纸下载失败, 15 分钟后再试' }
        }
        $s.last_bing_date = $today
        # 用"此刻"而不是进入本轮的时刻: 下载当天必应图可能花几分钟,
        # 时间戳要是记成开始时间, 下一次轮换就会提前触发。
        $s.last_swap = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Save-BwState $s
        return
      }
      Log '必应元数据取不到, 15 分钟后再试'
      # 故意不 return: 继续往下走, 免得整条节奏卡在这里
    }

    # ---- 规则 2: 重启电脑 -> 立刻换一张聚焦 ----
    if ($rebooted) {
      Invoke-BwSwap $s (Get-Date) '重启电脑进入桌面' | Out-Null
      Save-BwState $s
      return
    }

    # ---- 规则 3: 半小时到点 -> 换一张聚焦 ----
    if ($due) {
      Invoke-BwSwap $s (Get-Date) '半小时到点' | Out-Null
      Save-BwState $s
      return
    }

    # 未到点: 静默, 只把开机时间存下来
    Save-BwState $s
  } catch { Log ('轮换异常: ' + $_.Exception.Message) }
}
# 注意: -Update 与 -Cycle 走同一套逻辑。
# 老版本的开机自启动作是 -Update; 让 -Update 也进新节奏, 老用户不用重装就能零提权生效。
if ($Cycle -or $Update) { Invoke-BwCycle }
