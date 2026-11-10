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
CHECK=${CHECK:-3}            # 轮询间隔（越小越灵敏，2-3s 合适）
DIAL_TRIES=15                # 拨号最多等几秒
FAIL_BACKOFF=90              # 拨号失败后的退避（秒）
DIALED=0                     # 本轮是否真的拨了号（用于强制补发）

is_up() { [ "$(cat /sys/class/net/$IFACE/operstate 2>/dev/null)" = up ]; }

# 待发条数：必须排除点开头的隐藏文件 —— 转发补丁写队列时用 .<id>.tmp 临时名，
# `ls -A` 会把写到一半的临时文件算进队列，导致队列空着也反复拨号。
qlen() { ls -1 "$QUEUE" 2>/dev/null | wc -l | tr -d ' '; }

# 队列里最早一条排了多久。短信本身在断网时进队，那段时间的退避没有意义，
# 记下来是为了事后能算清"从短信进队到真正发出"到底花了多少秒。
q_age() {
	_f=$(ls -1t "$QUEUE"/* 2>/dev/null | tail -1)
	[ -n "$_f" ] || { echo 0; return 0; }
	_m=$(stat -c %Y "$_f" 2>/dev/null) || { echo 0; return 0; }
	case "$_m" in ''|*[!0-9]*) echo 0; return 0 ;; esac
	echo $(( $(date +%s) - _m ))
}

log() {
	# 256KB 轮转
	if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
		tail -c 131072 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
	fi
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

dial() {
	is_up && return 0
	log "拨号（队列 $(qlen) 条待发，最早一条 $(q_age)s 前入队）"
	DIALED=1
	ifup wan >/dev/null 2>&1
	i=0
	while [ "$i" -lt "$DIAL_TRIES" ]; do
		sleep 1
		is_up && { log "拨号成功 用时约 $((i + 1))s"; return 0; }
		i=$((i + 1))
	done
	log "拨号失败（等 ${DIAL_TRIES}s 仍未 up）"
	DIALED=0
	return 1
}

# 补发。刚拨通的那一次强制跳过退避：队列里的 next 是在断网时定的，
# 现在网络已经可用，再等 30s 纯属白等（实测占端到端延迟的一半以上）。
retry_queue() {
	if [ "$DIALED" = "1" ]; then
		MU300_FORCE_RETRY=1 /usr/libexec/unisoc-modem/sms-forward queue-retry >/dev/null 2>&1
		log "已强制补发（跳过退避），队列剩 $(qlen) 条"
	else
		/usr/libexec/unisoc-modem/sms-forward queue-retry >/dev/null 2>&1
	fi
	DIALED=0
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
			retry_queue
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
	up_since=0
	while :; do
		now=$(date +%s)
		pend=$(qlen)
		if [ "$pend" -gt 0 ]; then
			if [ "$now" -ge "$backoff_until" ]; then
				if dial; then
					retry_queue
					up_since=$now
				else
					backoff_until=$((now + FAIL_BACKOFF))
				fi
			fi
		else
			# 计时从"看到它 up"那一刻开始，而不是从上次活动。
			# 否则手动 up（或开机时 netifd 自动 up）会因为计时基准太老而被立刻挂断。
			if is_up; then
				[ "$up_since" -eq 0 ] && up_since=$now
				# 手动 up 会留下 hold 标记：一直保持，直到手动 down 或重启
				if [ -f /tmp/.e5-do.hold ]; then
					up_since=$now
				elif [ $((now - up_since)) -gt "$IDLE_SECS" ]; then
					hangup
					up_since=0
				fi
			else
				up_since=0
			fi
		fi
		sleep "$CHECK"
	done
}

case "$1" in
run) run_loop ;;
once) do_once; echo "rc=$?" ;;
up) touch /tmp/.e5-do.hold; if dial; then retry_queue; fi ;;
down) rm -f /tmp/.e5-do.hold; IDLE_SECS=0 hangup ;;
status)
	echo -n "数据连接: "
	if is_up; then echo "已连接（持续耗电）"; else echo "已断开（省电）"; fi
	echo "待发队列: $(qlen) 条"
	if [ -f /tmp/.e5-do.hold ]; then echo "手动保持: 是（不会自动挂断，用 down 取消）"; fi
	echo -n "守护进程: "
	if ps w | grep -q '[d]ata-ondemand.sh run'; then echo 运行中; else echo 未运行; fi
	;;
*)
	echo "用法: $0 {run|once|up|down|status}"
	;;
esac
