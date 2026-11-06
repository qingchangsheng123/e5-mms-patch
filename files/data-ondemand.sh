#!/bin/sh
# e5-data-ondemand —— 按需蜂窝数据
#
# 背景：sleep16 的基带驱动只要 PDP 保持激活，CP 每 ~26s 会通过 smsg 唤醒 SIPA，
# 每次约 10s、900mW。实测：数据连接空闲时整机在 320-930mW 之间跳；
# 数据断开后稳定 283mW。而拨号只要 6 秒。短信走信令通道，与 PDP 无关，
# 断开数据不影响收短信。
#
# 做法：平时断开 wan；转发队列里有待补发的短信就拨号、补发、再挂断。
#
#   data-ondemand.sh run        前台守护（procd 用）
#   data-ondemand.sh once       只跑一轮，便于调试
#   data-ondemand.sh status     当前状态
#   data-ondemand.sh up|down    手动拨号/断开

BASE=/etc/unisoc-modem/forward
QUEUE=$BASE/queue
IFACE=sipa_eth0
LOG=/etc/e5/power/data-ondemand.log
IDLE_SECS=${IDLE_SECS:-90}   # 队列空后再保持多久才挂断（秒）
CHECK=${CHECK:-5}            # 轮询间隔
DIAL_TRIES=15                # 拨号最多等几秒
FAIL_BACKOFF=90              # 拨号失败后的退避（秒）

is_up() { [ "$(cat /sys/class/net/$IFACE/operstate 2>/dev/null)" = up ]; }

qlen() { ls -A "$QUEUE" 2>/dev/null | wc -l | tr -d ' '; }

log() {
	# 256KB 轮转
	if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
		tail -c 131072 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
	fi
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

dial() {
	is_up && return 0
	log "拨号（队列 $(qlen) 条待发）"
	ifup wan >/dev/null 2>&1
	i=0
	while [ "$i" -lt "$DIAL_TRIES" ]; do
		sleep 1
		is_up && { log "拨号成功 用时约 $((i + 1))s"; return 0; }
		i=$((i + 1))
	done
	log "拨号失败（等 ${DIAL_TRIES}s 仍未 up）"
	return 1
}

hangup() {
	is_up || return 0
	log "空闲超时，挂断数据"
	ifdown wan >/dev/null 2>&1
	sleep 1
	if is_up; then log "挂断未生效，下轮再试"; else log "已挂断"; fi
}

do_once() {
	pend=$(qlen)
	if [ "$pend" -gt 0 ]; then
		if dial; then
			/usr/libexec/unisoc-modem/sms-forward queue-retry >/dev/null 2>&1
			log "补发触发完成，队列剩 $(qlen) 条"
			return 0
		fi
		return 1
	fi
	echo "队列为空，无需拨号"
	return 2
}

run_loop() {
	log "守护启动 idle=${IDLE_SECS}s check=${CHECK}s"
	backoff_until=0
	active=$(date +%s)
	while :; do
		now=$(date +%s)
		pend=$(qlen)
		if [ "$pend" -gt 0 ]; then
			if [ "$now" -ge "$backoff_until" ]; then
				if dial; then
					/usr/libexec/unisoc-modem/sms-forward queue-retry >/dev/null 2>&1
					active=$(date +%s)
				else
					backoff_until=$((now + FAIL_BACKOFF))
				fi
			fi
		else
			if is_up && [ $((now - active)) -gt "$IDLE_SECS" ]; then
				hangup
				active=$(date +%s)
			fi
		fi
		sleep "$CHECK"
	done
}

case "$1" in
run) run_loop ;;
once) do_once; echo "rc=$?" ;;
up) dial ;;
down) IDLE_SECS=0 hangup ;;
status)
	echo -n "数据连接: "
	if is_up; then echo "已连接（持续耗电）"; else echo "已断开（省电）"; fi
	echo "待发队列: $(qlen) 条"
	echo -n "守护进程: "
	if ps w | grep -q '[d]ata-ondemand.sh run'; then echo 运行中; else echo 未运行; fi
	;;
*)
	echo "用法: $0 {run|once|up|down|status}"
	;;
esac
