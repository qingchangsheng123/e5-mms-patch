#!/bin/sh
# 重新安装/修复 e5-modem-guard。
# 系统升级（LuCI「E5 系统升级」）会重建 /usr/bin 和 /etc/init.d，但保留 /etc/e5；
# 升级完在本机执行一次本脚本即可恢复看门狗：
#     sh /etc/e5/modem-guard/install.sh
set -e
D=/etc/e5/modem-guard

cp -f "$D/e5-modem-guard.init" /etc/init.d/e5-modem-guard
chmod 755 /etc/init.d/e5-modem-guard

cat >/usr/bin/e5-modem-guard <<'WRAP'
#!/bin/sh
exec /etc/e5/modem-guard/e5-modem-guard "$@"
WRAP
chmod 755 /usr/bin/e5-modem-guard

[ -f /etc/e5/modem-guard.conf ] || cp -f "$D/modem-guard.conf" /etc/e5/modem-guard.conf

/etc/init.d/e5-modem-guard enable
/etc/init.d/e5-modem-guard restart
echo "e5-modem-guard 已安装并启动：e5-modem-guard status"
