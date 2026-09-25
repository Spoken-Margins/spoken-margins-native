#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
xcodegen generate --spec desktop-project.yml
DERIVED_PATH="${SPOKEN_MARGINS_DESKTOP_DERIVED_PATH:-/tmp/spoken-margins-desktop-derived}"
xcodebuild -project SpokenMarginsDesktopHost.xcodeproj \
  -scheme SpokenMarginsDesktop -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED_PATH" \
  -allowProvisioningUpdates build
SOURCE_BUNDLE="$DERIVED_PATH/Build/Products/Debug/SpokenMarginsDesktop.app"
OUTPUT_BUNDLE="$ROOT_DIR/dist/SpokenMarginsDesktop-5.app"
mkdir -p "$ROOT_DIR/dist"
if [[ -d "$OUTPUT_BUNDLE" ]]; then
  mv "$OUTPUT_BUNDLE" "$ROOT_DIR/dist/SpokenMarginsDesktop-5-previous-$(date +%s).app"
fi
ditto "$SOURCE_BUNDLE" "$OUTPUT_BUNDLE"
codesign --verify --deep --strict "$OUTPUT_BUNDLE"
printf '%s\n' "$OUTPUT_BUNDLE"
