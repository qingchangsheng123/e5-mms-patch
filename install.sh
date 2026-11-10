#!/bin/sh
# e5-mms 一键安装 / 升级
#
#   sh install.sh              安装或升级（幂等，可重复执行）
#   sh install.sh --backfill   装完后把收件箱里历史乱码彩信改正
#   sh install.sh --dry-run    只检查环境，不改任何东西
#
# 在线安装（设备能访问 GitHub 时，raw.githubusercontent.com 在国内常被阻断，故走 api）：
#   wget -q -O /tmp/e5-mms.sh --header='Accept: application/vnd.github.raw' \
#     https://api.github.com/repos/qingchangsheng123/e5-mms-patch/contents/install.sh
#   sh /tmp/e5-mms.sh

set -u
REPO=qingchangsheng123/e5-mms-patch
TARGET=/etc/e5/mms
DST=/usr/lib/e5/sms_pdu.py
FWD=/usr/libexec/unisoc-modem/sms-forward
DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo "")

say() { echo "$*"; }
die() { echo "错误：$*" >&2; exit 1; }

BACKFILL=0
DRY=0
for arg in "$@"; do
	case "$arg" in
		--backfill) BACKFILL=1 ;;
		--dry-run) DRY=1 ;;
		-h|--help) sed -n '2,11p' "$0"; exit 0 ;;
		*) die "未知参数 $arg" ;;
	esac
done

[ "$(id -u)" = "0" ] || die "需要 root 权限执行"

# ---------- 环境检查 ----------
[ -f "$DST" ] || die "找不到 $DST，这台设备不像 E5 固件（需要 e5-sleep 系列）"
command -v python3 >/dev/null 2>&1 || die "缺少 python3"

if [ "$DRY" = "1" ]; then
	say "环境检查通过"
	[ -f "$FWD" ] && say "  转发脚本：$FWD（在，重试补丁会生效）" || say "  转发脚本：$FWD（不在，重试补丁会跳过）"
	if grep -q 'MMS_PUSH_PORTS' "$DST" 2>/dev/null; then
		say "  彩信解码：已安装过"
	else
		say "  彩信解码：尚未安装"
	fi
	exit 0
fi

# ---------- 准备文件 ----------
if [ -f "$DIR/files/sms_pdu.py" ]; then
	SRCDIR=$DIR
else
	say "本地没有 files/ 目录，从 GitHub 拉取发布包…"
	TMP=/tmp/e5-mms-$$
	mkdir -p "$TMP" || die "无法创建临时目录"
	# 两条通道依次尝试：codeload 直连；失败再走 api.github.com 的 tarball（会 302 回 codeload）
	for u in "https://codeload.github.com/$REPO/tar.gz/refs/heads/main" \
	         "https://api.github.com/repos/$REPO/tarball/main"; do
		rm -f "$TMP/pkg.tar.gz"
		wget -q -O "$TMP/pkg.tar.gz" "$u" </dev/null 2>/dev/null
		[ -s "$TMP/pkg.tar.gz" ] && break
		say "  该通道不稳定，换一个…"
	done
	if [ ! -s "$TMP/pkg.tar.gz" ]; then
		rm -rf "$TMP"
		die "下载失败。请手动下载 https://github.com/$REPO 后在其目录里执行 sh install.sh"
	fi
	tar -xzf "$TMP/pkg.tar.gz" -C "$TMP" 2>/dev/null || { rm -rf "$TMP"; die "解压失败"; }
	# 顶层目录名随通道而变：codeload 是 <仓库>-main，api tarball 是 <owner>-<仓库>-<sha>，
	# 所以按 files/sms_pdu.py 反推安装目录，别认目录名。
	SRCDIR=$(ls -d "$TMP"/*/files/sms_pdu.py 2>/dev/null | head -1)
	[ -n "$SRCDIR" ] && SRCDIR=${SRCDIR%/files/sms_pdu.py}
	[ -n "$SRCDIR" ] && [ -f "$SRCDIR/files/sms_pdu.py" ] || { rm -rf "$TMP"; die "下载包结构不对"; }
fi

# ---------- 部署文件 ----------
mkdir -p "$TARGET" || die "无法创建 $TARGET"
cp "$SRCDIR/files/sms_pdu.py" "$TARGET/sms_pdu.py" && chmod 644 "$TARGET/sms_pdu.py"
cp "$SRCDIR/files/patch-forward.py" "$TARGET/patch-forward.py" && chmod 755 "$TARGET/patch-forward.py"
cp "$SRCDIR/files/backfill.py" "$TARGET/backfill.py" && chmod 755 "$TARGET/backfill.py"
cp "$SRCDIR/files/install-core.sh" "$TARGET/install.sh" && chmod 755 "$TARGET/install.sh"
cp "$SRCDIR/files/e5-mms.init" /etc/init.d/e5-mms && chmod 755 /etc/init.d/e5-mms
say "文件已放到 $TARGET"

# ---------- 省电扩展（按需蜂窝数据 + 开机省电）----------
if [ -f "$SRCDIR/files/powersave.sh" ] && [ -f "$SRCDIR/files/data-ondemand.sh" ]; then
	mkdir -p /etc/e5/power || true
	cp "$SRCDIR/files/powersave.sh" /etc/e5/power/powersave.sh && chmod 755 /etc/e5/power/powersave.sh
	cp "$SRCDIR/files/data-ondemand.sh" /etc/e5/power/data-ondemand.sh && chmod 755 /etc/e5/power/data-ondemand.sh
	cp "$SRCDIR/files/e5-data-ondemand.init" /etc/e5/power/e5-data-ondemand.init && chmod 755 /etc/e5/power/e5-data-ondemand.init
	cp "$SRCDIR/files/e5-powersave.init" /etc/e5/power/e5-powersave.init && chmod 755 /etc/e5/power/e5-powersave.init
	cp "$SRCDIR/files/power-install.sh" /etc/e5/power/install.sh && chmod 755 /etc/e5/power/install.sh
	# v1.0.7：深睡守护的源件必须先就位，install.sh 第 3 段才会铺回 /usr/sbin 并建自启
	cp "$SRCDIR/files/e5-deepsleep" /etc/e5/power/e5-deepsleep && chmod 755 /etc/e5/power/e5-deepsleep
	cp "$SRCDIR/files/e5-deepsleep.init" /etc/e5/power/e5-deepsleep.init && chmod 755 /etc/e5/power/e5-deepsleep.init
	# v1.0.8：USB gadget 自愈工具的源件放 /etc/e5/usb/（/etc 升级不清、整目录进备份包），
	# 由 power/install.sh 第 4 段铺回 /usr/sbin 与 /etc/init.d 并建 S99 自启。
	mkdir -p /etc/e5/usb || true
	for f in e5-usb-recover e5-usb-guard-check e5-usb-guard.init pm-test.sh; do
		cp "$SRCDIR/files/$f" "/etc/e5/usb/$f" && chmod 755 "/etc/e5/usb/$f"
	done
	# 这里不再直接跑 power/install.sh：下面 install-core.sh 的扩展循环会跑一次，
	# v1.0.8 及以前两处都跑，手动升级时 data-ondemand 与 deepsleep 各被 restart 两次。
	say "省电扩展已就位（按需拨号、开机省电、深睡守护、USB 自愈）"
fi

# ---------- 双系统短信同步（v1.0.9 起随包分发）----------
# 之前只在本机手工部署，发布包里没有这四件，全新安装拿不到「双系统短信互通」。
# 源件放 /etc/e5/sms-sync（整目录进备份包），由 install-core.sh 的扩展循环执行它的 install.sh。
if [ -f "$SRCDIR/files/sms-sync/sms-sync.py" ]; then
	mkdir -p /etc/e5/sms-sync || true
	for f in sms-sync.py install.sh e5-sms-sync.init uninstall.sh; do
		cp "$SRCDIR/files/sms-sync/$f" "/etc/e5/sms-sync/$f" && chmod 755 "/etc/e5/sms-sync/$f"
	done
	say "短信同步源件已就位（/etc/e5/sms-sync，随包分发）"
fi

# ---------- 射频看门狗（v1.0.9 起随包分发）----------
# 2026-11-10 事故：基带停在 CFUN=0（射频关闭），ModemManager 却报
# registered/connected、运营商正常，短信一条都收不到。设备上原本有这套
# e5-modem-guard，但没有 /etc/init.d 与 rc.d 链接、进程也不在，等于没有。
# 源件放 /etc/e5/modem-guard（整目录进备份包），由 install-core.sh 扩展循环执行 install.sh。
if [ -f "$SRCDIR/files/modem-guard/e5-modem-guard" ]; then
	mkdir -p /etc/e5/modem-guard || true
	for f in e5-modem-guard e5-modem-guard.init install.sh modem-guard.conf; do
		cp "$SRCDIR/files/modem-guard/$f" "/etc/e5/modem-guard/$f" || true
	done
	chmod 755 /etc/e5/modem-guard/e5-modem-guard \
	          /etc/e5/modem-guard/e5-modem-guard.init \
	          /etc/e5/modem-guard/install.sh
	chmod 644 /etc/e5/modem-guard/modem-guard.conf
	say "射频看门狗源件已就位（/etc/e5/modem-guard）"
fi

# ---------- 信息屏：信号格修复 + 转发面板（v1.0.10 起随包分发）----------
# 两个独立的问题：
#   1. 熄屏时 t551m-sim-status 60 s 才刷一次快照，api.uc 只认 15 s，亮屏瞬间
#      信号格与制式必然为空（5 秒后才回来），而 app.js 的兜底又被 quality:null
#      堵死。patch-screen.py 让过期快照保留最后读数并标 stale，前端把它画成
#      半透明而不是 0 格。
#   2. transport.js 连的 8089 WebSocket 从来没有部署过，每次加载都在重连并刷
#      console 错误，一并改成原生 fetch。
# 补丁幂等：已打过的文件按 marker 跳过；原厂换版导致锚点对不上就原样不动。
if [ -f "$SRCDIR/files/patch-screen.py" ]; then
	cp "$SRCDIR/files/patch-screen.py" "$TARGET/patch-screen.py" && chmod 755 "$TARGET/patch-screen.py"
	python3 "$TARGET/patch-screen.py" || say "信息屏补丁未完成，见上面的输出（原文件已备份在 /root/e5-backup/screen）"
fi

# 转发面板：只是 e5-forward 的状态视图，装在 /etc 下（升级不清），
# plugin link 会把目录链到 web root；卸载只删目录，不动转发配置。
if [ -f "$SRCDIR/files/forward-plugin/manifest.json" ]; then
	FW=/etc/e5-infoscreen/plugins/forward
	mkdir -p "$FW" || true
	for f in manifest.json backend.uc index.html; do
		cp "$SRCDIR/files/forward-plugin/$f" "$FW/$f" && chmod 644 "$FW/$f"
	done
	/usr/libexec/e5-infoscreen/plugin link >/dev/null 2>&1 || true
	say "短信转发面板已就位（信息屏 → 应用 → 短信转发）"
fi

# 开机自愈：系统升级会覆盖 /usr 下的东西，靠这个 S19 服务补回来
/etc/init.d/e5-mms enable >/dev/null 2>&1
say "开机自愈服务 e5-mms 已启用（START=19）"

# ---------- 执行安装 ----------
echo
sh "$TARGET/install.sh"

# ---------- 可选：回填历史 ----------
if [ "$BACKFILL" = "1" ]; then
	echo
	say "回填历史乱码彩信…"
	python3 "$TARGET/backfill.py" || say "回填失败，可稍后手动执行 python3 $TARGET/backfill.py"
fi

# 信息屏补丁与新面板要重载 uhttpd 的 ucode handler 才生效（屏幕会黑一下再回来）
if [ -f "$TARGET/patch-screen.py" ] || [ -d /etc/e5-infoscreen/plugins/forward ]; then
	say "重启信息屏以加载补丁（约 5 秒）…"
	/etc/init.d/e5-infoscreen restart >/dev/null 2>&1 || true
fi

echo
say "完成。"
say "  查看效果：在设备管理页面或短信列表里看彩信通知，应显示「【彩信】…内容地址：…」"
say "  队列状态：e5-forward status"
say "  投递记录：cat /etc/unisoc-modem/forward/delivery.log"
say "  卸载回滚：sh $SRCDIR/uninstall.sh"
