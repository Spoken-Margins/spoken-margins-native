#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/Packages/SessionKit"

cd "$PACKAGE"
swift build --build-tests

XCTEST_BUNDLE="$(find .build -type d -name 'SessionKitPackageTests.xctest' -path '*/debug/*' | sort | head -n 1)"
if [[ -z "$XCTEST_BUNDLE" ]]; then
  echo "SessionKitPackageTests.xctest was not produced by swift build --build-tests." >&2
  exit 1
fi

xcrun xctest "$XCTEST_BUNDLE"
