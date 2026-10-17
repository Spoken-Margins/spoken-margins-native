#!/bin/zsh
# Builds the loopback CLI into .build/loopback (git-ignored). The Info.plist is embedded so macOS can ask
# for microphone and speech recognition access by name.
set -euo pipefail
here=${0:A:h}
mkdir -p "$here/.build"
swiftc -O -swift-version 5 "$here/loopback.swift" -o "$here/.build/loopback" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$here/Info.plist"
echo "$here/.build/loopback"
