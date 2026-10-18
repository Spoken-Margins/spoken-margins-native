#!/bin/zsh
# One-time setup at the Mac (#1790): build the recorder app, install it in ~/Applications, and ask macOS for its
# two permissions so the owner can click Allow. Run it again after loopback.swift changes: macOS treats a
# rebuilt ad-hoc app as a new app and asks again. README, The recorder app.
# Usage, from the repo folder in Terminal: ops/audio-loopback/setup-recorder-app.sh
set -euo pipefail
here=${0:A:h}
name=SpokenMarginsLaneRecorder
dest=${SM_LOOPBACK_APP:-$HOME/Applications/$name.app}
if [[ $dest != */$name.app ]]; then
  print -u2 "setup-recorder-app.sh: SM_LOOPBACK_APP must end in /$name.app, got $dest"
  exit 2
fi

print "Step 1 of 4: building the recorder app. This takes about a minute."
built=$("$here/build-app.sh")
mkdir -p "${dest:h}"
rm -rf "$dest"
ditto "$built" "$dest"
print "Installed $dest"
print

state=${SM_LANE_STATE_DIR:-$HOME/Library/Caches/SpokenMarginsLane}
mkdir -p "$state/recorder-jobs"
job=$(mktemp -d "$state/recorder-jobs/setup.XXXXXX")

print "Step 2 of 4: macOS will now show up to two boxes, one after the other."
print "  Box 1 says: \"Spoken Margins Lane Recorder\" would like to access the microphone."
print "    Click Allow (on some versions it says OK)."
print "  Box 2 says: \"Spoken Margins Lane Recorder\" would like to access Speech Recognition."
print "    Click Allow (on some versions it says OK)."
print "  If a box doesn't show, look behind your other windows. This script waits up to 10 minutes per box."
print "  It only ever records BlackHole, the silent virtual speaker, never your real microphone."
print
/usr/bin/open -n -a "$dest" --args --job "$job" permissions
waited=0
while [[ ! -f $job/status ]] && (( waited < 1300 )); do
  sleep 1
  waited=$(( waited + 1 ))
done
setup_status=$(cat "$job/status" 2>/dev/null || print missing)

print "Step 3 of 4: what macOS answered."
cat "$job/stdout" 2>/dev/null || true
rm -rf "$job"
print
if [[ $setup_status == 0 ]]; then
  print "Both are allowed."
  print
  print "Step 4 of 4: a 10-second test. You won't hear anything: the voice goes to BlackHole, not your speakers."
  proof=$state/recorder-jobs/setup-proof
  rm -rf "$proof"
  mkdir -p "$proof"
  phrase="The quick brown fox jumps over the lazy dog."
  print -r -- "$phrase" > "$proof/expected.txt"
  python3 "$here/loopback.py" app-run --timeout 40 --collect "recording.wav=$proof/recording.wav" \
    -- record --device "BlackHole 2ch" --seconds 8 --out '{job}/recording.wav' 2>/dev/null &
  recorder=$!
  sleep 2
  say -a "BlackHole 2ch" "$phrase" || true
  wait $recorder || true
  if python3 "$here/loopback.py" check "$proof/recording.wav" --allow-trailing --min-sound 1 \
      --expected "$proof/expected.txt" --max-wer 0.3 --via-app > "$proof/report.json" 2>&1; then
    print "Done. The recorder heard and understood the test sentence."
    print "Lane audio checks can now hear the Simulator unattended. You can close this window."
    exit 0
  fi
  print "The permissions are set, but the 10-second test didn't pass. Its report is in $proof/report.json."
  print "Tell Claude: \"the recorder test failed\". Nothing else is needed from you."
  exit 1
fi
print "Not done yet: at least one permission isn't allowed."
print "  1. Open System Settings, then Privacy & Security, then Microphone."
print "  2. Turn on Spoken Margins Lane Recorder."
print "  3. Go back to Privacy & Security, open Speech Recognition, and turn on Spoken Margins Lane Recorder."
print "  4. Run this script again. It should end with \"Done. Both are allowed.\""
exit 1
