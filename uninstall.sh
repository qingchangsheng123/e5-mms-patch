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

# v1.0.7 深睡守护（procd respawn，停服务要用 ubus 删实例，pkill 追不上）
if [ -x /etc/init.d/e5-deepsleep ]; then
	/etc/init.d/e5-deepsleep stop >/dev/null 2>&1 || true
	ubus call service delete '{"name":"e5-deepsleep"}' >/dev/null 2>&1 || true
	/etc/init.d/e5-deepsleep disable >/dev/null 2>&1 || true
	touch /run/e5-deepsleep.off
	echo "已停用深睡守护（源件保留在 /etc/e5/power）"
fi

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
