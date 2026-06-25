#!/bin/sh
# gl-portable-backup: Build the IPK package without the OpenWrt/GL SDK.
# Copyright (c) 2026 RemoteToHome Consulting (https://remotetohome.io)
# https://github.com/RemoteToHome-io/gl-portable-backup
# Usage: ./pkg/build.sh [version]
#
# The package is architecture-independent (pure shell + LuCI JS/JSON), so a
# valid opkg .ipk can be assembled directly with standard tools — no SDK
# toolchain required. The output container (a gzip tar of debian-binary +
# control.tar.gz + data.tar.gz) matches what the GL.iNet glbuilder SDK
# produces for this package, so the result installs identically with opkg.
set -eu

for cmd in tar gzip sed install find du cut; do
	command -v "$cmd" >/dev/null 2>&1 || {
		echo "Error: required command not found: $cmd" >&2
		exit 1
	}
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PKG_SRC="$ROOT_DIR/luci-app-gl-portable-backup"
PKG_NAME="luci-app-gl-portable-backup"

# Resolve version: explicit arg > $VERSION env > git tag > Makefile PKG_VERSION.
if [ -n "${1:-}" ]; then
	RAW_VERSION="$1"
elif [ -n "${VERSION:-}" ]; then
	RAW_VERSION="$VERSION"
elif [ "${GITHUB_REF_TYPE:-}" = "tag" ] && [ -n "${GITHUB_REF_NAME:-}" ]; then
	RAW_VERSION="$GITHUB_REF_NAME"
else
	RAW_VERSION="$(sed -n 's/^PKG_VERSION:=//p' "$PKG_SRC/Makefile")"
fi
VERSION="${RAW_VERSION#v}"   # strip optional leading 'v' from tags like v1.0.0
[ -n "$VERSION" ] || VERSION="0.0.0"

BUILD_DIR="$ROOT_DIR/build"
OUT_DIR="$BUILD_DIR/out"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/control" "$BUILD_DIR/data" "$OUT_DIR"

# -- data.tar.gz (installed files) --
# In the package source tree, root/ maps to / and htdocs/ maps to /www.
DATA="$BUILD_DIR/data"
cp -a "$PKG_SRC/root/." "$DATA/"
install -d "$DATA/www"
cp -a "$PKG_SRC/htdocs/." "$DATA/www/"

# Normalize permissions (the executable backend must stay 0755; data 0644).
chmod 0755 "$DATA/usr/sbin/gl-portable-backup"
find "$DATA" -type d -exec chmod 0755 {} +
find "$DATA" -type f \( -name '*.json' -o -name '*.js' \) -exec chmod 0644 {} +

# -- control.tar.gz (metadata + maintainer scripts) --
CTRL="$BUILD_DIR/control"
ISIZE="$(du -sb "$DATA" 2>/dev/null | cut -f1)"; [ -n "$ISIZE" ] || ISIZE=0
sed -e "s/{{VERSION}}/$VERSION/" -e "s/{{ISIZE}}/$ISIZE/" "$SCRIPT_DIR/control" > "$CTRL/control"
install -m 0755 "$SCRIPT_DIR/postinst" "$CTRL/postinst"
install -m 0755 "$SCRIPT_DIR/prerm"    "$CTRL/prerm"

# -- assemble ipk (OpenWrt opkg expects a tar-based ipk, not the ar-based .deb layout) --
echo "2.0" > "$BUILD_DIR/debian-binary"
( cd "$CTRL" && tar --owner=0 --group=0 -czf "$BUILD_DIR/control.tar.gz" . )
( cd "$DATA" && tar --owner=0 --group=0 -czf "$BUILD_DIR/data.tar.gz" . )

IPK="$OUT_DIR/${PKG_NAME}_${VERSION}_all.ipk"
( cd "$BUILD_DIR" && tar --owner=0 --group=0 -czf "$IPK" ./debian-binary ./control.tar.gz ./data.tar.gz )

SIZE="$(du -h "$IPK" | cut -f1)"
echo "Built: $IPK ($SIZE)"
echo "Install: scp $IPK root@<router>:/tmp/ && ssh root@<router> opkg install /tmp/$(basename "$IPK")"
