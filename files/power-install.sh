#!/bin/sh
# /etc/e5/power/install.sh —— 省电扩展的自愈安装
#
# 由 /etc/e5/mms/install.sh 的自愈链在开机时调用（S19，早于网络服务），
# 系统升级会清掉 /etc/init.d 下的自建服务，这里把文件与自启链接补回来。
#
# 只负责"文件就位 + 建自启"，不主动拉起守护：
# 开机流程里 S97（e5-data-ondemand）/ S98（e5-powersave）会在正确时机启动它。
# 已经在跑的时候才重启一次，让新代码生效。

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

exit 0
