#!/bin/sh
# Freezes the last shipped build's packet reader into SessionKit's tests (#317).
#
#   scripts/freeze-shipped-reader.sh             copy it from $SHIPPED_TAG (default testflight/0.1-build-29)
#   scripts/freeze-shipped-reader.sh --check     fail if the frozen copy differs from that tag
#
# Packets exported by a new build must import into the last shipped build (AGENTS.md). Build 29's
# reader rejects unknown manifest keys, so a new packet field would break import there silently.
# This copies that build's SessionKit and SessionKitSharing sources, verbatim except that
# `import SessionKit` becomes `import ShippedSessionKit`, into Packages/SessionKit/Tests/ShippedReader.
# Package.swift builds them as the ShippedSessionKit and ShippedSessionKitSharing modules, and
# SharingTests' exportPacket helper reads every exported packet back with them.
# After the next release, run it with the new tag and update ShippedPacketReader.build.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
tag=${SHIPPED_TAG:-testflight/0.1-build-29}
frozen="$repo/Packages/SessionKit/Tests/ShippedReader"
work=$(mktemp -d "${TMPDIR:-/tmp}/shipped-reader.XXXXXX")
trap 'rm -rf "$work"' EXIT

git -C "$repo" archive "$tag" Packages/SessionKit/Sources/SessionKit Packages/SessionKit/Sources/SessionKitSharing \
    | tar -x -C "$work"
mkdir -p "$work/out"
mv "$work/Packages/SessionKit/Sources/SessionKit" "$work/out/SessionKit"
mv "$work/Packages/SessionKit/Sources/SessionKitSharing" "$work/out/SessionKitSharing"
for file in "$work"/out/SessionKitSharing/*.swift; do
    sed 's/^import SessionKit$/import ShippedSessionKit/' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
done

if [ "${1:-}" = "--check" ]; then
    for part in SessionKit SessionKitSharing; do
        if ! diff -r "$work/out/$part" "$frozen/$part" > "$work/diff.txt"; then
            echo "FAIL the frozen $part differs from $tag:" >&2
            head -20 "$work/diff.txt" >&2
            exit 1
        fi
    done
    echo "ok: the frozen reader matches $tag ($(git -C "$repo" rev-parse --short "$tag^{commit}"))"
    exit 0
fi

rm -rf "$frozen/SessionKit" "$frozen/SessionKitSharing"
mkdir -p "$frozen"
mv "$work/out/SessionKit" "$work/out/SessionKitSharing" "$frozen/"
echo "froze the packet reader from $tag ($(git -C "$repo" rev-parse --short "$tag^{commit}")) into $frozen"
