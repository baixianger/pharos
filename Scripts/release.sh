#!/usr/bin/env bash
# release.sh — one command for a fully notarized, download-and-open release.
#
# Chains the two halves of the pipeline:
#   1. sign-and-notarize.sh  → build + Developer ID sign (hardened runtime) +
#                              notarize + staple Pharos.app  (also emits a zip)
#   2. make_dmg.sh           → build the styled DMG from the stapled app, then
#                              sign + notarize + staple the DMG itself
#
# The result — Pharos-<version>.dmg — opens on any Mac with no Gatekeeper
# prompt. Attach it to the GitHub Release.
#
# Prerequisites (see docs/RELEASE.md): an active Apple Developer Program
# membership, a "Developer ID Application" certificate in your login keychain,
# and notarytool credentials.
#
# Usage (stored keychain profile — recommended):
#   APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARYTOOL_PROFILE="pharos-notary" \
#   bash Scripts/release.sh
#
# Usage (inline credentials, e.g. CI):
#   APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARYTOOL_APPLE_ID="you@example.com" \
#   NOTARYTOOL_TEAM_ID="ABCDE12345" \
#   NOTARYTOOL_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
#   bash Scripts/release.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

if [[ -z "${APP_IDENTITY:-}" ]]; then
  cat >&2 <<'EOF'
ERROR: APP_IDENTITY is not set — release.sh produces a NOTARIZED build.
Set it to your Developer ID Application certificate, e.g.:
  APP_IDENTITY="Developer ID Application: Your Name (TEAMID)"
Find it with: security find-identity -v -p codesigning | grep "Developer ID Application"
For an ad-hoc (non-notarized) DMG, use Scripts/package_app.sh + Scripts/make_dmg.sh instead.
EOF
  exit 1
fi
if [[ -z "${NOTARYTOOL_PROFILE:-}" && ( -z "${NOTARYTOOL_APPLE_ID:-}" || -z "${NOTARYTOOL_TEAM_ID:-}" || -z "${NOTARYTOOL_APP_PASSWORD:-}" ) ]]; then
  echo "ERROR: set NOTARYTOOL_PROFILE, or all of NOTARYTOOL_APPLE_ID / _TEAM_ID / _APP_PASSWORD." >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$ROOT/version.env"
echo "==> Releasing Pharos ${MARKETING_VERSION} (${BUILD_NUMBER})"

# 1) Build + sign + notarize + staple the .app (and its distribution zip).
echo "==> [1/2] app: sign + notarize + staple"
bash "$ROOT/Scripts/sign-and-notarize.sh"

# 2) Build the DMG from the stapled app, then sign + notarize + staple the DMG.
#    (make_dmg.sh performs the DMG notarization when APP_IDENTITY is set.)
echo "==> [2/2] dmg: build + sign + notarize + staple"
bash "$ROOT/Scripts/make_dmg.sh"

echo ""
echo "Done. Notarized, download-and-open artifacts:"
echo "  Pharos-${MARKETING_VERSION}.dmg   (attach to the GitHub Release)"
echo "  Pharos-${MARKETING_VERSION}.zip   (Sparkle appcast / mirror)"
