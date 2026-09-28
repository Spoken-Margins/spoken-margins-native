#!/bin/sh
# Proves a database written by this checkout still opens in Build 29's own
# persistence code, with the Library, items and Margins readable. This is the
# owner's condition for storing I13 structured documents (C1 M3, #191).
#
#   scripts/check-build29-database.sh
#
# 1. The current SessionKit writes a database through the real import paths
#    (Build29DatabaseFixtureTests): a v1 PDF item and an extraction v2 PDF item
#    with its I13 document, each with a session and a written Margin.
# 2. Build 29's SessionKit and SessionKitPersistence sources, taken from the
#    testflight/0.1-build-29 tag, are built into a small reader
#    (scripts/build29-db-reader) that opens it the way Build 29 does.
# Needs Xcode's Swift toolchain. Touches nothing outside a temporary folder.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
tag=${BUILD29_TAG:-testflight/0.1-build-29}
work=$(mktemp -d "${TMPDIR:-/tmp}/build29-db.XXXXXX")
trap 'rm -rf "$work"' EXIT
db="$work/current.sqlite"

echo "== writing a database with the current code"
SM_BUILD29_DB="$db" swift test --package-path "$repo/Packages/SessionKit" --filter Build29DatabaseFixtureTests 2>&1 \
    | grep -E "error|Executed .* test" | tail -2
[ -f "$db.expected.json" ] || { echo "FAIL the writer produced no database" >&2; exit 1; }

echo "== building Build 29's persistence code from $tag ($(git -C "$repo" rev-parse --short "$tag^{commit}"))"
mkdir -p "$work/b29/reader"
git -C "$repo" archive "$tag" Packages/SessionKit/Sources/SessionKit Packages/SessionKit/Sources/SessionKitPersistence \
    | tar -x -C "$work/b29"
cp "$repo/scripts/build29-db-reader/main.swift" "$work/b29/reader/main.swift"
cat > "$work/b29/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Build29Reader",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "SessionKit", path: "Packages/SessionKit/Sources/SessionKit"),
        .target(name: "SessionKitPersistence", dependencies: ["SessionKit"],
                path: "Packages/SessionKit/Sources/SessionKitPersistence",
                linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "reader", dependencies: ["SessionKit", "SessionKitPersistence"], path: "reader"),
    ]
)
SWIFT
swift build --package-path "$work/b29" 2>&1 | grep -E "error|Compiling reader|Build complete" | tail -3

echo "== reading it with Build 29"
"$work/b29/.build/debug/reader" "$db"
