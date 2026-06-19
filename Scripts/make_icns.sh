#!/usr/bin/env bash
# Generate Icon.icns from assets/icon-source.png using sips + iconutil.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/assets/icon-source.png}"
SET="$ROOT/.build/Icon.iconset"

[[ -f "$SRC" ]] || { echo "ERROR: source $SRC not found" >&2; exit 1; }
rm -rf "$SET"; mkdir -p "$SET"

gen() { sips -z "$1" "$1" "$SRC" --out "$SET/$2" >/dev/null; }
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
gen 1024 icon_512x512@2x.png

iconutil -c icns "$SET" -o "$ROOT/Icon.icns"
echo "Wrote $ROOT/Icon.icns"
