#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_UDID="${DEVICE_UDID:-}"

cd "$ROOT"

xcodegen generate
xcodebuild \
  -project SpokenMarginsNative.xcodeproj \
  -scheme SpokenMarginsApp \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY='-' \
  -quiet \
  clean build

if [[ -z "$DEVICE_UDID" ]]; then
  DEVICE_UDID="$(xcrun simctl list devices available | awk '/iPhone 17 \\(/ { gsub(/[()]/, "", $NF); print $NF; exit }')"
fi

if [[ -z "$DEVICE_UDID" ]]; then
  echo "No available iPhone simulator found. Set DEVICE_UDID explicitly." >&2
  exit 1
fi

APP="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*Debug-iphonesimulator/SpokenMarginsApp.app' -type d | tail -1)"
if [[ -z "$APP" ]]; then
  echo "Built app not found in DerivedData." >&2
  exit 1
fi

if [[ -d "$APP/Resources" ]]; then
  echo "Invalid iOS bundle: top-level Resources/ directory triggers simulator install failure." >&2
  exit 1
fi

xcrun simctl boot "$DEVICE_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE_UDID" -b
xcrun simctl install "$DEVICE_UDID" "$APP"
xcrun simctl launch "$DEVICE_UDID" com.spokenmargins.native
sleep 3

mkdir -p "$ROOT/artifacts/gate1"
xcrun simctl io "$DEVICE_UDID" screenshot "$ROOT/artifacts/gate1/iphone-launch.png" >/dev/null
echo "Simulator smoke passed. Screenshot: $ROOT/artifacts/gate1/iphone-launch.png"
