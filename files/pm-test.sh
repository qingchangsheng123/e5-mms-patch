#!/bin/sh
# E5 过夜功耗测试 v4（2026-11-09 审计后修订）
# v3 -> v4：
#   新增「测量静默窗口」：仅在真正拔线开跑时临时停掉三个常驻唤醒源
#   （e5-powersam 60s / powermon 10s / cron rebind.sh），脚本结束或异常退出
#   一律自动恢复；只 stop 不 disable，开机自启不变，重启也能自愈。
# v2 -> v3：
#   1) 删掉 battery/charge_counter —— 实测恒为 1，是无效属性，用它算斜率必然误判。
#      改用 sc27xx-fgu/capacity（库仑计 0.1%）+ dmesg 的 cc_mah（累计 mAh，线性无跳变）。
#   2) 收尾判断热点改用 iw dev wlan0 info 的 "type AP"；hostapd 进程常驻，
#      ps | grep hostapd 永远为真，判断不出 wlan0 down 之后热点是否真的恢复。
#   3) RUNF 陈旧 PID 自动清除，脚本异常退出后可以直接重挂。
#   4) sync 从每条改为每 10 条，减少刷 ext4 journal 对功耗测量的干扰。
#
# 采样列：wall boottime cap_fgu(0.1%) cap_bat(%) voltage_uV current_uA temp status usb cc_mah
# 启动：start-stop-daemon -S -b -x /root/pm-test.sh
# 参数：DUR=秒 STEP=秒 WAITMAX=秒 START_AFTER=epoch

LOG=/root/e5-pmtest.log
PM=/root/e5-pmtest-pm.log
DONE=/root/e5-pmtest.done
RUNF=/tmp/e5-pmtest.running
QUIET=/run/e5-pmtest.quiet
CRONTAB=/etc/crontabs/root
QUIET_MARK='# pm-test quiet: '
USB=/sys/class/power_supply/usb/online
BL=/sys/class/backlight/sprd_backlight/brightness
BAT=/sys/class/power_supply/battery
FGU=/sys/class/power_supply/sc27xx-fgu
SLEEPLOG=/root/e5-deepsleep.log
DUR=${DUR:-25200}
STEP=${STEP:-120}
WAITMAX=${WAITMAX:-43200}
START_AFTER=${START_AFTER:-0}
N=0

log() {
	echo "$(date '+%F %T') $*" >>"$LOG"
}

# --- 测量静默窗口 ---------------------------------------------------------
# 三个常驻进程每 10/60/60 秒唤醒一次 AP，会污染占空比与平均功耗。
# 只在测试真正开跑后才停，等待拔线的白天不打断正常使用。
# 用 /run（tmpfs）记状态：设备一重启标记自然消失，服务开机自启不受影响。
quiet_start() {
	[ -f "$QUIET" ] && return 0
	/etc/init.d/e5-powersam stop >/dev/null 2>&1 || true
	/etc/init.d/powermon stop >/dev/null 2>&1 || true
	if grep -q '^[^#].*/root/rebind.sh' "$CRONTAB" 2>/dev/null; then
		sed -i "s|^\([^#].*/root/rebind.sh.*\)$|$QUIET_MARK\1|" "$CRONTAB"
		/etc/init.d/cron restart >/dev/null 2>&1 || true
	fi
	echo "$(date +%s)" >"$QUIET"
	log "QUIET on: e5-powersam/powermon stopped, rebind cron held"
}

quiet_end() {
	[ -f "$QUIET" ] || return 0
	/etc/init.d/e5-powersam start >/dev/null 2>&1 || true
	/etc/init.d/powermon start >/dev/null 2>&1 || true
	if grep -q "^$QUIET_MARK" "$CRONTAB" 2>/dev/null; then
		sed -i "s|^$QUIET_MARK||" "$CRONTAB"
		/etc/init.d/cron restart >/dev/null 2>&1 || true
	fi
	rm -f "$QUIET"
	log "QUIET off: samplers + rebind cron restored"
}
trap quiet_end EXIT
trap 'quiet_end; exit 1' INT TERM

# 库仑计累计值：dmesg 里 sprd-fgu 打印的 "data->cc_mah = -181"
cc_mah() {
	dmesg 2>/dev/null | sed -n 's/.*cc_mah = \([0-9-]*\).*/\1/p' | tail -1
}

sample() {
	echo "$(date +%s) $(cut -d' ' -f1 /proc/uptime) $(cat $FGU/capacity 2>/dev/null) $(cat $BAT/capacity 2>/dev/null) $(cat $BAT/voltage_now 2>/dev/null) $(cat $BAT/current_now 2>/dev/null) $(cat $BAT/temp 2>/dev/null) $(cat $BAT/status 2>/dev/null | tr -d ' ') $(cat $USB 2>/dev/null) $(cc_mah)" >>"$PM"
	N=$((N + 1))
	[ $((N % 10)) -eq 0 ] && sync
}

if [ -f "$RUNF" ]; then
	old=$(cat "$RUNF" 2>/dev/null)
	if [ -n "$old" ] && [ -d "/proc/$old" ]; then
		log "already running pid=$old, exit"
		exit 0
	fi
	log "stale RUNF pid=$old, cleared"
fi
echo $$ >"$RUNF"
rm -f "$DONE"

log "=== ARMED v4 usb=$(cat $USB 2>/dev/null) dur=$DUR step=$STEP waitmax=$WAITMAX start_after=$START_AFTER"

# --- 1. 等拔线：必须「已到允许时刻」且连续 30s usb=0 ---
i=0
zero=0
while [ $i -lt "$WAITMAX" ]; do
	if [ "$(cat $USB 2>/dev/null)" = "0" ] && [ "$(date +%s)" -ge "$START_AFTER" ]; then
		zero=$((zero + 2))
		[ $zero -ge 30 ] && break
	else
		zero=0
	fi
	sleep 2
	i=$((i + 2))
done
if [ $zero -lt 30 ]; then
	log "WAIT timeout(${WAITMAX}s) still plugged, abort"
	echo "ABORT $(date '+%F %T')" >"$DONE"
	rm -f "$RUNF"
	exit 1
fi
log "UNPLUGGED, settle 8s"
sleep 8

quiet_start

# --- 2. 关背光、关 wlan0（否则 SDIO 队列非空会让挂起 EBUSY）---
bl=$(cat $BL 2>/dev/null)
[ "$bl" != "0" ] && echo 0 >"$BL" 2>/dev/null
L0=$(wc -l <"$SLEEPLOG" 2>/dev/null)
log "SLEEPLOG L0=$L0 bl=${bl}->$(cat $BL 2>/dev/null)"
ip link set wlan0 down 2>/dev/null
sleep 3
log "WLAN down state=$(ip -br link show wlan0 2>/dev/null | awk '{print $2}')"

# --- 3. 采样主循环 ---
: >"$PM"
echo "# wall boottime cap_fgu(0.1%) cap_bat(%) voltage_uV current_uA temp status usb cc_mah" >>"$PM"
sync
T0=$(date +%s)
TEND=$((T0 + DUR))
sample
log "RUN start T0=$T0 TEND=$TEND"

while [ "$(date +%s)" -lt "$TEND" ]; do
	sleep "$STEP"
	sample
	if [ "$(cat $USB 2>/dev/null)" = "1" ]; then
		sleep 10
		[ "$(cat $USB 2>/dev/null)" = "1" ] && { log "EARLY replug"; break; }
	fi
done

sample
sync
T1=$(date +%s)
log "RUN end T1=$T1 elapsed=$((T1 - T0))"

# --- 4. 收尾：恢复采样器、抽守护日志、恢复 WiFi ---
quiet_end

L1=$(wc -l <"$SLEEPLOG" 2>/dev/null)
tail -n +$((L0 + 1)) "$SLEEPLOG" >/root/e5-pmtest-sleep.log 2>/dev/null
log "SLEEPLOG L1=$L1 new=$((L1 - L0))"
log "SUMMARY $(grep '汇总' /root/e5-pmtest-sleep.log 2>/dev/null | tail -1)"

echo "DONE $(date '+%F %T') elapsed=$((T1 - T0))s sleep_new=$((L1 - L0))" >"$DONE"
sync

ip link set wlan0 up 2>/dev/null
sleep 3
if iw dev wlan0 info 2>/dev/null | grep -q 'type AP'; then
	log "WLAN up, AP active"
else
	/usr/libexec/unisoc-modem/hotspot on >>"$LOG" 2>&1
	sleep 3
	if iw dev wlan0 info 2>/dev/null | grep -q 'type AP'; then
		log "WLAN up, hotspot re-enabled OK"
	else
		log "WARN: hotspot still not in AP mode, USB/串口 取数"
	fi
fi
log "=== FINISHED"
rm -f "$RUNF"
