# 桌面壁纸 - 核心库
# 作者: 海风（kele551）   https://gitee.com/kele551/ms-wallpaper-assistant
# 协作: Cindy（只在源码里留档，不出现在界面上）
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
  # 0 = 不限(老样子, 只增不减)。
  # 2026-10-09 用户要求: 默认从 100 上调到 200。理由 —— 聚焦源池总共就 800+ 张、官方每天
  # 只新增有限几张, 库越大、同样的图轮到第二次的间隔就越长(库 200 张 + 30 分钟一轮 ≈ 4 天才
  # 轮一遍)。**只改新装的默认值**: 已经有 config.json 的用户保持他自己那份, 不覆盖。
  if (-not $c.PSObject.Properties['lib_cap']) { Add-Member -InputObject $c NoteProperty lib_cap 200 -Force }
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
  if (-not $c.PSObject.Properties['art_fit_mode']) { Add-Member -InputObject $c NoteProperty art_fit_mode 'on' -Force }
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
  $tmp = $path + '.tmp'
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
  'https://gitee.com/kele551/ms-wallpaper-assistant/raw/main/version.json',
  'https://raw.githubusercontent.com/kele551/ms-wallpaper-assistant/main/version.json'
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
# 升级请求一律直连(不绕本机代理: 本机代理可能正是狐径, 而 Gitee 本来就直连更快)
function Get-BwBytes([string]$url, [int]$timeoutSec = 20) {
  for ($try = 1; $try -le 3; $try++) {
    try {
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      $wc = New-Object System.Net.WebClient
      $wc.Headers.Add('User-Agent', 'MSWallpaperAssistant')
      $wc.Proxy = $null
      return $wc.DownloadData($url)
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
function Get-BwUpdateInfo {
  param([switch]$Force, [switch]$Offline)
  if (-not $Force -and (Test-Path -LiteralPath $global:BWUpdateFile)) {
    try {
      $c = Get-Content -LiteralPath $global:BWUpdateFile -Raw -Encoding UTF8 | ConvertFrom-Json
      $age = (Get-Date) - ([datetime]::FromFileTime([int64]$c.checked_ft))
      if ($age.TotalHours -lt 6) { return $c }
      if ($Offline) { return $c }
    } catch {}
  } elseif ($Offline) { return $null }
  $urls = @()
  $cfgUrl = ''
  try { if ($global:BWDefaults) { $cfgUrl = '' } } catch {}
  try { $cfgUrl = [string](Get-BwConfig).update_url } catch {}
  if ($cfgUrl) { $urls += $cfgUrl } else { $urls += $global:BWUpdateUrls }
  foreach ($u in $urls) {
    $raw = ''
    if ($u -match '^(https?)://') { $raw = Get-BwText $u }
    elseif (Test-Path -LiteralPath $u) { try { $raw = Get-Content -LiteralPath $u -Raw -Encoding UTF8 } catch { $raw = '' } }
    if (-not $raw) { continue }
    try {
      $j = $raw | ConvertFrom-Json
      if (-not $j.version) { continue }
      $j | Add-Member -NotePropertyName checked_ft -NotePropertyValue ((Get-Date).ToFileTime()) -Force
      $j | Add-Member -NotePropertyName source -NotePropertyValue $u -Force
      # 2026-10-09 (审查 H-7): 缓存也走原子写 —— 它被写坏只是白查一次,
      # 但既然有现成的原子写, 就没必要留一个"半截 JSON"在数据目录里。
      [void](Save-BwJsonAtomic $global:BWUpdateFile $j)
      return $j
    } catch { continue }
  }
  return $null
}
# 执行升级: 只换脚本。返回 $true 表示脚本已经换成新的。
# ---- 主程序(exe)自动覆盖升级 ----
# 用户 2026-09-22 明确要求:「自动升级, 自动覆盖」。
# 正在运行的 exe 不能直接覆盖, 所以走这套: 自己先停 -> 小助手接管 -> 覆盖 -> 重新启动。
#   1) 新 exe 先下到 <目录>\微软壁纸助手.exe.new 并校验 SHA256(对不上立刻放弃);
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
    if (-not $url) { $url = 'https://gitee.com/kele551/ms-wallpaper-assistant/raw/main/' + $nm }
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
  foreach ($it in $plan) {
    $dst = Join-Path $global:BWRoot $it.Name
    $bak = $dst + '.bak'
    try { if (Test-Path -LiteralPath $dst) { Copy-Item -LiteralPath $dst -Destination $bak -Force } } catch {}
    try {
      [System.IO.File]::WriteAllBytes($dst, $it.Bytes)
      Log ('升级: ' + $it.Name + ' 已更新 (' + $it.Bytes.Length + ' 字节, sha256=' + $it.Sha.Substring(0,16) + ')')
    } catch {
      Log ('升级失败: 写 ' + $it.Name + ' 出错: ' + $_.Exception.Message)
      if (-not $Quiet) { Write-Host ('  写 ' + $it.Name + ' 失败: ' + $_.Exception.Message) -ForegroundColor Red }
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
  $tmp = $global:BWState + '.tmp'
  # 留档名要保证唯一: 同一秒里损坏两次(测试里就是这么撞上的)时, 重名会让
  # File.Move 直接失败 —— 那就等于"证据留不下来", 跟静默重置一样糟。
  $baseKeep = $global:BWState + '.corrupt-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
  $keep = $baseKeep
  $kn = 1
  while (Test-Path -LiteralPath $keep) { $kn++; $keep = $baseKeep + '-' + $kn }
  $obj = $null
  # 1) 先看原子写留下的临时文件: 写入被打断时, 完整的新内容往往就在它里面
  if (Test-Path -LiteralPath $tmp) {
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
  if ($cur -and ($cur -eq $target)) { return $true }
  return (Set-BwDesktopWallpaper $target)
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
# ---- 与既有机制的接合点 ----
# 队列里只存文件名, 图可能在四个库里的任何一个: 按文件名挨个找。
function Find-BwWallFile([psobject]$c, [string]$name) {
  if (-not ($c -and $name)) { return '' }
  $dirs = @([string]$c.spotlight_save_dir, [string]$c.bing_save_dir)
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
# (必应库不进队列: 它按"每日一图"的节奏走, 见 Invoke-BwCycle 规则 1。)
function Get-BwRotPool {
  $c = Get-BwConfig
  $out = @(Get-BwSpotlightAll)
  foreach ($def in @(Get-BwSourceDefs)) {
    if (-not (Get-BwSrcEnabled $c $def.Key)) { continue }
    $out += @(Get-BwSrcFiles (Get-BwSrcDir $c $def.Key))
  }
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
      Log ('重洗队列: 库里 ' + $names.Count + ' 张, 看过 ' + ($names.Count - $fresh.Count) + ' 张 -> 这一轮只排没看过的 ' + $fresh.Count + ' 张')
      $names = $fresh
    } else {
      # 未看过的不足 20 张 -> 进入"老图循环": 够久没出现过(>= recycle_min_days 天)的老图
      # 也排进来, 排在没看过的后面。官方每天新增的仍然插队, 所以不会一直吃老图。
      $now2 = Get-Date
      $minDays2 = Get-BwRecycleMinDays (Get-BwConfig)
      $oldPart = @($names | Where-Object {
        $kk = Get-BwNameKey $_
        $seen.ContainsKey($kk) -and (Test-BwOldImageReusable $s $kk $now2 $minDays2)
      })
      if ($oldPart.Count -gt 0) {
        $recycleMode = $true
        $freshPart = @($fresh)
        $oldest = 0
        foreach ($o in $oldPart) {
          $dd = Get-BwSeenDays $s (Get-BwNameKey $o) $now2
          if ($dd -gt $oldest) { $oldest = $dd }
        }
        Log ('重洗队列: 未看过的只剩 ' + $fresh.Count + ' 张(<' + $global:BWRecycleBelow + ') -> 进入老图循环, 回收 ' + $oldPart.Count + ' 张老图(最早 ' + $oldest + ' 天前看过, 间隔 >=' + $minDays2 + ' 天)')
      } elseif ($fresh.Count -eq 0) {
        # 库里的图全都看过、而且一张都还没到回收间隔: 退回老办法 —— 历史清零重来一轮,
        # 但留最近 20 条, 免得刚看完那张翻个身又排到队首。
        $s.history = @(@(Get-BwHist $s) | Select-Object -Last 20)
        Log ('重洗队列: 库里 ' + $names.Count + ' 张全都看过且还没到回收间隔 -> 历史清零重来(留最近 20 条防连着重复)')
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
  # 老图循环: 新图洗牌排在前面(先把没看过的看完), 回收的老图洗牌跟在后面。
  # 2026-10-09: 洗牌改成"按来源轮流抽"(Get-BwBalancedOrder) —— 四个源轮流出现,
  # 张数少的源不会被张数多的源淹没。轮转起点跟着换图次数走, 不总是同一个源打头。
  $turn = 0
  try { $turn = [int]$s.refills + [int]$s.shown } catch { $turn = 0 }
  if ($recycleMode) {
    return @(@(Get-BwBalancedOrder $freshPart $turn) + @(Get-BwBalancedOrder $oldPart $turn))
  }
  return @(Get-BwBalancedOrder $names $turn)
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
    # 试运行: 后台补货什么都不做 —— 它要联网下载, 还要重洗队列并落盘(H-8 的口径:
    # -DryRun 不许有任何副作用)。原来这道闸只加在 Start-BwBackfill 上, 直接调用本函数
    # (后台子进程就是直接调的)照样会干活。
    if ($global:BWDry) { Log ('试运行: 本应后台补货 ' + $count + ' 张聚焦壁纸, 不下载、不重洗队列'); return }
    $c = Get-BwConfig
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
  finally {
    # 每轮都留一行心跳 —— 正常结束、异常、以及三条规则里提前 return 的路径
    # 都会走到 finally, 所以日志里"有没有这行"本身就能判断它是否还活着。
    Write-BwHeartbeat
  }
}
# 注意: -Update 与 -Cycle 走同一套逻辑。
# 老版本的开机自启动作是 -Update; 让 -Update 也进新节奏, 老用户不用重装就能零提权生效。
if ($Cycle -or $Update) { Invoke-BwCycle }
