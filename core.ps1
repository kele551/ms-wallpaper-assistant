# 桌面壁纸 - 核心库
# 作者: 海风（kele551）   https://github.com/kele551/ms-wallpaper-assistant
# 协作: Cindy（只在源码里留档，不出现在界面上）
param([switch]$Update, [switch]$Cycle, [switch]$DryRun, [string]$PanelReq, [string]$PanelOut, [string]$PanelExport, [string]$PanelJob, [string]$PanelJobArg)
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
# 日志函数：支持 INFO/WARN/ERROR 三级，默认 INFO
# 用法: Log "消息" 或 Log "消息" "WARN" 或 Log "消息" "ERROR"
function Log([string]$m, [string]$level = 'INFO') {
  $prefix = switch ($level.ToUpper()) {
    'WARN' { '[WARN] ' }
    'ERROR' { '[ERR]  ' }
    default { '' }
  }
  Add-Content -Path $global:BWLog -Value ('{0}  {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $prefix, $m) -Encoding UTF8
  $fi = Get-Item $global:BWLog -ErrorAction SilentlyContinue
  if ($fi -and $fi.Length -gt 256KB) { Set-Content -Path $global:BWLog -Value (Get-Content $global:BWLog -Tail 200 -Encoding UTF8) -Encoding UTF8 }
}
# 2026-10-24 (用户要求"读取本机状态别那么慢"): 面板只读接口的短缓存。
# 状态 2s / 图库 2s / 目录索引 8s; 任何写操作立刻失效(见 Invoke-BwPanelAction)。
$global:BwPanelIdxCache = $null
$global:BwPanelIdxAt = [DateTime]::MinValue
$global:BwPanelStateCache = ''
$global:BwPanelStateAt = [DateTime]::MinValue
$global:BwPanelGalleryCache = @{}
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
  # 这是**老装机布局**盘根库目录(<盘>\微软壁纸助手), 老用户的目录还在原位、
  # 探测按老名保留(2026-10-12 产品改名不动这个兼容点; 新版不再往盘根造这个目录)。
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
    # 2026-10-10: -File 的值必须显式加引号。PowerShell 5.1 只是把 ArgumentList 数组
    # 按空格拼成命令行, 不会替你补引号 —— 用户名或 %TEMP% 带空格时路径被截断, 提权那
    # 一侧一行都不执行, 界面直接报"没修成"。menu.ps1:65 早就是 ('"{0}"' -f ...) 的正确
    # 写法, 这里和下面 1078 行的升级小助手都漏了。
    $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
         -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $tmp))
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
function Test-BwDriveRoot([string]$p) {
  if (-not $p) { return $false }
  return ($p.TrimEnd('\') -match '^[A-Za-z]:$')
}
# ---- 「这个地方该不该放」 ----
# 用户 2026-09-22 的要求（他表弟机器上的真实事故）：程序得自己判断
# 「哪些地方可以放，哪些地方不能乱放」，不能把图库安顿进别人的资料/工作目录。
# 事故经过：表弟的「图片」文件夹在 C 盘，程序就去别的盘找现成图片文件夹，
# E 盘上 `V9筑龙资料云南版\图片` 里正好有一张 jpg，程序就把库建成了
# `E:\V9筑龙资料云南版\图片\壁纸` —— 住进了他的**资料目录**里，还建了「必应」。
#
# 判据刻意只看结构、不看盘符（盘符在别人机器上什么情况都有）：
#   1) 沿着 base 往上追，任何一层目录名带「资料/教程/课程/素材/项目/工程/源码/备份」
#      这类词 -> 那是别人的工作目录，不放；
#   2) base 的上上层（也就是「图片」文件夹所在的那一层，盘根除外）里混着
#      非图片文件（文档/表格/PDF/安装包/程序文件）-> 那是资料区，不放。
# 返回空串 = 没意见；返回一段人话 = 不许放，理由要显示给用户看。
# 注意：只约束**程序自动挑位置**这一步；用户在向导/设置里手动指定一个路径不受限制
# （那是他自己的决定，程序不能替他做主）。
function Test-BwUnsafePlace([string]$base) {
  if (-not $base) { return '' }
  $b = $base.TrimEnd('\')
  $pic = Split-Path $b -Parent                 # 「图片」那一层
  if (-not $pic) { return '' }
  # 1) 名字像资料/工作目录
  $badWords = @('资料', '教程', '课程', '课件', '素材', '项目', '工程', '源码', '代码', '备份', '存档', '培训', '标书', '图纸', '课件')
  $cur = $pic
  $depth = 0
  while ($cur -and ($depth -lt 6)) {
    $nm = ''
    try { $nm = Split-Path $cur -Leaf } catch { $nm = '' }
    if (-not $nm) { break }                    # 到盘根（X:\）了，Leaf 为空 -> 停
    foreach ($w in $badWords) {
      if ($nm.Contains($w)) { return ('「' + $nm + '」看着是资料/工作目录，不是放图的地方') }
    }
    $cur = Split-Path $cur -Parent
    $depth++
  }
  # 2) 「图片」文件夹的上家是普通目录，且里面混着非图片文件
  $gp = Split-Path $pic -Parent
  if ($gp -and -not (Test-BwDriveRoot $gp)) {
    $other = @(Get-ChildItem -LiteralPath $gp -File -ErrorAction SilentlyContinue |
               Where-Object { -not (Test-BwImgFile $_.Name) } | Select-Object -First 1)
    if ($other.Count -gt 0) {
      $gn = ''
      try { $gn = Split-Path $gp -Leaf } catch { $gn = '' }
      return ('「' + $gn + '」里混着文档/安装包这类文件，不是专门放图的地方')
    }
  }
  return ''
}
# ---- 把已有的图库搬到新位置（2026-09-22 加） ----
# 用途：图库被放在不该放的地方（例如别人的资料目录里），用户按 [S] -> [3] 换位置后，
# 已经下载的图不用重下 —— 把 <旧>\必应 和 <旧>\聚焦 里的图搬过去。
# 安全底线（必须在，因为这是往用户的目录里动文件）：
#   * 只搬图片文件（Test-BwImgFile 认的那几种），别的文件一个字都不动；
#   * 目标已存在同名文件 -> 跳过，绝不覆盖；
#   * 源目录清空了才删它，而且用**非递归**删除 —— 里面有别的东西时它会失败，
#     正好当保险丝：删不掉就说明还留着用户的文件，那就留着；
#   * 上面两层都空了，才把程序自己建的「壁纸」那层删掉（同样只删空的）。
# 返回搬过去的图片张数。
function Move-BwLibraryFiles([string]$fromBase, [string]$toBase) {
  if (-not ($fromBase -and $toBase)) { return 0 }
  $fb = $fromBase.TrimEnd('\'); $tb = $toBase.TrimEnd('\')
  if ($fb.ToUpper() -eq $tb.ToUpper()) { return 0 }
  if (-not (Test-Path -LiteralPath $fb)) { return 0 }
  $moved = 0
  # 只搬本程序自己的库目录(「必应」「聚焦」两类); 库目录之外的文件夹一个字都不碰。
  foreach ($nm in @('必应', '聚焦')) {
    $src = Join-Path $fb $nm
    $dst = Join-Path $tb $nm
    if (-not (Test-Path -LiteralPath $src)) { continue }
    if (-not (New-BwDir $dst)) { continue }
    $pic = @(Get-ChildItem -LiteralPath $src -File -ErrorAction SilentlyContinue | Where-Object { Test-BwImgFile $_.Name })
    foreach ($f in $pic) {
      $to = Join-Path $dst $f.Name
      if (Test-Path -LiteralPath $to) { continue }
      try { [System.IO.File]::Move($f.FullName, $to); $moved++ } catch {}
    }
    $left = @(Get-ChildItem -LiteralPath $src -Force -ErrorAction SilentlyContinue)
    if ($left.Count -eq 0) { try { [System.IO.Directory]::Delete($src, $false) } catch {} }
  }
  $still = 0
  foreach ($nm in @('必应', '聚焦')) { if (Test-Path -LiteralPath (Join-Path $fb $nm)) { $still++ } }
  if ($still -eq 0) { try { [System.IO.Directory]::Delete($fb, $false) } catch {} }
  return $moved
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
        # 深度 2: 盘根下面一层里再找一遍。
        # 2026-09-22 修: 以前这里是"只要 <盘>\<某目录>\图片 里有一张 jpg"就认定它是
        # 本机的图片文件夹（打 45 分）。结果在用户表弟的机器上，E 盘那个
        # 「V9筑龙资料云南版\图片」正好有一张图，程序就把图库安顿进了他的**资料目录**，
        # 还在里面建了「壁纸\必应」。用户的原话：应该自动判断哪些地方可以放、
        # 哪些地方不能乱放 —— 只凭"有一张图"就下判断太草率，别人的资料盘里
        # 本来就可能存着几张图。
        # 现在只有**已经存在本程序自己的库结构**（壁纸\必应 或 \聚焦 里有图）才复用，
        # 那说明这台机器以前确实把它当库用；光有几张散图一律不再采纳。
        # 另外再加一道 Test-BwUnsafePlace：就算是老库，落在资料/工作目录里也不再回收。
        $subs = @(Get-ChildItem -LiteralPath ($root + '\') -Directory -ErrorAction SilentlyContinue | Select-Object -First 40)
        foreach ($sd in $subs) {
          foreach ($nm in $picNames) {
            $p2 = Join-Path $sd.FullName $nm
            if (-not (Test-Path -LiteralPath $p2)) { continue }
            $sub2 = Join-Path $p2 '壁纸'
            $hasLib2 = ((Test-BwHasJpg $sub2) -or (Test-BwHasJpg (Join-Path $sub2 '必应')) -or (Test-BwHasJpg (Join-Path $sub2 '聚焦')))
            if (-not $hasLib2) { continue }                         # 不是我们自己的库 -> 不碰
            if (Test-BwUnsafePlace $sub2) { continue }               # 落在资料目录里 -> 不用
            $why2 = $drv + ': 上的「' + $sd.Name + '\' + $nm + '」, 里面还留着以前下载的壁纸'
            if (95 -gt $bestScore) { $bestScore = 95; $best = $sub2; $bestWhy = $why2 }
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
  # 其它图源(将来的图源)的库目录: 只建"开着"的那些 ——
  # 关掉的源不该在用户盘上留一个永远空的文件夹。
  foreach ($def in @(Get-BwSourceDefs)) {
    if (-not (Get-BwSrcEnabled $c $def.Key)) { continue }
    $d = Get-BwSrcDir $c $def.Key
    if ($d) { [void](New-BwDir $d) }
  }
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
  # 2026-10-24(冷启动速度): 算"默认保存位置"要扫盘找「图片」文件夹(实测约 200 ms),
  # 而已经装过的用户 config.json 里两个目录都写着 —— 这条路径根本用不到默认值。
  # 改成**真缺字段时才去算**, 面板/后台每次启动都少等这 200 ms。老配置的兜底行为一个字都没变。
  $d = $null
  if (-not $c) {
    $freshCfg = $true   # 2026-10-12: 标记"config.json 原本不存在"(给下面 bing_cap 定默认用)
    $d = Get-BwDefaults
    $c = New-Object PSObject
    Add-Member -InputObject $c NoteProperty bing_save_dir $d.bing -Force
    Add-Member -InputObject $c NoteProperty spotlight_save_dir $d.spotlight -Force
    # 2026-10-10 晚: 默认从 uhd 改成 auto —— 按屏幕物理分辨率挑档。
    # 理由(用户提出): 1080p 屏的用户原来也在下 4K 图(3-6 MB/张), 纯占硬盘;
    # auto 档在 1080p 屏只下 1920x1080(约 1-2 MB/张), 画质在自己屏上看不出差别。
    Add-Member -InputObject $c NoteProperty resolution_mode 'auto' -Force
  }
  if (-not $c.bing_save_dir) {
    if (-not $d) { $d = Get-BwDefaults }
    Add-Member -InputObject $c NoteProperty bing_save_dir $d.bing -Force
  }
  if (-not $c.spotlight_save_dir) {
    # 默认放必应库旁边; 必应库要是在盘根, 就退回 "<盘>\聚焦"
    $par = Split-Path $c.bing_save_dir -Parent
    if ($par) { Add-Member -InputObject $c NoteProperty spotlight_save_dir (Join-Path $par '聚焦') -Force }
    else {
      if (-not $d) { $d = Get-BwDefaults }
      Add-Member -InputObject $c NoteProperty spotlight_save_dir $d.spotlight -Force
    }
  }
  # 2026-10-10 晚: 默认 'auto' —— 按屏幕挑档、省硬盘(见上面那段说明)。
  # 已经有 config.json 的用户不受影响: 他文件里写着 uhd 就还是 uhd, 只补缺失的字段。
  if (-not $c.resolution_mode) { Add-Member -InputObject $c NoteProperty resolution_mode 'auto' -Force }
  if (-not $c.spotlight_per_cycle) { Add-Member -InputObject $c NoteProperty spotlight_per_cycle 6 -Force }
  if (-not $c.cycle_minutes) { Add-Member -InputObject $c NoteProperty cycle_minutes 30 -Force }
  # 壁纸填充方式。默认 fill(填充) —— 与 v1.3.0 及更早的行为一致, 老用户升级后桌面不会变样。
  if (-not $c.wallpaper_style) { Add-Member -InputObject $c NoteProperty wallpaper_style 'fill' -Force }
  # 只在收藏里轮换。默认关。
  if (-not $c.fav_only) { Add-Member -InputObject $c NoteProperty fav_only $false -Force }
  # 必应模式: 只换必应(每天一张), 不轮换聚焦。默认关。
  # 2026-10-20 用户要求(与 GitHub #1 用户爱卡生同一诉求): 只想每天看必应当日图。
  if (-not $c.PSObject.Properties['bing_only']) { Add-Member -InputObject $c NoteProperty bing_only $false -Force }
  if (-not $c.PSObject.Properties['desktop_shortcut']) { Add-Member -InputObject $c NoteProperty desktop_shortcut 'on' -Force }
  # 图库上限: 聚焦库最多留多少张。超了就把**已经看过**的最老的几张移进回收站。
  # 没看过的一律不动 —— 那是等着换的, 删了就得重新下载。
  # 0 = 不限(老样子, 只增不减)。
  # 2026-10-09 用户要求: 默认从 100 上调到 200。理由 —— 聚焦源池总共就 800+ 张、官方每天
  # 只新增有限几张, 库越大、同样的图轮到第二次的间隔就越长(库 200 张 + 30 分钟一轮 ≈ 4 天才
  # 轮一遍)。**只改新装的默认值**: 已经有 config.json 的用户保持他自己那份, 不覆盖。
  if (-not $c.PSObject.Properties['lib_cap']) { Add-Member -InputObject $c NoteProperty lib_cap 200 -Force }
  # 必应库上限(2026-10-10 晚·用户提出「怕别的用户硬盘小」): 必应库原来**没有上限**,
  # 一天一张、4K 档一年就是约 1.4 GB, 几年攒成几个 GB 也没人管。
  # 默认跟图库上限一样 200 张; 超了同样把「已经看过的、最老的」移进回收站(能还原)。
  # 0 = 不限。想让它长期攒图就调大(菜单 [S] → [b])。
  # 2026-10-12 (审查 P1·用户拍板 A 案): **老用户**缺这个字段时补 0(不限) ——
  # 原来一律补 200, 等于攒了几年必应存档的人在下一次换图时被**静默批量移进回收站**,
  # 太惊吓。只有全新 config(这台机器第一次装)才默认 200; 老用户想省硬盘随时菜单 [S]→[b] 调小。
  if (-not $c.PSObject.Properties['bing_cap']) { Add-Member -InputObject $c NoteProperty bing_cap $(if ($freshCfg) { 200 } else { 0 }) -Force }
  # ---- 聚焦源池的三道闸 (2026-10-09 用户要求: 别把 800+ 张的源池一次抽干) ----
  # fetch_round_cap : 单轮最多抓几张(硬上限; 想一次抓更多也不给, 源池要慢慢放)
  # fetch_day_cap   : 每天最多抓几张(跨菜单/后台/向导统一算, 换天归零)
  # recycle_min_days: 老图回收的最小间隔(同一张图至少这么多天不再出现)
  if (-not $c.PSObject.Properties['fetch_round_cap'])  { Add-Member -InputObject $c NoteProperty fetch_round_cap 6 -Force }
  if (-not $c.PSObject.Properties['fetch_day_cap'])    { Add-Member -InputObject $c NoteProperty fetch_day_cap 20 -Force }
  if (-not $c.PSObject.Properties['recycle_min_days']) { Add-Member -InputObject $c NoteProperty recycle_min_days 30 -Force }
  # 2026-10-09: 两个试过的图源因"出的图不适合当壁纸"已按用户决定摘除, 上面这些配置键
  # (各自的开关 / 关键词 / 库容上限 / 画质线 / 只收横图)不再补默认值。
  # 用户机器上那份 config.json 里的旧字段**一个字节都不动** —— 读不到就不生效。
  # ---- 不放大显示 (2026-10-09 用户要求: "体验感不能减") ----
  # 两道线, 一个源的画质口径就是这两句话:
  #   *_min_width  : **能进候选的最低线** —— 比它窄的图直接跳过(太小的画放中间也不好看);
  #   *_full_width : **能满屏铺满的线** —— 到了这条线才走老的 fill(裁剪铺满, 最锐);
  #                  卡在两条线中间的走"不放大": 原图 1:1 居中 + 四周同一张图放大模糊作底。
  # 每张图的两道宽度线由各图源自己给(见 Get-BwSrcWidthCfg): 比最低线窄的不收,
  # 到了满屏线才裁剪铺满, 卡在中间的走"不放大"。0 = 不限(那一道门槛不生效)。
  # 不放大显示(默认开): 不到满屏线的图**绝不拉大** —— 糊的唯一来源就是拉大。
  # 关掉它就退回老样子(一律 fill, 小图会被放大), 留给"我就爱铺满"的用户。
  # 2026-10-23 用户要求: 桌面壁纸就是要满屏 —— 默认改成 'off'(拉大铺满)。
# 原来默认 'on' = 比屏幕小的图 1:1 居中 + 四周同图模糊; 1920 宽的图放到 2560 屏上
# 看着像"没铺满"。想要旧观感的人可以在控制台把「小图不放大」打开。
if (-not $c.PSObject.Properties['art_fit_mode']) { Add-Member -InputObject $c NoteProperty art_fit_mode 'off' -Force }
  # 本地文件夹图源(2026-10-24 UI 整改新增): 一个目录路径。空串 = 不用这个图源。
  # 老配置里没有这个字段 = 空串 = 行为与以前完全一样(不扫目录、不进队列、不删用户文件)。
  if (-not $c.PSObject.Properties['local_src_dir']) { Add-Member -InputObject $c NoteProperty local_src_dir '' -Force }
  # 面板观感(2026-10-25 修「主题/配色换次开机就丢」): 明暗档 + 主色。
  # 原来只存在浏览器 localStorage 里, 而面板端口是每次开机现抢的随机口(实测 10845 -> 38919),
  # 端口一变就是另一个 origin, 存的东西再也读不出来, 用户选过的明暗等于静默丢失。
  # 现在用户点一次就落进 config.json, 出页面时注入回去(见 / 的 HTML 处理分支)。
  # **故意不补默认值**: 字段不存在 = "这人从没在面板上选过观感", 页面就该回落到他自己
  # 浏览器里的旧 localStorage(升级那一刻观感不变); 补个 'auto' 反而会把老用户的选择顶掉。
  # 单张图下载超时(秒)。实测有的图床能慢到 ~130 秒/张: 硬等一张就把整轮补货拖成几十分钟,
  # 后面排队的源全被挡住。20 秒下不完就放弃、记一次失败、换下一张; 同一个源连着两张超时就
  # 本轮不再取它(见 Invoke-BwSrcFetch)。改大/改小都在 [S] 里。
  if (-not $c.PSObject.Properties['src_timeout_sec']) { Add-Member -InputObject $c NoteProperty src_timeout_sec 20 -Force }
  # 队列里的图换完之后, 要不要自动下一批新图? 默认**关**:
  # 库里现有的图轮着用就够了, 不过程序自己跑去下载一堆, 库越攒越大。
  # 想要不断有新图就到菜单里打开它。
  if (-not $c.PSObject.Properties['auto_fetch']) { Add-Member -InputObject $c NoteProperty auto_fetch $false -Force }
  # 数值护栏: 读出来的同时就夹回允许范围 —— 不管是菜单里填的, 还是有人直接
  # 手改 config.json 写进去的。这样"菜单显示的"和"后台真正按的"永远一致,
  # 排错时不用再猜是哪一份数据在骗人。
  foreach ($k in @($global:BwLimit.Keys)) {
    if ($c.PSObject.Properties[$k]) {
      $c.PSObject.Properties[$k].Value = (Limit-BwNum $c.PSObject.Properties[$k].Value $k)
    }
  }
  return $c
}
# ---- 原子写: 状态文件一律"先写临时文件 -> 校验 -> 再原子替换" (2026-10-09 审查 H-7) ----
# 为什么必须这样: state.json / config.json 原来是 [IO.File]::WriteAllText 直接盖原文件。
# 写到一半被强杀(升级小助手的兜底强杀)、断电、磁盘写满, 原文件就只剩半截 JSON ——
# 下次读解析失败, Get-BwState 把版本当 0 直接重置: 收藏夹、队列、看过名单、换图进度
# 一声不吭全没了。改成原子写之后, 最坏情况是"这一次没写进去", 旧文件一个字节都没被动过。
# 返回 $true = 真的换成新的了; $false = 保持原样(原因已写进日志, 旧文件仍在)。
function Save-BwTextAtomic([string]$path, [string]$text) {
  # 2026-10-12 (审查 P1): 临时文件名带上本进程 PID —— 菜单与守护进程并发写同一份
  # state.json 时共用一个 .tmp 会互相覆盖、还互相删(校验不过的一方顺手把对方的 tmp 删了)。
  # 恢复侧(Repair-BwDamagedState)同步改成按 '<名>*.tmp' 找最新的一份。
  $tmp = $path + '.' + $PID + '.tmp'
  try {
    [System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false)))
    # 写完先读回来比一遍再替换: 磁盘满/配额到顶会写出一个 0 字节的"成功"文件,
    # 不校验的话照样会把坏文件替换过去 —— 那就白原子了。
    $back = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8)
    if ($back -ne $text) { throw ('临时文件校验不一致 (写入 ' + $text.Length + ' 字符, 读回 ' + $back.Length + ' 字符)') }
    if (Test-Path -LiteralPath $path) {
      # File.Replace = 同一卷内的原子替换 (原文件的属性与 ACL 也保留)。
      # !! 第三个参数必须写 [NullString]::Value, **不能写 $null**: PowerShell 会把 $null
      # 当空字符串传下去, .NET 直接抛"路径的形式不合法", 于是每一次写都以失败告终、
      # 旧文件被原样保留 —— 表面看"原子写真安全", 实际是"配置/进度根本存不下去"。
      # (2026-10-09 自测抓出来的: config.json 里的 update_url 死活存不进去。)
      [System.IO.File]::Replace($tmp, $path, [NullString]::Value)
    } else {
      [System.IO.File]::Move($tmp, $path)
    }
    # 最后再读回来核一遍: 落盘的字节必须跟我们写的一模一样。
    # 少了这一步, 上面任何一环静默失败都会变成"用户改了设置、程序却当没听见"。
    $again = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    if ($again -ne $text) { throw ('替换后读回的内容不一致 (写入 ' + $text.Length + ' 字符, 读回 ' + $again.Length + ' 字符)') }
    return $true
  } catch {
    Log ('写文件失败, 已保留原文件: ' + (Split-Path $path -Leaf) + ' - ' + $_.Exception.Message) 'WARN'
    try { if (Test-Path -LiteralPath $tmp) { [System.IO.File]::Delete($tmp) } } catch {}
    return $false
  }
}
function Save-BwJsonAtomic([string]$path, $obj) {
  return (Save-BwTextAtomic $path ($obj | ConvertTo-Json -Depth 5))
}

function Save-BwConfig([psobject]$c) {
  # 保存前自动备份 config.json.bak (防止用户手改出错后无法回滚)
  if (Test-Path -LiteralPath $global:CfgPath) {
    try { Copy-Item -LiteralPath $global:CfgPath -Destination ($global:CfgPath + '.bak') -Force -ErrorAction SilentlyContinue } catch {}
  }
  # 2026-10-09 (审查 H-7): 改原子写 —— 配置写坏会让程序悄悄退回默认保存位置,
  # 用户看到的是"壁纸怎么突然换地方存了"。
  [void](Save-BwJsonAtomic $global:CfgPath $c)
}

# ---- 数值护栏 ----
# 菜单里那几个用户可以自己填的数字, 都给一个"人还能理解"的范围。
# 限制不是跟用户过不去, 是防止一次手滑把程序搞瘫:
# 换图间隔填到 41.9 亿分钟以上(约 7978 年), 后台算"下次该几点换"时 AddMinutes
# 会越过 DateTime 的上限(9999-12-31)直接抛异常 —— 守护进程当场摔死,
# 表现就是"壁纸再也不换了"。就算没到那个量级, 填几百万分钟也等于永不换图。
# 实测(2026-09-21): 能加的极限是 4193538076 分钟, 4194000000 就崩, 不是猜的。
# 所以做法是**越界夹回边界**, 不是报错退出、也不是把用户打回去重填。
$global:BwLimit = @{
  # 换图间隔(分钟)。太快看着晃眼、也没人看得清一张图; 超过一天就不叫换壁纸了。
  cycle_minutes       = @{ Min = 5; Max = 1440; Def = 30;  Zero = $false }
  # 一轮补几张聚焦图。太多了会让一轮补图跑很久, 像卡死。
  spotlight_per_cycle = @{ Min = 1; Max = 50;   Def = 6;   Zero = $false }
  # 图库上限(张)。0 = 不限; 上限卡在 2000, 再多就不是壁纸库而是冷备份了。
  # Def 同步成 200(新装默认值), 手改成读不出来的值时也退到这个数。
  lib_cap             = @{ Min = 5; Max = 2000; Def = 200; Zero = $true  }
  # 必应库上限(张)。0 = 不限; 范围与图库上限一致(4K 图一千张就是好几个 GB)。
  bing_cap            = @{ Min = 5; Max = 2000; Def = 200; Zero = $true  }
  # 聚焦源池保护(2026-10-09): 单轮上限 / 单日上限 / 老图回收间隔。都允许用户手改, 但有范围。
  fetch_round_cap     = @{ Min = 1; Max = 50;   Def = 6;   Zero = $false }
  fetch_day_cap       = @{ Min = 1; Max = 200;  Def = 20;  Zero = $false }
  recycle_min_days    = @{ Min = 1; Max = 3650; Def = 30;  Zero = $false }
  # 每个图源自己的库容上限 / 两道画质宽度线(像素), 由各源的静态定义给键名与默认值
  # (见 Get-BwSourceDefs / Get-BwSrcWidthCfg); 这里只留各源共用的一项。
  # 单张下载超时(秒): **0 = 用默认的 20 秒**(不是"不限" —— 不限就等于被一张慢图卡住整轮);
  # 1~4 抬到 5(再快会误杀正常图床); 上限 300 秒(与老版本写死的值一致)。
  src_timeout_sec     = @{ Min = 0; Max = 300; Def = 20; Zero = $true  }
}

# 把一个值按 kind 夹回合法范围。解析不出来的(被人手改成 "abc")退成默认值。
function Limit-BwNum($v, [string]$kind) {
  $r = $global:BwLimit[$kind]
  if (-not $r) { return 0 }
  $n = -1
  try { $n = [int]$v } catch { $n = -1 }
  if ($n -lt 0) { return $r.Def }
  # 只有明确允许 0 的项(目前就"图库上限 = 不限")才能取 0
  if ($r.Zero -and ($n -eq 0)) { return 0 }
  if ($n -lt $r.Min) { return $r.Min }
  if ($n -gt $r.Max) { return $r.Max }
  return $n
}

# 读"每多少分钟换一张"。各处都走这里, 保证菜单显示的数、后台按的数、
# 以及算出来的"下次几点换", 三者永远是同一个 —— 不出现两套口径。
function Get-BwCycleMinutes($c) {
  return (Limit-BwNum $c.cycle_minutes 'cycle_minutes')
}

# 把 config 里那几个数字一次性夹回范围并落盘, 返回改了哪些(没改就是空数组)。
# 菜单进设置时先跑一遍: 允许手改 config.json, 但不允许改出一辆刹不住的车。
#
# 注意: 传进来的 $c 是 Get-BwConfig 的产物, 里面的数字**已经**被夹过了 ——
# 拿它跟自己比永远是"没变", 落盘净化就成了摆设。所以这里要重新读一遍磁盘上的
# 原始值来比对。目标是让文件里写的和程序真正按的保持一致,
# 免得用户打开文件看到 99999999、界面却显示 1440, 不知道该信哪个。
function Repair-BwConfig([psobject]$c) {
  $fix = @()
  $raw = $null
  if (Test-Path $global:CfgPath) {
    try { $raw = Get-Content $global:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $raw = $null }
  }
  foreach ($k in @($global:BwLimit.Keys)) {
    if (-not $c.PSObject.Properties[$k]) { continue }
    $new = Limit-BwNum $c.PSObject.Properties[$k].Value $k
    # 2026-10-09: 用户文件里**根本没有这个字段**时跳过 —— 那种情况是"这一版新加的配置项",
    # Get-BwConfig 已经给它填了默认值, 不需要(也不该)借这次机会去改写用户手里的 config.json。
    # 以前这里会把"字段不存在"当成 -1、判成"超出范围", 于是进一次设置页就顺手改了用户的文件,
    # 还打一句"配置里有数字超出允许范围, 已夹回: 某个新字段 -1 -> 默认值"的假警报。
    if (-not ($raw -and $raw.PSObject.Properties[$k])) { continue }
    $oldN = -1
    try { $oldN = [int]$raw.PSObject.Properties[$k].Value } catch { $oldN = -1 }
    if ($oldN -ne $new) {
      $c.PSObject.Properties[$k].Value = $new
      $fix += ($k + ' ' + $oldN + ' -> ' + $new)
    }
  }
  if ($fix.Count -gt 0) {
    Save-BwConfig $c
    Log ('配置里的数字超出允许范围, 已夹回: ' + ($fix -join '; '))
  }
  return $fix
}
# ---- 自动升级 (2026-09-22, 用户要求) ----
# 这个程序的结构帮了大忙: exe 只是启动器, 真正的逻辑就是 core.ps1 / menu.ps1 两个脚本。
# 所以日常升级**只需要换这两个脚本** —— 不需要管理员权限(数据目录是自己的)、
# 不需要换 exe、不需要重启, 下一轮就生效。只有启动器本身升级时才要用户手动换一次 exe。
#
# 升级源 version.json（放仓库里, 也是发行版附件之一）长这样:
#   {"version":"2.0.6","min_launcher":"2.0.5","notes":"一句话",
#    "scripts":{"core.ps1":{"sha256":"...","url":"..."},"menu.ps1":{"sha256":"...","url":"..."}},
#    "launcher":{"sha256":"...","url":"...","size":7647107}}
# min_launcher = 这套脚本要求的最低启动器版本; 比本机启动器新 -> 只能提示手动换 exe。
# 下载后**必须校验 SHA256**: 对不上就整批放弃, 继续用旧脚本(绝不半个包)。
$global:BWUpdateFile = Join-Path $global:BWRoot 'update.json'
$global:BWUpdateUrls = @(
  # 【2026-10-26 顺序更正】主源换回 GitHub —— 原因是"取到就用、取到就停"：
  # 下面这个循环拿到**第一份能验签的 version.json** 就直接 return(见 1037 行起的 foreach),
  # 不会再看后面的地址。所以排在第一位的那个, 必须是**还在往上推代码的那个仓库**:
  # 现在四款软件只推 GitHub, GitCode 那条线已经不再同步了 —— 它停在过去那一版,
  # 排在前面就等于"永远回答已是最新版", 升级通道被自己堵死(和 2026-10-20 那次
  # "Gitee 停止更新后脚本地址不能再指 Gitee"是同一个坑)。
  # GitCode 仍留作兜底: 哪天恢复同步、或 GitHub 抽风时它还能顶一下。
  # 注意: version.json 里 scripts/launcher 的**下载地址**是写死的绝对地址(由
  # tools/make_version_json.py 生成, 目前指 GitCode 附件), 与本表无关;
  # 真要单平台发布, 那两处必须一起改, 且 GitHub 会削掉中文附件名 —— 见日记 2026-10-26。
  'https://raw.githubusercontent.com/kele551/ms-wallpaper-assistant/main/version.json',
  'https://gitcode.com/api/v5/repos/kele551/ms-wallpaper-assistant/raw/version.json?ref=main'
)
function Get-BwVerTuple([string]$v) {
  $out = @()
  foreach ($x in ([string]$v).Trim().Split('.')) {
    $n = 0
    if ([int]::TryParse($x, [ref]$n)) { $out += $n } else { $out += 0 }
  }
  while ($out.Count -lt 3) { $out += 0 }
  return ,$out
}
function Compare-BwVer([string]$a, [string]$b) {
  $ta = Get-BwVerTuple $a; $tb = Get-BwVerTuple $b
  for ($i = 0; $i -lt 3; $i++) {
    if ($ta[$i] -ne $tb[$i]) { if ($ta[$i] -gt $tb[$i]) { return 1 } else { return -1 } }
  }
  return 0
}
# 启动器版本(启动器每次运行都会写这个文件) —— 用来判断"这版脚本要不要新启动器"
function Get-BwLauncherVer {
  $p = Join-Path $global:BWRoot '.launcher-version'
  if (Test-Path -LiteralPath $p) { try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8).Trim() } catch {} }
  return ''
}
# 数据目录里脚本的版本(= .version)
function Get-BwLocalScriptVer {
  $p = Join-Path $global:BWRoot '.version'
  if (Test-Path -LiteralPath $p) { try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8).Trim() } catch {} }
  return '0.0.0'
}
# 2026-10-16 (升级通道加固·演练隔离): 下载地址只认 https；唯一例外是**回环 http**
# (http://127.0.0.1 / http://localhost)，只给发版前升级演练用(本地起 http 服务当升级源)。
# 回环地址只有本机能连，远程攻击者拿不到也利用不了，生产安全不受影响。
function Test-BwIsLoopbackHttp([string]$url) {
  return ([string]$url) -match '^http://(127\.0\.0\.1|localhost)(:[0-9]+)?($|/)'
}
# 升级请求一律直连(不绕本机代理: 本机代理可能正是狐径, 而 Gitee 本来就直连更快)
function Get-BwBytes([string]$url, [int]$timeoutSec = 20) {
  # 2026-10-12 (审查 P1): 原来用 WebClient.DownloadData —— $timeoutSec 根本没接到任何超时设置上,
  # 坏网口一次能挂满默认 100 秒, 三次重试叠加更久(后台巡检被一个死地址拖成好几分钟)。
  # 换 HttpWebRequest 显式设 Timeout/ReadWriteTimeout。
  # 顺带把 https 闸门做在总入口(审查 P1·安全): http:// 的下载地址一律拒绝 ——
  # version.json 里哈希与文件同源, http 源被中间人劫持就能同时伪造两者。
  if ($url -match '^http://' -and -not (Test-BwIsLoopbackHttp $url)) { Log ('下载: 拒绝非回环 http:// 地址(只允许 https 或回环 http): ' + $url) 'WARN'; return $null }
  $toMs = 20000
  try { if ($timeoutSec -gt 0) { $toMs = $timeoutSec * 1000 } } catch {}
  for ($try = 1; $try -le 3; $try++) {
    try {
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      $req = [System.Net.HttpWebRequest]::Create($url)
      $req.UserAgent = 'MSWallpaperAssistant'
      $req.Proxy = $null
      $req.Timeout = $toMs
      $req.ReadWriteTimeout = $toMs
      $resp = $req.GetResponse()
      try {
        $stm = $resp.GetResponseStream()
        $ms = New-Object System.IO.MemoryStream
        $stm.CopyTo($ms)
        try { $stm.Dispose() } catch {}
        return $ms.ToArray()
      } finally { try { $resp.Close() } catch {} }
    } catch {
      if ($try -ge 3) { return $null }
      Start-Sleep -Seconds 2
    }
  }
  return $null
}
function Get-BwText([string]$url, [int]$timeoutSec = 15) {
  $b = Get-BwBytes $url $timeoutSec
  if (-not $b) { return '' }
  return [System.Text.Encoding]::UTF8.GetString($b)
}
function Get-BwSha256Hex([byte[]]$bytes) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
}
# 读升级信息(带 6 小时缓存; -Offline 只读缓存, 菜单画界面时用, 不联网)
# ---- 升级界面: 好看 + 动态 + 显示从哪个版本升到哪个版本 ----
# 用户 2026-09-22 要求:「升级界面要好看, 动态的, 从什么版本升级到什么版本」。
# 只用 ASCII 画(方块/箭头字符在部分控制台字体会变乱码), 靠颜色 + 流动动效撑场面。
# 风格跟程序里已有的「虚线增长 + 游标流动」保持一致。
$global:BWUpW = 22
function Show-BwUpGradeHead([string]$from, [string]$to) {
  Write-Host ''
  Write-Host '  ============================================' -ForegroundColor Cyan
  Write-Host '            桌面壁纸 · 在线升级' -ForegroundColor Cyan
  Write-Host '  ============================================' -ForegroundColor Cyan
  Write-Host ''
  # 版本迁移: 箭头沿着轨道流动, 最后变成一条实线箭头
  $W = 10
  for ($f = 0; $f -lt 12; $f++) {
    $pos = $f % $W
    $track = ''
    for ($i = 0; $i -lt $W; $i++) {
      if ($i -eq $pos) { $track += 'o' } elseif ($i -lt $pos) { $track += '=' } else { $track += '-' }
    }
    Write-Host ("`r     v" + $from + "   " + $track + ">   v" + $to) -NoNewline -ForegroundColor Yellow
    Start-Sleep -Milliseconds 80
  }
  Write-Host ("`r     v" + $from + "   " + ('=' * $W) + ">   v" + $to) -ForegroundColor Yellow
  Write-Host ''
}
function Show-BwUpGradeStep([int]$step, [int]$total, [string]$label, [bool]$done, [string]$extra) {
  $sb = New-Object System.Text.StringBuilder
  $sb.Append('     [' + $step + '/' + $total + '] ' + $label) > $null
  $pad = 26 - $label.Length
  if ($pad -gt 0) { $sb.Append(' ' * $pad) > $null }
  if ($done) { $sb.Append('OK') > $null } else { $sb.Append('..') > $null }
  if ($extra) { $sb.Append('   ' + $extra) > $null }
  Write-Host $sb.ToString() -ForegroundColor $(if ($done) { 'Green' } else { 'Gray' })
}
# 下载时的流动进度条(总量未知, 用游标流动表示"在动"), 和 Show-BwDashedCounter 一个路子
function Show-BwUpGradeFlow([string]$label, [int]$step, [int]$total, [int]$frame, [string]$extra) {
  $W = $global:BWUpW
  $cur = $frame % $W
  $sb = New-Object System.Text.StringBuilder
  $sb.Append('     [' + $step + '/' + $total + '] ' + $label + '  [') > $null
  for ($i = 0; $i -lt $W; $i++) {
    if ($i -eq $cur) { $sb.Append('>') > $null } elseif ($i -lt $cur) { $sb.Append('=') > $null } else { $sb.Append('-') > $null }
  }
  $sb.Append(']') > $null
  if ($extra) { $sb.Append('  ' + $extra) > $null }
  Write-Host ("`r" + $sb.ToString()) -NoNewline -ForegroundColor Gray
}
# 下载 + 动画(异步下载, 一边下一边流动); 失败返回 $null
function Get-BwBytesAnimated([string]$url, [int]$timeoutSec, [string]$label, [int]$step, [int]$total) {
  # 2026-10-12 (审查 P1·安全): 同 Get-BwBytes 的 https 闸门（2026-10-16 放行回环 http）。
  if ($url -match '^http://' -and -not (Test-BwIsLoopbackHttp $url)) { Log ('下载: 拒绝非回环 http:// 地址(只允许 https 或回环 http): ' + $url) 'WARN'; return $null }
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'MSWallpaperAssistant')
    $wc.Proxy = $null
    $task = $wc.DownloadDataTaskAsync($url)
    $frame = 0; $t0 = Get-Date
    while (-not $task.IsCompleted) {
      if (((Get-Date) - $t0).TotalSeconds -gt $timeoutSec) { try { $wc.CancelAsync() } catch {}; return $null }
      $frame++
      Show-BwUpGradeFlow $label $step $total $frame ''
      Start-Sleep -Milliseconds 90
    }
    $b = $task.Result
    Show-BwUpGradeFlow $label $step $total ($global:BWUpW - 1) ('已完成 ' + [Math]::Round($b.Length / 1KB) + ' KB')
    Write-Host ''
    return $b
  } catch { return $null }
}
function Show-BwUpGradeDone([bool]$ok, [string]$to, [string]$msg) {
  Write-Host ''
  if ($ok) {
    Write-Host '  ============================================' -ForegroundColor Green
    Write-Host ('   升级完成   ->   v' + $to) -ForegroundColor Green
    Write-Host ('   ' + $msg) -ForegroundColor DarkGray
    Write-Host '  ============================================' -ForegroundColor Green
  } else {
    Write-Host '  ============================================' -ForegroundColor Red
    Write-Host '   升级没有完成, 已保持原样(不会半个包)' -ForegroundColor Red
    Write-Host ('   ' + $msg) -ForegroundColor DarkGray
    Write-Host '  ============================================' -ForegroundColor Red
  }
  Write-Host ''
}
# 2026-10-16 (升级通道加固): 在"相信 version.json 之前"先用主程序内置公钥验签。
# 签名对象是 version.json 的**原始字节**, 签名在 <源地址>.sig (128 个十六进制字符)。
# 这里把原始字节与 .sig 都落到临时文件, 调 桌面壁纸.exe --verify-update 拿退出码:
#   0 = 通过; 非 0 = 拒绝(缺签名/格式错/不匹配, 主程序会打印人话并返回非 0)。
# 纯读纯计算: 除了写两个临时文件(验完即删), 不联网、不改任何状态。
function Test-BwUpdateSignature([byte[]]$rawBytes, [string]$source) {
  $exe = Get-BwExePath
  if (-not $exe) { Log '升级验签: 找不到主程序路径(launcher.txt), 无法验签, 拒绝这次升级信息' 'WARN'; return $false }
  $sigText = ''
  if ($source -match '^https://' -or (Test-BwIsLoopbackHttp $source)) {
    # 2026-10-17: 升级源可能带查询串（GitCode 的 ?ref=main），.sig 要插在 ? 之前。
    if ($source -match '\?') {
      $pp = $source.Substring(0, $source.IndexOf('?'))
      $qq = $source.Substring($source.IndexOf('?') + 1)
      $sigText = Get-BwText ($pp + '.sig?' + $qq) 10
    } else {
      $sigText = Get-BwText ($source + '.sig') 10
    }
  } elseif ($source -match '^http://') {
    Log ('升级验签: 拒绝非回环 http:// 升级源(只允许 https 或回环 http): ' + $source) 'WARN'
    return $false
  } else {
    $sp = $source + '.sig'
    if (Test-Path -LiteralPath $sp) { try { $sigText = [System.IO.File]::ReadAllText($sp) } catch { $sigText = '' } }
  }
  if (-not $sigText) { Log ('升级验签: 拿不到签名 ' + $source + '.sig, 拒绝这次升级信息') 'WARN'; return $false }
  $vjTmp = Join-Path $env:TEMP ('bwvj_' + $PID + '_' + [guid]::NewGuid().ToString('N') + '.json')
  $sigTmp = $vjTmp + '.sig'
  $rc = 1
  try {
    [System.IO.File]::WriteAllBytes($vjTmp, $rawBytes)
    [System.IO.File]::WriteAllText($sigTmp, $sigText, (New-Object System.Text.UTF8Encoding($false)))
    # exe 路径与文件路径都显式加引号(中文 + 空格安全), 用 Start-Process -Wait -PassThru 拿退出码
    $p = Start-Process -FilePath $exe -ArgumentList @('--verify-update', ('"' + $vjTmp + '"'), ('"' + $sigTmp + '"')) -WindowStyle Hidden -Wait -PassThru
    $rc = [int]$p.ExitCode
  } catch {
    Log ('升级验签: 调用主程序验签出错: ' + $_.Exception.Message) 'WARN'
    $rc = 1
  } finally {
    try { [System.IO.File]::Delete($vjTmp) } catch {}
    try { [System.IO.File]::Delete($sigTmp) } catch {}
  }
  if ($rc -ne 0) {
    Log ('升级验签: version.json 验签未通过(退出码 ' + $rc + '), 已拒绝这次升级信息') 'WARN'
    return $false
  }
  return $true
}
function Get-BwUpdateInfo {
  param([switch]$Force, [switch]$Offline)
  # 2026-10-16 (升级通道加固): 只认"验过签"的缓存。旧版(或之前那份)写的缓存没有 sig_ok 标记,
  # 当没缓存、重新联网验签 —— 否则"删掉 update.json / 读一份旧缓存"就成了跳过验签的后门。
  if (-not $Force -and (Test-Path -LiteralPath $global:BWUpdateFile)) {
    try {
      $c = Get-Content -LiteralPath $global:BWUpdateFile -Raw -Encoding UTF8 | ConvertFrom-Json
      $cachedOk = $false
      try { if ($c.PSObject.Properties['sig_ok'] -and $c.sig_ok) { $cachedOk = $true } } catch {}
      if (-not $cachedOk) {
        Log '升级缓存不是验签得来的(可能是旧版写的), 忽略它、重新联网验签' 'WARN'
      } else {
        $age = (Get-Date) - ([datetime]::FromFileTime([int64]$c.checked_ft))
        if ($age.TotalHours -lt 6) { return $c }
        if ($Offline) { return $c }
      }
    } catch {}
  } elseif ($Offline) { return $null }
  $urls = @()
  $cfgUrl = ''
  # 2026-10-10 (复核 P3): 这里原来是**二选一** —— 配了 update_url 就只用它(内置源连试都不试),
  # 读不出来或字段为空就一声不吭退回内置源。于是: 自建镜像不通时, 明明能用的官方地址
  # 根本不在候选里, 直接放弃; 反过来, 自己配的地址为什么没生效, 日志里一个字都没有。
  # 现在: 两边**一起进候选**, 按顺序挨个试; 读配置失败/字段为空都写日志, 成功了写清用的是哪个。
  $cfgHasKey = $false
  try {
    $cfg = Get-BwConfig
    if ($cfg -and $cfg.PSObject.Properties['update_url']) {
      $cfgHasKey = $true
      $cfgUrl = ([string]$cfg.update_url).Trim()
    }
  } catch {
    Log ('升级源: 读配置里的 update_url 失败, 这次只按内置升级源试: ' + $_.Exception.Message) 'WARN'
  }
  if ($cfgUrl) { $urls += $cfgUrl }
  elseif ($cfgHasKey) { Log '升级源: 配置里的 update_url 是空的, 这次只按内置升级源试' 'WARN' }
  foreach ($bu in @($global:BWUpdateUrls)) {
    if ($bu -and ($urls -notcontains $bu)) { $urls += $bu }
  }
  if ($urls.Count -eq 0) { Log '升级源: 候选地址是空的, 这次没法检查更新' 'WARN'; return $null }
  if ($cfgUrl) { Log ('升级源: 自定义地址与内置地址一起试(共 ' + $urls.Count + ' 个): ' + ($urls -join ' | ')) }
  foreach ($u in $urls) {
    $rawBytes = $null
    $raw = ''
    if ($u -match '^https://' -or (Test-BwIsLoopbackHttp $u)) {
      $rawBytes = Get-BwBytes $u
      if ($rawBytes) { $raw = [System.Text.Encoding]::UTF8.GetString($rawBytes) }
    }
    elseif ($u -match '^http://') { Log ('升级源: 拒绝非回环 http:// 地址(只允许 https 或回环 http): ' + $u) 'WARN' }
    elseif (Test-Path -LiteralPath $u) {
      try { $rawBytes = [System.IO.File]::ReadAllBytes($u); $raw = [System.Text.Encoding]::UTF8.GetString($rawBytes) } catch { $rawBytes = $null; $raw = '' }
    }
    if (-not $raw) { Log ('升级源: ' + $u + ' 没取到内容, 试下一个'); continue }
    # 2026-10-16 (升级通道加固): 先验签、后相信。验不过就整条作废、试下一个。
    if (-not (Test-BwUpdateSignature $rawBytes $u)) { continue }
    try {
      $j = $raw | ConvertFrom-Json
      if (-not $j.version) { Log ('升级源: ' + $u + ' 里没有 version 字段, 试下一个') 'WARN'; continue }
      $j | Add-Member -NotePropertyName checked_ft -NotePropertyValue ((Get-Date).ToFileTime()) -Force
      $j | Add-Member -NotePropertyName source -NotePropertyValue $u -Force
      # 2026-10-16 (升级通道加固): 标记"这份结果是验过签的", 缓存命中才能放心复用(见上面读缓存分支)
      $j | Add-Member -NotePropertyName sig_ok -NotePropertyValue $true -Force
      # 2026-10-09 (审查 H-7): 缓存也走原子写 —— 它被写坏只是白查一次,
      # 但既然有现成的原子写, 就没必要留一个"半截 JSON"在数据目录里。
      [void](Save-BwJsonAtomic $global:BWUpdateFile $j)
      Log ('升级源: 这次实际用的是 ' + $u + ' (升级源版本 v' + [string]$j.version + ', 已验签)')
      return $j
    } catch { Log ('升级源: ' + $u + ' 的内容解析不了, 试下一个') 'WARN'; continue }
  }
  Log ('升级源: ' + $urls.Count + ' 个地址全都没成功, 保持上次的结果') 'WARN'
  return $null
}
# 执行升级: 只换脚本。返回 $true 表示脚本已经换成新的。
# ---- 主程序(exe)自动覆盖升级 ----
# 用户 2026-09-22 明确要求:「自动升级, 自动覆盖」。
# 正在运行的 exe 不能直接覆盖, 所以走这套: 自己先停 -> 小助手接管 -> 覆盖 -> 重新启动。
#   1) 新 exe 先下到 <当前 exe 同目录>\<exe 名>.new 并校验 SHA256(对不上立刻放弃);
#      (2026-10-12 改名: 覆盖是**原位替换、文件名不变** —— 老用户升上来还是老文件名, 新装是新文件名。)
#   2) 写一个独立的 .cmd 小助手, 由它: 让旧程序 --stop -> 等进程真的消失 ->
#      move /y .new 覆盖原 exe -> 启动新的 --daemon -> 删掉自己;
#   3) 本进程只负责把 .new 放好、把小助手放出去, 之后与它无关。
# 为什么能这么干: D:\Program Files 的 ACL 是 Authenticated Users:(F), 普通用户也写得进去,
# 所以**不用管理员、不弹 UAC**。目录写不进去时会明确说"要手动换", 绝不做半截。
function Q-Str([string]$x) { return ("'" + ([string]$x).Replace("'", "''") + "'") }
function Get-BwExePath {
  $p = Join-Path $global:BWRoot 'launcher.txt'
  if (Test-Path -LiteralPath $p) {
    try {
      $v = (Get-Content -LiteralPath $p -Raw -Encoding UTF8).Trim()
      if ($v -and (Test-Path -LiteralPath $v)) { return $v }
    } catch {}
  }
  return ''
}
function Invoke-BwLauncherUpdate {
  param([switch]$Quiet, [object]$Info, [switch]$NoStart, [switch]$Animated, [switch]$ReopenMenu)
  # 2026-10-09 (审查 H-8): 试运行闸门放在最前面 —— 连"联网查一次升级源"都不做。
  # 原来这条路径上一个 DryRun 判断都没有: 谁跑一次 -DryRun, 只要升级源上有新版本,
  # 就真的会把本机 exe 换掉。要显示的版本号只从本地缓存读, 所以这里零联网、零写入。
  if ($global:BWDry) {
    $dv = ''
    try { if (-not $Info) { $Info = Get-BwUpdateInfo -Offline }; if ($Info -and $Info.version) { $dv = ' v' + [string]$Info.version } } catch {}
    Log ('试运行: 本应下载主程序' + $dv + '并自动覆盖替换 (不下载、不写 .new、不放小助手、不重启)')
    if (-not $Quiet) { Write-Host ('  试运行: 本来会下载并覆盖主程序' + $dv + ', 本次什么都不做。') -ForegroundColor DarkGray }
    return $false
  }
  if (-not $Info) { $Info = Get-BwUpdateInfo -Force }
  if (-not $Info) { return $false }
  $url = ''; $want = ''
  try { $url = [string]$Info.launcher.url; $want = ([string]$Info.launcher.sha256).ToUpper().Trim() } catch {}
  if (-not $url) {
    Log '升级: 需要新主程序, 但升级信息里没给下载地址'
    if (-not $Quiet) { Write-Host '  升级信息里没有主程序下载地址, 先不升。' -ForegroundColor Yellow }
    return $false
  }
  # 2026-10-09 (审查 H-9): 校验改 fail-closed。原来是 `if ($want -and ($got -ne $want))` ——
  # 升级源里没有 sha256 就整段短路, 等于"不校验、直接安装"。可校验可回滚的自动升级是
  # 这套东西的核心卖点, 少一个字段(有人手改 version.json / 将来换生成脚本漏写)就静默
  # 失效, 不能接受: 缺 sha256、缺尺寸一律拒绝, 连下载都不下。
  $wsize = 0
  try { if ($Info.PSObject.Properties['launcher']) { $wsize = [int64]$Info.launcher.size } } catch { $wsize = 0 }
  if (-not $want) {
    Log '升级失败: 升级源里没有主程序 sha256, 按 fail-closed 拒绝替换(保持旧版)'
    if (-not $Quiet) { Write-Host '  升级源缺少 sha256, 拒绝替换(保持旧版)。' -ForegroundColor Red }
    return $false
  }
  if ($wsize -le 0) {
    Log '升级失败: 升级源里没有主程序大小(size), 按 fail-closed 拒绝替换(保持旧版)'
    if (-not $Quiet) { Write-Host '  升级源缺少 size, 拒绝替换(保持旧版)。' -ForegroundColor Red }
    return $false
  }
  $exe = Get-BwExePath
  if (-not $exe) {
    Log '升级: 找不到主程序路径(launcher.txt 缺失), 不升'
    if (-not $Quiet) { Write-Host '  找不到主程序路径, 先不升。' -ForegroundColor Yellow }
    return $false
  }
  # 2026-10-05 修: 同一时刻**只允许一个小助手**在换 exe。
  # 实测现场: 菜单里按 [U] 的同时后台的每日检查也在升级 -> 起了两个小助手,
  # 互相抢着停进程、覆盖文件, 结果两个都失败, 而且日志还谎报"已覆盖主程序"。
  $lockf = Join-Path $global:BWRoot 'launcher-update.lock'
  if (Test-Path -LiteralPath $lockf) {
    $fresh = $false
    try { $fresh = (((Get-Date) - (Get-Item -LiteralPath $lockf).LastWriteTime).TotalMinutes -lt 10) } catch {}
    if ($fresh) {
      Log '升级: 已有一个主程序升级在进行中, 本次跳过'
      if (-not $Quiet) { Write-Host '  已经有一个升级在进行, 稍等它完成。' -ForegroundColor Yellow }
      return $false
    }
  }
  try { [System.IO.File]::WriteAllText($lockf, (Get-Date -Format 'o'), (New-Object System.Text.UTF8Encoding($false))) } catch {}
  if ($Animated) { Show-BwUpGradeStep 2 3 '下载主程序' $false ('约 ' + [Math]::Round(([double]$Info.launcher.size) / 1MB, 1) + ' MB') }
  $bytes = if ($Animated) { Get-BwBytesAnimated $url 300 '主程序' 2 3 } else { Get-BwBytes $url 120 }
  if (-not $bytes) {
    Log '升级失败: 主程序下载没成功, 保持旧版'
    if (-not $Quiet) { Write-Host '  主程序下载失败, 保持旧版。' -ForegroundColor Yellow }
    try { Remove-Item -LiteralPath $lockf -Force -ErrorAction SilentlyContinue } catch {}
    return $false
  }
  # 大小: 升级源写的字节数 vs 实际下到的字节数对不上 -> 拒绝(最外圈的一道防线)
  if ($wsize -ne $bytes.Length) {
    Log ('升级失败: 主程序大小不符 (升级源写 ' + $wsize + ' 字节, 实际下到 ' + $bytes.Length + ' 字节), 保持旧版')
    if (-not $Quiet) { Write-Host '  主程序大小不符, 已放弃(保持旧版)。' -ForegroundColor Red }
    try { Remove-Item -LiteralPath $lockf -Force -ErrorAction SilentlyContinue } catch {}
    return $false
  }
  $got = Get-BwSha256Hex $bytes
  if ($got -ne $want) {
    # 原来这里的 $want.Substring(0,16) 没有长度保护: 升级源里写个短哈希就会抛
    # ArgumentOutOfRangeException(脚本侧 983 行早就有 [Math]::Min, 这里补上)。
    Log ('升级失败: 主程序校验不过 (期望 ' + $want.Substring(0,[Math]::Min(16,$want.Length)) + ', 实际 ' + $got.Substring(0,16) + '), 保持旧版')
    if (-not $Quiet) { Write-Host '  主程序校验不过, 已放弃(保持旧版)。' -ForegroundColor Red }
    try { Remove-Item -LiteralPath $lockf -Force -ErrorAction SilentlyContinue } catch {}
    return $false
  }
  $nu = $exe + '.new'
  try { [System.IO.File]::WriteAllBytes($nu, $bytes) }
  catch {
    Log ('升级失败: 主程序目录写不进去(' + $_.Exception.Message + '), 需要手动换 exe: ' + $url)
    if (-not $Quiet) { Write-Host ('  程序目录写不进去, 这次要手动换: ' + $url) -ForegroundColor Yellow }
    try { Remove-Item -LiteralPath $lockf -Force -ErrorAction SilentlyContinue } catch {}
    return $false
  }
  # 小助手用 **PowerShell 脚本**而不是 .cmd:
  #   .cmd 由 cmd.exe 按控制台代码页读, 中文路径会变成问号 —— 沙箱实测过, --stop 与 move 全失败。
  #   .ps1 按 UTF-8(带 BOM) 读, 中文路径没问题。
  $logf = Join-Path $global:BWRoot 'update-launcher.log'
  $hl = @()
  $hl += 'function W($m) { try { Add-Content -LiteralPath $log -Value (''['' + (Get-Date -Format ''yyyy-MM-dd HH:mm:ss'') + ''] '' + $m) -Encoding UTF8 } catch {} }'
  $hl += 'W ''开始自动覆盖主程序'''
  $hl += 'Start-Sleep -Seconds 2'
  $hl += 'try { & $exe --stop | Out-Null } catch { W (''调 --stop 出错: '' + $_.Exception.Message) }'
  # 2026-10-09 (审查 H-6): 兜底强杀原来有两条风险:
  #   ① 按**进程名**一网打尽 —— 同名但装在别处的 exe 会被一起杀掉;
  #   ② 60 秒到点就杀, 而守护进程(以及它拉起的 powershell 子进程)可能正卡在补漏里写
  #      state.json —— 一刀下去就是半截 JSON, 下次读判定"版本 0"静默重置,
  #      用户的收藏夹/队列/换图进度全没了。
  # 现在: 只认"路径就是本 exe"的进程; 到点先再发一次停止信号 + 20 秒宽限(够它把这一轮
  # 的写盘收尾), 宽限后还在才兜底强杀。真被强杀也丢不了数据 —— 状态文件已经是
  # "临时文件 + 原子替换"(state.json.tmp 可恢复、坏文件留档、日志报 ERROR)。
  $hl += 'function Alive { $r = @(); foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { $pth = $null; try { $pth = $p.Path } catch {}; if ($pth -and ($pth -eq $exe)) { $r += $p } }; return $r }'
  $hl += '$n = 0'
  $hl += 'while ($n -lt 60) { if (@(Alive).Count -eq 0) { break }; Start-Sleep -Seconds 1; $n++ }'
  $hl += 'if (@(Alive).Count -gt 0) {'
  $hl += '  W (''--stop 等了 '' + $n + '' 秒还没退; 再发一次停止信号并给 20 秒收尾(它可能正在写换图进度)'');'
  $hl += '  try { & $exe --stop | Out-Null } catch {}'
  $hl += '  $m = 0'
  $hl += '  while ($m -lt 20) { if (@(Alive).Count -eq 0) { break }; Start-Sleep -Seconds 1; $m++ }'
  $hl += '}'
  $hl += 'if (@(Alive).Count -gt 0) { W (''宽限结束仍未退出, 兜底结束(只杀路径 = 本 exe 的进程)''); try { @(Alive) | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}; Start-Sleep -Seconds 3 }'
  $hl += 'W (''旧进程已退出(等了 '' + $n + '' 秒)'')'
  # 2026-10-05 修: 覆盖必须**真的换成功**才算数。
  # 原来写的是 `Move-Item ...; W '已覆盖主程序'`, 而脚本头部是 ErrorActionPreference=Continue,
  # Move-Item 失败只是非终止错误 -> 不抛异常 -> 照样写下"已覆盖主程序", 实际文件一个字节没动。
  $hl += '$done = $false'
  $hl += 'for ($k = 1; $k -le 20; $k++) {'
  $hl += '  try { Move-Item -LiteralPath $new -Destination $exe -Force -ErrorAction Stop } catch {'
  $hl += '    try { Copy-Item -LiteralPath $new -Destination $exe -Force -ErrorAction Stop; Remove-Item -LiteralPath $new -Force -ErrorAction SilentlyContinue } catch {}'
  $hl += '  }'
  $hl += '  if (-not (Test-Path -LiteralPath $new)) { $done = $true; break }'
  $hl += '  Start-Sleep -Seconds 2'
  $hl += '}'
  $hl += 'if ($done) { W (''已覆盖主程序: '' + (Get-Item -LiteralPath $exe).Length + '' 字节'') } else { W ''覆盖失败: 文件一直被占用, 保持旧版(临时文件已清理)''; Remove-Item -LiteralPath $new -Force -ErrorAction SilentlyContinue }'
  if (-not $NoStart) {
    $hl += 'Start-Process -FilePath $exe -ArgumentList ''--daemon'' -WindowStyle Hidden'
    $hl += 'W ''已用新版本重新启动'''
  if ($ReopenMenu) {
    # 用户要求: 升级完要把**新版本**的菜单窗口弹出来。
    # 但菜单自己不能等 (它在等新版本就位, 小助手在等菜单窗口关闭 -> 互等 60 秒),
    # 所以由小助手在换完 exe、拉起后台之后, 自己把菜单打开。
    $hl += 'Start-Sleep -Seconds 2'
    $hl += 'try { Start-Process -FilePath $exe; W ''已把新版本的菜单窗口打开'' } catch { W (''打开菜单失败: '' + $_.Exception.Message) }'
  }
  } else {
    $hl += 'W ''(测试模式: 不启动)'''
  }
  $hl += 'try { Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue } catch {}'
  $hl += '$k = 0'
  $hl += 'while ($k -lt 10) { try { Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 500; $k++ } }'
  $head = @(
    '$ErrorActionPreference = ''Continue'''
    # 2026-10-09 真因修复(与狐径同一根因, 真机事故查出来的):
    # 升级小助手是**从主程序里起的**, 会继承主程序(PyInstaller 单文件 exe)的 _PYI_* 变量;
    # 新版本自己也是单文件 exe, 它的引导程序一看到 _PYI_PARENT_PROCESS_LEVEL 就以为
    # "我是子进程、已经解过包了", 于是跳过解包、去找那个早已被删掉的 _MEIxxxx 临时目录,
    # 结果 Failed to load Python DLL —— 新版永远起不来(用户看到的是"升级后程序没了")。
    # 所以起新版本之前, 先把这些变量从环境里擦掉(脚本里擦一次 + 主程序侧再擦一次, 双保险)。
    '$pyi = ''_PYI_PARENT_PROCESS_LEVEL'',''_PYI_APPLICATION_HOME_DIR'',''_PYI_ARCHIVE_FILE'',''_PYI_SPLASH_IPC'',''_MEIPASS'',''_MEIPASS2'''
    'foreach ($n in $pyi) { Remove-Item -LiteralPath (''Env:'' + $n) -ErrorAction SilentlyContinue }'
    ('$exe = ' + (Q-Str $exe))
    ('$new = ' + (Q-Str $nu))
    ('$log = ' + (Q-Str $logf))
    ('$lock = ' + (Q-Str $lockf))
  )
  $helper = Join-Path $env:TEMP ('bwupd_' + [guid]::NewGuid().ToString('N') + '.ps1')
  try {
    [System.IO.File]::WriteAllLines($helper, ($head + $hl), (New-Object System.Text.UTF8Encoding($true)))
    # 2026-10-10: -File 的值必须显式加引号(原因同上面提权那处)。
    # $helper 落在 %TEMP% 下, 用户名带空格的机器(如 C:\Users\Zhang San\AppData\Local\Temp)
    # 上路径会被截断, 小助手**一行都不执行** —— 而 exe 已经下好并校验通过、界面还弹绿框说
    # "程序会自己重启, 本窗口可以关掉", 实际一个字节没换, 程序目录多留一个约 7.7MB 的 .new,
    # 升级锁卡住 10 分钟, 每次启动重演一遍, 用户永远停在旧版。
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $helper)) -WindowStyle Hidden
  } catch {
    Log ('升级失败: 放小助手出错 ' + $_.Exception.Message)
    try { Remove-Item -LiteralPath $lockf -Force -ErrorAction SilentlyContinue } catch {}
    return $false
  }
  if ($Animated) { Show-BwUpGradeStep 3 3 '覆盖并重启' $true '已交给小助手, 几秒后自动完成'; Show-BwUpGradeDone $true ([string]$Info.version) '程序会自己重启, 本窗口可以关掉' }
  Log ('升级: 主程序 v' + $Info.version + ' 已下好(' + $bytes.Length + ' 字节, sha256=' + $got.Substring(0,16) + ')并通过校验, 已交给小助手自动覆盖并重启')
  if (-not $Quiet) { Write-Host ('  主程序 v' + $Info.version + ' 已下好, 几秒后自动覆盖并重启; 这个窗口可以关掉。') -ForegroundColor Green }
  return $true
}
# ---- 升级前的本地兜底备份 (2026-10-10 复核 P1: 固定名 .bak 会被后续发布逐步刷掉) ----
# 只给"这次真的要写的那几个文件"留备份 —— 没被换的文件一个字节都不碰;
# 备份名带上"被替换掉的那个版本号", 例如 core.ps1.bak-2.3.0 (版本号就照 .version 里那份写)。
# 为什么不能继续用固定名 core.ps1.bak:
#   ① 它是**唯一**的本地兜底, 而每一次升级都会把它重新覆盖一遍。只要有过一次"半新半旧"
#      的升级(核心脚本写成功、菜单那一步失败, 或反过来: 磁盘上两个文件不是同一版),
#      下一次升级再存 .bak, 就把当初那份"一切都正常"的副本刷成了这份半新半旧的内容;
#   ② 某一版有问题、用户升到下一版才发现时, .bak 里躺着的正好是**有问题的那一版**,
#      想退回"上一个一切正常的版本"已经没有副本了 —— 本地兜底越用越旧, 再也回不去。
# 带版本号之后: 同一个版本只留第一次存下的那一份, 后来的升级刷不掉它; 版本号读不出来
# (文件坏了/被清掉)就退回时间戳名, 一样是"谁都不覆盖谁"。
# 每个脚本最多留 $Keep 份(新的留下), 免得数据目录里越攒越多。
function Backup-BwScriptForUpdate([string]$path, [string]$ver, [int]$Keep = 5) {
  if (-not (Test-Path -LiteralPath $path)) { return '' }
  # 版本号来自升级源或本地 .version, 先洗一遍再拿去当文件名(只留 数字/字母/点/横线)。
  $tag = ([string]$ver).Trim()
  if ($tag) { $tag = ($tag -replace '[^0-9A-Za-z\.\-]', '_') }
  else { $tag = (Get-Date -Format 'yyyyMMdd-HHmmss') }
  $bak = $path + '.bak-' + $tag
  try {
    if (Test-Path -LiteralPath $bak) {
      # 同名备份已经在了 = 这个版本当初那份好副本还在, 一个字都不改。
      Log ('升级: ' + (Split-Path $path -Leaf) + ' 已有备份 ' + (Split-Path $bak -Leaf) + ', 不覆盖(留着当初那份)')
    } else {
      Copy-Item -LiteralPath $path -Destination $bak -Force
      # 时间戳显式写成"现在": 决定保留哪几份时看到的是"备份是什么时候存的",
      # 而不是源文件原来的修改时间(几个 .bak 的源文件时间戳可能一模一样)。
      try { [System.IO.File]::SetLastWriteTime($bak, (Get-Date)) } catch {}
      Log ('升级: 已备份本机脚本 ' + (Split-Path $path -Leaf) + ' -> ' + (Split-Path $bak -Leaf))
    }
  } catch {
    Log ('升级: 备份 ' + (Split-Path $path -Leaf) + ' 失败(不影响这次升级): ' + $_.Exception.Message) 'WARN'
    return ''
  }
  # 只清理"程序自己给这个文件留的备份", 最多留 $Keep 份; 目录里其它任何文件都不动。
  # 用 .NET 直接删: 本机 Remove-Item 走回收站, 中文路径下会报 trash 失败(见 Remove-BwFile)。
  try {
    $all = @(Get-ChildItem -LiteralPath (Split-Path $path -Parent) -File -Filter ((Split-Path $path -Leaf) + '.bak*') -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending)
    if ($Keep -gt 0 -and $all.Count -gt $Keep) {
      foreach ($f in @($all[$Keep..($all.Count - 1)])) { try { [System.IO.File]::Delete($f.FullName) } catch {} }
    }
  } catch {}
  return $bak
}
function Invoke-BwScriptUpdate {
  param([switch]$Quiet, [switch]$Force, [switch]$Animated, [switch]$ReopenMenu)
  # 2026-10-09 (审查 H-8): 试运行 = 什么都不做。升级要先联网, 之后写 core.ps1 / menu.ps1、
  # 写 .version, 必要时还会转去覆盖主程序 —— 这些在 -DryRun 下一律不许发生。
  # 想显示"本来会升到哪个版本", 只读本地那份缓存(不联网、不写缓存)。
  if ($global:BWDry) {
    $dv = ''
    try { $di = Get-BwUpdateInfo -Offline; if ($di -and $di.version) { $dv = ' v' + [string]$di.version } } catch {}
    Log ('试运行: 本应检查并自动升级脚本' + $dv + ' (不联网下载、不替换文件、不写版本号、不放小助手)')
    if (-not $Quiet) { Write-Host ('  试运行: 本来会升级到' + $dv + ', 本次什么都不做。') -ForegroundColor DarkGray }
    return $false
  }
  $info = Get-BwUpdateInfo -Force:$Force
  if (-not $info) {
    if (-not $Quiet) { Write-Host '  连不上升级源(或还没发布升级信息), 稍后再试。' -ForegroundColor Yellow }
    return $false
  }
  $local = Get-BwLocalScriptVer
  # 2026-10-05 修: 版本横幅要放在"是否真的需要升级"判断**之后**。
  # 本机脚本比升级源新时(例如刚热更过、而线上还没发新版), 原来会画出
  # `v2.0.8 ====> v2.0.7` 这种"从新指向旧"的箭头, 看着像要降级 —— 用户已经看到过。
  # 现在: 不需要升级就不画迁移箭头, 只说明本机与升级源各是什么版本。
  if ((Compare-BwVer ([string]$info.version) $local) -le 0) {
    if ($Animated) { Write-Host ('  本机脚本 v' + $local + '  ·  升级源 v' + [string]$info.version + '  —— 无需升级') -ForegroundColor DarkGray }
    Log ('升级检查: 已是最新 (本机脚本 ' + $local + ', 升级源 ' + $info.version + ')')
    if (-not $Quiet) { Write-Host ('  已是最新版 v' + $local) -ForegroundColor Green }
    return $false
  }
  if ($Animated) { Show-BwUpGradeHead $local ([string]$info.version) }
  $lau = Get-BwLauncherVer
  $minL = ''
  try { if ($info.PSObject.Properties['min_launcher']) { $minL = [string]$info.min_launcher } } catch {}
  if ($minL -and $lau -and ((Compare-BwVer $minL $lau) -gt 0)) {
    # 这一版脚本要求更高的主程序 -> 直接走"自动覆盖主程序"(用户要求自动升级, 自动覆盖)
    Log ('升级: v' + $info.version + ' 需要主程序 v' + $minL + ' 以上 (本机 v' + $lau + '), 转去自动覆盖主程序')
    return (Invoke-BwLauncherUpdate -Quiet:$Quiet -Info $info -Animated:$Animated -ReopenMenu:$ReopenMenu)
  }
  # 下载 -> 校验 -> 落地
  $plan = @()
if ($Animated) { Show-BwUpGradeStep 1 3 '连接升级源' $true ('升级源: ' + [string]$info.version) }
  foreach ($nm in @('core.ps1', 'menu.ps1')) {
    $node = $null
    try { if ($info.scripts -and $info.scripts.PSObject.Properties[$nm]) { $node = $info.scripts.PSObject.Properties[$nm].Value } } catch {}
    if (-not $node) { continue }
    $url = [string]$node.url
    if (-not $url) { $url = 'https://raw.githubusercontent.com/kele551/ms-wallpaper-assistant/main/' + $nm }
    # 2026-10-09 (审查 H-9): fail-closed —— 先确认"该有的校验信息"齐全, 再下载。
    # 原来是 $want 为空就整段短路 = 不校验直接装, 升级源少一个字段就静默降级成
    # "无校验安装", 而且用户端既没提示也没日志。
    $want = ([string]$node.sha256).ToUpper().Trim()
    if (-not $want) {
      Log ('升级失败: 升级源里 ' + $nm + ' 没有 sha256, 按 fail-closed 拒绝升级(保持旧版)')
      if (-not $Quiet) { Write-Host ('  升级源缺少 ' + $nm + ' 的 sha256, 拒绝升级(保持旧版)') -ForegroundColor Red }
      return $false
    }
    $bytes = if ($Animated) { Get-BwBytesAnimated $url 60 ('下载 ' + $nm) 2 3 } else { Get-BwBytes $url }
    if (-not $bytes) { Log ('升级失败: 下载 ' + $nm + ' 没成功, 保持旧版'); if (-not $Quiet) { Write-Host ('  下载 ' + $nm + ' 失败, 保持旧版') -ForegroundColor Yellow }; return $false }
    $got = Get-BwSha256Hex $bytes
    if ($got -ne $want) {
      Log ('升级失败: ' + $nm + ' 校验不过 (期望 ' + $want.Substring(0,[Math]::Min(16,$want.Length)) + ', 实际 ' + $got.Substring(0,16) + '), 保持旧版')
      if (-not $Quiet) { Write-Host ('  ' + $nm + ' 校验不过, 已放弃(保持旧版)') -ForegroundColor Red }
      return $false
    }
    $plan += [PSCustomObject]@{ Name = $nm; Bytes = $bytes; Sha = $got }
  }
  if ($plan.Count -eq 0) { Log '升级失败: 升级信息里没有可用的脚本'; return $false }
  # 2026-10-10 (复核 P1): 备份**只为这次真的要写的文件**留(上面 $plan 里装的就是全部要写的),
  # 而且名字带上"被换掉的那个版本号"。老写法是固定名 <文件>.bak —— 每次升级都刷一遍,
  # 半新半旧的中间态、或"有问题的那一版"会把当初那份好副本盖掉, 本地兜底越用越旧。
  # 现在: 没被换的文件一个字节都不碰; 同名备份已存在就绝不覆盖; 每个脚本最多留 5 份。
  foreach ($it in $plan) {
    $dst = Join-Path $global:BWRoot $it.Name
    $bak = Backup-BwScriptForUpdate $dst $local
    # 2026-10-12 (审查 P1): 直接 WriteAllBytes 盖目标文件不是原子操作 —— 写到一半
    # 断电/被杀, 半截 core.ps1 会**永远留在数据目录里**(launcher 按 .version 判定
    # "已就位"就不再重拉), 等于砖化。改成: 临时文件 → 读回验 sha → 原子替换 →
    # 替换后再验一遍; 中途失败且有本次备份时, 用备份把目标恢复回旧版。
    $tmpU = $dst + '.' + $PID + '.updatetmp'
    try {
      [System.IO.File]::WriteAllBytes($tmpU, $it.Bytes)
      $back = [System.IO.File]::ReadAllBytes($tmpU)
      if ($back.Length -ne $it.Bytes.Length -or (Get-BwSha256Hex $back) -ne $it.Sha) { throw '临时文件读回校验不一致' }
      if (Test-Path -LiteralPath $dst) { [System.IO.File]::Replace($tmpU, $dst, [NullString]::Value) }
      else { [System.IO.File]::Move($tmpU, $dst) }
      $fin = [System.IO.File]::ReadAllBytes($dst)
      if ((Get-BwSha256Hex $fin) -ne $it.Sha) { throw '替换后读回校验不一致' }
      Log ('升级: ' + $it.Name + ' 已更新 (' + $it.Bytes.Length + ' 字节, sha256=' + $it.Sha.Substring(0,16) + ')')
    } catch {
      Log ('升级失败: 写 ' + $it.Name + ' 出错: ' + $_.Exception.Message + ' (保持旧版)')
      if (-not $Quiet) { Write-Host ('  写 ' + $it.Name + ' 失败: ' + $_.Exception.Message) -ForegroundColor Red }
      try { if (Test-Path -LiteralPath $tmpU) { [System.IO.File]::Delete($tmpU) } } catch {}
      try {
        $curSha = ''
        if (Test-Path -LiteralPath $dst) { $curSha = Get-BwSha256Hex ([System.IO.File]::ReadAllBytes($dst)) }
        if ($curSha -and $curSha -ne $it.Sha -and $bak -and (Test-Path -LiteralPath $bak)) {
          Copy-Item -LiteralPath $bak -Destination $dst -Force
          Log ('升级: 已用本机备份 ' + (Split-Path $bak -Leaf) + ' 恢复 ' + $it.Name)
        }
      } catch {}
      return $false
    }
  }
  # 2026-10-05 修: 这里**不能**用 Set-Content -Encoding UTF8 —— PS 5.1 会在文件开头加上
  # UTF-8 BOM(EF BB BF), 而 launcher.py 用 Python 读 `.version` 时 BOM 会把版本号解析坏
  # (当成 0.0), 于是 launcher 判定"数据目录里的脚本比 exe 旧", 下次启动就把刚升级好的
  # 脚本覆盖回旧版 —— 现象是"提示升级成功, 重启又变回旧版本"。改用 .NET 直写(不带 BOM)。
  try { [System.IO.File]::WriteAllText((Join-Path $global:BWRoot '.version'),  [string]$info.version, (New-Object System.Text.UTF8Encoding($false))) } catch {}
  try { [System.IO.File]::WriteAllText((Join-Path $global:BWRoot '.upgraded'), [string]$info.version, (New-Object System.Text.UTF8Encoding($false))) } catch {}
  if ($Animated) { Show-BwUpGradeStep 3 3 '校验与安装' $true 'sha256 全部通过'; Show-BwUpGradeDone $true ([string]$info.version) '下一次运行生效' }
  Log ('升级完成: 脚本 -> v' + $info.version + ' (下次运行生效; 主程序仍是 v' + $lau + ')')
  if (-not $Quiet) { Write-Host ('  已升级到 v' + $info.version + ', 下次启动生效。') -ForegroundColor Green }
  return $true
}
# ---- 自动轮换进度 (state.json): 每次运行是独立进程, 靠这个文件把节奏串起来 ----
# 只记三件事: 今天切过必应没有 / 上次换壁纸是什么时候 / 上次开机时间。
# 聚焦的"不重复"靠 queue —— 把库里所有图洗一次牌按顺序发, 发完再下载 6 张重洗一轮。
# ---- 读 JSON 文件: 分清"文件不在"和"文件坏了" (2026-10-09 审查 H-6) ----
# 返回一个对象: Ok(能不能用) / Missing(文件在不在) / Value(读到的对象) / Why(坏在哪)。
# 为什么要专门写这个: 原来 state.json 一律 ConvertFrom-Json + try{}catch{}, 读失败
# 与"文件不存在"在后面的逻辑里长得一模一样 —— 于是被截断的 state.json 会被当成
# "老版本结构"静默重置, 用户只会发现自己的收藏夹不见了。
function Read-BwJsonState([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) {
    return [PSCustomObject]@{ Ok = $false; Missing = $true; Value = $null; Why = '文件不存在' }
  }
  $raw = ''
  try { $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) }
  catch { return [PSCustomObject]@{ Ok = $false; Missing = $false; Value = $null; Why = ('读不出来: ' + $_.Exception.Message) } }
  $t = $raw.Trim()
  if (-not $t) { return [PSCustomObject]@{ Ok = $false; Missing = $false; Value = $null; Why = '文件是空的(0 字节或只有空白)' } }
  # 尾部校验: 完整的 JSON 对象一定以 } 收尾。写盘写到一半被强杀, 最常见的样子就是
  # "连收尾括号都没有" —— 这一条比"能不能解析"更早、更准地认出截断。
  if (-not $t.EndsWith('}')) {
    return [PSCustomObject]@{ Ok = $false; Missing = $false; Value = $null; Why = ('内容不完整: 结尾没有右花括号, 像是写到一半被中断 (共 ' + $raw.Length + ' 字符)') }
  }
  try { $v = $raw | ConvertFrom-Json }
  catch { return [PSCustomObject]@{ Ok = $false; Missing = $false; Value = $null; Why = ('JSON 解析失败: ' + $_.Exception.Message) } }
  return [PSCustomObject]@{ Ok = $true; Missing = $false; Value = $v; Why = '' }
}
# 状态文件坏了之后的处理: 救 -> 留档 -> 出声(日志写 ERROR + 菜单提示一次)。
# 返回救回来的对象; 救不回来返回 $null(调用方按"新装"处理, 但用户已被明确告知)。
function Repair-BwDamagedState([string]$why) {
  $note = '换图进度文件(state.json)读不出来: ' + $why
  # 2026-10-12: 原子写的临时文件名带 PID(见 Save-BwTextAtomic), 这里按
  # "state.json*.tmp" 找**最新**的一份; 老的固定名 .tmp 也照样被这个通配捞到。
  $tmp = ''
  try {
    $tdir = Split-Path $global:BWState -Parent
    $tleaf = Split-Path $global:BWState -Leaf
    $tcand = @(Get-ChildItem -LiteralPath $tdir -File -Filter ($tleaf + '*.tmp') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($tcand.Count -gt 0) { $tmp = [string]$tcand[0].FullName }
  } catch {}
  # 留档名要保证唯一: 同一秒里损坏两次(测试里就是这么撞上的)时, 重名会让
  # File.Move 直接失败 —— 那就等于"证据留不下来", 跟静默重置一样糟。
  $baseKeep = $global:BWState + '.corrupt-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
  $keep = $baseKeep
  $kn = 1
  while (Test-Path -LiteralPath $keep) { $kn++; $keep = $baseKeep + '-' + $kn }
  $obj = $null
  # 1) 先看原子写留下的临时文件: 写入被打断时, 完整的新内容往往就在它里面
  if ($tmp -and (Test-Path -LiteralPath $tmp)) {
    $r = Read-BwJsonState $tmp
    if ($r.Ok) { $obj = $r.Value }
  }
  # 2) 坏文件改名留档, 不删 —— 里面可能还有能手工认出来的收藏名单
  try {
    [System.IO.File]::Move($global:BWState, $keep)
    $note += '; 损坏的原文件已留档: ' + (Split-Path $keep -Leaf)
  } catch {
    $note += '; 损坏的原文件改名失败(' + $_.Exception.Message + '), 仍在原处'
  }
  # 3) 临时文件里那份完整内容顶上 —— 它就是"上次没来得及替换的那一份"
  if ($obj) {
    try {
      [System.IO.File]::Move($tmp, $global:BWState)
      $note += '; 已用未完成的临时文件里的完整内容恢复(收藏与进度都还在)'
    } catch {
      $obj = $null
      $note += '; 临时文件放回原位失败(' + $_.Exception.Message + ')'
    }
  }
  if (-not $obj) { $note += '; 队列/看过名单无法恢复, 收藏名单请从留档文件里手工找回' }
  Log $note 'ERROR'
  # 4) 留一个标记, 菜单下次进来提示一次(提示完自己删掉, 不刷屏)
  try { [System.IO.File]::WriteAllText((Join-Path $global:BWRoot 'state.corrupt.flag'), $note, (New-Object System.Text.UTF8Encoding($false))) } catch {}
  return $obj
}
function Get-BwState {
  $existed = Test-Path -LiteralPath $global:BWState
  $s = $null
  $damaged = $false
  $why = ''
  if ($existed) {
    $r = Read-BwJsonState $global:BWState
    if ($r.Ok) { $s = $r.Value } else { $damaged = $true; $why = [string]$r.Why }
  }
  $ver = 0
  $needImport = $false
  $needDl = $false
  if ($damaged) {
    # 2026-10-09 (审查 H-6): 文件在、但内容读不出来 = 被写坏了, 不是"老版本结构"。
    # 先尽量救(原子写留下的 .tmp 里往往就是完整的新内容), 救不回来就留档 + ERROR + 菜单提示一次。
    $s = Repair-BwDamagedState $why
    $existed = $false   # 上面已经明确处理过, 不要再按"老结构"多报一次"已重置"
  }
  if ($s) { try { $ver = [int]$s.schema } catch { $ver = 0 } }
  if ($ver -lt 3) {
    # 3 以前的结构不一样, 没法迁, 重置
    if ($existed) { Log ('节奏进度文件版本 ' + $ver + ' -> 8, 结构太老迁不动, 已重置 (下一次运行会重新切一次必应当日图)') }
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
  } elseif ($ver -eq 7) {
    # 7 -> 8 多了「每张图最近一次换到桌面的时刻」(hist_at)。老图回收要靠它算
    # "这张图多少天没出现了", 所以必须留时间; 换图进度、队列、收藏、看过名单一律保留。
    # 老数据没有时间戳的那部分, 回收判定会退回按「看过」名单的位置当年龄。
    Log '节奏进度文件 7 -> 8: 新增每张图最近换图时间(给老图回收算间隔用), 进度/队列/收藏一律保留'
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
    schema = 8; last_bing_date = ''; last_swap = ''; last_boot = ''
    queue = @(); refills = 0; shown = 0; last_wall = ''
    bing_high_date = ''; favorites = @(); history = @()
    dl_total = 0; dl_filled = 0; strangers = @()
    hist_at = @{}
  }
  foreach ($k in $def.Keys) {
    $p = $s.PSObject.Properties[$k]
    if ((-not $p) -or ($null -eq $p.Value)) { Add-Member -InputObject $s NoteProperty $k $def[$k] -Force }
  }
  # schema 要**强制**写成当前版本: 上面那个循环只在"字段缺失或为空"时才补,
  # 而 schema 永远是 3 (有值), 于是升完级还是 3, 每次进来都要再"升级"一遍。
  Add-Member -InputObject $s NoteProperty schema 8 -Force
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
      # !! 这里只能走最底层的整份写, 绝不能调 Save-BwStateKeepFav !!
      # Save-BwStateKeepFav 的第一件事就是再读一次 state (Get-BwState), 而磁盘
      # 此刻还是旧 schema -> 又进到这个分支 -> 再调 -> 无限递归, 直撞 PowerShell
      # 的调用深度上限 ("call depth overflow")。
      # 实测(2026-09-22, 沙箱复现): 20~35 秒刷约 595 行日志后抛异常, 且磁盘
      # state.json 始终写不进去 —— 升级结果永远落不了盘, 之后每次巡检都再撞一次,
      # 被 Invoke-BwCycle 的 catch 吞成一句"轮换异常", 表现就是"壁纸再也不自动换"。
      # 迁移写盘不需要合并/再读: 这份 $s 就是刚读出来的, 只改了 schema 和 dl_filled。
      # dl_total 只是显示缓存(真账在流水文件里), 落盘前按流水同步一次 —— 和
      # Save-BwState 的做法一致, 免得文件里写着 0、界面却显示真实张数。
      try { $s.dl_total = Get-BwDlTotal $s } catch {}
      # 2026-10-09 (审查 H-7): 原子写。这一份写盘发生在"老版本升上来"的迁移里,
      # 写坏了一样会被当成"结构不对"重置 —— 迁移期恰恰最不该丢数据。
      [void](Save-BwJsonAtomic $global:BWState $s)
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
# 必应库的上限(0 = 不限)。跟聚焦库**各算各的** —— 两个库用途不同:
# 聚焦是轮换主力, 必应是「每日一图」的存档, 用户可能想给不同的张数。
# (2026-10-10 晚新增, 起因: 用户担心别的用户硬盘小 —— 必应库原来根本没上限。)
function Get-BwBingCap {
  $c = Get-BwConfig
  $v = 0
  try { $v = [int]$c.bing_cap } catch { $v = 0 }
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
# 一个库的裁剪: 超过 $cap 张就把「已经看过的、最老的」移进回收站(能还原), 绝不动没看过的。
# $label 只用于日志(图库 / 必应库)。移进回收站**不释放空间**(回收站还在同一块盘上),
# 所以界面上别把"裁了"说成"腾出了空间" —— 想真腾地方得清空回收站。
function Trim-BwOneDir($s, [string]$dir, [int]$cap, [string]$label) {
  if ($cap -le 0) { return 0 }
  if (-not $dir) { return 0 }
  if (-not (Test-Path -LiteralPath $dir)) { return 0 }
  $files = @(Get-ChildItem -LiteralPath $dir -File -Filter *.jpg -ErrorAction SilentlyContinue)
  $over = $files.Count - $cap
  if ($over -le 0) { return 0 }
  $hist = @(Get-BwHist $s)
  # 当前正显示的那张、收藏的图都不能动
  $curKey = ''
  if ($s.last_wall) { $curKey = Get-BwNameKey (Split-Path ([string]$s.last_wall) -Leaf) }
  $favKeys = @{}
  # 【2026-10-25 待办 #64 修·收藏的图会被"库上限"裁进回收站】
  # 两边口径不一样：「看过」名单(history)存的是 Get-BwNameKey 折出来的 **slug**
  # (聚焦那种 `日期_中文标题_hash_lakemisurinaitaly.jpg` 只留最后一段)，
  # 而收藏夹存的是**整文件名**。原来这里直接拿整文件名当键去比 slug，必然比不中 ——
  # 于是「收藏的图都不能动」这条对聚焦图**从来没生效过**。
  # 本机真账为证：state.json 的 favorites 是
  #   2026-10-15_逐高之争_858939eb_shanghaiskyscrapers.jpg（整文件名）
  # 而 history 里是 shanghaiskyscrapers（slug）。
  # 修法：收藏名单**两个口径都折一遍**再入表（整文件名 + 它的 key），
  # 老数据里"只记了 slug"的那种收藏也照样护得住。
  # 同一套折算在画廊那里早就有了（见 Get-BwPanelGalleryItems 的 $favKeys），这次是对齐口径。
  foreach ($fn in @(Get-BwFav $s)) {
    if (-not $fn) { continue }
    $favKeys[[string]$fn] = $true
    $fk = Get-BwNameKey ([string]$fn)
    if ($fk) { $favKeys[[string]$fk] = $true }
  }
  $picked = @{}
  $cand = @()
  # ① 先淘汰「已经看过的、最老的」—— 与改之前一致
  foreach ($h in $hist) {
    $hk = [string]$h
    if ((-not $hk) -or ($hk -eq $curKey) -or $favKeys.ContainsKey($hk) -or $picked.ContainsKey($hk)) { continue }
    $f = @($files | Where-Object { (Get-BwNameKey $_.Name) -eq $hk } | Select-Object -First 1)
    if ($f.Count -gt 0) { $cand += $f[0]; $picked[$hk] = $true }
    if ($cand.Count -ge $over) { break }
  }
  # ② 还不够(库里大量"从没轮到过"的图): 按文件名里的日期从早到晚补。
  #    2026-10-23 修: 原来只淘汰"看过的" —— 「必应库上限」形同虚设:
  #    用户设 200 张, 实际能长到 1110 张(4.6 GB), 因为绝大多数图一辈子没被轮到过。
  #    现在的口径: **上限就是上限**, 只保护「当前壁纸 / 收藏 / 做了记号的外来图」。
  if ($cand.Count -lt $over) {
    $rest = @($files | Where-Object {
        $k = Get-BwNameKey $_.Name
        ($k -ne $curKey) -and (-not $picked.ContainsKey([string]$k)) -and (-not $favKeys.ContainsKey([string]$k))
      } | Sort-Object -Property Name)
    foreach ($f in $rest) {
      $cand += $f
      if ($cand.Count -ge $over) { break }
    }
  }
  # 一轮最多搬这么多: 差得太多时别让一次换图卡在搬文件上, 剩下的下一轮继续
  $bulk = 250
  if ($cand.Count -gt $bulk) { $cand = @($cand | Select-Object -First $bulk) }
  $moved = 0
  foreach ($f in $cand) {
    if (Move-BwToRecycle $f.FullName) { $moved++ }
  }
  if ($moved -gt 0) {
    $more = ''
    if ($moved -lt $over) { $more = '; 还差 ' + ($over - $moved) + ' 张, 下一轮继续' }
    Log ($label + '上限 ' + $cap + ' 张: 库里 ' + $files.Count + ' 张, 超出 ' + $over + ' 张 -> 本轮移进回收站 ' + $moved + ' 张' + $more)
  }
  return $moved
}
# 库超上限就裁。2026-10-10 晚起**两个库都裁**: 聚焦按 lib_cap、必应按 bing_cap,
# 两个上限各自可以设 0 = 不限(菜单 [S] → [8] 与 [b])。
function Trim-BwLibrary($s) {
  $c = Get-BwConfig
  $n = 0
  $n += (Trim-BwOneDir $s ([string]$c.spotlight_save_dir) (Get-BwLibCap) '图库')
  $n += (Trim-BwOneDir $s ([string]$c.bing_save_dir) (Get-BwBingCap) '必应库')
  return $n
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
  if (-not ($h -contains $k)) {
    $h = @(@($h) + @($k))
    if ($h.Count -gt 400) { $h = @($h | Select-Object -Last 400) }
    $s.history = $h
  }
  # 2026-10-09: 顺手记下"这张图是什么时候换到桌面的"。老图回收(间隔 >= recycle_min_days 天)
  # 全靠它; 名单本身只有名字, 没有时间。重复看到同一张时更新这个时间(等于把它的间隔重新计时)。
  $at = Get-BwHistAt $s
  $at[[string]$k] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  # 名单裁到 400 条, 时间戳表跟着裁 —— 不然 state.json 会越攒越大
  $keep = @{}
  foreach ($x in $h) {
    $kk = [string]$x
    if ($at.ContainsKey($kk)) { $keep[$kk] = $at[$kk] }
  }
  Set-BwHistAt $s $keep
}
function Save-BwState($s) {
  $s.queue = @($s.queue | Where-Object { $_ })
  # dl_total 是显示缓存, 真账在流水文件里。写回前按流水同步一次:
  # 这样菜单进程哪怕握着旧快照整份覆盖, 带出去的也是当前真值,
  # 不会再把后台刚 +1 的数打回去 (v1.6.2 丢计数就是这个路子)。
  try { $s.dl_total = Get-BwDlTotal $s } catch {}
  # 2026-10-09 (审查 H-7): 原子写。这里是换图进度、队列、收藏名单唯一的总出口,
  # 一次半截写就是"用户收藏夹被清空"那种投诉的来源。
  [void](Save-BwJsonAtomic $global:BWState $s)
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
  # 每张图的最近换图时间: 两边的并集, 同一张取**更近**的那个(更近 = 间隔更保守)
  $da = Get-BwHistAt $disk
  $sa = Get-BwHistAt $s
  foreach ($k in @($da.Keys)) {
    if (-not $sa.ContainsKey($k)) { $sa[$k] = $da[$k]; continue }
    $t1 = Get-BwTime ([string]$sa[$k])
    $t2 = Get-BwTime ([string]$da[$k])
    if ($t2 -and ((-not $t1) -or ($t2 -gt $t1))) { $sa[$k] = $da[$k] }
  }
  $keepAt = @{}
  foreach ($x in @($s.history)) {
    $kk = [string]$x
    if ($sa.ContainsKey($kk)) { $keepAt[$kk] = $sa[$kk] }
  }
  Set-BwHistAt $s $keepAt
  Save-BwState $s
}
function Get-BwTime([string]$t) {
  try { return [DateTime]::ParseExact($t, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}
# ============ 不放大显示: 1:1 居中 + 同图放大模糊作底 (2026-10-09 用户要求) ============
# 用户原话:「**任何情况下都不放大小图** —— 那是"糊"的唯一来源」。
# 于是定成三条:
#   ① 图宽 >= 满屏线 -> 老样子 fill(按比例"缩小"到铺满, 只缩不放, 最锐);
#   ② 图宽 不到满屏线 -> **不放大、不裁剪**: 原图 1:1(或等比缩小到放得下)居中,
#      四周用**同一张图放大 + 模糊**铺底 —— 比黑边自然, 比拉伸清楚;
#   ③ 真比屏幕还小的图(正常不会进库, 门槛挡着)也走 ②, 绝不拉大。
# 合成用 PowerShell + .NET System.Drawing 直接画, 不需要任何第三方库;
# 结果落成一张 **JPEG**(质量 95) **缓存**在数据目录的「合成」下, 同一张图再次轮到直接命中, 不重算。
$global:BWArtFitVer      = 2      # 合成算法版本: 改了画法/格式就 +1, 缓存键跟着变(旧缓存自动失效)
$global:BWArtFitQuality  = 95     # JPEG 质量(用户 2026-10-09 定: 合成图存 JPEG 省盘; 95 肉眼无损)
# 合成结果是一张 2560x1440 的 JPEG(质量 95), 一张约 1MB(用户 2026-10-09 定, 省盘且肉眼无损)。
# 所以缓存既不许多、也不许胖: 张数封顶 + 总字节封顶(实测 5.9MB/张, 48MB 约 8 张)。
# 比屏幕窄的图才会用到合成, 平时命中几张就够轮换, 不会一直重算。
$global:BWArtFitCacheMax = 12     # 合成结果最多留几张(超出按最老淘汰)
$global:BWArtFitCacheMB  = 48     # 合成缓存目录的总字节上限(MB)
$global:BWArtFullDefault = 2560   # 必应/聚焦没有各自的满屏线配置, 用这个默认值
$global:BWSrcSlowMinutes = 30     # 一个源连续超时后的退避分钟数

# 屏幕的**物理**像素。必须用物理值: 本机 125% 缩放, WinForms 报的是 2048x1152(逻辑值),
# 拿它当画布合成, Windows 再铺到 2560x1440 上 —— 等于又被放大一次, 白忙。
# 顺序: 桌面 DC 的 DESKTOPHORZRES/VERTRES(不受进程 DPI 虚拟化影响) -> 显卡当前模式 -> WinForms -> 默认 2560x1440。
function Get-BwScreenSize {
  if ($global:BWScreenSize) { return $global:BWScreenSize }
  $w = 0; $h = 0
  try {
    if (-not ('BwScreenCaps' -as [type])) {
      Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices; public class BwScreenCaps { [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h); [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr hdc); [DllImport("gdi32.dll")] public static extern int GetDeviceCaps(IntPtr hdc, int i); }'
    }
    $hdc = [BwScreenCaps]::GetDC([IntPtr]::Zero)
    if ($hdc -ne [IntPtr]::Zero) {
      $w = [int][BwScreenCaps]::GetDeviceCaps($hdc, 118)   # DESKTOPHORZRES
      $h = [int][BwScreenCaps]::GetDeviceCaps($hdc, 117)   # DESKTOPVERTRES
      [void][BwScreenCaps]::ReleaseDC([IntPtr]::Zero, $hdc)
    }
  } catch { }
  if (($w -le 0) -or ($h -le 0)) {
    # 退一步用程序里现成的那个(GDI+ 那条路走不通时它也在用): 逻辑分辨率 x 系统 DPI 比例
    try {
      $ph = @(Get-BwScreenPhysical)
      if ($ph.Count -ge 2) { $w = [int]$ph[0]; $h = [int]$ph[1] }
    } catch { }
  }
  if (($w -le 0) -or ($h -le 0)) {
    try {
      Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
      $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
      $w = [int]$b.Width; $h = [int]$b.Height
    } catch { }
  }
  if (($w -le 0) -or ($h -le 0)) { $w = 2560; $h = 1440 }
  $global:BWScreenSize = @{ W = $w; H = $h }
  return $global:BWScreenSize
}
function Test-BwArtFitOn([psobject]$c) {
  if (-not $c) { return $true }
  try {
    if (-not $c.PSObject.Properties['art_fit_mode']) { return $true }
    $v = $c.PSObject.Properties['art_fit_mode'].Value
    if ($v -is [bool]) { return [bool]$v }
    $s = ([string]$v).Trim().ToLower()
    if (($s -eq 'off') -or ($s -eq 'false') -or ($s -eq '0') -or ($s -eq 'no') -or ($s -eq '关')) { return $false }
    return $true
  } catch { return $true }
}
# 这张图属于哪个源 -> 用哪个源的"满屏线"。必应/聚焦用默认的 2560。
function Get-BwSrcFullOfPath([psobject]$c, [string]$path) {
  try {
    $d = ([string](Split-Path $path -Parent)).TrimEnd('\').ToLower()
    if ($d) {
      foreach ($def in @(Get-BwSourceDefs)) {
        $sd = Get-BwSrcDir $c $def.Key
        if (-not $sd) { continue }
        if (([string]$sd).TrimEnd('\').ToLower() -eq $d) { return (Get-BwSrcFullWidth $c $def.Key) }
      }
    }
  } catch { }
  return $global:BWArtFullDefault
}
# 合成图的缓存路径。键 = 原图路径 + 大小 + 修改时刻 + 屏幕尺寸 + 算法版本,
# 文件名里另外带上"原图字节数": 万一路径哈希撞了(32 位哈希, 几百张时概率极低但不为零),
# 字节数不同就还是两个文件, 不会出现"两张图共用一张合成图"。
# 原图换了、屏幕换了、画法改了, 都会自然落到另一个文件, 不会拿旧图糊弄。
function Get-BwArtFitPath([string]$path, [int]$w, [int]$h) {
  $stamp = ''
  $len = 0
  try {
    $fi = Get-Item -LiteralPath $path -ErrorAction Stop
    $len = [int64]$fi.Length
    $stamp = ([string]$fi.Length + '_' + [string]$fi.LastWriteTimeUtc.Ticks)
  } catch { $stamp = '' }
  $key = (Get-BwHash ($path + '|' + $stamp)) + '_' + $w + 'x' + $h + '_' + $len + 'b_v' + $global:BWArtFitVer
  return (Join-Path (Join-Path $global:BWRoot '合成') ($key + '.jpg'))
}
# 小图上的盒式模糊(就地改)。用 C# 干这段是为了速度: 纯 PowerShell 逐像素要几秒,
# 编译一次之后只要几毫秒。**编译不出来就跳过**(前面的缩放本身已经糊了, 只是没那么绵)。
# 注意两个坑(2026-10-09 自测踩到):
#   ① 必须 -ReferencedAssemblies System.Drawing —— 少了它 Add-Type 报"找不到 Imaging 命名空间",
#      于是这段模糊**一次都没真正跑过**(画面靠 1/8 缩放撑着, 看着也还行, 所以很难发现);
#   ② 必须 -ErrorAction Stop —— 否则编译失败的报错会被打到控制台/日志里, 每次合成一条噪音。
function Optimize-BwBlurBitmap($bmp, [int]$r) {
  if (-not $bmp) { return $false }
  try {
    if (-not ('BwBlur' -as [type])) {
      Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public class BwBlur {
  public static void Box(Bitmap b, int r) {
    int w = b.Width, h = b.Height;
    BitmapData d = b.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadWrite, PixelFormat.Format24bppRgb);
    try {
      int stride = d.Stride;
      byte[] buf = new byte[stride * h];
      byte[] tmp = new byte[buf.Length];
      Marshal.Copy(d.Scan0, buf, 0, buf.Length);
      for (int p = 0; p < 3; p++) {
        for (int y = 0; y < h; y++) {
          int row = y * stride;
          for (int x = 0; x < w; x++) {
            int s0 = 0, s1 = 0, s2 = 0, n = 0;
            for (int k = -r; k <= r; k++) {
              int xx = x + k; if (xx < 0 || xx >= w) continue;
              int i = row + xx * 3; s0 += buf[i]; s1 += buf[i + 1]; s2 += buf[i + 2]; n++;
            }
            int o = row + x * 3; tmp[o] = (byte)(s0 / n); tmp[o + 1] = (byte)(s1 / n); tmp[o + 2] = (byte)(s2 / n);
          }
        }
        Array.Copy(tmp, buf, buf.Length);
        for (int x = 0; x < w; x++) {
          int col = x * 3;
          for (int y = 0; y < h; y++) {
            int s0 = 0, s1 = 0, s2 = 0, n = 0;
            for (int k = -r; k <= r; k++) {
              int yy = y + k; if (yy < 0 || yy >= h) continue;
              int i = yy * stride + col; s0 += buf[i]; s1 += buf[i + 1]; s2 += buf[i + 2]; n++;
            }
            int o = y * stride + col; tmp[o] = (byte)(s0 / n); tmp[o + 1] = (byte)(s1 / n); tmp[o + 2] = (byte)(s2 / n);
          }
        }
        Array.Copy(tmp, buf, buf.Length);
      }
      Marshal.Copy(buf, 0, d.Scan0, buf.Length);
    } finally { b.UnlockBits(d); }
  }
}
'@ -ReferencedAssemblies 'System.Drawing' -ErrorAction Stop
    }
    [BwBlur]::Box($bmp, $r)
    return $true
  } catch { return $false }
}
# 真正画那张合成图。返回 $true = 已经落盘。
function New-BwArtFitImage([string]$src, [string]$dst, [int]$W, [int]$H) {
  Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
  $im = $null; $bmp = $null; $g = $null; $small = $null; $gs = $null
  # 临时文件名带本进程号: 后台守护和菜单有可能同时要给同一张图做合成,
  # 共用同一个 .tmp 的话, 一边搬走另一边还在写, 落地的图就可能是半张。
  $tmp = $dst + '.' + $PID + '.tmp'
  try {
    [void](New-BwDir (Split-Path $dst -Parent))
    Remove-BwFile $tmp
    $im = [System.Drawing.Image]::FromFile($src)
    $bmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode  = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.SmoothingMode    = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality

    # ---- ① 底: 同一张图"铺满"缩小 -> 盒式模糊 -> 放大铺回去 ----
    # 缩到 1/8(2560x1440 -> 320x180)再模糊再放大: 这一步是"廉价高斯"。
    # 早先试过 1/20(128x72): 放大 20 倍之后能看出方块台阶(实测截图里一条条的),
    # 1/8 + 半径 4 的三遍盒式模糊才够绵, 又不会把画面糊成一团色块。
    $sw = [int]($W / 8); if ($sw -lt 32) { $sw = 32 }
    $sh = [int]($H / 8); if ($sh -lt 32) { $sh = 32 }
    $small = New-Object System.Drawing.Bitmap($sw, $sh, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $gs = [System.Drawing.Graphics]::FromImage($small)
    $gs.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $gs.PixelOffsetMode  = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $r = [Math]::Max(($sw * 1.0) / [double]$im.Width, ($sh * 1.0) / [double]$im.Height)   # cover
    $dw = [int][Math]::Ceiling([double]$im.Width * $r)
    $dh = [int][Math]::Ceiling([double]$im.Height * $r)
    $gs.DrawImage($im, [int](($sw - $dw) / 2), [int](($sh - $dh) / 2), $dw, $dh)
    $gs.Dispose(); $gs = $null
    [void](Optimize-BwBlurBitmap $small 4)
    $g.DrawImage($small, (New-Object System.Drawing.Rectangle(0, 0, $W, $H)))
    $small.Dispose(); $small = $null
    # 压暗三成: 中间那张原图才跳得出来, 不然同色底 + 同色图看不出边界
    $br = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(77, 0, 0, 0))
    $g.FillRectangle($br, 0, 0, $W, $H)
    $br.Dispose()

    # ---- ② 中间: 原图等比放进去(只有比屏幕还大时才缩, 绝不放大) ----
    $scale = [Math]::Min(1.0, [Math]::Min(($W * 1.0) / [double]$im.Width, ($H * 1.0) / [double]$im.Height))
    $dw2 = [int][Math]::Round([double]$im.Width * $scale)
    $dh2 = [int][Math]::Round([double]$im.Height * $scale)
    if ($dw2 -lt 1) { $dw2 = 1 }
    if ($dh2 -lt 1) { $dh2 = 1 }
    if ($dw2 -gt $W) { $dw2 = $W }
    if ($dh2 -gt $H) { $dh2 = $H }
    $x = [int](($W - $dw2) / 2); $y = [int](($H - $dh2) / 2)
    if ($scale -ge 0.999) {
      # 1:1 就要是**真的 1:1**: 逐像素照搬, 不能过任何插值
      $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
      $g.PixelOffsetMode  = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    }
    $g.DrawImage($im, (New-Object System.Drawing.Rectangle($x, $y, $dw2, $dh2)))
    $g.Dispose(); $g = $null
    # 先写 .tmp 再原子换名: 半张图被当成壁纸会直接花屏
    # 2026-10-09 用户定: 合成图存 JPEG(质量 95) —— 一张约 1MB, 比 PNG 省 4~5 倍盘;
    # 中间那块是 1:1 照搬后再过一次 q95 编码, 肉眼与原图无差别。
    $encJpg = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
    if ($encJpg) {
      $ep = New-Object System.Drawing.Imaging.EncoderParameters -ArgumentList 1
      $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter `
                       -ArgumentList ([System.Drawing.Imaging.Encoder]::Quality), ([int64]$global:BWArtFitQuality)
      $bmp.Save($tmp, $encJpg, $ep)
      $ep.Dispose()
    } else {
      # 取不到 JPEG 编码器就退回 PNG(保证功能不中断)
      $bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    if (Test-Path -LiteralPath $dst) { Remove-BwFile $dst }
    Move-Item -LiteralPath $tmp -Destination $dst -Force -ErrorAction Stop
    return $true
  } catch {
    Log ('合成壁纸失败(退回原图显示): ' + $_.Exception.Message) 'WARN'
    Remove-BwFile $tmp
    return $false
  } finally {
    if ($gs) { $gs.Dispose() }
    if ($small) { $small.Dispose() }
    if ($g) { $g.Dispose() }
    if ($bmp) { $bmp.Dispose() }
    if ($im) { $im.Dispose() }
  }
}
# 缓存别无限长: 张数超上限、或者总量超过 BWArtFitCacheMB, 就把最老的删掉
# (只删本程序自己生成的合成图, 不动目录里任何别的文件)。
# **正在当壁纸的那一张永远不删** —— 删了它, 桌面下次重绘就会变黑/回退, 用户莫名其妙。
# 2026-10-10: 这里原本写 -Filter *.png, 而合成缓存实际存的是 .jpg(见 Get-BwArtFitPath
# 第 1782 行的 $key + '.jpg', New-BwArtFitImage 也按 JPEG 存) —— 于是每次清理一个文件
# 都枚举不到, BWArtFitCacheMax=12 / BWArtFitCacheMB=48 两道上限**形同虚设**:
# 每碰到一张宽度不到满屏线的图, 「合成」目录里就多留一张约 1MB 的 jpg, 只增不减。
# 现在 .jpg 与 .png 都收: 前者是当前缓存, 后者是 BWArtFitVer 1 时代留下的历史缓存。
function Remove-BwArtFitOld {
  try {
    $dir = Join-Path $global:BWRoot '合成'
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $cur = ''
    try { $cur = [string](Get-ItemProperty 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue).Wallpaper } catch { $cur = '' }
    $fs = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.jpg', '.png' } |
            Sort-Object LastWriteTime -Descending)
    if ($fs.Count -eq 0) { return }
    $total = 0
    foreach ($f in $fs) { $total += [int64]$f.Length }
    $limitB = [int64]$global:BWArtFitCacheMB * 1MB
    $drop = @()
    for ($i = 0; $i -lt $fs.Count; $i++) {
      # 留最近的 BWArtFitCacheMax 张; 同时保证总量不超上限(从最老的开始砍)
      if (($i -ge $global:BWArtFitCacheMax) -or ($total -gt $limitB)) {
        if ($cur -and ($cur.ToLower() -eq ([string]$fs[$i].FullName).ToLower())) { continue }   # 正用着, 跳过
        $drop += $fs[$i]
        $total -= [int64]$fs[$i].Length
      }
    }
    foreach ($f in $drop) { Remove-BwFile $f.FullName }
  } catch { }
}
# 决策: 这张图该怎么显示? 只算不画、不落盘 —— 试运行与日志都用它。
# 返回 @{ Mode='fill'|'artfit'; ... }, Mode='fill' = 用原图(老样子), 'artfit' = 用合成图。
function Get-BwArtFitPlan([string]$path) {
  $plan = @{ Mode = 'fill'; Path = $path; Target = $path; W = 0; H = 0; ScreenW = 0; ScreenH = 0; Line = 0; Cache = ''; Why = '' }
  if (-not $path) { return $plan }
  $c = $null
  try { $c = Get-BwConfig } catch { $c = $null }
  if (-not (Test-BwArtFitOn $c)) { $plan.Why = '不放大显示关着(按老的填充走)'; return $plan }
  $sz = Get-BwImageSize $path
  if (-not $sz) { $plan.Why = '读不出分辨率, 按原样走'; return $plan }
  $scr = Get-BwScreenSize
  # 满屏线 = 这个源的配置线与屏幕物理宽**取大**: 两者只要有一个说"还不到满屏", 就不铺满。
  # 这样任何情况下都不会把图放大(放大 = 糊), 屏幕比配置线宽时也不会拉爆。
  $line = [Math]::Max([int](Get-BwSrcFullOfPath $c $path), [int]$scr.W)
  $plan.W = [int]$sz.W; $plan.H = [int]$sz.H
  $plan.ScreenW = [int]$scr.W; $plan.ScreenH = [int]$scr.H; $plan.Line = $line
  if ([int]$sz.W -ge $line) {
    $plan.Why = ('宽 ' + $sz.W + ' >= 满屏线 ' + $line + ': 铺满(只缩不放)')
    return $plan
  }
  $plan.Mode = 'artfit'
  $plan.Cache = (Get-BwArtFitPath $path ([int]$scr.W) ([int]$scr.H))
  $plan.Target = $plan.Cache
  # 中间那块到底画多大: 宽不到屏幕线, 所以只可能 1:1 或者"高度放不下时等比缩到放得下"。
  # 绝不放大(糊的来源), 也绝不裁掉画面(画的上下缘不能切) —— 这两条比"填满"重要。
  $sc = [Math]::Min(1.0, [Math]::Min(($scr.W * 1.0) / [double]$sz.W, ($scr.H * 1.0) / [double]$sz.H))
  $plan.DrawnW = [int][Math]::Round([double]$sz.W * $sc)
  $plan.DrawnH = [int][Math]::Round([double]$sz.H * $sc)
  $how = '原图 1:1 居中'
  if ($sc -lt 0.999) {
    $how = ('等比缩到 ' + $plan.DrawnW + 'x' + $plan.DrawnH + ' 居中(高 ' + $sz.H + ' 超过屏幕 ' + $scr.H + ', 缩一点才放得下; 不裁不放大)')
  }
  $plan.Why = ('宽 ' + $sz.W + ' < 满屏线 ' + $line + ': ' + $how + ' + 同图模糊底 (' + $scr.W + 'x' + $scr.H + ')')
  return $plan
}
# 决策 + 需要的话现场合成(命中缓存就直接用)。返回要设为壁纸的那个路径; 出任何问题都返回原图。
function Get-BwArtFitWall([string]$path) {
  try {
    $plan = Get-BwArtFitPlan $path
    if ([string]$plan.Mode -ne 'artfit') { return $path }
    if (Test-Path -LiteralPath $plan.Cache) {
      Log ('用缓存的合成壁纸: ' + (Split-Path $plan.Cache -Leaf) + ' (' + $plan.Why + ')')
      return $plan.Cache
    }
    $t0 = Get-Date
    $ok = New-BwArtFitImage $path $plan.Cache ([int]$plan.ScreenW) ([int]$plan.ScreenH)
    $ms = [int]((Get-Date) - $t0).TotalMilliseconds
    if (-not $ok) { return $path }
    Remove-BwArtFitOld
    Log ('合成壁纸: 原图 ' + $plan.W + 'x' + $plan.H + ' 画成 ' + $plan.DrawnW + 'x' + $plan.DrawnH + ' 居中' +
         ' -> ' + $plan.ScreenW + 'x' + $plan.ScreenH + ' (同图模糊底, 不放大不裁剪), 耗时 ' + $ms + ' ms -> ' + (Split-Path $plan.Cache -Leaf))
    return $plan.Cache
  } catch {
    Log ('合成壁纸异常(按原图显示): ' + $_.Exception.Message) 'WARN'
    return $path
  }
}
function Set-BwWall([string]$path) {
  # 已经是这张就不重复调 API, 少一次桌面重绘
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  # MWA_NO_SETWALL=1: 只给自检/演练用 —— 只写日志, 不真的改桌面壁纸。
  # 起因(2026-10-23): 自检里点了"必应模式", 把用户桌面壁纸切成了测试目录里的图;
  # 数据目录能隔离, "改系统壁纸"这个动作隔离不了, 所以给一个显式的闸。
  if ($env:MWA_NO_SETWALL -eq '1') {
    Log ('自检: 本应设为壁纸 -> ' + $path + ' (MWA_NO_SETWALL=1, 未动桌面)')
    return $true
  }
  if ($global:BWDry) {
    # 试运行: 连"要不要合成"都只算不画 —— 不然试运行也会往数据目录写 PNG。
    $why = ''
    try { $why = [string](Get-BwArtFitPlan $path).Why } catch { $why = '' }
    Log ('试运行: 本应设为壁纸 -> ' + $path + ' [' + $why + ']')
    return $true
  }
  # 2026-10-09: 小图不放大 —— 需要的话现场合成一张"1:1 居中 + 模糊底"(有缓存就用缓存)。
  $target = Get-BwArtFitWall $path
  if (-not $target) { $target = $path }
  $cur = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue).Wallpaper
  if ($cur -and ($cur -eq $target)) {
    # 2026-10-17: 图没变, 但“填充方式”可能在开机/重启后被系统重置成居中 ——
    # 必须顺手校对一遍, 否则开机第一张壁纸会一直显示成居中(桌面没铺满)。
    # 老代码直接 return, 漏了这一步(用户反馈“每天开机第一张是居中”)。
    if (-not (Test-BwStyleOk)) { return (Set-BwDesktopWallpaper $target) }
    return $true
  }
  return (Set-BwDesktopWallpaper $target)
}

# 2026-10-17: 系统里的填充方式 == 程序该设的值? (开机后被系统重置时, 用它判断要不要重设)
function Test-BwStyleOk {
  try {
    $w = Get-BwWallStyle
    $c = Get-ItemProperty 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue
    return [bool](((-not $w.Style) -or ([string]$c.WallpaperStyle -eq $w.Style)) -and ((-not $w.Tile) -or ([string]$c.TileWallpaper -eq $w.Tile)))
  } catch { return $false }
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
# ==================== 聚焦源池: 预算 / 退避 / 老图回收 (2026-10-09, 用户要求) ====================
# 背景(用户反馈的真问题): 微软聚焦的源池总共 800+ 张, 官方每天只新增有限几张; 而程序的
# 去重是**永久**的(「看过」名单 + dl_ledger.log 下载流水)。几百张被一次抽干之后, 它就再也
# 拿不到"新图"了 —— 用户视角就是"这软件没图可换了"。三条对策:
#   ① 抓取预算 : 单轮 <= fetch_round_cap 张、单日 <= fetch_day_cap 张; 库满了就不再补
#                (只在库低于阈值时补), 让 800+ 张成为"储备", 按消耗速度慢慢放;
#   ② 耗尽退避 : 连续 3 轮"新增 0" -> 低频模式, 每 24 小时只在官方更新时间点(早 8 点)附近
#                试一轮; 哪一轮新增 >0 就立刻恢复正常频率;
#   ③ 老图回收 : 未看过的剩量不足 20 张时, 允许把"至少 recycle_min_days 天没出现过"的老图
#                重新排进轮换 —— 本地还在(「已看过」文件夹)就直接移回库(零网络开销), 不在就
#                重新下载(流水账给这类"过期重下"放行, 但仍然拦住近期看过的)。
# 这样永久运行也不会枯竭: 新图优先, 老图按间隔循环, 官方每天新增的照样插队。
# 节流账本落在 fetch_stats.json, 独立于 state.json —— 它记的是"抓取节奏", 不该被换图进度覆盖。
$global:BWFetchStats = Join-Path $global:BWRoot 'fetch_stats.json'
$global:BWRecycleBelow = 20      # 未看过的剩量低于这个数, 就允许回收老图
$global:BWZeroRoundsToLow = 3    # 连续几轮"新增 0"进入低频模式

function Get-BwFetchStats {
  $o = $null
  if (Test-Path -LiteralPath $global:BWFetchStats) {
    try { $o = Get-Content -LiteralPath $global:BWFetchStats -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $o = $null }
  }
  if (-not $o) { $o = New-Object PSObject }
  if (-not $o.PSObject.Properties['day'])          { Add-Member -InputObject $o NoteProperty day '' -Force }
  if (-not $o.PSObject.Properties['day_used'])     { Add-Member -InputObject $o NoteProperty day_used 0 -Force }
  if (-not $o.PSObject.Properties['zero_rounds'])  { Add-Member -InputObject $o NoteProperty zero_rounds 0 -Force }
  if (-not $o.PSObject.Properties['last_try'])     { Add-Member -InputObject $o NoteProperty last_try '' -Force }
  if (-not $o.PSObject.Properties['last_new'])     { Add-Member -InputObject $o NoteProperty last_new '' -Force }
  if (-not $o.PSObject.Properties['next_try'])     { Add-Member -InputObject $o NoteProperty next_try '' -Force }
  if (-not $o.PSObject.Properties['mode'])         { Add-Member -InputObject $o NoteProperty mode 'normal' -Force }
  if (-not $o.PSObject.Properties['low_log_day'])  { Add-Member -InputObject $o NoteProperty low_log_day '' -Force }
  if (-not $o.PSObject.Properties['recycled'])     { Add-Member -InputObject $o NoteProperty recycled 0 -Force }
  return $o
}
function Save-BwFetchStats($o) {
  # 试运行: 连节流账本都不写 (与 H-8 的口径一致: -DryRun 不许有任何副作用)
  if ($global:BWDry) { return }
  [void](Save-BwJsonAtomic $global:BWFetchStats $o)
}
function Get-BwRecycleMinDays($c) {
  $v = 30
  try { if ($c -and $c.PSObject.Properties['recycle_min_days']) { $v = [int]$c.recycle_min_days } } catch { $v = 30 }
  $r = $global:BwLimit['recycle_min_days']
  if ($r) {
    if ($v -lt $r.Min) { $v = $r.Min }
    if ($v -gt $r.Max) { $v = $r.Max }
  }
  if ($v -lt 1) { $v = 30 }
  return $v
}
# 今天还能抓几张(单日额度, 换天自动归零)。
function Get-BwFetchBudget([psobject]$c, $st) {
  $dayCap = 20
  try { if ($c -and $c.PSObject.Properties['fetch_day_cap']) { $dayCap = [int]$c.fetch_day_cap } } catch { $dayCap = 20 }
  if ($dayCap -le 0) { $dayCap = 20 }
  $used = 0
  if ($st -and ([string]$st.day -eq (Get-Date).ToString('yyyy-MM-dd'))) {
    try { $used = [int]$st.day_used } catch { $used = 0 }
  }
  return [Math]::Max(0, $dayCap - $used)
}
# 这一轮实际允许抓几张 = min(想抓的张数, 单轮上限, 剩余单日额度)。
function Get-BwFetchAllow([psobject]$c, $st, [int]$want, [switch]$IgnoreDailyCap) {
  $roundCap = 6
  try { if ($c -and $c.PSObject.Properties['fetch_round_cap']) { $roundCap = [int]$c.fetch_round_cap } } catch { $roundCap = 6 }
  if ($roundCap -le 0) { $roundCap = 6 }
  $dayLeft = 999999
  if (-not $IgnoreDailyCap) { $dayLeft = Get-BwFetchBudget $c $st }
  $n = [Math]::Min([Math]::Min($want, $roundCap), $dayLeft)
  if ($n -lt 0) { $n = 0 }
  return $n
}
# 低频模式下"下一次值得试"的时刻: 下一个早 8 点(官方一般上午更新), 且至少 6 小时之后、
# 最多 24 小时之后 —— 用户要求"每 24 小时只在官方更新时间点附近试一轮(或至少间隔 >=6 小时)"。
function Get-BwNextTryTime([DateTime]$now) {
  $t = $now.Date.AddHours(8)
  while ($t -le $now.AddHours(6)) { $t = $t.AddDays(1) }
  if ((($t) - $now).TotalHours -gt 24) { $t = $now.AddHours(24) }
  return $t
}
function Test-BwFetchDue($st, [DateTime]$now) {
  if (-not $st) { return $true }
  if ([string]$st.mode -ne 'pool_end') { return $true }
  $nx = Get-BwTime ([string]$st.next_try)
  if (-not $nx) { return $true }
  return ($now -ge $nx)
}
function Format-BwTryTime([string]$t) {
  $d = Get-BwTime $t
  if ($d) { return $d.ToString('yyyy-MM-dd HH:mm') }
  return '稍后'
}
# 一轮抓取结束后记账。**纯函数**(只改传进来的 $st, 不碰磁盘), 所以好测。
#   $ran = 这一轮真的跑了吗(被预算或低频模式拦下的不算, 不能记成"空轮")
# 空轮的判定: 跑过、而且"见到了图但全被去重跳过"才算 —— 那是源池到头的信号;
# 一次都没拿到图(断网)不算, 不能因为网络抖动就把池子判成抓干了。
function Update-BwFetchStats($st, [int]$ok, [int]$skip, [int]$fail, [int]$tries, [bool]$ran, [DateTime]$now) {
  if (-not $st) { return $st }
  if (-not $ran) { return $st }
  $st.last_try = $now.ToString('yyyy-MM-dd HH:mm:ss')
  $today = $now.ToString('yyyy-MM-dd')
  if ([string]$st.day -ne $today) { $st.day = $today; $st.day_used = 0 }
  $st.day_used = [int]$st.day_used + [int]$ok
  if ($ok -gt 0) {
    # 有新图 -> 立刻退出低频模式, 回到正常频率
    $st.last_new = $st.last_try
    $st.zero_rounds = 0
    $st.mode = 'normal'
    $st.next_try = ''
    return $st
  }
  if ($skip -gt 0) {
    $st.zero_rounds = [int]$st.zero_rounds + 1
    if ([int]$st.zero_rounds -ge $global:BWZeroRoundsToLow) {
      if ([string]$st.mode -ne 'pool_end') {
        $st.mode = 'pool_end'
        $st.next_try = (Get-BwNextTryTime $now).ToString('yyyy-MM-dd HH:mm:ss')
      }
    }
  }
  return $st
}
# 源池抓到尽头时的聚合日志(每天最多一行)。用户要求: 进低频后别再每轮写"新增0 跳过N"。
function Write-BwPoolEndLine($st, [bool]$Quiet) {
  $today = (Get-Date).ToString('yyyy-MM-dd')
  if ([string]$st.low_log_day -eq $today) { return }
  $st.low_log_day = $today
  Save-BwFetchStats $st
  $line = '聚焦源池已抓到尽头（本地区 ' + @(Get-BwSpotlightAll).Count + ' 张），等官方更新；下次尝试 ' + (Format-BwTryTime ([string]$st.next_try))
  Log $line
  if (-not $Quiet) { Write-Host ('  ' + $line) -ForegroundColor DarkGray }
}
# ---- 「看过」的时间戳: 老图回收要靠它判断"多少天没出现了" ----
# state.json 里 history 只有名字、没有时间; 这里另存一份 名字 -> 最后一次换到桌面的时刻。
# 老版本升上来时这份是空的, 那时按 history 的位置当年龄(见 Test-BwOldImageReusable)。
function Get-BwHistAt($s) {
  $h = @{}
  if (-not $s) { return $h }
  $p = $s.PSObject.Properties['hist_at']
  if (-not $p -or -not $p.Value) { return $h }
  $v = $p.Value
  if ($v -is [System.Collections.IDictionary]) {
    foreach ($k in @($v.Keys)) { $h[[string]$k] = [string]$v[$k] }
  } else {
    foreach ($pp in @($v.PSObject.Properties)) { $h[[string]$pp.Name] = [string]$pp.Value }
  }
  return $h
}
function Set-BwHistAt($s, $map) {
  if (-not $s) { return }
  Add-Member -InputObject $s NoteProperty hist_at $map -Force
}
# 距这张图上次被换到桌面过了几天; -1 = 不知道(没在名单里 / 没有时间戳)
function Get-BwSeenDays($s, [string]$key, [DateTime]$now) {
  if (-not $key) { return -1 }
  $at = Get-BwHistAt $s
  if (-not $at.ContainsKey([string]$key)) { return -1 }
  $t = Get-BwTime ([string]$at[[string]$key])
  if (-not $t) { return -1 }
  $d = [Math]::Floor(($now - $t).TotalDays)
  if ($d -lt 0) { return 0 }
  return [int]$d
}
# 这张**以前看过**的老图, 现在允许再排进来 / 重新下载吗?
#   约束: 距上次看到至少 $minDays 天; 时间戳不明的用「看过」名单的位置当年龄
#   (只在最近 20 条之外才算老); -AnyAge 用于"库整个空了"的补救(那时有图最重要)。
# 2026-10-09: 判定逻辑抽成"名单 + 时间戳表"的通用版本 —— 聚焦用 state.json 的
# history/hist_at, 其它图源用 sources.json 的 rot 表(键 -> 最近一次换到桌面的时刻),
# 两边走的是**同一段代码**, 口径不会跑偏。外层那个 Test-BwOldImageReusable 保持原签名不变。
function Test-BwOldKeyReusable($seenList, $seenAt, [string]$key, [DateTime]$now, [int]$minDays, [switch]$AnyAge) {
  if (-not $key) { return $false }
  $d = -1
  if ($seenAt -and $seenAt.ContainsKey([string]$key)) {
    $t = Get-BwTime ([string]$seenAt[[string]$key])
    if ($t) {
      $d = [int][Math]::Floor(($now - $t).TotalDays)
      if ($d -lt 0) { $d = 0 }
    }
  }
  if ($d -ge 0) {
    if ($AnyAge) { return ($d -ge 1) }
    return ($d -ge $minDays)
  }
  $h = @($seenList)
  $idx = -1
  for ($i = 0; $i -lt $h.Count; $i++) { if ([string]$h[$i] -eq [string]$key) { $idx = $i; break } }
  if ($idx -ge 0) {
    if ($AnyAge) { return $true }
    return ($idx -lt ([Math]::Max(0, $h.Count - 20)))
  }
  # 名单里也没有 -> 只可能在下载流水里(下过但一次都没轮到看)。库空的时候放行, 平时不放 ——
  # 流水里上千条, 不能凭位置猜年龄。
  return [bool]$AnyAge
}
function Test-BwOldImageReusable($s, [string]$key, [DateTime]$now, [int]$minDays, [switch]$AnyAge) {
  return (Test-BwOldKeyReusable (Get-BwHist $s) (Get-BwHistAt $s) $key $now $minDays -AnyAge:$AnyAge)
}
# 未看过的还剩几张(库里不在「看过」名单里的)。
function Get-BwFreshLeft($s) {
  $seen = @{}
  foreach ($h in @(Get-BwHist $s)) { if ($h) { $seen[[string]$h] = $true } }
  $n = 0
  foreach ($f in @(Get-BwSpotlightAll)) {
    $k = Get-BwNameKey $f.Name
    if ($k -and -not $seen.ContainsKey($k)) { $n++ }
  }
  return $n
}
# 「已看过」文件夹(库上限淘汰时的兜底去处)在哪。系统回收站那部分程序不去翻 ——
# 那要动 Shell COM 的本地化动词, 容易出岔子; 那部分交给"过期重下"兜底。
function Get-BwSeenFolder {
  $c = Get-BwConfig
  $par = Split-Path ([string]$c.spotlight_save_dir) -Parent
  if (-not $par) { return '' }
  return (Join-Path $par '已看过')
}
# 老图回收(本地那条路): 把「已看过」文件夹里够久没出现的老图**直接移回库**, 零网络开销。
# 返回移回来的完整路径数组。不动别人放进去的文件 —— 只认够老的那些(规则见上)。
function Restore-BwRecycledFiles($s, [int]$max, [switch]$AnyAge) {
  $out = @()
  if ($max -le 0) { return $out }
  $d = Get-BwSeenFolder
  if (-not $d -or -not (Test-Path -LiteralPath $d)) { return $out }
  $c = Get-BwConfig
  $now = Get-Date
  $minDays = Get-BwRecycleMinDays $c
  $dir = [string]$c.spotlight_save_dir
  foreach ($f in @(Get-ChildItem -LiteralPath $d -File -Filter *.jpg -ErrorAction SilentlyContinue)) {
    if ($out.Count -ge $max) { break }
    $k = Get-BwNameKey $f.Name
    if (-not $k) { continue }
    if (-not (Test-BwOldImageReusable $s $k $now $minDays -AnyAge:$AnyAge)) { continue }
    $dst = Join-Path $dir $f.Name
    if (Test-Path -LiteralPath $dst) { continue }
    if ($global:BWDry) { Log ('试运行: 本应把「已看过」里的老图移回库 -> ' + $f.Name); continue }
    try {
      Move-Item -LiteralPath $f.FullName -Destination $dst -ErrorAction Stop
      $out += $dst
    } catch { Log ('老图回收: 移回库失败 ' + $f.Name + ' - ' + $_.Exception.Message) }
  }
  if ($out.Count -gt 0) { Log ('老图回收(本地): 从「已看过」移回库里 ' + $out.Count + ' 张 (零下载)') }
  return @($out)
}
# 源池状态(菜单/心跳共用): 三种模式让用户一眼看明白, 别以为程序坏了。
#   还有新图 / 进入老图循环 / 源池已抓到尽头
function Get-BwSourcePoolStatus($s) {
  $c = Get-BwConfig
  $st = Get-BwFetchStats
  $lib = @(Get-BwSpotlightAll).Count
  $fresh = Get-BwFreshLeft $s
  $minDays = Get-BwRecycleMinDays $c
  $mode = 'new'
  $line = ''
  if ([string]$st.mode -eq 'pool_end') {
    $mode = 'pool_end'
    $line = '源池已抓到尽头（本地区 ' + $lib + ' 张 / 未看过 ' + $fresh + ' 张），等官方更新'
    $nx = Get-BwTime ([string]$st.next_try)
    if ($nx) { $line += '；下次尝试 ' + $nx.ToString('MM-dd HH:mm') }
  } elseif ($fresh -lt $global:BWRecycleBelow) {
    $mode = 'recycle'
    $oldest = 0
    $now = Get-Date
    foreach ($f in @(Get-BwSpotlightAll)) {
      $d = Get-BwSeenDays $s (Get-BwNameKey $f.Name) $now
      if ($d -gt $oldest) { $oldest = $d }
    }
    $line = '进入老图循环（未看过只剩 ' + $fresh + ' 张'
    if ($oldest -gt 0) { $line += '；最早 ' + $oldest + ' 天前看过' }
    $line += '；间隔 ≥' + $minDays + ' 天）'
  } else {
    $line = '还有新图（未看过 ' + $fresh + ' 张）'
  }
  return [PSCustomObject]@{ Mode = $mode; Line = $line; Lib = $lib; Fresh = $fresh; ZeroRounds = [int]$st.zero_rounds; NextTry = [string]$st.next_try }
}
# 清空"下过哪些图"的记录(下载流水 + 看过名单 + 时间戳 + 节流账本), 让源池重新可抓。
# 用户 2026-10-09 要求: 默认不执行、执行前二次确认(菜单负责问); **只清记录, 不动图片文件**。
# 用在"我把库清空了/从回收站还原了, 想重新收一遍图"这种场景。
function Reset-BwSourceRecords {
  if ($global:BWDry) { Log '试运行: 本应清空下载记录(重新抓取源池), 本次不执行'; return '' }
  $moved = ''
  if (Test-Path -LiteralPath $global:BWDlLedger) {
    $moved = $global:BWDlLedger + '.cleared-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    try {
      Move-Item -LiteralPath $global:BWDlLedger -Destination $moved -Force -ErrorAction Stop
    } catch {
      Log ('清空下载记录: 流水账改名失败 - ' + $_.Exception.Message)
      return ''
    }
  }
  $s = Get-BwState
  if ($s) {
    $s.history = @()
    Set-BwHistAt $s @{}
    # 这里**故意**用整份写: 目的就是把记录清干净, 不能走 KeepFav(它会跟磁盘上的旧名单取并集)
    Save-BwState $s
  }
  $st = Get-BwFetchStats
  $st.zero_rounds = 0
  $st.mode = 'normal'
  $st.next_try = ''
  $st.day_used = 0
  $st.low_log_day = ''
  Save-BwFetchStats $st
  $lib = @(Get-BwSpotlightAll).Count
  Log ('清空下载记录(重新抓取源池): 下载流水/看过名单已清空(流水留档为 ' + (Split-Path $moved -Leaf) + '), 图片文件一张没动; 库里现有 ' + $lib + ' 张')
  return ('记录已清空（流水留档 ' + (Split-Path $moved -Leaf) + '）；库里现有 ' + $lib + ' 张图一张没动，下次补货会重新从源池里抓。')
}
# ==================== 可插拔图源框架: 与「必应」「聚焦」平级的独立图源 ====================
# 2026-10-09 用户决定: 两个试过的图源出的图不适合当壁纸(多为方形图或超宽长卷, 铺到 16:9 屏上
# 不是裁掉主体就是留两条空), **从产品里摘掉**, 等找到合适的图源再说。
# 但这一整套框架**原样保留** —— 它就是"将来换合适的图源"要用的东西: 加一个源只需在
# Get-BwSourceDefs 里加一条定义, 再补上它的"搜索 / 取图"两个函数(见 Get-BwSrcCandidates /
# Get-BwSrcAsset 的写法), 后面的抓取闸门、记账、菜单、心跳全自动跟上。
# 目前 Get-BwSourceDefs 返回空表, 所以下面这些函数处于"暂未启用"状态(没有任何调用者);
# 代码留着、注释写明, 等合适的图源接上就能用。
#
# 与「必应」「聚焦」**平级**: 各自的抓取函数、各自的库目录(<壁纸根>\<源名>)、
# 各自的去重键与「看过」记录(sources.json)、各自的容量上限。抓取纪律则**完全复用**上面聚焦那一套:
#   · 单轮 <= fetch_round_cap 张、单日 <= fetch_day_cap 张 —— 每个源各记一份账(换天自动归零);
#   · 库到了该源自己的上限就不再补货(补回来也只会挤掉别的图);
#   · 连续 3 轮"新增 0" -> 低频模式: 一天只试一轮, 日志每天一行聚合(不再每轮刷屏);
#   · 老图 >= recycle_min_days 天没参与过轮换 -> 放回轮换(本地零网络); 文件已经不在库里的
#     才允许"过期重下";
#   · -DryRun: 一个请求都不发、一个字节都不写(连 sources.json 都不碰)。
# 记账字段(day / day_used / zero_rounds / mode / next_try / low_log_day)与 fetch_stats.json
# **同名同口径**, 所以 Get-BwFetchBudget / Get-BwFetchAllow / Test-BwFetchDue / Update-BwFetchStats
# 这些现成的纯函数直接拿来用 —— 这就是"复用一套"而不是"另起一套"。
#
# 去重键: 各源自己的 id(用户实测口径), 小写化成"文件名最后一段"(带本源的短前缀),
# 于是与程序原有的 Get-BwNameKey(取最后一段当编号)天然对齐 ——
# 队列、收藏、去重、库容统计这些既有机制对新源的图**自动生效**, 不需要另开一套。
#
# 授权(README / 使用说明里也写了): 图只**下载到用户本机**, 不随发行版打包分发;
# 公版库**逐张校验公版标记**, 非公域的一眼都不看; 图片版权归**原提供方**。
$global:BWSources     = Join-Path $global:BWRoot 'sources.json'
$global:BWSrcSeenMax  = 3000     # 每个源最多记多少条"下过"的键(按时刻淘汰最老的)
$global:BWSrcRotMax   = 400      # 每个源最多记多少条"轮换过"的键
$global:BWSrcMaxBytes = 12MB     # 单张图大小上限: 超过就跳过(有的源条目挂着几十 MB 的原图)
$global:BWSrcUa       = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'

# [暂未启用 —— 等合适的图源] 新图源的静态定义表: **目前是空的**。
# 2026-10-09 用户决定摘除两个试过的图源(出的图不适合当壁纸)之后, 这里不再有任何源;
# 将来找到合适的图源, 只在这里加一条就够: 抓取闸门 / 记账 / 菜单 / 心跳全自动跟上。
# 一条定义要给的字段:
#   Key / Name / DirName : 内部键 / 显示名 / 库目录名(库在 <壁纸根>\<DirName>)
#   EnableKey / KwKey / CapKey / DirKey : 这一源在 config.json 里的开关/关键词/库容上限/库目录键名
#   MinKey / FullKey / MinDef / FullDef : 这个源自己的两道画质线(见 Get-BwSrcWidthCfg)
#   LandscapeOnly / LandscapeAr       : 只收横图(宽高比 >= LandscapeAr)
#   Doc / DefaultKw                   : 界面上的来源说明 / 默认关键词
# 定义照着上面这几行填, 再把这一源的"搜索 / 取图"两个函数接到 Get-BwSrcCandidates /
# Get-BwSrcAsset 上, 即可直接用下面整套抓取与轮换机制。
function Get-BwSourceDefs {
  return @()
}
function Get-BwSrcDef([string]$key) {
  if (-not $key) { return $null }
  foreach ($d in @(Get-BwSourceDefs)) { if ([string]$d.Key -eq [string]$key) { return $d } }
  return $null
}
# 这个源的"最低线 / 满屏线"(像素宽)。0 = 不限。
# 读的是 config 里那两项, 再走一遍数值护栏 —— 手改 config.json 写成离谱的值也一样按夹回后的算。
function Get-BwSrcWidthCfg([psobject]$c, [string]$key, [string]$which) {
  $def = Get-BwSrcDef $key
  if (-not $def) { return 0 }
  if ($which -eq 'full') { $k = [string]$def.FullKey; $dv = [int]$def.FullDef }
  else { $k = [string]$def.MinKey; $dv = [int]$def.MinDef }
  $v = $dv
  try { if ($c -and $c.PSObject.Properties[$k]) { $v = [int]$c.PSObject.Properties[$k].Value } } catch { $v = $dv }
  $r = $global:BwLimit[$k]
  if ($r) {
    if ($v -lt 0) { $v = $r.Def }
    elseif ($v -eq 0) { return 0 }        # 0 = 不限, 明确放行
    elseif ($v -lt $r.Min) { $v = $r.Min }
    elseif ($v -gt $r.Max) { $v = $r.Max }
  }
  if ($v -lt 0) { $v = $dv }
  return $v
}
function Get-BwSrcMinWidth([psobject]$c, [string]$key)  { return (Get-BwSrcWidthCfg $c $key 'min') }
function Get-BwSrcFullWidth([psobject]$c, [string]$key) { return (Get-BwSrcWidthCfg $c $key 'full') }
# 某个源要不要"只收横图"(宽高比 >= 该源定义里的 LandscapeAr)。默认开: 字段不存在 = 开。
# [暂未启用 —— 等合适的图源] 由 Invoke-BwSrcFetch 调用; 表里没有源时不会被走到。
function Get-BwSrcLandscapeOnly([psobject]$c, [string]$key) {
  $def = Get-BwSrcDef $key
  if (-not ($def -and $def.LandscapeOnly)) { return $false }
  if (-not $c) { return $true }
  try {
    $lk = [string]$def.LandscapeKey
    if (-not $lk) { return $true }
    if (-not $c.PSObject.Properties[$lk]) { return $true }
    $v = $c.PSObject.Properties[$lk].Value
    if ($v -is [bool]) { return [bool]$v }
    $s = ([string]$v).Trim().ToLower()
    if (($s -eq 'off') -or ($s -eq 'false') -or ($s -eq '0') -or ($s -eq 'no') -or ($s -eq '关')) { return $false }
    return $true
  } catch { return $true }
}
# 单张下载超时(秒)。必应/聚焦不受影响 —— 它们走的还是写死的 300 秒。
# 0 = 用默认的 20 秒: **不允许"不限"** —— 这里一旦不限, 一张慢图就能把整轮补货卡死,
# 那正是这一批要解决的问题。填 1~4 抬到 5 秒。
# [暂未启用 —— 等合适的图源] 由 Invoke-BwSrcFetch 调用; 值仍在设置里的 [t] 一项里可改。
function Get-BwSrcTimeoutSec([psobject]$c) {
  $v = 20
  try { if ($c -and $c.PSObject.Properties['src_timeout_sec']) { $v = [int]$c.src_timeout_sec } } catch { $v = 20 }
  if ($v -le 0) { return 20 }
  $r = $global:BwLimit['src_timeout_sec']
  if ($r) {
    if ($v -lt $r.Min) { $v = $r.Min }
    if ($v -gt $r.Max) { $v = $r.Max }
  }
  if ($v -lt 5) { $v = 5 }
  return $v
}
# 一个源的"画质门槛"打包成一次调用要用的几个数(抓取处只取一次, 循环里直接用)。
# 宽高比窗口: @{Min=下限; Max=上限}, 0 = 那一边不限。
# [暂未启用 —— 等合适的图源] 这里是"接近 16:9 的横构图"这一口径的默认窗口;
# 实测教训(2026-10-09): 方形图(1.0~1.4)铺 16:9 必裁主体、长卷(2.6~2.9)铺满会留两条空,
# 所以将来接新图源时, 建议把窗口设在 1.5~2.1 附近, 再按那个源的实际出图调。
function Get-BwSrcAspectWindow([psobject]$c) {
  $lo = 1.5; $hi = 2.1
  if ($lo -lt 0) { $lo = 0 }
  if ($hi -lt 0) { $hi = 0 }
  if (($hi -gt 0) -and ($lo -gt $hi)) { $lo = $hi }
  return @{ Min = $lo; Max = $hi }
}
function Get-BwSrcGate([psobject]$c, [string]$key) {
  $minW = Get-BwSrcMinWidth $c $key
  $ar = 0.0
  $def = Get-BwSrcDef $key
  if ($def -and (Get-BwSrcLandscapeOnly $c $key)) { $ar = [double]$def.LandscapeAr }
  # 2026-10-09: 再加一道**比例窗口**(用户要求"只收适合当壁纸的横构图"): 比下限窄的(方图/竖图)
  # 和比上限宽的(长卷)都不要。
  $w = Get-BwSrcAspectWindow $c
  if ($w.Min -gt $ar) { $ar = $w.Min }
  return @{ MinWidth = $minW; MinAspect = $ar; MaxAspect = $w.Max; FullWidth = (Get-BwSrcFullWidth $c $key) }
}
# 源开着没有。2026-10-09 用户要求**默认关**(保持必应+聚焦的原始体验), 字段不存在 = 关;
# 想开就在菜单里对应的那一项打开。
# [暂未启用 —— 等合适的图源] 由轮换 / 浏览 / 库目录那几处调用; 表里没有源时不会被走到。
function Get-BwSrcEnabled([psobject]$c, [string]$key) {
  $def = Get-BwSrcDef $key
  if (-not $def) { return $false }
  if (-not $c) { return $true }
  try {
    if (-not $c.PSObject.Properties[$def.EnableKey]) { return $false }
    $v = $c.PSObject.Properties[$def.EnableKey].Value
    if ($v -is [bool]) { return [bool]$v }
    $s = ([string]$v).Trim().ToLower()
    if (($s -eq 'off') -or ($s -eq 'false') -or ($s -eq '0') -or ($s -eq 'no') -or ($s -eq '关')) { return $false }
    return $true
  } catch { return $true }
}
function Get-BwSrcDir([psobject]$c, [string]$key) {
  $def = Get-BwSrcDef $key
  if (-not ($def -and $c)) { return '' }
  try { if ($c.PSObject.Properties[$def.DirKey]) { return [string]$c.PSObject.Properties[$def.DirKey].Value } } catch {}
  return ''
}
# 这个源自己的库容上限(0 = 不限)。每个源一个独立的上限而不是共用 lib_cap ——
# 各源池子的总量差得很远(聚焦总共 800+ 张, 有的源能到几万张), 共用一个数会让
# "库满不补"的语义在两边都别扭。
# [暂未启用 —— 等合适的图源] 由 Invoke-BwSrcFetch 与状态行调用。
function Get-BwSrcCap([psobject]$c, [string]$key) {
  $def = Get-BwSrcDef $key
  if (-not $def) { return 0 }
  $v = 100
  try { if ($c -and $c.PSObject.Properties[$def.CapKey]) { $v = [int]$c.PSObject.Properties[$def.CapKey].Value } } catch { $v = 100 }
  $r = $global:BwLimit[$def.CapKey]
  if ($r) {
    if ($v -lt 0) { $v = $r.Def }
    elseif ($v -eq 0) { return 0 }
    elseif ($v -lt $r.Min) { $v = $r.Min }
    elseif ($v -gt $r.Max) { $v = $r.Max }
  }
  if ($v -lt 0) { $v = 100 }
  return $v
}
# 关键词: 逗号(中英文都认)分隔的一行。解析与清洗都在这里, 菜单和抓取共用同一个口径:
# 最多 12 个、每个最长 40 字、去重、去空白。
# [暂未启用 —— 等合适的图源] 与关键词相关的这几个函数都留给将来的图源。
function Format-BwSrcKeywords([string]$raw) {
  $out = @()
  $txt = [string]$raw
  if (-not $txt) { return '' }
  foreach ($x in @($txt -split '[,，;；]')) {
    $t = ([string]$x).Trim()
    if (-not $t) { continue }
    if ($t.Length -gt 40) { $t = $t.Substring(0, 40) }
    if (-not ($out -contains $t)) { $out += $t }
    if ($out.Count -ge 12) { break }
  }
  return ($out -join ',')
}
function Get-BwSrcKeywords([psobject]$c, [string]$key) {
  $def = Get-BwSrcDef $key
  if (-not $def) { return @() }
  $raw = ''
  try { if ($c -and $c.PSObject.Properties[$def.KwKey]) { $raw = [string]$c.PSObject.Properties[$def.KwKey].Value } } catch { $raw = '' }
  $txt = Format-BwSrcKeywords $raw
  if (-not $txt) { $txt = Format-BwSrcKeywords ([string]$def.DefaultKw) }
  if (-not $txt) { return @() }
  return @($txt -split ',')
}
function Get-BwSrcFiles([string]$dir) {
  if (-not $dir) { return @() }
  if (-not (Test-Path -LiteralPath $dir)) { return @() }
  return @(Get-ChildItem -LiteralPath $dir -File -Filter *.jpg -ErrorAction SilentlyContinue)
}
# ---- 每个源的记录(sources.json) ---- [暂未启用 —— 等合适的图源]
# 这套记录(seen / rot 与各源的单轮单日记账)是给将来的图源用的: 目前 Get-BwSourceDefs
# 是空表, sources.json 不会被创建, 下面这些函数也不会被走到。
# seen = { 键: 下载时刻 }            永久去重: 下过的不再下(与聚焦"下过就不再下"一个口径)
# rot  = { 键: 最近换到桌面的时刻 }   参与过轮换的记录, 老图回收靠它算间隔
# day/day_used/zero_rounds/mode/next_try/low_log_day: 与 fetch_stats.json 同名字同口径
function Get-BwSrcRecs {
  $o = $null
  if (Test-Path -LiteralPath $global:BWSources) {
    try { $o = Get-Content -LiteralPath $global:BWSources -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $o = $null }
  }
  if (-not $o) { $o = New-Object PSObject }
  return $o
}
function Get-BwSrcRec($o, [string]$key) {
  $def = Get-BwSrcDef $key
  if (-not ($o -and $def)) { return $null }
  $p = $o.PSObject.Properties[$key]
  $isNew = $false
  $r = $null
  if ($p -and $p.Value) { $r = $p.Value } else { $r = New-Object PSObject; $isNew = $true }
  foreach ($pair in @(
      @('seen', @{}), @('rot', @{}), @('day', ''), @('day_used', 0), @('zero_rounds', 0),
      @('last_try', ''), @('last_new', ''), @('next_try', ''), @('mode', 'normal'),
      @('low_log_day', ''), @('recycled', 0), @('kw_i', 0), @('last_err', ''),
      @('slow_until', ''), @('to_streak', 0))) {
    if (-not $r.PSObject.Properties[$pair[0]]) { Add-Member -InputObject $r NoteProperty $pair[0] $pair[1] -Force }
  }
  if ($isNew) { Add-Member -InputObject $o NoteProperty $key $r -Force }
  return $r
}
# JSON 里的对象读回来是 PSCustomObject, 内存里写的是 hashtable —— 统一转成 hashtable 再动。
function Get-BwSrcMap($v) {
  $h = @{}
  if (-not $v) { return $h }
  if ($v -is [System.Collections.IDictionary]) {
    foreach ($k in @($v.Keys)) { $h[[string]$k] = [string]$v[$k] }
  } else {
    try { foreach ($pp in @($v.PSObject.Properties)) { $h[[string]$pp.Name] = [string]$pp.Value } } catch {}
  }
  return $h
}
# 回写一张表 + 按上限裁剪(读不出时刻的当最老, 先淘汰)
function Set-BwSrcMap($rec, [string]$name, $map, [int]$max) {
  if (-not $rec) { return }
  if (-not $map) { $map = @{} }
  if (($max -gt 0) -and ($map.Count -gt $max)) {
    $keys = @($map.Keys | Sort-Object -Property { $t = Get-BwTime ([string]$map[$_]); if ($t) { $t } else { [datetime]'2000-01-01' } })
    $drop = $map.Count - $max
    for ($i = 0; $i -lt $drop; $i++) { [void]$map.Remove([string]$keys[$i]) }
  }
  Add-Member -InputObject $rec NoteProperty $name $map -Force
}
function Save-BwSrcRecs($o) {
  # -DryRun: 连记录都不写(与既有口径一致: 试运行不许有任何副作用)
  if ($global:BWDry) { return }
  if (-not $o) { return }
  [void](Save-BwJsonAtomic $global:BWSources $o)
}
# 这张"以前下过"的老图, 现在允许重新下吗: 距它上次换到桌面 >= minDays 天。
# 从没轮换过的键由调用方先按"库里还有没有文件"筛过, 到这里只剩 -AnyAge(库空了)才放行。
function Test-BwSrcKeyReusable($rec, [string]$key, [DateTime]$now, [int]$minDays, [switch]$AnyAge) {
  if (-not ($rec -and $key)) { return $false }
  $rot = Get-BwSrcMap $rec.rot
  if (-not $rot.ContainsKey([string]$key)) { return [bool]$AnyAge }
  $t = Get-BwTime ([string]$rot[[string]$key])
  if (-not $t) { return [bool]$AnyAge }
  $d = [Math]::Floor(($now - $t).TotalDays)
  if ($d -lt 0) { $d = 0 }
  if ($AnyAge) { return ($d -ge 1) }
  return ($d -ge $minDays)
}
# 老图回收(本地那条路, 零网络): 某个源"还没轮到过"的图不足 20 张时, 把 >= minDays 天
# 没轮换过的键从 rot 里摘掉 —— 它们立刻回到队列里。文件本来就在库里, 不需要下载任何东西。
function Update-BwSrcRotRecycle($rec, $haveKeys, [DateTime]$now, [int]$minDays, $def) {
  if (-not $rec) { return 0 }
  $rot = Get-BwSrcMap $rec.rot
  $fresh = 0
  if ($haveKeys) { foreach ($k in @($haveKeys.Keys)) { if (-not $rot.ContainsKey([string]$k)) { $fresh++ } } }
  if ($fresh -ge $global:BWRecycleBelow) { return 0 }
  $drop = @()
  foreach ($k in @($rot.Keys)) {
    $t = Get-BwTime ([string]$rot[$k])
    if (-not $t) { $drop += $k; continue }
    if ((($now - $t).TotalDays) -ge $minDays) { $drop += $k }
  }
  if ($drop.Count -eq 0) { return 0 }
  foreach ($k in $drop) { [void]$rot.Remove([string]$k) }
  Set-BwSrcMap $rec 'rot' $rot $global:BWSrcRotMax
  $nm = '图源'
  if ($def) { $nm = [string]$def.Name }
  Log ($nm + ' 老图回收: 没轮到过的只剩 ' + $fresh + ' 张(<' + $global:BWRecycleBelow + '), 把 ' + $drop.Count + ' 张 >= ' + $minDays + ' 天没出现过的老图放回轮换(零下载)')
  return $drop.Count
}
# 源池抓到尽头时的聚合日志(每天最多一行) —— 与聚焦那条 Write-BwPoolEndLine 一个口径。
# 注意: 本函数只改传进来的记录, 落盘由调用方负责(它同时也负责整份记录的写回)。
function Write-BwSrcPoolEndLine($def, $rec, [string]$dir, [bool]$Quiet) {
  if (-not ($def -and $rec)) { return }
  $today = (Get-Date).ToString('yyyy-MM-dd')
  if ([string]$rec.low_log_day -eq $today) { return }
  $rec.low_log_day = $today
  $line = [string]$def.Name + ' 源池已抓到尽头（本地 ' + @(Get-BwSrcFiles $dir).Count + ' 张），等官方更新；下次尝试 ' + (Format-BwTryTime ([string]$rec.next_try))
  Log $line
  if (-not $Quiet) { Write-Host ('  ' + $line) -ForegroundColor DarkGray }
}
# ---- 文件名与去重键 ----
# 文件名: 日期_标题(<=28字)_哈希_键.jpg。最后一段就是去重键 —— Get-BwNameKey 取的就是它,
# 所以队列、收藏、「看过」名单、库容统计这些既有机制对新源的图自动生效。
function Get-BwSrcKeyToken([string]$key, [string]$id) {
  $s = ([string]$id).ToLower() -replace '[^a-z0-9]', ''
  if ($s.Length -lt 4) { $s = $s + (Get-BwHash ([string]$id)).Substring(0, 6) }
  $tk = ([string]$key) + $s
  if ($tk.Length -lt 8) { $tk = $tk + (Get-BwHash ($key + '|' + $id)).Substring(0, 8) }
  return $tk
}
function Get-BwSrcName([string]$key, [string]$token, [string]$title, [string]$url) {
  $t = ([string]$title) -replace '[\\/:*?"<>|\s？：＊＜＞｜]', ''
  if ($t.Length -gt 28) { $t = $t.Substring(0, 28) }
  if (-not $t) { $t = 'wallpaper' }
  return ('{0}_{1}_{2}_{3}.jpg' -f (Get-Date -Format 'yyyy-MM-dd'), $t, (Get-BwHash ($key + '|' + $url)), $token)
}
# ---- 图源的"搜索 / 取图"两个钩子 (新图源要接的两个函数) ----
# [暂未启用 —— 等合适的图源] 目前 Get-BwSourceDefs 是空表, 这两个函数不会被调用。
# 加新图源时照下面这个形状写:
#   Get-BwSrcCandidates $key $kw -> 返回候选数组, 每条至少要有 id(去重键) 与 title; 需要再取一次
#                                  接口才拿得到图片地址的源, 可以在这里顺手带上 href 之类的中间信息。
#   取图那一侧 -> 由候选返回 @{ url = 图片直链; title = 标题; link = 详情页; copy = 版权说明 }
#                 (挑不到图就返回 $null, 抓取循环会当成"这一条跳过"继续下一条)。
# 下面两个函数就是这两个钩子的分发点: 一个源一个分支即可。
function Get-BwSrcCandidates([string]$key, [string]$kw) {
  return @()
}
function Get-BwSrcAsset([string]$key, $item) {
  return $null
}
# ---- 本地文件夹图源 (2026-10-24 UI 整改新增) ----
# 用户自己指定一个文件夹当图源: 里面的图**不搬、不复制、不删**, 只把文件名排进轮换队列。
# 没设置(默认空串)时下面这些函数一律返回空, 老用户的行为一个字节都不变。
# 先不做目录监听(FileSystemWatcher): 换图时才现场扫目录, 简单、也没有句柄泄漏的风险;
# 所以"往文件夹里新丢一张图"要等到下一次换图(或面板上点「重新扫一遍」)才会进队列。
function Get-BwLocalDir([psobject]$c) {
  if (-not $c) { return '' }
  $d = ''
  try { if ($c.PSObject.Properties['local_src_dir']) { $d = [string]$c.local_src_dir } } catch { $d = '' }
  $d = $d.Trim()
  if (-not $d) { return '' }
  try {
    if (-not (Test-Path -LiteralPath $d -PathType Container)) { return '' }
  } catch { return '' }
  return $d
}
# 本地图源里能当壁纸的文件(只认 Windows 换壁纸接口支持的那几种格式: jpg/jpeg/png/bmp)。
# 带一句进程内缓存: Get-BwRotPool 在一次换图里会被调好几次, 不缓存会把同一个目录连扫好几遍。
function Get-BwLocalFiles([psobject]$c, [switch]$Force) {
  $dir = Get-BwLocalDir $c
  if (-not $dir) { return @() }
  $now = Get-Date
  $key = $dir.ToLower()
  if ((-not $Force) -and $global:BWLocalCache -and $global:BWLocalCache.ContainsKey($key)) {
    try {
      $ce = $global:BWLocalCache[$key]
      if (((($now) - [datetime]$ce['At']).TotalSeconds) -lt 3) { return @($ce['Files']) }
    } catch {}
  }
  $files = @()
  try {
    $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
               Where-Object { Test-BwWallFile $_.Name } | Sort-Object Name)
  } catch { $files = @() }
  if (-not $global:BWLocalCache) { $global:BWLocalCache = @{} }
  $global:BWLocalCache[$key] = @{ At = $now; Files = @($files) }
  return @($files)
}
# ---- 与既有机制的接合点 ----
# 队列里只存文件名, 图可能在四个库里的任何一个: 按文件名挨个找。
function Find-BwWallFile([psobject]$c, [string]$name) {
  if (-not ($c -and $name)) { return '' }
  $dirs = @([string]$c.spotlight_save_dir, [string]$c.bing_save_dir)
  $ld = Get-BwLocalDir $c
  if ($ld) { $dirs += $ld }
  foreach ($def in @(Get-BwSourceDefs)) {
    if (-not (Get-BwSrcEnabled $c $def.Key)) { continue }
    $d = Get-BwSrcDir $c $def.Key
    if ($d) { $dirs += $d }
  }
  foreach ($d in $dirs) {
    if (-not $d) { continue }
    $p = Join-Path $d $name
    if (Test-Path -LiteralPath $p) { return $p }
  }
  return ''
}
# 参与轮换的图池 = 聚焦库 + 开着的新图源库。
# (必应库**也**进队列 —— 由 Get-BwFreshQueue 组装队列时并进来, 2026-10-10 晚起按"永远按最旧优先"排;
#  本函数只管聚焦与新图源那部分。必应那条"每日一图"另走 Invoke-BwCycle 规则 1, 与队列无关。)
function Get-BwRotPool {
  $c = Get-BwConfig
  $out = @(Get-BwSpotlightAll)
  foreach ($def in @(Get-BwSourceDefs)) {
    if (-not (Get-BwSrcEnabled $c $def.Key)) { continue }
    $out += @(Get-BwSrcFiles (Get-BwSrcDir $c $def.Key))
  }
  # 2026-10-24: 本地文件夹图源也进轮换池。没设置这个图源时 Get-BwLocalFiles 返回空数组,
  # 对老用户等于没加这一行 —— 轮换顺序、队列、收藏全都不受影响。
  $out += @(Get-BwLocalFiles $c)
  return @($out)
}
# 一张图真的换到桌面了 -> 记进它所属源名下的 rot 表(老图回收靠它算间隔)。
# 不是新图源的图就什么都不做; 写盘走原子写; -DryRun 一个字都不写。
function Add-BwSrcRot([string]$path) {
  if ($global:BWDry) { return }
  if (-not $path) { return }
  try {
    $dir = ''
    try { $dir = ([string](Split-Path $path -Parent)).TrimEnd('\') } catch { return }
    $key = Get-BwNameKey (Split-Path $path -Leaf)
    if (-not ($dir -and $key)) { return }
    $c = Get-BwConfig
    foreach ($def in @(Get-BwSourceDefs)) {
      if (-not (Get-BwSrcEnabled $c $def.Key)) { continue }
      $d = Get-BwSrcDir $c $def.Key
      if (-not $d) { continue }
      if (([string]$d).TrimEnd('\').ToLower() -ne $dir.ToLower()) { continue }
      $all = Get-BwSrcRecs
      $rec = Get-BwSrcRec $all $def.Key
      $rot = Get-BwSrcMap $rec.rot
      $rot[[string]$key] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
      Set-BwSrcMap $rec 'rot' $rot $global:BWSrcRotMax
      Save-BwSrcRecs $all
      return
    }
  } catch { }
}
# 状态行(菜单 / 设置页共用): 一眼看出开着没有、库里有几张、现在处于哪种模式。
function Get-BwSrcStatusLine([string]$key) {
  $def = Get-BwSrcDef $key
  if (-not $def) { return '' }
  $c = Get-BwConfig
  $on = '关'
  if (Get-BwSrcEnabled $c $key) { $on = '开' }
  $dir = Get-BwSrcDir $c $key
  $files = @(Get-BwSrcFiles $dir)
  $cap = Get-BwSrcCap $c $key
  $capTxt = '不限'
  if ($cap -gt 0) { $capTxt = ($cap.ToString() + ' 张') }
  $rot = @{}
  $mode = '还有新图'
  try {
    $rec = Get-BwSrcRec (Get-BwSrcRecs) $key
    $rot = Get-BwSrcMap $rec.rot
    if ([string]$rec.mode -eq 'pool_end') { $mode = '已抓到尽头' }
  } catch {}
  $fresh = 0
  foreach ($f in $files) {
    $k = Get-BwNameKey $f.Name
    if ($k -and -not $rot.ContainsKey([string]$k)) { $fresh++ }
  }
  if (($mode -ne '已抓到尽头') -and ($fresh -lt $global:BWRecycleBelow)) { $mode = '老图循环' }
  # 2026-10-09: 画质门槛也摆在状态行里 —— 用户一眼能看到"这个源收图的两道线"。
  # 0 显示成"不限"(那道线不生效), 与菜单里填 0 的含义一致。
  $minW = Get-BwSrcMinWidth $c $key
  $fullW = Get-BwSrcFullWidth $c $key
  $minTxt = '不限'
  if ($minW -gt 0) { $minTxt = ('>=' + $minW) }
  $fullTxt = '不限'
  if ($fullW -gt 0) { $fullTxt = ('>=' + $fullW) }
  $gateTxt = ' · 门槛 ' + $minTxt + '(进库) / ' + $fullTxt + '(铺满)'
  if (Get-BwSrcLandscapeOnly $c $key) { $gateTxt += ' · 只收横图' }
  return ([string]$def.Name + ' ' + $on + ' · 库 ' + $files.Count + ' / ' + $capTxt + $gateTxt + ' · 没轮到过 ' + $fresh + ' 张 · ' + $mode)
}
# ---- 单个源的抓取 ----
# 与 Invoke-SpotlightFetch 同一套闸门与记账, 但**单源独立**: 一个源失败只写一行日志,
# 不影响别的源、更不影响换图(失败隔离)。
function Invoke-BwSrcFetch([string]$key, [int]$count, [switch]$Quiet, [switch]$Force, [switch]$IgnoreCap) {
  # -Force     : 不受"自动补新图"开关限制(用户明确要求 / 恢复模式)
  # -IgnoreCap : 不受这个源的库容上限限制(只有"库整个空了"的补救路径才传)
  $out = @()
  $def = Get-BwSrcDef $key
  if (-not $def) { return @() }
  # 试运行: 连搜索请求都不发, 也不写 sources.json
  if ($global:BWDry) {
    Log ('试运行: 本应抓取 ' + [string]$def.Name + ' 图(最多 ' + $count + ' 张), 不发请求、不下载、不写账本')
    return @()
  }
  try {
    $c = Get-BwConfig
    if (-not (Get-BwSrcEnabled $c $key)) {
      Log ([string]$def.Name + ' 源已关闭(设置里可开), 跳过')
      return @()
    }
    $dir = Get-BwSrcDir $c $key
    if (-not $dir) { Log ([string]$def.Name + ' 源没有配置库目录, 跳过'); return @() }
    [void](New-BwDir $dir)
    $now = Get-Date
    $all = Get-BwSrcRecs
    $rec = Get-BwSrcRec $all $key
    # 低频模式(源池抓到尽头): 一天只放行一轮, 其余轮次不发任何请求, 日志每天一行
    if (-not (Test-BwFetchDue $rec $now)) {
      Write-BwSrcPoolEndLine $def $rec $dir $Quiet.IsPresent
      Save-BwSrcRecs $all
      return @()
    }
    # 慢源退避(2026-10-09): 上一轮这个源连着超时过 -> 在退避时间到达之前一轮都不碰它。
    # 实测有的图床能慢到 ~130 秒/张, 连着超时的时段里硬试只是白等; 别的源照常抓。
    $slowUntil = Get-BwTime ([string]$rec.slow_until)
    if ($slowUntil -and ($now -lt $slowUntil)) {
      Log ([string]$def.Name + ' 源在超时退避中(到 ' + $slowUntil.ToString('yyyy-MM-dd HH:mm') + '), 本轮跳过, 不影响其它源')
      if (-not $Quiet) { Write-Host ('  ' + [string]$def.Name + ' 上轮连续超时, 退避到 ' + $slowUntil.ToString('HH:mm') + ', 本轮跳过') -ForegroundColor DarkGray }
      return @()
    }
    if ($slowUntil -and ($now -ge $slowUntil)) { $rec.slow_until = '' }   # 退避期满, 清掉记号
    $cap = Get-BwSrcCap $c $key
    $have = @(Get-BwSrcFiles $dir)
    $haveKeys = @{}
    foreach ($f in $have) {
      $k = Get-BwNameKey $f.Name
      if ($k) { $haveKeys[[string]$k] = $true }
    }
    # 库满不补: 到了该源自己的上限就不再下载(下回来也只会挤掉别的图, 白费源池)。
    # 只有 -IgnoreCap(库整个空了、有图最重要)才穿透这道闸; 菜单里的手动抓取不算。
    if (($cap -gt 0) -and ($have.Count -ge $cap) -and (-not $IgnoreCap)) {
      Log ([string]$def.Name + ' 源库已满(' + $have.Count + '/' + $cap + ' 张), 不再补货, 源池留着慢慢用')
      return @()
    }
    # 与聚焦那条一样: 自动补新图关着时只在"库还是空的"这种异常情况下才自动抓
    if (-not ($c.auto_fetch -or $Force -or ($have.Count -eq 0))) {
      Log ([string]$def.Name + ' 源跳过: 自动补新图关着, 且库里已有 ' + $have.Count + ' 张(不动现有这些图)')
      return @()
    }
    # 老图回收(零网络): 没轮到过的不足 20 张 -> 把够久没出现过的键放回轮换
    $minDays = Get-BwRecycleMinDays $c
    [void](Update-BwSrcRotRecycle $rec $haveKeys $now $minDays $def)
    # 单轮 / 单日闸门(与聚焦共用同一组配置与同一段函数)
    $allow = Get-BwFetchAllow $c $rec $count
    if ($allow -le 0) {
      $capTxt = '20'
      try { $capTxt = [string][int]$c.fetch_day_cap } catch {}
      Log ([string]$def.Name + ' 抓取: 今天的额度已经用完(' + [int]$rec.day_used + '/' + $capTxt + ' 张), 这一轮不下载(源池留着慢慢用)')
      if (-not $Quiet) { Write-Host ('  ' + [string]$def.Name + ' 今天已经抓过 ' + [int]$rec.day_used + ' 张了(每日上限 ' + $capTxt + ' 张), 源池留着慢慢用。') -ForegroundColor DarkGray }
      return @()
    }
    if ($allow -lt $count) {
      Log ([string]$def.Name + ' 抓取: 按上限把这一轮从 ' + $count + ' 张收到 ' + $allow + ' 张')
      if (-not $Quiet) { Write-Host ('  ' + [string]$def.Name + ' 按上限收成 ' + $allow + ' 张') -ForegroundColor DarkGray }
    }
    $count = $allow
    $kws = @(Get-BwSrcKeywords $c $key)
    if ($kws.Count -eq 0) { Log ([string]$def.Name + ' 没有可用关键词, 跳过'); return @() }
    $ran = $true
    $ok = 0; $skip = 0; $fail = 0; $tries = 0; $reuse = 0
    # 2026-10-09 画质门槛 + 慢源: $qskip = 被门槛筛掉的张数(不算失败, 是"这张不合用"),
    # $toStreak = 这个源连续超时了几张(连着 2 张就本轮不再取它)。
    $qskip = 0; $toStreak = 0
    $toSec = Get-BwSrcTimeoutSec $c
    $gate = Get-BwSrcGate $c $key
    $seenMap = Get-BwSrcMap $rec.seen
    $ki = 0
    try { $ki = [int]$rec.kw_i } catch { $ki = 0 }
    if ($ki -lt 0) { $ki = 0 }
    # 一轮最多用掉"每个关键词一批候选": 候选翻完就换下一个关键词, 全翻完就收工 ——
    # 不会在一个词上空转, 也不会把同一个搜索请求打十几遍。
    $cands = @()
    $usedKw = 0
    $maxTries = [Math]::Max($count * 6, 24)
    while (($ok -lt $count) -and ($tries -lt $maxTries) -and ($usedKw -le $kws.Count)) {
      if ($cands.Count -eq 0) {
        if ($usedKw -ge $kws.Count) { break }
        $kw = [string]$kws[($ki + $usedKw) % $kws.Count]
        $cands = @(Get-BwSrcCandidates $key $kw)
        $usedKw++
        if ($cands.Count -eq 0) {
          $fail++
          if (-not $Quiet) { Write-Host ('  ' + [string]$def.Name + ' 「' + $kw + '」没拿到候选') -ForegroundColor DarkGray }
          Start-Sleep -Milliseconds 400
          continue
        }
      }
      $cd = $cands[0]
      $cands = @($cands | Select-Object -Skip 1)
      $tries++
      $token = Get-BwSrcKeyToken $key ([string]$cd.id)
      if (-not $token) { continue }
      if ($haveKeys.ContainsKey([string]$token)) { $skip++; Start-Sleep -Milliseconds 300; continue }
      $isReuse = $false
      if ($seenMap.ContainsKey([string]$token)) {
        # 以前下过(永久去重)。只有"够久没出现过、而且本地文件已经不在"才允许过期重下。
        if (Test-BwSrcKeyReusable $rec $token $now $minDays -AnyAge:($have.Count -eq 0)) { $isReuse = $true }
        else { $skip++; Start-Sleep -Milliseconds 300; continue }
      }
      $asset = Get-BwSrcAsset $key $cd
      if (-not ($asset -and $asset.url)) { $fail++; Start-Sleep -Milliseconds 400; continue }
      $path = Join-Path $dir (Get-BwSrcName $key $token ([string]$asset.title) ([string]$asset.url))
      $m = @{ date=(Get-Date -Format 'yyyy-MM-dd'); title=[string]$asset.title; copyright=[string]$asset.copy;
              source_type=[string]$def.Name; source_url=[string]$asset.url; source_link=[string]$asset.link }
      # 单张下载: 超时 $toSec 秒(默认 20, 可配), 宽度不到门槛 / 宽高比不达标的不落盘。
      # 真实分辨率由 Save-BwFile 用 System.Drawing 量, 写进日志与图片元数据。
      # -TotalDeadline: 新图源走"总时长硬期限"(慢图床到点就放弃), 必应/聚焦那条路不传这个开关。
      $got = Save-BwFile -urls @([string]$asset.url) -path $path -meta $m -MaxBytes $global:BWSrcMaxBytes `
                          -TimeoutSec $toSec -MinWidth ([int]$gate.MinWidth) -MinAspect ([double]$gate.MinAspect) -MaxAspect ([double]$gate.MaxAspect) -TotalDeadline
      $dlSt = [string]$global:BWLastDlStatus
      if ($got) {
        $ok++
        $toStreak = 0
        if ($isReuse) { $reuse++ }
        $out += $path
        $seenMap[[string]$token] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $haveKeys[[string]$token] = $true
        if (-not $Quiet) { Write-Host ('    OK  [' + [string]$def.Name + '] ' + (Split-Path $path -Leaf) + '  ' + (Get-BwImageDim $path)) }
      } elseif (($dlSt -eq 'toosmall') -or ($dlSt -eq 'aspect') -or ($dlSt -eq 'toobig')) {
        # 画质门槛筛掉的: 不是网络失败, 是"这张不合用"。单独记一笔, 日志里分得清。
        $qskip++
        $skip++
        $toStreak = 0
        if (-not $Quiet) { Write-Host ('    跳过 [' + [string]$def.Name + '] ' + $dlSt + ' ' + [string]$asset.title) -ForegroundColor DarkGray }
      } elseif ($dlSt -eq 'timeout') {
        $fail++
        $toStreak++
        if ($toStreak -ge 2) {
          # 同一个源连着两张都超时 -> 这个源本轮不再取它。图床慢的时候硬等只会把整轮
          # 拖成几十分钟, 后面的源全被挡住; 退避一会儿再来。别的源一点都不受影响。
          $rec.to_streak = $toStreak
          $rec.slow_until = $now.AddMinutes($global:BWSrcSlowMinutes).ToString('yyyy-MM-dd HH:mm:ss')
          $rec.last_err = ('连续 ' + $toStreak + ' 张下载超时(' + $toSec + ' 秒/张)')
          Log ([string]$def.Name + ' 连续 ' + $toStreak + ' 张下载超时(' + $toSec + ' 秒/张) -> 本轮不再取它, 退避 ' +
               $global:BWSrcSlowMinutes + ' 分钟(到 ' + $now.AddMinutes($global:BWSrcSlowMinutes).ToString('HH:mm') + '); 其它源不受影响') 'WARN'
          if (-not $Quiet) { Write-Host ('    ' + [string]$def.Name + ' 连着超时 ' + $toStreak + ' 张, 本轮不再取它(退避 ' + $global:BWSrcSlowMinutes + ' 分钟)') -ForegroundColor Yellow }
          break
        }
      } else {
        $fail++
        $toStreak = 0
      }
      Start-Sleep -Milliseconds 400
    }
    $rec.kw_i = (($ki + $usedKw) % $kws.Count)
    $rec.to_streak = $toStreak
    Set-BwSrcMap $rec 'seen' $seenMap $global:BWSrcSeenMax
    # 记账走聚焦那套纯函数: 单日额度 / 空轮计数 / 低频模式切换
    # (门槛筛掉的算进 $skip: 那一轮"见到了图但一张都没用上"就是源池到头的信号,
    #  连续 3 轮就该转低频, 不该为了翻过一堆小图每轮都跑满 —— 这是省流量也是省时间)
    Update-BwFetchStats $rec $ok $skip $fail $tries $ran $now | Out-Null
    Save-BwSrcRecs $all
    $extra = ''
    if ($reuse -gt 0) { $extra = ', 回收老图 ' + $reuse + ' 张' }
    if ($qskip -gt 0) { $extra += ', 画质门槛筛掉 ' + $qskip + ' 张(宽<' + [int]$gate.MinWidth + ' 或比例不在 ' + [double]$gate.MinAspect + '~' + [double]$gate.MaxAspect + ' 之间)' }
    if (($ok -eq 0) -and ($skip -eq 0) -and ($tries -eq 0)) {
      Log ([string]$def.Name + ' 抓取: 一个候选都没拿到(网络或接口异常, 不影响别的源)') 'WARN'
    } elseif ([string]$rec.mode -eq 'pool_end') {
      if ([string]$rec.low_log_day -eq $now.ToString('yyyy-MM-dd')) {
        Log ([string]$def.Name + ' 抓取(低频模式): 新增' + $ok + ' 跳过' + $skip + ' 失败' + $fail + $extra + '；下次尝试 ' + (Format-BwTryTime ([string]$rec.next_try)))
      } else {
        Write-BwSrcPoolEndLine $def $rec $dir $Quiet.IsPresent
        Save-BwSrcRecs $all
      }
    } else {
      Log ([string]$def.Name + ' 抓取: 新增' + $ok + ' 跳过' + $skip + ' 失败' + $fail + $extra)
    }
    if (-not $Quiet) { Write-Host ('  完成 [' + [string]$def.Name + ']: 新增 ' + $ok + ', 已存在 ' + $skip + ', 失败 ' + $fail + $extra) }
    return @($out)
  } catch {
    # 失败隔离: 单个源出任何问题(网络 / 解析 / 写盘)都只写一行日志
    Log ([string]$def.Name + ' 源抓取异常(不影响其它源与换图): ' + $_.Exception.Message) 'WARN'
    return @($out)
  }
}
# 逐源抓取: 每个源各自独立, 谁失败都不影响谁。
# [暂未启用 —— 等合适的图源] Get-BwSourceDefs 是空表时, 这里就是个空循环(不发任何请求)。
function Invoke-BwAllSrcFetch([int]$count, [switch]$Quiet, [switch]$Force, [switch]$IgnoreCap) {
  $out = @()
  if ($count -le 0) { return $out }
  foreach ($def in @(Get-BwSourceDefs)) {
    try { $out += @(Invoke-BwSrcFetch -key $def.Key -count $count -Quiet:$Quiet -Force:$Force -IgnoreCap:$IgnoreCap) }
    catch { Log ([string]$def.Name + ' 图源异常(不影响其它源与换图): ' + $_.Exception.Message) 'WARN' }
  }
  return @($out)
}
# 【2026-10-10 修·由用户提问引出】老图循环应当"最早看过的先回来", 而不是洗牌。
#
# 用户原话:「**既然是老图循环, 为什么不从最早的图片开始循环呢**」
# 原来的行为: 回收的老图走 Get-BwBalancedOrder 洗牌; 而且"库里全看过、又没一张
# 够回收间隔"时会走「历史清零重来」分支, 把整库重新洗一遍 —— 于是同一张图两次
# 出现的间隔**忽长忽短**(平均 35 小时 = 70 张 x 30 分钟, 但有的 1 小时就撞回来)。
# 用户就是这么发现"这张壁纸怎么又出现了"的。
#
# 现在: 按"上次看过"从**最早到最近**排 —— 间隔被拉到最大而且均等。
# 时间戳不明的(Get-BwSeenDays 返回 -1)按"很老"处理排在最前: 它们本来就是靠
# Test-BwOldImageReusable 的"名单位置(最近 20 条之外)"判定为老的。
function Get-BwOldestFirst($s, [string[]]$names, [DateTime]$now) {
  $list = @($names | Where-Object { $_ })
  if ($list.Count -le 1) { return @($list) }
  $tmp = @($list | ForEach-Object {
    $d = -1
    try { $d = Get-BwSeenDays $s (Get-BwNameKey $_) $now } catch { $d = -1 }
    $age = 99999                      # 时间戳不明 -> 当"很老", 排最前
    if ($d -ge 0) { $age = $d }
    [pscustomobject]@{ Name = $_; Age = $age }
  } | Sort-Object -Property @{ Expression = { $_.Age }; Descending = $true },
                            @{ Expression = { $_.Name }; Descending = $false })
  return @($tmp | ForEach-Object { $_.Name })
}
# 2026-10-09 轮换均衡(用户要求"四个源轮流出现, 别让某源霸屏或缺席"):
# 纯随机洗牌在库容悬殊时很难看 —— 比如一类 100 张、另一类 6 张, 随机排出来经常
# "连着七八张都是同一类"或者"张数少的那类大半天没露面"。
# 做法: 先按来源分组、每组自己洗牌, 再**轮流从每组抽一张**;
# 起点每轮往后挪一格, 所以也不会永远是同一个源打头。张数少的源因此能均匀插在整个队列里。
function Get-BwBalancedOrder([string[]]$names, [int]$turn) {
  $list = @($names | Where-Object { $_ })
  if ($list.Count -le 1) { return @($list) }
  $c = $null
  try { $c = Get-BwConfig } catch { $c = $null }
  $srcOf = @{}
  $keys = @()
  try {
    foreach ($f in @(Get-BwSpotlightAll)) { $srcOf[[string]$f.Name] = 'spot' }
    $keys += 'spot'
    foreach ($def in @(Get-BwSourceDefs)) {
      $d = Get-BwSrcDir $c $def.Key
      if (-not $d) { continue }
      $keys += [string]$def.Key
      foreach ($f in @(Get-BwSrcFiles $d)) { $srcOf[[string]$f.Name] = [string]$def.Key }
    }
  } catch { }
  $keys += 'other'
  $buckets = @{}
  foreach ($k in $keys) { $buckets[$k] = @() }
  foreach ($n in $list) {
    $k = 'other'
    if ($srcOf.ContainsKey([string]$n)) { $k = [string]$srcOf[[string]$n] }
    $buckets[$k] = @($buckets[$k]) + @($n)
  }
  foreach ($k in @($buckets.Keys)) {
    if (@($buckets[$k]).Count -gt 1) { $buckets[$k] = @($buckets[$k] | Sort-Object { Get-Random }) }
  }
  $n0 = @($keys).Count
  if ($n0 -le 0) { return @($list) }
  $idx = [Math]::Abs($turn) % $n0
  $maxLen = 0
  foreach ($k in $keys) { if (@($buckets[$k]).Count -gt $maxLen) { $maxLen = @($buckets[$k]).Count } }
  $order = @()
  for ($i = 0; $i -lt $maxLen; $i++) {
    for ($j = 0; $j -lt $n0; $j++) {
      $kk = $keys[($idx + $j) % $n0]
      $arr = @($buckets[$kk])
      if ($i -lt $arr.Count) { $order += $arr[$i] }
    }
  }
  if ($order.Count -lt $list.Count) {
    # 有文件不属于任何已知目录(理论上不该发生): 剩下的照原样补在队尾, 一张都不能丢
    $got = @{}
    foreach ($o in $order) { $got[[string]$o] = $true }
    foreach ($n in $list) { if (-not $got.ContainsKey([string]$n)) { $order += $n } }
  }
  return @($order)
}

# 2026-10-23 用户要求: 「现在必应和聚焦的新图片比较多, 是否轮换切换?」-> 「改」。
# 改之前: 队列是**全局**按"最旧优先"排的, 于是 1109 张 2020-2023 的必应老图全排在前面,
# 205 张 2026 年的聚焦新图要等约 23 天才轮到 —— 库越大越明显。
# 现在: **每个来源内部仍按原来的"最旧优先"**, 来源之间**按各自张数比例均匀穿插**
# (1109 : 205 ≈ 每 6 张里 1 张聚焦)。这样两边的完整轮回时长也基本一样(都约 3 周),
# 既不会"新图老也轮不到", 也不会让某一个来源霸屏。
# 算法用"平滑加权轮转"(smooth weighted round-robin): 每步给每个还没出完的组加上它自己的
# 权重, 取权重最大的那组出一张, 再减掉总权重 —— 出来的比例平稳, 不会成段扎堆。
function Merge-BwQueueBySource([string[]]$ordered) {
  $list = @($ordered | Where-Object { $_ })
  if ($list.Count -le 2) { return @($list) }
  $c = $null
  try { $c = Get-BwConfig } catch { $c = $null }
  # 每张图属于哪个来源 —— 认不出来的一律算 other(照原顺序排在最后)
  $srcOf = @{}
  try {
    foreach ($f in @(Get-BwSpotlightAll)) { $srcOf[[string]$f.Name] = 'spot' }
    foreach ($def in @(Get-BwSourceDefs)) {
      $d = Get-BwSrcDir $c $def.Key
      if (-not $d) { continue }
      foreach ($f in @(Get-BwSrcFiles $d)) { $srcOf[[string]$f.Name] = [string]$def.Key }
    }
    foreach ($f in @(Get-BwBingAll)) { $srcOf[[string]$f.Name] = 'bing' }
  } catch { }
  $keys = @('spot', 'bing', 'other')
  try { foreach ($def in @(Get-BwSourceDefs)) { if ($keys -notcontains [string]$def.Key) { $keys += [string]$def.Key } } } catch { }
  $bucket = @{}
  foreach ($k in $keys) { $bucket[$k] = New-Object System.Collections.ArrayList }
  foreach ($n in $list) {
    $k = 'other'
    if ($srcOf.ContainsKey([string]$n)) { $k = [string]$srcOf[[string]$n] }
    if (-not $bucket.ContainsKey($k)) { $bucket[$k] = New-Object System.Collections.ArrayList; $keys += $k }
    [void]$bucket[$k].Add([string]$n)
  }
  $groups = @()
  foreach ($k in $keys) {
    $arr = @($bucket[$k] | Where-Object { $_ })
    if ($arr.Count -eq 0) { continue }
    $groups += ,@{ K = [string]$k; Items = $arr; Next = 0; Weight = $arr.Count; Credit = 0.0 }
  }
  if ($groups.Count -le 1) { return @($list) }
  $totalW = 0
  foreach ($g in $groups) { $totalW += [int]$g.Weight }
  $out = New-Object System.Collections.ArrayList
  while ($out.Count -lt $list.Count) {
    $pick = -1
    $best = -1.0e18
    for ($i = 0; $i -lt $groups.Count; $i++) {
      $g = $groups[$i]
      if ($g.Next -ge $g.Items.Count) { continue }
      $g.Credit = [double]$g.Credit + [double]$g.Weight
      if ($g.Credit -gt $best) { $best = $g.Credit; $pick = $i }
    }
    if ($pick -lt 0) { break }
    $pg = $groups[$pick]
    [void]$out.Add([string]$pg.Items[$pg.Next])
    $pg.Next = [int]$pg.Next + 1
    $pg.Credit = [double]$pg.Credit - [double]$totalW
  }
  if ($out.Count -lt $list.Count) {
    # 理论上不该发生(每个名字都在某个组里); 真漏了就照原顺序补在队尾, 一张都不能丢
    $got = @{}
    foreach ($o in $out) { $got[[string]$o] = $true }
    foreach ($n in $list) { if (-not $got.ContainsKey([string]$n)) { [void]$out.Add([string]$n) } }
  }
  # 一行日志, 日后翻日志就能确认"到底怎么穿插的"
  $sumTxt = ''
  foreach ($g in $groups) { $sumTxt += (' / ' + $g.K + ' ' + @($g.Items).Count + ' 张') }
  Log ('队列按来源交错: 共 ' + $list.Count + ' 张' + $sumTxt)
  return @($out)
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
      foreach ($f in @(Get-BwRotPool)) { $names += [string]$f.Name }
    }
  } else {
    # 2026-10-09: 轮换图池 = 聚焦库 + 开着的其它图源库 —— 新源的图与聚焦图
    # **同一个队列**轮换(用户要求"参与正常轮换")。队列里只存文件名, 取图时各个库挨个找。
    foreach ($f in @(Get-BwRotPool)) { $names += [string]$f.Name }
  }
  if ($names.Count -eq 0) { return @() }
  $allNames = @($names)

  # 挑掉看过的
  $recycleMode = $false     # 这一轮是不是"老图循环"
  $oldestFirst = $false     # 走了"历史清零重来"那条分支(整库按最早看过优先排)
  $freshPart = @()
  $oldPart = @()
  $seen = @{}
  foreach ($h in @(Get-BwHist $s)) { if ($h) { $seen[[string]$h] = $true } }
  # 2026-10-09: 新图源各有自己的「轮换过」表(sources.json 的 rot), 作用与「看过」名单一样。
  # 顺手做一次老图回收: 某个源没轮到过的不足 20 张时, 把 >= recycle_min_days 天没出现过的
  # 键从 rot 里摘掉 —— 它们立刻回到这一轮的队列里(文件本来就在库里, 零下载)。
  foreach ($sdef in @(Get-BwSourceDefs)) {
    if (-not (Get-BwSrcEnabled $c $sdef.Key)) { continue }
    try {
      $sall = Get-BwSrcRecs
      $srec = Get-BwSrcRec $sall $sdef.Key
      $sdir = Get-BwSrcDir $c $sdef.Key
      $shave = @{}
      foreach ($sf in @(Get-BwSrcFiles $sdir)) {
        $sk = Get-BwNameKey $sf.Name
        if ($sk) { $shave[[string]$sk] = $true }
      }
      if ((Update-BwSrcRotRecycle $srec $shave (Get-Date) (Get-BwRecycleMinDays $c) $sdef) -gt 0) {
        Save-BwSrcRecs $sall
      }
      foreach ($sk2 in @((Get-BwSrcMap $srec.rot).Keys)) { $seen[[string]$sk2] = $true }
    } catch {}
  }
  if ($seen.Count -gt 0) {
    $fresh = @($names | Where-Object { -not $seen.ContainsKey((Get-BwNameKey $_)) })
    # 2026-10-09 (源池保护): 未看过的快见底了(< 20 张), 先把「已看过」文件夹里还在本地的
    # 老图移回库(零网络开销), 再重新分一次组 —— 移回来的图就算"已经在库里"了。
    if ($fresh.Count -lt $global:BWRecycleBelow) {
      $back = @(Restore-BwRecycledFiles $s ($global:BWRecycleBelow - $fresh.Count))
      if ($back.Count -gt 0) {
        foreach ($p in $back) { $names += (Split-Path $p -Leaf) }
        $allNames = @($names)
        $fresh = @($names | Where-Object { -not $seen.ContainsKey((Get-BwNameKey $_)) })
      }
    }
    if ($fresh.Count -ge $global:BWRecycleBelow) {
      Log ('重洗队列: 库里 ' + $names.Count + ' 张, 看过 ' + ($names.Count - $fresh.Count) + ' 张 -> 没看过的 ' + $fresh.Count + ' 张排最前, 其余按"最旧优先"接在后面')
    }
    # 【2026-10-10 晚·用户要求: 永远按最旧优先(从远到近)】
    # 原来这里是 if/else 两条路: "没看过的够 20 张"就走单独一条 —— 这一轮只排没看过的,
    # 必应库和够老的老图全被挡在外面; 不足 20 张才走下面的"老图循环", 而必应库那时
    # 还要"等聚焦一张没看过的都不剩"。用户把口径定成一句话, 两条路就此合并成一条:
    #   · 池子 = 聚焦库 + 必应库(上面已排除做了记号的外来图);
    #   · 没看过的(没有"上次看过"时间)被 Get-BwOldestFirst 当成"最老"天然排最前, 内部按文件名日期从早到晚;
    #   · 看过的按"上次看过时间"从早到晚接在后面; 不够 recycle_min_days 天的老图仍不排(尊重"间隔"设置)。
    # 用户原话:「原则上是从最旧的图片开始切换 / 从远到近」「永远按最旧优先」。
    # (`$names.Count -gt 0` = 池子非空才组装; 进到这里池子必然是空的或非空, 不影响语义。)
    if ($names.Count -gt 0) {
      # 池子组装(2026-10-10 晚起: 无论有没有"没看过的", 都走这一条):
      # 够久没出现过(>= recycle_min_days 天)的老图也排进来, 由 Get-BwOldestFirst 统一排序;
      # 没看过的因为没有"上次看过"时间, 天然排在最前面。
      #
      # 【2026-10-10 修·用户提议】用户原话:
      #   「**可以打开思路, 聚焦的图片轮完了, 可以轮必应图库啊, 从最早开始轮**」
      # 对 —— 必应库那几十张本来**根本不参与轮换**(见 Get-BwRotPool 的说明:
      # 它按"每日一图"的节奏走), 于是聚焦那几十张被反复轮、必应那几十张一直躺着。
      # 现在: **必应库每一轮都并进池子**(2026-10-10 晚去掉"等聚焦轮完"的闸门之后,
      # 不再有"只有聚焦见底才并"这回事), 和聚焦图一起按"最旧优先"排 ——
      # 图池大一截、重复来得更慢; "每日一图"照旧, 不受影响。
      $bingAdd = @()
      foreach ($f in @(Get-BwBingAll)) {
        $bn = [string]$f.Name
        if ($bn -and ($names -notcontains $bn)) { $names += $bn; $bingAdd += $bn }
      }
      $allNames = @($names)
      $now2 = Get-Date
      $minDays2 = Get-BwRecycleMinDays (Get-BwConfig)
      $oldPart = @($names | Where-Object {
        $kk = Get-BwNameKey $_
        $seen.ContainsKey($kk) -and (Test-BwOldImageReusable $s $kk $now2 $minDays2)
      })
      # 【2026-10-10 修·审查 P1】刚并进来的必应图**既不在「看过」名单里、
      # hist_at 里也没记过时间**(规则 1 原来不记账, 同批已补), 所以上面那个
      # `$seen.ContainsKey(...)` 条件会把它们**全部漏掉** ——
      # 现象就是"并进来了、但排队时一张都用不上", 等于这次改动白做。
      # 这里把本次新并进来的必应图直接算作"老图": 它们都当过一天"每日一图",
      # 本来就属于"很久没见过"的那一类。
      # 顺序交给下面的 Get-BwOldestFirst —— 没有时间戳的按文件名里的日期从早到晚,
      # 而必应文件名正是 `2026-09-19_…` 这种带日期的, 所以就是"从最早开始轮"。
      # 【2026-10-10 晚·用户改口径: 永远按最旧优先】
      # 这里原来有一道 `$fresh.Count -eq 0` 的闸(必应图只在"聚焦一张没得轮"时才并进来)。
      # 用户后来把口径定成一句话 —— **永远按最旧优先**(从远到近) —— 闸门去掉,
      # 必应库**每一轮都并进池子**, 顺序全交给下面的 Get-BwOldestFirst。
      foreach ($bn in $bingAdd) { if ($oldPart -notcontains $bn) { $oldPart += $bn } }
      if ($oldPart.Count -gt 0) {
        $recycleMode = $true
        $freshPart = @($fresh)
        # 【2026-10-10 修】这一行原来固定写"最早 N 天前看过"。必应图并进来之后
        # 它们大多**没有时间戳**(hist_at 里没有), Get-BwSeenDays 返回 -1,
        # 于是 N 恒为 0, 日志会写成"最早 0 天前看过" —— 读起来像"刚看过",
        # 跟事实(其实是按文件名里的日期从早到晚排的)正好相反。这里如实分开说。
        $oldest = -1
        $unknown = 0
        foreach ($o in $oldPart) {
          $dd = Get-BwSeenDays $s (Get-BwNameKey $o) $now2
          if ($dd -lt 0) { $unknown++ } elseif ($dd -gt $oldest) { $oldest = $dd }
        }
        $ageTxt = '最早 ' + $oldest + ' 天前看过'
        if ($oldest -lt 0) { $ageTxt = '都没有时间戳' }
        elseif ($unknown -gt 0) { $ageTxt = $ageTxt + '; 另 ' + $unknown + ' 张没有时间戳(按文件名里的日期从早到晚)' }
        Log ('轮换队列: 按"最旧优先"共排 ' + ($fresh.Count + $oldPart.Count) + ' 张(没看过 ' + $fresh.Count + ' 张, 老图 ' + $oldPart.Count + ' 张: ' + $ageTxt + ', 间隔 >=' + $minDays2 + ' 天)')
      } elseif ($fresh.Count -eq 0) {
        # 库里的图全都看过、而且一张都还没到回收间隔: 退回老办法 —— 历史清零重来一轮,
        # 但留最近 20 条, 免得刚看完那张翻个身又排到队首。
        #
        # 【2026-10-10 注·第二轮审查指出】加了"聚焦轮完就轮必应库"(见上面那一段)之后,
        # 只要有必应图, 上面那个 `$oldPart.Count -gt 0` 就必然成立, 于是**这条分支
        # 在必应库非空时走不到了**。它现在只在"必应库整个为空"(用户删光了/盘没挂上)
        # 时才兜底 —— 这不是死代码, 但**注释必须说清**, 免得以后有人以为它还是主路径。
        # 顺带说明代价: 少掉的那个副作用是"把 history 裁到最近 20 条"。
        # 不裁也不会涨到天上去 —— Add-BwHist 本身给 history 封了顶(见那边的实现);
        # 而且现在这条路上真正决定顺序的是 Get-BwOldestFirst 的"按时间从早到晚"。
        $s.history = @(@(Get-BwHist $s) | Select-Object -Last 20)
        # 这一轮也**按"最早看过"优先排**, 不再整库洗牌 ——
        # 见 Get-BwOldestFirst 上面那段说明(由用户提问引出)。
        $oldestFirst = $true
        Log ('重洗队列: 库里 ' + $names.Count + ' 张全都看过且还没到回收间隔 -> 历史清零重来(留最近 20 条防连着重复; 本轮按"最早看过"优先排)')
      } else {
        Log ('重洗队列: 未看过的只剩 ' + $fresh.Count + ' 张(不到 ' + $global:BWRecycleBelow + ' 张), 但还没有够 ' + $minDays2 + ' 天的老图可回收 -> 这一轮只排这 ' + $fresh.Count + ' 张')
        $names = $fresh
      }
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
  # 老图循环: 新图洗牌排在前面(先把没看过的看完)。
  # 【2026-10-10 修·用户提问引出】回收的老图改成**按"上次看过"从最早到最近排**,
  # 不再洗牌 —— 这样每张图两次出现的间隔最大而且均等。
  # 用户原话:「既然是老图循环, 为什么不从最早的图片开始循环呢」。
  # 2026-10-09 那个"按来源轮流抽"的均衡(Get-BwBalancedOrder)是为**四个源**防霸屏加的;
  # 现在图源只剩聚焦一个, 均衡已无意义, 反而盖住了"按时间排"。
  $turn = 0
  try { $turn = [int]$s.refills + [int]$s.shown } catch { $turn = 0 }
  if ($recycleMode) {
    # 2026-10-10 晚·用户要求"永远按最旧优先": 没看过的与看过的放进**同一个**排序,
    # 不再"没看过的先洗牌、老图另排一段"。没看过的没有时间戳, Get-BwOldestFirst 会把它们
    # 当成"最老"排在最前(内部按文件名里的日期从早到晚), 看过的按上次看过时间从早到晚跟在后面。
    # 【2026-10-12 修·P0】freshPart/oldPart 是在上面外来图过滤(再往下 40 行)
    # 之前就定型的; 直接返回会**绕过过滤** —— 做了记号的外来图(用户自己丢进
    # 图库的照片)照样被定时换到桌面上。这里对最终队列补一道同样的过滤:
    # 挑掉有记号的; 万一全被挑光, 就照常用(总得有图可换, 口径与上面一致)。
    $pool = @(@($freshPart) + @($oldPart))
    if ($mark -and $mark.Count -gt 0) {
      $keep = @($pool | Where-Object { -not $mark.ContainsKey((Get-BwNameKey $_)) })
      if ($keep.Count -gt 0) { $pool = $keep }
    }
    return @(Merge-BwQueueBySource (Get-BwOldestFirst $s $pool $now2))
  }
  if ($oldestFirst) {
    # 「历史清零重来」那条分支: 整库按"最早看过"优先排, 不走洗牌
    return @(Merge-BwQueueBySource (Get-BwOldestFirst $s $names $now2))
  }
  return @(Get-BwBalancedOrder $names $turn)
}

# 2026-10-23: 新下载的图别只排在队尾 —— 队列平时只在"空了 / 重洗"时才重建,
# 新图要等下次重洗才轮得到(实测有时要等一整天)。这里把新图插进当前队列的**前 1/3**:
# 既不"下一张就是它"(避免刚换过的又撞回来), 也不至于等半天。
function Add-BwNewToQueue($s, [string[]]$names) {
  if (-not $s) { return 0 }
  $q = @($s.queue | Where-Object { $_ })
  $have = @{}
  foreach ($x in $q) { $have[[string]$x] = $true }
  $add = @()
  foreach ($n in @($names)) {
    $nm = [string]$n
    if (-not $nm) { continue }
    if ($have.ContainsKey($nm)) { continue }
    $have[$nm] = $true
    $add += $nm
  }
  if ($add.Count -eq 0) { return 0 }
  $at = [int][Math]::Floor($q.Count / 3)
  if ($at -lt 0) { $at = 0 }
  $head = @($q | Select-Object -First $at)
  $tail = @($q | Select-Object -Skip $at)
  $s.queue = @(@($head) + @($add) + @($tail))
  Log ('新图进队: ' + $add.Count + ' 张插在队列第 ' + ($at + 1) + ' 位 (队列现在 ' + @($s.queue).Count + ' 张)')
  return $add.Count
}
# 2026-10-24: 本地文件夹图源——扫一遍目录, 把文件名插进队里。
# 只动队列, 不搬文件、不复制、不删: 用户的照片永远原样留在原来的文件夹里。
# 上限 300 张, 免得一个几千张的文件夹把 state.json 和队列撑爆。
function Add-BwLocalToQueue {
  $c = Get-BwConfig
  $dir = Get-BwLocalDir $c
  if (-not $dir) { return 0 }
  # -Force: 用户点了「重新扫一遍」就必须现场重读目录, 不能吃那 3 秒的进程内缓存
  # (实测: 刚丢进文件夹的新图, 3 秒内点重新扫会扫不到 —— 会被当成"点了没反应")
  $files = @(Get-BwLocalFiles $c -Force)
  if ($files.Count -eq 0) { return 0 }
  $names = @()
  foreach ($f in $files) {
    $names += [string]$f.Name
    if ($names.Count -ge 300) { break }
  }
  $s = Get-BwState
  $n = Add-BwNewToQueue $s $names
  if ($n -gt 0) { Save-BwStateKeepFav $s }
  return $n
}
# 库里所有图名的快照(聚焦 + 必应 + 其它图源), 用来算"这一趟新下了哪几张"。
function Get-BwLibNameSet {
  $h = @{}
  try { foreach ($f in @(Get-BwSpotlightAll)) { $h[[string]$f.Name] = $true } } catch {}
  try { foreach ($f in @(Get-BwBingAll)) { $h[[string]$f.Name] = $true } } catch {}
  try {
    $c = Get-BwConfig
    foreach ($def in @(Get-BwSourceDefs)) {
      foreach ($f in @(Get-BwSrcFiles (Get-BwSrcDir $c $def.Key))) { $h[[string]$f.Name] = $true }
    }
    # 2026-10-24: 本地图源的文件也算"库里已经有的", 免得被当成"这趟新下的图"。
    foreach ($f in @(Get-BwLocalFiles (Get-BwConfig))) { $h[[string]$f.Name] = $true }
  } catch {}
  return $h
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
  # 2026-10-09: 轮换图池(聚焦 + 开着的新图源)都算"收藏里还能用的图"
  foreach ($f in @(Get-BwRotPool)) { if ($want.ContainsKey([string]$f.Name)) { $out += $f } }
  foreach ($f in @(Get-BwBingAll)) { if ($want.ContainsKey([string]$f.Name)) { $out += $f } }
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
  # 2026-10-09: "还在库里"要把其它图源的库也算上 —— 否则队列里那些图
  # 每一轮都会被当成"已经被删掉"剔出去, 白抓一场。
  foreach ($f in @(Get-BwRotPool)) { $live[[string]$f.Name] = $true }
  # 开了「只看收藏」时队列里会混进必应库的图, 把它们也算作"还在",
  # 否则这些图会在每次取图前被当成"已被删掉"剔得一干二净。
  #
  # 【2026-10-10 修·用户提议引出】这一句原来只在 fav_only 时才跑, 现在**无条件跑** ——
  # 因为"聚焦轮完就轮必应库"(见 Get-BwFreshQueue)会把必应图排进**常规队列**。
  # 不放开的话: 队列里那 22 张必应在每次取图前都被 Sync-BwQueue 当"已删除"剔掉
  # (必应库不在 Get-BwRotPool 里), 同时打出一行
  # "队列里有 22 张已经不在库里 (被删除或移到别处), 已剔除" 的**假告警**,
  # 而且必应图永远换不上桌面 —— 等于这次改动白做。
  foreach ($f in @(Get-BwBingAll)) { $live[[string]$f.Name] = $true }
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
    # 试运行: 后台补货什么都不做 —— 它要联网下载, 还要重洗队列并落盘(H-8 的口径:
    # -DryRun 不许有任何副作用)。原来这道闸只加在 Start-BwBackfill 上, 直接调用本函数
    # (后台子进程就是直接调的)照样会干活。
    if ($global:BWDry) { Log ('试运行: 本应后台补货 ' + $count + ' 张聚焦壁纸, 不下载、不重洗队列'); return }
    $c = Get-BwConfig
    # 记下"下载之前库里有哪些", 下完一比就知道这次新下了哪几张
    $snap = Get-BwLibNameSet
    # 2026-10-09 用户要求"只在库低于阈值时补货": 阈值就是库上限 —— 库已经满了还去下载,
    # 下回来立刻又被 Trim-BwLibrary 淘汰, 纯属白白消耗源池(而且源池总共才 800+ 张)。
    $cap = Get-BwLibCap
    $libN = @(Get-BwSpotlightAll).Count
    if (($cap -gt 0) -and ($libN -ge $cap) -and (-not $Force)) {
      Log ('后台补货跳过: 库里已有 ' + $libN + ' 张 (达到上限 ' + $cap + ' 张), 不再下载, 源池留着慢慢用')
      return
    }
    # -Force = 恢复模式: 库被清空过, 前台先下 1 张之后库就不空了,
    # 光靠"库是空的"这个判断后台就再也不肯下(实测只补回 1 张), 所以显式穿透开关。
    if ($c.auto_fetch -or $Force -or ($libN -eq 0)) {
      $one = @(Invoke-SpotlightFetch -count $count -Quiet)
    }
    # 2026-10-09: 两个新图源走同一条"按需补货"通道 —— 各自库满即停、单轮/单日闸门照旧,
    # 一个源失败只写一行日志, 不影响聚焦库、也不影响换图。
    [void](Invoke-BwAllSrcFetch -count $count -Quiet -Force:$Force -IgnoreCap:$Force)
    # 2026-10-23: 原来这里**整队重洗** —— 新图会被"最旧优先"排到队尾, 又等于没插队。
    # 现在只把**这次新下的**插进队列前 1/3; 队列本来就空才重洗。
    $s = Get-BwState
    if ($s) {
      $after = Get-BwLibNameSet
      $news = @()
      foreach ($k in @($after.Keys)) { if (-not $snap.ContainsKey($k)) { $news += [string]$k } }
      $q0 = @($s.queue | Where-Object { $_ })
      if ($q0.Count -eq 0) {
        $s.queue = @(Get-BwFreshQueue $s)
        Log ('后台补货结束: 队列本来就是空的, 已重洗成 ' + @($s.queue).Count + ' 张')
      } elseif ($news.Count -gt 0) {
        [void](Add-BwNewToQueue $s $news)
      }
      Save-BwState $s
    }
    Log ('后台补货结束: 库中现有 ' + @(Get-BwSpotlightAll).Count + ' 张')
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
      # 队列里只有文件名, 而图可能在几个库里的任何一个(聚焦 / 必应 / 其它图源) ——
      # 挨个找一遍, 都没找到才当"这张被删了"。
      $p = Find-BwWallFile $c $name
      if ($p) {
        # 最后一道闸: 不管前面哪里漏了, 设上桌面之前必须再验一遍 ——
        # 截断的图进了队列/库的话, 在这里隔离掉、换下一张。
        if (-not (Test-BwImageOk $p)) { [void](Move-BwBadImage $p); continue }
        $s.queue = $q; return (Get-Item -LiteralPath $p)
      }
      # 这张被删了, 丢掉接着取下一张
    }
    $s.queue = @()
    # 队列空了要不要下一批新图? 默认**不下** —— 库里现有的图轮着用就行,
    # 想让程序自己补新图的话去菜单 [S] 设置 - [0] 打开。
    # 例外: 库整个被清空(0 张)属于异常状态, 不论开关都自动补救 ——
    # 总不能让用户手动按 [3] 才有图可换。
    $libCount = @(Get-BwSpotlightAll).Count
    $recover = ($libCount -eq 0)
    if ($recover) {
      # 2026-10-09: 库整个空了的时候, 先把「已看过」文件夹里还在本地的老图移回来(零网络开销,
      # 比下载快得多), 移回来就不用再下载了 —— 这也是"老图回收"最省事的那条路。
      $backN = @(Restore-BwRecycledFiles $s 6 -AnyAge).Count
      if ($backN -gt 0) {
        $libCount = @(Get-BwSpotlightAll).Count
        $recover = ($libCount -eq 0)
        Log ('库是空的: 已从「已看过」移回 ' + $backN + ' 张老图, 库里现在 ' + $libCount + ' 张')
      }
    }
    if (($c.auto_fetch -or $recover) -and ($round -eq 1)) {
      $want = Get-BwSpotlightWant
      if ($recover) { Log ('聚焦库是空的, 自动补救 (不等用户手动), 先下 1 张立刻换, 其余后台补') }
      else { Log ('队列已空 (库中现有 ' + $libCount + ' 张), 先下 1 张立刻换, 其余后台补') }
      $one = @()
      # 库是空的: 这时候"有图"比"省着用"重要, 不受当日额度限制(单轮上限照旧生效)
      if (-not $global:BWDry) { $one = @(Invoke-SpotlightFetch -count 1 -Quiet -IgnoreDailyCap:$recover) }
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
  # 2026-10-09: 这张要是某个图源的图, 顺手记进它自己的「轮换过」表 ——
  # 老图回收(>= recycle_min_days 天再排回来)靠这个时间。(图源表目前是空的, 不动任何东西)
  Add-BwSrcRot $f.FullName
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
  # 手动挑的图可能是用户自己的 png / 小尺寸照片, 所以用宽松校验:
  # 只要求"能打开"。用下载那套严格标准会把好图当成坏图挪走 (2026-09-22 修)。
  if (-not (Test-BwUsableImage $path)) {
    Write-Host '  这张图打不开 (文件截断或已损坏), 不能设为壁纸 —— 已把它挪出图库' -ForegroundColor Yellow
    [void](Move-BwBadImage $path)
    return $false
  }
  $ok = Set-BwWall $path
  $s.last_wall = $path
  $s.shown = [int]$s.shown + 1
  $s.last_swap = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  Add-BwHist $s (Split-Path $path -Leaf)
  Add-BwSrcRot $path
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
    # 2026-10-10 晚: 门槛从 3840 降到 2560 —— 2K 屏原来会先试 1920x1200,
    # 铺满 2560 宽时被放大, 反而比 4K 糊。1080p 及以下的屏照旧走小档(省硬盘)。
    if ($w -ge 2560) { $suf += '_UHD' }
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
    # keep 跟随系统: 程序**一个字节都不写**这两个注册表值(见 Set-BwDesktopWallpaper)。
    # 用来兑现"恢复我原来的填充方式"—— 还原之后再换图, 也不该又把用户的设置改回去。
    'keep'    { return @{ Style = '';   Tile = '';  Label = '跟随系统(不改)' } }
    default   { return @{ Style = '10'; Tile = '0'; Label = '填充' } }
  }
}
# ---- 「填充方式」的用户原值: 记下来 + 能还原 (2026-10-10 复核 P2) ----
# 程序会按需改 HKCU\Control Panel\Desktop 的 WallpaperStyle / TileWallpaper。
# 以前**从不记录原值**, 卸载也不还原 —— 用户机器上真实的原值事后无从得知,
# 对外文档只好照实写"不记录你的原值、卸载后也不会自动还原"。
# 现在: 第一次真要写这两个值**之前**, 先把"当时是什么"存进数据目录的 config.json;
# 已经有记录就一个字都不改(后来再写进去的都是程序自己改的值, 不是用户的原值)。
# 注册表里那一项**根本不存在**时记成 <absent> —— 还原时把它删掉, 而不是写个空值
# (空字符串本身也是一种取值, 跟"没有这一项"不是一回事)。
$global:BwStyleOrigKey    = 'wall_style_orig'
$global:BwStyleOrigAbsent = '<absent>'
# 读出记下来的原值; 没有记录返回 $null(调用方按"还没改过"处理)。
function Get-BwStyleOrig {
  try {
    $c = Get-BwConfig
    if (-not $c) { return $null }
    if (-not $c.PSObject.Properties[$global:BwStyleOrigKey]) { return $null }
    $o = $c.PSObject.Properties[$global:BwStyleOrigKey].Value
    if (-not $o) { return $null }
    if (-not $o.PSObject.Properties['style']) { return $null }
    if (-not $o.PSObject.Properties['tile']) { return $null }
    return $o
  } catch { return $null }
}
# 记录用户原值。返回 $true = 这次真的记下了; $false = 早就有记录 / 没记成, 都没动它。
function Save-BwStyleOrig($cur) {
  if (Get-BwStyleOrig) { return $false }
  $style = ''; $tile = ''
  try {
    if ($cur) {
      if ($cur.PSObject.Properties['WallpaperStyle']) { $style = [string]$cur.WallpaperStyle }
      if ($cur.PSObject.Properties['TileWallpaper'])  { $tile  = [string]$cur.TileWallpaper }
    }
  } catch {}
  if (-not $style) { $style = $global:BwStyleOrigAbsent }
  if (-not $tile)  { $tile  = $global:BwStyleOrigAbsent }
  try {
    $c = Get-BwConfig
    $c | Add-Member -NotePropertyName $global:BwStyleOrigKey -NotePropertyValue ([PSCustomObject]@{
      style = $style
      tile  = $tile
      at    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }) -Force
    Save-BwConfig $c
    Log ('填充方式: 已记下你原来的值 (WallpaperStyle=' + $style + ', TileWallpaper=' + $tile + '), 以后可以还原')
    return $true
  } catch { Log ('填充方式: 原值没能记下来: ' + $_.Exception.Message) 'WARN'; return $false }
}
# 把注册表里的两个值翻译回本程序的那几档; 认不出来返回 ''(说明用户用的是别的组合)。
function Get-BwStyleKeyByReg([string]$style, [string]$tile) {
  $k = (([string]$style).Trim() + '/' + ([string]$tile).Trim())
  switch ($k) {
    '10/0' { return 'fill' }
    '6/0'  { return 'fit' }
    '2/0'  { return 'stretch' }
    '0/0'  { return 'center' }
    '0/1'  { return 'tile' }
    '22/0' { return 'span' }
    default { return '' }
  }
}
# 把记下来的原值说成人话(菜单里显示用)。
function Format-BwStyleOrig($o) {
  if (-not $o) { return '没有记录' }
  $style = [string]$o.style; $tile = [string]$o.tile
  if (($style -eq $global:BwStyleOrigAbsent) -and ($tile -eq $global:BwStyleOrigAbsent)) { return '原来没有这两项(系统默认)' }
  $sTxt = $style; $tTxt = $tile
  if ($style -eq $global:BwStyleOrigAbsent) { $sTxt = '没这一项' }
  if ($tile  -eq $global:BwStyleOrigAbsent) { $tTxt = '没这一项' }
  $lab = ''
  switch (Get-BwStyleKeyByReg $style $tile) {
    'fill'    { $lab = '填充' }
    'fit'     { $lab = '适应' }
    'stretch' { $lab = '拉伸' }
    'center'  { $lab = '居中' }
    'tile'    { $lab = '平铺' }
    'span'    { $lab = '跨区' }
  }
  if ($lab) { $lab = ' (' + $lab + ')' }
  return ('WallpaperStyle=' + $sTxt + ', TileWallpaper=' + $tTxt + $lab)
}
# 恢复用户原来的填充方式。返回 @{ Ok; Msg } —— 调用方(菜单)照 Msg 说话。
function Restore-BwStyleOrig {
  $o = Get-BwStyleOrig
  if (-not $o) {
    return @{ Ok = $false; Msg = '没有你的原值记录 —— 程序还没改过你的填充方式, 所以没什么要还原的。' }
  }
  $style = [string]$o.style
  $tile  = [string]$o.tile
  $k = 'HKCU:\Control Panel\Desktop'
  $bad = @()
  foreach ($it in @(@('WallpaperStyle', $style), @('TileWallpaper', $tile))) {
    $nm = [string]$it[0]; $v = [string]$it[1]
    try {
      if ($v -eq $global:BwStyleOrigAbsent) {
        # 原来没有这一项 -> 删掉它(不是写个空值)
        Remove-ItemProperty -Path $k -Name $nm -ErrorAction SilentlyContinue
      } else {
        Set-ItemProperty -Path $k -Name $nm -Value $v -ErrorAction Stop
      }
    } catch { $bad += $nm; Log ('填充方式: 还原 ' + $nm + ' 失败: ' + $_.Exception.Message) 'WARN' }
  }
  # 还原之后还要让程序**不再覆盖它**: 认得出是程序那几档就按那一档走,
  # 认不出(用户自己用的别的组合)就设成 keep —— 以后一个字节都不动这两个值。
  $key = Get-BwStyleKeyByReg $style $tile
  $mode = 'keep'
  if ($key) { $mode = $key }
  try {
    $c = Get-BwConfig
    $c.wallpaper_style = $mode
    Save-BwConfig $c
  } catch { Log ('填充方式: 还原后没能更新设置: ' + $_.Exception.Message) 'WARN' }
  # 立刻生效: 把当前这张壁纸再设一次(keep 模式下不会写注册表)。
  try { [void](Apply-BwWallStyle) } catch {}
  if ($bad.Count -gt 0) {
    return @{ Ok = $false; Msg = ('没还原干净: ' + ($bad -join ', ') + ' 写不进去(见日志)。') }
  }
  $tail = '以后换图不会再动它'
  if ($key) { $tail = '以后换图还按「' + (Get-BwWallStyle).Label + '」走, 想换回程序那几档, 在「壁纸填充方式」里再选一次就行' }
  Log ('填充方式: 已还原为你原来的值 (WallpaperStyle=' + $style + ', TileWallpaper=' + $tile + '), ' + $tail)
  return @{ Ok = $true; Msg = ('已经还原成 ' + (Format-BwStyleOrig $o) + ' —— 立刻生效; ' + $tail + '。') }
}
function Set-BwDesktopWallpaper([string]$path) {
  if (-not ('WinWall' -as [type])) {
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class WinWall { [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool SystemParametersInfo(uint a, uint p, string v, uint f); }'
  }
  $w = Get-BwWallStyle
  $k = 'HKCU:\Control Panel\Desktop'
  $cur = Get-ItemProperty $k -ErrorAction SilentlyContinue
  # 2026-10-10 (复核 P2): 真要写之前先把用户原值记下来。只在第一次记, 已有的记录不动 ——
  # 否则第二次写入时"当时的值"已经是程序自己改过的, 原值就永久丢了。
  # Style/Tile 为空串 = keep(跟随系统), 那就一个字都不写。
  $needWrite = (($w.Style -and ([string]$cur.WallpaperStyle -ne $w.Style)) -or ($w.Tile -and ([string]$cur.TileWallpaper -ne $w.Tile)))
  if ($needWrite) { [void](Save-BwStyleOrig $cur) }
  if ($w.Style -and ([string]$cur.WallpaperStyle -ne $w.Style)) { Set-ItemProperty $k -Name WallpaperStyle -Value $w.Style }
  if ($w.Tile  -and ([string]$cur.TileWallpaper  -ne $w.Tile))  { Set-ItemProperty $k -Name TileWallpaper  -Value $w.Tile }
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
# ---- 借鉴 SpotlightWall: 文件名带哈希, 强制壁纸刷新 ----
# 把图片"唯一身份"hash 进文件名: 不同图 -> 不同路径 -> Windows 永远重新加载,
# 不会拿缓存里的旧版本糊弄桌面; 同一张图(身份不变) -> 同一路径 -> 不重复下载。
# Bing 用 urlbase、Spotlight 用 slug+url 作身份, 都稳定, 所以幂等。
function Get-BwHash([string]$s) {
  if (-not $s) { return '00000000' }
  try {
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $b = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s))
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt 4; $i++) { [void]$sb.Append($b[$i].ToString('x2')) }
    return $sb.ToString()
  } catch { return '00000000' }
}
# ---- 元数据写进图片自己身上 (JPEG 注释段 FF FE) ----
# 不在图库里另建文件, 也就不存在"白纸图标的 json 混在图里"那回事;
# 数据跟着图片走 —— 图拷到哪儿、发给谁, 来源信息还在 (海风: "元数据应该写在
# 图片里, 这样你调取也方便, 用户也看不见")。
# 插在 SOI/APP0 后面的注释段, 不重新编码、不动像素, 文件只变大几百字节,
# 画质和体积都不受影响, 尾部 FF D9 也依然是 FF D9 (坏图校验不受干扰)。
function Get-BwMetaPayload($info) {
  $o = [ordered]@{ app = '桌面壁纸'; date = ''; title = ''; copyright = ''; source_type = ''; source_url = ''; source_link = ''; width = 0; height = 0 }
  if ($info) {
    foreach ($k in @('date', 'title', 'copyright', 'source_type', 'source_url', 'source_link')) {
      if ($info.ContainsKey($k)) { $o[$k] = [string]$info[$k] }
    }
    # 2026-10-09: 真实分辨率也写进去(用户要求"每张图落盘时把宽度 x 高度写进元数据/日志")。
    # 写成数字而不是字符串 —— 以后要按分辨率筛图, 读出来就能直接比大小。
    foreach ($k in @('width', 'height')) {
      if ($info.ContainsKey($k)) { try { $o[$k] = [int]$info[$k] } catch {} }
    }
  }
  return ($o | ConvertTo-Json -Compress)
}
function Read-BwImageMeta([string]$path) {
  # 从 JPEG 注释段里读回程序自己写的元数据。没有就返回 $null。
  try {
    $b = [System.IO.File]::ReadAllBytes($path)
    $i = 2
    while ($i -lt ($b.Length - 3)) {
      if ($b[$i] -ne 0xFF) { break }
      $m = $b[$i + 1]
      if ($m -eq 0xDA) { break }              # SOS: 后面是压缩数据, 不再有段
      if (($m -ge 0xD0 -and $m -le 0xD7) -or $m -eq 0x01) { $i += 2; continue }
      $len = ($b[$i + 2] * 256) + $b[$i + 3]
      if ($len -lt 2) { break }
      if ($m -eq 0xFE) {
        $n = $len - 2
        if ($n -gt 2 -and ($i + 4 + $n) -le $b.Length) {
          $s = [System.Text.Encoding]::UTF8.GetString($b, $i + 4, $n)
    # 写入侧标记一直是「桌面壁纸」; 「微软壁纸助手」是**更早年代图片**里的历史标记 ——
    # 2026-10-12 产品改名后这个匹配**必须永久保留**, 否则老图的内嵌元数据全部读不回。
    if ($s.StartsWith('{') -and (($s.Contains('桌面壁纸')) -or ($s.Contains('微软壁纸助手')))) {
            $o = $s | ConvertFrom-Json
            return @{
              date        = [string]$o.date
              title       = [string]$o.title
              copyright   = [string]$o.copyright
              source_type = [string]$o.source_type
              source_url  = [string]$o.source_url
              source_link = [string]$o.source_link
              width       = [int]$o.width
              height      = [int]$o.height
            }
          }
        }
      }
      $i += 2 + $len
    }
  } catch {}
  return $null
}
function Write-BwImageMeta([string]$path, [hashtable]$info) {
  if (-not ($path -and $info)) { return $false }
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  # 已经写过的不再重复插一段 (注释段可以有多段, 重复写会越攒越多)
  if (Read-BwImageMeta $path) { return $true }
  try {
    $pay = [System.Text.Encoding]::UTF8.GetBytes((Get-BwMetaPayload $info))
    if ($pay.Length -gt 65500) { return $false }
    $b = [System.IO.File]::ReadAllBytes($path)
    if ($b.Length -lt 4 -or $b[0] -ne 0xFF -or $b[1] -ne 0xD8) { return $false }
    # 插入点: SOI 之后; 如果紧跟着 APP0 (JFIF), 就插在它后面, 顺序才合规
    $at = 2
    if ($b[2] -eq 0xFF -and $b[3] -eq 0xE0) { $at = 4 + ($b[4] * 256) + $b[5] }
    $L = $pay.Length + 2
    $seg = New-Object byte[] (4 + $pay.Length)
    $seg[0] = 0xFF; $seg[1] = 0xFE
    $seg[2] = [byte](($L -shr 8) -band 0xFF); $seg[3] = [byte]($L -band 0xFF)
    [Array]::Copy($pay, 0, $seg, 4, $pay.Length)
    $out = New-Object byte[] ($b.Length + $seg.Length)
    [Array]::Copy($b, 0, $out, 0, $at)
    [Array]::Copy($seg, 0, $out, $at, $seg.Length)
    [Array]::Copy($b, $at, $out, ($at + $seg.Length), ($b.Length - $at))
    $tmp = $path + '.metatmp'
    [System.IO.File]::WriteAllBytes($tmp, $out)
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $true
  } catch { return $false }
}
# ---- 借鉴 SpotlightWall: 多区域并抓 ----
# 各国聚焦图池不一样。每次请求轮换到下一个区域, 配合按 slug 去重,
# 一次更新就能拿到比单区域多得多的不重复 4K 图 (实测 4 区域 x 4 轮可 60+ 张)。
$script:BWSpotIdx = 0
function Get-BwSpotRegion {
  $c = Get-BwConfig
  $regs = $null
  if ($c.PSObject.Properties['spotlight_regions']) { $regs = @($c.spotlight_regions | Where-Object { $_ }) }
  if (-not $regs -or $regs.Count -eq 0) { $regs = @('cn|zh-CN') }
  if (-not $script:BWSpotIdx) { $script:BWSpotIdx = 0 }
  $r = $regs[$script:BWSpotIdx % $regs.Count]
  $script:BWSpotIdx = ($script:BWSpotIdx + 1) % $regs.Count
  return $r
}

# ---- 坏图拦截: 截断的 JPEG 也常常能被 GDI+ "打开", 光查能不能解码拦不住 ----
# 2026-09-21 实测两连: 一张聚焦图正好下到 4MB 整被掐断(尾部不是 FF D9),
# GDI+ FromFile 报得出宽高; 又以为"强制整张解码"能现原形, 结果 GDI+ 对截断
# 更宽容 —— 整张解完也不抛异常, 解出来就是那半张灰图。两次都拦不住,
# 结论: **尾部 FF D9 是唯一可靠的硬标准**, 没有就一律当坏图, 不给第二次机会。
# 校验共三层:
#   1) 文件不小于 100KB;
#   2) 头 3 字节必须是 FF D8 FF (JPEG 起点);
#   3) 尾 2 字节必须是 FF D9 (JPEG 结束标记, 下载被掐断几乎必然没有)。
function Test-BwImageOk([string]$path) {
  if (-not $path) { return $false }
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  try { if ((Get-Item -LiteralPath $path -ErrorAction Stop).Length -lt 100KB) { return $false } } catch { return $false }
  try {
    $fs = [System.IO.File]::OpenRead($path)
    try {
      if ($fs.Length -lt 4) { return $false }
      $h = New-Object byte[] 3
      if ($fs.Read($h, 0, 3) -lt 3) { return $false }
      if (-not ($h[0] -eq 0xFF -and $h[1] -eq 0xD8 -and $h[2] -eq 0xFF)) { return $false }
      $null = $fs.Seek(-2, [System.IO.SeekOrigin]::End)
      $t = New-Object byte[] 2
      if ($fs.Read($t, 0, 2) -lt 2) { return $false }
      if (-not ($t[0] -eq 0xFF -and $t[1] -eq 0xD9)) { return $false }
    } finally { $fs.Close() }
  } catch { return $false }
  Add-Type -AssemblyName System.Drawing
  $im = $null
  try { $im = [System.Drawing.Image]::FromFile($path); return $true } catch { return $false }
  finally { if ($im) { $im.Dispose() } }
}
# 「这张图 Windows 能不能打开」—— 给**用户自己放进图库的图**用的宽松校验。
#
# 为什么需要它: Test-BwImageOk 那套标准(>=100KB + 头 FF D8 FF + 尾 FF D9)是给
# "程序自己下载的 jpg"定的 —— 较真的是下载被掐断。拿它去量用户的图会误伤:
#   * 用户丢进图库的 png / webp / bmp / gif / tif 头几个字节不是 FF D8 FF,
#     一律被判"已损坏", 选中设壁纸时还会被挪进「坏图」文件夹;
#   * 用户自己的小照片(手机压缩图、缩略图)常常不到 100KB, 同样被误判。
# 这里只回答一个问题: GDI+ 能不能打开它。空文件/截断文件/非图片文件都会抛异常。
function Test-BwUsableImage([string]$path) {
  if (-not $path) { return $false }
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
  $im = $null
  try { $im = [System.Drawing.Image]::FromFile($path); return $true } catch { return $false }
  finally { if ($im) { $im.Dispose() } }
}
# 真实分辨率(像素)。返回 @{W=宽; H=高} —— 读不出来返回 $null。
# 2026-10-09: 画质门槛与"不放大显示"都要拿它判, 而它一次调用就要开一次图,
# 所以带一层进程内缓存(键 = 完整路径)。库里的图不会变, 缓存是安全的;
# 长跑时缓存上限 200 条, 超了整个丢掉重建, 不会一直涨。
function Get-BwImageSize([string]$path) {
  if (-not $path) { return $null }
  if (-not $global:BWArtDimCache) { $global:BWArtDimCache = @{} }
  if ($global:BWArtDimCache.ContainsKey([string]$path)) { return $global:BWArtDimCache[[string]$path] }
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
  $im = $null
  $o = $null
  try { $im = [System.Drawing.Image]::FromFile($path); $o = @{ W = [int]$im.Width; H = [int]$im.Height } }
  catch { $o = $null }
  finally { if ($im) { $im.Dispose() } }
  if ($global:BWArtDimCache.Count -gt 200) { $global:BWArtDimCache = @{} }
  $global:BWArtDimCache[[string]$path] = $o
  return $o
}
function Get-BwImageDim([string]$path) {
  $sz = Get-BwImageSize $path
  if (-not $sz) { return '' }
  return "$($sz.W)x$($sz.H)"
}
# 坏图挪出图库 —— 图库里只该有能用的图 (海风: "图库里就应该是图片,
# 不应该有其他无关的文件存在")。挪到程序数据目录的「坏图」文件夹,
# 不删: 万一哪次是程序自己看走眼, 图还在, 还能拿回来。
function Move-BwBadImage([string]$path) {
  if (-not ($path -and (Test-Path -LiteralPath $path))) { return $false }
  try {
    $bad = Join-Path $global:BWRoot '坏图'
    if (-not (Test-Path -LiteralPath $bad)) { New-Item -ItemType Directory -Path $bad -Force | Out-Null }
    # 文件名用 .NET 取: 这里曾用 Split-Path -Leaf, 实测在部分路径上取回空串,
    # 目标就变成「坏图\.225526」这种点开头的怪名, Move 直接失败 —— 坏图一张都
    # 没挪走, 外面看扫描"跑过了", 其实库里原样躺着装满半张灰图的 jpg。
    $leaf = [System.IO.Path]::GetFileName($path)
    if (-not $leaf) { $leaf = 'bad.jpg' }
    $dst = Join-Path $bad ($leaf + '.' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    [System.IO.File]::Move($path, $dst)
    Log ('坏图隔离: ' + $leaf)
    return $true
  } catch {
    # 隔离失败必须留痕: 以前 catch 里一声不吭返回 False, 坏图就一直赖在图库里,
    # 外面看着是"扫过了", 其实一张都没挪走 (2026-09-21 羽扇豆)。
    try { Log ('坏图隔离失败: ' + (Split-Path -LiteralPath $path -Leaf) + ' -> ' + $_.Exception.Message) } catch {}
    return $false
  }
}
# 扫两个库, 把截断/损坏的图隔离出去; 顺手把 .meta.json 元数据小文件清掉
# (这功能已取消, 图库里只该有图 —— 白纸图标的 json 用户只当它是坏文件)。
function Sweep-BwBadImages {
  $c = Get-BwConfig
  # 严格标准(>=100KB / JPEG 头尾)只用来量**程序自己下载的**图 —— 截断是下载环节
  # 引入的, 只有它需要较真。用户自己丢进图库的图(不到 100KB 的小照片等)只要求
  # "能打开", 否则会被当成坏图挪走 (2026-09-22 修)。
  # 下载清单在这里取一次: 它是文件读取, 放进循环里按文件读会白白重复几千次。
  $dlKeys = Get-BwDlKeys
  $n = 0
  foreach ($dir in @($c.spotlight_save_dir, $c.bing_save_dir)) {
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Filter *.jpg -ErrorAction SilentlyContinue)) {
      $bad = $false
      if ($dlKeys.Contains((Get-BwNameKey $f.Name))) { $bad = (-not (Test-BwImageOk $f.FullName)) }
      else { $bad = (-not (Test-BwUsableImage $f.FullName)) }
      if ($bad) { if (Move-BwBadImage $f.FullName) { $n++ } }
    }
    # 老版本把 .meta.json 直接写在图库里, 文件管理器里混着一片白纸图标 —— 清掉
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Filter *.meta.json -ErrorAction SilentlyContinue)) {
      Remove-BwFile $f.FullName
    }
    # 下载中断留下的 .part 半成品同理: 图库里不该有它, 见到就删
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Filter *.part -ErrorAction SilentlyContinue)) {
      Remove-BwFile $f.FullName
    }
  }
  return $n
}

# 把一个 URL 搬到文件上, 带**总时长**硬期限(超时抛 WebException, 由调用方按"超时"处理)。
#
# 为什么不能只靠 Invoke-WebRequest 的 -TimeoutSec: 它管的是"多久拿到响应头",
# 一旦响应头到手就开始慢慢吐字节的图床, 它一点办法都没有 ——
# 2026-10-09 自测实测: 本地一个"每 2 秒才给 1KB"的服务器, -TimeoutSec 5 照样一直下下去
# (卡了 2 分多钟还没回来, 只能人为掐掉)。实测有的图床 ~130 秒/张, 正是这种慢法。
# 所以新图源这条路自己盯表: 超过 $TimeoutSec 秒还没搬完就中止。
# 两个都设: Timeout 管"连不上/不回响应头", ReadWriteTimeout 管"连上了但一直不给数据",
# 循环里的 deadline 管"一直在给、但给得太慢"。
function Save-BwUrlToFile([string]$u, [string]$tmp, [int]$TimeoutSec) {
  $req = $null; $resp = $null; $st = $null; $fs = $null
  try {
    $req = [System.Net.HttpWebRequest]::Create($u)
    $req.UserAgent = $global:BWSrcUa
    $req.Method = 'GET'
    $req.AllowAutoRedirect = $true
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $resp = $req.GetResponse()
    $st = $resp.GetResponseStream()
    $fs = [System.IO.File]::Create($tmp)
    $buf = New-Object byte[] 65536
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
      if ((Get-Date) -gt $deadline) {
        throw (New-Object System.Net.WebException ('下载超时(总时长超过 ' + $TimeoutSec + ' 秒)'))
      }
      $n = $st.Read($buf, 0, $buf.Length)
      if ($n -le 0) { break }
      $fs.Write($buf, 0, $n)
    }
    return $true
  } finally {
    if ($fs) { $fs.Dispose() }
    if ($st) { $st.Dispose() }
    if ($resp) { $resp.Dispose() }
  }
}
function Save-BwFile([string[]]$urls, [string]$path, [hashtable]$meta = $null, [int64]$MaxBytes = 0, [int]$TimeoutSec = 300, [int]$MinWidth = 0, [double]$MinAspect = 0, [double]$MaxAspect = 0, [switch]$TotalDeadline) {
  # 试运行: 只说一声, 一张都不下。-DryRun 的意思就是"什么都不改",
  # 少了这道闸, 后台补漏 (Invoke-BwBackfill) 在试运行时照样会真去下载。
  if ($global:BWDry) { Log ('试运行: 本应下载 -> ' + (Split-Path $path -Leaf)); return $false }
  # 2026-10-09: 这次下载的结局写在这里, 给调用方分类用 ——
  #   ok / toobig(超过大小上限) / badimage(截断或坏图) / toosmall(宽度不到门槛)
  #   / aspect(宽高比不达标, 竖幅或方形) / timeout(超时) / fail(其它网络失败)
  # 为什么必须分出来: 那种慢图床, "超时"和"图不合格"要做的事完全不同 ——
  # 前者要退避, 后者要接着翻下一张。老的两源不看这个字段, 行为一个字没变。
  $global:BWLastDlStatus = 'fail'
  # 先落地成 .part, 确认是张能用的图再改名进库。
  # 以前直接写到目标名: 下载到一半被截断 / 拿到的是 HTML 错误页(同样超过 100KB),
  # 半成品会留在图库里, 被计入库容, 甚至被挑去设为壁纸 —— 桌面直接黑掉或花掉。
  $tmp = $path + '.part'
  Remove-BwFile $tmp
  foreach ($u in $urls) {
    try {
      if ($TotalDeadline) {
        # 走这条路的图源: 总时长硬期限, 慢图床到点就放弃(见 Save-BwUrlToFile 上面的说明)
        [void](Save-BwUrlToFile $u $tmp $TimeoutSec)
      } else {
        # 必应 / 聚焦 / 归档: **一行没动**, 还是老样子(它们本来就快)
        Invoke-WebRequest -Uri $u -OutFile $tmp -TimeoutSec $TimeoutSec -UseBasicParsing
      }
      if ((Get-Item $tmp -ErrorAction SilentlyContinue).Length -gt 100KB) {
        # 2026-10-09: 可选的大小上限(给将来的图源用)。有的源条目挂着几十 MB 的原图,
        # 当壁纸没意义还白占盘; 超过上限的就地丢弃、换下一个地址(和"截断"一个处理法)。
        $tmpLen = 0
        try { $tmpLen = (Get-Item -LiteralPath $tmp -ErrorAction Stop).Length } catch { $tmpLen = 0 }
        if (($MaxBytes -gt 0) -and ($tmpLen -gt $MaxBytes)) {
          Log ('下载的图超过大小上限(' + [math]::Round($tmpLen / 1MB, 2) + ' MB > ' + [math]::Round($MaxBytes / 1MB, 0) + ' MB), 已丢弃: ' + (Split-Path $path -Leaf))
          Remove-BwFile $tmp
          $global:BWLastDlStatus = 'toobig'
          continue
        }
        if (-not (Test-BwImageOk $tmp)) {
          # 大小够了但校验不过 = 截断/坏图。以前只查"能不能打开",
          # 截断的 JPEG 照样能打开, 半张灰图就上了桌面 (2026-09-21 羽扇豆)。
          Log ('下载的图不完整(截断或坏图), 已丢弃: ' + (Split-Path $path -Leaf))
          Remove-BwFile $tmp
          $global:BWLastDlStatus = 'badimage'
          continue
        }
        # 2026-10-09 画质门槛(用户要求"门槛 1600 / 满屏线 2560"): 拿**真实分辨率**判,
        # 不看接口自称的尺寸。不达标的图就地丢掉 —— 不落盘、不进库、不占库容。
        # 判定放在"校验过是张完整图"之后: 截断的半张图读出来的宽度是假的, 不能拿来判门槛。
        if (($MinWidth -gt 0) -or ($MinAspect -gt 0) -or ($MaxAspect -gt 0)) {
          # .part 是**临时文件名**: 同一个名字先后可能装过两张不同的图(前一次失败重下),
          # 分辨率缓存里那份不算数, 先把它抹掉再量 —— 不然门槛会拿上一张的尺寸做判断。
          try { if ($global:BWArtDimCache) { [void]$global:BWArtDimCache.Remove([string]$tmp) } } catch { }
          $dim = Get-BwImageSize $tmp
          if (-not $dim) {
            Log ('下载的图读不出分辨率, 已丢弃: ' + (Split-Path $path -Leaf))
            Remove-BwFile $tmp
            $global:BWLastDlStatus = 'badimage'
            continue
          }
          if (($MinWidth -gt 0) -and ([int]$dim.W -lt $MinWidth)) {
            Log ('宽度 ' + $dim.W + ' 不到门槛 ' + $MinWidth + ', 跳过不落盘: ' + (Split-Path $path -Leaf))
            Remove-BwFile $tmp
            $global:BWLastDlStatus = 'toosmall'
            continue
          }
          if (($MinAspect -gt 0) -or ($MaxAspect -gt 0)) {
            $ar = 0.0
            if ([int]$dim.H -gt 0) { $ar = [double]$dim.W / [double]$dim.H }
            if (($MinAspect -gt 0) -and ($ar -lt $MinAspect)) {
              Log ('宽高比 ' + [math]::Round($ar, 2) + ' 不到 ' + $MinAspect + '(竖幅/方形), 跳过不落盘: ' + (Split-Path $path -Leaf))
              Remove-BwFile $tmp
              $global:BWLastDlStatus = 'aspect'
              continue
            }
            if (($MaxAspect -gt 0) -and ($ar -gt $MaxAspect)) {
              Log ('宽高比 ' + [math]::Round($ar, 2) + ' 超过 ' + $MaxAspect + '(太宽/长卷), 跳过不落盘: ' + (Split-Path $path -Leaf))
              Remove-BwFile $tmp
              $global:BWLastDlStatus = 'aspect'
              continue
            }
          }
        }
        # 2026-10-09 (审查 H-10): 落地这一步必须**确认真的落地了**才算成功。
        # Move-Item 在 ErrorActionPreference=Continue 下失败只是非终止错误, catch 抓不到,
        # 于是"移动失败"照样被记成"下载成功"、还会写进下载流水 —— 而流水同时就是
        # 「已下过清单」(Get-BwDlKeys), 这一张从此**永远不再下**。同一类坑在升级路径
        # 2026-10-05 已经修过(见上面小助手那段), 这里补上。
        $wantBytes = 0
        try { $wantBytes = (Get-Item -LiteralPath $tmp -ErrorAction Stop).Length } catch { $wantBytes = 0 }
        Remove-BwFile $path
        $moved = $false
        try { Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop; $moved = $true }
        catch { Log ('下载落地失败(文件可能正被占用): ' + (Split-Path $path -Leaf) + ' - ' + $_.Exception.Message) }
        $fi = $null
        if ($moved) { try { $fi = Get-Item -LiteralPath $path -ErrorAction Stop } catch { $fi = $null } }
        if ((-not $fi) -or ($fi.Length -le 0) -or (($wantBytes -gt 0) -and ($fi.Length -ne $wantBytes))) {
          # 没落地 / 落地了但字节数对不上 -> 这一张按失败处理: 不记流水、不报成功,
          # 换下一个候选地址再试(这里 continue, 与上面的截断分支一致)。
          Log ('下载落地校验不过(文件不在或不完整), 按失败处理: ' + (Split-Path $path -Leaf))
          Remove-BwFile $tmp
          continue
        }
        # 真实分辨率同时写进两条路: ① 日志(用户要求"日志/心跳能看到本张 3840x2160")
        # ② 图片自己的注释段(元数据跟着图片走, 换台机器也认得)。
        $dims = Get-BwImageDim $path
        Log ('下载成功: ' + (Split-Path $path -Leaf) + ' (' + $dims + ')')
        # 元数据(标题/版权/来源)写进图片自己的注释段, 图库里不另外生成文件
        if ($meta) {
          try {
            $sz = Get-BwImageSize $path
            if ($sz) { $meta['width'] = [int]$sz.W; $meta['height'] = [int]$sz.H }
          } catch {}
          [void](Write-BwImageMeta $path $meta)
        }
        # 记一笔: 从装上那天起一共下载过多少张(删掉的、清走的都不往回减)。
        # 带上图片编号 —— 流水文件同时是「程序下载清单」, 菜单 [9] 校验图库靠它。
        Add-BwDlCount 1 (Get-BwNameKey (Split-Path $path -Leaf))
        $global:BWLastDlStatus = 'ok'
        return $true
      }
      Remove-BwFile $tmp
    } catch {
      # 超时单独认出来(实测有的图床能慢到 ~130 秒/张)。判据两条腿走路:
      # 先看 WebException 的 Status, 再退回消息里的关键字(中文系统上是"操作已超时")。
      $isTo = $false
      try {
        $ex = $_.Exception
        $guard = 0
        while ($ex -and (-not $isTo) -and ($guard -lt 6)) {
          $guard++
          if ($ex -is [System.Net.WebException]) {
            if ($ex.Status -eq [System.Net.WebExceptionStatus]::Timeout) { $isTo = $true }
          }
          if ((-not $isTo) -and ([string]$ex.Message -match '(?i)超时|timeout|timed out')) { $isTo = $true }
          $ex = $ex.InnerException
        }
      } catch { $isTo = $false }
      if ($isTo) {
        $global:BWLastDlStatus = 'timeout'
        Log ('下载超时(' + $TimeoutSec + ' 秒): ' + $u) 'WARN'
      } else {
        $global:BWLastDlStatus = 'fail'
        Log ('下载失败: ' + $_.Exception.Message)
      }
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
  $snap0 = Get-BwLibNameSet
  Write-Host ('  共 ' + $items.Count + ' 张, 开始批量下载(跳过已有)...')
  $ok = 0; $skip = 0; $fail = 0
  foreach ($it in $items) {
    $path = Get-BwTargetPath $it.date (Get-BwMonthName $it)
    if (Test-Path $path) { $skip++; continue }
    $dir = Split-Path $path -Parent
    [void](New-BwDir $dir)
    $m = @{ date=$it.date; title=''; copyright=''; source_type='必应归档'; source_url=$it.url; source_link='' }
    if (Save-BwFile @($it.url) $path $m) { $ok++ } else { $fail++ }
    Start-Sleep -Milliseconds 400
  }
  Write-Host ('  完成: 成功 ' + $ok + ', 跳过 ' + $skip + ', 失败 ' + $fail)
  Log ("归档批量 $ym : 成功$ok 跳过$skip 失败$fail")
  # 2026-10-23: 新补齐的图也尽快进轮换(插在队列前 1/3), 不要等下次重洗
  try {
    if ($ok -gt 0) {
      $s0 = Get-BwState
      if ($s0) {
        $after0 = Get-BwLibNameSet
        $news0 = @()
        foreach ($k in @($after0.Keys)) { if (-not $snap0.ContainsKey($k)) { $news0 += [string]$k } }
        if ($news0.Count -gt 0) { [void](Add-BwNewToQueue $s0 $news0); Save-BwState $s0 }
      }
    }
  } catch { }
}
function Invoke-BwArchiveSingle([string]$ym, [string]$date, [switch]$SetWall) {
  $items = Get-BwMonthItems $ym
  $it = $items | Where-Object { $_.date -eq $date } | Select-Object -First 1
  if (-not $it) { Write-Host '  该日期不存在于当月清单'; return }
  $path = Get-BwTargetPath $it.date (Get-BwMonthName $it)
  $dir = Split-Path $path -Parent
  [void](New-BwDir $dir)
  if (-not (Test-Path $path)) {
    $m = @{ date=$it.date; title=''; copyright=''; source_type='必应归档'; source_url=$it.url; source_link='' }
    if (-not (Save-BwFile @($it.url) $path $m)) { Write-Host '  下载失败'; return }
  }
  if ($SetWall) { $ok = Set-BwDesktopWallpaper $path; Write-Host ("  已设为壁纸: ok=$ok") } else { Write-Host ("  已保存: $path") }
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
    $m = $null
    if ($meta) { $m = @{ date=$bday; title=$meta.title; copyright=($meta.copyright -replace '\s*[(（]©.*$',''); source_type='必应'; source_url=('https://cn.bing.com' + $meta.urlbase); source_link='https://www.bing.com' } }
    elseif ($it) { $m = @{ date=$it.date; title=''; copyright=''; source_type='必应归档'; source_url=$it.url; source_link='' } }
    if (Save-BwFile $urls $path $m) { $ok++; $gotThrough = $day } else { $fail++ }
    Start-Sleep -Milliseconds 400
  }
  if (($ok + $skip + $fail) -gt 0) {
    Log ('补漏 ' + $missing[0].ToString('yyyy-MM-dd') + ' ~ ' + $missing[$missing.Count - 1].ToString('yyyy-MM-dd') + ': 新增 ' + $ok + ' 已有 ' + $skip + ' 失败 ' + $fail)
  }
  # 水位只推到"确实拿到过的那天"。以前不看成败一律推到最后一天,
  # 于是断一次网那几天的图就永久漏了, 而且再也不会补。
  if ($gotThrough) {
    Set-BwHighDate $s $gotThrough.ToString('yyyy-MM-dd')
    # 必须走 KeepFav 合并写: 补漏可能连着下 30 天(好几分钟), 这期间用户很可能
    # 正在菜单里按 [F] 收藏、手动挑图。整份覆盖会把人家刚写进 state 的
    # 收藏/队列/看过名单无声抹掉 —— 这正是 Invoke-BwCycle 注释里承认过的那类漏改
    # (2026-09-22 修)。
    Save-BwStateKeepFav $s
  }
}
# ---- Windows 聚焦图源 (微软官方桌面聚焦, 3840x2160, 与 Bing 壁纸同一壁纸团队) ----
function Get-SpotlightOne {
  # 单次请求 -> @{title,url,copyright,slug,id}; 失败返回 $null
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
  # 借鉴 SpotlightWall: 每次请求轮换到下一个区域, 不同区域图池不一样 -> 更多不重复 4K 图。
  $reg = Get-BwSpotRegion
  $cc = 'cn'; $loc = 'zh-CN'
  if ($reg -and $reg.Contains('|')) { $cc = $reg.Split('|')[0]; $loc = $reg.Split('|')[1] }
  $u = ('https://fd.api.iris.microsoft.com/v4/api/selection?placement=88000820&aid=1195280&country={0}&locale={1}&fmt=json' -f $cc, $loc)
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
  # 借鉴 SpotlightWall: 把身份哈希嵌进文件名(slug 仍留在最后, 去重/历史不受影响)。
  # 不同图 -> 不同路径 -> Windows 必重新加载, 不会拿缓存里的旧图糊弄桌面。
  $h = Get-BwHash (($it.slug) + '|' + ($it.url))
  return ('{0}_{1}_{2}_{3}.jpg' -f (Get-Date -Format 'yyyy-MM-dd'), $t, $h, $it.slug)
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
# 菜单 [2] 下载聚焦图片的计数动效 (方案 A): 虚线增长 + 游标流动。
# 固定的中括号轨道里, 已下载的张数越多, 实线 '-' 越长 (增长);
# 一颗 '>' 游标在轨道里从左向右不停流动 (流动), 数字同步递增。
# 只有手动按 [2] 才开 (-Counter), 后台自动补图不开。
function Show-BwDashedCounter([int]$ok, [int]$frame) {
  $W = 18
  $fill = [Math]::Min($ok, $W)
  $cursor = $frame % $W
  $sb = New-Object System.Text.StringBuilder
  $sb.Append('  下载聚焦图片 [') > $null
  for ($i = 0; $i -lt $W; $i++) {
    if ($i -eq $cursor) { $sb.Append('>') > $null }
    elseif ($i -lt $fill) { $sb.Append('-') > $null }
    else { $sb.Append(' ') > $null }
  }
  $sb.Append('] ') > $null
  $sb.Append([string]$ok) > $null
  $sb.Append('  ') > $null
  Write-Host ("`r" + $sb.ToString()) -NoNewline
}
# 在两次下载之间的等待里, 让游标持续流动几步, 屏幕一直有动静 (不会像卡死)。
function Wait-BwFlow([int]$ms, [int]$ok, [ref]$frame) {
  $step = 90
  $n = [Math]::Max(1, [Math]::Round($ms / $step))
  for ($j = 0; $j -lt $n; $j++) {
    $frame.Value++
    Show-BwDashedCounter $ok $frame.Value
    Start-Sleep -Milliseconds $step
  }
}

function Invoke-SpotlightFetch([int]$count, [switch]$SetWall, [switch]$Quiet, [switch]$Counter, [switch]$IgnoreDailyCap) {
  # $Counter: 菜单 [2] 手动下载时开 —— 每下成一张就在同一行把数字加一,
  # 并用「虚线增长 + 游标流动」的动效显示进度 (Show-BwDashedCounter / Wait-BwFlow),
  # 不然联网这几秒屏幕上一点动静都没有, 像卡住了。
  # 后台自动补图不开: 它跑在没人的时候, 也不需要有人看。
  # 聚焦接口每次请求几乎都返回一张不同的图(实测 40 次 / 39 张唯一), 因此可批量刷。
  # 返回本次新增的文件全名数组, 调用方可以立刻把它们排进轮换队列。
  #
  # 2026-10-09 (用户要求: 别把 800+ 张的源池一次抽干) —— 抓取一律在这里收口, 三道闸:
  #   · 单轮上限 fetch_round_cap、单日上限 fetch_day_cap: 不管谁调、要多少, 都按闸门收;
  #   · 低频模式(源池抓到尽头)期间一天只放行一轮, 恢复靠"某轮新增 >0";
  #   · 老图循环模式下放行"过期重下"(>= recycle_min_days 天没出现过), 但拦住近期看过的。
  # -IgnoreDailyCap: 库整个被清空时的补救专用(那时候"有图"比"省着用"重要)。
  $c = Get-BwConfig
  $dir = $c.spotlight_save_dir
  [void](New-BwDir $dir)
  $ok = 0; $skip = 0; $fail = 0; $first = $null
  $newFiles = @()
  $frame = 0   # 游标流动用的动画帧计数 (仅 -Counter 时用到)
  $tries = 0
  $reuse = 0   # 这一轮"回收老图"重下了几张
  $ran = $false
  $now = Get-Date
  if ($global:BWDry) {
    # 试运行: 连请求都不发 (H-8 的口径: -DryRun 不许有任何副作用, 联网请求也算)
    Log ('试运行: 本应抓取聚焦图(最多 ' + $count + ' 张), 不发请求、不下载、不写账本')
    return @()
  }
  $st = Get-BwFetchStats
  $s0 = Get-BwState
  if (-not (Test-BwFetchDue $st $now)) {
    # 低频模式: 源池抓到尽头了, 今天已经试过 -> 只留一行聚合日志, 不再每轮刷"新增0 跳过N"
    Write-BwPoolEndLine $st $Quiet.IsPresent
    return @()
  }
  $minDays = Get-BwRecycleMinDays $c
  $libNow = @(Get-BwSpotlightAll).Count
  $freshLeft = Get-BwFreshLeft $s0
  # 老图循环: 未看过的快见底(或上一轮已经出现过空轮)时才开 —— 平时新图优先
  $recycle = [bool](([int]$st.zero_rounds -gt 0) -or ($freshLeft -lt $global:BWRecycleBelow))
  $anyAge = ($libNow -eq 0)      # 库空了: 有图最重要, 老图门槛放宽
  $allow = Get-BwFetchAllow $c $st $count -IgnoreDailyCap:$IgnoreDailyCap
  if ($allow -le 0) {
    $capTxt = '20'
    try { $capTxt = [string][int]$c.fetch_day_cap } catch {}
    Log ('聚焦抓取: 今天的额度已经用完 (' + [int]$st.day_used + '/' + $capTxt + ' 张), 这一轮不下载(源池留着慢慢用)')
    if (-not $Quiet) { Write-Host ('  今天已经抓过 ' + [int]$st.day_used + ' 张了(每日上限 ' + $capTxt + ' 张), 源池留着慢慢用, 明天再抓。') -ForegroundColor DarkGray }
    return @()
  }
  if ($allow -lt $count) {
    $left = Get-BwFetchBudget $c $st
    Log ('聚焦抓取: 按上限把这一轮从 ' + $count + ' 张收到 ' + $allow + ' 张 (单轮上限 ' + [int]$c.fetch_round_cap + ' 张 / 今日还剩 ' + $left + ' 张)')
    if (-not $Quiet) { Write-Host ('  按上限收成 ' + $allow + ' 张 (单轮上限 ' + [int]$c.fetch_round_cap + ' 张 / 今日还剩 ' + $left + ' 张)') -ForegroundColor DarkGray }
  }
  $count = $allow
  $ran = $true
  $maxTries = [Math]::Max($count * 5, 20)
  # 循环只看**真的新增了几张**。以前把"已存在"也算进配额, 于是库一大(几十张),
  # 连着抽到的全是库里已有的图, 配额被"已存在"耗尽 -> 一张新图都不下,
  # 客户就一直轮换那批老图, 越用越觉得"怎么老是这几张"。
  # 另: 「看过」名单也拦一道 —— 客户把库里的图备份到网盘(本地删掉)之后,
  # 本地查不到, 光靠文件去重会把同一张图再下一遍。
  $seen = @{}
  foreach ($h in @(Get-BwHist $s0)) { if ($h) { $seen[[string]$h] = $true } }
  # 也认下载流水账(dl_ledger.log)里的编号: 库被清空/回收站清走过、或「看过」名单
  # 超 400 淘汰掉的图, 光靠文件和历史拦不住, 会被同一张图反复下。流水账是
  # “下过哪些图”的永久记录 —— 认过就不再下, 哪怕本地文件已经没了。
  foreach ($k in @(Get-BwDlKeys)) { if ($k) { $seen[[string]$k] = $true } }
  if ($Counter) { $frame = 0; Show-BwDashedCounter 0 $frame }
  while (($ok -lt $count) -and ($tries -lt $maxTries)) {
    $tries++
    $isReuse = $false
    $it = Get-SpotlightOne
    if (-not $it) { if ($Counter) { Wait-BwFlow 800 $ok ([ref]$frame) } else { Start-Sleep -Milliseconds 800 }; continue }
    # 下过的图不再下(流水账/看过名单都认)。**例外**(2026-10-09 老图回收):
    # 老图循环模式下, 至少 recycle_min_days 天没出现过的老图允许"回收重下" ——
    # 这是源池被官方新增枯竭之后"永久运行也有图可换"的兜底; 近期看过的照样拦住。
    if ($it.slug -and $seen.ContainsKey([string]$it.slug)) {
      if ($recycle -and (Test-BwOldImageReusable $s0 $it.slug $now $minDays -AnyAge:$anyAge)) {
        $isReuse = $true
      } else {
        $skip++
        if ($Counter) { Wait-BwFlow 400 $ok ([ref]$frame) } else { Start-Sleep -Milliseconds 400 }
        continue
      }
    }
    if (Test-SpotlightDup $dir $it) {
      $skip++
      if (-not $first) { $first = (Get-ChildItem -LiteralPath $dir -Filter "*_$($it.slug).jpg" -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }
      if ($Counter) { Wait-BwFlow 400 $ok ([ref]$frame) } else { Start-Sleep -Milliseconds 400 }
      continue
    }
    $path = Join-Path $dir (Get-SpotlightName $it)
    $m = @{ date=(Get-Date -Format 'yyyy-MM-dd'); title=$it.title; copyright=$it.copyright; source_type='聚焦'; source_url=$it.url; source_link='' }
    if (Save-BwFile @($it.url) $path $m) {
      $ok++
      if ($isReuse) { $reuse++ }
      $newFiles += $path
      if ($it.slug) { $seen[[string]$it.slug] = $true }   # 同一轮里别把同一张抓第二次
      if (-not $first) { $first = $path }
      if (-not $Quiet) { Write-Host ('    OK  ' + (Split-Path $path -Leaf)) }
      elseif ($Counter) { Show-BwDashedCounter $ok $frame }
    } else { $fail++ }
    if ($Counter) { Wait-BwFlow 600 $ok ([ref]$frame) } else { Start-Sleep -Milliseconds 600 }
  }
  # 计数器那行是 -NoNewline 写的, 先把这一行收掉再打总结, 免得总结接在数字后面。
  if ($Counter) {
    if ($ok -eq 0) { Show-BwDashedCounter 0 $frame }
    Write-Host ''
  }
  # 记账: 单日额度用掉多少 / 这一轮算不算空轮 / 要不要进(或退出)低频模式
  Update-BwFetchStats $st $ok $skip $fail $tries $ran $now | Out-Null
  Save-BwFetchStats $st
  $extra = ''
  if ($reuse -gt 0) { $extra = ', 回收老图 ' + $reuse + ' 张' }
  Write-Host ("  完成: 新增 $ok, 已存在 $skip, 失败 $fail" + $extra)
  if ([string]$st.mode -eq 'pool_end') {
    # 抓到尽头了: 写聚合一行(每天最多一行), 不再每轮刷"新增0 跳过N"
    if ([string]$st.low_log_day -eq $now.ToString('yyyy-MM-dd')) {
      Log ('聚焦抓取(低频模式): 新增' + $ok + ' 跳过' + $skip + ' 失败' + $fail + $extra + '；下次尝试 ' + (Format-BwTryTime ([string]$st.next_try)))
    } else {
      Write-BwPoolEndLine $st $Quiet.IsPresent
    }
  } else {
    Log ("聚焦抓取: 新增$ok 跳过$skip 失败$fail" + $extra)
  }
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
      $m = @{ date=(Get-BwDisplayDate $meta); title=$meta.title; copyright=($meta.copyright -replace '\s*[(（]©.*$',''); source_type='必应'; source_url=('https://cn.bing.com' + $meta.urlbase); source_link='https://www.bing.com' }
      if (-not (Save-BwFile (Get-BwCandidates $meta ($c.resolution_mode)) $path $m)) { Log '巡检: 下载失败, 下次再试'; return }
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

# ---- 心跳: 每轮结束留一行状态 ----
# 目的: 万一半夜出问题(壁纸不换了 / 队列卡住 / 库空了), 第二天翻日志就能一眼看出
# "它到底还在不在跑、当时是什么状态", 不用去猜。一次轮换一行, 一天约 48 行。
function Write-BwHeartbeat {
  try {
    $c = Get-BwConfig
    $s = Get-BwState
    if (-not $s) { return }
    $lib  = @(Get-BwSpotlightAll).Count
    $b    = @(Get-BwBingAll).Count
    $q    = @($s.queue | Where-Object { $_ }).Count
    $hist = @(Get-BwHist $s).Count
    $last = Get-BwTime $s.last_swap
    $next = '--:--'
    if ($last) { $next = $last.AddMinutes((Get-BwCycleMinutes $c)).ToString('MM-dd HH:mm') }
    # 源池状态进心跳: 翻日志就知道现在处于三种模式的哪一种(用户要求"别让人以为程序坏了")
    $poolLine = ''
    try { $poolLine = (Get-BwSourcePoolStatus $s).Line } catch { $poolLine = '' }
    # 2026-10-09: 两个新图源各有多少张也进心跳 —— 用户要求"翻日志能看出各源各有多少张"。
    # 关掉的源也照实报 0, 免得日志里时有时无、看不懂。
    $srcTxt = ''
    try {
      foreach ($sdef in @(Get-BwSourceDefs)) {
        $sdir = Get-BwSrcDir $c $sdef.Key
        $srcTxt += ' / ' + $sdef.Name + '库 ' + @(Get-BwSrcFiles $sdir).Count + ' 张'
      }
    } catch { $srcTxt = '' }
    # 2026-10-09: 现在桌面上这张的真实分辨率也进心跳(用户要求"心跳能看到本张 3840x2160")。
    # 顺手标一句它是怎么显示的: 铺满 / 居中+模糊底 —— 日后想复盘"这张为什么有边"时一眼就懂。
    # 注意: 取扩展名必须用 [IO.Path]::GetExtension —— 本机是 PowerShell 5.1,
    # 它**没有** Split-Path -Extension 这个参数(那是 PowerShell 7 才有的),
    # 用了会抛 ParameterBindingException, 被下面的 catch 一口吞掉 ——
    # 表现就是"心跳里永远看不到本张分辨率", 而且一声不吭(2026-10-09 自测抓到)。
    $nowTxt = ''
    try {
      $lw = [string]$s.last_wall
      if ($lw -and (Test-Path -LiteralPath $lw)) {
        $dims = Get-BwImageDim $lw
        $ext = ''
        try { $ext = [System.IO.Path]::GetExtension($lw).ToLower() } catch { $ext = '' }
        $how = ', 铺满'
        if ($ext -eq '.png') { $how = ', 居中+模糊底' }
        if ($dims) { $nowTxt = ' / 本张 ' + $dims + $how }
      }
    } catch { $nowTxt = '' }
    Log ('心跳: 聚焦库 ' + $lib + ' 张 / 必应库 ' + $b + ' 张' + $srcTxt + ' / 队列剩 ' + $q +
         ' 张 / 看过 ' + $hist + ' 条 / 累计换 ' + $s.shown + ' 次 / 上次 ' +
         $s.last_swap + $nowTxt + ' / 下次 ' + $next + ' / 源池: ' + $poolLine)
  } catch {}
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
  # 2026-10-12 (审查 P1): 跨实例锁。计划任务(开机+周期)与菜单/守护并发进来时,
  # 两个进程按同一份 last_swap 各自判定"到点了"、各换一张 -> 连跳两张、
  # history 重复记账、两份进程快照互相整份覆盖。锁 15 分钟自动过期,
  # 进程崩了不会把轮换永久卡死(照 backfill.lock 的做法)。试运行不碰锁(守 H-8 零副作用)。
  $cycLock = Join-Path $global:BWRoot 'cycle.lock'
  $lkVal = ''
  if (-not $global:BWDry) {
    if (Test-Path -LiteralPath $cycLock) {
      $lkAge = 999.0
      try { $lkAge = ((Get-Date) - (Get-Item -LiteralPath $cycLock).LastWriteTime).TotalMinutes } catch {}
      if ($lkAge -lt 15) { Log ('轮换: 已有一次轮换在进行(锁龄 ' + [int]$lkAge + ' 分钟), 本次跳过'); return }
    }
    $lkVal = (Get-Date -Format 'o')
    try { [System.IO.File]::WriteAllText($cycLock, $lkVal, (New-Object System.Text.UTF8Encoding($false))) } catch {}
  }
  # 每天顺带看一次有没有新版脚本: 只换脚本、不需要管理员权限。
  # 整段包在 try 里 —— 升级出任何问题都不许影响换壁纸。
  try {
    $dueUpd = $true
    if (Test-Path -LiteralPath $global:BWUpdateFile) {
      $cached = Get-Content -LiteralPath $global:BWUpdateFile -Raw -Encoding UTF8 | ConvertFrom-Json
      $dueUpd = (((Get-Date) - ([datetime]::FromFileTime([int64]$cached.checked_ft))).TotalHours -ge 20)
    }
    if ($dueUpd) { [void](Invoke-BwScriptUpdate -Quiet) }
  } catch { Log ('升级检查异常(不影响换壁纸): ' + $_.Exception.Message) }

  try {
    $c = Get-BwConfig
    $null = Ensure-BwDirs
    # 每次巡检顺带认一遍: 库里哪些图不是本程序下载的。只打记号, 不动文件。
    [void](Update-BwStrangers)
    $s = Get-BwState
    $now = Get-Date
    $today = $now.ToString('yyyy-MM-dd')
    # 换图间隔走护栏: 就算 config.json 被手改成离谱的值(比如一亿分钟),
    # 这里也只会拿到 1440, AddMinutes 不会溢出, 后台不会崩。
    $gap = Get-BwCycleMinutes $c

    $boot = ''
    try { $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss') } catch {}
    $rebooted = [bool]($boot -and $s.last_boot -and ($s.last_boot -ne $boot))
    if ($boot) { $s.last_boot = $boot }
    # 2026-10-17: 开机/重启后, Windows 常把“壁纸填充方式”重置回居中 —— 这里按配置校对一遍,
    # 避免开机第一张壁纸显示成居中。只在确实被改掉时才重设(不白重绘)。试运行不碰。
    if (-not $global:BWDry) {
      if (-not (Test-BwStyleOk)) {
        try {
          [void](Apply-BwWallStyle)
          Log ('开机校对填充方式: 已被系统重置, 已恢复为 ' + (Get-BwWallStyle).Label)
        } catch { Log ('开机校对填充方式失败: ' + $_.Exception.Message) 'WARN' }
      }
    }
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
            $m = @{ date=$bday; title=$meta.title; copyright=($meta.copyright -replace '\s*[(（]©.*$',''); source_type='必应'; source_url=('https://cn.bing.com' + $meta.urlbase); source_link='https://www.bing.com' }
            if (-not (Save-BwFile (Get-BwCandidates $meta ($c.resolution_mode)) $path $m)) { $path = $null }
          }
          if (-not $path) {
            # 这里必须直接 return 且不记账。以前下载失败也照样把 last_bing_date 写成今天,
            # 而 15 分钟后要不要重试恰恰是看这个字段 —— 当天就再也不会重试了,
            # 上面那句"15 分钟后再试"的日志其实是假的。
            Log '必应当日壁纸下载失败, 15 分钟后再试'
            # 2026-10-09 (审查 H-11): 这里以前是全份覆盖写。$s 是 40 多行前读的快照,
            # 中间还跑过 Invoke-BwBackfill(可能几分钟), 用户这期间按 [F] 收藏的图
            # 会被无声抹掉。同函数下面的规则 2/3 早就是 KeepFav, 这一条漏改。
            Save-BwStateKeepFav $s
            return
          }
          $ok = Set-BwWall $path
          $s.last_wall = $path
          # 【2026-10-10 修】必应当日图也要记进"看过"时间表(hist_at)。
          # 别处都记了(手动切必应见上面巡检那一段、轮换取图见 Add-BwSrcRot/Add-BwHist),
          # 只有这一处漏 —— 后果: hist_at 里永远没有必应图, Get-BwSeenDays 一律返回 -1。
          # 一旦"聚焦轮完就轮必应"(见 Get-BwFreshQueue), 它们会被当成"很老"全排到队首,
          # 今天早上刚当每日一图换过的那张, 约 21 次换图(约 10 小时)后就会原样再出现一次。
          Add-BwHist $s $name
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

    # ---- 必应模式: 只换必应、每天一张 (2026-10-20 用户要求) ----
    # 规则 1 已经负责"每天第一次换成必应当日图"; 这里只额外处理"重启后把当天那张贴回去",
    # 然后直接收工 —— 不做半小时轮换、不抓聚焦。
    if ([bool]$c.bing_only) {
      if ($rebooted) {
        $bwp = ''
        try {
          $bmeta = Get-BwMeta 0
          if ($bmeta) {
            $bdt = Get-BwDisplayDate $bmeta
            $bpp = Get-BwTargetPath $bdt (Get-BwName $bmeta)
            if (Test-Path -LiteralPath $bpp) { $bwp = $bpp }
          }
        } catch {}
        if (-not $bwp -and $s.last_wall -and (Test-Path -LiteralPath $s.last_wall)) { $bwp = $s.last_wall }
        if ($bwp) {
          if ($global:BWDry) {
            Log ('试运行: 必应模式重启后本应贴回 ' + (Split-Path $bwp -Leaf))
          } else {
            [void](Set-BwWall $bwp)
            $s.last_wall = $bwp
            Log ('必应模式: 重启后贴回 ' + (Split-Path $bwp -Leaf))
          }
        } else {
          Log '必应模式: 重启后没找到当日必应图, 等下一轮再试'
        }
      }
      Save-BwStateKeepFav $s
      return
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
  finally {
    # 2026-10-12: 释放轮换锁 —— 只删自己写的那一份(内容对得上才删),
    # 免得锁被判定过期后由新持有者接管、旧持有者反而把人家的锁删了。
    if (-not $global:BWDry -and $lkVal) {
      try {
        if ((Test-Path -LiteralPath $cycLock) -and ((Get-Content -LiteralPath $cycLock -Raw -ErrorAction SilentlyContinue) -eq $lkVal)) {
          [System.IO.File]::Delete($cycLock)
        }
      } catch {}
    }
    # 每轮都留一行心跳 —— 正常结束、异常、以及三条规则里提前 return 的路径
    # 都会走到 finally, 所以日志里"有没有这行"本身就能判断它是否还活着。
    Write-BwHeartbeat
  }
}
# ==================== 网页控制台接口 (V2.4.0) ====================
# 为什么面板 HTML 内嵌在本文件里:
#   升级只替换 core.ps1 / menu.ps1 两个文件 —— 老客户端的升级循环里**写死了这两个名字**,
#   多放一个 panel.html 老用户永远收不到。所以 HTML 跟着脚本走, 由 launcher 释放成
#   数据目录里的 panel.html, 再交给浏览器。
# 为什么用"请求文件 / 结果文件"而不是命令行参数 / stdout:
#   PS 5.1 传中文参数、抓 stdout 都踩过编码坑(ANSI 乱码、BOM 混入)。写文件 + 明确 UTF-8 最省事。
# 为什么不在本文件里开端口:
#   本文件会被计划任务、菜单、面板同时调用, 每次都是独立进程, 活不长。端口、令牌、浏览器
#   都归 launcher.py 管; 这里只负责"读一个请求 → 干活 → 写一个结果"。

# >>> PANEL_HTML_BEGIN（本段由 tools/embed_panel.py 从 panel.html 生成，勿手改）
$global:BwPanelHtml = @'
<!DOCTYPE html>
<!--
  桌面壁纸 · 控制台
  作者: 海风（kele551）   https://github.com/kele551/ms-wallpaper-assistant
  说明: 由 menu.ps1 起本地服务后打开; 只与本机 127.0.0.1 通信, 不联网、不引外部资源。
        页面里的 {{BWPANEL_TOKEN}} 由脚本在返回时替换成一次性令牌。
  2026-10-24 UI 整改: 分「当前 / 图库 / 设置」三块(单页切换, 不路由);
        图库走新接口 ?panel=gallery 与 ?panel=thumb(只读、只回数据目录里的图片、支持 304)。
        倒计时环纯前端计时 —— 页面**不再轮询**本机服务(它是单线程手写 TcpListener)。
-->
<html lang="zh-CN" data-theme="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="#171a20">
<title>桌面壁纸 · 控制台</title>
<style>
  :root{
    --font:"Microsoft YaHei UI","Microsoft YaHei","PingFang SC","Segoe UI",system-ui,sans-serif;
    --mono:"Cascadia Mono",Consolas,"Courier New",monospace;
    /* 暗色(默认) = 石墨灰 */
    --bg:#171a20; --bg-1:#1c2027; --card:#20252d; --card-2:#262d37;
    --line:#303844; --line-2:#3e4856;
    --txt:#e7ebf1; --txt-2:#a3aebe; --txt-3:#76818f;
    --ok:#3ecf8e; --warn:#f0b429; --danger:#f2555a; --info:#4f8cff;
    --accent:#35d07f; --accent-ink:#062016;
    --fs-title:20px; --fs-h:14px; --fs-body:13px; --fs-meta:12px; --fs-micro:11px;
    --r-card:10px; --r-btn:8px; --r-pill:999px;
    --shadow-1:0 1px 0 rgba(0,0,0,.18); --shadow-2:0 14px 40px rgba(0,0,0,.45);
    --sp-1:4px; --sp-2:8px; --sp-3:12px; --sp-4:16px; --sp-5:20px; --sp-6:24px;
    --knob:#fff; --on-art:#fff; --on-art-2:rgba(255,255,255,.78);
    --scrim:rgba(6,9,14,.66); --scrim-2:rgba(6,9,14,.12);
    --accent-soft:rgba(53,208,127,.14);
    --accent-line:rgba(53,208,127,.45);
    --ok-soft:rgba(62,207,142,.16); --warn-soft:rgba(240,180,41,.16); --danger-soft:rgba(242,85,90,.16);
    /* 浏览器原生那部分（滚动条/表单控件/日期弹层）跟着主题走，
       否则暗色面板配一条亮色滚动条。2026-10-24 四款一起补。 */
    color-scheme:dark;
  }
  [data-theme="light"]{
    --bg:#f3f5f9; --bg-1:#e9edf4; --card:#ffffff; --card-2:#f7f9fc;
    --line:#e2e7ef; --line-2:#d3dae5;
    --txt:#17202b; --txt-2:#5b6675; --txt-3:#8a96a5;
    --ok:#12a150; --warn:#a86f00; --danger:#d13438; --info:#1a5fd0;
    --accent:#0f9d58; --accent-ink:#fff;
    --shadow-1:0 1px 0 rgba(16,30,54,.04); --shadow-2:0 18px 40px rgba(20,34,60,.14);
    --scrim:rgba(4,10,18,.58); --scrim-2:rgba(4,10,18,.06);
    --accent-soft:rgba(15,157,88,.12);
    --accent-line:rgba(15,157,88,.42);
    --ok-soft:rgba(18,161,80,.12); --warn-soft:rgba(168,111,0,.12); --danger-soft:rgba(209,52,56,.12);
    color-scheme:light;
  }
  *{box-sizing:border-box}
  html,body{height:100%}
  body{margin:0;background:var(--bg);color:var(--txt);font:var(--fs-body)/1.5 var(--font);-webkit-font-smoothing:antialiased}
  h1,h2,h3,p{margin:0}
  button,select,input{font:inherit;color:inherit}
  button{cursor:pointer;background:none;border:0}
  :focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:6px}
  ::-webkit-scrollbar{width:10px;height:10px}
  ::-webkit-scrollbar-thumb{background:var(--line-2);border-radius:8px;border:2px solid var(--bg)}
  ::-webkit-scrollbar-track{background:transparent}

  .wrap{max-width:1160px;margin:0 auto;padding:var(--sp-5) var(--sp-5) var(--sp-6);
        display:flex;flex-direction:column;gap:var(--sp-4)}

  /* 顶栏 */
  .top{display:flex;align-items:center;justify-content:space-between;gap:var(--sp-4);flex-wrap:wrap}
  .brand{display:flex;align-items:center;gap:var(--sp-3);min-width:0}
  .logo{width:36px;height:36px;border-radius:10px;background:var(--accent);color:var(--accent-ink);
        display:grid;place-items:center;font-weight:700;font-size:15px;flex:none}
  .brand h1{font-size:var(--fs-title);font-weight:650;letter-spacing:.2px}
  .brand p{color:var(--txt-3);font-size:var(--fs-meta);margin-top:2px}
  .top-r{display:flex;align-items:center;gap:var(--sp-2)}

  /* 分段控件(当前 / 图库 / 设置) */
  .segbar{display:flex;align-items:center;gap:var(--sp-3);flex-wrap:wrap}
  .seg{display:inline-flex;gap:2px;padding:3px;border:1px solid var(--line);border-radius:var(--r-pill);background:var(--card)}
  .seg-btn{height:28px;padding:0 var(--sp-4);border-radius:var(--r-pill);border:0;background:none;
           color:var(--txt-2);font-size:var(--fs-meta);transition:color .15s,background .15s}
  .seg-btn:hover{color:var(--txt)}
  .seg-btn.on{background:var(--accent-soft);color:var(--accent);font-weight:600}
  .seg-info{margin-left:auto;color:var(--txt-3);font-size:var(--fs-micro);font-family:var(--mono)}
  .screen{display:none}
  .screen.on{display:block;animation:fade .15s ease}
  @keyframes fade{from{opacity:0;transform:translateY(3px)}to{opacity:1;transform:none}}

  /* 通用组件 */
  .card{background:var(--card);border:1px solid var(--line);border-radius:var(--r-card);padding:var(--sp-4);
        box-shadow:var(--shadow-1)}
  .card.pad0{padding:0;overflow:hidden}
  .card-h{display:flex;align-items:center;gap:var(--sp-2);margin-bottom:var(--sp-3);flex-wrap:wrap}
  .card-h h2{font-size:var(--fs-h);font-weight:600}
  .card-h .right{margin-left:auto;display:flex;align-items:center;gap:var(--sp-2);flex-wrap:wrap}
  .muted{color:var(--txt-3)}
  .mono{font-family:var(--mono);font-size:var(--fs-meta)}
  .xs{font-size:var(--fs-micro)}
  .t-lg{font-size:17px;font-weight:650}

  /* 2026-10-25（用户截图：控制台整页都是「—」）：连不上本机服务时，唯一的提示是顶栏
     那颗小胶囊，一滚动就没影了，剩下满屏"读不到值"看着像程序坏了。真实原因是控制台
     每从快捷图标打开一次就换一个随机端口、服务闲置约 30 分钟自动退出 —— 旧标签页永远
     连不回去。所以在内容区顶部（三个视图都看得见）钉一条说明，把话说清楚。 */
  .offnote{display:flex;flex-direction:column;gap:var(--sp-2);align-items:flex-start;
           background:var(--danger-soft);border:1px solid var(--danger);border-radius:var(--r-card);
           padding:var(--sp-4);margin-bottom:var(--sp-4)}
  .offnote[hidden]{display:none}
  .offnote b{font-size:var(--fs-h);color:var(--txt)}
  .offnote span{font-size:var(--fs-body);color:var(--txt-2);line-height:1.7}

  .pill{display:inline-flex;align-items:center;gap:6px;height:24px;padding:0 var(--sp-3);border-radius:var(--r-pill);
        border:1px solid var(--line);font-size:var(--fs-micro);color:var(--txt-2);white-space:nowrap;background:var(--card-2)}
  .pill i{width:6px;height:6px;border-radius:50%;background:var(--txt-3);flex:none}
  .pill.ok i{background:var(--ok);box-shadow:0 0 0 3px var(--ok-soft)}
  .pill.warn i{background:var(--warn);box-shadow:0 0 0 3px var(--warn-soft)}
  .pill.bad i{background:var(--danger);box-shadow:0 0 0 3px var(--danger-soft)}

  .btn{height:30px;padding:0 var(--sp-3);border-radius:var(--r-btn);border:1px solid var(--line);
       background:var(--card-2);color:var(--txt);font-size:var(--fs-meta);display:inline-flex;align-items:center;gap:6px;
       transition:border-color .15s,background .15s,color .15s;white-space:nowrap}
  .btn:hover{border-color:var(--line-2);background:var(--card)}
  .btn:disabled{opacity:.45;cursor:not-allowed}
  .btn.primary{background:var(--accent);border-color:transparent;color:var(--accent-ink);font-weight:600}
  .btn.primary:hover{filter:brightness(1.07);background:var(--accent)}
  .btn.ghost{background:transparent;border-color:transparent;color:var(--txt-2)}
  .btn.ghost:hover{color:var(--txt);background:var(--card-2)}
  .btn.danger{color:var(--danger);border-color:var(--danger)}
  .btn.danger:hover{background:var(--danger-soft)}
  .btn.sm{height:24px;padding:0 var(--sp-2);font-size:var(--fs-micro)}
  .btn.icon{width:30px;padding:0;justify-content:center}
  .btn.primary kbd{border-color:var(--accent-ink);color:var(--accent-ink);opacity:.7;background:transparent}
  .btn svg{width:16px;height:16px;stroke:currentColor;fill:none;stroke-width:1.7;stroke-linecap:round;stroke-linejoin:round}
  .btn.on{border-color:var(--accent-line);color:var(--accent);background:var(--accent-soft)}

  kbd{font:500 10px/1 var(--mono);color:var(--txt-3);border:1px solid var(--line-2);border-radius:5px;
      padding:3px 5px;background:var(--card)}

  .chip{height:26px;padding:0 var(--sp-3);border-radius:var(--r-pill);border:1px solid var(--line);
        background:transparent;color:var(--txt-2);font-size:var(--fs-meta);display:inline-flex;align-items:center;gap:6px;
        transition:background .15s,border-color .15s,color .15s;white-space:nowrap;cursor:pointer}
  .chip:hover{color:var(--txt);border-color:var(--line-2)}
  .chip.on{background:var(--accent-soft);border-color:var(--accent-line);color:var(--accent);font-weight:600}
  .chip.add{border-style:dashed;color:var(--txt-3)}
  .chiprow{display:flex;gap:6px;flex-wrap:wrap}

  .sw{width:36px;height:20px;border-radius:var(--r-pill);background:var(--line-2);position:relative;
      flex:none;transition:background .18s;border:0}
  .sw::after{content:"";position:absolute;top:2px;left:2px;width:16px;height:16px;border-radius:50%;
             background:var(--knob);transition:transform .18s;box-shadow:0 1px 2px rgba(0,0,0,.35)}
  .sw.on{background:var(--accent)}
  .sw.on::after{transform:translateX(16px)}

  /* 句子式设置行(标题 + 一句说明 + 控件)
     2026-10-25 再收口（用户指着「高级」卡问"这样好看吗"）：这一卡里三种排版打架——
     「版本」是标题左、值右；「数据目录」的「打开」被三行文字挤到行中间浮着；「操作」
     又整行左对齐。根因是 .ctl 用 align-self:center，控件对齐的是**整行的中线**，
     行里文字一多，控件就飘到半空。改成一律对齐**标题那一行**：
     标题行高写死 28px（正好是最常用控件 .inp/.btn.sm 的高度），控件给 min-height:28px，
     于是文字值、开关、输入框、按钮的垂直中心全落在同一条线上，右边界本来就贴着卡片内边距。 */
  .set{display:flex;align-items:flex-start;gap:var(--sp-3);padding:var(--sp-3) 0;border-top:1px solid var(--line)}
  .set:first-of-type{border-top:0}
  .set .txt{flex:1;min-width:0}
  .set .txt b{display:block;font-size:var(--fs-body);font-weight:550;line-height:28px}
  .set .txt span{display:block;color:var(--txt-3);font-size:var(--fs-meta);margin-top:2px}
  .set .ctl{align-self:flex-start;flex:none;min-height:28px;display:flex;align-items:center;gap:var(--sp-2);flex-wrap:wrap;justify-content:flex-end}
  .set.col{flex-direction:column;align-items:stretch}
  /* 2026-10-25 对齐/收边：上面 .set .ctl 的 align-self 在竖排行里会赢过
     .set.col 的 align-items:stretch，于是「补货/补齐」「本地文件夹图源」这些
     整行排开的控件全部飘到卡片中间，和左边的标题对不上。这里把它掰回左对齐，
     同时给 max-width:100% —— 长路径、长目录名换行收在卡片里，不再顶穿右边框。 */
  .set.col .ctl{align-self:flex-start;justify-content:flex-start;max-width:100%;margin-top:var(--sp-2)}
  .set.col .ctl .mono{text-align:left;overflow-wrap:anywhere}

  .inp{height:28px;border-radius:var(--r-btn);border:1px solid var(--line-2);background:var(--card-2);
       color:var(--txt);padding:0 var(--sp-2);font-size:var(--fs-meta);width:88px;text-align:right;
       font-family:var(--mono);font-variant-numeric:tabular-nums}
  .selinp{height:28px;border-radius:var(--r-btn);border:1px solid var(--line-2);background:var(--card-2);
       color:var(--txt);padding:0 var(--sp-2);font-size:var(--fs-meta)}
  input[type=range]{-webkit-appearance:none;appearance:none;flex:1;height:6px;border-radius:var(--r-pill);
       background:var(--line-2);outline:none;min-width:120px}
  input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:16px;height:16px;border-radius:50%;
       background:var(--accent);box-shadow:0 2px 8px rgba(0,0,0,.4);cursor:pointer}
  input[type=range]::-moz-range-thumb{width:16px;height:16px;border:0;border-radius:50%;background:var(--accent);cursor:pointer}
  input[type=range]:disabled{opacity:.45;cursor:not-allowed}
  .chiprow.locked{opacity:.5;pointer-events:none}

  /* 统计卡 */
  .stats{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:var(--sp-3)}
  .stat{background:var(--card);border:1px solid var(--line);border-radius:var(--r-card);padding:var(--sp-3) var(--sp-4)}
  .stat .k{color:var(--txt-3);font-size:var(--fs-micro);letter-spacing:.04em}
  .stat .v{font-size:24px;font-weight:650;line-height:1.25;margin-top:var(--sp-1);
           font-variant-numeric:tabular-nums}
  .stat .v small{font-size:var(--fs-meta);font-weight:500;color:var(--txt-3);margin-left:var(--sp-1)}
  .stat .d{font-size:var(--fs-micro);color:var(--txt-3);margin-top:2px}

  /* 进度条 / 倒计时环 */
  .meter{height:6px;border-radius:var(--r-pill);background:var(--line);overflow:hidden;margin:var(--sp-3) 0 var(--sp-2)}
  .meter i{display:block;height:100%;border-radius:var(--r-pill);background:var(--accent);width:0;
           transition:width .15s linear}
  .ring{width:52px;height:52px;border-radius:50%;flex:none;display:grid;place-items:center;
        background:conic-gradient(var(--accent) calc(var(--p)*1%),var(--line) 0);position:relative;
        transition:background .15s linear}
  .ring::before{content:"";position:absolute;inset:5px;border-radius:50%;background:var(--card)}
  .ring span{position:relative;font-size:var(--fs-h);font-weight:650;font-variant-numeric:tabular-nums;
             display:inline-flex;align-items:baseline;gap:1px}
  .ring small{font-size:var(--fs-micro);color:var(--txt-3);font-weight:400}

  /* 当前壁纸大图 */
  .art{position:relative;aspect-ratio:16/9;background:var(--bg-1);overflow:hidden}
  .art img{width:100%;height:100%;object-fit:cover;display:block;opacity:0;transition:opacity .3s ease}
  .art img.ready{opacity:1}
  .art img:not([src]){visibility:hidden}
  .art::after{content:"";position:absolute;inset:0;pointer-events:none;
    background:linear-gradient(to top,var(--scrim),var(--scrim-2) 56%,transparent 82%)}
  .art .cap{position:absolute;left:var(--sp-4);right:var(--sp-4);bottom:var(--sp-3);z-index:2}
  .art .cap .badge{display:inline-block;font-size:var(--fs-micro);letter-spacing:.05em;color:var(--on-art);
    background:rgba(255,255,255,.16);border:1px solid rgba(255,255,255,.22);border-radius:var(--r-pill);
    padding:3px var(--sp-2)}
  .art .cap h3{color:var(--on-art);font-size:var(--fs-title);font-weight:650;margin-top:var(--sp-2);
    text-shadow:0 2px 12px rgba(0,0,0,.45);word-break:break-all}
  .art .cap p{color:var(--on-art-2);font-size:var(--fs-meta);margin-top:2px}
  .art .empty{position:absolute;inset:0;display:grid;place-items:center;color:var(--txt-3);
    font-size:var(--fs-meta);z-index:1}

  .nextrow{display:flex;align-items:center;gap:var(--sp-3);padding:var(--sp-3) var(--sp-4) 0}
  .nextrow .grow{flex:1;min-width:0}
  .acts{display:flex;gap:var(--sp-2);flex-wrap:wrap;padding:var(--sp-3) var(--sp-4)}
  .monrow{display:flex;align-items:center;gap:var(--sp-2);padding:0 var(--sp-4) var(--sp-4);flex-wrap:wrap}
  .lbl{letter-spacing:.04em}

  /* 缩略图网格(16:10)
     【2026-10-25 用户「文字比例不和谐」】原来一行 6 张：单张 112x70，悬停那排按钮
     （设为壁纸 58px + 收藏 + 原图，共约 130px）比格子还宽，直接溢出到隔壁格、
     第三个按钮被切掉 —— 看着就是"字比图大"。改成一行 4 张（约 170x106），
     和下方图库 .gallery 的格子同一量级，按钮排得下、文字比例也就顺了。 */
  .thumbs{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:var(--sp-2)}
  .gallery{display:grid;grid-template-columns:repeat(auto-fill,minmax(152px,1fr));gap:var(--sp-2)}
  .tile{position:relative;margin:0;aspect-ratio:16/10;border-radius:var(--r-btn);overflow:hidden;
        border:1px solid var(--line);background:var(--bg-1);cursor:pointer;padding:0;
        transition:border-color .15s,transform .15s}
  .tile:hover{border-color:var(--accent);transform:translateY(-2px)}
  .tile img{width:100%;height:100%;object-fit:cover;display:block}
  .tile.sel{outline:2px solid var(--accent);outline-offset:1px}
  .tile-d{position:absolute;left:6px;bottom:6px;font-size:var(--fs-micro);color:var(--on-art);
    background:rgba(0,0,0,.45);border-radius:5px;padding:1px 5px;font-variant-numeric:tabular-nums}
  .tile-star{position:absolute;right:6px;top:5px;font-size:var(--fs-micro);color:var(--warn);
    background:rgba(0,0,0,.5);border-radius:5px;padding:1px 5px;line-height:1.3}
  .tile-acts{position:absolute;left:0;right:0;bottom:0;display:flex;gap:var(--sp-1);padding:var(--sp-2);
    background:linear-gradient(to top,var(--scrim),transparent);opacity:0;transform:translateY(4px);
    transition:opacity .15s,transform .15s}
  .tile:hover .tile-acts,.tile:focus-within .tile-acts{opacity:1;transform:none}
  .tile-acts .btn{height:22px;padding:0 6px;font-size:var(--fs-micro)}
  .empty{padding:var(--sp-5) var(--sp-4);text-align:center;color:var(--txt-3);font-size:var(--fs-meta);
    display:flex;flex-direction:column;align-items:center;gap:var(--sp-2)}
  .loadmore{display:flex;justify-content:center;padding-top:var(--sp-3)}

  /* 2026-10-25 收边（「最近动作」末行被横切半截，用户截图）：
     1) 断词从 break-all 换成 anywhere：中文按词断行，只有超长 URL / 长 token 这种没有
        空格的东西才允许在任意位置断开，不再出现「版本 v / 2.4.1」这种断法。
     2) 行高写死 18px，框高 = 7 行 + 边框。关键是**竖向内边距只能是 0 或 18px 的整数倍**：
        overflow 的裁剪线在内边距盒上，底部那 8px 内边距也算可视区，于是第 8 行总会露出
        上半截（实测 7~8px）；就算把它挪到顶部，钉到底时裁剪线又会落在某一行的中间
        （实测上沿切 8px）。改成上下 0 之后，滚动到底的裁剪位置 = 18 的整数倍，
        两头都正好压在行与行之间。以后要给日志框加呼吸感，请把内边距写成 18px 的整倍数。
     3) 光对齐还不够：日志是从旧往新排的，框只放得下 7 行，停在顶部就等于把最新那条
        藏在滚动条下面（截图里被切半截的正是最新那条）。渲染完钉到底见 renderLog()。
     4) 2026-10-25 再改（用户："这个日志框可以再往下拉，对齐左边"）：
        · 左对齐：框的边框本来就贴着卡片内容左沿，但**里面那 12px 横向内边距**把第一行字
          顶到比「最近动作」标题还右 12px，看着就是没对齐。改成框往外扩 12px（负外边距）、
          内边距仍 12px —— 边框离卡片边 4px，文字左沿和卡里所有文字同一条线。
        · 往下拉：框高不再写死 7 行，改由 fitLog() 按卡片剩余空间取**整行**填到底
          （等高网格里邻居卡片撑出来的空白，正好被它吃掉）。CSS 这里留 12 行做兜底。 */
  .log{font:var(--fs-micro)/18px var(--mono);color:var(--txt-2);background:var(--bg-1);
       border:1px solid var(--line);border-radius:var(--r-btn);padding:0 var(--sp-3);
       margin:0 calc(var(--sp-3) * -1);
       max-height:calc(18px*12 + 2px);overflow:auto;white-space:pre-wrap;
       overflow-wrap:anywhere}

  /* 库容条（下载卡底部）：名称 44px + 进度槽 + 右对齐数值，三行同宽同基线 */
  .capbar{display:flex;flex-direction:column;gap:6px;margin-top:var(--sp-2)}
  .capline{display:flex;align-items:center;gap:var(--sp-2);font-size:var(--fs-meta)}
  .capline .capname{width:44px;flex:none;color:var(--txt-2)}
  .capline .captrack{flex:1;min-width:60px;height:6px;border-radius:3px;background:var(--card-2);overflow:hidden}
  .capline .captrack i{display:block;height:100%;width:0;border-radius:3px;background:var(--accent)}
  .capline .captrack i.full{background:var(--warn)}
  .capline .capnum{width:104px;flex:none;text-align:right;color:var(--txt-3);
                   font-family:var(--mono);font-size:var(--fs-micro)}

  .sk{background:linear-gradient(90deg,var(--line) 25%,var(--line-2) 37%,var(--line) 63%);
      background-size:400% 100%;animation:sk 1.4s linear infinite;border-radius:5px;height:10px}
  @keyframes sk{0%{background-position:100% 0}100%{background-position:-100% 0}}

  .toast{position:fixed;left:50%;bottom:var(--sp-6);transform:translate(-50%,14px);opacity:0;pointer-events:none;
    background:var(--card);border:1px solid var(--line-2);box-shadow:var(--shadow-2);border-radius:var(--r-btn);
    padding:var(--sp-2) var(--sp-4);font-size:var(--fs-meta);z-index:40;max-width:min(560px,92vw);
    transition:opacity .15s,transform .15s}
  .toast.on{opacity:1;transform:translate(-50%,0)}
  .toast.bad{border-color:var(--danger);color:var(--danger)}

  .foot{display:flex;flex-direction:column;align-items:center;gap:var(--sp-2);text-align:center;
        color:var(--txt-3);font-size:var(--fs-meta);padding-top:var(--sp-2)}
  .foot .links{display:flex;gap:var(--sp-3);flex-wrap:wrap;justify-content:center}
  .foot a{color:var(--txt-2);text-decoration:none;border-bottom:1px dotted var(--line-2)}
  .foot a:hover{color:var(--accent);border-bottom-color:var(--accent-line)}
  .foot .repo{font-family:var(--mono);font-size:var(--fs-micro);display:flex;gap:6px;flex-wrap:wrap;justify-content:center}

  .cols-2{display:grid;grid-template-columns:minmax(0,1.55fr) minmax(300px,1fr);gap:var(--sp-4);align-items:start}
  .col{display:flex;flex-direction:column;gap:var(--sp-4);min-width:0}
  /* 2026-10-25（用户："这样好看吗"）：align-items:start 让同一行的两张卡各自高度，
     「换图」卡到 1000px、「下载」卡到 830px，底边一高一低。改成 stretch 后同一行等高，
     底边齐平；矮的那张多出来的空白在卡内，读起来是留白而不是错位。 */
  .setgrid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:var(--sp-4)}
  .setfoot{margin-top:var(--sp-4);text-align:center}
  @media (max-width:1000px){
    .cols-2{grid-template-columns:minmax(0,1fr)}
    .setgrid{grid-template-columns:minmax(0,1fr)}
  }
  @media (max-width:640px){
    .wrap{padding:var(--sp-3) var(--sp-3) var(--sp-5)}
    .thumbs{grid-template-columns:repeat(2,minmax(0,1fr))}
    .brand p{display:none}
  }
  @media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
</style>
<script>
/* 首屏观感（2026-10-24 加防闪 + 2026-10-25 把持久层从浏览器搬到 config.json）
   两件老毛病一起治：
   1) 防闪：<html> 上写死 data-theme="dark"，真主题原来要等 body 末尾才赋值 —— 系统浅色时
      打开会先黑一下再变白。这段在 </head> 前就把明暗（和主色）定下来。
   2) 别再丢：面板端口是每次开机现抢的随机口（实测同一台机器 10845 -> 38919），端口一变
      就是另一个 origin，localStorage 里存的明暗/主色再也读不出来 —— 用户选过的等于静默丢失。
      现在 core.ps1 出页面时把 config.json 里的值替换进 BWUI_THEME / BWUI_ACCENT 两个占位符。
   取值口径（本页唯一一处，下面 themeMode() 和「外观」面板都走它）：
      ?theme= 最优先（截图/验收用，不写记忆）
      > 本次页面上刚点的
      > 服务端下发的 seed（空串 = 服务端没意见）
      > 本机 localStorage（升级前只有这一层的老用户，观感不变样）
      > 跟随系统
   这段只读不写；写入由页尾「外观」面板负责（同时落 localStorage 和 config.json）。 */
(function(){
  var TL = ['auto','light','dark'], AL = ['default','blue','green','violet','amber'];
  function pick(v, list){
    v = String(v === null || v === undefined ? '' : v).trim().toLowerCase();
    return list.indexOf(v) >= 0 ? v : '';
  }
  /* 占位符没被替换（直接双击打开这个文件）时 pick 认不出来 -> 空串 = 没意见，不会把花括号当主题 */
  var seedT = pick('{{BWUI_THEME}}', TL);
  var seedA = pick('{{BWUI_ACCENT}}', AL);
  var curM = '', curA = '';
  function ls(k){ try { return localStorage.getItem(k) || ''; } catch(e){ return ''; } }
  window.__BWUI = {
    mode:   function(){ return curM || seedT || pick(ls('ui-theme-mode'), TL) || pick(ls('bw-theme'), ['light','dark']) || 'auto'; },
    accent: function(){ return curA || seedA || pick(ls('ui-accent'), AL) || 'default'; },
    sysTheme: function(){
      try { return (window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches) ? 'light' : 'dark'; }
      catch(e){ return 'dark'; }
    },
    effTheme: function(){ var m = this.mode(); return (m === 'light' || m === 'dark') ? m : this.sysTheme(); },
    /* 记在本机浏览器这一层（老键一并写，升级回来的用户观感不断档） */
    setLS: function(obj){
      try { for (var k in obj){ if (Object.prototype.hasOwnProperty.call(obj, k)) localStorage.setItem(k, obj[k]); } } catch(e){}
      if (obj['ui-theme-mode']) curM = pick(obj['ui-theme-mode'], TL);
      if (obj['ui-accent']) curA = pick(obj['ui-accent'], AL);
    },
    /* 落到 config.json：这样换端口、换浏览器、重开都还在。api() 是后面那段脚本里的函数，
       这里只在用户点击后才调用，那时它已经定义好了。失败不拦界面（面板会 toast）。 */
    persist: function(key, value){
      var m = pick(value, key === 'panel_theme' ? TL : AL);
      if (!m) return;
      try { if (typeof api === 'function') api('set', { key: key, value: m })['catch'](function(){}); } catch(e){}
    },
    seedTheme: seedT, seedAccent: seedA
  };
  var U = window.__BWUI, R = document.documentElement;
  try {
    var q = String(location.search || '').match(/[?&]theme=(dark|light)\b/);
    R.setAttribute('data-theme', q ? q[1] : U.effTheme());
  } catch(e){}
  try { var a = U.accent(); if (a !== 'default') R.setAttribute('data-accent', a); } catch(e){}
})();
</script>
</head>
<body>
<div class="wrap">

  <header class="top">
    <div class="brand">
      <span class="logo" aria-hidden="true">壁</span>
      <div>
        <h1>桌面壁纸</h1>
        <p>必应每日 + 微软聚焦 · 自动更换 · 绿色单文件</p>
      </div>
    </div>
    <div class="top-r">
      <span class="pill" id="statusPill"><i></i><span id="statusText">连接中…</span></span>
      <button class="btn ghost icon" id="themeBtn" title="切换明暗" aria-label="切换明暗">
        <svg viewBox="0 0 24 24" id="themeIcon"><path d="M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5z"/></svg>
      </button>
    </div>
  </header>

  <div class="segbar">
    <div class="seg" role="tablist" aria-label="视图">
      <button class="seg-btn on" data-screen="now" role="tab" aria-selected="true">当前</button>
      <button class="seg-btn" data-screen="lib" role="tab" aria-selected="false">图库</button>
      <button class="seg-btn" data-screen="set" role="tab" aria-selected="false">设置</button>
    </div>
    <span class="seg-info" id="segInfo">正在读取本机状态…</span>
  </div>

  <main>
    <!-- 连不上本机服务时才会显示（默认 hidden），三个视图都在它下面，见 .offnote 注释 -->
    <div class="offnote" id="offNote" hidden>
      <b>这一页没连上本机服务，所以下面全是「—」</b>
      <span>不是壁纸出了故障：控制台每从「桌面壁纸」图标打开一次就换一个随机端口，服务闲置约 30 分钟也会自动退出，
        旧标签页从此连不回去。重新双击一次「桌面壁纸」（桌面上的图标、任务栏上钉着的那个、或者那个 exe，
        哪个顺手用哪个），就会开出一页新的控制台。</span>
      <span>服务还活着的时候点「重试」也能连回来。<i id="offWhy" class="muted xs"></i></span>
      <button class="btn sm" id="offRetry">重试</button>
    </div>
    <!-- ============ 1. 当前 ============ -->
    <section class="screen on" id="s-now">
      <div class="cols-2">
        <div class="col">
          <div class="card pad0">
            <div class="art" id="hero">
              <img id="heroImg" alt="">
              <div class="empty" id="heroEmpty">正在读取本机状态…</div>
              <div class="cap">
                <span class="badge" id="heroBadge">当前壁纸</span>
                <h3 id="heroTitle">—</h3>
                <p id="heroSub">—</p>
              </div>
            </div>
            <div class="acts">
              <button class="btn primary" id="btnSwap">立即换一张 <kbd>Space</kbd></button>
              <button class="btn" id="btnFav">收藏 <kbd>F</kbd></button>
              <button class="btn" id="btnOpenImg">看原图</button>
            </div>
            <div class="monrow">
              <span class="muted xs lbl">显示器</span>
              <span class="chip on" id="chipScreen" title="多屏支持暂不做">主屏 —</span>
              <span class="muted xs" title="多屏支持暂不做">多屏待做</span>
            </div>
          </div>

          <div class="card">
            <div class="card-h">
              <h2>最近换过</h2>
              <span class="muted xs">点一下设为壁纸</span>
              <div class="right"><button class="btn ghost sm" id="btnAll">全部 ›</button></div>
            </div>
            <div class="thumbs" id="hist"></div>
            <div class="empty" id="histEmpty" style="display:none">还没有换过图</div>
          </div>
        </div>

        <div class="col">
          <div class="card">
            <div class="card-h">
              <h2>更换节奏</h2>
              <span class="pill ok"><i></i><span id="cycPill">—</span></span>
            </div>
            <div class="chiprow" id="cycChips">
              <button class="chip cyc-chip" data-v="10">10 分</button>
              <button class="chip cyc-chip" data-v="30">30 分</button>
              <button class="chip cyc-chip" data-v="60">1 小时</button>
              <button class="chip cyc-chip" data-v="240">4 小时</button>
              <button class="chip cyc-chip" data-v="720">12 小时</button>
              <button class="chip cyc-chip" data-v="1440">24 小时</button>
            </div>
            <div class="meter"><i id="cycMeter"></i></div>
            <p class="muted xs" id="cycHint">—</p>
          </div>

          <div class="stats">
            <div class="stat"><div class="k">图库</div><div class="v" id="statLib">—</div><div class="d">必应 + 聚焦</div></div>
            <div class="stat"><div class="k">收藏</div><div class="v" id="statFav">—</div><div class="d">打开「只看收藏」单独看</div></div>
            <div class="stat"><div class="k">队列剩余</div><div class="v" id="statQueue">—</div><div class="d">剩 2 张时自动补</div></div>
            <div class="stat"><div class="k">累计下载</div><div class="v" id="statDl">—</div><div class="d">从装上那天算起</div></div>
          </div>
        </div>
      </div>
    </section>

    <!-- ============ 2. 图库 ============ -->
    <section class="screen" id="s-lib">
      <div class="card">
        <div class="card-h">
          <h2>图库</h2>
          <span class="muted xs" id="libCount">—</span>
          <div class="right">
            <span class="chip on lib-chip" data-src="all">全部</span>
            <span class="chip lib-chip" data-src="bing">必应</span>
            <span class="chip lib-chip" data-src="spotlight">聚焦</span>
            <span class="chip lib-chip" data-src="local" id="libLocalChip" style="display:none">本地文件夹</span>
            <button class="btn ghost sm" id="libFav">只看收藏</button>
            <button class="btn ghost sm" id="libOpenDir">打开这个库的文件夹</button>
            <button class="btn ghost sm" id="libReload">刷新</button>
          </div>
        </div>
        <div class="gallery" id="lib"></div>
        <div class="empty" id="libEmpty" style="display:none">
          <span id="libEmptyText">正在读取图库…</span>
          <button class="btn sm" id="libEmptyBtn">重新读一次</button>
        </div>
        <div class="loadmore" id="libMoreWrap" style="display:none">
          <button class="btn ghost sm" id="libMore">加载更多</button>
        </div>
        <p class="muted xs" id="libHint" style="margin-top:var(--sp-3)">
          点缩略图直接设为壁纸；鼠标移上去有「设为壁纸 / 收藏 / 看原图」。缩略图走本机服务，支持缓存。
        </p>
      </div>
    </section>

    <!-- ============ 3. 设置 ============ -->
    <section class="screen" id="s-set">
      <div class="setgrid">
        <div class="card">
          <div class="card-h"><h2>换图</h2><span class="muted xs">多久换一次、按什么顺序换</span></div>
          <div class="set">
            <div class="txt"><b>更换节奏</b><span id="setCycHint">每多少分钟自动换一张</span></div>
            <div class="ctl"><span class="num muted" id="setCycNum">—</span></div>
          </div>
          <div class="set col">
            <input type="range" id="setCyc" min="5" max="240" step="5" value="30" aria-label="换图间隔（分钟）">
            <div class="chiprow" id="setCycChips" style="margin-top:var(--sp-2)">
              <span class="chip cyc-chip" data-v="10">10 分</span>
              <span class="chip cyc-chip" data-v="30">30 分</span>
              <span class="chip cyc-chip" data-v="60">1 小时</span>
              <span class="chip cyc-chip" data-v="240">4 小时</span>
              <span class="chip cyc-chip" data-v="720">12 小时</span>
              <span class="chip cyc-chip" data-v="1440">24 小时</span>
            </div>
          </div>
          <div class="set">
            <div class="txt"><b>自动补新图</b><span>关掉就只在现有图库里轮换</span></div>
            <div class="ctl"><button class="sw" id="swAuto" aria-label="自动补新图"></button></div>
          </div>
          <div class="set">
            <div class="txt"><b>只在收藏里轮换</b><span>只挑你收藏过的图来换</span></div>
            <div class="ctl"><button class="sw" id="swFav" aria-label="只在收藏里轮换"></button></div>
          </div>
          <div class="set col">
            <div class="txt"><b>更换模式</b><span id="modeHint">—</span></div>
            <div class="ctl">
              <span class="chip" id="modeFocus" data-mode="focus">聚焦模式</span>
              <span class="chip" id="modeBing" data-mode="bing">必应模式</span>
            </div>
          </div>
          <div class="set">
            <div class="txt"><b>队列剩余</b><span>还能按顺序换多少张；剩 2 张时会自动补</span></div>
            <div class="ctl"><span class="num muted" id="queueNum">—</span></div>
          </div>
          <div class="set">
            <div class="txt"><b>源池状态</b><span>取图池还剩多少新图</span>
              <!-- 同上：这句「抓到尽头 / 进入老图循环」最长有四五十字，
                   以前挤在右列里两边都变形，改成标题下面整行铺开。 -->
              <div class="muted xs" id="poolLine" style="margin-top:4px;overflow-wrap:anywhere">—</div>
            </div>
          </div>
          <div class="set col">
            <div class="txt"><b>补货 / 补齐</b><span>在后台跑，进度看下面的「最近动作」</span></div>
            <div class="ctl">
              <span class="chip" id="jobRefill">补几张新图</span>
              <span class="chip" id="jobBackfill">补漏必应</span>
              <span class="chip" id="jobArchive">补齐某月</span>
              <span class="chip" id="jobReset">清空源池记录</span>
            </div>
          </div>
          <div class="set col">
            <div class="txt"><b>本地文件夹图源</b><span id="localHint">把你自己的照片文件夹也接进来：只记文件名，不搬、不复制、不删；只收 jpg / png / bmp</span></div>
            <div class="ctl" style="flex-wrap:wrap">
              <span class="mono muted" id="localDir" style="overflow-wrap:anywhere">未启用</span>
              <span class="muted xs" id="localCount">—</span>
            </div>
          </div>
          <div class="set col">
            <div class="txt"><b>换一个文件夹 / 重新扫一遍</b><span>不做目录监听：新丢进去的图，点一下「重新扫一遍」才进队列（一次最多进队 300 张）</span></div>
            <div class="ctl">
              <span class="chip" id="btnLocalPick">选目录…</span>
              <span class="chip" id="btnLocalScan">重新扫一遍</span>
              <span class="chip" id="btnLocalOpen">打开这个文件夹</span>
              <span class="chip" id="btnLocalOff">关掉本地图源</span>
            </div>
          </div>
        </div>

        <div class="card">
          <div class="card-h"><h2>下载</h2><span class="muted xs">画质、张数与回收</span></div>
          <div class="set">
            <div class="txt"><b>下载画质</b><span>自动 = 1080p 屏只下 1080p，省一半空间</span></div>
            <div class="ctl">
              <select class="selinp" id="selRes">
                <option value="auto">按屏幕自动</option>
                <option value="uhd">固定 4K</option>
              </select>
            </div>
          </div>
          <div class="set">
            <div class="txt"><b>图库上限</b><span>0 = 不限；超了把看过的、最老的移进回收站</span></div>
            <div class="ctl"><input class="inp" type="number" id="numLib" min="0" max="2000" step="10"></div>
          </div>
          <div class="set">
            <div class="txt"><b>必应库上限</b><span>0 = 不限</span></div>
            <div class="ctl"><input class="inp" type="number" id="numBing" min="0" max="2000" step="10"></div>
          </div>
          <div class="set">
            <div class="txt"><b>每轮抓几张</b><span>一轮补几张聚焦图（1–50）</span></div>
            <div class="ctl"><input class="inp" type="number" id="numRound" min="1" max="50" step="1"></div>
          </div>
          <div class="set">
            <div class="txt"><b>单张下载超时</b><span>秒；慢图床到点就放弃、换下一张</span></div>
            <div class="ctl"><input class="inp" type="number" id="numTimeout" min="0" max="300" step="5"></div>
          </div>
          <div class="set">
            <div class="txt"><b>单轮抓取上限</b><span>一轮最多抓几张（硬上限）</span></div>
            <div class="ctl"><input class="inp" type="number" id="numRoundCap" min="1" max="50" step="1"></div>
          </div>
          <div class="set">
            <div class="txt"><b>每日抓取上限</b><span>跨菜单 / 后台 / 面板统一算，换天归零</span></div>
            <div class="ctl"><input class="inp" type="number" id="numDayCap" min="1" max="200" step="1"></div>
          </div>
          <div class="set">
            <div class="txt"><b>老图回收间隔</b><span>同一张图至少隔这么多天才再轮到</span></div>
            <div class="ctl"><input class="inp" type="number" id="numRecycle" min="0" max="365" step="1"></div>
          </div>
          <div class="set">
            <div class="txt"><b>累计下载</b><span>从装上这个程序那天算起</span></div>
            <div class="ctl"><span class="muted" id="dlTotal">—</span></div>
          </div>
          <div class="set">
            <div class="txt"><b>不是程序下载的图</b><span>你自己放进库的；只做记号，不会换到桌面上</span></div>
            <div class="ctl"><span class="muted" id="strangers">—</span></div>
          </div>
          <div class="set">
            <div class="txt"><b>库里有多少</b><span>必应库 / 聚焦库（本地图源另算）</span></div>
            <div class="ctl"><span class="muted" id="poolCounts">—</span></div>
          </div>
          <!-- 2026-10-25（用户指着这张卡底下的空白说"这里可以加点内容"）：等高网格让矮的
               一张卡空出 ~145px。与其留白，不如把上面两个上限输入框和实际张数画成三条库容
               条 —— 必应/聚焦/本地各一行，到顶会变黄，比再堆两行文字有用。 -->
          <div class="set col">
            <div class="txt"><b>库容</b><span>已用 / 上限；到顶会把最老的移进回收站，上限填 0 = 不限</span></div>
            <div class="capbar">
              <div class="capline"><span class="capname">必应</span><span class="captrack"><i id="capBingBar"></i></span><span class="capnum" id="capBing">—</span></div>
              <div class="capline"><span class="capname">聚焦</span><span class="captrack"><i id="capSpotBar"></i></span><span class="capnum" id="capSpot">—</span></div>
              <div class="capline"><span class="capname">本地</span><span class="captrack"><i id="capLocalBar"></i></span><span class="capnum" id="capLocal">—</span></div>
            </div>
          </div>
        </div>

        <div class="card">
          <div class="card-h"><h2>桌面</h2><span class="muted xs">跟系统桌面有关的几项</span></div>
          <div class="set">
            <div class="txt"><b>壁纸填充方式</b><span>跟系统「填充 / 适应」等价</span></div>
            <div class="ctl">
              <select class="selinp" id="selStyle">
                <option value="fill">填充</option>
                <option value="fit">适应</option>
                <option value="stretch">拉伸</option>
                <option value="center">居中</option>
                <option value="tile">平铺</option>
                <option value="span">跨区</option>
                <option value="keep">跟随系统（不改）</option>
              </select>
            </div>
          </div>
          <!-- 2026-10-25 补：程序第一次改这个值之前会把你的原值记在 config.json 里,
               这里给那条记录一个出口。没有记录时按钮灰着，点了也不会有任何动作。 -->
          <div class="set">
            <div class="txt"><b>还原我原来的填充方式</b><span id="origHint">程序第一次改这个值前会记下你的原值</span></div>
            <div class="ctl"><button class="btn ghost" id="btnRestoreStyle">还原</button></div>
          </div>
          <div class="set">
            <div class="txt"><b>小图不放大</b><span>开 = 1:1 居中 + 同图模糊底；关 = 拉大铺满（会糊）</span></div>
            <div class="ctl"><button class="sw" id="swFit" aria-label="小图不放大"></button></div>
          </div>
          <div class="set">
            <div class="txt"><b>桌面快捷方式</b><span id="deskHint">关掉会删掉那个图标</span></div>
            <div class="ctl"><button class="sw" id="swDesk" aria-label="桌面快捷方式"></button></div>
          </div>
          <div class="set">
            <div class="txt"><b>开机自动换</b><span id="autoHint">关 = 登录后不会自己换</span></div>
            <div class="ctl"><button class="sw" id="swAutoStart" aria-label="开机自动换"></button></div>
          </div>
          <div class="set">
            <div class="txt"><b>壁纸保存位置</b><span>改到别的盘会把「必应」「聚焦」两个库搬过去</span></div>
            <div class="ctl"><span class="chip" id="btnMoveBase">换位置…</span></div>
          </div>
          <div class="set">
            <div class="txt"><b>显示器</b><span>本轮只按主屏来；多屏支持暂不做</span></div>
            <div class="ctl"><span class="chip" id="chipScreen2" title="多屏支持暂不做">主屏 —</span></div>
          </div>
          <!-- 2026-10-25（用户："日志框再往下拉"）：日志能显示几行，取决于左边「桌面」卡多高
               （等高网格）。而「上次换上 / 累计换到桌面」这两个数本来就有、以前哪都没露过
               —— 补在这里，既是有用的信息，也把日志框顶到 11~12 行。 -->
          <div class="set">
            <div class="txt"><b>上次换上</b><span>最近一次真正贴到桌面的时间</span></div>
            <div class="ctl"><span class="muted" id="lastSwapLine">—</span></div>
          </div>
          <div class="set">
            <div class="txt"><b>累计换到桌面</b><span>装上天数里换过的总次数（同一张重复算）</span></div>
            <div class="ctl"><span class="num muted" id="shownNum">—</span></div>
          </div>
        </div>

        <div class="card">
          <div class="card-h"><h2>高级</h2><span class="muted xs">看状态 / 排错用</span></div>
          <div class="set">
            <div class="txt"><b>版本</b><span>脚本与主程序各自的版本号</span></div>
            <div class="ctl"><span class="mono muted" id="versionLine">—</span></div>
          </div>
          <div class="set">
            <div class="txt"><b>数据目录</b><span>config.json / state.json / 日志都在这里</span>
              <!-- 2026-10-25 收边：这条路径以前塞在右边那一列（还限了 70% 宽），
                   卡片一窄就把「数据目录」那两行字压成三四行，路径自己又顶到右边框。
                   挪到标题下面独占一行，长路径在卡片内换行，左右都不贴边。 -->
              <div class="mono muted xs" id="dirsLine" style="margin-top:4px;overflow-wrap:anywhere">—</div>
            </div>
            <div class="ctl">
              <button class="btn sm" id="btnOpenDir2" title="在资源管理器里打开数据目录">打开</button>
            </div>
          </div>
          <!-- 「操作」以前是 .set.col（按钮独占一行、左对齐），和同一张卡里
               「版本 / 数据目录」的"值贴右边界"是两种语法，看着像漏了一行。三个小按钮
               一共 ~250px，放得进右列，所以收回普通行，跟标题同一水平线。 -->
          <div class="set">
            <div class="txt"><b>操作</b><span>检查更新走的是线上升级源；改错了可以手动还原</span></div>
            <div class="ctl">
              <button class="btn sm" id="btnCheckUpd">检查更新</button>
              <button class="btn sm" id="btnRefresh">刷新状态</button>
              <button class="btn sm danger" id="btnQuit">退出控制台</button>
            </div>
          </div>
          <div class="set col">
            <div class="txt"><b>最近动作</b><span>只在本机，最近几行日志</span></div>
            <div class="log" id="logBox">—</div>
          </div>
        </div>
      </div>
      <!-- 快捷键是全局提示，不属于「高级」这一张卡，以前挂在卡尾变成卡里多出来的一行 -->
      <p class="muted xs setfoot">
        快捷键：<kbd>Space</kbd> 立即换一张 · <kbd>F</kbd> 收藏 · <kbd>1</kbd><kbd>2</kbd><kbd>3</kbd> 切视图
      </p>
    </section>
  </main>

  <footer class="foot">
    <span>桌面壁纸 · 作者 海风（kele551）　·　<a href="https://github.com/kele551/ms-wallpaper-assistant" target="_blank" rel="noopener">github.com/kele551/ms-wallpaper-assistant</a>　·　所有请求只在本机；本页没有任何外部资源</span>
  </footer>
</div>

<div class="toast" id="toast" role="status" aria-live="polite"></div>
<!-- 页面内的 JS 错误钩子: 有报错就把内容写进这个隐藏元素（验收时可以 --dump-dom 看） -->
<div id="jsErr" hidden></div>

<script>
var TOKEN = "{{BWPANEL_TOKEN}}";
/* 页面内错误钩子: 任何 JS 报错都记下来, 用无头浏览器 --dump-dom 一看就知道有没有错 */
window.__errs = [];
window.onerror = function(m){
  try {
    window.__errs.push(String(m));
    var d = document.getElementById("jsErr");
    if (d){ d.textContent = window.__errs.join(" | "); d.hidden = false; }
  } catch (e) {}
};
var S = null;                    /* 最近一次 /api/state 的结果 */
var busy = false;                /* 一次只跑一个动作 */
var G = { src: "all", fav: false, skip: 0, items: [], more: false, loaded: false };
var tickTimer = null;
var cycMin = 30;                 /* 当前间隔(分钟), 只用于前端倒计时 */
var nextAt = 0;                  /* 下一次自动换的时间戳(毫秒), 0 = 不知道 */
/* 【2026-10-25 用户「当前预览图没有锁定当前壁纸的图像，关闭窗口[重开]才恢复」】
   这一页是**打开时拉一次状态**, 之后只有前端计时在跑(服务是单线程 TcpListener,
   故意不做轮询)。所以后台到点换了一张、或者在别的窗口按了 F1, 这一页的「当前壁纸」
   大卡就一直停在旧的那张上 —— 看着像预览和桌面不一致, 重开窗口才对上。
   下面三个变量用来做"不轮询的前提下补拉": ①记最后一次拉取时间; ②倒计时归零那一刻
   补拉一次(每个 nextAt 只补一次, 不会变成每分钟打一遍); ③标签页切回前台时补拉一次。 */
var LAST_STATE_AT = 0;           /* 最后一次真的发出 /api/state 的时刻 */
var CROSS_AT = 0;                /* 已经为哪一个 nextAt 补拉过了 */
var REVEAL_MIN_GAP = 8000;       /* 切回前台补拉的最小间隔(毫秒) */

function $(id){ return document.getElementById(id); }
function setText(id, t){ var e = $(id); if (e) e.textContent = (t == null ? "" : String(t)); }
function setHTML(id, t){ var e = $(id); if (e) e.innerHTML = (t == null ? "" : String(t)); }

function toast(msg, bad){
  var t = $("toast");
  t.textContent = msg;
  t.className = "toast on" + (bad ? " bad" : "");
  clearTimeout(toast._t);
  toast._t = setTimeout(function(){ t.className = "toast"; }, 2800);
}

/* 本机接口: 只有 /api/do 与 /api/state, 都带一次性令牌 */
function api(doName, extra){
  var q = "/api/do?t=" + encodeURIComponent(TOKEN) + "&do=" + encodeURIComponent(doName);
  if (extra){
    for (var k in extra){
      if (extra[k] === undefined || extra[k] === null) continue;
      q += "&" + k + "=" + encodeURIComponent(extra[k]);
    }
  }
  return fetch(q, { cache: "no-store" }).then(function(r){ return r.json(); })
    .then(function(j){
      if (!j) throw new Error("空响应");
      if (j.ok === false && j.error) toast(j.error, true);
      if (j && j.scriptVer !== undefined) render(j);
      return j;
    })
    .catch(function(e){ toast("本机服务没响应：" + e.message, true); throw e; });
}

function wallUrl(p){
  return p ? ("/api/wall?t=" + encodeURIComponent(TOKEN) + "&p=" + encodeURIComponent(p)) : "";
}
function baseName(p){
  if (!p) return "";
  var i = Math.max(p.lastIndexOf("\\"), p.lastIndexOf("/"));
  return i >= 0 ? p.slice(i + 1) : p;
}
/* state.json 里存的名字有的带扩展名、有的不带 —— 比"是不是同一张"时统一去扩展名小写 */
function sameName(a, b){
  var sa = String(a || "").replace(/\.[a-z0-9]+$/i, "").toLowerCase();
  var sb = String(b || "").replace(/\.[a-z0-9]+$/i, "").toLowerCase();
  return !!sa && sa === sb;
}
/* 文件名形如 2026-10-22_标题_地点.jpg —— 拆成日期 / 标题 / 地点 */
function parseName(name){
  var out = { date: "", title: name || "", place: "" };
  if (!name) return out;
  var core = String(name).replace(/\.[a-z0-9]+$/i, "");
  var m = core.match(/^(\d{4}-\d{2}-\d{2})_(.*)$/);
  if (!m) return out;
  out.date = m[1];
  var rest = m[2].split("_").filter(function(x){ return x; });
  out.title = rest[0] || "";
  out.place = rest.length > 1 ? rest.slice(1).join("，") : "";
  if (!out.title) out.title = core;
  return out;
}
function parseTime(s){
  if (!s) return 0;
  var t = Date.parse(String(s).replace(/-/g, "/"));
  return isNaN(t) ? 0 : t;
}
function pad2(n){ return (n < 10 ? "0" : "") + n; }
function hhmm(ms){
  var d = new Date(ms);
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes());
}
function fmtLeft(minutes){
  if (minutes < 1) return "0";
  if (minutes < 60) return String(Math.round(minutes));
  var h = minutes / 60;
  return (h >= 10 ? String(Math.round(h)) : (Math.round(h * 10) / 10).toFixed(1));
}
function fmtLeftUnit(minutes){
  return minutes < 60 ? "分" : "小时";
}
function fmtCycle(m){
  if (!m || m <= 0) return "—";
  if (m % 1440 === 0) return (m / 1440) + " 天";
  if (m % 60 === 0) return (m / 60) + " 小时";
  return m + " 分钟";
}

/* ── 主题: 默认跟随系统; 手动切换后记住; URL 上 ?theme=light 可强制(截图用) ──
   【2026-10-24 修 主题两个键打架】右下角「外观」面板存 ui-theme-mode（auto|light|dark），
   右上角那个旧按钮存 bw-theme（dark|light）。原来两边各写各的，旧键会被面板那套忽略：
   手动选过的观感刷新后失效。现在读的时候新键优先、写的时候两个键一起写。
   【2026-10-25 换持久层】面板端口每次开机都是现抢的随机口，换个口就是另一个 origin，
   localStorage 里的选择跟着一起没了 —— 所以口径统一收到页首的 window.__BWUI 一处：
   本次点击 > 服务端下发的 seed(config.json) > 本机 localStorage > 跟随系统。
   这两个函数只保留给右上角那个已经隐藏的旧按钮，行为跟面板一致。 */
function themeMode(){
  try {
    if (window.__BWUI) return __BWUI.mode();
    var m = localStorage.getItem("ui-theme-mode");
    var old = localStorage.getItem("bw-theme");
    /* 只有旧键（右上角老按钮切过主题）的人，在这里一次性搬到新键：
       页尾"外观"面板只认 ui-theme-mode，不搬的话面板会把旧键的选择当没有、按系统重来一遍。 */
    if (!m && (old === "dark" || old === "light")) {
      localStorage.setItem("ui-theme-mode", old);
      return old;
    }
    return m || old || "auto";
  }
  catch (e) { return "auto"; }
}
function sysTheme(){
  var dark = true;
  try { dark = !(window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches); } catch (e) {}
  return dark ? "dark" : "light";
}
function applyTheme(t, remember){
  document.documentElement.setAttribute("data-theme", t);
  if (remember){
    try {
      localStorage.setItem("bw-theme", t);
      localStorage.setItem("ui-theme-mode", t);
    } catch (e) {}
    /* 老键也搬进 config.json, 否则换次开机这条线又只剩 localStorage */
    try { if (window.__BWUI) __BWUI.persist("panel_theme", t); } catch (e) {}
  }
  var icon = $("themeIcon");
  if (icon && t === "light"){
    icon.innerHTML = '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5L19 19M19 5l-1.5 1.5M6.5 17.5L5 19"/>';
  } else if (icon){
    icon.innerHTML = '<path d="M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5z"/>';
  }
}
function initTheme(){
  var m = String(location.search || "").match(/[?&]theme=(dark|light)\b/);
  if (m){ applyTheme(m[1], false); return; }
  var mode = themeMode();
  if (mode === "dark" || mode === "light"){ applyTheme(mode, false); return; }
  applyTheme(sysTheme(), false);
}
$("themeBtn").addEventListener("click", function(){
  var cur = document.documentElement.getAttribute("data-theme");
  applyTheme(cur === "light" ? "dark" : "light", true);
});

/* ── 视图切换(单页, 不路由) ── */
function showTab(name){
  var btns = document.querySelectorAll(".seg-btn");
  for (var i = 0; i < btns.length; i++){
    var on = btns[i].getAttribute("data-screen") === name;
    btns[i].classList.toggle("on", on);
    btns[i].setAttribute("aria-selected", on ? "true" : "false");
  }
  var screens = { now: "s-now", lib: "s-lib", set: "s-set" };
  for (var k in screens){
    var el = $(screens[k]);
    if (el) el.classList.toggle("on", k === name);
  }
  if (name === "lib" && !G.loaded) loadGallery(true);
  /* 刚切到「设置」屏才量得到日志框（其它屏时 display:none 全是 0），顺手把框高补齐 */
  if (name === "set") fitLog();
  if (name === "now") tick();
}
Array.prototype.forEach.call(document.querySelectorAll(".seg-btn"), function(b){
  b.addEventListener("click", function(){ showTab(b.getAttribute("data-screen")); });
});
var _gs=$("btnGoSet"); if(_gs) _gs.addEventListener("click", function(){ showTab("set"); });
$("btnAll").addEventListener("click", function(){ showTab("lib"); });

/* ── 倒计时环: 完全前端计时, 不发任何请求 ── */
function computeNext(){
  nextAt = 0;
  if (!S || !S.st || !S.st.lastSwap) return;
  var t = parseTime(S.st.lastSwap);
  if (!t) return;
  if (!cycMin || cycMin <= 0) return;
  nextAt = t + cycMin * 60000;
}
/* 【2026-10-25 用户「必应模式，时间没有锁死」】
   必应模式**不按间隔走** —— 后台是"每天第一轮巡检把当天那张贴上去"(core.ps1 规则 1),
   所以这一屏不该再有"还有 23 小时"这类倒计时: 进度条一点点往前爬、顶栏偶尔还会翻成
   "即将换图…", 看着就是"时间没锁死"。现在必应模式直接给一句固定说明, 进度条归零,
   也不做"倒计时归零补拉"(在必应模式下那条没有意义, 换图由下面的轻量探测负责)。 */
function tick(){
  var meter = $("cycMeter");
  var cfg = (S && S.cfg) || {};
  if (cfg.bing_only){
    if (meter) meter.style.width = "0%";
    setText("statusText", "必应模式 · 明天开机后换新图");
    return;
  }
  if (!nextAt || !cycMin){
    if (meter) meter.style.width = "0%";
    return;
  }
  var total = cycMin * 60000;
  var left = nextAt - Date.now();
  var pct = 100 - (left / total) * 100;
  if (pct < 0) pct = 0;
  if (pct > 100) pct = 100;
  var leftMin = Math.max(0, left / 60000);
  var txt = fmtLeft(leftMin);
  var unit = fmtLeftUnit(leftMin);
  if (left <= 0){ txt = "即将"; unit = ""; }
  if (meter) meter.style.width = Math.round(pct) + "%";
  /* 顶栏也显示换图时间，而不是笼统的"自动更换中" */
  var st2;
  if (cfg.auto_fetch === false) st2 = "不会自动换（可随时手动换）";
  else if (left <= 0) st2 = "即将换图…";
  else st2 = hhmm(nextAt) + " 换图 · 还有 " + txt + unit;
  setText("statusText", st2);
  /* 【2026-10-25】倒计时走到零的那一刻补拉一次状态 —— 后台换完图, 「当前壁纸」大卡
     才会跟着换成真在桌面上的那一张。按 nextAt 记名, 一轮换图只补拉一次,
     机器一直开着也不会变成每分钟打一遍服务。 */
  if (S && left <= 0 && CROSS_AT !== nextAt){
    CROSS_AT = nextAt;
    refresh(false);
  }
}

/* ── 渲染 ── */
function render(s){
  if (!s || s.ok === false) return;
  S = s;
  var cfg = s.cfg || {}, st = s.st || {}, au = s.auto || {}, cnt = s.counts || {};

  /* 顶栏状态 */
  var isBing = !!cfg.bing_only;
  var pill = $("statusPill");
  pill.className = "pill ok";
  setText("statusText", (isBing ? "必应模式 · 明天开机后换新图" : "读取下次换图时间…"));
  setText("segInfo", "脚本 v" + (s.scriptVer || "?") + " · 主程序 v" + (s.launcherVer || "?")
    + (au.daemon ? " · 后台在跑" : " · 后台没在跑"));

  /* 当前壁纸 */
  var p = st.lastWall || "";
  var bn = parseName(baseName(p));
  var img = $("heroImg");
  if (p){
    var src = wallUrl(p);
    if (img.getAttribute("src") !== src){
      img.classList.remove("ready");
      img.onload = function(){ img.classList.add("ready"); $("heroEmpty").style.display = "none"; };
      img.onerror = function(){
        img.classList.remove("ready");
        $("heroEmpty").style.display = "grid";
        setText("heroEmpty", "这张图打不开了（可能刚被清理）");
      };
      img.src = src;
    }
    setText("heroTitle", bn.title || baseName(p));
    /* 2026-10-24 用户要求：这张卡要能看出「这是哪一天的哪张图」。
       名字一直是主标题（例如「到灯塔去！」），副行原来只有换上的时间；
       现在把图片自己的日期放到最前面，日期取自文件名的 YYYY-MM-DD_ 前缀
       （本机必应目录 137/137 张都是这个命名）。取不到日期就不硬凑，只留换上的时间，
       依旧不露原始 id / 英文 slug。 */
    var _imgDay = bn.date ? (bn.date + " 的图") : "";
    var _when = st.lastSwap ? (String(st.lastSwap).slice(0, 16) + " 换上") : "";
    setText("heroSub", _imgDay && _when ? (_imgDay + "　·　" + _when) : (_imgDay || _when || "—"));
    setText("heroBadge", isBing ? "必应模式 · 每日一图" : "当前壁纸");
    $("btnOpenImg").style.display = "";
  } else {
    img.classList.remove("ready");
    img.removeAttribute("src");
    $("heroEmpty").style.display = "grid";
    setText("heroEmpty", "还没有设置过壁纸，点「立即换一张」");
    setText("heroTitle", "—");
    setText("heroSub", "—");
    setText("heroBadge", "当前壁纸");
    $("btnOpenImg").style.display = "none";
  }

  /* 显示器: 只显示主屏(多屏本轮不做) */
  var scr = s.screen || {};
  var scrTxt = (scr.w && scr.h) ? ("主屏 " + scr.w + "×" + scr.h) : "主屏";
  setText("chipScreen", scrTxt);
  setText("chipScreen2", scrTxt);
  /* 上次换上 / 累计换到桌面：这两个数一直在 state 里，只是以前哪都没露 */
  setText("lastSwapLine", st.lastSwap ? String(st.lastSwap).slice(0, 19) : "还没换过");
  setText("shownNum", (st.shown == null ? "—" : st.shown + " 次"));

  /* 节奏 */
  var cyc = parseInt(cfg.cycle_minutes, 10);
  if (!isNaN(cyc) && cyc > 0) cycMin = cyc;
  computeNext();
  /* 【2026-10-25 用户「这个描述应该是明天第一次开机切换」】
     必应模式下别再显示"24 小时" —— 那不是真的"下次换图点", 后台按天走:
     明天第一次开机(开机后第一轮巡检)才换成当天的新图。 */
  setText("cycPill", isBing ? "明天开机" : fmtCycle(cycMin));
  setText("setCycNum", fmtCycle(cycMin));
  var chips = document.querySelectorAll(".cyc-chip");
  for (var i = 0; i < chips.length; i++){
    /* 必应模式下**一个档位都不高亮**: 高亮 24 小时会让人以为"下次就是 24 小时后" */
    chips[i].classList.toggle("on", !isBing
      && parseInt(chips[i].getAttribute("data-v"), 10) === cycMin);
  }
  var slider = $("setCyc");
  if (slider){
    slider.value = String(Math.min(240, Math.max(5, cycMin)));
    slider.disabled = isBing;
  }
  var cycRow = $("setCycChips");
  if (cycRow) cycRow.classList.toggle("locked", isBing);
  /* 【2026-10-25 用户「必应模式，时间没有锁死」】上面两行只锁了「设置」页那一排
     (setCycChips), 首页「更换节奏」卡片里那排(#cycChips, 10分/30分/1小时/4小时/12小时/24小时)
     从来没被锁 —— 必应模式下它照样能点, 点完还弹一句"间隔已改成 10 分"。
     服务端其实钉住了(core.ps1 把 cycle_minutes 强制写回 1440), 所以刷新一下又跳回 24 小时,
     看着就是"锁了个寂寞"。这里把首页那排一起灰掉, 下面点击处理里再加一道拒收。 */
  var cycRow2 = $("cycChips");
  if (cycRow2) cycRow2.classList.toggle("locked", isBing);
  var hint = isBing
    ? "必应模式：每天一张 —— 明天第一次开机（开机后第一轮巡检）换成当天的新图；必应约每天 16:00 发图。切回聚焦模式会还原原来的间隔"
    : "点一下直接切；滑块到 4 小时，更长用上面的档位";
  setText("cycHint", hint);
  setText("setCycHint", isBing ? "必应模式：明天第一次开机换当天的新图" : "每多少分钟自动换一张");
  setText("nextSub", "每 " + fmtCycle(cycMin) + " · 图库 " + ((cnt.bing || 0) + (cnt.spotlight || 0)) + " 张 · 收藏 "
    + (s.favCount || 0) + " 张" + (s.local && s.local.count ? (" · 本地 " + s.local.count + " 张") : ""));

  /* 开关类 */
  $("swAuto").className = "sw" + (cfg.auto_fetch === false ? "" : " on");
  $("swFav").className = "sw" + (cfg.fav_only ? " on" : "");
  $("swFit").className = "sw" + (cfg.art_fit_mode === "off" ? "" : " on");
  var dkOn = cfg.desktop_shortcut !== "off";
  var dk = s.desktop || {};
  $("swDesk").className = "sw" + (dkOn ? " on" : "");
  setText("deskHint", !dkOn
    ? "当前：没有桌面图标（打开会在原来的位置重建）"
    : (dk.exists ? ("当前：图标在 " + (dk.path || "")) : "配置是开，但桌面上找不到图标 —— 关一次再开就会重建"));
  $("swAutoStart").className = "sw" + (au.startup ? " on" : "");
  setText("autoHint", au.startup
    ? (au.daemon ? "开着 · 后台正在跑" : "开着 · 这次开机没跑起来，点一下会拉起来")
    : "关 = 登录后不会自己换");

  /* 模式 */
  $("modeFocus").classList.toggle("on", !isBing);
  $("modeBing").classList.toggle("on", isBing);
  setText("modeHint", isBing
    ? "当前是必应模式：只换必应每日一图，一天一张；不抓聚焦、不按间隔轮换"
    : "当前是聚焦模式：按间隔换「Windows 聚焦」图库里的图（和必应图混着轮换）");

  /* 下拉 / 数字 */
  $("selRes").value = (cfg.resolution_mode === "uhd") ? "uhd" : "auto";
  $("selStyle").value = cfg.wallpaper_style || "fill";
  /* 还原原值那条: 有没有记录由后端说, 页面不自己猜 (2026-10-25 补入口) */
  var sty = s.style || {};
  setText("origHint", sty.hasOrig
    ? ("记着的原值：" + (sty.orig || "（读不出来）") + " —— 还原后以后换图不再动它")
    : "程序还没改过这个值，没什么要还原的");
  var brs = $("btnRestoreStyle");
  if (brs) brs.disabled = !sty.hasOrig;
  setNum("numLib", cfg.lib_cap == null ? 200 : cfg.lib_cap);
  setNum("numBing", cfg.bing_cap == null ? 200 : cfg.bing_cap);
  setNum("numRound", cfg.spotlight_per_cycle == null ? 6 : cfg.spotlight_per_cycle);
  setNum("numTimeout", cfg.src_timeout_sec == null ? 20 : cfg.src_timeout_sec);
  setNum("numRoundCap", cfg.fetch_round_cap == null ? 6 : cfg.fetch_round_cap);
  setNum("numDayCap", cfg.fetch_day_cap == null ? 20 : cfg.fetch_day_cap);
  setNum("numRecycle", cfg.recycle_min_days == null ? 30 : cfg.recycle_min_days);

  /* 统计 */
  setText("statLib", ((cnt.bing || 0) + (cnt.spotlight || 0)));
  setText("statFav", (s.favCount || 0));
  setText("statQueue", (st.queue == null ? "—" : st.queue));
  setText("statDl", (au.dlTotal || 0));
  setText("queueNum", (st.queue == null ? "—" : (st.queue + " 张")));
  setText("poolCounts", "必应 " + (cnt.bing || 0) + " 张　·　聚焦 " + (cnt.spotlight || 0) + " 张");
  setText("poolLine", (s.pool && s.pool.line) ? s.pool.line : "—");
  setText("dlTotal", (au.dlTotal || 0) + " 张");
  setText("strangers", (au.strangers || 0) + " 张");

  /* 本地文件夹图源 */
  var local = s.local || {};
  setText("localDir", local.dir ? local.dir : "未启用");
  setText("localCount", local.dir ? (local.count + " 张") : "—");
  var lc = $("libLocalChip");
  if (lc) lc.style.display = local.dir ? "" : "none";

  /* 库容三条：把上面「图库上限 / 必应库上限」两个输入框和实际张数画成看得见的进度。
     上限填 0 是不限，画一小截灰条而不是空条，免得看着像"没数据"。 */
  function capLine(barId, numId, used, cap, off){
    var b = $(barId), n = $(numId);
    if (!b || !n) return;
    var u = +used || 0, c = +cap || 0;
    b.className = "";
    if (off) { b.style.width = "0%"; n.textContent = "未启用"; return; }
    if (!c) { b.style.width = "10%"; n.textContent = u + " 张 · 不限"; return; }
    b.style.width = Math.max(2, Math.min(100, Math.round(u * 100 / c))) + "%";
    if (u >= c) b.className = "full";
    n.textContent = u + " / " + c + " 张";
  }
  capLine("capBingBar", "capBing", cnt.bing, cfg.bing_cap, false);
  capLine("capSpotBar", "capSpot", cnt.spotlight, cfg.lib_cap, false);
  capLine("capLocalBar", "capLocal", local.count, 0, !local.dir);

  /* 版本 / 目录 */
  setText("versionLine", "脚本 v" + (s.scriptVer || "?") + " / 主程序 v" + (s.launcherVer || "?"));
  setText("dirsLine", s.dataDir || (s.dirs && s.dirs.base) || "—");
  setText("libCount", "已显示 " + G.items.length + " 张" + (G.fav ? " · 只看收藏" : ""));

  /* 收藏按钮状态 */
  var favNames = (s.favorites || []).map(function(x){ return x.name; });
  var curName = baseName(p);
  var isFav = favNames.indexOf(curName) >= 0;
  setText("btnFav", isFav ? "已收藏 ✓" : "收藏");
  $("btnFav").classList.toggle("on", isFav);

  /* 最近换过 */
  renderHistory(s.history || [], curName);

  /* 日志 */
  renderLog(s.log || []);

  tick();
}

/* 「最近动作」的框只有 7 行高，服务端一次给 30 条日志、长行还要折行 —— 内容比框高是常态。
   以前渲染完停在顶部，等于把最新那条藏在滚动条下面：用户想看「刚刚发生了什么」得自己滚，
   而截图里被横切半截的正是最新那条。所以填完把滚动条钉到底；用户往上翻旧行时不抢他的位置
   （滚回底部就恢复跟随）。 */
var LOG_FOLLOW = true;
function renderLog(lines){
  var lg = $("logBox");
  if (!lg) return;
  lg.innerHTML = "";
  (lines || []).forEach(function(line){
    var d = document.createElement("div");
    d.textContent = line;
    lg.appendChild(d);
  });
  if (!lines || !lines.length) lg.textContent = "—";
  if (LOG_FOLLOW) lg.scrollTop = lg.scrollHeight;
  fitLog();
  /* 网格等高是这一帧之后才最终定下来的，再量一次才吃得满 */
  if (window.requestAnimationFrame) window.requestAnimationFrame(function(){ fitLog(); });
}
/* 日志框高度 = 卡片里剩下的空间，但**只能按整行(18px)取整**：
   一旦底边落在行中间，最后一条又被横切半截（见 .log 那段注释，别再走回头路）。
   卡片在等高网格里会被邻居撑高，这块空白与其留着，不如给日志多看几行。
   2026-10-25（用户："日志框再往下拉"）：上一版只写 maxHeight，而 max-height 只能**封顶**、
   不能把内容少的框撑大 —— 于是框一直是 8 行（内容自己就那么高），卡片下面空出一截。
   改成写真实 height，并且量之前先把框压回最小值（见函数里那段注释）。 */
function fitLog(){
  var lg = $("logBox");
  if (!lg || !lg.closest) return;
  var card = lg.closest(".card");
  if (!card || !card.offsetWidth) return;   /* 不在「设置」屏时全是 0，量了也白量 */
  var row = lg.parentElement;
  var head = row && row.querySelector(".txt");
  if (!head) return;
  var MIN = 7, MAX = 20;
  /* 先退到"最小框"再量，不能退 auto：退 auto 时卡片按 30 条日志的完整高度把自己撑到一千多
     像素，等高网格的行高跟着涨，量出来的"剩余空间"永远大于上限 —— 空白只是从这张卡挪到
     隔壁那张卡。退到最小值量到的才是邻居真正给得起的空间，一次填平，也不会自增。 */
  lg.style.maxHeight = "none";
  lg.style.height = (MIN * 18 + 2) + "px";
  var cs = getComputedStyle(card);
  var rs = getComputedStyle(row);
  var pad = (parseFloat(cs.paddingBottom) || 0) + (parseFloat(rs.paddingBottom) || 0);
  var avail = card.getBoundingClientRect().bottom - pad - head.getBoundingClientRect().bottom - 4;
  var n = Math.floor((avail - 2) / 18);
  if (!(n >= MIN)) n = MIN;
  if (n > MAX) n = MAX;
  var h = (n * 18 + 2) + "px";
  lg.style.height = h;
  lg.style.maxHeight = h;
  if (LOG_FOLLOW) lg.scrollTop = lg.scrollHeight;
}
window.addEventListener("resize", function(){ fitLog(); });
(function(){
  var lg = $("logBox");
  if (!lg) return;
  lg.addEventListener("scroll", function(){
    LOG_FOLLOW = (lg.scrollHeight - lg.scrollTop - lg.clientHeight) < 8;
  }, {passive: true});
})();
function setNum(id, v){
  var e = $(id);
  if (!e) return;
  if (document.activeElement === e) return;
  e.value = v;
}

/* ── 缩略图 ── */
function mkBtn(text, cls, onClick){
  var b = document.createElement("button");
  b.type = "button";
  b.className = "btn " + (cls || "");
  b.textContent = text;
  b.addEventListener("click", function(e){ e.stopPropagation(); onClick(); });
  return b;
}
/* 「今天」的 yyyy-MM-dd，用来判断换图角标该显示时间还是日期 */
function todayKey(){
  var n = new Date();
  var p = function(x){ return (x < 10 ? "0" : "") + x; };
  return n.getFullYear() + "-" + p(n.getMonth() + 1) + "-" + p(n.getDate());
}
function tileFor(it, opt){
  var f = document.createElement("figure");
  var cur = (opt && opt.currentName) || "";
  var isSel = !!(cur && sameName(it.name, cur));
  f.className = "tile" + (isSel ? " sel" : "");
  f.title = it.name || "";
  f.setAttribute("data-name", it.name || "");
  var im = document.createElement("img");
  im.loading = "lazy";
  im.decoding = "async";
  im.alt = "";
  im.src = it.thumb || wallUrl(it.path);
  /* 2026-10-24 用户要求：加载不出来的（文件已不在库里）直接过滤掉，不留灰块 */
  im.onerror = function(){ if (f.parentNode) f.parentNode.removeChild(f); };
  f.appendChild(im);
  var bn = parseName(it.name);
  var d = document.createElement("span");
  d.className = "tile-d";
  // 【2026-10-25 用户「描述显示不一致」】「最近换过」这一排的角标原来取的是**文件名里的日期**
  // （聚焦图 = 微软那张图自己的发布日期），于是标题写"最近换过"、角标却是"这图是哪年的"，
  // 两个口径混在一排里看着就是错的。现在：有"换上时间"(it.at，服务端从 hist_at 带出来)
  // 就角标写换上的月-日、悬停 tooltip 补一句完整时间；没有才退回图片日期。
  // 图库/收藏那两排没有"换上时间"这个概念，仍然显示图片自己的日期，不受影响。
  if (it.at && /^\d{4}-\d{2}-\d{2}/.test(String(it.at))) {
    var at = String(it.at);
    // 【2026-10-25 收尾】角标先做成"换上的月-日"，但这一排天天都是当天换的几张，
    // 四个格子全写"10-25"等于没写、看不出先后。改成：今天的显"时:分"，
    // 更早的显"月-日"，悬停 tooltip 仍是完整的"换上于 yyyy-MM-dd HH:mm"。
    d.textContent = (at.slice(0, 10) === todayKey()) ? at.slice(11, 16) : at.slice(5, 10);
    f.title = (it.name || "") + " · 换上于 " + at.slice(0, 16);
  } else {
    d.textContent = bn.date ? bn.date.slice(5) : String(bn.title || "").slice(0, 12);
  }
  f.appendChild(d);
  if (it.fav){
    var star = document.createElement("span");
    star.className = "tile-star";
    star.textContent = "★";
    f.appendChild(star);
  }
  var acts = document.createElement("div");
  acts.className = "tile-acts";
  acts.appendChild(mkBtn("设为壁纸", "primary", function(){ useItem(it); }));
  acts.appendChild(mkBtn(it.fav ? "取消收藏" : "收藏", "", function(){ toggleFav(it); }));
  acts.appendChild(mkBtn("原图", "ghost", function(){ openOriginal(it); }));
  f.appendChild(acts);
  f.addEventListener("click", function(){ useItem(it); });
  f.setAttribute("tabindex", "0");
  f.addEventListener("keydown", function(e){
    if (e.key === "Enter" || e.key === " "){ e.preventDefault(); useItem(it); }
  });
  return f;
}
/* 【2026-10-25 用户「必应模式下 最近换过 浏览框也应该切换到必应图库」】
   这一排原来不分库: 切到必应模式以后, 名单里压着的还是上一阵子按间隔轮下来的聚焦图,
   看着就是"必应模式却给我看聚焦的旧图"。
   现在的口径:
     · 必应模式 —— **必应图库里最近的几张**(按文件名日期, 当前这张排第一并带换上时刻),
       一张聚焦图都不混进来; 历史只用来给同名条目补"换上时间"(见 renderHistory)。
     · 聚焦模式 —— 本来就是两库混着轮, 照旧按换上时间给 4 张。
   必应图库那份 60 秒最多拉一次(拉回来只重画这一排, 不整页刷新)。 */
var BING_FILL = { at: 0, rows: [], busy: false };
/* 必应图库按**文件名里的日期**排 —— 这是"必应哪天发的图", 用户认的就是这个。
   服务端给的是按文件修改时间, 补回来的老存档(下载于今天)会把 2023 年那些顶到前面,
   用户截图里 2023-01 的归档图排在最前就是这个原因。 */
function bingNameDate(n){
  var m = String(n || "").match(/^(\d{4}-\d{2}-\d{2})/);
  return m ? m[1] : "";
}
function bingGalleryOrdered(arr){
  var list = (arr || []).slice();
  list.sort(function(a, b){
    var da = bingNameDate(a && a.name), db = bingNameDate(b && b.name);
    if (da && db && da !== db) return da < db ? 1 : -1;
    if (da && !db) return -1;
    if (!da && db) return 1;
    return (Number(b && b.ts) || 0) - (Number(a && a.ts) || 0);
  });
  return list;
}
function bingFillRows(){
  var now = Date.now();
  if (BING_FILL.busy || (now - BING_FILL.at) < 60000) return BING_FILL.rows;
  BING_FILL.busy = true;
  BING_FILL.at = now;
  /* 40 张: 排序在页面上做, 取太少(原来 8 张)的话, 一次补档就能把最近几天的图挤出窗口。 */
  fetch("/?panel=gallery&src=bing&take=40", { cache: "no-store" })
    .then(function(r){ return r.ok ? r.json() : []; })
    .then(function(arr){
      BING_FILL.busy = false;
      if (arr && arr.length){
        BING_FILL.rows = bingGalleryOrdered(arr);
        if (S) renderHistory(S.history || [], baseName((S.st && S.st.lastWall) || ""));
      }
    })
    .catch(function(){ BING_FILL.busy = false; });
  return BING_FILL.rows;
}
function renderHistory(list, curName){
  var box = $("hist");
  if (!box) return;
  list = list || [];
  var isBing = !!(S && S.cfg && S.cfg.bing_only);
  var rows = [], seen = {};
  /* 【2026-10-25 二次修正 · 用户截图】必应模式下把"过去 30 分钟轮换记下的必应条目"端上来还不够:
     他截图里那四张(企鹅/圣丹斯/白沙/树木)确实是必应库里的图, 但都是 2023 年的**归档**,
     是聚焦模式轮换时被换过的, 看着跟必应每日一图完全不是一回事。
     现在的口径: 这一排 = **必应图库里最近的几张**(按文件名日期), 当前这张带换上时间;
     历史只用来给同名条目补"换上时间", 以及图库清单还没回来时先顶一格不空白。 */
  function add(it, at){
    /* 去扩展名再比: state.json 的"看过"名单记的是不带扩展名的名字, 图库清单带 .jpg,
       不去掉就永远对不上 —— 当前这张换上的时刻(20:42)就补不到角标上。 */
    var k = String((it && it.name) || "").replace(/\.[a-z0-9]+$/i, "").toLowerCase();
    if (!k || seen[k] || rows.length >= 4) return;
    seen[k] = 1;
    rows.push({ name: it.name, path: it.path || "", thumb: it.thumb || "", at: at || "" });
  }
  var atMap = {};
  for (var i = 0; i < list.length; i++){
    var h = list[i];
    if (h && h.src === "bing") {
      atMap[String(h.name || "").replace(/\.[a-z0-9]+$/i, "").toLowerCase()] = (h.at || "");
    }
  }
  if (isBing){
    var fill = bingFillRows();
    for (var j = 0; j < fill.length; j++){
      var f = fill[j];
      var fk = String(f.name || "").replace(/\.[a-z0-9]+$/i, "").toLowerCase();
      add(f, atMap[fk] || "");
    }
    if (rows.length < 4){
      /* 图库清单是异步来的: 首次打开这一下先用必应历史顶住(有内容就不闪空),
         清单回来后 bingFillRows 会重画这一排。 */
      for (var k2 = 0; k2 < list.length; k2++){
        var h2 = list[k2];
        if (h2 && h2.src === "bing") add(h2, h2.at);
      }
    }
  } else {
    for (var k3 = 0; k3 < list.length; k3++){ add(list[k3], list[k3] && list[k3].at); }
  }
  // 【2026-10-25】服务端已改成"从最新的一条往前给"，这里只取一行（4 张）。
  // 原来一行 6 张：单张只有 112px 宽，悬停那排「设为壁纸/收藏/原图」按钮塞不下、
  // 直接溢出到隔壁格，用户截图反馈"文字比例不和谐"。改成 4 张后单张约 170px，
  // 与下方图库 .gallery 的格子（minmax(152px)）同一量级，按钮和图的比例就顺了。
  box.innerHTML = "";
  rows.forEach(function(it){
    // 有"换上时间"就角标写换上的时刻/月日；没有(图库里最近但本机没换过)就退回图片日期。
    var f = tileFor({ name: it.name, path: it.path || "", thumb: it.thumb || "",
                      fav: false, src: "hist", at: it.at || "" },
                    { currentName: curName });
    box.appendChild(f);
  });
  $("histEmpty").style.display = rows.length ? "none" : "";
  if (!rows.length) setText("histEmpty", isBing ? "必应图库还是空的 —— 补几张新图之后这里就有了" : "还没有换过图");
}

/* ── 动作 ── */
function useItem(it){
  if (busy) return;
  busy = true;
  api("use", { name: it.name }).then(function(j){
    busy = false;
    toast(j && j.ok ? ("已设为壁纸：" + it.name) : "没设上，稍后再点一次", !(j && j.ok));
    if (j && j.ok){
      markCurrent(it.name);
      /* 【2026-10-25】markCurrent 只挪了格子的选中框, 上面那张「当前壁纸」大卡还是旧图 ——
         用户报的"预览图没锁定当前壁纸"有一半是这个。拉一次状态, 大卡/角标/最近换过一起对上。 */
      refresh(false);
    }
  }, function(){ busy = false; });
}
function toggleFav(it){
  if (busy) return;
  busy = true;
  api(it.fav ? "unfav" : "fav", { name: it.name }).then(function(j){
    busy = false;
    if (j && j.ok === false) return;
    toast(it.fav ? "已取消收藏" : "已收藏");
    if (G.fav) loadGallery(true);
    else { it.fav = !it.fav; refreshTileStars(); }
  }, function(){ busy = false; });
}
function openOriginal(it){
  if (it.path) window.open(wallUrl(it.path), "_blank", "noopener");
  else if (it.thumb) window.open(it.thumb, "_blank", "noopener");
}
function markCurrent(name){
  var tiles = document.querySelectorAll(".gallery .tile, .thumbs .tile");
  for (var i = 0; i < tiles.length; i++){
    tiles[i].classList.toggle("sel", sameName(tiles[i].getAttribute("data-name"), name));
  }
}
function refreshTileStars(){
  /* 只更新星标, 不重拉列表 */
  var box = $("lib");
  var tiles = box.querySelectorAll(".tile");
  for (var i = 0; i < tiles.length; i++){
    var nm = tiles[i].getAttribute("data-name");
    var it = null;
    for (var k = 0; k < G.items.length; k++){ if (G.items[k].name === nm){ it = G.items[k]; break; } }
    if (!it) continue;
    var star = tiles[i].querySelector(".tile-star");
    if (it.fav && !star){
      var s = document.createElement("span");
      s.className = "tile-star";
      s.textContent = "★";
      tiles[i].appendChild(s);
    } else if (!it.fav && star){
      tiles[i].removeChild(star);
    }
    var fb = tiles[i].querySelector(".tile-acts .btn:not(.primary):not(.ghost)");
    if (fb) fb.textContent = it.fav ? "取消收藏" : "收藏";
  }
}

/* ── 图库 ── */
function galleryUrl(){
  var q = "/?panel=gallery&src=" + encodeURIComponent(G.src) + "&skip=" + G.skip + "&take=48";
  if (G.fav) q += "&fav=1";
  return q;
}
function loadGallery(reset){
  if (reset){ G.skip = 0; G.items = []; $("lib").innerHTML = ""; }
  G.more = false;
  $("libEmpty").style.display = "none";
  return fetch(galleryUrl(), { cache: "no-store" })
    .then(function(r){
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    })
    .then(function(arr){
      if (!arr || !arr.length) {
        G.loaded = true;
        G.more = false;
        if (!G.items.length){
          $("libEmpty").style.display = "";
          setText("libEmptyText", G.fav ? "还没有收藏。在当前页点「收藏」，或者在这里的缩略图上点「收藏」"
                                        : "这个库还没有图（自动换图或点「补几张新图」之后就会有了）");
        }
      } else {
        G.loaded = true;
        arr.forEach(function(it){ G.items.push(it); });
        G.skip += arr.length;
        G.more = arr.length >= 48;
        var box = $("lib");
        var cur = baseName(S && S.st ? S.st.lastWall : "");
        arr.forEach(function(it){ box.appendChild(tileFor(it, { currentName: cur })); });
      }
      var shown = G.items.length;
      setText("libCount", "已显示 " + shown + " 张" + (G.fav ? " · 只看收藏" : "")
        + (G.src === "all" ? "" : " · " + (G.src === "bing" ? "必应库" : (G.src === "spotlight" ? "聚焦库" : "本地文件夹"))));
      $("libMoreWrap").style.display = G.more ? "" : "none";
    })
    .catch(function(e){
      $("libEmpty").style.display = "";
      setText("libEmptyText", "图库读不出来：" + e.message + "（可以点下面重新读一次）");
      $("libMoreWrap").style.display = "none";
    });
}
Array.prototype.forEach.call(document.querySelectorAll(".lib-chip"), function(chip){
  chip.addEventListener("click", function(){
    Array.prototype.forEach.call(document.querySelectorAll(".lib-chip"), function(c){ c.classList.remove("on"); });
    chip.classList.add("on");
    G.src = chip.getAttribute("data-src");
    loadGallery(true);
  });
});
$("libFav").addEventListener("click", function(){
  G.fav = !G.fav;
  $("libFav").classList.toggle("on", G.fav);
  setText("libFav", G.fav ? "只看收藏 ✓" : "只看收藏");
  loadGallery(true);
});
$("libReload").addEventListener("click", function(){ loadGallery(true); });
$("libOpenDir").addEventListener("click", function(){
  api("openDir", { name: G.src === "spotlight" ? "spotlight" : (G.src === "local" ? "local" : "bing") }).then(function(j){ if(j && j.ok) toast("已打开：" + (j.path || "?") + "（端口 " + location.port + "）"); else if(j && j.error) toast(j.error, true); });
});
$("libMore").addEventListener("click", function(){ loadGallery(false); });
$("libEmptyBtn").addEventListener("click", function(){ loadGallery(true); });

/* ── 设置项绑定 ── */
function run(fn){
  if (busy) return;
  busy = true;
  fn().then(function(){ busy = false; }, function(){ busy = false; });
}
function bindSw(id, key, getVal){
  var e = $(id);
  e.addEventListener("click", function(){
    run(function(){ return api("set", { key: key, value: getVal() }).then(function(){ toast("已保存"); }); });
  });
}
bindSw("swAuto", "auto_fetch", function(){ return S && S.cfg && S.cfg.auto_fetch === false ? "true" : "false"; });
bindSw("swFav", "fav_only", function(){ return S && S.cfg && S.cfg.fav_only ? "false" : "true"; });
bindSw("swFit", "art_fit_mode", function(){ return S && S.cfg && S.cfg.art_fit_mode === "off" ? "on" : "off"; });

/* 桌面快捷方式: 真建 / 真删, 所以关之前问一句 */
$("swDesk").addEventListener("click", function(){
  var on = !!(S && S.cfg && S.cfg.desktop_shortcut !== "off");
  var dk = (S && S.desktop) || {};
  if (on){
    var where = dk.path ? dk.path : "桌面";
    if (!confirm("关掉桌面快捷方式会把文件删掉：\n\n" + where +
      "\n\n如果你把这个文件夹挂在任务栏的「工具栏」上，那个入口也会一起消失。\n确定要关吗？")) return;
  }
  run(function(){
    return api("set", { key: "desktop_shortcut", value: on ? "off" : "on" }).then(function(j){
      toast((j && j.note) ? j.note : (on ? "已关闭桌面快捷方式" : "已打开桌面快捷方式"), !(j && j.ok));
    });
  });
});
$("swAutoStart").addEventListener("click", function(){
  var on = !!(S && S.auto && S.auto.startup);
  run(function(){
    return api("autostart", { value: on ? "off" : "on" }).then(function(j){
      toast((j && j.note) || "已处理", !(j && j.ok));
    });
  });
});

$("selRes").addEventListener("change", function(){
  var v = this.value;
  run(function(){ return api("set", { key: "resolution_mode", value: v }).then(function(){ toast("画质档已保存"); }); });
});
$("selStyle").addEventListener("change", function(){
  var v = this.value;
  run(function(){ return api("set", { key: "wallpaper_style", value: v }).then(function(){ toast("填充方式已保存"); }); });
});
/* 2026-10-25 补：把「还原我原来的填充方式」接上后端。
   后端 Restore-BwStyleOrig 会写回注册表那两个值、把设置里那一档对齐, 再把当前这张重设一次立刻生效。
   没记录时按钮是灰的, 这里再挡一道 —— 老标签页 / 状态还没刷新过来的情况下也不至于白点一次。 */
$("btnRestoreStyle").addEventListener("click", function(){
  var sty = (S && S.style) || {};
  if (!sty.hasOrig) { toast("程序还没改过这个值，没什么要还原的", true); return; }
  if (!confirm("要把桌面的「填充方式」还原成你原来的值：\n\n" + (sty.orig || "") +
               "\n\n还原以后换图不会再动它（除非你在上面自己重新选一档）。")) return;
  run(function(){
    return api("restore_style").then(function(j){
      toast((j && j.note) ? j.note : (j && j.ok ? "已还原" : "没还原成功"), !(j && j.ok));
    });
  });
});
function bindNum(id, key){
  $(id).addEventListener("change", function(){
    var v = $(id).value;
    run(function(){ return api("set", { key: key, value: v }).then(function(){ toast("已保存"); }); });
  });
}
bindNum("numLib", "lib_cap");
bindNum("numBing", "bing_cap");
bindNum("numRound", "spotlight_per_cycle");
bindNum("numTimeout", "src_timeout_sec");
bindNum("numRoundCap", "fetch_round_cap");
bindNum("numDayCap", "fetch_day_cap");
bindNum("numRecycle", "recycle_min_days");

/* 节奏: 滑块 + 档位 */
/* 必应模式下"间隔"这一组控件的统一拒收: 界面已经整排置灰点不动了, 这里再兜一层,
   是因为旧标签页(数据是几分钟前那一份)或者刚点完还没刷新的瞬间仍可能发出去,
   而服务端只会钉回 1440 —— 前端要是还弹一句"间隔已改成 10 分", 就是骗人。 */
function bingLocked(){
  if (!(S && S.cfg && S.cfg.bing_only)) return false;
  toast("必应模式固定 24 小时（每天一张），先切回聚焦模式才能改间隔", true);
  refresh(false);
  return true;
}
$("setCyc").addEventListener("input", function(){ setText("setCycNum", fmtCycle(parseInt(this.value, 10))); });
$("setCyc").addEventListener("change", function(){
  if (bingLocked()) return;
  var v = this.value;
  run(function(){ return api("set", { key: "cycle_minutes", value: v }).then(function(){ toast("间隔已改成 " + fmtCycle(parseInt(v, 10))); }); });
});
Array.prototype.forEach.call(document.querySelectorAll(".cyc-chip"), function(chip){
  chip.addEventListener("click", function(){
    if (bingLocked()) return;
    var v = chip.getAttribute("data-v");
    run(function(){ return api("set", { key: "cycle_minutes", value: v }).then(function(){ toast("间隔已改成 " + fmtCycle(parseInt(v, 10))); }); });
  });
});

/* 更换模式: 切过去后端会当场换一张 */
function setMode(bing){
  var cur = !!(S && S.cfg && S.cfg.bing_only);
  if (cur === bing){ toast(bing ? "已经是必应模式" : "已经是聚焦模式"); return; }
  run(function(){
    return api("set", { key: "bing_only", value: bing ? "true" : "false" }).then(function(){
      toast(bing ? "已切到必应模式：正在换成今天的必应图…" : "已切到聚焦模式：正在按轮换换一张…");
      /* 换图是后台那一轮干的, 前端这一刻拉状态还来不及。
         有上限地补拉两次(4 秒 / 12 秒), 只为把「当前壁纸」大卡对上桌面真正那张 ——
         不做持续轮询: 服务是单线程 TcpListener, 而且这一页的设计就是打开时拉一次。 */
      setTimeout(function(){ refresh(false); }, 4000);
      setTimeout(function(){ refresh(false); }, 12000);
    });
  });
}
$("modeFocus").addEventListener("click", function(){ setMode(false); });
$("modeBing").addEventListener("click", function(){ setMode(true); });

/* 补货 / 补齐 / 重置 / 换位置 */
function startJob(name, arg, tip){
  return api("job", { name: name, value: arg }).then(function(){
    toast(tip || "已在后台开始，进度看「最近动作」");
  });
}
$("jobRefill").addEventListener("click", function(){ startJob("refill", "", "开始补新图（后台）"); });
$("jobBackfill").addEventListener("click", function(){ startJob("backfill", "", "开始补漏必应（后台）"); });
$("jobArchive").addEventListener("click", function(){
  var ym = prompt("补齐哪个月？写成 2024-08 这种样子", "");
  if (!ym) return;
  if (!/^\d{4}-\d{2}$/.test(ym.trim())){ toast("年月格式不对，要 2024-08 这样", true); return; }
  startJob("archive", ym.trim(), "开始补齐 " + ym.trim() + "（后台）");
});
$("jobReset").addEventListener("click", function(){
  if (!confirm("只清下载记录，不动图片文件。\n之后可能重复下到以前看过的图，确定吗？")) return;
  startJob("resetpool", "", "已清空源池记录");
});
$("btnMoveBase").addEventListener("click", function(){
  var p = prompt("要搬到哪个目录？（会把「必应」「聚焦」两个库搬过去）\n例如 D:\\我的图片\\壁纸", "");
  if (!p) return;
  if (!confirm("确定搬到：\n" + p + "\n\n图多的时候会跑一会儿，搬完看日志确认。")) return;
  startJob("setbase", p, "开始迁移库（后台）");
});

/* 本地文件夹图源 */
$("btnLocalPick").addEventListener("click", function(){
  var p = prompt("把哪个文件夹当图源？\n（只记文件名，不搬、不复制、不删你的照片）\n例如 D:\\我的照片\\风景", "");
  if (!p) return;
  run(function(){
    return api("set", { key: "local_src_dir", value: p }).then(function(j){
      toast((j && j.ok === false) ? "这个目录没设上" : ("已接入：" + p), !(j && j.ok !== false));
    });
  });
});
$("btnLocalScan").addEventListener("click", function(){
  run(function(){
    return api("localscan").then(function(j){
      toast("扫完了" + (j && j.added != null ? ("：" + j.added + " 张进了轮换队列") : ""));
    });
  });
});
$("btnLocalOff").addEventListener("click", function(){
  if (!confirm("关掉本地文件夹图源？\n（只是不再从那个文件夹取图，你的照片一张都不会被删）")) return;
  run(function(){
    return api("set", { key: "local_src_dir", value: "" }).then(function(){ toast("已关掉本地文件夹图源"); });
  });
});
$("btnLocalOpen").addEventListener("click", function(){ api("openDir", { name: "local" }).then(function(j){ if(j && j.ok) toast("已打开：" + (j.path || "?") + "（端口 " + location.port + "）"); else if(j && j.error) toast(j.error, true); }); });

/* 顶栏与「当前」页的动作 */
$("btnSwap").addEventListener("click", function(){
  run(function(){
    var b = $("btnSwap");
    b.disabled = true;
    return api("swap").then(function(j){
      b.disabled = false;
      toast(j && j.ok ? "换好了" : "这一轮没换成，稍后再试", !(j && j.ok));
    }, function(){ b.disabled = false; });
  });
});
$("btnFav").addEventListener("click", function(){
  run(function(){
    var isFav = $("btnFav").classList.contains("on");
    return api(isFav ? "unfav" : "fav").then(function(){ toast(isFav ? "已取消收藏" : "已收藏"); });
  });
});
$("btnOpenImg").addEventListener("click", function(){
  if (S && S.st && S.st.lastWall) window.open(wallUrl(S.st.lastWall), "_blank", "noopener");
});
var od1 = $("btnOpenDir"); if (od1) od1.addEventListener("click", function(){ api("openDir", { name: "data" }).then(function(j){ if(j && j.ok) toast("已打开：" + (j.path || "?") + "（端口 " + location.port + "）"); else if(j && j.error) toast(j.error, true); }); });
$("btnOpenDir2").addEventListener("click", function(){ api("openDir", { name: "data" }); });
$("btnCheckUpd").addEventListener("click", function(){
  run(function(){
    toast("正在检查更新…");
    return api("update").then(function(j){
      toast(j && j.updated ? "已升级，重新打开控制台生效" : "已是最新版");
    });
  });
});
$("btnRefresh").addEventListener("click", function(){ refresh(true); });
$("btnQuit").addEventListener("click", function(){
  api("quit").then(function(){
    $("statusPill").className = "pill bad";
    setText("statusText", "已退出");
    toast("控制台已退出，可以直接关掉这个标签页");
  });
});

/* 键盘: Space 换一张 / F 收藏 / 1 2 3 切视图(Esc 从输入框退出) */
document.addEventListener("keydown", function(e){
  var tag = (e.target && e.target.tagName) ? e.target.tagName.toLowerCase() : "";
  if (tag === "input" || tag === "select" || tag === "textarea"){
    if (e.key === "Escape" && e.target.blur) e.target.blur();
    return;
  }
  if (e.key === " " || e.code === "Space"){ e.preventDefault(); $("btnSwap").click(); }
  else if (e.key === "f" || e.key === "F"){ e.preventDefault(); $("btnFav").click(); }
  else if (e.key === "1"){ showTab("now"); }
  else if (e.key === "2"){ showTab("lib"); }
  else if (e.key === "3"){ showTab("set"); }
});

/* 状态: 只在页面自己需要时拉一次, **不轮询**(服务是单线程手写 TcpListener) */
function setOffline(on, why){
  var n = $("offNote");
  if (!n) return;
  n.hidden = !on;
  var w = $("offWhy");
  if (w) w.textContent = on ? ("（" + (why || "无响应") + "）") : "";
}
function refresh(showTip){
  LAST_STATE_AT = Date.now();
  return fetch("/api/state?t=" + encodeURIComponent(TOKEN), { cache: "no-store" })
    .then(function(r){ return r.json(); })
    .then(function(j){
      if (j && j.error && !j.cfg) throw new Error(j.error);
      if (!j || j.ok === false) throw new Error((j && j.error) || "服务返回了空状态");
      render(j);
      setOffline(false);
      if (showTip) toast("已刷新");
      return j;
    })
    .catch(function(e){
      $("statusPill").className = "pill bad";
      setText("statusText", "连不上本机服务");
      /* 顶栏那颗胶囊会被滚出视野，满屏「—」看着像程序坏了 —— 内容区再钉一条说明。 */
      setOffline(true, e.message);
      if (showTip) toast("刷新失败：" + e.message, true);
    });
}
try { $("offRetry").addEventListener("click", function(){ refresh(true); }); } catch (e) {}

/* 启动 */
initTheme();
refresh(false);
/* ?tab=lib / ?tab=set 可以直接打开某个视图(截图与"贴个链接给用户"都用得上) */
var mTab = String(location.search || "").match(/[?&]tab=(now|lib|set)\b/);
if (mTab) showTab(mTab[1]);
setInterval(tick, 1000);      /* 只有前端计时, 不发请求 */
/* 【2026-10-25 用户「当前预览图没有锁定当前壁纸的图像，关闭窗口[重开]才恢复」】
   这一页原来只在"打开 / 倒计时归零 / 切回前台"时拉一次状态。必应模式的倒计时是 24 小时,
   后台换图根本不看它 —— 页面上的大卡能一直停在旧图, 重开窗口才对上。
   现在每 15 秒问一次 /api/now: 服务端只 stat 一下 state.json(不读目录、不带日志),
   桌面上的图真变了才整页补拉; 没变就回几百字节。服务是单线程手写 TcpListener,
   所以只在**页面可见**时问, 两次之间至少隔 12 秒。 */
var NOW_AT = 0;
function watchCurrent(){
  if (!S || document.hidden) return;
  var now = Date.now();
  if (now - NOW_AT < 12000) return;
  NOW_AT = now;
  fetch("/api/now?t=" + encodeURIComponent(TOKEN), { cache: "no-store" })
    .then(function(r){ return r.ok ? r.json() : null; })
    .then(function(j){
      if (!j || j.ok !== true) return;
      var st = (S && S.st) || {};
      if ((j.wall && j.wall !== (st.lastWall || "")) || (j.swap && j.swap !== (st.lastSwap || ""))) refresh(false);
    })
    .catch(function(){});
}
setInterval(watchCurrent, 15000);
var LAST_BLIND_RETRY = 0;
document.addEventListener("visibilitychange", function(){
  if (document.hidden) return;
  var now = Date.now();
  /* 【2026-10-25 用户「当前预览图没锁定当前壁纸」】原来切回前台时, 只要页面上已经有数据
     就只重跑前端计时 —— 人离开这段时间后台换过的图就一直不反映到大卡上。
     现在切回来补拉一次(距上次拉取不足 8 秒就不重复拉, 免得来回切标签压服务)。 */
  if (S){
    if (now - LAST_STATE_AT >= REVEAL_MIN_GAP) refresh(false);
    else tick();
    return;
  }
  /* 2026-10-25（用户截图：整页「—」）：这一页从没拿到过数据（多半是旧标签页连的是
     上一次会话的随机端口），切回来时再试一次，能连上就自愈。只在没有数据时试，
     并且隔 5 秒才试一次——服务是单线程 TcpListener，别把切换标签变成压测。 */
  if (now - LAST_BLIND_RETRY < 5000) return;
  LAST_BLIND_RETRY = now;
  refresh(false);
});
</script>
<!-- ===== 外观：主题三档 + 主色（2026-10-24 四款统一组件） ===== -->
<style>
#apFab{z-index:70;width:30px;height:30px;border-radius:50%;flex:none;margin-left:6px;border:1px solid var(--line);background:transparent;color:var(--txt-2);display:grid;place-items:center;cursor:pointer;font-size:13px;padding:0}
#apFab:hover{color:var(--accent);border-color:var(--accent)}
#apPop{position:fixed;z-index:71;width:250px;background:var(--card);border:1px solid var(--line-2);
  border-radius:12px;box-shadow:var(--shadow-2);padding:12px;display:none}
#apPop.on{display:block}
.ap-row{display:flex;align-items:center;gap:10px;margin-bottom:10px}
.ap-lab{font-size:11px;color:var(--txt-3);width:30px;flex:none}
.ap-seg{display:flex;gap:4px;flex:1}
.ap-seg button{flex:1;height:26px;border-radius:7px;border:1px solid var(--line);background:transparent;
  color:var(--txt-2);font-size:11px;cursor:pointer;padding:0}
.ap-seg button.on{background:color-mix(in srgb,var(--accent) 15%,transparent);border-color:var(--accent);color:var(--accent);font-weight:600}
.ap-sw{display:flex;gap:8px;flex:1}
.ap-sw button{width:20px;height:20px;border-radius:50%;border:2px solid transparent;cursor:pointer;padding:0;flex:none}
.ap-sw button.on{border-color:var(--txt)}
.ap-hint{font-size:10px;color:var(--txt-3);line-height:1.5;margin-top:9px}
#btnTheme,#themeBtn{display:none!important}
html[data-accent="blue"]{--accent:#4f8cff;--accent-ink:#04122e}
html[data-accent="green"]{--accent:#3ecf8e;--accent-ink:#062016}
html[data-accent="violet"]{--accent:#a78bfa;--accent-ink:#1a1030}
html[data-accent="amber"]{--accent:#f0b429;--accent-ink:#221603}
html[data-theme="light"][data-accent="blue"]{--accent:#1a5fd0;--accent-ink:#fff}
html[data-theme="light"][data-accent="green"]{--accent:#0f9d58;--accent-ink:#fff}
html[data-theme="light"][data-accent="violet"]{--accent:#6d28d9;--accent-ink:#fff}
html[data-theme="light"][data-accent="amber"]{--accent:#a86f00;--accent-ink:#fff}
html[data-accent]{--accent-soft:color-mix(in srgb,var(--accent) 14%,transparent);--accent-line:color-mix(in srgb,var(--accent) 45%,transparent)}
</style>
<button id="apFab" title="外观：主题与主色" aria-label="外观">◐</button>
<div id="apPop" role="dialog" aria-label="外观设置">
  <div class="ap-row"><span class="ap-lab">主题</span><div class="ap-seg" id="apMode">
    <button type="button" data-m="auto">跟随系统</button><button type="button" data-m="light">亮色</button><button type="button" data-m="dark">暗色</button>
  </div></div>
  <div class="ap-row"><span class="ap-lab">主色</span><div class="ap-sw" id="apAcc">
    <button type="button" data-a="default" title="品牌色"></button><button type="button" data-a="blue" title="蓝" style="background:#4f8cff"></button><button type="button" data-a="green" title="绿" style="background:#3ecf8e"></button><button type="button" data-a="violet" title="紫" style="background:#a78bfa"></button><button type="button" data-a="amber" title="琥珀" style="background:#f0b429"></button>
  </div></div>
  <div class="ap-hint">「跟随系统」随 Windows 亮/暗模式自动切换；选择存进程序配置，换端口、重开、换浏览器都在。</div>
</div>
<script>
(function(){
  var R=document.documentElement, K='ui-theme-mode', A='ui-accent';
  var media=window.matchMedia?window.matchMedia('(prefers-color-scheme: light)'):null;
  /* 品牌色给「主色-默认」那颗小方块用。页首现在会提前写 data-accent(防主色闪)，
     所以读之前先把属性摘掉、读完挂回去 —— 不然量到的是用户选的主色、不是品牌色。 */
  var savedAcc=R.getAttribute('data-accent'); if(savedAcc) R.removeAttribute('data-accent');
  var brand=(getComputedStyle(R).getPropertyValue('--accent')||'').trim()||'#888';
  if(savedAcc) R.setAttribute('data-accent',savedAcc);
  /* 口径只在页首 __BWUI 一处定义（本次点击 > 服务端 seed > localStorage > 跟随系统）。
     万一这段被单文件拆开跑在页首之前，回落成原来的 localStorage 读法。 */
  var U=window.__BWUI||null;
  function mode(){ try{return (U?U.mode():localStorage.getItem(K)||'auto')}catch(e){return 'auto'} }
  function acc(){ try{return (U?U.accent():localStorage.getItem(A)||'default')}catch(e){return 'default'} }
  function apply(){
    var m=mode();
    var dark = m==='dark' || (m==='auto' && !(media&&media.matches));
    R.setAttribute('data-theme', dark?'dark':'light');
    var a=acc();
    if(a==='default'){ R.removeAttribute('data-accent'); } else { R.setAttribute('data-accent',a); }
    sync(m,a);
  }
  function sync(m,a){
    var mb=document.querySelectorAll('#apMode button');
    for(var i=0;i<mb.length;i++) mb[i].classList.toggle('on', mb[i].getAttribute('data-m')===m);
    var ab=document.querySelectorAll('#apAcc button');
    for(var j=0;j<ab.length;j++) ab[j].classList.toggle('on', ab[j].getAttribute('data-a')===a);
    var fab=document.getElementById('apFab');
    if(fab) fab.textContent = R.getAttribute('data-theme')==='dark' ? '◐' : '◑';
  }
  function setMode(m){
    if(U){ U.setLS({'ui-theme-mode':m}); U.persist('panel_theme',m); }
    else { try{localStorage.setItem(K,m)}catch(e){} }
    apply();
  }
  function setAcc(a){
    if(U){ U.setLS({'ui-accent':a}); U.persist('panel_accent',a); }
    else { try{localStorage.setItem(A,a)}catch(e){} }
    apply();
  }
  var fab=document.getElementById('apFab'), pop=document.getElementById('apPop');
  var holder=document.querySelector('.top-r')||document.querySelector('.hbar')||document.querySelector('header');
  if(holder && fab){ holder.appendChild(fab); if(holder.tagName==='HEADER'){ fab.style.position='fixed'; fab.style.top='10px'; fab.style.right='12px'; } }
  if(fab) fab.addEventListener('click',function(e){ e.stopPropagation();
    if(!pop.classList.contains('on')){ var r=fab.getBoundingClientRect();
      pop.style.right='12px'; pop.style.left='auto'; pop.style.top=(r.bottom+8)+'px'; }
    pop.classList.toggle('on'); });
  document.addEventListener('click',function(e){ if(pop && !pop.contains(e.target) && e.target!==fab) pop.classList.remove('on'); });
  document.addEventListener('keydown',function(e){
    if(e.key==='Escape'){ pop && pop.classList.remove('on'); }
    if((e.key==='t'||e.key==='T') && !/^(INPUT|TEXTAREA|SELECT)$/.test((e.target.tagName||''))){
      e.stopImmediatePropagation(); e.preventDefault();
      setMode(R.getAttribute('data-theme')==='dark'?'light':'dark');
    }
  }, true);
  document.getElementById('apMode').addEventListener('click',function(e){
    var b=e.target.closest?e.target.closest('button'):null; if(!b) return; setMode(b.getAttribute('data-m'));
  });
  document.getElementById('apAcc').addEventListener('click',function(e){
    var b=e.target.closest?e.target.closest('button'):null; if(!b) return; setAcc(b.getAttribute('data-a'));
  });
  var d=document.querySelector('#apAcc button[data-a="default"]'); if(d) d.style.background=brand;
  if(media && media.addEventListener) media.addEventListener('change',function(){ if(mode()==='auto') apply(); });
  else if(media && media.addListener) media.addListener(function(){ if(mode()==='auto') apply(); });
  var forced=null; try{ forced=new URLSearchParams(location.search).get('theme'); }catch(e){}
  if(forced==='light'||forced==='dark'){ R.setAttribute('data-theme',forced); sync(mode(),acc()); } else { apply(); }
  window.__uiTheme={mode:mode,accent:acc,setMode:setMode,setAccent:setAcc};
})();
</script>
</body>
</html>

'@
# <<< PANEL_HTML_END

# 把内嵌的面板 HTML 释放成真文件。不带 BOM: 浏览器读 HTML 不需要它。
function Write-BwPanelHtml([string]$path) {
  if (-not $path) { return $false }
  try {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, [string]$global:BwPanelHtml, $enc)
    return $true
  } catch { return $false }
}

# ---- 快捷方式与开机自启（V2.4.0 从 menu.ps1 搬来） ----
# 为什么搬: 界面改成网页控制台之后, 「开机自动换」和「桌面快捷方式」要由面板通过接口改,
# 而它们以前写在 menu.ps1 里。menu.ps1 现在只剩"起服务 + 开浏览器"几十行。
# 这几个全局常量原来也定义在 menu.ps1, 一并搬过来(注意: 这里**不放**版本号常量,
# 版本只在 launcher.py 与 menu.ps1 定义 —— 发版自检会查这一点)。
$global:BWLnkName       = '桌面壁纸.lnk'
$global:BWLnkNameLegacy = '微软壁纸助手.lnk'
# 【2026-10-25 文件名更正】主程序文件名从「壁纸助手.exe」改成「桌面壁纸.exe」——
# 和显示名、快捷方式名、以及另外三款程序（LIVE直播源.exe / 热点新闻.exe）的口径对齐。
# 更早的「微软壁纸助手.exe」带着别人的商标，v2.1.0 起就不该出现在任何地方。
#
# 为什么**不**强行把老用户那份改名: 改名要动正在跑的进程、启动项、升级路径三处，
# 任何一步失手就是"升级之后程序起不来"那类事故。老名字照样是固定名，一律认，
# 原地覆盖升级会保持它自己的文件名不变；只有新下载的人拿到的是新名。
# 顺序即优先级：目录里同时存在多份时，取排在前面的那份。
$global:BWExeName        = '桌面壁纸.exe'
$global:BWExeNamesFixed  = @('桌面壁纸.exe', '壁纸助手.exe', '微软壁纸助手.exe')
$global:BWExeNameLegacy  = '微软壁纸助手.exe'

# ---------- 开机自动换壁纸 (绿色做法: 往「启动」文件夹放个快捷方式, 不需要管理员) ----------
# 快捷方式指向固定名 exe(桌面壁纸.exe, 老用户原地保留旧名) --daemon。exe 是 GUI 子系统程序, 后台模式
# 一个控制台都不建, 所以开机拉起时不会闪任何窗口。
function Get-BwStartupLnk {
  # MWA_STARTUP_DIR: 只给自检/演练用（把启动项目录指到临时目录），
  # 免得测试往用户真正的「启动」文件夹里放/删快捷方式。
  $d = [string]$env:MWA_STARTUP_DIR
  if (-not $d) { $d = [Environment]::GetFolderPath('Startup') }
  return (Join-Path $d $global:BWLnkName)
}
# 老名字的启动项(从旧版升上来的用户那儿还留着)。只用来"搬一次家":
# 存在就把它改成新名字, 不让新旧两份同时躺在启动文件夹里。
function Get-BwStartupLnkLegacy {
  $d = [string]$env:MWA_STARTUP_DIR
  if (-not $d) { $d = [Environment]::GetFolderPath('Startup') }
  return (Join-Path $d $global:BWLnkNameLegacy)
}
# 快捷方式要指向**固定名**那份 exe (桌面壁纸.exe, 老用户原地保留旧名), 而不是 桌面壁纸-v2.2.1.exe。
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
  # 2026-10-12 改名双名兼容: 老用户原位覆盖后文件名还是老名, 新装是新名 ——
  # 哪个真实存在用哪个; 都不在(当前 exe 是带版本号的名字)就回新名, 由 Ensure 复制出一份。
  $dir = Split-Path $cur -Parent
  foreach ($nm in $global:BWExeNamesFixed) {
    $cand = Join-Path $dir $nm
    if (Test-Path -LiteralPath $cand) { return $cand }
  }
  return (Join-Path $dir $global:BWExeName)
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
  # 老名字的启动项(旧版留下的)先搬成新名字, 再照原来的逻辑核对指向
  $legacyLnk = Get-BwStartupLnkLegacy
  if (Test-Path -LiteralPath $legacyLnk) { [void](Move-BwLnkToNewName $legacyLnk) }
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
    $sc.Description      = '桌面壁纸 - 开机自动换壁纸'
    $sc.IconLocation     = (Get-BwIconLocation $want)
    $sc.Save()
    Log ('开机自动换: 快捷方式原先指向 [' + $cur + '], 已改指 [' + $want + ']')
    return $true
  } catch { return $false }
}
# ---------- 桌面快捷方式 ----------
# 桌面上要一直有一个能双击打开菜单的快捷方式, 不用用户自己动手建:
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
  return (Join-Path (Get-BwDesktopDir) $global:BWLnkName)
}
# 桌面在哪。抽成一个函数是因为测试要能把它换成临时目录 ——
# 不然"首次自动建快捷方式"那条分支只能往真桌面上建, 测试就没法隔离了。
function Get-BwDesktopDir {
  # MWA_DESKTOP_DIR: 只给自检/演练用。
  # 2026-10-23 真事故: 自检的"关掉桌面快捷方式"这一步, 找的是**真桌面**,
  # 把用户放在「桌面\桌面图标」里的快捷方式删掉了(已按原样重建)。
  # 有了这个环境变量, 演练就只在自己造的假桌面里动。
  $d = [string]$env:MWA_DESKTOP_DIR
  if ($d) { return $d }
  return ([Environment]::GetFolderPath('Desktop'))
}
# 桌面根目录找不到时, 再往桌面上的一层子目录里找一遍 (用户收进文件夹的情况)
function Find-BwDesktopLnk {
  $desk = Get-BwDesktopDir
  # 新名字优先; 老名字也认(升级上来的用户桌面上留着的还是旧名字那份)
  foreach ($nm in @($global:BWLnkName, $global:BWLnkNameLegacy)) {
    $hit = @()
    try { $hit = @(Get-ChildItem -LiteralPath $desk -File -Filter $nm -ErrorAction SilentlyContinue) } catch { $hit = @() }
    if ($hit.Count -eq 0) {
      try {
        $subs = @(Get-ChildItem -LiteralPath $desk -Directory -ErrorAction SilentlyContinue)
        foreach ($s in $subs) {
          $f = @(Get-ChildItem -LiteralPath $s.FullName -File -Filter $nm -ErrorAction SilentlyContinue)
          if ($f.Count -gt 0) { $hit = @($f[0]); break }
        }
      } catch {}
    }
    if ($hit.Count -gt 0) { return $hit[0].FullName }
  }
  return ''
}
# 快捷方式的图标从哪取: 优先数据目录里那份独立的 .ico 文件, 没有才退回 exe 自己。
#
# 为什么不直接用 exe: Windows 的图标缓存是按「exe 的完整路径」记的。老版本 exe 占着
# 同一个路径时 (比如 D:\Program Files\微软壁纸助手.exe), 即使文件已经换成新版,
# 缓存里存的还是旧图标 —— 表现为"放桌面一个样、拖进文件夹又一个样"。
# 独立的 .ico 是另一条路径, 没被旧版本污染过, 显示出来的始终是这张图。
function Get-BwIconLocation([string]$exe) {
  # 2026-10-12 改名: 数据目录里的图标, 新装是「壁纸助手.ico」; 老用户热更上来的
  # 还是「微软壁纸助手.ico」(payload 只补缺失不覆盖同名旧物) —— 两个名都认, 新名优先。
  foreach ($nm in @('壁纸助手.ico', '微软壁纸助手.ico')) {
    $ico = Join-Path $global:BWRoot $nm
    if (Test-Path -LiteralPath $ico) { return ('{0},0' -f $ico) }
  }
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
    $ver = ''
    try { $ver = [string]$global:BWVersion } catch {}
    $sc.Description      = ('桌面壁纸 v' + $ver + ' - 双击打开控制台')
    $sc.IconLocation     = (Get-BwIconLocation $want)
    $sc.Save()
    if ($need -eq 'create') { Log ('桌面快捷方式: 已创建 -> ' + $lnk) }
    else { Log ('桌面快捷方式: 已更新, 指向 [' + $want + ']') }
    return $need
  } catch { return 'fail' }
}
# 返回: create / update / ok / gone / off / fail
#   gone = 以前建过, 现在没了 (被用户删了) —— 不再自动建
# 老名字的快捷方式 -> 新名字(同一个文件夹里改个名), 返回改完之后的路径。
# 为什么要搬: 显示名改了以后老 lnk 留着就是桌面上一个"旧名字"的空壳;
# 启动项里要是新旧并存, 还会变成两个开机自启。
function Move-BwLnkToNewName([string]$lnk) {
  if (-not $lnk) { return '' }
  $leaf = ''
  try { $leaf = Split-Path $lnk -Leaf } catch { return $lnk }
  if ($leaf -ne $global:BWLnkNameLegacy) { return $lnk }
  $dst = Join-Path (Split-Path $lnk -Parent) $global:BWLnkName
  if (Test-Path -LiteralPath $dst) {
    # 新名字那份已经在 -> 老的删掉(内容一样, 留着只会变成两个入口)
    try { Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue } catch {}
    return $dst
  }
  try {
    Move-Item -LiteralPath $lnk -Destination $dst -Force -ErrorAction Stop
    Log ('快捷方式改名: ' + $leaf + ' -> ' + $global:BWLnkName)
    return $dst
  } catch { return $lnk }
}
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
    # 老名字的快捷方式: 先就地改成新名字, 再按新路径继续维护
    $newLnk = Move-BwLnkToNewName $info.path
    if ($newLnk -ne $info.path) { $info.path = $newLnk; Save-BwDeskInfo $info }
    if ([string]$info.created -ne 'yes') { $info.created = 'yes'; Save-BwDeskInfo $info }
    return (Write-BwShortcut $sh $info.path $want)
  }

  # 2) 记的位置没了 (被删/被挪) -> 桌面根和一层子目录里找, 找到了就接着用那个
  #    找着的要是还叫老名字, 一样就地改名 (用户把它收进文件夹时, 上面那条分支走不到,
  #    不改名的话桌面上就永远留着一个旧名字的壳)。
  $found = Move-BwLnkToNewName (Find-BwDesktopLnk)
  if ($found) {
    $info.path = $found
    $info.created = 'yes'   # 找着了就说明确实建过, 别再当成"从来没建过"
    Save-BwDeskInfo $info
    return (Write-BwShortcut $sh $found $want)
  }

  # 3) 从来没自动建过 -> 建这一次
  if ([string]$info.created -ne 'yes') {
    $target = Join-Path (Get-BwDesktopDir) $global:BWLnkName
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
function Test-BwAutoStart {
  # 老名字的启动项也算"开着" —— 否则升级上来的用户会看到"开机自动换: 关"而其实是开的
  return ((Test-Path -LiteralPath (Get-BwStartupLnk)) -or (Test-Path -LiteralPath (Get-BwStartupLnkLegacy)))
}
# 后台到底有没有在跑? 只看"开机自动换开了没"是不够的 ——
# 那个开关只是往启动文件夹放了个快捷方式, **本次开机**并不会自己跑起来。
# 所以客户会看到「开机自动换: 开」+「下次自动换: 15:52」, 以为程序在换,
# 其实这次开机压根没后台进程, 那个 15:52 永远不会兑现 —— 这就是「时间不会变」的由来。
# 认进程命令行里带 --daemon 的那个, 那是真正在按节拍换图的那个。
function Test-BwDaemonRunning {
  # 2026-10-20 提速: 原来用 Get-CimInstance Win32_Process 扫命令行, 每进一次菜单要 ~500ms
  # (WMI 查询本来就慢, 机器上 WMI 再慢一点就是一秒)。守护进程 mode_daemon 启动时会
  # 一直持有命名互斥体 Local\MSWallpaperAssistantDaemon (launcher.py 的 MUTEX_NAME),
  # 直接探测它在不在就行 —— 实测 14ms, 判定结果与原来一致。
  try {
    $mtx = [System.Threading.Mutex]::OpenExisting('Local\MSWallpaperAssistantDaemon')
    $mtx.Dispose()
    return $true
  } catch [System.Threading.WaitHandleCannotBeOpenedException] {
    return $false
  } catch [System.UnauthorizedAccessException] {
    # 名字存在、只是打不开 —— 说明确实有人持有它
    return $true
  } catch {
    # 兜底: 互斥体探测意外失败时退回老办法, 宁可慢也别误报"后台没跑"
    try {
      $flt = 'Name=' + ((@($global:BWExeNamesFixed) | ForEach-Object { "'" + $_ + "'" }) -join ' OR Name=')
      $ps = @(Get-CimInstance Win32_Process -Filter $flt -ErrorAction SilentlyContinue |
              Where-Object { $_.CommandLine -and ($_.CommandLine -like '*--daemon*') })
      return ($ps.Count -gt 0)
    } catch { return $false }
  }
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
  # 老名字的启动项还在的话先搬成新名字, 免得启动文件夹里新旧两份并存(两个开机自启)
  $legacyLnk = Get-BwStartupLnkLegacy
  if (Test-Path -LiteralPath $legacyLnk) { [void](Move-BwLnkToNewName $legacyLnk) }
  $lnk = Get-BwStartupLnk
  $exe = Get-BwLauncherPath
  if ((-not $exe) -or (-not (Test-Path -LiteralPath $exe))) {
    Write-Host ('  找不到主程序「' + $global:BWExeName + '」(旧版文件名也行)。')
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
    $sc.Description      = '桌面壁纸 - 开机自动换壁纸'
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
    if ($global:BWExeNamesFixed -notcontains (Split-Path $exe -Leaf)) {
      Write-Host '  (这份 exe 名字里带版本号, 以后换新版本要重开一次本开关)' -ForegroundColor DarkYellow
    }
    return $true
  } catch { Write-Host ('  开启失败: ' + $_.Exception.Message); return $false }
}
function Disable-BwAutoStart {
  $lnk = Get-BwStartupLnk
  $legacyLnk = Get-BwStartupLnkLegacy
  if ((-not (Test-Path -LiteralPath $lnk)) -and (-not (Test-Path -LiteralPath $legacyLnk))) {
    Write-Host '  开机自动换本来就是关着的, 不用关。'
    return $false
  }
  # 新老名字都清掉 —— 只删一个的话, 另一个还会在开机时把后台拉起来
  foreach ($p in @($lnk, $legacyLnk)) {
    if (Test-Path -LiteralPath $p) { try { Remove-Item -LiteralPath $p -Force } catch {} }
  }
  # 告诉还在后台跑的 daemon 收工
  try { Set-Content -LiteralPath (Join-Path $global:BWRoot 'daemon.stop') -Value 'stop' -Encoding ASCII } catch {}
  Write-Host '  已关闭开机自动换壁纸。想再开, 回来按 [A] 就行。'
  return $true
}

# 用户在面板上**主动**打开「桌面快捷方式」时用这个。
# 为什么不能直接用 Ensure-BwDesktopShortcut: 它有一条"用户删过就不再自动建"的保护
# （尊重用户删掉图标的决定），于是"你主动点开"也会被它挡回来，表现为"点了没反应"。
function New-BwDesktopShortcutForce {
  $info = Get-BwDeskInfo
  $want = Get-BwLauncherPath
  if ((-not $want) -or (-not (Test-Path -LiteralPath $want))) { return 'fail' }
  # 2026-10-23 用户要求：「开 -> 桌面有图标」。
  # 原来会沿用记录里的路径，而那个路径是桌面里的子文件夹（…\桌面\桌面图标\），
  # 资源管理器桌面上根本不显示子文件夹里的东西 —— 用户看到的就是"开了没变化"。
  # 所以主动打开时一律建在**桌面根目录**，并把记录改成这个位置。
  $target = Join-Path (Get-BwDesktopDir) $global:BWLnkName
  $dir = Split-Path $target -Parent
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    try { [void][System.IO.Directory]::CreateDirectory($dir) } catch {}
  }
  $sh = $null
  try { $sh = New-Object -ComObject WScript.Shell } catch { return 'fail' }
  $r = Write-BwShortcut $sh $target $want
  if ($r -ne 'fail') {
    $info.path = $target
    $info.created = 'yes'
    Save-BwDeskInfo $info
    Log ('桌面快捷方式: 已按用户操作重建 -> ' + $target)
  }
  return $r
}

# 面板里把「桌面快捷方式」关掉时, 要把桌面上那个 lnk 真删掉 ——
# 只改 config 不删文件, 用户会看到"关了但图标还在"。
function Remove-BwDesktopShortcut {
  $paths = @()
  try { $info = Get-BwDeskInfo; if ($info.path) { $paths += [string]$info.path } } catch {}
  # 桌面根那份也要删（主动打开时是建在这里的）
  try { $paths += (Join-Path (Get-BwDesktopDir) $global:BWLnkName) } catch {}
  try { $p = Find-BwDesktopLnk; if ($p) { $paths += [string]$p } } catch {}
  $n = 0
  foreach ($p in $paths) {
    if ($p -and (Test-Path -LiteralPath $p)) {
      try { Remove-Item -LiteralPath $p -Force -ErrorAction Stop; $n++ } catch {}
    }
  }
  if ($n -gt 0) {
    try { $info2 = Get-BwDeskInfo; $info2.path = ''; $info2.created = 'yes'; Save-BwDeskInfo $info2 } catch {}
  }
  Log ('桌面快捷方式: 已按设置删掉 ' + $n + ' 个')
  return $n
}

# ---------- [F] 收藏当前这张壁纸 ----------
# 取当前壁纸: 优先用 state 里程序自己记的那张, 读不到再回退注册表
# (用户可能自己手动换过壁纸, 那张也一样该能收藏)。

# ---- 面板用的 JSON 输出 ----
# 为什么不用 ConvertTo-Json: 实测(2026-10-23) 它把从 Get-Content 拿到的两行日志
# 序列化成了 6 万多字符(PSObject 包装被当成对象全量展开), 整个 state 拼完就不返回了。
# 这里只处理我们真正会输出的几种形状: 字典 / 数组 / 字符串 / 数字 / 布尔 / 普通对象。
function ConvertTo-BwPanelJsonStr([string]$s) {
  if ($null -eq $s) { $s = '' }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  foreach ($ch in $s.ToCharArray()) {
    $c = [int][char]$ch
    if ($ch -eq '"') { [void]$sb.Append('\"') }
    elseif ($ch -eq '\') { [void]$sb.Append('\\') }
    elseif ($c -eq 10) { [void]$sb.Append('\n') }
    elseif ($c -eq 13) { [void]$sb.Append('\r') }
    elseif ($c -eq 9) { [void]$sb.Append('\t') }
    elseif ($c -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $c)) }
    else { [void]$sb.Append($ch) }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}

function Add-BwPanelJson($sb, $v) {
  if ($null -eq $v) { [void]$sb.Append('null'); return }
  if ($v -is [string]) { [void]$sb.Append((ConvertTo-BwPanelJsonStr $v)); return }
  if ($v -is [bool]) { if ($v) { [void]$sb.Append('true') } else { [void]$sb.Append('false') }; return }
  if (($v -is [int]) -or ($v -is [long]) -or ($v -is [double]) -or ($v -is [decimal])) {
    [void]$sb.Append(([string]$v)); return
  }
  if ($v -is [System.Collections.IDictionary]) {
    [void]$sb.Append('{')
    $first = $true
    foreach ($k in $v.Keys) {
      if (-not $first) { [void]$sb.Append(',') }
      $first = $false
      [void]$sb.Append((ConvertTo-BwPanelJsonStr ([string]$k)))
      [void]$sb.Append(':')
      Add-BwPanelJson $sb $v[$k]
    }
    [void]$sb.Append('}')
    return
  }
  if ($v -is [System.Collections.IEnumerable]) {
    [void]$sb.Append('[')
    $first = $true
    foreach ($x in $v) {
      if (-not $first) { [void]$sb.Append(',') }
      $first = $false
      Add-BwPanelJson $sb $x
    }
    [void]$sb.Append(']')
    return
  }
  # 普通对象: 按属性逐个输出(这里只有 PSCustomObject, 不会有循环引用)
  [void]$sb.Append('{')
  $first = $true
  foreach ($p in $v.PSObject.Properties) {
    if (-not $first) { [void]$sb.Append(',') }
    $first = $false
    [void]$sb.Append((ConvertTo-BwPanelJsonStr ([string]$p.Name)))
    [void]$sb.Append(':')
    Add-BwPanelJson $sb $p.Value
  }
  [void]$sb.Append('}')
}

function ConvertTo-BwPanelJson($v) {
  $sb = New-Object System.Text.StringBuilder
  Add-BwPanelJson $sb $v
  return $sb.ToString()
}

# ---- 本地服务 ----
# 为什么手写最小 HTTP 而不用 HttpListener:
#   HttpListener 在部分机器上需要 URL 保留(要管理员), 换台机器就可能起不来;
#   TcpListener 只要绑 127.0.0.1, 普通用户一定开得起来。这里只服务一个本地页面,
#   不需要完整 HTTP 实现 —— 读到空行就够, 只处理 GET。
# 【2026-10-26 修】浏览器自己有一张「不安全端口」禁行表：Firefox 在
#   netwerk/base/nsIOService.cpp 的 kRestrictedPorts（83 项），Chromium/Edge 在
#   net/base/port_util.cc（79 项，是前者的子集，只少 4190/6679）。**撞上就直接
#   ERR_UNSAFE_PORT，浏览器连请求都不发** —— 服务端完全不知道有人来过。
#   现场：本机 11:33 系统随机发到 6666（IRC 备选端口），日志「面板: 本地服务已启动
#   -> http://127.0.0.1:6666/」，我用脚本取同一地址能拿到完整 108,934 B 页面、
#   /api/state 也 200，用户点图标却「控制台打不开」，连点三次全被「已经在跑, 直接复用」
#   指回这个死端口。所以端口不能全交给系统随机发。
# 这张表取两家并集，另外把 1024 以下一并排除（特权段，也容易撞上别人的服务）。
$global:BwBannedBrowserPorts = @(
  0, 1, 7, 9, 11, 13, 15, 17, 19, 20, 21, 22, 23, 25, 37, 42, 43, 53, 69, 77, 79, 87, 95,
  101, 102, 103, 104, 109, 110, 111, 113, 115, 117, 119, 123, 135, 137, 139, 143, 161, 179,
  389, 427, 465, 512, 513, 514, 515, 526, 530, 531, 532, 540, 548, 554, 556, 563, 587, 601,
  636, 989, 990, 993, 995, 1719, 1720, 1723, 2049, 3659, 4045, 4190, 5060, 5061, 6000, 6566,
  6665, 6666, 6667, 6668, 6669, 6679, 6697, 10080
)

function Test-BwBrowserSafePort {
  param([int]$Port)
  if ($Port -lt 1024) { return $false }
  if ($global:BwBannedBrowserPorts -contains $Port) { return $false }
  return $true
}

# 系统随机发一个端口（发不到就回 0）。单独拆出来是为了能被测试替换掉：
# 「系统发到禁行端口时到底会不会绕开」这件事，本机动态端口段会变（今天压到 1254–1453，
# 过一会儿又跳到 52000+），拿真机运气当判据的测试必然时灵时不灵，不如把这里做成可注入的桩。
function Get-BwPanelOsPort {
  try {
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $l.Start()
    $p = ([System.Net.IPEndPoint]$l.LocalEndpoint).Port
    $l.Stop()
    return $p
  } catch {
    return 0
  }
}

function Get-BwPanelPort {
  # 1) 先让系统发几次 —— 它一般给 49152+ 的动态私有段，既快又不会撞已在听的端口。
  for ($i = 0; $i -lt 8; $i++) {
    $p = Get-BwPanelOsPort
    if ((Test-BwBrowserSafePort $p)) { return $p }
    Log ('面板: 系统发到 ' + $p + ' 是浏览器禁行端口, 换一个再试')
  }
  # 2) 连着 8 次都不走运（本机就被 Hyper-V 的端口保留段挤到过低端口）：
  #    自己在 49153–65534 里挑一个当场试开一次，开得了才用。
  for ($i = 0; $i -lt 40; $i++) {
    $p = Get-Random -Minimum 49153 -Maximum 65535
    if (-not (Test-BwBrowserSafePort $p)) { continue }
    $free = $false
    try {
      $l2 = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $p)
      $l2.Start(); $l2.Stop(); $free = $true
    } catch { $free = $false }
    if ($free) { return $p }
  }
  return 0
}

function Send-BwPanelResponse($stream, [int]$code, [string]$type, [byte[]]$body, [string]$cache = 'no-store',
                              [string]$etag = '', [string]$lastMod = '') {
  $reason = 'OK'
  if ($code -eq 304) { $reason = 'Not Modified' }
  elseif ($code -eq 403) { $reason = 'Forbidden' }
  elseif ($code -eq 404) { $reason = 'Not Found' }
  elseif ($code -eq 500) { $reason = 'Server Error' }
  if ($null -eq $body) { $body = New-Object byte[] 0 }
  $head = ("HTTP/1.1 {0} {1}`r`nContent-Type: {2}`r`nContent-Length: {3}`r`nCache-Control: {4}`r`nConnection: close`r`n" -f $code, $reason, $type, $body.Length, $cache)
  # 2026-10-24: 图库缩略图要能缓存/304(网格里几十张图, 每次重开面板都重下太浪费)。
  if ($etag) { $head = $head + 'ETag: ' + $etag + "`r`n" }
  if ($lastMod) { $head = $head + 'Last-Modified: ' + $lastMod + "`r`n" }
  $head = $head + "`r`n"
  $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
  $stream.Write($hb, 0, $hb.Length)
  if ($body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
  $stream.Flush()
}

# ---- 图库只读接口 (2026-10-24 UI 整改新增) ----
# 为什么要单开两个接口:
#   原来面板只能按「必应库 / 聚焦库」分页拿 60 张、而且**看图必须带令牌**(/api/wall);
#   新图库页要一次拿到"文件名 / 时间 / 是否收藏 / 缩略图地址", 还要能 304 缓存,
#   否则网格里几十张 4K 图每次重开面板都重下一遍, 单线程服务会被拖住。
# 两个接口都是**只读**、只回数据目录内的图片、只认图片扩展名; 不返回任何绝对路径。
function Get-BwPanelGalleryItems {
  param([string]$src = 'all', [switch]$FavOnly, [int]$Skip = 0, [int]$Take = 48)
  if ($Take -le 0) { $Take = 48 }
  if ($Take -gt 200) { $Take = 200 }
  if ($Skip -lt 0) { $Skip = 0 }
  $c = Get-BwConfig
  $s = Get-BwState
  # 收藏名单里存的是"不带扩展名的名字"(也兼容带扩展名的老数据), 统一折算成 Get-BwNameKey 再比
  $favKeys = @{}
  try {
    foreach ($f in (Get-BwFav $s)) {
      $k = Get-BwNameKey ([string]$f)
      if ($k) { $favKeys[$k] = $true }
    }
  } catch {}
  $srcL = ([string]$src).Trim().ToLower()
  if (-not $srcL) { $srcL = 'all' }
  $dirs = @()
  if (($srcL -eq 'all') -or ($srcL -eq 'bing')) {
    $dirs += [PSCustomObject]@{ key = 'bing'; dir = [string]$c.bing_save_dir }
  }
  if (($srcL -eq 'all') -or ($srcL -eq 'spotlight')) {
    $dirs += [PSCustomObject]@{ key = 'spotlight'; dir = [string]$c.spotlight_save_dir }
  }
  if (($srcL -eq 'all') -or ($srcL -eq 'local')) {
    $ld = Get-BwLocalDir $c
    if ($ld) { $dirs += [PSCustomObject]@{ key = 'local'; dir = $ld } }
  }
  $files = @()
  foreach ($dd in $dirs) {
    $d = [string]$dd.dir
    if (-not $d) { continue }
    try { if (-not (Test-Path -LiteralPath $d)) { continue } } catch { continue }
    try {
      foreach ($f in @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue |
                       Where-Object { Test-BwImgFile $_.Name })) {
        $files += [PSCustomObject]@{ File = $f; Src = [string]$dd.key }
      }
    } catch {}
  }
  # 新的排前面(和原来"浏览图库"按文件名倒序一致); 时间相同再按名字倒序, 保证每次顺序一样。
  $files = @($files | Sort-Object -Property @{ Expression = { $_.File.LastWriteTimeUtc }; Descending = $true },
                                          @{ Expression = { $_.File.Name }; Descending = $true })
  $out = @()
  $seen = 0
  foreach ($it in $files) {
    $nm = [string]$it.File.Name
    $isFav = $false
    try { if ($favKeys.ContainsKey([string](Get-BwNameKey $nm))) { $isFav = $true } } catch {}
    if ($FavOnly -and (-not $isFav)) { continue }
    if ($seen -lt $Skip) { $seen++; continue }
    if ($out.Count -ge $Take) { break }
    $seen++
    $out += [ordered]@{
      name  = $nm
      src   = [string]$it.Src
      time  = $it.File.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
      ts    = [long]([DateTimeOffset]::new($it.File.LastWriteTimeUtc.ToUniversalTime()).ToUnixTimeSeconds())
      fav   = $isFav
      thumb = ('/?panel=thumb&name=' + [System.Uri]::EscapeDataString($nm) +
               '&v=' + [string]$it.File.LastWriteTimeUtc.Ticks)
    }
  }
  return $out
}
# 缩略图: 目前**直接回原图字节**(在浏览器里按网格缩放), 不引 GDI+ 缩放 ——
# 这个服务是单线程手写 TcpListener, 现场解码 4K 图会把整页卡住;
# 真正的代价(几 MB 的下载)被 ETag/304 + 浏览器缓存 + loading="lazy" 兜住了。
function Send-BwPanelThumb($stream, [string]$name, [string]$ifNoneMatch, $utf8) {
  $name = [string]$name
  # 只接受"一个纯文件名": 带路径分隔符、带 ..、带盘符冒号、非图片扩展名, 一律 403。
  $bad = $false
  if (-not $name) { $bad = $true }
  elseif ($name.Length -gt 260) { $bad = $true }
  elseif ($name -match '[\\/]') { $bad = $true }
  elseif ($name -match '\.\.') { $bad = $true }
  elseif ($name -match '[:*?"<>|]') { $bad = $true }
  elseif (-not (Test-BwImgFile $name)) { $bad = $true }
  if ($bad) {
    Send-BwPanelResponse $stream 403 'text/plain; charset=utf-8' $utf8.GetBytes('只允许图库目录里的图片文件')
    return
  }
  $full = ''
  try { $full = Get-BwPanelResolve $name } catch { $full = '' }
  # 再兜一道: 解析出来的绝对路径必须真落在允许的目录里(防"解析函数之外的意外")
  $okPath = $false
  if ($full) {
    try {
      $fp = [System.IO.Path]::GetFullPath($full)
      $c = Get-BwConfig
      $roots = @([string]$c.bing_save_dir, [string]$c.spotlight_save_dir)
      $ld = Get-BwLocalDir $c
      if ($ld) { $roots += $ld }
      foreach ($d in $roots) {
        if (-not $d) { continue }
        $dd = ([System.IO.Path]::GetFullPath($d)).TrimEnd('\') + '\'
        if ($fp.StartsWith($dd, [System.StringComparison]::OrdinalIgnoreCase)) { $okPath = $true; break }
      }
    } catch { $okPath = $false }
  }
  if (-not ($full -and $okPath -and (Test-Path -LiteralPath $full))) {
    Send-BwPanelResponse $stream 404 'text/plain; charset=utf-8' $utf8.GetBytes('这张图不在了')
    return
  }
  $fi = $null
  try { $fi = Get-Item -LiteralPath $full -ErrorAction Stop } catch { $fi = $null }
  if (-not $fi) {
    Send-BwPanelResponse $stream 404 'text/plain; charset=utf-8' $utf8.GetBytes('这张图不在了')
    return
  }
  $etag = '"' + (Get-BwHash ($name + '|' + [string]$fi.Length + '|' + [string]$fi.LastWriteTimeUtc.Ticks)) + '"'
  $lm = $fi.LastWriteTimeUtc.ToString('r')
  $cache = 'private, max-age=600'
  $inm = ([string]$ifNoneMatch).Trim()
  if ($inm -and ($inm -eq $etag)) {
    Send-BwPanelResponse $stream 304 'image/jpeg' ([byte[]]@()) $cache $etag $lm
    return
  }
  $mt = 'image/jpeg'
  $ext = ''
  try { $ext = [System.IO.Path]::GetExtension($full).ToLower() } catch { $ext = '' }
  if ($ext -eq '.png') { $mt = 'image/png' }
  elseif ($ext -eq '.webp') { $mt = 'image/webp' }
  elseif ($ext -eq '.bmp') { $mt = 'image/bmp' }
  elseif ($ext -eq '.gif') { $mt = 'image/gif' }
  elseif ($ext -eq '.tif' -or $ext -eq '.tiff') { $mt = 'image/tiff' }
  $bytes = $null
  try { $bytes = [System.IO.File]::ReadAllBytes($full) } catch { $bytes = $null }
  if (-not $bytes) {
    Send-BwPanelResponse $stream 404 'text/plain; charset=utf-8' $utf8.GetBytes('这张图读不出来')
    return
  }
  Send-BwPanelResponse $stream 200 $mt $bytes $cache $etag $lm
}

# 只绑回环地址; 令牌每启动一次换一个, 页面里的 {{BWPANEL_TOKEN}} 会被替换掉。
# IdleMinutes: 一直没人访问就自己退出, 不在后台永久驻留。
# 2026-10-23: 已经有一个控制台服务在跑? 有就直接把浏览器指过去, 不新起进程。
# 判据三样都对才复用: 记录文件在 / 那个进程还活着 / 那个端口真在监听。
function Open-BwExistingPanel {
  param([switch]$NoBrowser)
  $f = Join-Path $global:BWRoot 'panel.serve.json'
  if (-not (Test-Path -LiteralPath $f)) { return $false }
  $rec = $null
  try { $rec = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $false }
  if (-not $rec) { return $false }
  $port = 0
  try { $port = [int]$rec.port } catch { return $false }
  if ($port -le 0) { return $false }
  $alive = $false
  try { $alive = [bool](Get-Process -Id ([int]$rec.pid) -ErrorAction Stop) } catch { $alive = $false }
  if (-not $alive) { try { Remove-Item -LiteralPath $f -Force } catch {}; return $false }
  # 【2026-10-25 热更后面板还是旧界面】
  # 服务进程在启动时就把 core.ps1 里的整页 HTML 读进内存了。更新/热换 core.ps1 之后,
  # 旧的窗口服务还活着、端口也还通 —— 用户点图标时被"复用"到那一个, 看到的仍是
  # 更新前的页面, 会以为"改了跟没改一样"(本轮必应模式就是这么撞上的)。
  # 所以记录里带上 core.ps1 的时间戳指纹: 对不上 = 那是上一版脚本起的服务,
  # **只关我们自己那个进程**(命令行必须指向本目录的 menu.ps1/core.ps1, 防止 PID 被系统复用误杀),
  # 然后让本次调用者重新起一个。
  $mine = 0
  try { $mine = (Get-Item -LiteralPath (Join-Path $global:BWRoot 'core.ps1')).LastWriteTimeUtc.Ticks } catch {}
  $theirs = 0
  try { if ($rec.PSObject.Properties['core']) { $theirs = [long]$rec.core } } catch { $theirs = 0 }
  if ($mine -gt 0 -and ($theirs -ne $mine)) {
    $killed = $false
    try {
      $p0 = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + [int]$rec.pid) -ErrorAction Stop
      $cmd = ''
      if ($p0) { $cmd = [string]$p0.CommandLine }
      if ($cmd -and (($cmd.IndexOf('menu.ps1') -ge 0) -or ($cmd.IndexOf('core.ps1') -ge 0))) {
        Stop-Process -Id ([int]$rec.pid) -Force -ErrorAction Stop
        $killed = $true
      }
    } catch {}
    try { Remove-Item -LiteralPath $f -Force } catch {}
    Log ('面板: 上次那个窗口服务是旧一版脚本起的(' + $(if ($killed) { '已关掉' } else { '没能关掉, 交给闲置退出' }) + '), 这次重新起一个')
    return $false
  }
  $listening = $false
  try {
    $cli = New-Object System.Net.Sockets.TcpClient
    $ar = $cli.BeginConnect('127.0.0.1', $port, $null, $null)
    if ($ar.AsyncWaitHandle.WaitOne(1500)) { $cli.EndConnect($ar); $listening = $true }
    $cli.Close()
  } catch { $listening = $false }
  if (-not $listening) { return $false }
  $url = ('http://127.0.0.1:{0}/' -f $port)
  if (-not $NoBrowser) { try { Start-Process $url | Out-Null } catch {} }
  Log ('面板: 已经在跑, 直接复用 -> ' + $url)
  return $true
}

function Start-BwPanelServer {
  param([int]$Port = 0, [int]$IdleMinutes = 30, [switch]$NoBrowser)

  if ($Port -le 0) { $Port = Get-BwPanelPort }
  if ($Port -le 0) { throw '挑不出可用的本地端口' }

  $token = [guid]::NewGuid().ToString('N')
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $listener = $null
  try {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
  } catch {
    throw ('本地端口打不开: ' + $_.Exception.Message)
  }

  # 2026-10-24 用户要求：地址栏要干净，不要 ?t= 令牌（令牌已嵌在页面里，页面照常能操作）
  $url = ('http://127.0.0.1:{0}/' -f $Port)
  # 2026-10-23: 把"正在服务"记下来, 下次点图标时直接复用这个服务,
  # 不再每点一次就多起一个进程(以前旧的要等 30 分钟闲置才退, 同时挂好几个, 每个约 140MB)。
  $serveFile = Join-Path $global:BWRoot 'panel.serve.json'
  try {
    # core 指纹: 见 Open-BwExistingPanel 里的说明 —— 升级/热换脚本后旧服务不再被复用
    $coreTicks = 0
    try { $coreTicks = (Get-Item -LiteralPath (Join-Path $global:BWRoot 'core.ps1')).LastWriteTimeUtc.Ticks } catch {}
    $rec0 = [ordered]@{ port = $Port; token = $token; pid = $PID; core = $coreTicks
                        url = $url; since = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    [System.IO.File]::WriteAllText($serveFile, ($rec0 | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
  Log ('面板: 本地服务已启动 -> ' + $url)

  $last = Get-Date
  $running = $true

  if (-not $NoBrowser) {
    try { Start-Process $url | Out-Null } catch { Log ('面板: 打不开浏览器: ' + $_.Exception.Message) 'WARN' }
  }

  try {
    while ($running) {
      if (-not $listener.Pending()) {
        # 2026-10-24: 原来是 120ms —— 每个请求都可能白等一个睡眠周期（面板所有请求都慢 100ms+）。
        # 改成 15ms：空转成本可以忽略，但页面/状态请求明显更快。
        Start-Sleep -Milliseconds 15
        if (($IdleMinutes -gt 0) -and (((Get-Date) - $last).TotalMinutes -ge $IdleMinutes)) {
          Log '面板: 闲置太久, 自动退出'
          break
        }
        continue
      }

      $client = $listener.AcceptTcpClient()
      try {
        $client.ReceiveTimeout = 3000
        $stream = $client.GetStream()
        $buf = New-Object byte[] 8192
        $sb = New-Object System.Text.StringBuilder
        while ($true) {
          $n = $stream.Read($buf, 0, $buf.Length)
          if ($n -le 0) { break }
          [void]$sb.Append([System.Text.Encoding]::ASCII.GetString($buf, 0, $n))
          if ($sb.Length -gt 16384) { break }
          $t = $sb.ToString()
          if ($t.Contains("`r`n`r`n") -or $t.Contains("`n`n")) { break }
        }

        $line = ''
        $inm = ''
        foreach ($ln in ($sb.ToString() -split "`r?`n")) {
          if (-not $line) { if ($ln.Trim()) { $line = $ln.Trim() }; continue }
          # 图库缩略图要支持 304: 记下浏览器的 If-None-Match（就是上次我们发的 ETag）
          if ($ln -match '^(?i)If-None-Match:\s*(.+)$') { $inm = $matches[1].Trim(); break }
        }
        # 2026-10-25 收边（日志里那条假报错）: 面板的"你还活着吗"探针是一次裸 TCP 连接
        # (见上面复用判断里的 TcpClient), 连上就关、一个字节都不发。以前这种空请求也会
        # 一路往下走 —— 给一个已经关掉的 socket 现拼 74KB 页面再写出去, 写失败被外层
        # catch 记成 "[WARN] 面板: 处理请求出错: …无法将数据写入传输连接…"。
        # 用户每次从菜单进面板, 日志尾巴上就多一条这种吓人的假故障。
        # 现在空请求直接静默断开(外层 finally 负责关 socket), 既不生成页面也不记 WARN,
        # 也**不**刷新 $last —— 探针不该让闲置自动退出被续命。
        if (-not $line) { continue }
        $target = '/'
        if ($line -match '^([A-Za-z]+)\s+(\S+)') { $target = $matches[2] }
        $last = Get-Date

        $u = $null
        try { $u = New-Object System.Uri(('http://127.0.0.1:' + $Port + $target)) } catch { $u = $null }
        $path = '/'
        if ($u) { $path = $u.AbsolutePath }
        if ($env:BWPANEL_DEBUG -eq '1') { Log ('面板调试: ' + $line) }

        $q = @{}
        if ($u) {
          $qs = [string]$u.Query
          if ($qs.StartsWith('?')) { $qs = $qs.Substring(1) }
          foreach ($kv in ($qs -split '&')) {
            if (-not $kv) { continue }
            $i = $kv.IndexOf('=')
            if ($i -lt 0) { $q[$kv] = '' }
            else {
              $k = [System.Uri]::UnescapeDataString($kv.Substring(0, $i))
              $v = [System.Uri]::UnescapeDataString($kv.Substring($i + 1))
              $q[$k] = $v
            }
          }
        }

        # 2026-10-24: 图库的两个只读接口挂在根路径的 ?panel= 上(与原来 /api/* 并存, 一个都没改):
        #   ?panel=gallery[&src=all|bing|spotlight|local][&fav=1][&skip=N][&take=N]  -> 裸数组
        #   ?panel=thumb&name=<文件名>                                                -> 图片字节 + ETag/304
        #   ?panel=state[&t=<令牌>]                                                   -> 与 /api/state 同一份 JSON
        # 其中 gallery / thumb **不需要令牌**: 只读、只回数据目录里的图片、不返回绝对路径, 服务本身也只绑 127.0.0.1。
        # state 里有目录路径和日志尾巴, 所以照旧要令牌(它只是 /api/state 的别名)。
        $panelView = ''
        if ($q.ContainsKey('panel')) { $panelView = ([string]$q['panel']).Trim().ToLower() }

        if (($panelView -ne '') -and (($path -eq '/') -or ($path -eq '/index.html') -or ($path -eq '/panel.html'))) {
          if (($panelView -eq 'state') -and (([string]$q['t']) -ne $token)) {
            # 2026-10-24 修正: 这份 JSON 里有 dataDir / dirs.* / desktop.path /
            # local.dir / 最近动作(日志尾巴) —— 免令牌时本机任何进程都能把
            # 用户的目录结构和日志尾巴读走。页面本身走的是 /api/state?t=(见 panel.html),
            # 这个别名只是同一份东西, 所以一样要令牌; gallery/thumb 仍按原口径免令牌。
            Send-BwPanelResponse $stream 403 'text/plain; charset=utf-8' $utf8.GetBytes('令牌不对')
          }
          elseif ($panelView -eq 'state') {
            # 只读状态: 和 /api/state 是同一份 JSON。
            # 旧的 /api/state 一点没改(仍然要令牌), 这里只是多一个只读别名, 给图库和自检用。
            # 2026-10-24: 2 秒内重复请求直接回缓存（页面刷新/自检脚本会连打两次）。
            $nowSt = [DateTime]::UtcNow
            if ($global:BwPanelStateCache -and (($nowSt - $global:BwPanelStateAt).TotalMilliseconds -lt 2000)) {
              $stxt = $global:BwPanelStateCache
            } else {
              $stj = $null
              try { $stj = Get-BwPanelState } catch { $stj = [ordered]@{ ok = $false; error = $_.Exception.Message } }
              $stxt = '{"ok":false,"error":"状态读不出来"}'
              try { $stxt = ConvertTo-BwPanelJson $stj } catch {}
              $global:BwPanelStateCache = $stxt
              $global:BwPanelStateAt = [DateTime]::UtcNow
            }
            Send-BwPanelResponse $stream 200 'application/json; charset=utf-8' $utf8.GetBytes($stxt) 'no-store'
          }
          elseif ($panelView -eq 'gallery') {
            $gsrc = 'all'; $gskip = 0; $gtake = 48; $gfav = $false
            try { if ($q.ContainsKey('src')) { $gsrc = [string]$q['src'] } } catch {}
            try { if ($q.ContainsKey('skip')) { $gskip = [int]$q['skip'] } } catch { $gskip = 0 }
            try { if ($q.ContainsKey('take')) { $gtake = [int]$q['take'] } } catch { $gtake = 48 }
            try {
              $fv = ([string]$q['fav']).Trim().ToLower()
              if (@('1','true','on','yes') -contains $fv) { $gfav = $true }
            } catch { $gfav = $false }
            $items = @()
            try { $items = @(Get-BwPanelGalleryItems -src $gsrc -FavOnly:$gfav -Skip $gskip -Take $gtake) }
            catch { Log ('面板: 图库清单出错: ' + $_.Exception.Message) 'WARN' }
            # 手写拼接(不走 ConvertTo-BwPanelJson): 空数组也必须是合法的 []
            $gjs = New-Object System.Text.StringBuilder
            [void]$gjs.Append('[')
            $gfirst = $true
            foreach ($it in $items) {
              if (-not $gfirst) { [void]$gjs.Append(',') }
              $gfirst = $false
              Add-BwPanelJson $gjs $it
            }
            [void]$gjs.Append(']')
            Send-BwPanelResponse $stream 200 'application/json; charset=utf-8' $utf8.GetBytes($gjs.ToString()) 'no-store'
          }
          elseif ($panelView -eq 'thumb') {
            $tn = ''
            try { if ($q.ContainsKey('name')) { $tn = [string]$q['name'] } } catch { $tn = '' }
            Send-BwPanelThumb $stream $tn $inm $utf8
          }
          else {
            Send-BwPanelResponse $stream 404 'text/plain; charset=utf-8' $utf8.GetBytes('没有这个面板视图')
          }
        }
        elseif (($path -eq '/') -or ($path -eq '/index.html') -or ($path -eq '/panel.html')) {
          $html = [string]$global:BwPanelHtml
          $html = $html.Replace('{{BWPANEL_TOKEN}}', $token)
          # 2026-10-25 修「主题/配色换次开机就丢」: 面板端口是 Get-BwPanelPort 现抢的随机端口
          # (TcpListener 回环 0 号口, 实测同一台机器 10845 -> 38919), 于是每次开机
          # http://127.0.0.1:<另一个端口> 就是另一个 origin, localStorage 里存的观感设置
          # 再也看不见 —— 用户选过的明暗/主色等于静默丢失。现在观感落在 config.json,
          # 出页面时把当前值注入进去, 页面 bootstrap 先读它、再回落 localStorage。
          # 取值一律过白名单: 字段不存在或值不认识 -> 注入空串, 让页面回落到浏览器里
          # 存的老观感(升级那一刻不变样)。绝不把任意字符串塞进页面。
          $uiT = ''
          $uiA = ''
          try {
            $cui = Get-BwConfig
            if ($cui.PSObject.Properties['panel_theme']) {
              $vt = ([string]$cui.panel_theme).Trim().ToLower()
              if (@('auto', 'light', 'dark') -contains $vt) { $uiT = $vt }
            }
            if ($cui.PSObject.Properties['panel_accent']) {
              $va = ([string]$cui.panel_accent).Trim().ToLower()
              if (@('default', 'blue', 'green', 'violet', 'amber') -contains $va) { $uiA = $va }
            }
          } catch {}
          $html = $html.Replace('{{BWUI_THEME}}', $uiT)
          $html = $html.Replace('{{BWUI_ACCENT}}', $uiA)
          Send-BwPanelResponse $stream 200 'text/html; charset=utf-8' $utf8.GetBytes($html)
        }
        elseif (($path -eq '/api/state') -or ($path -eq '/api/do') -or ($path -eq '/api/wall') -or ($path -eq '/api/now')) {
          if ([string]$q['t'] -ne $token) {
            Send-BwPanelResponse $stream 403 'text/plain; charset=utf-8' $utf8.GetBytes('令牌不对')
          }
          elseif ($path -eq '/api/now') {
            # 【2026-10-25 用户「当前预览图没有锁定当前壁纸的图像，关闭窗口[重开]才恢复」】
            # 页面每 15 秒问一次的轻量探针: 只回"桌面现在挂的是哪张 + 换上的时刻"。
            # 用 state.json 的**修改时间**做缓存 —— 没换图时只有一个 Get-Item,
            # 不解析 68KB 的 JSON、不读目录、不带日志尾巴, 单线程 TcpListener 扛得住。
            # 有令牌才给路径(与 /api/state 同口径), gallery/thumb 那套免令牌的口径不变。
            $ntxt = ''
            $ticks = 0
            try { $ticks = (Get-Item -LiteralPath $global:BWState).LastWriteTimeUtc.Ticks } catch { $ticks = 0 }
            if ($global:BwNowCache -and ([string]$global:BwNowTicks -eq [string]$ticks)) {
              $ntxt = [string]$global:BwNowCache
            } else {
              $nw = ''; $ns = ''
              try {
                $s0 = Get-BwState
                if ($s0.PSObject.Properties['last_wall']) { $nw = [string]$s0.last_wall }
                if ($s0.PSObject.Properties['last_swap']) { $ns = [string]$s0.last_swap }
              } catch {}
              try { $ntxt = ConvertTo-BwPanelJson ([ordered]@{ ok = $true; wall = $nw; swap = $ns }) }
              catch { $ntxt = '{"ok":false}' }
              $global:BwNowCache = $ntxt
              $global:BwNowTicks = $ticks
            }
            Send-BwPanelResponse $stream 200 'application/json; charset=utf-8' $utf8.GetBytes($ntxt) 'no-store'
          }
          elseif ($path -eq '/api/wall') {
            $want = ''
            if ($q.ContainsKey('p')) { $want = [string]$q['p'] }
            $full = ''
            $okPath = $false
            if ($want) {
              try {
                $full = [System.IO.Path]::GetFullPath($want)
                $c = Get-BwConfig
                $roots = @($c.bing_save_dir, $c.spotlight_save_dir, (Join-Path $global:BWRoot '合成'))
                # 2026-10-24: 本地文件夹图源的图也要能在大图里显示(/api/wall 仍然要令牌、只认图片)
                $ld0 = Get-BwLocalDir $c
                if ($ld0) { $roots += $ld0 }
                foreach ($d in $roots) {
                  if (-not $d) { continue }
                  $dd = ([System.IO.Path]::GetFullPath($d)).TrimEnd('\') + '\'
                  if ($full.StartsWith($dd, [System.StringComparison]::OrdinalIgnoreCase)) { $okPath = $true; break }
                }
              } catch { $okPath = $false }
            }
            if ($okPath -and (Test-Path -LiteralPath $full)) {
              $bytes = [System.IO.File]::ReadAllBytes($full)
              $ext = [System.IO.Path]::GetExtension($full).ToLower()
              $mt = 'image/jpeg'
              if ($ext -eq '.png') { $mt = 'image/png' }
              elseif ($ext -eq '.webp') { $mt = 'image/webp' }
              elseif ($ext -eq '.bmp') { $mt = 'image/bmp' }
              elseif ($ext -eq '.gif') { $mt = 'image/gif' }
              Send-BwPanelResponse $stream 200 $mt $bytes
            } else {
              Send-BwPanelResponse $stream 404 'text/plain; charset=utf-8' $utf8.GetBytes('这张图不在了')
            }
          }
          else {
            $req = New-Object PSObject
            if ($path -eq '/api/state') {
              Add-Member -InputObject $req NoteProperty do 'state' -Force
            } else {
              Add-Member -InputObject $req NoteProperty do ([string]$q['do']) -Force
              if ($q.ContainsKey('key')) { Add-Member -InputObject $req NoteProperty key ([string]$q['key']) -Force }
              if ($q.ContainsKey('value')) { Add-Member -InputObject $req NoteProperty value ([string]$q['value']) -Force }
              if ($q.ContainsKey('name')) { Add-Member -InputObject $req NoteProperty name ([string]$q['name']) -Force }
            }
            $res = $null
            try { $res = Invoke-BwPanelAction $req }
            catch { $res = [ordered]@{ ok = $false; error = $_.Exception.Message } }
            $json = ConvertTo-BwPanelJson $res
            Send-BwPanelResponse $stream 200 'application/json; charset=utf-8' $utf8.GetBytes($json)
            if (([string]$q['do']).ToLower() -eq 'quit') { $running = $false }
          }
        }
        else {
          Send-BwPanelResponse $stream 404 'text/plain; charset=utf-8' $utf8.GetBytes('没有这个地址')
        }
      } catch {
        # 2026-10-25 收边: 浏览器中途取消请求(切标签页、关窗口)也会让写响应抛异常,
        # 那是客户端走的, 不是面板坏了 —— 只有这类"连接被对端掐掉"降级成调试行,
        # 其余异常照旧记 WARN, 不放过真故障。中英文两种 socket 报错都认。
        $msg = [string]$_.Exception.Message
        if ($msg -match '无法将数据写入传输连接|中止了一个已建立的连接|远程主机强迫关闭|An established connection was aborted|software caused connection abort') {
          if ($env:BWPANEL_DEBUG -eq '1') { Log ('面板调试: 客户端提前断开, 本次响应没发出去') }
        } else {
          Log ('面板: 处理请求出错: ' + $msg) 'WARN'
        }
      } finally {
        try { $client.Close() } catch {}
      }
    }
  } finally {
    try { $listener.Stop() } catch {}
    # 只删自己那份记录(端口 + 令牌都对得上才删), 免得把别的实例的记录删了
    try {
      if ((Test-Path -LiteralPath $serveFile)) {
        $r0 = Get-Content -LiteralPath $serveFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (([int]$r0.port -eq $Port) -and ([string]$r0.token -eq $token)) { Remove-Item -LiteralPath $serveFile -Force }
      }
    } catch {}
    Log '面板: 本地服务已停止'
  }
  return $url
}

# 把 state.json 里的文件名解析成库里的完整路径(必应库 / 聚焦库各找一遍)。
function Get-BwPanelResolve([string]$name) {
  if (-not $name) { return '' }
  $c = Get-BwConfig
  # state.json 里的「最近换过的 / 收藏」存的是**不带扩展名**的名字
  # （例：2026-10-15_桥梁、屋顶与暮色_弗罗茨瓦夫），而库里的文件是 .jpg。
  # 2026-10-23 修：按名字直接拼路径会一律找不到，面板上就显示"还没有换过图"。
  $cands = @($name)
  if (-not [System.IO.Path]::HasExtension($name)) {
    foreach ($e in @('.jpg', '.jpeg', '.png', '.webp', '.bmp')) { $cands += ($name + $e) }
  }
  $dirs = @($c.bing_save_dir, $c.spotlight_save_dir)
  # 2026-10-24: 本地文件夹图源里的图也要能解析到(否则图库里点它当壁纸会"找不到这张图")
  $ld = Get-BwLocalDir $c
  if ($ld) { $dirs += $ld }
  foreach ($d in $dirs) {
    if (-not $d) { continue }
    foreach ($n in $cands) {
      try {
        $p = Join-Path $d $n
        if (Test-Path -LiteralPath $p) { return $p }
      } catch {}
    }
  }
  return ''
}

# 2026-10-24(面板轻量化): 一次把三个库目录列出来, 做成「文件名 -> 完整路径」索引。
# 原来 Get-BwPanelState 要对最多 12 张历史 + 24 张收藏逐个试 5 种扩展名 × 2 个目录
# (上百次 Test-Path, 一次状态请求实测 250 ms); 换成"列一次目录 + 字典查", 降到几十毫秒。
# 注意: 这个索引只给**面板状态**用; 缩略图/设为壁纸那两条路仍然走 Get-BwPanelResolve(单次判断, 不受影响)。
function Get-BwPanelIndex {
  $nowIx = [DateTime]::UtcNow
  if ($global:BwPanelIdxCache -and (($nowIx - $global:BwPanelIdxAt).TotalMilliseconds -lt 8000)) {
    return $global:BwPanelIdxCache
  }
  $c = Get-BwConfig
  $dirs = @([string]$c.bing_save_dir, [string]$c.spotlight_save_dir)
  $ld = Get-BwLocalDir $c
  if ($ld) { $dirs += $ld }
  $map = @{}
  $kmap = @{}
  # 【2026-10-25 用户「必应模式下最近换过那一排也该切到必应图库」】同一趟扫描里再记一份
  # "完整路径 -> 属于哪个库"(bing / spotlight / local)。history 里存的是图片编号, 光看文件名
  # 分不出必应还是聚焦(两边的命名都是 yyyy-MM-dd_标题), 所以只能在解析出路径之后按目录认。
  $smap = @{}
  $srcTag = @('bing', 'spotlight', 'local')
  $counts = @(0, 0, 0)
  $i = 0
  foreach ($d in $dirs) {
    $n = 0
    if ($d) {
      try {
        foreach ($f in @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue |
                         Where-Object { Test-BwImgFile $_.Name })) {
          $k = ([string]$f.Name).ToLower()
          if (-not $map.ContainsKey($k)) { $map[$k] = [string]$f.FullName }
          $tag = 'bing'
          if ($i -lt 3) { $tag = [string]$srcTag[$i] }
          $fk = ([string]$f.FullName).ToLower()
          if (-not $smap.ContainsKey($fk)) { $smap[$fk] = $tag }
          # 【2026-10-25 用户「最近换过的图不对」第二半】同一趟目录扫描里再存一份
          # 「图片编号 -> 完整路径」。state.json 的 history 存的是 Get-BwNameKey 出来的
          # **编号**而不是文件名: 聚焦图取文件名末尾那段 slug(2026-10-08_一片极度干旱的海岸_
          # skeletoncoastnamibia.jpg -> skeletoncoastnamibia), 必应图没有 slug 才用整个文件名。
          # 所以只按文件名查的话, 聚焦图那几条永远查不到 —— 现象就是刚换上的一张
          # 明明在桌面上了, 「最近换过」里却没有它, 排第一的还是上一张。
          $nk = Get-BwNameKey ([string]$f.Name)
          if ($nk) {
            $nk = $nk.ToLower()
            if (-not $kmap.ContainsKey($nk)) { $kmap[$nk] = [string]$f.FullName }
          }
          $n++
        }
      } catch {}
    }
    if ($i -lt 3) { $counts[$i] = $n }
    $i++
  }
  $idx = @{ Map = $map; KeyMap = $kmap; Src = $smap; Bing = [int]$counts[0]; Spotlight = [int]$counts[1]; Local = [int]$counts[2] }
  $global:BwPanelIdxCache = $idx
  $global:BwPanelIdxAt = [DateTime]::UtcNow
  return $idx
}
# 名字 -> 完整路径(与 Get-BwPanelResolve 同一口径: 先按原样找, 名字没扩展名再补常见扩展名)
function Resolve-BwPanelName($idx, [string]$name) {
  if (-not ($idx -and $name)) { return '' }
  $map = $idx['Map']
  if (-not $map) { return '' }
  $k = ([string]$name).ToLower()
  if ($map.ContainsKey($k)) { return [string]$map[$k] }
  if (-not [System.IO.Path]::HasExtension($name)) {
    foreach ($e in @('.jpg', '.jpeg', '.png', '.webp', '.bmp')) {
      $k2 = $k + $e
      if ($map.ContainsKey($k2)) { return [string]$map[$k2] }
    }
  }
  return ''
}
# 图片编号(Get-BwNameKey 的输出) -> 完整路径。给「最近换过」用: 那里的名字是编号不是文件名。
function Resolve-BwPanelKey($idx, [string]$key) {
  if (-not ($idx -and $key)) { return '' }
  $m = $idx['KeyMap']
  if (-not $m) { return '' }
  $k = ([string]$key).ToLower()
  if ($m.ContainsKey($k)) { return [string]$m[$k] }
  return ''
}

function Get-BwPanelState {
  $c = Get-BwConfig
  $s = Get-BwState
  if (-not $s) { $s = New-Object PSObject }
  # 一次列目录的索引(见 Get-BwPanelIndex 的说明): 状态里"找图"和"数张"都走它, 不再上百次 Test-Path
  $idx = $null
  try { $idx = Get-BwPanelIndex } catch { $idx = $null }

  # 面板只读这几项; 原样回传的话会把路径、上限之类一次性全抖出去, 没必要。
  $cfg = [ordered]@{}
  foreach ($k in @('cycle_minutes','resolution_mode','wallpaper_style','auto_fetch','fav_only',
                   'art_fit_mode','desktop_shortcut','lib_cap','bing_cap','spotlight_per_cycle',
                   'fetch_round_cap','fetch_day_cap','recycle_min_days','src_timeout_sec','bing_only',
                   'local_src_dir')) {
    $v = $null
    try { if ($c.PSObject.Properties[$k]) { $v = $c.PSObject.Properties[$k].Value } } catch {}
    $cfg[$k] = $v
  }

  $lastWall = ''; $lastSwap = ''; $shown = 0; $queueCount = 0
  try { if ($s.last_wall) { $lastWall = [string]$s.last_wall } } catch {}
  try { if ($s.last_swap) { $lastSwap = [string]$s.last_swap } } catch {}
  try { $shown = [int]$s.shown } catch { $shown = 0 }
  try { $queueCount = @($s.queue | Where-Object { $_ }).Count } catch { $queueCount = 0 }

  $favs = @()
  try { $favs = @($s.favorites | Where-Object { $_ }) } catch { $favs = @() }
  $hist = @()
  try { $hist = @($s.history | Where-Object { $_ }) } catch { $hist = @() }

  # 缩略图只回"能真找到文件的", 免得面板上出现一排破图
  #
  # 【2026-10-25 修「最近换过」显示的根本不是最近换的（用户截图）】
  # `history` 是**追加表**：越靠后越是刚换过的（本机实测 history[-1] = blueparrotfish，
  # 正是 14:58 刚换上的那张）。原来这里 `foreach ($x in $hist)` 从下标 0 往后取 12 条，
  # 取到的其实是"最早换过、而且文件侥幸还在库里"的那批 —— 本机真账为证：
  #   2026-10-23_荒野伙伴… / 2023-01-01_在北极附近打盹 / 2023-01-02… 01-03… 01-04…
  # 标题写着「最近换过」、内容却是「最久换过」，刚换上的那张压根不在名单里。
  # 改成**从尾部往前取**，并把 `hist_at`（slug -> 换上时间）一起带出去给角标用，
  # 让角标的日期和栏目标题是同一个口径：显示的是"哪天换上的"，不是"图本身是哪天的"。
  $histAt = @{}
  try {
    foreach ($pk in @($s.hist_at.PSObject.Properties)) {
      if ($pk.Name) { $histAt[[string]$pk.Name] = [string]$pk.Value }
    }
  } catch {}
  $histOut = @(); $n = 0
  for ($i = (@($hist).Count - 1); $i -ge 0; $i--) {
    # 【2026-10-25】12 -> 24: 页面只画 4 张, 但必应模式下前端要**先按库筛**再取 4 张
    # (用户「最近换过浏览框也应该切换到必应图库」)。刚切过模式时名单里多半还压着
    # 上一模式的聚焦图, 只给 12 条会筛不出东西。多给十几条只是字符串, 不值钱。
    if ($n -ge 24) { break }
    $x = [string]$hist[$i]
    # 先按文件名查(必应图的历史记的就是整个文件名), 查不到再按图片编号查
    # (聚焦图记的是末尾 slug, 见 Get-BwPanelIndex 里的说明)。
    $p = Resolve-BwPanelName $idx $x
    $nm = $x
    if (-not $p) {
      $p = Resolve-BwPanelKey $idx $x
      if ($p) { $nm = [System.IO.Path]::GetFileNameWithoutExtension([string]$p) }
    }
    if (-not $p) { continue }
    $at = ''
    if ($histAt.ContainsKey($x)) { $at = [string]$histAt[$x] }
    # 这张属于哪个库(bing / spotlight / local) —— 前端按当前模式决定「最近换过」显不显它
    $src = ''
    $sm = $idx['Src']
    if ($sm) { $src = [string]$sm[[string]$p.ToLower()] }
    $histOut += [PSCustomObject]@{ name = $nm; path = $p; at = $at; src = $src }
    $n++
  }
  $favOut = @(); $n = 0
  foreach ($x in $favs) {
    if ($n -ge 24) { break }
    $p = Resolve-BwPanelName $idx ([string]$x)
    if (-not $p) { continue }
    $favOut += [PSCustomObject]@{ name = [string]$x; path = $p }
    $n++
  }

  $ver = ''; $lauVer = ''
  try { $ver = [string](Get-BwLocalScriptVer) } catch {}
  try { $lauVer = [string](Get-BwLauncherVer) } catch {}

  # 日志尾巴: 面板右下角"最近动作"
  # 2026-10-25(用户："日志框可以再往下拉"): 框现在按卡片剩余空间撑高(7~20 行),
  # 但服务端一次只给 6 条 —— 框撑高了里面却是空的。尾巴放到 40 条、滤掉空行后取最近 30 条
  # (全本机, 单条仍截 240 字, 最坏约 7KB), 框才真看得满; 面板本身不轮询, 请求只在打开/刷新时发生。
  $logTail = @()
  try {
    if (Test-Path -LiteralPath $global:BWLog) {
      $logRaw = @()
      foreach ($x in @(Get-Content -LiteralPath $global:BWLog -Tail 40 -Encoding UTF8)) {
        $s1 = ([string]$x).TrimEnd()
        if ($s1.Trim().Length -eq 0) { continue }   # 空行塞进面板就是几条白行，看着像框没填满
        if ($s1.Length -gt 240) { $s1 = $s1.Substring(0, 240) + '…' }
        $logRaw += $s1
      }
      if ($logRaw.Count -gt 30) { $logRaw = @($logRaw | Select-Object -Last 30) }
      $logTail = $logRaw
    }
  } catch {}

  # 桌面快捷方式的真实状态（配置说"开"不代表图标还在；用户可能自己删了/挪了）
  $deskOn = $true
  try { if ([string]$c.desktop_shortcut -eq 'off') { $deskOn = $false } } catch {}
  $deskPath = ''
  $deskExists = $false
  # 2026-10-24(面板轻量化): 配置里关掉桌面快捷方式时, 不必去探图标 —— Get-BwDeskInfo 要建
  # WScript.Shell COM(实测冷调一次约 190 ms), 每次状态请求都白花。关着的时候本来就显示"没有桌面图标"。
  if ($deskOn) {
    try {
      $di = Get-BwDeskInfo
      if ($di.path) { $deskPath = [string]$di.path }
      if ($deskPath -and (Test-Path -LiteralPath $deskPath)) { $deskExists = $true }
      else {
        $found = Find-BwDesktopLnk
        if ($found) { $deskPath = [string]$found; $deskExists = $true }
      }
    } catch {}
  }

  $autoOn = $false; $daemonOn = $false
  try { $autoOn = [bool](Test-BwAutoStart) } catch {}
  try { $daemonOn = [bool](Test-BwDaemonRunning) } catch {}
  $dlTotal = 0
  try { $dlTotal = [int]$s.dl_total } catch {}
  $strangers = 0
  try { $strangers = @($s.strangers | Where-Object { $_ }).Count } catch {}

  $poolLine = ''; $poolMode = ''
  try { $ps1 = Get-BwSourcePoolStatus $s; $poolLine = [string]$ps1.Line; $poolMode = [string]$ps1.Mode } catch {}
  # 2026-10-24: 面板上的「显示器」只显示主屏(多屏这一步不做), 分辨率当场量一次
  $scrW = 0; $scrH = 0
  try { $scr = Get-BwScreenSize; $scrW = [int]$scr.W; $scrH = [int]$scr.H } catch { $scrW = 0; $scrH = 0 }
  # 本地文件夹图源(没设置就是空目录 + 0 张)
  $localDir = ''; $localCount = 0
  try { $localDir = Get-BwLocalDir $c; if ($idx) { $localCount = [int]$idx['Local'] } elseif ($localDir) { $localCount = @(Get-BwLocalFiles $c).Count } } catch { $localDir = ''; $localCount = 0 }
  # 2026-10-24: 张数直接用上面那份索引的统计, 不再对每个目录重列一遍
  $bingCount = 0; $spotCount = 0
  if ($idx) { $bingCount = [int]$idx['Bing']; $spotCount = [int]$idx['Spotlight'] }

  # 2026-10-25: 「还原我原来的填充方式」要在面板上有个入口, 所以把原值记录也回给页面。
  # 只回"有没有记录 + 一句人话", 注册表原值本身留在 config.json 里不外传。
  $hasOrig = $false; $origTxt = ''
  try { $oOrig = Get-BwStyleOrig; if ($oOrig) { $hasOrig = $true; $origTxt = Format-BwStyleOrig $oOrig } } catch {}

  return [ordered]@{
    ok          = $true
    scriptVer   = $ver
    launcherVer = $lauVer
    dataDir     = [string]$global:BWRoot
    dirs        = [ordered]@{
      base      = [string](Split-Path ([string]$c.bing_save_dir) -Parent)
      bing      = [string]$c.bing_save_dir
      spotlight = [string]$c.spotlight_save_dir
    }
    cfg         = $cfg
    style       = [ordered]@{ hasOrig = $hasOrig; orig = $origTxt }
    st          = [ordered]@{
      lastWall = $lastWall
      lastSwap = $lastSwap
      queue    = $queueCount
      shown    = $shown
    }
    history     = $histOut
    favorites   = $favOut
    favCount    = @($favs).Count
    pool        = [ordered]@{ line = $poolLine; mode = $poolMode }
    screen      = [ordered]@{ w = $scrW; h = $scrH }
    local       = [ordered]@{ dir = $localDir; count = $localCount }
    auto        = [ordered]@{ startup = $autoOn; daemon = $daemonOn; dlTotal = $dlTotal; strangers = $strangers }
    desktop     = [ordered]@{ on = $deskOn; exists = $deskExists; path = $deskPath }
    counts      = [ordered]@{ bing = $bingCount; spotlight = $spotCount }
    log         = $logTail
  }
}

# 面板能改的只有白名单里的项; 数值一律过 Limit-BwNum 的护栏(手填 1 亿分钟那种也能夹回来)。
function Invoke-BwPanelSet([string]$key, $value) {
  $c = Get-BwConfig
  $key = [string]$key
  $numKeys = @('cycle_minutes','lib_cap','bing_cap','spotlight_per_cycle','fetch_round_cap',
               'fetch_day_cap','recycle_min_days','src_timeout_sec')
  if ($numKeys -contains $key) {
    $n = Limit-BwNum $value $key
    # 2026-10-23 用户要求：「必应模式下其他时间段应该锁死」。
    # 光把界面控件 disable 不够 —— 旧标签页 / 手工调接口都能绕过，所以服务端也钉住：
    # 必应模式期间 cycle_minutes 只能等于 24 小时。
    if ($key -eq 'cycle_minutes' -and [bool]$c.bing_only -and $n -ne 1440) {
      Log ('面板: 必应模式期间不接受把间隔改成 ' + $n + ' 分钟, 已钉住 24 小时')
      $n = 1440
    }
    $c | Add-Member -NotePropertyName $key -NotePropertyValue $n -Force
  } elseif ($key -eq 'auto_fetch' -or $key -eq 'fav_only' -or $key -eq 'bing_only') {
    # 注意: [bool]"false" 在 PowerShell 里是 $true(非空字符串), 直接转会把开关"关不掉"。
    # 面板传来的都是字符串, 必须按白名单判。
    $b = $false
    if ($value -is [bool]) {
      $b = [bool]$value
    } else {
      $s2 = ([string]$value).Trim().ToLower()
      if ($s2 -notin @('false', '0', 'off', 'no', '关', '')) { $b = $true }
    }
    $c | Add-Member -NotePropertyName $key -NotePropertyValue $b -Force
  } elseif ($key -eq 'resolution_mode') {
    $v = ([string]$value).Trim().ToLower()
    if (@('auto','uhd') -notcontains $v) { throw ('画质档不支持: ' + $v) }
    $c | Add-Member -NotePropertyName $key -NotePropertyValue $v -Force
  } elseif ($key -eq 'wallpaper_style') {
    $v = ([string]$value).Trim().ToLower()
    if (@('fill','fit','stretch','center','tile','span','keep') -notcontains $v) { throw ('填充方式不支持: ' + $v) }
    $c | Add-Member -NotePropertyName $key -NotePropertyValue $v -Force
  } elseif ($key -eq 'art_fit_mode' -or $key -eq 'desktop_shortcut') {
    $v = ([string]$value).Trim().ToLower()
    if (@('on','off') -notcontains $v) { throw ('这个开关只接受 on / off: ' + $v) }
    $c | Add-Member -NotePropertyName $key -NotePropertyValue $v -Force
  } elseif ($key -eq 'panel_theme' -or $key -eq 'panel_accent') {
    # 2026-10-25: 面板观感落到 config.json(替代 localStorage, 见 Get-BwConfig 那段说明)。
    # 这两个值最终会被塞进 HTML, 所以**只认死名单**, 别的写法一律拒绝。
    $v = ([string]$value).Trim().ToLower()
    $ok = if ($key -eq 'panel_theme') { @('auto','light','dark') } else { @('default','blue','green','violet','amber') }
    if ($ok -notcontains $v) { throw ($key + ' 只接受 ' + ($ok -join ' / ') + ': ' + $v) }
    $c | Add-Member -NotePropertyName $key -NotePropertyValue $v -Force
  } elseif ($key -eq 'local_src_dir') {
    # 2026-10-24: 本地文件夹图源。空串 = 关掉这个图源(文件一张都不会动)。
    $v = ([string]$value).Trim()
    if ($v) {
      $v = $v.TrimEnd('\')
      $isDir = $false
      try { $isDir = [bool](Test-Path -LiteralPath $v -PathType Container) } catch { $isDir = $false }
      if (-not $isDir) { throw ('这个文件夹不存在或不是文件夹: ' + $v) }
    }
    $c | Add-Member -NotePropertyName $key -NotePropertyValue $v -Force
  } else {
    throw ('不支持的设置项: ' + $key)
  }
  Save-BwConfig $c
  Log ('面板: 设置 ' + $key + ' -> ' + [string]$value)
  # 设完本地图源顺手扫一遍: 不然要等下一轮"队列重洗"才轮得到这些图(可能等一天)。
  if ($key -eq 'local_src_dir') {
    $ln = Add-BwLocalToQueue
    if ([string]$c.local_src_dir) { Log ('面板: 本地图源 -> ' + [string]$c.local_src_dir + ', 扫到 ' + $ln + ' 张进了轮换队列') }
    else { Log '面板: 本地图源已关闭' }
  }
  # 桌面快捷方式这一项光改配置不够: 要真去桌面建/删那个图标
  if ($key -eq 'desktop_shortcut') {
    if (([string]$c.desktop_shortcut).ToLower() -eq 'off') {
      [void](Remove-BwDesktopShortcut)
    } else {
      # 主动打开 = 强制重建（绕过"用户删过就不再建"的保护）
      [void](New-BwDesktopShortcutForce)
    }
  }
  # 必应模式一打开就立刻换成"今天这张": 用户在面板上开它, 期待的是当场看到今天的图,
  # 而不是等到下一个轮换周期(最多 30 分钟)才动。用独立进程跑, 不占住面板的请求。
  if ($key -eq 'bing_only') {
    # 2026-10-23 用户要求：「必应模式以后，更换节奏应该变成 24 小时」。
    # 必应模式本来就一天一张，间隔再留着 30 分钟会自相矛盾（界面上还会显示"约 30 分钟后换"）。
    # 进必应 -> 固定 1440 分钟；退出必应 -> 还原进之前的值（缺省 30）。
    if ([bool]$c.bing_only) {
      $prev = 30
      try { if ($c.PSObject.Properties['cycle_minutes']) { $prev = [int]$c.cycle_minutes } } catch {}
      if ($prev -ne 1440) {
        $c | Add-Member -NotePropertyName cycle_before_bing -NotePropertyValue $prev -Force
      }
      $c | Add-Member -NotePropertyName cycle_minutes -NotePropertyValue 1440 -Force
      Log '面板: 必应模式开启 -> 更换节奏固定 24 小时'
    } else {
      $restore = 30
      try {
        if ($c.PSObject.Properties['cycle_before_bing']) {
          $r = [int]$c.cycle_before_bing
          if ($r -ge 5 -and $r -le 1440) { $restore = $r }
        }
      } catch {}
      $c | Add-Member -NotePropertyName cycle_minutes -NotePropertyValue $restore -Force
      Log ('面板: 必应模式关闭 -> 更换节奏还原为 ' + $restore + ' 分钟')
    }
    # 注意：Save-BwConfig 在这段之前已经执行过了（在开关解析之后），
    # 所以这里改的 cycle_minutes 必须再存一次盘，否则只改了内存、下次读回来还是旧值。
    Save-BwConfig $c
    $jobName = 'normalnow'
    if ([bool]$c.bing_only) { $jobName = 'bingnow' }
    try {
      $coreFile = Join-Path $global:BWRoot 'core.ps1'
      Start-Process 'powershell.exe' -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $coreFile),'-PanelJob',$jobName
      ) -WindowStyle Hidden | Out-Null
      if ($jobName -eq 'bingnow') { Log '面板: 必应模式已开, 正在切成今天的必应图' }
      else { Log '面板: 必应模式已关, 正在恢复默认轮换' }
    } catch {}
  }
  return $true
}

# 2026-10-23 用户报:「打开数据目录, 怎么是网页背后跳出」。
# 原因: 面板的服务进程是隐藏窗口的后台 PowerShell, 它起的资源管理器窗口没有前台权,
# 于是常常在浏览器**后面**开出来 —— 用户看不到, 以为"点了没反应"。
# 做法: 打开目录之后主动把新冒出来的窗口激活到最前(按窗口标题试, 提不到就按目录名再试),
# 最多等 2 秒; 提窗口失败也不影响"目录已经打开"这件事。
function Open-BwFolderFront([string]$path) {
  # 2026-10-24 用户要求：打开文件夹必须"弹出来"、居中、置前。
  # Windows 把全部文件夹窗口放在同一个 explorer.exe 里，进程级 MainWindowHandle 看不到它们，
  # 必须用 EnumWindows 按窗口类(CabinetWClass)枚举，才能真正找到并提到前台。
  if (-not $path) { return $false }
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  $leaf = ''
  try { $leaf = [string](Split-Path $path -Leaf) } catch {}
  if (-not ('BwFolderWin' -as [type])) {
    try {
      Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class BwFolderWin {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr h, bool alt);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  public static List<IntPtr> Folders(string needle) {
    var list = new List<IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (!IsWindowVisible(h)) return true;
      var cn = new StringBuilder(128); GetClassName(h, cn, 128);
      string cls = cn.ToString();
      if (cls != "CabinetWClass" && cls != "ExploreWClass") return true;
      var sb = new StringBuilder(512); GetWindowText(h, sb, 512);
      string t = sb.ToString();
      if (needle == null || needle.Length == 0 || t.IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0) list.Add(h);
      return true;
    }, IntPtr.Zero);
    return list;
  }
  public static void Bring(IntPtr h, int x, int y, int w, int hh, bool center) {
    if (h == IntPtr.Zero) return;
    uint pid; IntPtr fg = GetForegroundWindow();
    uint fgT = GetWindowThreadProcessId(fg, out pid);
    uint me = GetCurrentThreadId();
    AttachThreadInput(me, fgT, true);
    // 先最小化再还原：这是让后台进程"抢到前台"的常用办法
    ShowWindow(h, 6);
    ShowWindow(h, 9);
    if (center && w > 200 && hh > 200) { MoveWindow(h, x, y, w, hh, true); }
    // 顶置切换一次，把窗口从"被浏览器压住"的层拉上来
    SetWindowPos(h, (IntPtr)(-1), 0, 0, 0, 0, 0x0003);
    SetWindowPos(h, (IntPtr)(-2), 0, 0, 0, 0, 0x0003);
    SwitchToThisWindow(h, true);
    SetForegroundWindow(h);
    AttachThreadInput(me, fgT, false);
  }
  public static bool Close(IntPtr h) {
    return PostClose(h);
  }
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  static bool PostClose(IntPtr h) { return PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero); }
}
"@ -ErrorAction Stop
    } catch { try { Log ("openDir: Add-Type 失败: " + $_.Exception.Message) "WARN" } catch {}; return $true }
  }
  $wx = 0; $wy = 0; $ww = 1000; $wh = 700
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if ($wa) {
      $ww = [int][Math]::Min(1100, [Math]::Max(720, $wa.Width * 0.62))
      $wh = [int][Math]::Min(820, [Math]::Max(460, $wa.Height * 0.72))
      $wx = [int]($wa.X + ($wa.Width - $ww) / 2)
      $wy = [int]($wa.Y + ($wa.Height - $wh) / 2)
    }
  } catch {}
  $before = New-Object System.Collections.Generic.HashSet[Int64]
  try { foreach ($h in [BwFolderWin]::Folders('')) { [void]$before.Add($h.ToInt64()) } } catch {}
  try { Start-Process 'explorer.exe' -ArgumentList ('"{0}"' -f $path) | Out-Null } catch { try { Log ('openDir: explorer 启动失败: ' + $_.Exception.Message) 'WARN' } catch {} }
  for ($i = 1; $i -le 16; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $found = $null
      # 先找标题带目录名的（新建/复用都算）
      if ($leaf) {
        foreach ($h in [BwFolderWin]::Folders($leaf)) { $found = $h; break }
      }
      # 再找这次新冒出来的窗口
      if (-not $found) {
        foreach ($h in [BwFolderWin]::Folders('')) {
          if (-not $before.Contains($h.ToInt64())) { $found = $h; break }
        }
      }
      if ($found) {
        [BwFolderWin]::Bring($found, $wx, $wy, $ww, $wh, $true)
        try { Log ("面板: 已打开并置前 -> " + $path) } catch {}
        return $true
      }
    } catch {}
  }
  return $true
}

function Invoke-BwPanelAction($req) {
  $do = ''
  try { $do = ([string]$req.do).Trim().ToLower() } catch {}
  # 2026-10-24: 写操作后立刻失效面板的只读缓存（状态/索引/图库），避免点到旧数据。
  if (($do -ne '') -and ($do -ne 'state')) {
    $global:BwPanelStateCache = ''
    $global:BwPanelIdxCache = $null
    $global:BwPanelGalleryCache = @{}
  }
  if (($do -eq '') -or ($do -eq 'state')) { return (Get-BwPanelState) }

  if ($do -eq 'swap') {
    $s = Get-BwState
    $ok = Invoke-BwSwap $s (Get-Date) '面板: 立即换一张'
    Save-BwStateKeepFav $s
    $st = Get-BwPanelState
    $st['ok'] = [bool]$ok
    if (-not $ok) { $st['error'] = '这一轮没换成（库里暂时没有可换的图），稍后再点一次' }
    return $st
  }

  if ($do -eq 'set') {
    $k = [string]$req.key
    [void](Invoke-BwPanelSet $k $req.value)
    $st = Get-BwPanelState
    $st['ok'] = $true
    if ($k -eq 'desktop_shortcut') {
      $d = $st['desktop']
      if ($d -and $d['exists']) {
        $st['note'] = '桌面图标已就位：' + [string]$d['path']
      } elseif (([string]$req.value).ToLower() -eq 'off') {
        $st['note'] = '桌面图标已删除'
      } else {
        $st['note'] = '没建成功：找不到主程序（launcher.txt）或桌面没有写权限'
      }
    }
    return $st
  }

  # 2026-10-25 补入口: Restore-BwStyleOrig 一直是"备份留了、还原按钮没接上"(体检第 3 条)。
  # 菜单里有这条路, 面板上没有 —— 只会用网页的人样式改坏了只能删数据目录重来。
  # 真正写注册表的是 Restore-BwStyleOrig 自己: 它把原值写回去、再把设置里那一档对齐
  # (认得出是程序那几档就跟着那档, 认不出就设成 keep, 以后换图一个字节都不动)。
  if ($do -eq 'restore_style') {
    $r = Restore-BwStyleOrig
    $st = Get-BwPanelState
    $st['ok'] = [bool]$r.Ok
    $st['note'] = [string]$r.Msg
    if (-not $r.Ok) { $st['error'] = [string]$r.Msg }
    return $st
  }

  if (($do -eq 'fav') -or ($do -eq 'unfav')) {
    $s = Get-BwState
    $nm = ''
    try { if ($req.name) { $nm = [string]$req.name } } catch {}
    if (-not $nm) {
      try { if ($s.last_wall) { $nm = Split-Path ([string]$s.last_wall) -Leaf } } catch {}
    }
    if (-not $nm) { throw '不知道该收藏哪一张' }
    $favs = @()
    try { $favs = @($s.favorites | Where-Object { $_ }) } catch { $favs = @() }
    if ($do -eq 'fav') {
      if ($favs -notcontains $nm) { $favs += $nm }
      Log ('面板: 收藏 ' + $nm)
    } else {
      $favs = @($favs | Where-Object { $_ -ne $nm })
      Log ('面板: 取消收藏 ' + $nm)
    }
    $s.favorites = $favs
    # 刚改过 favorites -> 只能用 Save-BwState。KeepFav 以**磁盘上**的 favorites 为准,
    # 在这里用等于把用户刚点的收藏立刻抹掉(menu.ps1 里同样的注释, 2026-09-22 踩过)。
    Save-BwState $s
    $st = Get-BwPanelState
    $st['ok'] = $true
    return $st
  }

  if ($do -eq 'use') {
    $nm = [string]$req.name
    $p = Get-BwPanelResolve $nm
    if (-not $p) { throw '这张图找不到了（可能已被自动清理）' }
    $ok = Set-BwWall $p
    $s = Get-BwState
    $s.last_wall = $p
    $s.last_swap = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Add-BwHist $s $nm
    Save-BwStateKeepFav $s
    Log ('面板: 手动设为壁纸 ' + $nm + ' (ok=' + $ok + ')')
    $st = Get-BwPanelState
    $st['ok'] = [bool]$ok
    return $st
  }

  if ($do -eq 'update') {
    $changed = $false
    try { $changed = [bool](Invoke-BwScriptUpdate -Quiet -Force) } catch {}
    $st = Get-BwPanelState
    $st['ok'] = $true
    $st['updated'] = $changed
    return $st
  }

  if ($do -eq 'list') {
    $src = 'bing'
    try { if ($req.name) { $src = ([string]$req.name).ToLower() } } catch {}
    $c = Get-BwConfig
    $dir = [string]$c.bing_save_dir
    if ($src -eq 'spotlight') { $dir = [string]$c.spotlight_save_dir }
    $files = @()
    try {
      $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                 Where-Object { Test-BwImgFile $_.Name } | Sort-Object Name -Descending)
    } catch {}
    $skip = 0
    try { if ($req.value) { $skip = [int]([string]$req.value) } } catch { $skip = 0 }
    $out = @()
    $i = 0
    foreach ($f in $files) {
      if ($i -lt $skip) { $i++; continue }
      $out += [PSCustomObject]@{ name = $f.Name; path = $f.FullName }
      if ($out.Count -ge 60) { break }
      $i++
    }
    return [ordered]@{ ok = $true; src = $src; dir = $dir; total = $files.Count; skip = $skip; items = $out }
  }

  if ($do -eq 'job') {
    $name = 'refill'
    $arg = ''
    try { if ($req.name) { $name = ([string]$req.name).ToLower() } } catch {}
    try { if ($req.value) { $arg = [string]$req.value } } catch {}
    $okNames = @('refill','backfill','archive','resetpool','setbase','update','bingnow','normalnow')
    if ($okNames -notcontains $name) { throw ('不支持的任务: ' + $name) }
    if (($name -eq 'archive') -and ($arg -notmatch '^\d{4}-\d{2}$')) { throw '年月要写成 2024-08 这样' }
    if (($name -eq 'setbase') -and (-not $arg)) { throw '要指定一个目标目录' }
    $coreFile = Join-Path $global:BWRoot 'core.ps1'
    $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $coreFile),
                '-PanelJob',$name)
    if ($arg) { $psArgs += @('-PanelJobArg', ('"{0}"' -f $arg)) }
    $p = Start-Process 'powershell.exe' -ArgumentList $psArgs -WindowStyle Hidden -PassThru
    Log ('面板: 已起后台任务 ' + $name + ' ' + $arg + ' (PID ' + $p.Id + ')')
    $st = Get-BwPanelState
    $st['ok'] = $true
    $st['job'] = $name
    return $st
  }

  if ($do -eq 'localscan') {
    # 2026-10-24: 本地文件夹图源——重新扫一遍目录, 把新丢进去的图排进队列
    $n = 0
    try { $n = Add-BwLocalToQueue } catch { $n = 0 }
    $st = Get-BwPanelState
    $st['ok'] = $true
    $st['added'] = $n
    return $st
  }

  if ($do -eq 'quit') { return [ordered]@{ ok = $true } }

  if ($do -eq 'autostart') {
    # 三件事: 开(建启动项+立刻拉后台) / 关(删启动项+让后台收工) / 已开着但后台没跑就只拉后台
    $want = 'on'
    try { if ($req.value) { $want = ([string]$req.value).Trim().ToLower() } } catch {}
    $cur = $false
    try { $cur = [bool](Test-BwAutoStart) } catch {}
    $daemon = $false
    try { $daemon = [bool](Test-BwDaemonRunning) } catch {}
    $ok = $true
    $note = ''
    if ($want -eq 'off') {
      if ($cur) { try { [void](Disable-BwAutoStart) } catch { $ok = $false } }
      $note = '已关闭开机自动换'
    } else {
      if (-not $cur) {
        try { $ok = [bool](Enable-BwAutoStart) } catch { $ok = $false }
        if ($ok) { $note = '已开启，下次登录起会自动换' } else { $note = '没开成：找不到主程序（launcher.txt），请直接双击 exe 再试' }
      } elseif (-not $daemon) {
        try { $ok = [bool](Start-BwDaemonNow (Get-BwLauncherPath)) } catch { $ok = $false }
        $note = '启动项本来就是开的，已把后台现在拉起来'
      } else {
        $note = '本来就是开着的'
      }
    }
    Log ('面板: 开机自动换 -> ' + $want + ' (ok=' + $ok + '; ' + $note + ')')
    $st = Get-BwPanelState
    $st['ok'] = [bool]$ok
    $st['note'] = $note
    return $st
  }

  if ($do -eq 'openDir') {
    $c = Get-BwConfig
    $which = 'base'
    try { if ($req.name) { $which = [string]$req.name } } catch {}
    $p = [string]$c.bing_save_dir
    if ($which -eq 'spotlight') { $p = [string]$c.spotlight_save_dir }
    elseif ($which -eq 'local') { $p = Get-BwLocalDir $c }
    elseif ($which -eq 'data') { $p = [string]$global:BWRoot }
    # 2026-10-24 用户要求：本地源没启用时不要拦着，直接退回到程序默认的壁纸库根目录
    if (-not $p -or -not (Test-Path -LiteralPath $p)) {
      $fallback = ''
      try { $fallback = [string](Split-Path ([string]$c.bing_save_dir) -Parent) } catch {}
      if (-not $fallback -or -not (Test-Path -LiteralPath $fallback)) { $fallback = [string]$global:BWRoot }
      if ($fallback -and (Test-Path -LiteralPath $fallback)) {
        Log ('面板: openDir name=' + $which + ' 没有自己的目录，退回到默认库 -> ' + $fallback)
        $p = $fallback
      } else {
        Log ('面板: openDir 连默认库都找不到 name=' + $which) 'WARN'
        return [ordered]@{ ok = $false; error = '找不到可打开的目录（默认库也不存在）'; path = $p }
      }
    }
    # 2026-10-23: 打开后把窗口提到最前 —— 不然它总在浏览器后面出来, 看着像没反应
    [void](Open-BwFolderFront $p)
    return [ordered]@{ ok = $true; path = $p }
  }

  throw ('未知操作: ' + $do)
}

# 立刻把壁纸换成"今天这一张"必应图（只给必应模式用）。
# 为什么要单独一个函数: 原来的"每天第一次 -> 必应当日图"只在后台轮换跑到时才执行,
# 用户刚把必应模式打开的那一下不会动 —— 看起来像"点了没反应"。
# 这里刻意不走 Invoke-BwCycle: 那个会顺手补漏、抓聚焦, 而必应模式只要一张当天的图。
function Invoke-BwPanelBingNow {
  $c = Get-BwConfig
  $s = Get-BwState
  $meta = $null
  for ($i = 1; $i -le 3; $i++) {
    $meta = Get-BwMeta 0
    if ($meta) { break }
    Start-Sleep -Seconds 5
  }
  if (-not $meta) {
    Log '面板: 切必应当日图失败(取不到元数据), 后台下一轮会再试'
    return $false
  }
  $bday = Get-BwDisplayDate $meta
  $name = Get-BwName $meta
  $path = Get-BwTargetPath $bday $name
  $dir = Split-Path $path -Parent
  [void](New-BwDir $dir)
  if (-not (Test-Path -LiteralPath $path)) {
    $m = @{ date = $bday; title = $meta.title
            copyright = ($meta.copyright -replace '\s*[(（]©.*$', '')
            source_type = '必应'; source_url = ('https://cn.bing.com' + $meta.urlbase)
            source_link = 'https://www.bing.com' }
    if (-not (Save-BwFile (Get-BwCandidates $meta ($c.resolution_mode)) $path $m)) { $path = $null }
  }
  if (-not $path) {
    Log '面板: 必应当日图下载失败, 后台下一轮会再试'
    return $false
  }
  $ok = Set-BwWall $path
  $s.last_wall = $path
  $s.last_bing_date = (Get-Date).ToString('yyyy-MM-dd')
  $s.last_swap = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  Add-BwHist $s $name
  Save-BwStateKeepFav $s
  Log ('面板: 已切到必应当日图 ' + $name + ' (ok=' + $ok + ')')
  return [bool]$ok
}

# 关掉必应模式后立刻回到"默认模式": 按队列换一张普通壁纸。
# 不开这个的话, 关掉开关只是把配置改了, 桌面还停在今天那张必应图上,
# 要等下一个轮换周期(最多 30 分钟)才动 —— 用户会觉得"关了没反应"。
function Invoke-BwPanelNormalNow {
  $s = Get-BwState
  $ok = Invoke-BwSwap $s (Get-Date) '面板: 关闭必应模式, 恢复默认轮换'
  Save-BwStateKeepFav $s
  if (-not $ok) {
    Log '面板: 恢复默认轮换时没换成图(队列可能是空的), 后台下一轮会补; 也可以点「补几张新图」'
  } else {
    Log '面板: 已关闭必应模式, 并已按默认轮换换了一张'
  }
  return [bool]$ok
}

# ---- 后台任务 ----
# 补货 / 补漏 / 整月补齐 / 重置源池 / 迁移库 都可能跑几分钟到几十分钟, 绝不能占住
# 本地服务的请求线程(占住了面板就"转圈"), 所以一律起独立进程跑, 进度看 wallpaper.log。
function Invoke-BwPanelRefill {
  $null = Ensure-BwDirs
  $c = Get-BwConfig
  $s = Get-BwState
  $want = 6
  try { $want = [int]$c.spotlight_per_cycle } catch { $want = 6 }
  if ($want -gt 50) { $want = 50 }
  Log ('面板任务: 开始补货, 本轮最多 ' + $want + ' 张')
  $new = @(Invoke-SpotlightFetch -count $want -Quiet -Counter)
  if ($new.Count -gt 0) {
    # 队列里存文件名; 存完整路径会让取图时拼成 "库\F:\库\xxx.jpg", 张张找不到。
    # 2026-10-23: 以前接在**队尾**(等于今天看不到), 改成插到队列前 1/3。
    $names = @($new | ForEach-Object { Split-Path $_ -Leaf })
    [void](Add-BwNewToQueue $s $names)
    Save-BwStateKeepFav $s
  }
  Log ('面板任务: 补货结束, 新下载 ' + $new.Count + ' 张')
}

function Invoke-BwPanelSetBase([string]$target) {
  if (-not $target) { Log '面板任务: 没给目标目录, 放弃'; return }
  $target = $target.Trim().TrimEnd('\')
  if (-not (Test-BwWritable $target)) { Log ('面板任务: 目标写不进去 -> ' + $target); return }
  $c = Get-BwConfig
  $oldBase = ''
  try { $oldBase = [string](Split-Path ([string]$c.bing_save_dir) -Parent) } catch {}
  if ($oldBase -and ($oldBase.TrimEnd('\').ToUpper() -ne $target.ToUpper())) {
    Log ('面板任务: 开始迁移库 ' + $oldBase + ' -> ' + $target)
    $n = Move-BwLibraryFiles $oldBase $target
    Log ('面板任务: 已搬 ' + $n + ' 张图')
  }
  $c.bing_save_dir = Join-Path $target '必应'
  $c.spotlight_save_dir = Join-Path $target '聚焦'
  Save-BwConfig $c
  [void](Ensure-BwDirs)
  Log ('面板任务: 保存位置已改成 ' + $target)
}

if ($PanelJob) {
  $jm = ([string]$PanelJob).Trim().ToLower()
  Log ('面板任务开始: ' + $jm + ' ' + [string]$PanelJobArg)
  try {
    if ($jm -eq 'refill') { Invoke-BwPanelRefill }
    elseif ($jm -eq 'backfill') { Invoke-BwBackfill (Get-BwState) }
    elseif ($jm -eq 'archive') { Invoke-BwArchiveBatch ([string]$PanelJobArg) }
    elseif ($jm -eq 'resetpool') { $r = Reset-BwSourceRecords; Log ('面板任务: ' + [string]$r) }
    elseif ($jm -eq 'setbase') { Invoke-BwPanelSetBase ([string]$PanelJobArg) }
    elseif ($jm -eq 'update') { [void](Invoke-BwScriptUpdate -Quiet -Force) }
    elseif ($jm -eq 'bingnow') { [void](Invoke-BwPanelBingNow) }
    elseif ($jm -eq 'normalnow') { [void](Invoke-BwPanelNormalNow) }
    else { Log ('面板任务: 不认识的任务 ' + $jm) 'WARN' }
    Log ('面板任务完成: ' + $jm)
  } catch {
    Log ('面板任务失败: ' + $jm + ' :: ' + $_.Exception.Message) 'ERROR'
  }
  exit 0
}

# 入口: -PanelExport 释放面板文件; -PanelReq 处理一次接口请求。
if ($PanelExport) {
  $ok = Write-BwPanelHtml $PanelExport
  exit ([int](-not $ok))
}
if ($PanelReq) {
  $res = $null
  try {
    $req = $null
    if (Test-Path -LiteralPath $PanelReq) {
      $raw = [System.IO.File]::ReadAllText($PanelReq, [System.Text.Encoding]::UTF8)
      if ($raw) { $req = $raw | ConvertFrom-Json }
    }
    if (-not $req) { throw '请求文件是空的' }
    $res = Invoke-BwPanelAction $req
  } catch {
    $res = [ordered]@{ ok = $false; error = $_.Exception.Message }
  }
  if ($PanelOut) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    try {
      $json = ConvertTo-BwPanelJson $res
      [System.IO.File]::WriteAllText($PanelOut, $json, $enc)
    } catch {
      $err = (@{ ok = $false; error = ('写结果失败: ' + $_.Exception.Message) } | ConvertTo-Json)
      try { [System.IO.File]::WriteAllText($PanelOut, $err, $enc) } catch {}
    }
  }
  exit 0
}

# 注意: -Update 与 -Cycle 走同一套逻辑。
# 老版本的开机自启动作是 -Update; 让 -Update 也进新节奏, 老用户不用重装就能零提权生效。
if ($Cycle -or $Update) { Invoke-BwCycle }
