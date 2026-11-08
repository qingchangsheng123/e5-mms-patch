#!/bin/sh
# E5 省电开关（只保留短信转发）
#   powersave.sh on      关热点 + 停蓝牙/音频
#   powersave.sh off     恢复原厂（热点开、蓝牙音频开）
#   powersave.sh status  查看当前状态
#   powersave.sh wlan-on|wlan-off  仅开关 WiFi 链路（调试用，不动蓝牙/音频）
#
# 实测（HiZ 停充、20×3s 采样、静置后测）：
#   热点开  ≈ 750-800mW
#   热点关  ≈ 500-590mW
#   → 关热点省 0.25-0.3W（约 35%），是唯一有效的一项。
# 实测无效（差异在噪声内，故不写进开机脚本）：
#   CPU 限频 / 关大核 344 vs 340mW；蓝牙+音频 333 vs 340mW；4G vs 5G 384 vs 421mW。
# 想锁 4G 可单独执行（本站 LTE RSRP 约 -110dBm，比 5G 差，不建议）：
#   /usr/libexec/unisoc-modem/lock-control start mode 4g

HS=/usr/libexec/unisoc-modem/hotspot
MODE="$1"

svc() {
	act=$1; shift
	for s in "$@"; do
		if [ "$act" = on ]; then /etc/init.d/$s start >/dev/null 2>&1
		else /etc/init.d/$s stop >/dev/null 2>&1; fi
	done
}

do_status() {
	echo -n "热点:      "
	if [ "$(uci -q get wireless.radio0.disabled)" = 1 ]; then echo "关"; else echo "开"; fi
	echo -n "制式:      "
	mmcli -m 0 2>/dev/null | grep -o 'access tech: [a-z0-9]*' | sed 's/access tech: //' | head -1
	echo -n "蓝牙:      "
	uci -q get e5-bluetooth.main.enabled | sed 's/^1$/开/; s/^0$/关/' | tr -d '\n'; echo
	echo -n "音频:      "
	uci -q get e5-audio.main.enabled | sed 's/^1$/开/; s/^0$/关/' | tr -d '\n'; echo
	echo -n "短信转发:  "
	ps w | grep -q '[e]5-sms-receive serve' && echo "运行中" || echo "未运行"
	echo -n "WiFi链路:  "
	ip -br link show wlan0 2>/dev/null | awk '{print $2}' | tr -d '\n'; echo
}

case "$MODE" in
on)
	$HS off >/dev/null 2>&1
	uci set e5-bluetooth.main.enabled=0; uci set e5-bluetooth.main.autostart=0; uci commit e5-bluetooth
	uci set e5-audio.main.enabled=0; uci commit e5-audio
	# 先通过协议把 BT 核心关掉：bluetoothd 还活着时才能成功。
	# 顺序反了（先停 bluetoothd）会让 e5-bt 的 stop_service 卡在 bluetoothctl 上。
	if ps w | grep -q '[b]luetoothd'; then
		timeout 8 bluetoothctl power off >/dev/null 2>&1
	fi
	# 统一禁用自启：直接删 rc.d 链接。
	# 不能用 /etc/init.d/<svc> disable —— e5-bt 的 disable 会经 rc.common 触发
	# procd reload → stop_service → bluetoothctl power off，此时 bluetoothd 已停，
	# 该调用会一直阻塞（实测卡死，只能 timeout 杀掉）。
	for s in e5-audio e5-pulseaudio e5-voice-audio pulseaudio e5-bt bluetoothd e5-hfp; do
		rm -f /etc/rc.d/S[0-9]*"$s" /etc/rc.d/K[0-9]*"$s" 2>/dev/null
	done
	# 不用 init stop 收尾：e5-bt 的 stop_service 会阻塞；直接 kill 残留
	for pat in "[b]tattach" "[e]5-voice-audio" "[p]ulseaudio" "[e]5-bt" "[b]luetoothd" "[e]5-hfp"; do
		ps w | grep "$pat" | awk '{print $1}' | while read p; do kill "$p" 2>/dev/null; done
	done
	sleep 2
	timeout 5 rfkill block bluetooth 2>/dev/null
	# 深睡守护要求 wlan0 链路关闭：只关 hostapd（$HS off）不够。
	# 实测 `ip link set wlan0 down` 保留 wcn 驱动且消除 sdiohal/Wi-Fi_cmd 唤醒；
	# `wifi down` 会让驱动半死（MPM wakelock 0.78s/次、挂起 EBUSY），禁用。
	if ip link show wlan0 >/dev/null 2>&1; then
		ip link set wlan0 down 2>/dev/null
	fi
	echo "已开启省电模式"
	do_status
	;;
off)
	$HS on >/dev/null 2>&1
	if ip link show wlan0 >/dev/null 2>&1; then
		ip link set wlan0 up 2>/dev/null
	fi
	uci set e5-bluetooth.main.enabled=1; uci set e5-bluetooth.main.autostart=1; uci commit e5-bluetooth
	uci set e5-audio.main.enabled=1; uci commit e5-audio
	for s in e5-audio e5-pulseaudio e5-voice-audio pulseaudio e5-bt bluetoothd e5-hfp; do
		[ -x /etc/init.d/$s ] && timeout 10 /etc/init.d/$s enable >/dev/null 2>&1
	done
	rfkill unblock bluetooth 2>/dev/null
	for s in e5-audio e5-pulseaudio e5-voice-audio pulseaudio e5-bt bluetoothd e5-hfp; do
		[ -x /etc/init.d/$s ] && timeout 15 /etc/init.d/$s start >/dev/null 2>&1
	done
	echo "已恢复原厂模式"
	do_status
	;;
wlan-on)
	$HS on >/dev/null 2>&1
	if ip link show wlan0 >/dev/null 2>&1; then ip link set wlan0 up 2>/dev/null; fi
	do_status
	;;
wlan-off)
	$HS off >/dev/null 2>&1
	if ip link show wlan0 >/dev/null 2>&1; then ip link set wlan0 down 2>/dev/null; fi
	do_status
	;;
status)
	do_status
	;;
*)
	do_status
	echo
	echo "用法: $0 on|off|status|wlan-on|wlan-off"
	;;
esac
