#!/bin/sh
# 卸载 / 回滚到厂商原版
#
#   sh uninstall.sh
#
# 会把 /usr/lib/e5/sms_pdu.py 和 /usr/libexec/unisoc-modem/sms-forward 还原成
# 第一次安装时备份的原件，并停用开机自愈服务。队列里的待重发消息不删。

set -u
TARGET=/etc/e5/mms
DST=/usr/lib/e5/sms_pdu.py
FWD=/usr/libexec/unisoc-modem/sms-forward
receiver() { ps w | grep '[p]ython3 /usr/libexec/e5-sms-receive serve' | awk '{ print $1 }'; }

[ "$(id -u)" = "0" ] || { echo "错误：需要 root 权限执行" >&2; exit 1; }

CHANGED=0

if [ -f "$TARGET/sms_pdu.orig.py" ] && [ -f "$DST" ]; then
	cp "$TARGET/sms_pdu.orig.py" "$DST"
	chmod 644 "$DST"
	rm -f /usr/lib/e5/__pycache__/sms_pdu*.pyc
	echo "已还原 $DST"
	CHANGED=1
else
	echo "跳过解码器还原：没有备份 $TARGET/sms_pdu.orig.py"
fi

if [ -f "$TARGET/sms-forward.orig" ] && [ -f "$FWD" ]; then
	cp "$TARGET/sms-forward.orig" "$FWD"
	chmod 755 "$FWD"
	echo "已还原 $FWD"
	/etc/init.d/unisoc-sms-forward restart >/dev/null 2>&1 || true
	echo "短信转发服务已重启"
else
	echo "跳过转发还原：没有备份 $TARGET/sms-forward.orig"
fi

/etc/init.d/e5-mms disable >/dev/null 2>&1
rm -f /etc/init.d/e5-mms
rm -f /usr/bin/e5-forward
echo "已停用开机自愈服务 e5-mms"

# ---------- v1.0.9：把省电/同步扩展的副作用一并回滚 ----------
# 顺序有要求：先让 powersave.sh off 恢复蓝牙/音频/热点的 rc.d 链接与 uci，
# 再停服务、删 init。反过来先删 powersave.sh 就没人能把这两样复原了。
if [ -x /etc/e5/power/powersave.sh ]; then
	echo "恢复蓝牙/音频/热点为原厂状态（约需 10-20 秒）…"
	timeout 150 /bin/sh /etc/e5/power/powersave.sh off >/dev/null 2>&1 || true
	echo "已恢复原厂省电状态"
fi

# 双系统短信同步：优先用它自带的卸载（会撤 cron、删 /usr/bin 链接与源目录）
if [ -x /etc/e5/sms-sync/uninstall.sh ]; then
	/bin/sh /etc/e5/sms-sync/uninstall.sh >/dev/null 2>&1 || true
	echo "已卸载双系统短信同步"
else
	sed -i '/sms-sync\.py run/d' /etc/crontabs/root 2>/dev/null || true
	rm -f /usr/bin/e5-sms-sync /etc/init.d/e5-sms-sync /etc/rc.d/S99e5-sms-sync
	echo "已清理短信同步残留（cron / init / 链接）"
fi

# 按需数据：停守护并挂断（v1.0.9 起 stop_service 是挂断，不再拨号）
if [ -x /etc/init.d/e5-data-ondemand ]; then
	/etc/init.d/e5-data-ondemand stop >/dev/null 2>&1 || true
	/etc/init.d/e5-data-ondemand disable >/dev/null 2>&1 || true
	rm -f /etc/init.d/e5-data-ondemand /etc/rc.d/S97e5-data-ondemand \
	      /etc/rc.d/K12e5-data-ondemand /tmp/.e5-do.hold
	echo "已停用按需数据守护（数据已挂断）"
fi

if [ -x /etc/init.d/e5-powersave ]; then
	/etc/init.d/e5-powersave disable >/dev/null 2>&1 || true
	rm -f /etc/init.d/e5-powersave
	echo "已停用开机省电（配置与自启已由 powersave.sh off 复原）"
fi

# v1.0.8 USB gadget 自愈：停开机自检，源件保留在 /etc/e5/usb 便于以后重装
if [ -x /etc/init.d/e5-usb-guard ]; then
	/etc/init.d/e5-usb-guard disable >/dev/null 2>&1 || true
	rm -f /etc/init.d/e5-usb-guard
	echo "已停用 USB 开机自检（源件与工具保留）"
fi

# v1.0.9 射频看门狗（procd respawn，停服务同样要 ubus 删实例）
if [ -x /etc/init.d/e5-modem-guard ]; then
	/etc/init.d/e5-modem-guard stop >/dev/null 2>&1 || true
	ubus call service delete '{"name":"e5-modem-guard"}' >/dev/null 2>&1 || true
	/etc/init.d/e5-modem-guard disable >/dev/null 2>&1 || true
	rm -f /etc/init.d/e5-modem-guard /etc/rc.d/S92e5-modem-guard \
	      /etc/rc.d/K05e5-modem-guard /usr/bin/e5-modem-guard
	echo "已停用射频看门狗（源件与日志保留在 /etc/e5/modem-guard）"
fi

# v1.0.7 深睡守护（procd respawn，停服务要用 ubus 删实例，pkill 追不上）
if [ -x /etc/init.d/e5-deepsleep ]; then
	/etc/init.d/e5-deepsleep stop >/dev/null 2>&1 || true
	ubus call service delete '{"name":"e5-deepsleep"}' >/dev/null 2>&1 || true
	/etc/init.d/e5-deepsleep disable >/dev/null 2>&1 || true
	touch /run/e5-deepsleep.off
	echo "已停用深睡守护（源件保留在 /etc/e5/power）"
fi

# v1.0.10 信息屏补丁与转发面板
if [ -f "$TARGET/patch-screen.py" ]; then
	python3 "$TARGET/patch-screen.py" --revert >/dev/null 2>&1 || true
	echo "已还原信息屏 api.uc / app.js / transport.js / calls.js（备份在 /root/e5-backup/screen）"
fi
if [ -d /etc/e5-infoscreen/plugins/forward ]; then
	rm -rf /etc/e5-infoscreen/plugins/forward
	rm -f /usr/share/e5-infoscreen/www/plugins/forward
	/usr/libexec/e5-infoscreen/plugin link >/dev/null 2>&1 || true
	echo "已移除短信转发面板（转发配置与投递记录未动）"
fi
/etc/init.d/e5-infoscreen restart >/dev/null 2>&1 || true

# 让接收进程重开，重新加载原版解码器
if [ "$CHANGED" = "1" ]; then
	for pid in $(receiver); do
		kill -TERM "$pid" 2>/dev/null || true
	done
	n=0
	while [ "$n" -lt 8 ]; do
		sleep 1
		[ -n "$(receiver)" ] && break
		n=$((n + 1))
	done
	if [ -z "$(receiver)" ]; then
		setsid python3 /usr/libexec/e5-sms-receive serve </dev/null >/dev/null 2>&1 &
		sleep 2
	fi
	echo "短信接收已重开"
fi

echo
echo "卸载完成。$TARGET 下的原件备份和重试队列都还在，确认没问题后可手动删除："
echo "  rm -rf $TARGET"
