# -*- coding: utf-8 -*-
"""发版脚本"推完复核远端 sha"这一步的单测 (2026-11-05 加).

起因: 第一次用 2026-10-26 重构后的 tools/publish.py 发 v2.4.3, tag 明明已经推到
GitCode（`git ls-remote --tags origin` 看得见）, 脚本却抛
`RuntimeError: 推送 v2.4.3 -> origin 没生效`, 整条发布流水线当场停在第③步。
根因在它复核的那一行: 把 `ls-remote` 的输出 `.split()` 摊平后取 `[1:2]`,
拿到的是**第一行的 ref 名**（`refs/tags/v2.4.3`）而不是 sha —— 永远比不中。
annotated tag 还会多返回一行 `^{}`（剥出来的 commit）, 更加没法按位置取。

这里全是不碰 git、不碰网络的纯字符串用例: 喂假的 ls-remote 输出就能测。

用法:
    python tests\\test_publish_sha.py
"""
import os
import sys

sys.stdout.reconfigure(encoding='utf-8')

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.environ.get('BW_SRC') or os.path.dirname(HERE)
sys.path.insert(0, os.path.join(SRC, 'tools'))

import publish  # noqa: E402

ok_all = True


def check(name, cond, extra=''):
    global ok_all
    ok_all = ok_all and bool(cond)
    print(('  [通过] ' if cond else '  [失败] ') + name + (('  ' + str(extra)) if extra else ''))


def title(t):
    print('\n' + t)


TAG_SHA = 'db18949d5a7e613189338d3ae2c2978e6fd612b2'
PEELED_SHA = 'd0a77d5682ef3cc82a0722ac04b77d8360417dc4'

title('1. annotated tag 返回两行 —— 要比的是 tag 对象那一行, 不是 ^{}、也不是 ref 名')
_two = '%s\trefs/tags/v2.4.3\n%s\trefs/tags/v2.4.3^{}\n' % (TAG_SHA, PEELED_SHA)
check('取到 tag 对象的 sha', publish.pick_remote_sha(_two, 'v2.4.3') == TAG_SHA,
      publish.pick_remote_sha(_two, 'v2.4.3')[:16] + '…')
check('不会把 ref 名当成 sha 返回（老写法就是栽在这）',
      publish.pick_remote_sha(_two, 'v2.4.3') != 'refs/tags/v2.4.3')
check('两行顺序反过来也一样',
      publish.pick_remote_sha('%s\trefs/tags/v2.4.3^{}\n%s\trefs/tags/v2.4.3\n'
                              % (PEELED_SHA, TAG_SHA), 'v2.4.3') == TAG_SHA)

title('2. 分支（只有一行，ref 是 refs/heads/main）')
_one = '%s\trefs/heads/main\n' % PEELED_SHA
check('按短名 main 也能认', publish.pick_remote_sha(_one, 'main') == PEELED_SHA)
check('按全名 refs/heads/main 同样认',
      publish.pick_remote_sha(_one, 'refs/heads/main') == PEELED_SHA)

title('3. 远端根本没有这个 ref —— 必须返回空串，不许"比出一个假通过"')
check('输出为空', publish.pick_remote_sha('', 'v2.4.3') == '')
check('输出只有别的 ref', publish.pick_remote_sha(
    '%s\trefs/tags/v2.4.2\n%s\trefs/tags/v2.4.2^{}\n' % (TAG_SHA, PEELED_SHA),
    'v2.4.3') == '')
check('行里没有第二列（脏输出）', publish.pick_remote_sha('garbage-line', 'main') == '')

title('4. 只有 ^{} 那一行的少见的场合 —— 退让一步用剥出来的 sha')
check('peeled 兜底', publish.pick_remote_sha(
    '%s\trefs/tags/v2.4.3^{}\n' % PEELED_SHA, 'v2.4.3') == PEELED_SHA)

title('5. 回放 2026-11-05 发布现场（GitCode 上真返回过的那两行）')
_want = TAG_SHA            # `git rev-parse v2.4.3` 给的就是 tag 对象 sha
check('复核判定"已生效"，不再误报推送失败',
      publish.pick_remote_sha(_two, 'v2.4.3') == _want)
check('而老写法会拿 ref 名去比 sha —— 必然假失败',
      (_two.split() or ['', ''])[1:2] != [_want])

print('\n' + '-' * 70)
print('结果: ' + ('全部通过' if ok_all else '有失败'))
sys.exit(0 if ok_all else 1)
