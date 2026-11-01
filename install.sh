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

echo
say "完成。"
say "  查看效果：在设备管理页面或短信列表里看彩信通知，应显示「【彩信】…内容地址：…」"
say "  队列状态：e5-forward status"
say "  投递记录：cat /etc/unisoc-modem/forward/delivery.log"
say "  卸载回滚：sh $SRCDIR/uninstall.sh"
