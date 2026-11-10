#!/bin/sh
# 卸载同步：停服务、撤 cron、删文件。已写入 Android 的短信不会自动删除。
set -eu
BASE=/etc/e5/sms-sync
CRON=/etc/crontabs/root

/etc/init.d/e5-sms-sync disable >/dev/null 2>&1 || true
rm -f /etc/init.d/e5-sms-sync
if [ -f "$CRON" ]; then
	sed -i '/sms-sync\.py run/d' "$CRON"
fi
/etc/init.d/cron restart >/dev/null 2>&1 || true
rm -f /usr/bin/e5-sms-sync
rm -rf "$BASE"
echo "removed. Android 侧已写入的短信需在 Android 里自行删除。"
