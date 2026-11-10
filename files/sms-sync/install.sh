#!/bin/sh
# 安装 OpenWrt <-> Android 短信同步。可重复执行。
set -eu
SRC=$(cd "$(dirname "$0")" && pwd)
BASE=/etc/e5/sms-sync
PY=/usr/bin/python3

[ -x "$PY" ] || { echo "python3 not found at $PY" >&2; exit 1; }

mkdir -p "$BASE/backup"
# 自愈时源目录就是 $BASE，跳过自我拷贝
if [ "$SRC" != "$BASE" ]; then
	cp "$SRC/sms-sync.py" "$BASE/sms-sync.py"
	cp "$SRC/e5-sms-sync.init" "$BASE/e5-sms-sync.init"
fi
cp "$BASE/e5-sms-sync.init" /etc/init.d/e5-sms-sync
chmod 755 "$BASE/sms-sync.py" "$BASE/e5-sms-sync.init" /etc/init.d/e5-sms-sync
ln -sf "$BASE/sms-sync.py" /usr/bin/e5-sms-sync

/etc/init.d/e5-sms-sync enable >/dev/null 2>&1 || true

CRON=/etc/crontabs/root
touch "$CRON"
if ! grep -q 'sms-sync.py run' "$CRON"; then
	printf '%s\n' '*/2 * * * * /usr/bin/python3 /etc/e5/sms-sync/sms-sync.py run >/dev/null 2>&1' >> "$CRON"
fi
/etc/init.d/cron restart >/dev/null 2>&1 || /etc/init.d/cron reload >/dev/null 2>&1 || true

echo "installed: $BASE/sms-sync.py"
echo "cron:"; grep 'sms-sync' "$CRON" || true
# 只在终端里顺手打印状态；开机自愈调用时保持安静
if [ -t 1 ]; then
	"$PY" "$BASE/sms-sync.py" status
fi
