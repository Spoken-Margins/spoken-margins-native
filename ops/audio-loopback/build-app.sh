#!/bin/zsh
# Builds SpokenMarginsLaneRecorder.app (#1790): loopback.swift as a small Mac app with its own bundle identifier,
# Microphone and Speech Recognition usage text, and the audio-input entitlement, so macOS asks for both in the
# app's own name. The lane launches it through LaunchServices, so it is its own responsible process for those
# permissions, not the runner's node. Ad-hoc signed: macOS asks again whenever the code changes.
# Usage: ops/audio-loopback/build-app.sh [destination.app]   (default .build/SpokenMarginsLaneRecorder.app)
# Prints the app's path. setup-recorder-app.sh installs it; README, The recorder app.
set -euo pipefail
here=${0:A:h}
name=SpokenMarginsLaneRecorder
app=${1:-$here/.build/$name.app}
if [[ $app != *.app ]]; then
  print -u2 "build-app.sh: the destination must end in .app, got $app"
  exit 2
fi
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
swiftc -O -swift-version 5 "$here/loopback.swift" -o "$app/Contents/MacOS/$name"
cp "$here/recorder-app/Info.plist" "$app/Contents/Info.plist"
source_hash=$(shasum -a 256 "$here/loopback.swift" | cut -d ' ' -f 1)
/usr/libexec/PlistBuddy -c "Add :SMLoopbackSourceSHA256 string $source_hash" "$app/Contents/Info.plist"
codesign --force --sign - --options runtime --entitlements "$here/recorder-app/entitlements.plist" "$app" 2>/dev/null
print -r -- "$app"
