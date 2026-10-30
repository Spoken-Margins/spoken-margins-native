#!/bin/sh
# Proves a database written by this checkout still opens in the shipped builds' own
# persistence code (Build 29, 32 and 34), with the Library, items, podcasts and Margins
# readable. This is the owner's condition for storing I13 structured documents (C1 M3, #191).
# It also imports every packet the current exporter tests write with each of those builds'
# own importer (#1900): the frozen reader in Tests/ShippedReader covers Build 29 only.
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
#    In the same run, SessionKitTests' exporter tests keep every packet Build 29's frozen reader
#    accepted, with the Margin ids it carries (exportPacket, SM_SHIPPED_PACKETS_DIR).
# 2. Each shipped build's SessionKit, SessionKitPersistence and SessionKitSharing sources, taken
#    from its testflight/0.1-build-N tag, are built into two small readers
#    (scripts/build29-db-reader): one opens the database and one imports every packet, the way
#    that build does.
# Needs Xcode's Swift toolchain. Touches nothing outside a temporary folder.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/build29-db.XXXXXX")
trap 'rm -rf "$work"' EXIT
db="$work/current.sqlite"
packets="$work/packets"

# A step's own exit status decides, not the summary lines grep picks out of its output: a failing XCTest
# in the writer used to vanish into `swift test | grep | tail` and the script still passed (#1899).
summarize() { printf '%s\n' "$1" | grep -E "error|Executed .* test" | tail -2 || true; }

echo "== writing a database and packets with the current code"
mkdir -p "$packets"
# Only the SessionKitTests classes that export a packet: the rest of that target holds real-time AVFoundation
# tests that need a sound output, which the hosted runner leaves out (verify-tests.py PORTABLE_LEFT_OUT).
# A file that exports with no XCTestCase class found in it fails, rather than leaving its packets out unseen.
# SM_EXPORTER_TESTS_DIR lets the script's own tests point it at sample sources.
tests_dir=${SM_EXPORTER_TESTS_DIR:-$repo/Packages/SessionKit/Tests/SessionKitTests}
exporters=""
for file in $(grep -l 'exportPacket(' "$tests_dir"/*.swift); do
    classes=$(sed -nE 's/.*class ([A-Za-z0-9_]+) *: *XCTestCase.*/\1/p' "$file")
    [ -n "$classes" ] || { echo "FAIL $(basename "$file") exports a packet but no XCTestCase class was found in it" >&2; exit 1; }
    exporters="$exporters $classes"
done
exporters=$(printf '%s\n' $exporters | sort -u | paste -sd '|' -)
[ -n "$exporters" ] || { echo "FAIL found no exporter tests in SessionKitTests" >&2; exit 1; }
status=0
out=$(SM_BUILD29_DB="$db" SM_SHIPPED_PACKETS_DIR="$packets" swift test --package-path "$repo/Packages/SessionKit" \
    --filter "Build29DatabaseFixtureTests|SessionKitTests\\.($exporters)/" 2>&1) || status=$?
summarize "$out"
[ "$status" -eq 0 ] || { echo "FAIL the writer's tests failed (swift test exited $status)" >&2; exit 1; }
[ -f "$db.expected.json" ] || { echo "FAIL the writer produced no database" >&2; exit 1; }
count=$(find "$packets" -name '*.spokenmargins' | wc -l | tr -d ' ')
[ "$count" -gt 0 ] || { echo "FAIL the exporter tests kept no packets" >&2; exit 1; }
echo "kept $count packets"
# The packet readers reuse the writer's ZIPFoundation checkout, so a shipped build must pin the same version.
zip="$repo/Packages/SessionKit/.build/checkouts/ZIPFoundation"
zip_version() { sed -n '/"identity" : "zipfoundation"/,/"version"/s/.*"version" : "\(.*\)".*/\1/p'; }
current_zip=$(zip_version < "$repo/Packages/SessionKit/Package.resolved")
[ -n "$current_zip" ] || { echo "FAIL no ZIPFoundation version in Package.resolved" >&2; exit 1; }

# Opens the database and imports the packets with one shipped build's own code. $1 is its tag, $2 its name.
check_build() {
    tag=$1
    name=$2
    dir=$work/$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '-')
    echo "== building $name's persistence code from $tag ($(git -C "$repo" rev-parse --short "$tag^{commit}"))"
    shipped_zip=$(git -C "$repo" show "$tag:Packages/SessionKit/Package.resolved" | zip_version)
    [ "$shipped_zip" = "$current_zip" ] || {
        echo "FAIL $name pins ZIPFoundation $shipped_zip, this checkout $current_zip: its packet reader would not be $name's" >&2
        exit 1
    }
    mkdir -p "$dir/reader" "$dir/packet-reader"
    git -C "$repo" archive "$tag" Packages/SessionKit/Sources/SessionKit Packages/SessionKit/Sources/SessionKitPersistence \
        Packages/SessionKit/Sources/SessionKitSharing | tar -x -C "$dir"
    cp "$repo/scripts/build29-db-reader/main.swift" "$dir/reader/main.swift"
    cp "$repo/scripts/build29-db-reader/packet-reader.swift" "$dir/packet-reader/main.swift"
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
    dependencies: [.package(path: "$zip")],
    targets: [
        .target(name: "SessionKit", path: "Packages/SessionKit/Sources/SessionKit"),
        .target(name: "SessionKitPersistence", dependencies: ["SessionKit"],
                path: "Packages/SessionKit/Sources/SessionKitPersistence",
                linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "SessionKitSharing", dependencies: ["SessionKit", .product(name: "ZIPFoundation", package: "ZIPFoundation")],
                path: "Packages/SessionKit/Sources/SessionKitSharing"),
        .executableTarget(name: "reader", dependencies: ["SessionKit", "SessionKitPersistence"], path: "reader"$settings),
        .executableTarget(name: "packet-reader", dependencies: ["SessionKit", "SessionKitSharing"], path: "packet-reader"),
    ]
)
SWIFT
    status=0
    out=$(swift build --package-path "$dir" 2>&1) || status=$?
    printf '%s\n' "$out" | grep -E "error|Compiling reader|Build complete" | tail -3 || true
    [ "$status" -eq 0 ] || { echo "FAIL $name's reader did not build (swift build exited $status)" >&2; exit 1; }

    echo "== reading it with $name"
    "$dir/.build/debug/reader" "$db" "$name"
    echo "== importing the packets with $name"
    "$dir/.build/debug/packet-reader" "$packets" "$name"
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
