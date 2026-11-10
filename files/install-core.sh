#!/bin/sh
# e5-mms 核心安装逻辑（安装到 /etc/e5/mms/install.sh 后执行）
#
# 做两件事：
#   1) 用带 MMS 解码的 sms_pdu.py 替换 /usr/lib/e5/sms_pdu.py
#      彩信 WAP Push（端口 2948/2949）不再被当成普通短信、按 latin1 解成乱码。
#   2) 给 /usr/libexec/unisoc-modem/sms-forward 打补丁
#      投递失败不再一次性丢弃，按 30s/2m/10m/30m/2h/6h 退避重试。
#
# 幂等，可以反复执行。系统升级会把 /usr 下的文件换回原版，所以开机由
# /etc/init.d/e5-mms（START=19）自动补装一次，早于短信服务启动。
#
# 手动执行：sh /etc/e5/mms/install.sh

set -e
SRC=/etc/e5/mms/sms_pdu.py
DST=/usr/lib/e5/sms_pdu.py
MARK='MMS_PUSH_PORTS'
FWD=/usr/libexec/unisoc-modem/sms-forward
PATCH=/etc/e5/mms/patch-forward.py
# 只匹配真正在跑的进程，[y] 写法避免匹配到自己这条命令行
receiver() { ps w | grep '[p]ython3 /usr/libexec/e5-sms-receive serve' | awk '{ print $1 }'; }
CHANGED=0
FWD_CHANGED=0

# ---------- 1. 彩信解码 ----------
if [ -f "$SRC" ] && [ -f "$DST" ]; then
	if ! grep -q "$MARK" "$DST" 2>/dev/null; then
		# 第一次安装时留一份系统原件，便于回滚
		[ -f /etc/e5/mms/sms_pdu.orig.py ] || cp "$DST" /etc/e5/mms/sms_pdu.orig.py
		cp "$SRC" "$DST"
		chmod 644 "$DST"
		rm -f /usr/lib/e5/__pycache__/sms_pdu*.pyc
		CHANGED=1
		echo "已安装彩信解码（MMS WAP Push）"
	else
		echo "彩信解码已是最新"
	fi
else
	echo "跳过彩信解码：缺少 $SRC 或 $DST"
fi

# 方便命令行查看：e5-forward queue / e5-forward status
[ -f "$FWD" ] && ln -sf "$FWD" /usr/bin/e5-forward 2>/dev/null || true

# ---------- 2. 转发失败重试队列 ----------
if [ -x "$PATCH" ] && [ -f "$FWD" ]; then
	_result=$(python3 "$PATCH" 2>&1) || _result="失败：$_result"
	case "$_result" in
		patched) FWD_CHANGED=1; echo "已给短信转发打补丁（失败入队重试）" ;;
		already) echo "短信转发补丁已是最新" ;;
		*) echo "转发补丁未应用：$_result" ;;
	esac
else
	echo "跳过转发补丁：缺少 $PATCH 或 $FWD"
fi

# 解码器只在进程启动时读入；换了文件要让收短信的进程重开
if [ "$CHANGED" = "1" ]; then
	if [ -z "$(receiver)" ]; then
		# 开机早期（S19）收短信进程还没起来：文件已就位，等系统服务正常拉起即可。
		# 这里若主动 setsid 一个，会和随后 e5-sms-notify 拉起的那个并存，变成两个实例。
		echo "短信接收尚未启动（开机早期），文件已就位，交给系统服务拉起"
	else
		for pid in $(receiver); do
			kill -TERM "$pid" 2>/dev/null || true
		done
		# 有的固件会自己把进程拉回来：先等一会儿，别和它抢，否则会有两个实例
		n=0
		while [ "$n" -lt 8 ]; do
			sleep 1
			[ -n "$(receiver)" ] && break
			n=$((n + 1))
		done
		if [ -z "$(receiver)" ]; then
			# 确实没人管：按原来的方式重新拉起
			setsid python3 /usr/libexec/e5-sms-receive serve </dev/null >/dev/null 2>&1 &
			sleep 2
		fi
		if [ -n "$(receiver)" ]; then
			echo "短信接收已用新解码器重开"
		else
			echo "警告：短信接收没有起来，执行 /usr/libexec/e5-sms-receive serve 检查"
		fi
	fi
fi

# 转发脚本被改过，守护进程要重开才会用新代码
if [ "$FWD_CHANGED" = "1" ]; then
	/etc/init.d/unisoc-sms-forward restart >/dev/null 2>&1 || true
	echo "短信转发服务已重启"
fi

# ---------- 3. 本机额外扩展（装了才生效，与本补丁无关）----------
for ext in /etc/e5/usb-rndis /etc/e5/maintenance /etc/e5/power /etc/e5/sms-sync /etc/e5/modem-guard; do
	[ -x "$ext/install.sh" ] || continue
	if sh "$ext/install.sh" >/dev/null 2>&1; then
		echo "扩展 $(basename "$ext") 已就位"
	else
		echo "扩展 $(basename "$ext") 重装失败，执行 sh $ext/install.sh 看原因"
	fi
done

exit 0
