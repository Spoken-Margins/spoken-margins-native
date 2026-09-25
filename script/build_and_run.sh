#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SpokenMarginsDesktop"
BUNDLE_ID="com.spokenmargins.desktop"
PACKAGE="$ROOT_DIR/App/$APP_NAME"
BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
case "$MODE" in run|--verify|--build|--debug|--logs|--telemetry) ;; *) echo "usage: $0 [--build|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;; esac
APP_RUNNING=0
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then APP_RUNNING=1; fi
if [[ "$APP_RUNNING" == 1 && ( "$MODE" == --verify || "$MODE" == --debug ) ]]; then
  echo "Spoken Margins Desktop is already running. Save any recording and quit normally before using $MODE; this script will not force-stop it." >&2
  exit 3
fi
swift build --package-path "$PACKAGE" --product "$APP_NAME"
BIN_DIR="$(swift build --package-path "$PACKAGE" --show-bin-path)"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$BIN_DIR/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
mkdir -p "$BUNDLE/Contents/Resources"
ditto "$ROOT_DIR/App/SpokenMarginsApp/Resources/Supertonic" "$BUNDLE/Contents/Resources/Supertonic"
cp "$PACKAGE/Resources/chatterbox_worker.py" "$BUNDLE/Contents/Resources/chatterbox_worker.py"
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>Spoken Margins Desktop</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSMicrophoneUsageDescription</key><string>Record your spoken Margins when you press Interject.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Transcribe your recorded Margins for editing and copying.</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$BUNDLE"
case "$MODE" in
 --build) echo "$BUNDLE" ;;
 --debug) lldb -- "$BUNDLE/Contents/MacOS/$APP_NAME" ;;
 --logs|--telemetry)
   if [[ "$APP_RUNNING" == 0 ]]; then /usr/bin/open -n "$BUNDLE"; fi
   /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\"" ;;
 --verify) /usr/bin/open -n "$BUNDLE"; sleep 1; pgrep -x "$APP_NAME" >/dev/null ;;
 run)
   if [[ "$APP_RUNNING" == 1 ]]; then /usr/bin/open -a "$BUNDLE"; else /usr/bin/open -n "$BUNDLE"; fi
   ;;
esac
