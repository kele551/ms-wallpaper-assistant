# -*- coding: utf-8 -*-
# 作者: 海风（kele551）
"""桌面壁纸 2026-11-06：万象 / 随拍的中文名字离线回归。

现场：面板上出现过
    标题 雄性红翅黑鸟阿杰莱乌斯腓尼基人约翰海因茨国
    介绍 一只红翼黑鸟在约翰海因茨国家自然保护区的木板路上鸣叫。
三处毛病叠在一起：
  1) 作品名里的拉丁学名被逐词硬译成「阿杰莱乌斯腓尼基人」；
  2) Format-BwZhName 硬截 24 字、Get-BwSrcName 再截 28 字，把句尾的国家/州/市砍没；
  3) 面板拿被截坏的文件名重新拼标题，越拼越碎。
现在的口径（用户 2026-11-06「后期加入的两个图源，图片名字表述要准确，通顺，
包括国家，地理元素」）：
  原文先整理再整句送翻译；学名只在与另一个原始字段互证时才从短标题里移走；
  国家只认照片自己的元数据，绝不从物种名 / 词典猜；译文里还留着拉丁字母、
  汉字比例不够、去掉国家和日期后不足 4 个字、或超过 48 字的，一律不算名字，
  交回地理词典那条线（Get-BwFlowName），不硬截成半句话。

翻译引擎要联网、返回还会变，所以这里把两个引擎换成实测返回的桩表
（桩表里每一句都是 2026-11-06 在本机真实取到的返回，只有第 10 组两句是
 为了走「洗不干净就不收」这条路而构造的），闸门只判代码逻辑：
不联网、不碰图库、不看时间。

用法：
    python tests\\test_caption_names.py
    python tests\\test_caption_names.py <core.ps1 路径>
"""
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.environ.get('BW_SRC') or os.path.dirname(HERE)
CORE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(SRC, 'core.ps1')

# 控制台默认 GBK：中文照打，实在打不了的字符（冰岛语 ð、西里尔字母）走转义，
# 免得一条报错把整个测试冲掉。
try:
    sys.stdout.reconfigure(errors='backslashreplace')
except Exception:
    pass

WANT = ['Get-BwZhScore', 'Format-BwZhOrder', 'Get-BwZhRatio', 'Get-BwZhText',
        'Get-BwCaptionSource', 'Get-BwCaptionPlaces', 'Get-BwCaptionCountry',
        'Get-BwCaptionInput', 'Test-BwZhNameBody', 'Get-BwZhCommonRun',
        'Test-BwZhNameFluent', 'Get-BwPageCaption', 'Format-BwZhName',
        'Get-BwGeoLabel', 'Get-BwWordRe', 'Get-BwFlowName', 'Get-BwSubjectName',
        # 2026-11-06: Set-BwSrcDescriptiveName / Get-BwDisplayMeta 都调它，漏摘就会在子进程里
        # 抛「不是可识别的 cmdlet」，被两处 try/catch 静默吞掉 —— 名字一个都不更新还看不出原因。
        'Get-BwPendingSrcName', 'Set-BwSrcDescriptiveName',
        # 2026-11-06「名字要带国家」：这几个是补国家 / 用页面介绍派生命名的新支路，
        # 同样必须摘进子进程，漏一个就会被 try/catch 吞成「什么都没发生」。
        'Get-BwGeoCountry', 'Get-BwGeoCity', 'Repair-BwNameHead', 'Get-BwDescName',
        # 2026-11-07 三要素终检：Get-BwPageCaption / Get-BwPendingSrcName 都调它，
        # 漏摘就会在 try/catch 里被静默吞掉，名字一个都不更新还看不出原因。
        'Test-BwNameTriad',
        # 2026-11-08: Get-BwPageCaption 新加的国家/地名误译回修，同样必须在场，
        # 否则子进程直接抛 CommandNotFoundException，整段脚本中断、所有用例一起变空。
        'Repair-BwGeoMistranslation',
        'Get-BwMetaPayload', 'Write-BwImageMeta', 'Read-BwImageMeta',
        'Get-BwFileCredit', 'Get-BwDisplayMeta']

# 上面 WANT 是「这几个命名函数一个都不能少」的断言清单；这里是被它们**间接调用**的依赖。
# 以前只摘 WANT，core.ps1 里新增一层调用（2026-11-08 的 Convert-BwPageProperNames /
# Repair-BwGeoMistranslation）就漏摘，子进程第一句就抛 CommandNotFoundException，
# 又因为 $ErrorActionPreference='Stop'，整段脚本当场中断 —— 现象是所有用例的输出一起变成
# 空字符串，看上去像「命名逻辑全坏了」，其实一行代码都没错。依赖清单由 core.ps1 的 AST
# 求传递闭包得到（WANT 出发，只收仓库里真实定义的同名函数），改命名链路时要跟着更新。
# Log / Get-BwZhTencent / Get-BwZhYoudao 故意不收：前两个由 ps() 的 head 与 zh_stub()
# 提供桩，收了反而会把桩覆盖掉，测试就会去联网。
DEPS = ['Convert-BwPageProperNames', 'Repair-BwGeoMistranslation',
        'Get-BwDescFromCats', 'Get-BwEnDescriptionFromWikitext', 'Get-BwPageCaptionFromLink',
        'Get-BwLinkText', 'Get-BwText', 'Get-BwBytes',
        'Fetch-BwCommonsPage', 'Invoke-BwHttpPostJson', 'Test-BwIsLoopbackHttp']

# 2026-11-06 本机实测：整句在腾讯 / 有道两家的返回（送翻译的那句 -> 译文）。
# 「Goðafoss Waterfall, Iceland.」那条：库里四张连拍的原名都挂着
# 20240716 0832 1077 这类日期+时刻+序号尾巴，引擎把数字原样吐回来
# （见带数字的那条实测），整理阶段去掉尾巴后剩下部分的译法不变。
ZH = {
    "A male Red-Winged Blackbird calling from the boardwalk at John Heinz National Wildlife Refuge, Philadelphia, Pennsylvania, United States.": (
        "一只雄性红翅黑鸟在美国宾夕法尼亚州费城约翰海因茨国家野生动物保护区的木板路上鸣叫。",
        "一只雄性红翅黑鹂在美国宾夕法尼亚州费城约翰海因茨国家野生动物保护区的木板路上鸣叫。"),
    "Skyline of Toronto, Canada.": (
        "加拿大多伦多的天际线。", "加拿大多伦多的天际线。"),
    "Thailand, Sunset over downtown Bangkok.": (
        "泰国，日落在市中心的曼谷。", "泰国，曼谷市中心的日落。"),
    "Guinea baboon with juvenile at Port Lympne Wild Animal Park.": (
        "几内亚狒狒与少年在林姆尼港野生动物园。", "林姆尼港野生动物园的几内亚狒狒和幼崽。"),
    "Goðafoss Waterfall, Iceland.": (
        "冰岛戈阿福斯瀑布。", "冰岛gozhafoss瀑布。"),
    "Goðafoss Waterfall, Iceland, 20240716 0832 1077.": (
        "冰岛戈阿福斯瀑布，20240716 0832 1077.", "冰岛gozhafoss瀑布，20240716 0832 1077。"),
    "Greece, Kourtaliotiko Gorge, Finikas, Crete.": (
        "希腊，Kourtaliotiko峡谷，科孚岛，克里特岛", "希腊，Kourtaliotiko峡谷，菲尼卡斯，克里特岛。"),
    "United States, 10638 Bryce Canyon Luca Galuzzi 2007, Bryce Canyon National Park, Utah, USA.": (
        "美国，10638布莱斯峡谷Luca Galuzzi 2007，布莱斯峡谷国家公园，犹他州，美国.",
        "美国，10638布莱斯峡谷卢卡·格鲁兹2007，布莱斯峡谷国家公园，犹他州，美国。"),
    # 第 10 组专用：刻意造一句「专名洗不掉」的译文，看代码收不收。
    "Urban scene at dusk in Someplace, Nowhere.": (
        "Someplace的城市夜景，在诺威尔。", "诺威尔Someplace的黄昏城市景观。"),
    "Iceland": ("冰岛", "冰岛"),
    "United States": ("美国", "美国"),
    "Canada": ("加拿大", "加拿大"),
    "Thailand": ("泰国", "泰国"),
    "Greece": ("希腊", "希腊"),
    # 第 13 组（英文语序）专用：以下每句都是 2026-11-06 在本机取到的真实返回，
    # 左边腾讯、右边有道；句子本身就是库里那几张图整理后送去翻译的那一句。
    "Germany, Aurora and perseids.": (
        "德国，极光和英仙座流星雨。", "德国，极光和英仙座。"),
    "Germany": ("德国", "德国"),
    "City scene, inner city Birmingham.": (
        "城市风景，伯明翰市中心。", "城市景观，伯明翰内城。"),
    "inner city Birmingham": ("伯明翰市中心", "伯明翰内城"),
    "Boats, Donaghadee Harbour.": (
        "船，多纳哈迪港。", "船只，Donaghadee港。"),
    "Donaghadee Harbour": ("多纳哈迪港", "Donaghadee港口"),
    "United States, Sunset at Little Island, New York City - view towards Jersey City.": (
        "美国，在小岛屿的日落，纽约市-对泽西城的看法。", "美国，日落在小岛，纽约市-向泽西城的看法。"),
    "Kisumu City, Kenya - Night Skyline.": (
        "基苏穆市，肯尼亚-夜晚的地平线。", "肯尼亚基苏木市——夜晚的天际线。"),
    "Kenya": ("肯尼亚", "肯尼亚"),
    "United States, Old Crissy Field Coast Guard Station in the Presidio of San Francisco.": (
        "美国，位于旧金山弗朗西斯科的普雷西迪奥的老克里西菲尔德海岸警卫队站。",
        "美国，位于旧金山要塞的老克里西菲尔德海岸警卫站。"),
    "United States, Market st. San Francisco, hotels, and, along the way.": (
        "美国，市场圣弗朗西斯科，酒店，和，沿着。", "美国，市场圣弗朗西斯科，酒店，和，沿着。"),
    # 第 18 组（词典地名写法优先）专用：三句都是 2026-11-06 联网取到的真实返回，
    # 语序通顺、国家也在，只有专名的音译跟词典对不上。
    "Iceland, Goðafoss Island.": (
        "冰岛，戈洛福斯岛。", "冰岛，gozhafoss岛。"),
    "Sun getting through fog in the New Zealand bush, Bryant Range.": (
        "阳光穿过新西兰灌木丛中的雾，布莱恩特山脉。", "新西兰丛林的雾气透出的阳光，布莱恩特山脉。"),
    "Minato City, Tokyo, Japan.": (
        "日本东京都美娜多市。", "日本东京美娜多市。"),
    "New Zealand": ("新西兰", "新西兰"),
    "Japan": ("日本", "日本"),
}

# 本机万象 / 随拍库里这几张图的原始 Commons 字段（作品名 / 描述 / 分类）。
# 用例直接喂原始字段，验证「整理 -> 送翻译」这一步产出的正是上面桩表里那句。
RAW = {
    'heinz': {
        'orig': 'Male Red-winged blackbird (Agelaius phoeniceus) John Heinz National Wildlife Refuge, Philadelphia, Pennsylvania, United States',
        'desc': 'A Red-Winged Blackbird calling from the boardwalk at John Heinz NWR.',
        'cats': 'Agelaius phoeniceus (male) / Birds at John Heinz National Wildlife Refuge at Tinicum'},
    'toronto': {
        'orig': 'Skyline of Toronto', 'desc': 'Toronto, Canada',
        'cats': 'Flickr images uploaded by Flickr upload bot / Night skylines of Toronto / September 2012 in Toronto'},
    'bangkok': {
        'orig': 'Bangkok - City skyline at sunset', 'desc': 'Sunset over downtown Bangkok.',
        'cats': 'Taken with Panasonic Lumix DMC-LX5 / Views of Bangkok / Skyscapes of Thailand'},
    'baboon': {
        'orig': 'Papio papio and juvenile Port Lympne Wild Animal Park',
        'desc': 'Guinea baboon (  Papio papio  ) with juvenile at  Port Lympne Wild Animal Park .',
        'cats': 'Taken with Olympus E-M1 / Featured pictures on Wikipedia, English / Flickr images reviewed by FlickreviewR'},
    'gorge': {
        'orig': 'Kourtaliotiko Gorge 03',
        'desc': 'Kourtaliotiko Gorge (Κουρταλιώτικο φαράγγι), Finikas, Crete',
        'cats': 'Kourtaliotiko Gorge / Greece photographs taken on 2015-08-29 / All images by Uoaei1'},
    'bryce': {
        'orig': 'USA 10638 Bryce Canyon Luca Galuzzi 2007',
        'desc': 'Navajo Trail, Bryce Canyon National Park, Utah, USA, Trees are Pseudotsuga menziesii and Pinus ponderosa',
        'cats': 'Pseudotsuga menziesii subsp. glauca / Pinus ponderosa subsp. brachyptera / Rock formations in Utah'},
    'burst': {
        'orig': 'Goðafoss Waterfall, Iceland, 20240716 0832 1077',
        'desc': 'Goðafoss Waterfall, Iceland',
        'cats': 'Iceland photographs taken on 2024-07-16 / Goðafoss in 2024'},
    # 第 13 组：这几张是 2026-11-06 联网跑遍图库时挑出来的「翻对了但读着像外文」的样本。
    'perseids': {
        'orig': 'Aurora and perseids',
        'desc': 'Aurora and perseids seen at the beach of Norderney, Germany. The image is a composite of 64 individual exposures of meteors, one of these images was used as a background. The frames were taken in the night from 12 to 13 …',
        'cats': 'Taken with Nikon Z 6 / Retouched pictures / Night in Norderney'},
    'birmingham': {
        'orig': 'City scene, inner city Birmingham - geograph.org.uk - 2413712',
        'desc': 'City scene, inner city Birmingham',
        'cats': 'Images from Geograph Britain and Ireland / Birmingham city centre'},
    'donaghadee': {
        'orig': 'Boats, Donaghadee Harbour - geograph.org.uk - 6921482',
        'desc': 'Boats, Donaghadee Harbour',
        'cats': 'Donaghadee / Images from Geograph Britain and Ireland'},
    'little_island': {
        'orig': 'Sunset at Little Island, New York City, 20231001 1823 1522',
        'desc': 'Sunset at Little Island, New York City - view towards Jersey City',
        'cats': 'New York City photographs taken on 2023-10-01 / Sunsets of New York City / Files by Jakub Hałun'},
    'kisumu': {
        'orig': 'Kisumu City, Kenya - Night Skyline (55038160251)',
        'desc': 'Kisumu City, Kenya - Night Skyline',
        'cats': 'Flickr images reviewed by FlickreviewR 2 / Flickr images missing SDC published in'},
    'crissy': {
        'orig': 'Old Crissy Field Coast Guard Station in the fog (December 2015)',
        'desc': 'Old Crissy Field Coast Guard Station in the Presidio of San Francisco.',
        'cats': 'Fog in San Francisco / Crissy Field / Golden Gate Bridge in fog'},
    'market_st': {
        'orig': 'Market st. San Francisco. (48669724832)',
        'desc': "Considered to be the Champs Elysees of the city, this grand street is filled with shops, hotels, and, along the way, remarkable architecture. San Francisco's Municipal Railway has assembled one of the most diverse collec…",
        'cats': 'CC-Zero / F Market & Wharves streetcars / Streetcar 1059 (San Francisco)'},
    # 第 18 组：作品名里就写着地名，机翻却给出另一套音译（2026-11-06 实测）。
    'godafoss_island': {
        'orig': 'Goðafoss Island',
        'desc': 'Goðafoss is a waterfall located in the northern part of Iceland.',
        'cats': 'Waterfalls in Iceland / Goðafoss'},
    'bryant': {
        'orig': 'Sun getting through fog in the New Zealand bush, Bryant Range',
        'desc': 'The picture was taken on the trail between Rocks Hut and Middle Creek Hut. This section is part of Te Araroa Trail',
        'cats': 'Trees in New Zealand'},
    'minato': {
        'orig': 'Minato City, Tokyo, Japan',
        'desc': ('A wide-angle landscape photograph of the Tokyo skyline captured during the golden hour. '
                 'The image features a dense concentration of skyscrapers in the Minato ward.'),
        'cats': 'Views of Minato, Tokyo'},
}

# 每个样本整理后应当送翻译的那一句（与实测一致）。
EXPECT = {
    'heinz': ("A male Red-Winged Blackbird calling from the boardwalk at John Heinz National "
              "Wildlife Refuge, Philadelphia, Pennsylvania, United States."),
    'toronto': 'Skyline of Toronto, Canada.',
    'bangkok': 'Thailand, Sunset over downtown Bangkok.',
    'baboon': 'Guinea baboon with juvenile at Port Lympne Wild Animal Park.',
    'gorge': 'Greece, Kourtaliotiko Gorge, Finikas, Crete.',
    'bryce': ("United States, 10638 Bryce Canyon Luca Galuzzi 2007, Bryce Canyon National Park, Utah, "
              "USA."),
    'burst': 'Goðafoss Waterfall, Iceland.',
    'perseids': 'Germany, Aurora and perseids.',
    'birmingham': 'City scene, inner city Birmingham.',
    'donaghadee': 'Boats, Donaghadee Harbour.',
    'little_island': 'United States, Sunset at Little Island, New York City - view towards Jersey City.',
    'kisumu': 'Kisumu City, Kenya - Night Skyline.',
    'crissy': 'United States, Old Crissy Field Coast Guard Station in the Presidio of San Francisco.',
    'market_st': 'United States, Market st. San Francisco, hotels, and, along the way.',
}

def asc(s):
    return json.dumps(s or '', ensure_ascii=True)


def q(s):
    """PowerShell 单引号字面量：反斜杠和 $ 都不展开，中文原样带过去。"""
    return "'" + str(s or '').replace("'", "''") + "'"


FAILS = []

# 第 12 组：老图「只改内嵌译名」这条路（Invoke-BwSrcGenericNameFix 用的就是它）。
# 现场在临时目录里造一张最小 JPEG，绝不允许碰用户图库。
NEWNAME = '美国宾夕法尼亚州费城约翰海因茨国家野生动物保护区的木板路上鸣叫的雄性红翅黑鸟'
META_SCRIPT = r"""
$dir = Join-Path ([IO.Path]::GetTempPath()) ('bwmeta-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
try {
  $p = Join-Path $dir 'a.jpg'
  $pixels = [byte[]](1..64)
  $b = New-Object byte[] ($pixels.Length + 4)
  $b[0] = 0xFF; $b[1] = 0xD8
  [Array]::Copy($pixels, 0, $b, 2, $pixels.Length)
  $b[$b.Length - 2] = 0xFF; $b[$b.Length - 1] = 0xD9
  [IO.File]::WriteAllBytes($p, $b)

  $old = @{ zhname = %s; zhdesc = '旧介绍'; caption_version = ''; author = 'Kris Madsen';
            origname = 'Male Red-winged blackbird (Agelaius phoeniceus) John Heinz National Wildlife Refuge';
            shot_date = '2016-05-07'; date = '2016-05-07'; width = 3840; height = 2160 }
  [void](Write-BwImageMeta $p $old)
  $before = [IO.File]::ReadAllBytes($p)
  $when = [DateTime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
  [IO.File]::SetLastWriteTimeUtc($p, $when)

  $new = @{ zhname = %s; zhdesc = ''; caption_version = '2' }
  $ok = Write-BwImageMeta $p $new -ReplaceCaption
  $after = [IO.File]::ReadAllBytes($p)
  $m = Read-BwImageMeta $p

  # 自研 COM 段(FF FE)只能有一段，多写一次就是叠加脏数据。
  $segs = 0; $i = 2
  while ($i -lt ($after.Length - 3)) {
    if ($after[$i] -ne 0xFF) { break }
    $mk = $after[$i + 1]
    if ($mk -eq 0xDA -or $mk -eq 0xD9) { break }
    if (($mk -ge 0xD0 -and $mk -le 0xD7) -or $mk -eq 0x01) { $i += 2; continue }
    $len = ([int]$after[$i + 2] * 256) + [int]$after[$i + 3]
    if ($len -lt 2) { break }
    if ($mk -eq 0xFE) { $segs++ }
    $i += $len + 2
  }

  $pixSame = $true
  for ($j = 0; $j -lt $pixels.Length; $j++) {
    if ($before[$before.Length - 66 + $j] -ne $after[$after.Length - 66 + $j]) { $pixSame = $false; break }
  }

  Write-Output ('OK|' + $ok)
  Write-Output ('ZHNAME|' + ($m.zhname -eq %s))
  Write-Output ('CAPVER|' + ($m.caption_version -eq '2'))
  Write-Output ('AUTHOR|' + ($m.author -eq 'Kris Madsen'))
  Write-Output ('ORIG|' + ($m.origname -like 'Male Red-winged blackbird*'))
  Write-Output ('SHOT|' + ($m.shot_date -eq '2016-05-07'))
  Write-Output ('PIX|' + $pixSame)
  Write-Output ('SEG|' + $segs)
  Write-Output ('MTIME|' + ([IO.File]::GetLastWriteTimeUtc($p) -eq $when))
  Write-Output ('NAME1|' + (Get-BwDisplayMeta $p))

  # 没升到 caption_version 2 的老图，面板不许拿它的旧译名当新名。
  $p2 = Join-Path $dir 'b.jpg'
  [IO.File]::WriteAllBytes($p2, $b)
  [void](Write-BwImageMeta $p2 @{ zhname = '上一版截断的旧名'; caption_version = '' })
  Write-Output ('NAME0|[' + (Get-BwDisplayMeta $p2) + ']')
} finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
""" % (q('雄性红翅黑鸟阿杰莱乌斯腓尼基人约翰海因茨国'), q(NEWNAME), q(NEWNAME))

# 第 16 组：整句译文被闸门挡下的老图，也要被后台补成词典名，不许继续顶着坏名字。
# 「银河娱乐城」就是库里两张 Milky Way 现在的标题（词典给的是「银河星空」）。
DICTNAME = '银河星空'
REPAIR_SCRIPT = r"""
$dir = Join-Path ([IO.Path]::GetTempPath()) ('bwfix-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
try {
  $p = Join-Path $dir 'a.jpg'
  $pixels = [byte[]](1..64)
  $b = New-Object byte[] ($pixels.Length + 4)
  $b[0] = 0xFF; $b[1] = 0xD8
  [Array]::Copy($pixels, 0, $b, 2, $pixels.Length)
  $b[$b.Length - 2] = 0xFF; $b[$b.Length - 1] = 0xD9
  [IO.File]::WriteAllBytes($p, $b)

  $old = @{ zhname = '银河娱乐城'; zhdesc = ''; caption_version = ''; author = 'Guisard';
            origname = 'Guisard - Milky Way'; desc = 'Milky Way over the ridge'; cats = '';
            source_type = '万象'; shot_date = '2009-09-21'; date = '2009-09-21';
            width = 3840; height = 2199 }
  [void](Write-BwImageMeta $p $old)
  Write-Output ('BEFORE|' + (Read-BwImageMeta $p).zhname)
  [void](Set-BwSrcDescriptiveName $p)
  $m = Read-BwImageMeta $p
  Write-Output ('AFTER|' + $m.zhname)
  Write-Output ('CAPVER|' + $m.caption_version)
  Write-Output ('AUTHOR|' + ($m.author -eq 'Guisard'))
  Write-Output ('SHOT|' + ($m.shot_date -eq '2009-09-21'))
  Write-Output ('ORIG|' + ($m.origname -eq 'Guisard - Milky Way'))
  Write-Output ('DISPLAY|' + (Get-BwDisplayMeta $p))
} finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
"""

# 同一套后台补名，换成任意一张老图：库里真实字段（RAW[key]）+ 现在顶着的老名字。
REPAIR_TMPL = r"""
$dir = Join-Path ([IO.Path]::GetTempPath()) ('bwfix-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
try {
  $p = Join-Path $dir 'a.jpg'
  $pixels = [byte[]](1..64)
  $b = New-Object byte[] ($pixels.Length + 4)
  $b[0] = 0xFF; $b[1] = 0xD8
  [Array]::Copy($pixels, 0, $b, 2, $pixels.Length)
  $b[$b.Length - 2] = 0xFF; $b[$b.Length - 1] = 0xD9
  [IO.File]::WriteAllBytes($p, $b)

  $old = @{ zhname = %(OLD)s; zhdesc = %(OLDDESC)s; caption_version = ''; author = 'Luca Galuzzi';
            origname = %(ORIG)s; desc = %(DESC)s; cats = %(CATS)s;
            source_type = '万象'; shot_date = '2007-07-21'; date = '2007-07-21';
            width = 3840; height = 2199 }
  [void](Write-BwImageMeta $p $old)
  Write-Output ('BEFORE|' + (Read-BwImageMeta $p).zhname)
  [void](Set-BwSrcDescriptiveName $p)
  $m = Read-BwImageMeta $p
  Write-Output ('AFTER|' + $m.zhname)
  Write-Output ('CAPVER|' + $m.caption_version)
  Write-Output ('DESCR|' + $m.zhdesc)
  Write-Output ('AUTHOR|' + ($m.author -eq 'Luca Galuzzi'))
  Write-Output ('ORIG|' + ($m.origname -eq %(ORIG)s))
  Write-Output ('DISPLAY|' + (Get-BwDisplayMeta $p))
} finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
"""


def repair_call(key, old_name, old_desc=''):
    """跑一遍后台补名，返回（最终写进元数据的名字, 全部中间输出）。"""
    c = RAW[key]
    rc, out, got = run(REPAIR_TMPL % {'OLD': q(old_name), 'OLDDESC': q(old_desc),
                                      'ORIG': q(c['orig']), 'DESC': q(c['desc']),
                                      'CATS': q(c['cats'])})
    return got.get('AFTER', ''), got


# 第 20 组：老图「内嵌介绍 -> 名字」这条路（面板当场显示走的就是它，不联网）。
DESC_TMPL = r"""
$dir = Join-Path ([IO.Path]::GetTempPath()) ('bwdesc-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
try {
  $p = Join-Path $dir 'a.jpg'
  $pixels = [byte[]](1..64)
  $b = New-Object byte[] ($pixels.Length + 4)
  $b[0] = 0xFF; $b[1] = 0xD8
  [Array]::Copy($pixels, 0, $b, 2, $pixels.Length)
  $b[$b.Length - 2] = 0xFF; $b[$b.Length - 1] = 0xD9
  [IO.File]::WriteAllBytes($p, $b)
  $old = @{ zhname = ''; zhdesc = %(DESC)s; caption_version = ''; author = 'Frank Schulenburg';
            origname = %(ORIG)s; desc = %(RAW)s; cats = %(CATS)s;
            source_type = %(TYPE)s; shot_date = '2024-09-23'; date = '2024-09-23';
            width = 3840; height = 2160 }
  [void](Write-BwImageMeta $p $old)
  Write-Output ('DISP|' + (Get-BwDisplayMeta $p))
  Write-Output ('SUBJ|' + (Get-BwSubjectName (([string]$old.desc) + ' ' + [string]$old.origname) 'urban'))
} finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
"""


# 第 21 组：面板里那几个取名字的函数（真拿 node 跑一遍，不看注释）。
PANEL_JS = r"""
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
function grabFn(name) {
  const at = src.indexOf('function ' + name + '(');
  if (at < 0) throw new Error('missing function ' + name);
  let i = src.indexOf('{', at), depth = 0, j = i;
  for (; j < src.length; j++) {
    if (src[j] === '{') depth++;
    else if (src[j] === '}') { depth--; if (depth === 0) break; }
  }
  return src.slice(at, j + 1);
}
function grabVar(name) {
  const at = src.indexOf('var ' + name + ' =');
  if (at < 0) throw new Error('missing var ' + name);
  const end = src.indexOf('];', at);
  return src.slice(at, end + 2);
}
const code = [grabVar('CN_FALLBACK'), grabFn('safeDisplay'), grabFn('baseName'),
              grabFn('parseName'), grabFn('displayName')].join('\n');
eval(code);
function say(k, v) { console.log(k + '|' + v); }
say('A', displayName({ name: '2024-09-23_BrooklynDinerNewYorkCity2024_4027fc30_picsum153061729.jpg' }));
say('B', displayName({ name: 'x.jpg', display: '2024' }));
say('C', displayName({ name: 'x.jpg', display: '美国纽约市西43街时代广场附近的布鲁克林餐厅' }));
say('D', displayName({ name: '2026-05-19_雄性红翅黑鸟（阿杰莱乌斯腓尼基人）约翰海因茨国_3d1fe651.jpg' }));
"""


def node_panel_check():
    """用 node 真跑面板的 displayName，确认「2024」不会再被当成标题。"""
    panel = os.path.join(SRC, 'panel.html')
    if not os.path.exists(panel):
        return 1, 'MISSING|panel.html'
    try:
        import shutil
        node = shutil.which('node') or 'node'
        tmp = tempfile.mkdtemp(prefix='bwpanel-')
        p = os.path.join(tmp, 'p.js')
        with open(p, 'wb') as f:
            f.write(PANEL_JS.encode('utf-8'))
        # 本机的 node 是个 .cmd 影子（Electron 以 NODE 模式跑），CreateProcess 直接执行不了。
        if node.lower().endswith(('.cmd', '.bat')):
            cmd = '"%s" "%s" "%s"' % (node, p, panel)
            r = subprocess.run(cmd, capture_output=True, timeout=60, shell=True)
        else:
            r = subprocess.run([node, p, panel], capture_output=True, timeout=60)
        return r.returncode, (r.stdout.decode('utf-8', 'replace') + r.stderr.decode('utf-8', 'replace'))
    except Exception as e:  # node 不在就如实说没测，不假装通过
        return 1, 'NONODE|%s' % e



def check(name, cond, extra=''):
    if cond:
        print('[ok] %s' % name)
    else:
        print('[X ] %s  %s' % (name, extra))
        FAILS.append(name)
    return bool(cond)


def asc(s):
    return json.dumps(s or '', ensure_ascii=True)


def q(s):
    """PowerShell 单引号字面量：反斜杠和 $ 都不展开，中文原样带过去。"""
    return "'" + str(s or '').replace("'", "''") + "'"


def zh_stub():
    lines = ['$script:BwZhStub = @{}']
    for i, (k, (t, y)) in enumerate(sorted(ZH.items())):
        lines.append('$script:BwZhStub["t%d"] = @(%s, %s)' % (i, q(k), q(t)))
        lines.append('$script:BwZhStub["y%d"] = @(%s, %s)' % (i, q(k), q(y)))
    lines.append(r'''
function Get-BwZhTencent([string]$t) {
  foreach ($k in @($script:BwZhStub.Keys | Sort-Object)) {
    if ($k -like 't*') {
      $v = $script:BwZhStub[$k]
      if ([string]$v[0] -eq $t) { return [string]$v[1] }
    }
  }
  return ''
}
function Get-BwZhYoudao([string]$t) {
  foreach ($k in @($script:BwZhStub.Keys | Sort-Object)) {
    if ($k -like 'y*') {
      $v = $script:BwZhStub[$k]
      if ([string]$v[0] -eq $t) { return [string]$v[1] }
    }
  }
  return ''
}''')
    return '\n'.join(lines)


def ps(script):
    """摘函数 + 桩，交给 PowerShell 跑；返回 (rc, 文本)。

    子进程默认按控制台代码页写管道，中文会花；先把输出编码钉成 UTF-8 再解。
    """
    tmp = tempfile.mkdtemp(prefix='bwcaption-')
    p = os.path.join(tmp, 't.ps1')
    head = ("try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }\n"
            "$ErrorActionPreference = 'Stop'\nfunction Log($m, $lvl = '') { }\n")
    with open(p, 'wb') as f:
        f.write(b'\xef\xbb\xbf' + (head + script).encode('utf-8'))
    r = subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', p],
                       capture_output=True, timeout=180)
    return r.returncode, r.stdout.decode('utf-8', 'replace') + r.stderr.decode('utf-8', 'replace')


def extract_block():
    """用 PowerShell 自己的解析器按名字取函数体，不写死行号。"""
    return (
        "$txt = Get-Content -Raw -Encoding UTF8 %s\n"
        "$errs = @()\n"
        "$ast = [System.Management.Automation.Language.Parser]::ParseInput($txt, [ref]$null, [ref]$errs)\n"
        "if ($errs.Count) { Write-Output ('PARSE_ERR ' + $errs.Count); exit 2 }\n"
        "$fs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)\n"
        "foreach ($n in @(%s)) {\n"
        "  $f = $fs | Where-Object { $_.Name -eq $n } | Select-Object -First 1\n"
        "  if (-not $f) { Write-Output ('MISSING ' + $n); exit 3 }\n"
        "  . ([scriptblock]::Create($f.Extent.Text))\n}\n"
        % (q(CORE), ', '.join(q(n) for n in WANT + DEPS)))


BASE = None


def run(snippet, head=None):
    rc, out = ps((head if head is not None else BASE) + snippet)
    return rc, out, dict(l.split('|', 1) for l in out.splitlines() if '|' in l)


def cap_call(key, tag=''):
    """用库里真实的原始字段走一遍命名，把中间结果都打出来。"""
    c = RAW[key]
    s = ("$in = Get-BwCaptionInput %s %s %s\n"
         "$out = Get-BwPageCaption %s %s %s\n"
         "Write-Output ('%sINPUT|' + $in.text)\n"
         "Write-Output ('%sCOUNTRY|' + $in.country)\n"
         "Write-Output ('%sNAME|' + $out.zhname)\n"
         "Write-Output ('%sDESC|' + $out.zhdesc)\n"
         % (q(c['orig']), q(c['desc']), q(c['cats']),
            q(c['orig']), q(c['desc']), q(c['cats']), tag, tag, tag, tag))
    rc, out, got = run(s)
    return out, got


def main():
    global BASE
    print('被测: %s' % CORE)
    if not os.path.exists(CORE):
        check('core.ps1 存在', False, CORE)
        return 1

    print('---- 0) core.ps1 能解析、命名函数一个都不能少')
    rc, out, got = run("Write-Output 'OK|FNS_OK'\n", head=extract_block())
    check('AST 摘取 %d 个函数' % len(WANT), 'OK|FNS_OK' in out, out.strip()[:300])
    if 'OK|FNS_OK' not in out:
        return 1
    BASE = extract_block() + zh_stub() + "\n$global:BwZhCache = @{}\n"

    print('---- 1) 用户截图那条：国家、州、市、保护区全留住，且不截断')
    out, got = cap_call('heinz')
    name = got.get('NAME', '')
    print('    送翻译: %s' % asc(got.get('INPUT', '')))
    print('    名字  : %s' % asc(name))
    check('整理出的原文与实测那句一致', got.get('INPUT', '') == EXPECT['heinz'], asc(got.get('INPUT', '')))
    check('国家认成 United States', got.get('COUNTRY', '') == 'United States', got.get('COUNTRY', ''))
    check('名字留住 美国 / 宾夕法尼亚州 / 费城 / 约翰海因茨',
          all(w in name for w in ['美国', '宾夕法尼亚州', '费城', '约翰海因茨']), asc(name))
    check('名字留住画面主体（红翅黑 / 木板路 / 鸣叫）',
          all(w in name for w in ['红翅黑', '木板路', '鸣叫']), asc(name))
    check('名字里没有拉丁字母（学名硬译的痕迹）',
          not any(ch.isascii() and ch.isalpha() for ch in name), asc(name))
    check('名字里不再有学名硬译的「阿杰莱乌斯」「腓尼基人」',
          '阿杰莱乌斯' not in name and '腓尼基' not in name, asc(name))

    print('---- 2) 语序：国家在前的那份要赢（泰国曼谷…，不是日落在…，泰国）')
    out, got = cap_call('bangkok')
    name = got.get('NAME', '')
    print('    送翻译: %s' % asc(got.get('INPUT', '')))
    print('    名字  : %s' % asc(name))
    check('整理出的原文与实测那句一致', got.get('INPUT', '') == EXPECT['bangkok'], asc(got.get('INPUT', '')))
    check('国家开头 + 通顺（泰国曼谷市中心的夕阳）',
          name.startswith('泰国') and '曼谷' in name and '日落' in name, asc(name))

    print('---- 3) 加拿大那张：原作品名没有国家，从描述/分类认出来要补上')
    out, got = cap_call('toronto')
    print('    送翻译: %s' % asc(got.get('INPUT', '')))
    print('    名字  : %s' % asc(got.get('NAME', '')))
    check('整理出的原文与实测那句一致', got.get('INPUT', '') == EXPECT['toronto'], asc(got.get('INPUT', '')))
    check('名字带国家（加拿大多伦多的天际线）',
          got.get('NAME', '').startswith('加拿大') and '多伦多' in got.get('NAME', ''), asc(got.get('NAME', '')))

    print('---- 4) 国家不许猜：Guinea baboon 不是摄于几内亚')
    out, got = cap_call('baboon')
    print('    送翻译: %s' % asc(got.get('INPUT', '')))
    print('    名字  : %s' % asc(got.get('NAME', '')))
    check('整理出的原文与实测那句一致', got.get('INPUT', '') == EXPECT['baboon'], asc(got.get('INPUT', '')))
    check('country 是空的（不从物种名推国家）', got.get('COUNTRY', '') == '', asc(got.get('COUNTRY', '')))
    # 2026-11-06「名字要带国家」后：页面原文里的 Port Lympne 进地名表（英国·林姆尼港），
    # 名字就成了「英国林姆尼港野生动物园的…」—— 国家在头、地点在前、主体在后。
    check('改用「先地点后主体」的语序，动物园不再甩在句尾',
          got.get('NAME', '') == '英国林姆尼港野生动物园的几内亚狒狒和幼崽', asc(got.get('NAME', '')))

    print('---- 5) 学名括注：只在与另一个原始字段互证时才从短标题移走')
    rc, out, got = run(
        "Write-Output ('DROP|' + (Get-BwCaptionSource %s %s))\n"
        "Write-Output ('KEEP|' + (Get-BwCaptionSource %s %s))\n"
        % (q('Red-Winged Blackbird (Agelaius phoeniceus) calling'),
           q('Agelaius phoeniceus|Birds of Pennsylvania'),
           q('Red-Winged Blackbird (Agelaius phoeniceus) calling'),
           q('some unrelated categories')))
    print('    互证: %s' % asc(got.get('DROP', '')))
    print('    孤证: %s' % asc(got.get('KEEP', '')))
    check('互证时移走学名', 'Agelaius' not in got.get('DROP', '') and 'calling' in got.get('DROP', ''),
          asc(got.get('DROP', '')))
    check('孤证时原样保留', 'Agelaius phoeniceus' in got.get('KEEP', ''), asc(got.get('KEEP', '')))

    print('---- 6) 只有日期+国家的译文不算名字，交回地理词典那条线')
    rc, out, got = run(
        "Write-Output ('BODY|' + (Test-BwZhNameBody %s %s))\n"
        "Write-Output ('FULL|' + (Test-BwZhNameBody %s %s))\n"
        "Write-Output ('NUM|' + (Test-BwZhNameBody %s %s))\n"
        % (q('2014年7月，冰岛'), q('冰岛'),
           q('冰岛北部的戈阿福斯瀑布'), q('冰岛'),
           q('冰岛戈阿福斯瀑布，20240716 0832 1077'), q('冰岛')))
    check('日期+国家 -> 不收', got.get('BODY', '').strip().lower() == 'false', out.strip()[:200])
    check('真名字 -> 收', got.get('FULL', '').strip().lower() == 'true', out.strip()[:200])
    check('只剩瀑布名+一串数字 -> 收不了（戈阿福斯瀑布本身够 4 字）',
          got.get('NUM', '').strip().lower() == 'true', out.strip()[:200])

    print('---- 7) 专名洗不掉 / 文件名痕迹：一律退回地理词典那条线，不硬凑')
    for key, why in [('gorge', 'Kourtaliotiko 这种专名引擎不译'),
                     ('bryce', '文件名里的编号和作者名不译')]:
        out, got = cap_call(key)
        print('    送翻译: %s' % asc(got.get('INPUT', '')))
        print('    名字  : %s' % asc(got.get('NAME', '')))
        check('整理出的原文与实测那句一致（%s）' % why, got.get('INPUT', '') == EXPECT[key], asc(got.get('INPUT', '')))
        check('名字留空，交回词典（%s）' % why, got.get('NAME', '') == '', asc(got.get('NAME', '')))

    print('---- 8) 连拍时间戳 / 序号不进译文输入，也不进名字')
    out, got = cap_call('burst')
    name = got.get('NAME', '')
    print('    送翻译: %s' % asc(got.get('INPUT', '')))
    print('    名字  : %s' % asc(name))
    check('整理出的原文与实测那句一致', got.get('INPUT', '') == EXPECT['burst'], asc(got.get('INPUT', '')))
    check('时间戳/序号被去掉', not any(w in got.get('INPUT', '') for w in ['20240716', '0832', '1077']),
          asc(got.get('INPUT', '')))
    check('国家仍然认成 Iceland', got.get('COUNTRY', '') == 'Iceland', got.get('COUNTRY', ''))
    check('名字既有国家又有瀑布，且不带数字串',
          '冰岛' in name and '瀑布' in name and not any(ch.isdigit() for ch in name), asc(name))

    print('---- 9) 长句不硬截：48 字以内留全，超了就整条退回')
    rc, out, got = run(
        "$a = Format-BwZhName (%s + (%s * 4))\n"
        "Write-Output ('LEN|' + $a.Length)\n"
        "Write-Output ('TAIL|' + $a.EndsWith(%s))\n"
        "Write-Output ('LONG|[' + (Format-BwZhName (%s * 12)) + ']')\n"
        % (q('美国加利福尼亚州洛杉矶'), q('市中心夜景'), q('市中心夜景'), q('市中心夜景')))
    print('    短句: %s' % out.strip()[:200])
    check('长地名整句保住（>=24 字）', int(got.get('LEN', 0) or 0) >= 24, out.strip()[:200])
    check('句尾完整（末尾还是「市中心夜景」，没被砍半）',
          got.get('TAIL', '').strip().lower() == 'true', out.strip()[:200])
    check('超长整条退回而不是截一半', got.get('LONG', '').strip('[]') == '', out.strip()[:200])

    print('---- 10) 介绍（zhdesc）与名字同一把尺：外文没洗掉就整条不收')
    rc, out, got = run(
        "$o = Get-BwPageCaption %s '' ''\n"
        "Write-Output ('BADNAME|[' + $o.zhname + ']')\n"
        "Write-Output ('BADDESC|[' + $o.zhdesc + ']')\n"
        "Write-Output ('VER|' + $o.caption_version)\n"
        % q('Urban scene at dusk in Someplace, Nowhere.'))
    print('    %s' % out.strip()[:260])
    check('外文没洗掉 -> 名字留空', got.get('BADNAME', '').strip('[]') == '', out.strip()[:260])
    check('外文没洗掉 -> 介绍留空', got.get('BADDESC', '').strip('[]') == '', out.strip()[:260])
    check('仍然带 caption_version 2（面板据此认定这条是新版整理过的）',
          got.get('VER', '') == '2', got.get('VER', ''))

    print('---- 11) 反证：桩表里没有这句（翻不出来），名字必须是空')
    rc, out, got = run("Write-Output ('NAME|[' + (Get-BwPageCaption 'NoSuchSentence In The Table.' '' '').zhname + ']')\n")
    check('翻不出来 -> 空', got.get('NAME', '') == '[]', out.strip()[:200])

    print('---- 12) 老图改名：只换内嵌译名，文件名/像素/作者/日期一个都不动')
    rc, out, got = run(META_SCRIPT)
    print('    %s' % out.strip()[:400])
    for key, label in [('OK', '写回成功'), ('ZHNAME', '译名换成新的'), ('CAPVER', 'caption_version=2'),
                       ('AUTHOR', '作者名保留'), ('ORIG', '原始作品名保留'), ('SHOT', '拍摄日保留'),
                       ('PIX', '像素字节没动'), ('SEG', '只有一段自研 COM 标记'),
                       ('MTIME', '文件时间戳没变'),
                       ('NAME0', '旧版(caption_version 不是 2)不冒充新名')]:
        if key == 'SEG':
            check(label, got.get(key, '') == '1', got.get(key, ''))
        elif key == 'NAME0':
            check(label, got.get(key, '').strip('[]') == '', asc(got.get(key, '')))
        else:
            check(label, got.get(key, '').lower() == 'true', got.get(key, ''))
    check('面板显示名走的是内嵌的新译名', got.get('NAME1', '') == NEWNAME, asc(got.get('NAME1', '')))

    print('---- 13) 翻对了但语序是英文的：不当名字用，交回地理词典那条线')
    # 2026-11-06 联网跑遍万象/随拍那轮里最典型的几句：字都翻对了，读着仍是外文。
    for key, why in [('perseids', '国家吊在逗号后面（极光和英仙座流星雨，德国）'),
                     ('birmingham', '地方不在这句的开头（城市风景，伯明翰市中心）'),
                     ('donaghadee', '主语一个「船」字打头，地名在逗号后'),
                     ('little_island', '把 at 直译成句中的「在」（日落在小岛…）'),
                     ('market_st', '逗号后面挂着「和，沿着」这种没整理干净的连词')]:
        out, got = cap_call(key)
        print('    送翻译: %s' % asc(got.get('INPUT', '')))
        print('    名字  : %s' % asc(got.get('NAME', '')))
        check('整理出的原文与实测那句一致（%s）' % key, got.get('INPUT', '') == EXPECT[key], asc(got.get('INPUT', '')))
        check('这种译文不收（%s）' % why, got.get('NAME', '') == '', asc(got.get('NAME', '')))

    print('    两份译文都挂着破折号（肯尼亚-夜晚的天际线）：不当名字用，交给地理词典成句')
    out, got = cap_call('kisumu')
    name = got.get('NAME', '')
    print('    送翻译: %s' % asc(got.get('INPUT', '')))
    print('    名字  : %s' % asc(name))
    check('整理出的原文与实测那句一致（kisumu）', got.get('INPUT', '') == EXPECT['kisumu'], asc(got.get('INPUT', '')))
    check('Kenya 后面接破折号也要认成国家', got.get('COUNTRY', '') == 'Kenya', asc(got.get('COUNTRY', '')))
    check('带破折号的译文不收（%s）' % '肯尼亚基苏木市——夜晚的天际线', name == '', asc(name))
    kis = repair_call('kisumu', '肯尼亚基苏木市-夜间天际线')[0]
    print('    后台补名: %s' % asc(kis))
    check('后台补出来的词典名国家在头、天际线不翻成地平线',
          kis == '肯尼亚基苏木夜色中的城市天际线', asc(kis))

    print('---- 14) 括号里只有拍摄时间的，名字里去掉（界面和文件名都另有日期）')
    out, got = cap_call('crissy')
    name = got.get('NAME', '')
    print('    送翻译: %s' % asc(got.get('INPUT', '')))
    print('    名字  : %s' % asc(name))
    check('整理出的原文与实测那句一致', got.get('INPUT', '') == EXPECT['crissy'], asc(got.get('INPUT', '')))
    check('日期括注没了', ('（2015' not in name) and ('2015年' not in name), asc(name))
    check('站名本身留着（美国旧金山…的老克里西菲尔德海岸警卫队站）',
          '老克里西菲尔德海岸警卫队站' in name, asc(name))

    print('---- 15) 尺子本身：同一句里「在」和判断句都要挡掉，地名在前的放行')
    rc, out, got = run(
        "Write-Output ('A|' + (Test-BwZhNameFluent %s %s @()))\n"
        "Write-Output ('B|' + (Test-BwZhNameFluent %s %s @()))\n"
        "Write-Output ('C|' + (Test-BwZhNameFluent %s '' @(%s)))\n"
        "Write-Output ('D|' + (Test-BwZhNameFluent %s '' @(%s)))\n"
        "Write-Output ('RUN|' + (Get-BwZhCommonRun %s %s))\n"
        % (q('泰国曼谷市中心的夕阳'), q('泰国'),
           q('日落在小岛，纽约市'), '',
           q('城市风景，伯明翰市中心'), q('inner city Birmingham'),
           q('伯明翰市中心的街景'), q('inner city Birmingham'),
           q('伯明翰市中心夜景'), q('伯明翰内城')))
    check('国家在开头 -> 通顺', got.get('A', '').strip().lower() == 'true', out.strip()[:200])
    check('句中的「在」-> 不收', got.get('B', '').strip().lower() == 'false', out.strip()[:200])
    check('地名不在开头 -> 不收', got.get('C', '').strip().lower() == 'false', out.strip()[:200])
    check('地名在开头 -> 收', got.get('D', '').strip().lower() == 'true', out.strip()[:200])
    check('两家写法不同也算同一个地名（公共片段 >=3）',
          int(got.get('RUN', 0) or 0) >= 3, got.get('RUN', ''))

    print('---- 16) 译文被挡下的老图：后台补成地理词典名，坏名字不许留在界面上')
    rc, out, got = run(REPAIR_SCRIPT)
    print('    %s' % out.strip()[:400])
    check('补之前确实是那个坏名字', got.get('BEFORE', '') == '银河娱乐城', asc(got.get('BEFORE', '')))
    check('没有国家信息时不落盘（保持待补，界面仍显示词典名）', got.get('AFTER', '') == '银河娱乐城', asc(got.get('AFTER', '')))
    check('没有国家不升 caption_version', got.get('CAPVER', '') == '', got.get('CAPVER', ''))
    check('作者与拍摄日原样保留',
          got.get('AUTHOR', '').lower() == 'true' and got.get('SHOT', '').lower() == 'true', out.strip()[:200])
    check('原始作品名原样保留（下次还能重算）',
          got.get('ORIG', '').lower() == 'true', got.get('ORIG', ''))
    check('面板显示名取的就是词典名', got.get('DISPLAY', '') == DICTNAME, asc(got.get('DISPLAY', '')))

    print('---- 17) 66 张实测里剩下的四类：形容词国家、标点后的直译、地名叠字、词典整词')
    rc, out, got = run(
        # (a) 介绍里只写形容词 Moroccan，也要认成 Morocco，否则闸门没得核对国家。
        "Write-Output ('CTRY1|' + (Get-BwCaptionCountry %s %s %s))\n"
        # (b) 但 'Spanish dance steps' 这种不是国家，不许认成 Spain。
        "Write-Output ('CTRY2|[' + (Get-BwCaptionCountry %s %s %s) + ']')\n"
        # (c) 逗号后挂「-从西南」这种标点，先抹标点再判，才算直译。
        "Write-Output ('FLU1|' + (Test-BwZhNameFluent %s '' @(%s)))\n"
        "Write-Output ('FLU2|' + (Test-BwZhNameFluent %s '' @(%s)))\n"
        # (d) 地名末段自带通名时不再叠一遍：布莱斯峡谷的峡谷 / 奥伊赫桥的桥梁 / 新加坡新加坡。
        "Write-Output ('FLOW1|' + (Get-BwFlowName %s %s ''))\n"
        "Write-Output ('FLOW2|' + (Get-BwFlowName %s %s ''))\n"
        "Write-Output ('FLOW3|' + (Get-BwFlowName %s %s %s))\n"
        # (e) valley 不许撞 alley；肯尼亚/加州这些直写国家的地名要认得出来。
        "Write-Output ('SUBJ1|' + (Get-BwSubjectName %s 'urban'))\n"
        "Write-Output ('GEO1|' + (Get-BwGeoLabel %s))\n"
        "Write-Output ('GEO2|' + (Get-BwGeoLabel %s))\n"
        % (q('Desierto del Sahara'), q('Picture taken near the Moroccan city of Merzouga'), q('Deserts / Sahara'),
           q('Spanish dance steps in the plaza'), q('A couple performing'), q('Dance'),
           q('奥奇桥-从西南'), q('Bridge of Oich'),
           q('奥伊赫桥，从西南方向看过去'), q('Bridge of Oich'),
           q('美国·布莱斯峡谷'), q('峡谷'),
           q('英国·苏格兰奥伊赫桥'), q('桥梁'),
           q('新加坡·新加坡'), q('城市天际线'), q('落日'),
           q('Just after the easing of lockdown we ventured to Ogwen Valley to catch the milky way arch'),
           q('Kisumu City, Kenya - Night Skyline'),
           q('Early Lake Reflection Shoreline Park Mountain View, California')))
    print('    %s' % out.strip()[:520])
    check('形容词 Moroccan 也认成 Morocco', got.get('CTRY1', '') == 'Morocco', asc(got.get('CTRY1', '')))
    check('Spanish dance steps 不算西班牙', got.get('CTRY2', '').strip('[]') == '', out.strip()[:520])
    check('破折号后面接「从」算直译，不收', got.get('FLU1', '').strip().lower() == 'false', out.strip()[:520])
    check('逗号后面接「从」同样不收', got.get('FLU2', '').strip().lower() == 'false', out.strip()[:520])
    check('布莱斯峡谷不再写成「峡谷的峡谷」', got.get('FLOW1', '') == '美国布莱斯峡谷', asc(got.get('FLOW1', '')))
    check('奥伊赫桥不再写成「桥的桥梁」', got.get('FLOW2', '') == '英国苏格兰奥伊赫桥', asc(got.get('FLOW2', '')))
    check('新加坡·新加坡不叠字', got.get('FLOW3', '') == '新加坡落日时分的城市天际线', asc(got.get('FLOW3', '')))
    check('Ogwen Valley 的 valley 不算 alley（街道）',
          '街道' not in got.get('SUBJ1', '') and '银河星空' in got.get('SUBJ1', ''), asc(got.get('SUBJ1', '')))
    check('Kisumu 认成肯尼亚·基苏木', got.get('GEO1', '') == '肯尼亚·基苏木', asc(got.get('GEO1', '')))
    check('Shoreline Park 认成美国·加州山景市',
          got.get('GEO2', '') == '美国·加州山景市', asc(got.get('GEO2', '')))

    print('---- 18) 译文自造的地名写法：作品名里就写着这个地名时，改用词典那套人工核过的写法')
    for key, want, why in [
            ('godafoss_island', '冰岛戈达福斯的瀑布', 'Goðafoss 被翻成「戈阿福斯岛」'),
            ('bryant', '新西兰丛林的雾气透出的阳光，布赖恩特山脉', 'Bryant Range 被翻成「布莱恩特山脉」'),
            ('minato', '日本东京港区落日时分的城市天际线', 'Minato City 被翻成「美娜多市」')]:
        out, got = cap_call(key)
        print('    送翻译: %s' % asc(got.get('INPUT', '')))
        print('    名字  : %s' % asc(got.get('NAME', '')))
        check('换成词典写法（%s）' % why, got.get('NAME', '') == want, asc(got.get('NAME', '')))
    # 反证：地名只写在介绍里、作品名没写时，不拿笼统词典名换掉整句描述（crissy field 那张）。
    # 2026-11-06 用户「两个新图源的图片，带国家地理元素」：这种整句描述照旧保留，
    # 但前面要补上国家与城市（美国旧金山），所以期望值比原来多了这一截。
    out, got = cap_call('crissy')
    check('介绍里才有地名时保留整句译文，并在前面补上国家',
          '老克里西菲尔德海岸警卫队站' in got.get('NAME', ''), asc(got.get('NAME', '')))

    print('---- 19) 后台补名别把已经够具体的老名换成笼统词典名（66 张实测里词典名更短的那些）')
    # 老名「美国布莱斯峡谷的纳瓦霍步道」地名+主体都在；词典那条线只会给「美国布莱斯峡谷」。
    b, bg = repair_call('bryce', '美国布莱斯峡谷的纳瓦霍步道', '纳瓦霍小径，布莱斯峡谷国家公园，犹他州，美国。')
    print('    补之前: %s' % asc(bg.get('BEFORE', '')))
    print('    补之后: %s' % asc(b))
    check('同一处地方且老名更具体时沿用老名', b == '美国布莱斯峡谷的纳瓦霍步道', asc(b))
    check('沿用老名也把 caption_version 升到 2', bg.get('CAPVER', '') == '2', bg.get('CAPVER', ''))
    check('面板读到的还是那个老名', bg.get('DISPLAY', '') == '美国布莱斯峡谷的纳瓦霍步道', asc(bg.get('DISPLAY', '')))
    check('说明配的是同名那份老说明', bg.get('DESCR', '') == '纳瓦霍小径，布莱斯峡谷国家公园，犹他州，美国。',
          asc(bg.get('DESCR', '')))
    check('作者与原始作品名原样保留',
          bg.get('AUTHOR', '').lower() == 'true' and bg.get('ORIG', '').lower() == 'true',
          out.strip()[:200])
    # 反证一：老名自己就不通顺（带破折号），照旧换成词典名。
    k, kg = repair_call('kisumu', '肯尼亚基苏木市-夜间天际线')
    check('老名带破折号时换成词典名', k == '肯尼亚基苏木夜色中的城市天际线', asc(k))
    # 反证二：老名夹着空格（「早期 湖 反射 海岸线 公园山景，加州」那一张），也要换掉。
    s, sg = repair_call('bryce', '早期 湖 反射 海岸线 公园山景，加州')
    print('    夹空格的老名 -> %s' % asc(s))
    check('老名夹空格时换成词典名', s == '美国布莱斯峡谷', asc(s))

    print('---- 20) 页面介绍派生的名字：带国家、和介绍对得上（用户截图那两张）')
    # 用户 2026-11-06 原话：「图片名字和原图介绍不贴切」「两个新图源的图片，带国家地理元素，
    # 图片内容的通顺描述」。老图的内嵌介绍就是页面自己那句话，名字要从它派生，且补上国家。
    desc_cases = [
        ('布鲁克林餐厅', {
            'zhdesc': '2024年9月23日晚上，纽约市西43街时代广场附近的布鲁克林餐厅。',
            'orig': 'Brooklyn Diner, New York City (2024)-L1006207',
            'raw': ('The Brooklyn Diner near Times Square on West 43rd Street in  New York City , '
                    'at night on September 23, 2024'),
            'cats': 'Featured pictures of New York City / Americana / Taken with Leica M11',
            'type': '随拍'},
         '美国纽约市西43街时代广场附近的布鲁克林餐厅'),
        ('红翼黑鸟', {
            'zhdesc': '一只红翼黑鸟在约翰海因茨国家自然保护区的木板路上鸣叫。',
            'orig': ('Male Red-winged blackbird (Agelaius phoeniceus) John Heinz National Wildlife '
                     'Refuge, Philadelphia, Pennsylvania, United States'),
            'raw': 'A Red-Winged Blackbird calling from the boardwalk at John Heinz NWR.',
            'cats': ('Agelaius phoeniceus (male) / Birds at John Heinz National Wildlife Refuge '
                     'at Tinicum'),
            'type': '万象'},
         '美国宾夕法尼亚州约翰海因茨国家自然保护区的木板路上鸣叫的红翼黑鸟'),
    ]
    for label, c, want in desc_cases:
        rc, out, got = run(DESC_TMPL % {'DESC': q(c['zhdesc']), 'ORIG': q(c['orig']),
                                        'RAW': q(c['raw']), 'CATS': q(c['cats']),
                                        'TYPE': q(c['type'])})
        print('    %s -> %s   (词典那条线: %s)' %
              (label, asc(got.get('DISP', '')), asc(got.get('SUBJ', ''))))
        check('介绍派生的名字带国家且贴着介绍（%s）' % label,
              got.get('DISP', '') == want, asc(got.get('DISP', '')))
        check('名字里没有拉丁字母（%s）' % label,
              bool(got.get('DISP', '')) and not re.search(r'[A-Za-z]', got.get('DISP', '')),
              asc(got.get('DISP', '')))
        # 反证：英文原名里明明写着年份，名字不能再只剩「2024」。
        check('名字不是光秃秃的年份（%s）' % label, got.get('DISP', '') not in ('2024', ''), asc(got.get('DISP', '')))

    print('---- 21) 面板兜底：纯数字/英文原名不许当标题（用户截图「2024」）')
    rc, out = node_panel_check()
    got = dict(l.split('|', 1) for l in out.splitlines() if '|' in l)
    print('    %s' % out.strip()[:300])
    check('英文原名只剩年份时，标题给稳定的中文场景名',
          bool(re.match(r'^[\u4e00-\u9fa5]{2,}$', got.get('A', ''))) and got.get('A', '') != '2024',
          asc(got.get('A', '')))
    check('metadata 里的 display 是纯数字也不收',
          bool(re.match(r'^[\u4e00-\u9fa5]{2,}$', got.get('B', ''))) and got.get('B', '') != '2024',
          asc(got.get('B', '')))
    check('metadata 里有好名字时照用', got.get('C', '') == '美国纽约市西43街时代广场附近的布鲁克林餐厅',
          asc(got.get('C', '')))
    check('老图文件名里的中文照样能用', got.get('D', '') == '雄性红翅黑鸟阿杰莱乌斯腓尼基人约翰海因茨国',
          asc(got.get('D', '')))

    print('---- 22) 三要素终检（2026-11-07）：国家 / 地理 / 主题，像素不进名字')
    triad_cases = [
        ('冰岛戈达福斯的瀑布', True),
        ('瑞典吕塞基尔的极光全景', True),
        ('瑞士苏黎世的动物园', True),
        ('美国纽约市西43街时代广场附近的布鲁克林餐厅', True),
        ('尼泊尔珠穆朗玛峰的喜马拉雅群山航拍', True),
        ('瑞士苏黎世动物园的雪豹', True),      # 三要素齐全
        ('英国伦敦泰晤士河畔的塔桥', True),
        ('日本京都仁和寺观音殿外立面的佛教旗', True),
        ('新加坡南部山脊的亨德森波浪桥', True),
        ('英国福伊南街的街景', True),
        ('火山熔岩', False),                 # 没国家
        ('动物园', False),                   # 没国家也没地点
        ('老城', False),
        ('德国的码头', False),               # 有国家，但国名后只剩泛主体
        ('德国落日时分的船只', False),
        ('德国的建筑立面', False),
        ('奥维耶多大教堂外立面', False),      # 有地点，没国家
        ('肯尼亚基苏木市-夜间天际线', False),  # 破折号，不通顺
        ('日落在小岛，纽约市', False),        # 英文语序
        ('冰岛戈达福斯瀑布3840像素', False),   # 像素不是命名要素
        ('英国南街的场景', False),            # 「场景」是空词，没写出画面主体
        ('德国的风景', False),                # 空词 + 泛主体
        ('德国勃兰登堡门', False),            # 只有国家 + 地名，没有主题
        ('', False),
    ]
    expr = '\n'.join("Write-Output ('T%d|' + (Test-BwNameTriad %s '' ''))"
                     % (i, q(n)) for i, (n, _) in enumerate(triad_cases))
    rc, out, got = run(expr)
    for i, (n, want) in enumerate(triad_cases):
        check('三要素 %s -> %s' % (asc(n), want),
              got.get('T%d' % i, '').strip().lower() == str(want).lower(),
              '%s / got=%s / %s' % (asc(n), got.get('T%d' % i, ''), out.strip()[:200]))

    print()
    if FAILS:
        print('未通过 %d 项: %s' % (len(FAILS), ' / '.join(FAILS)))
        return 1
    print('全部通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())
