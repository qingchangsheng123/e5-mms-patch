#!/usr/bin/env python3
"""信息屏补丁（v1.0.10）：信号格不再空窗，去掉从未部署的 8089 通道。

在设备上跑（root）：

    python3 /etc/e5/mms/patch-screen.py            # 打补丁，已打过就跳过
    python3 /etc/e5/mms/patch-screen.py --revert   # 用备份恢复

改动四处，每个锚点必须刚好命中 1 次，命中不到就跳过并说明原因（原厂换版后
结构变了，宁可不动也不猜）：

1. api.uc sim_status()：熄屏快照超过 15 s 时保留最后已知读数（present /
   registration / tech / signal），只标 stale。原来直接返回空 signal，而
   t551m-sim-status 熄屏时 60 s 才刷一次，亮屏那几秒信号格必然 0 格。
2. app.js renderBar()：stale 不再直接归零，用最后一次 rsrp 折算并把信号格
   半透明；rsrp 缺失才回落 m.quality。
3. transport.js：8089 的 WebSocket 从未部署，每次加载都在重连并刷 console
   错误；改为原生 fetch 直通。
4. calls.js：SSE 首次失败即关闭事件源，交给已有的轮询兜底，不再自动重连。
"""
import os
import re
import shutil
import sys

SCREEN = "/usr/share/e5-infoscreen"
API = SCREEN + "/api.uc"
APP = SCREEN + "/www/app.js"
TRANS = SCREEN + "/www/transport.js"
CALLS = SCREEN + "/www/calls.js"
BACKUP = "/root/e5-backup/screen"

MARK_API = "Dark-screen snapshots are up to 60 s old"
MARK_APP = "A dark-screen snapshot can be a minute old"
MARK_TRANS = "A WebSocket sidecar on 8089 was planned"
MARK_CALLS = "if(stream){stream.close();stream=null;}"

REVERT = "--revert" in sys.argv


def backup(path):
    dst = os.path.join(BACKUP, path.lstrip("/"))
    if os.path.exists(dst):
        return
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(path, dst)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def write(path, text):
    tmp = path + ".e5new"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    os.replace(tmp, path)


def patch_api():
    s = read(API)
    if MARK_API in s:
        print("api.uc: 已打过，跳过")
        return
    old = ("\t\tif (s == null || s.slot != slot || now - s.updated > 15 || now < s.updated)\n"
           "\t\t\treturn { slot, data: slot == active, registration: 'unknown', stale: true, signal: {} };\n"
           "\t\treturn { ...s, data: slot == active, stale: false };")
    new = ("\t\tif (s == null || s.slot != slot)\n"
           "\t\t\treturn { slot, data: slot == active, registration: 'unknown', stale: true, signal: {} };\n"
           "\t\t// Dark-screen snapshots are up to 60 s old (t551m-sim-status DIM-QUIET).\n"
           "\t\t// Keep the last known readings and mark them stale instead of blanking the\n"
           "\t\t// card: an empty signal reads as \"no signal\" on the bar the instant the\n"
           "\t\t// screen lights up, seconds before the first fresh poll lands.\n"
           "\t\tif (now - s.updated > 15 || now < s.updated)\n"
           "\t\t\treturn { ...s, data: slot == active, stale: true };\n"
           "\t\treturn { ...s, data: slot == active, stale: false };")
    n = s.count(old)
    if n != 1:
        print("api.uc: 锚点命中 %d 次（应为 1），跳过" % n)
        return
    backup(API)
    write(API, s.replace(old, new))
    print("api.uc: 已补（熄屏保留最后读数）")


def patch_app():
    s = read(APP)
    if MARK_APP in s:
        print("app.js: 已打过，跳过")
        return
    old = ("\tconst q = single ? (single.stale || single.error || single.signal?.rsrp == null ? 0 : "
           "Math.max(0, Math.min(100, (single.signal.rsrp + 120) * 2.5))) : (m.quality ?? 0);\n")
    new = ("\t// A dark-screen snapshot can be a minute old (t551m-sim-status polls\n"
           "\t// every 60 s with the backlight off). Show its last reading, dimmed,\n"
           "\t// instead of dropping to zero bars until the first fresh poll lands.\n"
           "\tconst rsrp = single && !single.error ? single.signal?.rsrp : null;\n"
           "\tconst q = rsrp != null ? Math.max(0, Math.min(100, (rsrp + 120) * 2.5)) : (m.quality ?? 0);\n"
           "\t$('bar-bars').style.opacity = single?.stale ? '0.55' : '';\n")
    n = s.count(old)
    if n != 1:
        print("app.js: 锚点命中 %d 次（应为 1），跳过" % n)
        return
    backup(APP)
    write(APP, s.replace(old, new))
    print("app.js: 已补（stale 不再归零）")


def patch_transport():
    s = read(TRANS)
    if MARK_TRANS in s:
        print("transport.js: 已打过，跳过")
        return
    backup(TRANS)
    write(TRANS, """/* The screen page is served by the API instance on 127.0.0.1:8088 and reads
   everything over plain /api/* GETs. A WebSocket sidecar on 8089 was planned
   but never deployed: connecting to it failed on every load and cost each page
   a 3 s retry window plus a console network error. Native fetch covers the
   same reads, so the shim now just forwards. */
'use strict';
window.T551MTransport = { fetch: (input, options) => window.fetch(input, options) };
""")
    print("transport.js: 已替换（不再连 8089）")


def patch_calls():
    s = read(CALLS)
    if MARK_CALLS in s:
        print("calls.js: 已打过，跳过")
        return
    old = "stream.onerror=()=>{streaming=false;pollCalls();};"
    new = "stream.onerror=()=>{streaming=false;if(stream){stream.close();stream=null;}pollCalls();};"
    if s.count(old) != 1:
        print("calls.js: 锚点不唯一，跳过")
        return
    backup(CALLS)
    write(CALLS, s.replace(old, new))
    print("calls.js: 已补（SSE 失败不再重连）")


def revert():
    for path in (API, APP, TRANS, CALLS):
        src = os.path.join(BACKUP, path.lstrip("/"))
        if os.path.exists(src):
            shutil.copy2(src, path)
            print("恢复 %s" % path)
        else:
            print("没有备份，跳过 %s" % path)


if REVERT:
    revert()
else:
    for fn in (patch_api, patch_app, patch_transport, patch_calls):
        try:
            fn()
        except Exception as e:
            print("%s: 出错，跳过（%r）" % (fn.__name__, e))
