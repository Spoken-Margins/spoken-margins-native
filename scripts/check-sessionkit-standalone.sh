#!/usr/bin/env bash
# Proves Packages/SessionKit builds and tests on its own, outside this repository (#1387).
#
# It copies the package (the working tree, without .build) into a temporary folder, so nothing next
# to it is reachable, then:
#   1. fails if a source file names a path outside the package (Sources/ must stand alone);
#   2. builds every target and test with `swift build --build-tests`;
#   3. with --test, runs the tests. Tests that need an input from the repository (Contracts/, Site/,
#      research/, the app's sources; see Tests/TestInputs/TestInputs.swift) report as skipped with
#      the input named, and every other test must pass.
# On demand only: nothing schedules it. A cold build fetches onnxruntime into SwiftPM's shared cache
# and takes several minutes; the temporary folder is removed afterwards.
#
# Usage: scripts/check-sessionkit-standalone.sh [--test] [extra swift arguments]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/Packages/SessionKit"
RUN_TESTS=0
if [[ "${1:-}" == "--test" ]]; then RUN_TESTS=1; shift; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sessionkit-standalone.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
rsync -a --exclude .build --exclude .swiftpm "$PACKAGE/" "$WORK/SessionKit/"
cd "$WORK/SessionKit"

# Sources read nothing by repository path. Comments may name docs, so only string literals count.
# Known exception: SpeechBench, a Mac bench tool run from the repository root, reads the app's bundled
# voice resources by default. It is narration code, left for the voice work to move (#1387 report).
LEAKS="$(grep -rnE '"(\.\./)*(Contracts|App|research|Site)/' Sources | grep -v '^Sources/SpeechBench/' || true)"
if [[ -n "$LEAKS" ]]; then
  echo "Sources name paths outside the package:" >&2
  echo "$LEAKS" >&2
  exit 1
fi
echo "Sources: no paths outside the package."

LANE=()
if [[ -x "$ROOT/scripts/host-test-lane" && "$(uname)" == "Darwin" ]]; then LANE=("$ROOT/scripts/host-test-lane"); fi

${LANE[@]+"${LANE[@]}"} swift build --build-tests "$@"
echo "Standalone build: OK in $WORK/SessionKit"

if [[ "$RUN_TESTS" == 1 ]]; then
  LOG="$WORK/test.log"
  set +e
  ${LANE[@]+"${LANE[@]}"} swift test --skip-build "$@" 2>&1 | tee "$LOG"
  STATUS=${PIPESTATUS[0]}
  set -e
  SKIPS="$(grep -c 'skipped' "$LOG" || true)"
  echo "Standalone tests: exit $STATUS; $SKIPS lines report a skip (each names the repository input it needs)."
  exit "$STATUS"
fi
