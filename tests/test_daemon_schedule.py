# -*- coding: utf-8 -*-
"""守护进程"下一轮什么时候跑"的调度单测 (2026-11-05 加).

起因(用户反馈): 前一天在必应模式里手动挑了一张**别的日期**的必应图, 第二天早上
第一次开机不换当日必应图, 非得手动切到聚焦再切回必应才换得动。
根因: 必应模式把间隔钉成 1440 分钟, 而守护进程原来只按「上次换图 + 间隔」决定
什么时候跑第一轮 —— 前一天 17:20 手动挑图把 last_swap 推到 17:20, 下一轮就排到
第二天 17:20, 早上开机压根不进轮换, core.ps1 的「每天第一次 -> 必应当日图」
「开机校对填充方式」「必应模式重启贴回」全都没机会执行。

这里的用例全是纯函数 + 临时文件: 不睡真觉、不联网、不碰端口、不读系统时间,
所以换机器、换时钟、CI 上跑结果都一样。

用法:
    python tests\\test_daemon_schedule.py
"""
import io
import json
import os
import sys
import tempfile

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.environ.get('BW_SRC') or os.path.dirname(HERE)
sys.path.insert(0, SRC)

import launcher  # noqa: E402

ok_all = True


def check(name, cond, extra=''):
    global ok_all
    ok_all = ok_all and bool(cond)
    print(('  [通过] ' if cond else '  [失败] ') + name + (('  ' + str(extra)) if extra else ''))


def title(t):
    print('-' * 70)
    print(t)


# 假时钟: 用一个固定的"现在", 所有断言都比对这个基准, 与本机时间无关
NOW = 1_000_000.0
MIN = 60.0
HOUR = 3600.0


def ts(offset_seconds):
    return NOW + offset_seconds


# ============ 1. 复现用户的场景 ============
title('1. 必应模式 + 前一天手动挑过图 -> 开机必须立刻跑一轮 (回归用例)')
# 现场还原: 11-04 17:20:55 手动设为壁纸, 必应模式 gap=1440 分钟,
# last_bing_date 还停在 11-04, 守护进程 11-05 08:48 起来。
cycle_at = 17.5 * HOUR          # 「上次换图 + 24 小时」= 今晚 17:30 才到点
t = launcher.compute_target(NOW, ts(cycle_at), True, 0.0, True, 0.0)
check('开机第一轮立刻到点 (不等今晚 17:30)', t == NOW, t - NOW)
# 只靠"本次开机"这一个触发也必须够 —— 万一 state 里 last_bing_date 已经是今天
t2 = launcher.compute_target(NOW, ts(cycle_at), False, 0.0, True, 0.0)
check('仅"本次开机没跑过"也立刻到点', t2 == NOW, t2 - NOW)
# 反过来: 只靠跨天触发也够 (守护进程被菜单当场拉起来, 不算开机第一次)
t3 = launcher.compute_target(NOW, ts(cycle_at), True, 0.0, False, 0.0)
check('仅"今天还没换必应当日图"也立刻到点', t3 == NOW, t3 - NOW)

# ============ 2. 不打扰 ============
title('2. 今天已经换过必应当日图 + 本次开机也跑过了 -> 不许提前跑')
t = launcher.compute_target(NOW, ts(cycle_at), False, 0.0, False, 0.0)
check('回到原节拍 (今晚 17:30)', t == ts(cycle_at), t - cycle_at)
# 聚焦模式 30 分钟间隔: 到点才跑, 触发条件不该把它提前
t = launcher.compute_target(NOW, ts(5 * MIN), False, 0.0, False, 0.0)
check('节拍没到点就不动 (还剩 5 分钟)', t == ts(5 * MIN), t - 5 * MIN)

# ============ 3. 断网退避 ============
title('3. 跨天触发没兑现(断网/下载失败) -> 阶梯退避, 不许空转')
t = launcher.compute_target(NOW, ts(cycle_at), True, ts(15 * MIN), False, 0.0)
check('退避期内不跑 (等到 15 分钟后)', t == ts(15 * MIN), t - 15 * MIN)
t = launcher.compute_target(NOW, ts(cycle_at), True, ts(-10 * MIN), False, 0.0)
check('退避时刻已过 -> 立刻跑 (min 取的是较早的那个)', t == NOW, t - NOW)
ladder = [launcher.daily_retry_seconds(i) for i in range(6)]
check('退避阶梯 5/15/30/60/60/60 分钟',
      ladder == [300, 900, 1800, 3600, 3600, 3600], ladder)
check('失败次数为负也不崩', launcher.daily_retry_seconds(-3) == 300)

# ============ 4. 人不在 ============
title('4. 人不在/锁屏时三个触发一起推后 -> 保持"5 分钟看一眼", 不空跑')
away = ts(5 * MIN)
t = launcher.compute_target(NOW, away, True, away, True, away)
check('离开时 earliest = 5 分钟后 (不是 now)', t == away, t - NOW)
t = launcher.compute_target(NOW, ts(24 * HOUR), True, ts(-1 * HOUR), True, 0.0)
check('人在场时开机触发照样立刻跑 (退避已过期)', t == NOW, t - NOW)

# ============ 5. last_bing_date 读法 ============
title('5. read_last_bing_date: 认 state.json 的记账, 读不到就当"今天还没换过"')
root = tempfile.mkdtemp(prefix='bwsched_')
p = os.path.join(root, 'state.json')


def write_state(obj):
    with io.open(p, 'w', encoding='utf-8-sig') as f:
        f.write(json.dumps(obj, ensure_ascii=False))


write_state({'last_bing_date': '2026-11-05'})
check('正常读出日期', launcher.read_last_bing_date(root) == '2026-11-05')
write_state({'last_bing_date': ''})
check('空字段 -> 空串 (守护进程会立刻跑一轮补上)', launcher.read_last_bing_date(root) == '')
write_state({})
check('缺字段 -> 空串', launcher.read_last_bing_date(root) == '')
os.remove(p)
check('state.json 不存在 -> 空串', launcher.read_last_bing_date(root) == '')
write_state('{坏掉的 json')
check('state.json 读坏了 -> 空串, 不抛异常', launcher.read_last_bing_date(root) == '')

title('6. last_swap 读法没被我改坏 (节拍的地基)')
write_state({'last_swap': '2026-11-04 17:20:55', 'last_bing_date': '2026-11-04'})
got = launcher.read_last_swap(root)
check('last_swap 解析成功', got is not None and got.strftime('%Y-%m-%d %H:%M:%S') == '2026-11-04 17:20:55', got)
check('跨天记账照旧读得到 (11-04)', launcher.read_last_bing_date(root) == '2026-11-04')

print('-' * 70)
print('结果: ' + ('全部通过' if ok_all else '有用例失败'))
sys.exit(0 if ok_all else 1)
