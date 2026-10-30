#!/bin/sh
# Proves a database written by this checkout still opens in the shipped builds' own
# persistence code (Build 29, 32 and 34), with the Library, items, podcasts and Margins
# readable. This is the owner's condition for storing I13 structured documents (C1 M3, #191).
# The file keeps its Build 29 name because shipped-build-compat.yml runs it by that name.
#
#   scripts/check-build29-database.sh
#   BUILD29_TAG=<tag> scripts/check-build29-database.sh   # one tag only, named Build 29
#
# 1. The current SessionKit writes a database through the real import paths
#    (Build29DatabaseFixtureTests): a v1 PDF item, an extraction v2 PDF item
#    with its I13 document, and a v1 item moved to v2 by a re-import, each
#    with a session and a written Margin, a streamed podcast with a saved download and a
#    Margin placed by media time, and an imported audio file linked to its episode (#1900).
# 2. Each shipped build's SessionKit and SessionKitPersistence sources, taken from its
#    testflight/0.1-build-N tag, are built into a small reader
#    (scripts/build29-db-reader) that opens it the way that build does.
# Needs Xcode's Swift toolchain. Touches nothing outside a temporary folder.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/build29-db.XXXXXX")
trap 'rm -rf "$work"' EXIT
db="$work/current.sqlite"

# A step's own exit status decides, not the summary lines grep picks out of its output: a failing XCTest
# in the writer used to vanish into `swift test | grep | tail` and the script still passed (#1899).
summarize() { printf '%s\n' "$1" | grep -E "error|Executed .* test" | tail -2 || true; }

echo "== writing a database with the current code"
status=0
out=$(SM_BUILD29_DB="$db" swift test --package-path "$repo/Packages/SessionKit" --filter Build29DatabaseFixtureTests 2>&1) || status=$?
summarize "$out"
[ "$status" -eq 0 ] || { echo "FAIL the writer's tests failed (swift test exited $status)" >&2; exit 1; }
[ -f "$db.expected.json" ] || { echo "FAIL the writer produced no database" >&2; exit 1; }

# Opens the database with one shipped build's own persistence code. $1 is its tag, $2 its name.
check_build() {
    tag=$1
    name=$2
    dir=$work/$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '-')
    echo "== building $name's persistence code from $tag ($(git -C "$repo" rev-parse --short "$tag^{commit}"))"
    mkdir -p "$dir/reader"
    git -C "$repo" archive "$tag" Packages/SessionKit/Sources/SessionKit Packages/SessionKit/Sources/SessionKitPersistence \
        | tar -x -C "$dir"
    cp "$repo/scripts/build29-db-reader/main.swift" "$dir/reader/main.swift"
    # Item.linkedEpisode (#755) first shipped in a build after 29; only a reader built from such a tag checks it.
    settings=""
    if grep -q "linkedEpisode" "$dir/Packages/SessionKit/Sources/SessionKit/Models.swift"; then
        settings=', swiftSettings: [.define("HAS_LINKED_EPISODE")]'
    fi
    cat > "$dir/Package.swift" <<SWIFT
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ShippedBuildReader",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "SessionKit", path: "Packages/SessionKit/Sources/SessionKit"),
        .target(name: "SessionKitPersistence", dependencies: ["SessionKit"],
                path: "Packages/SessionKit/Sources/SessionKitPersistence",
                linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "reader", dependencies: ["SessionKit", "SessionKitPersistence"], path: "reader"$settings),
    ]
)
SWIFT
    status=0
    out=$(swift build --package-path "$dir" 2>&1) || status=$?
    printf '%s\n' "$out" | grep -E "error|Compiling reader|Build complete" | tail -3 || true
    [ "$status" -eq 0 ] || { echo "FAIL $name's reader did not build (swift build exited $status)" >&2; exit 1; }

    echo "== reading it with $name"
    "$dir/.build/debug/reader" "$db" "$name"
}

# BUILD29_TAG names one tag to check, as Build 29 (the tests use it). Without it, every shipped build the
# owner's packet and database compatibility rule covers is checked against the same database: Build 29, 32 and 34.
if [ -n "${BUILD29_TAG:-}" ]; then
    check_build "$BUILD29_TAG" "Build 29"
else
    check_build testflight/0.1-build-29 "Build 29"
    check_build testflight/0.1-build-32 "Build 32"
    check_build testflight/0.1-build-34 "Build 34"
fi
