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
if [[ -n "${CODEX_SANDBOX:-}" ]]; then
  exec "$ROOT/scripts/host-test-lane" swift test --disable-sandbox
fi
"$ROOT/scripts/host-test-lane" swift test
