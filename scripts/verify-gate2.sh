#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/Packages/SessionKit"
PYTHON="$ROOT/.venv/bin/python"

"$ROOT/scripts/bootstrap-python-tools.sh"
"$PYTHON" "$ROOT/scripts/validate-contracts.py"

cd "$PACKAGE"
swift build --build-tests
xcrun xctest .build/arm64-apple-macosx/debug/SessionKitPackageTests.xctest

cd "$ROOT"
xcodegen generate
xcodebuild \
  -project SpokenMarginsNative.xcodeproj \
  -scheme SpokenMarginsApp \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  -quiet \
  build

PHONE_UDID="${PHONE_UDID:-${DEVICE_UDID:-}}"
if [[ -z "$PHONE_UDID" ]]; then
  PHONE_UDID="$(xcrun simctl list devices available | sed -nE '/iPhone 17 / { s/.*\(([0-9A-Fa-f-]{36})\).*/\1/p; q; }')"
fi

if [[ -z "$PHONE_UDID" ]]; then
  echo "No available iPhone simulator found for Gate 2 validation. Set PHONE_UDID or DEVICE_UDID explicitly." >&2
  exit 1
fi

xcrun simctl boot "$PHONE_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$PHONE_UDID" -b

xcodebuild \
  -project SpokenMarginsNative.xcodeproj \
  -scheme SpokenMarginsApp \
  -sdk iphonesimulator \
  -destination "id=$PHONE_UDID" \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:SpokenMarginsAppTests/Gate2CompactControlTests \
  -quiet \
  test

xcodebuild \
  -project SpokenMarginsNative.xcodeproj \
  -scheme SpokenMarginsApp \
  -sdk iphonesimulator \
  -destination "id=$PHONE_UDID" \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:SpokenMarginsAppUITests/Gate1FlowUITests/testGate2CompactValidationControlsDelegateTransportCommands \
  -quiet \
  test
