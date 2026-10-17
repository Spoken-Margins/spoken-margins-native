#!/bin/zsh
# Host proof, no simulator: say a known phrase straight into BlackHole while recording BlackHole, then
# check the recording. The Mac's default output is never switched (the sound goes to BlackHole directly).
# Usage: ops/audio-loopback/prove-host.sh [--no-words] [output folder]   (default artifacts/loopback/host-proof)
# --no-words skips transcription, for runs whose parent app may not use Speech Recognition (README, Permissions).
set -euo pipefail
here=${0:A:h}
check_words=1
if [[ ${1:-} == --no-words ]]; then check_words=0; shift; fi
out=${1:-$here/../../artifacts/loopback/host-proof}
mkdir -p "$out"
tool=$("$here/build.sh")
phrase="The quick brown fox jumps over the lazy dog. Spoken Margins plays every word once."
print -r -- "$phrase" > "$out/expected.txt"
words=()
(( check_words )) && words=(--expected "$out/expected.txt" --max-wer 0.2)

if ! "$tool" devices | grep -q '^BlackHole 2ch'; then
  print "BlackHole 2ch is not installed; see README, Installing BlackHole" >&2
  exit 2
fi

"$tool" record --device "BlackHole 2ch" --seconds 15 --out "$out/say.wav" &
recorder=$!
sleep 1
say -a "BlackHole 2ch" "$phrase"
wait $recorder

python3 "$here/loopback.py" check "$out/say.wav" --max-stall 2 --allow-trailing --min-sound 4.5 "${words[@]}" \
  | tee "$out/report.json"
