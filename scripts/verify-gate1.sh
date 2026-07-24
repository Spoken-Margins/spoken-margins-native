#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="$ROOT/.venv/bin/python"

"$ROOT/scripts/bootstrap-python-tools.sh"
"$PYTHON" "$ROOT/scripts/validate-contracts.py"
"$PYTHON" "$ROOT/scripts/validate-surface-contracts.py"
"$ROOT/scripts/run-sessionkit-tests.sh"

cd "$ROOT"

xcodegen generate
xcodebuild \
  -project SpokenMarginsNative.xcodeproj \
  -scheme SpokenMarginsApp \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY='-' \
  -quiet \
  build

PHONE_UDID="${PHONE_UDID:-${DEVICE_UDID:-}}"
IPAD_UDID="${IPAD_UDID:-}"

if [[ -z "$PHONE_UDID" ]]; then
  PHONE_UDID="$(xcrun simctl list devices available | sed -nE '/iPhone 17 / { s/.*\(([0-9A-Fa-f-]{36})\).*/\1/p; q; }')"
fi

if [[ -z "$IPAD_UDID" ]]; then
  IPAD_UDID="$(xcrun simctl list devices available | sed -nE '/iPad/ { s/.*\(([0-9A-Fa-f-]{36})\).*/\1/p; q; }')"
fi

if [[ -z "$PHONE_UDID" ]]; then
  echo "No available iPhone simulator found for UI validation. Set PHONE_UDID or DEVICE_UDID explicitly." >&2
  exit 1
fi

if [[ -z "$IPAD_UDID" ]]; then
  echo "No available iPad simulator found for UI validation. Set IPAD_UDID explicitly." >&2
  exit 1
fi

run_ui_test() {
  local label="$1"
  local udid="$2"

  echo "Running Gate 1 UI validation on ${label} (${udid})."
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b

  xcodebuild \
    -project SpokenMarginsNative.xcodeproj \
    -scheme SpokenMarginsApp \
    -sdk iphonesimulator \
    -destination "id=$udid" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_IDENTITY='-' \
    -only-testing:SpokenMarginsAppUITests/Gate1FlowUITests \
    -quiet \
    test
}

run_ui_test "iPhone" "$PHONE_UDID"
run_ui_test "iPad" "$IPAD_UDID"
