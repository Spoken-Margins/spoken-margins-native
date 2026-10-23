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
#
# verify-tests.py splits the run (#1328): SessionKitCoreTests in parallel (--core-parallel <xunit file>; with
# --parallel SwiftPM prints no line for a passing test, so the result file is the record), and the other two
# targets serially (--rest), because they hold real-time AVFoundation tests that need the machine to themselves.
# --core-serial is the fallback when the parallel run fails. --skip-build alone runs every test serially.
# A filter is a regex on "Module.Class/test", so each group is anchored on its module names.
#
# --tools builds and tests Packages/SessionKitTools, the developer tools built on SessionKit (#1873). Its build goes
# inside SessionKit's .build, which worktrees and the lane link to a warm cache that disk relief can clear.
#
# #1956: XCTest's output to a file is block-buffered, so a hung run's log ended hundreds of results before the test
# that hung. Unbuffered, each test's "started" line reaches the log as it starts.
export NSUnbufferedIO=YES
SANDBOX=()
if [[ -n "${CODEX_SANDBOX:-}" ]]; then
  SANDBOX=(--disable-sandbox)
fi
CORE='^SessionKitCoreTests\.'
REST='^(SessionKitTests|SessionKitTraceTests)\.'
WORKERS=4  # the Mac also runs builds and other jobs: leave it room
case "${1:-}" in
  --core-parallel)
    [[ -n "${2:-}" ]] || { echo "usage: $0 --core-parallel <xunit file>" >&2; exit 2; }
    exec "$ROOT/scripts/host-test-lane" swift test --skip-build --parallel --num-workers "$WORKERS" --filter "$CORE" --xunit-output "$2" ${SANDBOX[@]+"${SANDBOX[@]}"} ;;
  --core-serial) exec "$ROOT/scripts/host-test-lane" swift test --skip-build --filter "$CORE" ${SANDBOX[@]+"${SANDBOX[@]}"} ;;
  --rest) exec "$ROOT/scripts/host-test-lane" swift test --skip-build --filter "$REST" ${SANDBOX[@]+"${SANDBOX[@]}"} ;;
  --build-only) exec "$ROOT/scripts/host-test-lane" swift build --build-tests ${SANDBOX[@]+"${SANDBOX[@]}"} ;;
  --tools) exec "$ROOT/scripts/host-test-lane" swift test --package-path "$ROOT/Packages/SessionKitTools" --scratch-path "$PACKAGE/.build/tools" ${SANDBOX[@]+"${SANDBOX[@]}"} ;;
  --skip-build) exec "$ROOT/scripts/host-test-lane" swift test --skip-build ${SANDBOX[@]+"${SANDBOX[@]}"} ;;
  "") exec "$ROOT/scripts/host-test-lane" swift test ${SANDBOX[@]+"${SANDBOX[@]}"} ;;
  *) echo "usage: $0 [--build-only | --skip-build | --core-parallel <xunit file> | --core-serial | --rest | --tools]" >&2; exit 2 ;;
esac
