#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/Packages/SessionKit"

cd "$PACKAGE"
# Let SwiftPM select every test product. Toolchains can emit either an aggregate
# PackageTests bundle or separate target bundles; a fixed bundle path skips/fails
# valid tests after that layout changes. The outer runner verifies exact test IDs.
# A full run takes a Mac-wide host-test slot (#350); inside verify-tests.py it already holds one.
# Inside Codex's sandbox (CODEX_SANDBOX is set) SwiftPM can't start its own sandbox for the
# manifest ("sandbox_apply: Operation not permitted"), so it runs without one there.
#
# --build-only builds the package and its tests; --skip-build then runs the tests without building.
# verify-tests.py uses the pair so a slow build can't eat the tests' time limit (#844). With no
# argument it builds and tests, as before.
SANDBOX=()
if [[ -n "${CODEX_SANDBOX:-}" ]]; then
  SANDBOX=(--disable-sandbox)
fi
case "${1:-}" in
  --build-only) exec "$ROOT/scripts/host-test-lane" swift build --build-tests ${SANDBOX[@]+"${SANDBOX[@]}"} ;;
  --skip-build) exec "$ROOT/scripts/host-test-lane" swift test --skip-build ${SANDBOX[@]+"${SANDBOX[@]}"} ;;
  "") exec "$ROOT/scripts/host-test-lane" swift test ${SANDBOX[@]+"${SANDBOX[@]}"} ;;
  *) echo "usage: $0 [--build-only | --skip-build]" >&2; exit 2 ;;
esac
