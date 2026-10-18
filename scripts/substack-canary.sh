#!/usr/bin/env bash
# Runs the daily Substack format canary (#2027): live Substack pages through the app's own parser
# (SessionKitFeeds), on the Mac or on Linux. Usage:
#   scripts/substack-canary.sh [--scratch-path <dir>] [canary arguments, e.g. --report <file.md>]
# Exit status is the canary's (0 passed, 1 parser failure, 3 inconclusive), or 4 when it didn't build.
# On Linux, Package.swift swaps dependencies and SwiftPM rewrites Package.resolved; that file belongs to
# the Mac build, so it is restored afterwards (as in run-sessionkit-linux-tests.sh).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/Packages/SessionKit"
BACKUP="$(mktemp)"
cp "$PACKAGE/Package.resolved" "$BACKUP"
trap 'cp "$BACKUP" "$PACKAGE/Package.resolved"; rm -f "$BACKUP"' EXIT

SCRATCH=()
if [[ "${1:-}" == "--scratch-path" ]]; then
  SCRATCH=(--scratch-path "$2")
  shift 2
fi

cd "$PACKAGE"
swift build --product substack-canary ${SCRATCH[@]+"${SCRATCH[@]}"} || exit 4
swift run --skip-build ${SCRATCH[@]+"${SCRATCH[@]}"} substack-canary "$@"
