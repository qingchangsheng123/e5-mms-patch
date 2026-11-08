#!/bin/sh
# 打成可分发 tar.gz：sh package.sh
set -eu
VERSION=$(cat VERSION)
NAME=e5-mms-patch-$VERSION
OUT=dist

rm -rf "$OUT/$NAME" "$OUT/$NAME.tar.gz" "$OUT/$NAME.tar.gz.sha256"
mkdir -p "$OUT/$NAME"

for f in install.sh uninstall.sh README.md CHANGELOG.md LICENSE VERSION; do
	cp "$f" "$OUT/$NAME/"
done
cp -r files "$OUT/$NAME/"

chmod 755 "$OUT/$NAME/install.sh" "$OUT/$NAME/uninstall.sh"
chmod 755 "$OUT/$NAME/files/"*.sh "$OUT/$NAME/files/"*.py
chmod 755 "$OUT/$NAME/files/e5-mms.init"
chmod 755 "$OUT/$NAME/files/e5-deepsleep" "$OUT/$NAME/files/e5-deepsleep.init"

tar -czf "$OUT/$NAME.tar.gz" -C "$OUT" "$NAME"
(cd "$OUT" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")

echo "已生成 $OUT/$NAME.tar.gz"
cat "$OUT/$NAME.tar.gz.sha256"
