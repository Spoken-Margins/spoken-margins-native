#!/bin/zsh
# Streamed-MP3 seek measurement (#2110). Needs ffmpeg with libmp3lame, swiftc and python3. Takes about 8 minutes.
# Usage: ops/stream-seek/run.sh [work directory, default artifacts/stream-seek]
set -e
HERE="${0:A:h}"
WORK="${1:-artifacts/stream-seek}"
mkdir -p "$WORK"
cd "$WORK"
if [ ! -f vbr_xing0.mp3 ]; then
  # Frequency sweep, 300 + 2t Hz, so the dominant tone in any window says which second of the file it came from.
  # Harmonics switch on and off so a VBR encoder gives the frames different sizes.
  EXPR="sin(2*PI*(300*t+t*t))*0.4+0.3*sin(2*PI*2*(300*t+t*t))*gt(mod(t,20),10)+0.1*sin(2*PI*3*(300*t+t*t))*gt(mod(t,7),3)"
  ffmpeg -loglevel error -y -f lavfi -i "aevalsrc='$EXPR':s=44100:d=1800" -c:a pcm_s16le src.wav
  for xing in 0 1; do
    ffmpeg -loglevel error -y -i src.wav -c:a libmp3lame -b:a 128k -write_xing $xing cbr_xing$xing.mp3
    ffmpeg -loglevel error -y -i src.wav -c:a libmp3lame -q:a 6 -write_xing $xing vbr_xing$xing.mp3
  done
  rm -f src.wav
fi
swiftc -O "$HERE/measure.swift" -o measure
: > results.jsonl
# Profile: bytes per second per connection, request latency in seconds, name.
for profile in "2500000 0.05 fast" "600000 0.1 slow"; do
  set -- ${=profile}
  python3 "$HERE/server.py" 8792 $1 $2 . > server.log 2>&1 &
  spid=$!
  sleep 1
  for f in cbr_xing1 cbr_xing0 vbr_xing1 vbr_xing0; do
    for p in 0 1; do
      line=$(./measure http://127.0.0.1:8792 $f.mp3 $p 2>&1 | tail -1)
      echo "{\"profile\":\"$3\",\"run\":$line}" >> results.jsonl
    done
  done
  kill $spid
done
python3 "$HERE/summarize.py" results.jsonl
