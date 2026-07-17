#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${1:-}
ARCH=${2:-}
BINARY=${3:-}
OUTPUT_DIR=${4:-"$ROOT/dist"}

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
  "$PKG/usr/lib/systemd/user" \
  "$PKG/etc" \
  "$PKG/usr/share/doc/pharos-mesh"
install -m 0755 "$BINARY" "$PKG/usr/bin/pharos-mesh"
install -m 0644 "$ROOT/Packaging/debian/pharos-mesh.service" \
  "$PKG/usr/lib/systemd/system/pharos-mesh.service"
install -m 0644 "$ROOT/Packaging/debian/pharos-mesh-node.service" \
  "$PKG/usr/lib/systemd/user/pharos-mesh-node.service"
install -m 0644 "$ROOT/Packaging/debian/pharos-mesh.env" "$PKG/etc/pharos-mesh.env"
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
Depends: libc6, libstdc++6
Recommends: qrencode
Installed-Size: $INSTALLED_SIZE
Homepage: https://github.com/baixianger/pharos
Description: Headless data broker and CLI for Pharos
 Pharos Mesh stores revisioned project data, backups, chat transcripts, and
 attachments for Pharos clients over a private Tailscale network. This package
 installs the portable Broker, CLI, system service, and an optional per-user
 Host node. The node only controls registered tmux panes owned by that user.
EOF
printf '%s\n' '/etc/pharos-mesh.env' > "$PKG/DEBIAN/conffiles"

mkdir -p "$OUTPUT_DIR"
OUT="$OUTPUT_DIR/pharos-mesh_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group --build "$PKG" "$OUT"
sha256sum "$OUT"
