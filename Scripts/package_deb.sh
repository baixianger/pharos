#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${1:-}
ARCH=${2:-}
BINARY=${3:-}
OUTPUT_DIR=${4:-"$ROOT/dist"}
# Phase E: optional 5th arg kept for call-site compat; iroh-ffi is no longer packaged.
_UNUSED_IROH_LIBRARY=${5:-}

usage() {
  echo "usage: Scripts/package_deb.sh VERSION amd64|arm64 BINARY [OUTPUT_DIR]" >&2
  exit 2
}

[[ -n "$VERSION" && -n "$ARCH" && -n "$BINARY" ]] || usage
[[ "$VERSION" =~ ^[0-9][0-9A-Za-z.+:~-]*$ ]] || { echo "error: invalid Debian version: $VERSION" >&2; exit 2; }
case "$ARCH" in amd64|arm64) ;; *) usage ;; esac
[[ -x "$BINARY" ]] || { echo "error: executable not found: $BINARY" >&2; exit 1; }
command -v dpkg-deb >/dev/null || { echo "error: dpkg-deb is required" >&2; exit 1; }

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/pharos-deb.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/pharos-mesh"

install -d \
  "$PKG/DEBIAN" \
  "$PKG/usr/bin" \
  "$PKG/usr/lib/systemd/system" \
  "$PKG/usr/share/doc/pharos-mesh"
install -m 0755 "$BINARY" "$PKG/usr/bin/pharos"
ln -sf pharos "$PKG/usr/bin/pharos-mesh"
if [[ -x "$(dirname "$BINARY")/pharos-meshd" ]]; then
  install -m 0755 "$(dirname "$BINARY")/pharos-meshd" "$PKG/usr/bin/pharos-meshd"
fi
if [[ -x "$(dirname "$BINARY")/pharos-web" ]]; then
  install -m 0755 "$(dirname "$BINARY")/pharos-web" "$PKG/usr/bin/pharos-web"
fi
install -m 0644 "$ROOT/Packaging/debian/pharos-mesh.service" \
  "$PKG/usr/lib/systemd/system/pharos-mesh.service"
install -m 0644 "$ROOT/docs/MESH_HEADLESS.md" "$PKG/usr/share/doc/pharos-mesh/README.md"
install -m 0755 "$ROOT/Packaging/debian/postinst" "$PKG/DEBIAN/postinst"
install -m 0755 "$ROOT/Packaging/debian/prerm" "$PKG/DEBIAN/prerm"
install -m 0755 "$ROOT/Packaging/debian/postrm" "$PKG/DEBIAN/postrm"

INSTALLED_SIZE=$(du -sk "$PKG/usr" | awk '{print $1}')
cat > "$PKG/DEBIAN/control" <<EOF
Package: pharos-mesh
Version: $VERSION
Section: devel
Priority: optional
Architecture: $ARCH
Maintainer: Pai <baixianger@gmail.com>
Depends: adduser, libc6, libsqlite3-0, libstdc++6, ca-certificates
Recommends: qrencode
Installed-Size: $INSTALLED_SIZE
Homepage: https://github.com/baixianger/pharos
Description: Pharos Rust backend CLI and daemon helpers
 Phase E ships the Rust \`pharos\` CLI (compat symlink \`pharos-mesh\`) plus
 optional \`pharos-meshd\` / \`pharos-web\` helpers. The Swift Mesh backend is gone.
EOF
mkdir -p "$OUTPUT_DIR"
OUT="$OUTPUT_DIR/pharos-mesh_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group --build "$PKG" "$OUT"
sha256sum "$OUT"
