#!/usr/bin/python3
"""给 e5 的短信转发脚本打补丁：投递失败不再丢弃，按退避策略排队重试。

原生实现 /usr/libexec/unisoc-modem/sms-forward 只在事件到来时投递一次，
失败就记一条结果、把消息 ID 烧进 claimed-ids，之后永不重试。这个补丁只做
三件事，不改原有投递逻辑：

  1. 投递失败（网络不通 / 服务端拒绝 / DNS 失败）时，把消息写进 queue 目录；
  2. 常驻 worker 每轮检查队列，按 30s/2m/10m/30m/2h/6h 退避补发；
  3. 补发过程写 /etc/unisoc-modem/forward/delivery.log，重启后仍可回溯。

补丁幂等：已打过直接退出。锚点对不上（上游脚本改版）就放弃并说明原因，
绝不写一个半成品进去。回滚：cp /etc/e5/mms/sms-forward.orig <目标>。
"""

import os
import shutil
import sys

TARGET = os.environ.get('E5_FORWARD_TARGET', '/usr/libexec/unisoc-modem/sms-forward')
BACKUP = os.environ.get('E5_FORWARD_BACKUP', '/etc/e5/mms/sms-forward.orig')
MARK = '# e5-forward-queue-v3'

BLOCK = r'''# e5-forward-queue-v3: 投递失败进入队列，按退避重试（由 /etc/e5/mms 注入）
QUEUE=$BASE/queue
DELIVERY_LOG=$BASE/delivery.log
RETRY_LIMIT=${MU300_FORWARD_RETRY_LIMIT:-7}
queue_log() {
    ensure_base || return 0
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$DELIVERY_LOG" 2>/dev/null || :
    _qsize=$(wc -c < "$DELIVERY_LOG" 2>/dev/null || echo 0)
    number "$_qsize" && [ "$_qsize" -gt 204800 ] &&
        { tail -c 102400 "$DELIVERY_LOG" > "$DELIVERY_LOG.tmp.$$" 2>/dev/null &&
            mv -f "$DELIVERY_LOG.tmp.$$" "$DELIVERY_LOG"; } || :
    return 0
}
retry_delay() { # 第几次尝试 → 等多少秒再试
    case "$1" in
        1) echo 30 ;; 2) echo 120 ;; 3) echo 600 ;;
        4) echo 1800 ;; 5) echo 7200 ;; *) echo 21600 ;;
    esac
}
retryable() {
    case "$1" in
        delivery_failed|invalid_destination|service_rejected|service_answer_missing|source_unavailable) return 0 ;;
    esac
    return 1
}
enqueue_retry() { # kind, from, text, date —— 调用方已持有 state.lock
    retryable "$DELIVER_RESULT" || return 1
    ensure_base || return 1
    mkdir -p "$QUEUE" && chmod 700 "$QUEUE" || return 1
    # 队列 ID 必须唯一：同一秒里两条短信（双卡并发、运营商补发）用「秒.$$」会撞名，
    # 后写的一条把前一条覆盖掉，等于丢消息。撞了就加序号，直到名字不存在。
    _qn=0
    while :; do
        _qid="$(date +%s).$$.$_qn"
        [ -e "$QUEUE/$_qid" ] || break
        _qn=$((_qn + 1))
    done
    json_init
    json_add_string kind "$1"
    json_add_string from "$2"
    json_add_string text "$3"
    json_add_string time "${4:-}"
    json_add_string profile "${profile:-shared}"
    json_add_int card "${MU300_SIM_SLOT:-0}"
    json_add_int attempts 1
    json_add_int next "$(( $(date +%s) + $(retry_delay 1) ))"
    # 临时文件用隐藏名：qlen/queue_report 的 glob 不匹配点开头的文件，
    # 写到一半的条目不会被当成待发消息，也不会让按需拨号误判队列非空。
    json_dump > "$QUEUE/.$_qid.tmp" && mv -f "$QUEUE/.$_qid.tmp" "$QUEUE/$_qid" \
        || { rm -f "$QUEUE/.$_qid.tmp"; return 1; }
    queue_log "排队重试 id=$_qid 原因=$DELIVER_RESULT 计划 $RETRY_LIMIT 次"
}
drain_queue() { # 每轮只补一条，避免长时间占着 state.lock 挡住新短信
    [ -d "$QUEUE" ] || return 0
    _qnow=$(date +%s)
    for _qfile in "$QUEUE"/*; do
        [ -f "$_qfile" ] || continue
        json_load_file "$_qfile" 2>/dev/null || { rm -f "$_qfile"; continue; }
        json_get_vars kind from text time profile card attempts next
        number "$attempts" || attempts=0
        number "$next" || next=0
        # 数据从断开到拨上来这段时间，退避计时毫无意义：网络刚可用就补发。
        # MU300_FORCE_RETRY=1 由按需拨号守护在刚拨通时传进来，只跳过一次等待。
        if [ "$_qnow" -lt "$next" ] && [ "${MU300_FORCE_RETRY:-0}" != 1 ]; then
            continue
        fi
        _qslot=$card
        read_mode && select_profile "${profile:-shared}" || { rm -f "$_qfile"; continue; }
        [ "$_qslot" = 1 ] && STATE=$BASE/state.sim1
        load_config || return 0
        if [ "$enabled" != 1 ]; then
            rm -f "$_qfile"
            queue_log "转发已关闭，放弃补发 $(basename "$_qfile")"
            continue
        fi
        export MU300_SIM_SLOT=$_qslot
        deliver "$kind" "$from" "$text" "$time" || :
        if [ "$DELIVER_RESULT" = sent ]; then
            rm -f "$_qfile"
            record_delivery "$kind" || :
            queue_log "补发成功 第$((attempts + 1))次尝试 $(basename "$_qfile")"
        else
            attempts=$((attempts + 1))
            if [ "$attempts" -ge "$RETRY_LIMIT" ]; then
                rm -f "$_qfile"
                record_delivery "$kind" || :
                queue_log "补发放弃 共$attempts次 最后原因=$DELIVER_RESULT $(basename "$_qfile")"
            else
                json_init
                json_add_string kind "$kind"
                json_add_string from "$from"
                json_add_string text "$text"
                json_add_string time "$time"
                json_add_string profile "${profile:-shared}"
                json_add_int card "$_qslot"
                json_add_int attempts "$attempts"
                json_add_int next "$(( _qnow + $(retry_delay "$attempts") ))"
                # 同样用隐藏临时名，避免被其他进程的 glob 当成一条待发消息读到半截
                _qtmp="$(dirname "$_qfile")/.$(basename "$_qfile").tmp.$$"
                json_dump > "$_qtmp" && mv -f "$_qtmp" "$_qfile" || rm -f "$_qtmp"
                queue_log "补发失败 第$attempts次 原因=$DELIVER_RESULT 稍后再试 $(basename "$_qfile")"
            fi
        fi
        select_profile shared >/dev/null 2>&1 || :
        load_config || :
        return 0
    done
    return 0
}
queue_report() {
    _qn=0
    json_init
    if [ -d "$QUEUE" ]; then
        for _qfile in "$QUEUE"/*; do [ -f "$_qfile" ] && _qn=$((_qn + 1)); done
    fi
    json_add_int pending "$_qn"
    json_add_int limit "$RETRY_LIMIT"
    json_add_array items
    if [ -d "$QUEUE" ]; then
        for _qfile in "$QUEUE"/*; do
            [ -f "$_qfile" ] || continue
            json_load_file "$_qfile" 2>/dev/null || continue
            json_get_vars from text attempts next
            json_add_object ''
            json_add_string from "$from"
            json_add_string preview "$(printf '%s' "$text" | cut -c1-60)"
            json_add_int attempts "${attempts:-0}"
            json_add_int next "${next:-0}"
            json_close_object
        done
    fi
    json_close_array
    json_dump
}
queue_retry() {
    ensure_base || { reply_error forward_storage_failed; return; }
    exec 8> "$BASE/state.lock"
    flock -x 8 || exit 1
    drain_queue || :
    queue_report
}
'''

# 三处锚点：失败入队、守护进程补发、命令行入口
EVENT_BEFORE = '''    deliver sms "$_sender" "$_body" "$_date" || :
    record_delivery sms || :
    write_result "$DELIVER_RESULT" "$power_last_result" || :
'''
EVENT_AFTER = EVENT_BEFORE + '''    retryable "$DELIVER_RESULT" && enqueue_retry sms "$_sender" "$_body" "$_date" || :
'''

DAEMON_BEFORE = '''        # Idle sleep must not retain the singleton lock after procd stops us.
        sleep "${MU300_FORWARD_POLL:-5}" 8>&- 9>&-
'''
DAEMON_AFTER = '''        drain_queue || :
        # Idle sleep must not retain the singleton lock after procd stops us.
        sleep "${MU300_FORWARD_POLL:-5}" 8>&- 9>&-
'''

CLI_BEFORE = '''    log-clear) clear_history ;;
'''
CLI_AFTER = '''    log-clear) clear_history ;;
    queue) read_mode && select_profile "${2:-shared}" >/dev/null 2>&1; load_config; queue_report ;;
    queue-retry) queue_retry ;;
'''


def fail(message):
    print('patch forward: ' + message, file=sys.stderr)
    sys.exit(1)


def main():
    if not os.path.exists(TARGET):
        fail('找不到 %s' % TARGET)
    with open(TARGET, encoding='utf-8', newline='') as stream:
        original = stream.read()
    if MARK in original:
        print('already')
        return 0
    text = original
    if 'e5-forward-queue-' in original:
        # 从旧版补丁升级：旧补丁的代码已在文件里，锚点必然对不上。
        # 用留着的上游原件重新打一遍，绝不在旧补丁上面叠。
        clean = ''
        if os.path.exists(BACKUP):
            with open(BACKUP, encoding='utf-8', newline='') as stream:
                clean = stream.read()
        if 'e5-forward-queue-' in clean:
            fail('旧补丁的原件备份已被覆盖，请从固件重新解出 sms-forward 再装')
        if not clean:
            fail('目标里已有旧补丁但没有原件备份 %s，请先还原原件' % BACKUP)
        text = clean
    for name, anchor in [('process_event', EVENT_BEFORE),
                         ('run_daemon', DAEMON_BEFORE),
                         ('cli', CLI_BEFORE)]:
        if text.count(anchor) != 1:
            fail('锚点 %s 不唯一（上游脚本可能改版），未改动任何文件' % name)
    patched = text.replace(EVENT_BEFORE, EVENT_AFTER, 1)
    patched = patched.replace(DAEMON_BEFORE, DAEMON_AFTER, 1)
    patched = patched.replace(CLI_BEFORE, CLI_AFTER, 1)
    head = 'process_event() {\n'
    if patched.count(head) != 1:
        fail('process_event 定义不唯一，未改动任何文件')
    patched = patched.replace(head, BLOCK + head, 1)

    # 只在原件干净时刷新备份：系统升级后脚本会变，回滚要回到当前这版。
    # 若本次是从旧补丁升级，目标文件已被改过，不能拿它覆盖原件备份。
    if 'e5-forward-queue-' not in original:
        shutil.copy2(TARGET, BACKUP)
        os.chmod(BACKUP, 0o755)
    temporary = TARGET + '.new'
    with open(temporary, 'w', encoding='utf-8', newline='') as stream:
        stream.write(patched)
    os.chmod(temporary, 0o755)
    os.replace(temporary, TARGET)
    print('patched')
    return 0


if __name__ == '__main__':
    sys.exit(main())
