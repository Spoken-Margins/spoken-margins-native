#!/bin/zsh
# Checks the PhononCore.xcframework the app links against a build from source (#2704).
#
# The app takes Gradium's compiled core through Swift Package Manager: xn-ptts v0.4.2's Package.swift pins the
# release's PhononCore.xcframework.zip by SHA-256. This script builds the same core from the tagged source and
# compares what can be compared without a reproducible Rust build: the C header, the exported ptts_ symbols, and
# the set of Rust crates linked into the iPhone library. It also fails if a crate we keep out (the MPL-2.0 and
# networking ones a Hugging Face Hub build would pull in) shows up. On-demand only; nothing runs it on a schedule.
#
# Needs cargo and `rustup target add aarch64-apple-ios`, about 3 minutes and 3 GB under artifacts/. Run it again
# whenever the pinned tag changes in project.yml.
set -euo pipefail

TAG=v0.4.2
COMMIT=cc0c32bcad4e79121e98cb16d9a1b19f87772e82
ZIP_SHA256=d7a9dbda50e3696133a8a61d69c5c8ea85da19ec506a9de7f270333b73645efa
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="$ROOT/artifacts/phonon-core-check"
mkdir -p "$WORK"

if [[ ! -d "$WORK/xn-ptts" ]]; then
  git clone --quiet --depth 1 --branch "$TAG" https://github.com/gradium-ai/xn-ptts.git "$WORK/xn-ptts"
fi
actual=$(git -C "$WORK/xn-ptts" rev-parse HEAD)
[[ "$actual" == "$COMMIT" ]] || { print -u2 "tag $TAG is $actual, not the pinned $COMMIT"; exit 1; }

curl -fsSL -o "$WORK/PhononCore.xcframework.zip" "https://github.com/gradium-ai/xn-ptts/releases/download/$TAG/PhononCore.xcframework.zip"
got=$(shasum -a 256 "$WORK/PhononCore.xcframework.zip" | cut -d' ' -f1)
[[ "$got" == "$ZIP_SHA256" ]] || { print -u2 "release zip sha256 $got, pinned $ZIP_SHA256"; exit 1; }
rm -rf "$WORK/release" && mkdir "$WORK/release"
unzip -q "$WORK/PhononCore.xcframework.zip" -d "$WORK/release"
released="$WORK/release/PhononCore.xcframework/ios-arm64/libptts_ffi.a"

(cd "$WORK/xn-ptts" && cargo build --quiet --profile release -p ptts-ffi --target aarch64-apple-ios)
built="$WORK/xn-ptts/target/aarch64-apple-ios/release/libptts_ffi.a"

crates() { ar t "$1" | sed -E 's/-[0-9a-f]{16}.*//; s/\..*//' | grep -vE '^[0-9a-f]{16}-' | sort -u; }
symbols() { nm -gU "$1" 2>/dev/null | awk '{print $3}' | grep '^_ptts_' | sort -u; }

result=0
diff -q "$WORK/release/PhononCore.xcframework/ios-arm64/Headers/ptts.h" "$WORK/xn-ptts/ptts-ffi/include/ptts.h" >/dev/null \
  && print "header: same" || { print "header: DIFFERENT"; result=1; }
diff <(symbols "$released") <(symbols "$built") >/dev/null \
  && print "ptts_ symbols: same ($(symbols "$built" | wc -l | tr -d ' '))" || { print "ptts_ symbols: DIFFERENT"; result=1; }
diff <(crates "$released") <(crates "$built") >/dev/null \
  && print "linked crates: same ($(crates "$built" | wc -l | tr -d ' '))" || { print "linked crates: DIFFERENT"; diff <(crates "$released") <(crates "$built") || true; result=1; }
if crates "$released" | grep -qiE '^(colored|option_ext|hf_hub|hf_xet|aws_lc|reqwest)'; then
  print "kept-out crate found in the release library"; result=1
fi
exit $result
