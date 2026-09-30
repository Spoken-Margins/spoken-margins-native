#!/usr/bin/env bash
# Runs SessionKitCoreTests on Linux (cloud sessions and the ubuntu CI job).
# On Linux, Package.swift swaps in swift-crypto and drops the Apple-only targets, so SwiftPM
# rewrites Package.resolved; that file belongs to the Mac build, so it is restored afterwards.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/Packages/SessionKit"
BACKUP="$(mktemp)"
cp "$PACKAGE/Package.resolved" "$BACKUP"
trap 'cp "$BACKUP" "$PACKAGE/Package.resolved"; rm -f "$BACKUP"' EXIT

cd "$PACKAGE"
swift test "$@"
