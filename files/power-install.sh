#!/bin/sh
# /etc/e5/power/install.sh —— 省电扩展的自愈安装
#
# 由 /etc/e5/mms/install.sh 的自愈链在开机时调用（S19，早于网络服务），
# v1.0.7 起同时负责铺回深度休眠守护。
# 系统升级会清掉 /etc/init.d 下的自建服务，这里把文件与自启链接补回来。
#
# 只负责"文件就位 + 建自启"，不主动拉起守护：
# 开机流程里 S97（e5-data-ondemand）/ S98（e5-powersave）会在正确时机启动它。
# 已经在跑的时候才重启一次，让新代码生效。
# v1.0.8 起增加第 4 段：USB gadget 自愈工具（源件在 /etc/e5/usb/）。

set -e
DIR=/etc/e5/power

# ---------- 1. 按需蜂窝数据守护 ----------
if [ -f "$DIR/data-ondemand.sh" ] && [ -f "$DIR/e5-data-ondemand.init" ]; then
	chmod 755 "$DIR/data-ondemand.sh"
	cp -f "$DIR/e5-data-ondemand.init" /etc/init.d/e5-data-ondemand
	chmod 755 /etc/init.d/e5-data-ondemand
	/etc/init.d/e5-data-ondemand enable >/dev/null 2>&1 || true
	if ps w | grep -q '[d]ata-ondemand.sh run'; then
		/etc/init.d/e5-data-ondemand restart >/dev/null 2>&1 || true
	elif [ "$(cut -d. -f1 /proc/uptime)" -gt 120 ]; then
		# 不是开机早期（手动重装的情形）：直接拉起来
		/etc/init.d/e5-data-ondemand start >/dev/null 2>&1 || true
	fi
	echo "按需数据已就位"
else
	echo "跳过按需数据：缺少 data-ondemand.sh 或 init"
fi

# ---------- 2. 开机应用省电配置 ----------
if [ -f "$DIR/powersave.sh" ] && [ -f "$DIR/e5-powersave.init" ]; then
	chmod 755 "$DIR/powersave.sh"
	cp -f "$DIR/e5-powersave.init" /etc/init.d/e5-powersave
	chmod 755 /etc/init.d/e5-powersave
	/etc/init.d/e5-powersave enable >/dev/null 2>&1 || true
	echo "省电自启已就位"
else
	echo "跳过省电自启：缺少 powersave.sh 或 init"
fi

# ---------- 3. 深度休眠守护（v1.0.7） ----------
# 源件留在 /etc/e5/power/（整目录进备份包，固件升级不清），
# 目标 /usr/sbin 与 /etc/init.d 的自建文件会被升级覆盖，这里铺回并建自启。
# 开机早期由 S99 自动拉起；手动重装（uptime>120）时若没在跑就直接 start。
if [ -f "$DIR/e5-deepsleep" ] && [ -f "$DIR/e5-deepsleep.init" ]; then
	cp -f "$DIR/e5-deepsleep" /usr/sbin/e5-deepsleep
	chmod 755 /usr/sbin/e5-deepsleep
	cp -f "$DIR/e5-deepsleep.init" /etc/init.d/e5-deepsleep
	chmod 755 /etc/init.d/e5-deepsleep
	/etc/init.d/e5-deepsleep enable >/dev/null 2>&1 || true
	if ps w | grep -q '[e]5-deepsleep'; then
		/etc/init.d/e5-deepsleep restart >/dev/null 2>&1 || true
	elif [ "$(cut -d. -f1 /proc/uptime)" -gt 120 ]; then
		/etc/init.d/e5-deepsleep start >/dev/null 2>&1 || true
	fi
	echo "深睡守护已就位"
else
	echo "跳过深睡守护：缺少 e5-deepsleep 或 init"
fi

# ---------- 4. USB gadget 自愈工具（v1.0.8） ----------
# 症状：state=configured、usb0 UP、carrier=1，但 usb0 收发计数不动（RNDIS 数据面卡死），
# 此时 Windows 侧 ping "通"其实是走了 WiFi 的假象。复位手段是 UDC soft_connect
# disconnect -> connect（软件拔插），不是重启、更不是 unbind musb-sprd（会内核重启）。
# 源件放 /etc/e5/usb/（整个 /etc/e5 进备份包，固件升级不清），目标在 /usr/sbin 与
# /etc/init.d，会被升级覆盖，所以每次开机由本段铺回。
USBDIR=/etc/e5/usb
if [ -f "$USBDIR/e5-usb-recover" ] && [ -f "$USBDIR/e5-usb-guard-check" ] && \
   [ -f "$USBDIR/e5-usb-guard.init" ] && [ -f "$USBDIR/pm-test.sh" ]; then
	cp -f "$USBDIR/e5-usb-recover" /usr/sbin/e5-usb-recover
	cp -f "$USBDIR/e5-usb-guard-check" /usr/sbin/e5-usb-guard-check
	cp -f "$USBDIR/e5-usb-guard.init" /etc/init.d/e5-usb-guard
	chmod 755 /usr/sbin/e5-usb-recover /usr/sbin/e5-usb-guard-check /etc/init.d/e5-usb-guard
	/etc/init.d/e5-usb-guard enable >/dev/null 2>&1 || true
	# 测试脚本只在没跑测试时铺回，避免在运行的 shell 脚本被覆盖
	if [ ! -f /tmp/e5-pmtest.running ]; then
		cp -f "$USBDIR/pm-test.sh" /root/pm-test.sh
		chmod 755 /root/pm-test.sh
	fi
	echo "USB 自愈工具已就位"
else
	echo "跳过 USB 自愈工具：/etc/e5/usb/ 源件不齐"
fi

# ---------- 5. 测试静默窗口的开机会滚（v1.0.8） ----------
# pm-test.sh 开跑时会临时注释 crontab 里的 rebind 行以停掉周期性唤醒。若测试进程被
# kill -9 或中途断电，/run 标记随 tmpfs 消失，crontab 的注释却会留下。开机时按标记
# 无条件清一次；正常开机零动作，也不在开机早期重启 crond（S19 早于 S50 cron）。
CRONTAB=/etc/crontabs/root
if grep -q '^# pm-test quiet: ' "$CRONTAB" 2>/dev/null; then
	sed -i 's|^# pm-test quiet: ||' "$CRONTAB"
	echo "已回滚测试静默窗口的 crontab 标记"
fi

exit 0
