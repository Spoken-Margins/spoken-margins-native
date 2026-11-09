#!/bin/zsh
# Builds sim-audio-pin into ~/SpokenMarginsOps/audio-loopback and runs it for good through launchd. Safe to run again.
set -euo pipefail
here=${0:A:h}
home_dir=~/SpokenMarginsOps/audio-loopback
binary=$home_dir/sim-audio-pin
label=com.spokenmargins.sim-audio-pin
plist=~/Library/LaunchAgents/$label.plist
mkdir -p "$home_dir"
clang -O2 -fobjc-arc -framework Foundation "$here/sim-audio-pin.m" -o "$binary.new"
mv -f "$binary.new" "$binary"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$binary</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>$home_dir/sim-audio-pin.log</string>
  <key>StandardOutPath</key><string>/dev/null</string>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "installed: $binary"
