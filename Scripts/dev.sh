#!/usr/bin/env bash
# Build the icon, package Pharos.app (ad-hoc signed), and launch it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export APP_NAME=Pharos
export BUNDLE_ID=me.pai.pharos
export MACOS_MIN_VERSION=26.0

"$ROOT/Scripts/make_icns.sh"
exec "$ROOT/Scripts/compile_and_run.sh" "$@"
