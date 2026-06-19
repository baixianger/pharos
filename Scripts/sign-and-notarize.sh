#!/usr/bin/env bash
# sign-and-notarize.sh — Developer ID sign, notarize, staple, and zip Pharos.app
# for direct-download distribution (NOT Mac App Store).
#
# Pharos is intentionally NOT sandboxed: it spawns terminals, reads ~/.claude
# and ~/.codex, and uses private SkyLight APIs. Hardened Runtime is ON;
# com.apple.security.app-sandbox must NOT be in the entitlements.
#
# Usage:
#   APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARYTOOL_PROFILE="pharos-notary" \
#   Scripts/sign-and-notarize.sh
#
# Alternative (no stored keychain profile — uses raw credentials):
#   NOTARYTOOL_APPLE_ID="you@example.com" \
#   NOTARYTOOL_TEAM_ID="ABCDE12345" \
#   NOTARYTOOL_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
#   APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   Scripts/sign-and-notarize.sh
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve project root regardless of where the script is invoked from.
# ---------------------------------------------------------------------------
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# ---------------------------------------------------------------------------
# Load version info.
# ---------------------------------------------------------------------------
if [[ -f "$ROOT/version.env" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/version.env"
else
  echo "ERROR: version.env not found at $ROOT/version.env" >&2
  exit 1
fi

APP_NAME=${APP_NAME:-Pharos}
BUNDLE_ID=${BUNDLE_ID:-me.pai.pharos}
APP_BUNDLE="${APP_NAME}.app"
ZIP_NAME="${APP_NAME}-${MARKETING_VERSION}.zip"

# ---------------------------------------------------------------------------
# Require APP_IDENTITY (the Developer ID Application certificate name).
# ---------------------------------------------------------------------------
if [[ -z "${APP_IDENTITY:-}" ]]; then
  cat >&2 <<EOF
ERROR: APP_IDENTITY is not set.
Set it to your Developer ID Application certificate name, e.g.:
  export APP_IDENTITY="Developer ID Application: Your Name (TEAMID)"
EOF
  exit 1
fi

# ---------------------------------------------------------------------------
# Validate notarytool credentials: prefer a stored keychain profile; fall back
# to raw Apple ID + team + app-specific password.
# ---------------------------------------------------------------------------
USE_PROFILE=0
if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  USE_PROFILE=1
elif [[ -n "${NOTARYTOOL_APPLE_ID:-}" && -n "${NOTARYTOOL_TEAM_ID:-}" && -n "${NOTARYTOOL_APP_PASSWORD:-}" ]]; then
  USE_PROFILE=0
else
  cat >&2 <<EOF
ERROR: notarytool credentials are not set. Provide one of:

Option A — stored keychain profile (recommended):
  export NOTARYTOOL_PROFILE="pharos-notary"
  (Created via: xcrun notarytool store-credentials pharos-notary)

Option B — inline credentials:
  export NOTARYTOOL_APPLE_ID="you@apple.com"
  export NOTARYTOOL_TEAM_ID="ABCDE12345"
  export NOTARYTOOL_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
  (App-specific password from appleid.apple.com)
EOF
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: Build and assemble Pharos.app with Developer ID signing.
# package_app.sh signs with --options runtime --timestamp when APP_IDENTITY is
# set and SIGNING_MODE is not "adhoc".
# ---------------------------------------------------------------------------
echo "==> Building and packaging ${APP_BUNDLE} (Developer ID mode)..."
SIGNING_MODE=devid \
APP_IDENTITY="$APP_IDENTITY" \
APP_NAME="$APP_NAME" \
BUNDLE_ID="$BUNDLE_ID" \
ARCHES="${ARCHES:-arm64 x86_64}" \
  "$ROOT/Scripts/package_app.sh" release

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "ERROR: ${APP_BUNDLE} not found after package_app.sh" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Sanity-check: confirm the app is NOT sandboxed (belt-and-suspenders guard).
# ---------------------------------------------------------------------------
echo "==> Checking entitlements (sandbox must be absent)..."
ENTITLEMENTS_FILE="$ROOT/.build/entitlements/${APP_NAME}.entitlements"
if [[ -f "$ENTITLEMENTS_FILE" ]]; then
  if grep -q "com.apple.security.app-sandbox" "$ENTITLEMENTS_FILE"; then
    echo "ERROR: com.apple.security.app-sandbox found in entitlements." >&2
    echo "       Pharos must NOT be sandboxed. Remove that entitlement." >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Step 2: Create a temporary zip for notarization submission.
# We use ditto (preserves HFS metadata) for the upload zip only.
# ---------------------------------------------------------------------------
NOTARIZE_TMP="/tmp/${APP_NAME}Notarize_$$.zip"
trap 'rm -f "$NOTARIZE_TMP"' EXIT

echo "==> Creating notarization upload zip..."
/usr/bin/ditto --norsrc -c -k --keepParent "$APP_BUNDLE" "$NOTARIZE_TMP"

# ---------------------------------------------------------------------------
# Step 3: Submit for notarization and wait for Apple's response.
# ---------------------------------------------------------------------------
echo "==> Submitting to Apple Notary Service (this may take a few minutes)..."

if [[ "$USE_PROFILE" -eq 1 ]]; then
  xcrun notarytool submit "$NOTARIZE_TMP" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait
else
  xcrun notarytool submit "$NOTARIZE_TMP" \
    --apple-id "$NOTARYTOOL_APPLE_ID" \
    --team-id "$NOTARYTOOL_TEAM_ID" \
    --password "$NOTARYTOOL_APP_PASSWORD" \
    --wait
fi

# ---------------------------------------------------------------------------
# Step 4: Staple the notarization ticket to the app bundle.
# ---------------------------------------------------------------------------
echo "==> Stapling notarization ticket..."
xcrun stapler staple "$APP_BUNDLE"

# ---------------------------------------------------------------------------
# Step 5: Final verification.
# ---------------------------------------------------------------------------
echo "==> Verifying Gatekeeper acceptance..."
spctl --assess --type exec --verbose=4 "$APP_BUNDLE"

echo "==> Validating stapled ticket..."
xcrun stapler validate "$APP_BUNDLE"

# ---------------------------------------------------------------------------
# Step 6: Create the distribution zip (clean, no extended attributes).
# ---------------------------------------------------------------------------
echo "==> Cleaning extended attributes..."
xattr -cr "$APP_BUNDLE"
find "$APP_BUNDLE" -name '._*' -delete

echo "==> Creating distribution zip: ${ZIP_NAME}..."
rm -f "$ZIP_NAME"
/usr/bin/ditto --norsrc -c -k --keepParent "$APP_BUNDLE" "$ZIP_NAME"

echo ""
echo "Done: ${ZIP_NAME}"
echo "  App version : ${MARKETING_VERSION} (${BUILD_NUMBER})"
echo "  Identity    : ${APP_IDENTITY}"
echo ""
echo "Distribute ${ZIP_NAME} directly (e.g. GitHub Releases, website download)."
echo "Do NOT submit to the Mac App Store — Pharos requires unsandboxed access."
