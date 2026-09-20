# -*- coding: utf-8 -*-
import io, os, subprocess

MSG = """v1.6.2: 定位收口到「图片文件夹\\壁纸」, 没有就自动创建, 不再另起路径

用户拍板 A 方案: 目标始终是那台机器的「图片」文件夹下面的「壁纸」,
没有这个路径就自动创建, 不另外在盘根造 <盘>\\图片\\壁纸。

- 新增 Get-BwPicturesLeaf: 取系统「图片」文件夹自己的名字 (本机叫「我的图片」,
  别人那台可能叫「图片」/「Pictures」)。兜底造文件夹时跟着这台机器的叫法走,
  不再一刀切写成「图片」—— 那正是"明明有「我的图片」, 盘根却多出个「图片」"的由来。
- 扫描补一档: 盘上散着图片文件、但没专门建图片文件夹的, 也算这个盘,
  归到 <盘>\\<图片文件夹名>\\壁纸 (用户的意思: 一个现成的都没有, 程序自己造一个)。
- 修盘符口径 (Get-BwSysDriveLetter / Get-BwDriveLetter): 以前一处拿 C: 一处拿 C,
  系统盘从来没被排除过, 于是"图片文件夹还在 C 盘"的电脑反而被判定成
  「本来就在系统盘以外」, 老老实实往 C 盘塞壁纸 —— 与用户的要求正好相反。
- 设置 [3] 改位置时传入当前位置作建议; 候选里摆出「已有图片文件夹」。
  以前传的是空建议, 列表里没有建议标记, 用户只能猜着挑, 挑错就多一个空壳。
- 菜单 A/B 三态: 开机自动换开着、后台却没跑时, [A] 拉起后台和 [B] 关掉同时给出
  (以前只摆 [B], 首页却写"按 [A] 开", 用户照着按 A 只能靠猜)。
- 措辞: 去掉"后台还没启动"(菜单开着不等于后台在跑), 改成"后台这会儿没在跑"。

三档实测:
  本机(图片文件夹在 F)               -> F:\\我的图片\\壁纸
  别人的电脑(图片还在 C 盘)          -> F:\\我的图片\\壁纸
  全新机器(一个现成图片文件夹都没有) -> C:\\Users\\xxx\\Pictures\\壁纸 (不再另造)

语法 0 错误; exe 实机测试 6 组全过; zip 7.45MB CRC OK; 版本资源 1.6.2。
按规矩隔天发布, 本提交只落在本地, 未推送。
"""

p = r'F:\wp-src\_cmsg.txt'
with io.open(p, 'w', encoding='utf-8') as f:
    f.write(MSG)

GIT = r'C:\Users\kele551\.workbuddy\binaries\PortableGit\versions\1.2.0\mingw64\bin\git.exe'
env = dict(os.environ)
env['GIT_EXEC_PATH'] = r'C:/Users/kele551/.workbuddy/binaries/PortableGit/versions/1.2.0/mingw64/bin'

def g(args):
    r = subprocess.run([GIT] + args, cwd=r'F:\wp-src', capture_output=True,
                       env=env, encoding='utf-8', errors='replace')
    return r.returncode, (r.stdout or '') + (r.stderr or '')

print('--- add ---');  print(g(['add', '-A'])[1])
print('--- commit ---')
print(g(['-c', 'user.name=kele551', '-c', 'user.email=75219857@qq.com',
         'commit', '-F', p])[1])
print('--- status ---'); print(g(['status', '--short'])[1])
print('--- log ---');    print(g(['log', '--oneline', '-3'])[1])
os.remove(p)
