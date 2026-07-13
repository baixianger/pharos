#!/usr/bin/env bash
# Build a styled Pharos disk image: branded background, the app icon on the left,
# an Applications alias on the right, and a drag-to-install layout. Zero external
# dependencies — uses hdiutil + osascript (+ optional tiffutil/SetFile).
#
# Usage: Scripts/make_dmg.sh            # builds Pharos-<version>.dmg at the repo root
# Requires Pharos.app to already exist (run Scripts/package_app.sh first).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-Pharos}"
APP="$ROOT/${APP_NAME}.app"
[[ -d "$APP" ]] || { echo "error: ${APP_NAME}.app not found — run Scripts/package_app.sh first." >&2; exit 1; }

# shellcheck disable=SC1091
[[ -f "$ROOT/version.env" ]] && source "$ROOT/version.env"
VERSION="${MARKETING_VERSION:-dev}"
VOLNAME="$APP_NAME"
DMG_FINAL="$ROOT/${APP_NAME}-${VERSION}.dmg"

# Layout (must match assets/dmg-background.svg: 660x400 window, icons at y=205).
WIN_W=660; WIN_H=400; ICON_SIZE=112
APP_X=180; APP_Y=205; APPS_X=480; APPS_Y=205

STAGING="$(mktemp -d)"
DMG_TMP="$(mktemp -u).dmg"
cleanup() { rm -rf "$STAGING" "$DMG_TMP" 2>/dev/null || true; }
trap cleanup EXIT

echo "==> staging contents"
cp -R "$APP" "$STAGING/${APP_NAME}.app"
ln -s /Applications "$STAGING/Applications"
mkdir -p "$STAGING/.background"

# Retina-aware background: combine 1x + 2x into a multi-representation TIFF when
# tiffutil is available, else fall back to the 1x PNG.
if command -v tiffutil >/dev/null 2>&1 && [[ -f "$ROOT/assets/dmg-background@2x.png" ]]; then
  tiffutil -cathidpicheck "$ROOT/assets/dmg-background.png" "$ROOT/assets/dmg-background@2x.png" \
    -out "$STAGING/.background/background.tiff" >/dev/null
  BG_FILE="background.tiff"
else
  cp "$ROOT/assets/dmg-background.png" "$STAGING/.background/background.png"
  BG_FILE="background.png"
fi

# Volume icon (the lighthouse), if available.
if [[ -f "$ROOT/Icon.icns" ]]; then
  cp "$ROOT/Icon.icns" "$STAGING/.VolumeIcon.icns"
  command -v SetFile >/dev/null 2>&1 && SetFile -a C "$STAGING" || true
fi

echo "==> creating writable image"
SIZE_MB=$(( $(du -sm "$STAGING" | cut -f1) + 60 ))
hdiutil create -srcfolder "$STAGING" -volname "$VOLNAME" -fs HFS+ \
  -format UDRW -size "${SIZE_MB}m" "$DMG_TMP" >/dev/null

echo "==> mounting"
DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_TMP" | grep -E '^/dev/' | head -1 | awk '{print $1}')"
MOUNT="/Volumes/$VOLNAME"
sleep 2

echo "==> applying Finder layout"
osascript <<OSA
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, $((200 + WIN_W)), $((120 + WIN_H))}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to $ICON_SIZE
    set text size of opts to 12
    set background picture of opts to file ".background:$BG_FILE"
    set position of item "${APP_NAME}.app" of container window to {$APP_X, $APP_Y}
    set position of item "Applications" of container window to {$APPS_X, $APPS_Y}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA

echo "==> finalizing"
chmod -Rf go-w "$MOUNT" 2>/dev/null || true
sync
hdiutil detach "$DEV" >/dev/null || hdiutil detach "$DEV" -force >/dev/null
rm -f "$DMG_FINAL"
hdiutil convert "$DMG_TMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL" >/dev/null

echo "Created $DMG_FINAL ($(du -h "$DMG_FINAL" | cut -f1))"

# ---------------------------------------------------------------------------
# Optional: Developer ID sign + notarize + staple the DMG itself, so a
# downloaded DMG opens without a Gatekeeper prompt. Skipped entirely when
# APP_IDENTITY is unset (the ad-hoc default — first launch needs right-click →
# Open). For a fully clean release the app INSIDE should already be
# Developer-ID-signed + stapled — run Scripts/sign-and-notarize.sh first, or use
# Scripts/release.sh which chains both.
# ---------------------------------------------------------------------------
if [[ -n "${APP_IDENTITY:-}" ]]; then
  echo "==> signing DMG with $APP_IDENTITY"
  codesign --force --sign "$APP_IDENTITY" --timestamp "$DMG_FINAL"

  echo "==> submitting DMG to the Apple Notary Service (a few minutes)…"
  if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG_FINAL" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
  elif [[ -n "${NOTARYTOOL_APPLE_ID:-}" && -n "${NOTARYTOOL_TEAM_ID:-}" && -n "${NOTARYTOOL_APP_PASSWORD:-}" ]]; then
    xcrun notarytool submit "$DMG_FINAL" \
      --apple-id "$NOTARYTOOL_APPLE_ID" --team-id "$NOTARYTOOL_TEAM_ID" \
      --password "$NOTARYTOOL_APP_PASSWORD" --wait
  else
    echo "ERROR: APP_IDENTITY set but no notarytool credentials." >&2
    echo "       Set NOTARYTOOL_PROFILE, or NOTARYTOOL_APPLE_ID/TEAM_ID/APP_PASSWORD." >&2
    exit 1
  fi

  echo "==> stapling ticket to DMG"
  xcrun stapler staple "$DMG_FINAL"
  xcrun stapler validate "$DMG_FINAL"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_FINAL" || true
  echo "Notarized + stapled: $DMG_FINAL — downloads open without a Gatekeeper prompt."
else
  echo "Note: ad-hoc DMG (no APP_IDENTITY). First launch needs right-click → Open."
  echo "      For a notarized DMG, run Scripts/release.sh (see docs/RELEASE.md)."
fi
