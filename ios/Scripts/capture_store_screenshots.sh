#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${PHAROS_SCREENSHOT_APP:-/tmp/pharos-shots-derived/Build/Products/Debug-iphonesimulator/PharosMobile.app}"
RAW="$ROOT/fastlane/raw-demo"
BUNDLE_ID="me.pai.pharos.mobile"

simulator_id() {
  local pattern="$1"
  xcrun simctl list devices available | awk -v pattern="$pattern" '
    index($0, pattern) {
      for (i = 1; i <= NF; i++) {
        value = $i
        gsub(/[()]/, "", value)
        if (length(value) == 36 && value ~ /^[0-9A-F-]+$/) { print value; exit }
      }
    }'
}

IPHONE="${PHAROS_IPHONE_UDID:-$(simulator_id "iPhone 17 Pro Max")}"
IPAD="${PHAROS_IPAD_UDID:-$(simulator_id "iPad Pro 13")}"

IFS=' ' read -r -a SCENES <<< "${PHAROS_SCREENSHOT_SCENES:-projects issues agents chat}"

if [[ ! -d "$APP" ]]; then
  echo "Missing simulator app: $APP" >&2
  echo "Build first with xcodebuild -derivedDataPath /tmp/pharos-shots-derived." >&2
  exit 1
fi

mkdir -p "$RAW"
for device in iphone ipad; do
  for scene in "${SCENES[@]}"; do
    rm -f "$RAW/$device-$scene.png"
  done
done

for spec in "iphone:$IPHONE:1320:2868" "ipad:$IPAD:2064:2752"; do
  IFS=: read -r device udid expected_w expected_h <<< "$spec"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  # Status-bar punctuation follows device locale. Pin en_US, then reboot so
  # the 9:41 override renders with a colon rather than a locale-specific dot.
  xcrun simctl spawn "$udid" defaults write "Apple Global Domain" AppleLocale -string en_US
  xcrun simctl spawn "$udid" defaults write "Apple Global Domain" AppleLanguages -array en
  xcrun simctl shutdown "$udid"
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl install "$udid" "$APP"
  xcrun simctl status_bar "$udid" override \
    --time 09:41 --batteryState charged --batteryLevel 100 --cellularMode active --wifiBars 3

  for scene in "${SCENES[@]}"; do
    xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
    SIMCTL_CHILD_PHAROS_DEMO=1 SIMCTL_CHILD_PHAROS_SCENE="$scene" \
      xcrun simctl launch --terminate-running-process "$udid" "$BUNDLE_ID" >/dev/null
    sleep 3
    output="$RAW/$device-$scene.png"
    xcrun simctl io "$udid" screenshot "$output" >/dev/null
    dimensions="$(sips -g pixelWidth -g pixelHeight "$output" | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w "x" h}')"
    if [[ "$dimensions" != "${expected_w}x${expected_h}" ]]; then
      echo "Unexpected dimensions for $output: $dimensions" >&2
      exit 1
    fi
    echo "captured $device-$scene ($dimensions)"
  done

  xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
done

"$ROOT/Scripts/frame_store_screenshots.py"
