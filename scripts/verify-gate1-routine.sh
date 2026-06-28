#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/Packages/SessionKit"

python3 "$ROOT/scripts/validate-contracts.py"
python3 "$ROOT/scripts/validate-surface-contracts.py"

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
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY='-' \
  -quiet \
  build
