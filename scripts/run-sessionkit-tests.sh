#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/Packages/SessionKit"

cd "$PACKAGE"
swift build --build-tests

BIN_PATH="$(swift build --show-bin-path)"
XCTEST_BUNDLE="$BIN_PATH/SessionKitPackageTests.xctest"
if [[ ! -d "$XCTEST_BUNDLE" ]]; then
  echo "Expected XCTest bundle not found at $XCTEST_BUNDLE." >&2
  exit 1
fi

xcrun xctest "$XCTEST_BUNDLE"
