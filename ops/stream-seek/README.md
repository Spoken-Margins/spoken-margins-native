# Streamed-MP3 seek measurement (#2110)

Asks whether a streamed podcast episode can use `AVURLAssetPreferPreciseDurationAndTimingKey`, as a downloaded one does
(#2094, #2109). Run it with `ops/stream-seek/run.sh` (about 8 minutes; needs `ffmpeg` with libmp3lame and `swiftc`).
It writes to the git-ignored `artifacts/stream-seek/`.

## Method

- A 30-minute MP3 whose pitch rises with time (300 + 2·t Hz), so the dominant tone of any half-second of decoded audio says
  which second of the file it came from. Four encodings: CBR 128 kbps and VBR (`-q:a 6`), each with and without a Xing/Info
  header (`-write_xing`).
- A loopback HTTP server with byte ranges, a per-connection rate cap and a fixed request latency, counting bytes served.
  Profiles: fast (20 Mbit/s, 50 ms) and slow (4.8 Mbit/s, 100 ms).
- `measure.swift` plays the URL with a real `AVPlayer`, taps the decoded audio (`MTAudioProcessingTap`), and for each of five
  seeks (exact tolerance) reports the seek time, the megabytes fetched, and the error between the requested time and the
  time the audio came from. It runs once with the key and once without.

## Result (macOS 27 build of AVFoundation, 2026-10-24)

Without the key, every streamed VBR file seeks to the wrong place; with it, every file seeks within 1.3 s (most within 0.3 s).
The cost of the key depends on the header:

| Stream | Key off: start / seek error | Key on: start | Key on: first seeks |
| --- | --- | --- | --- |
| CBR + Info header | 0.3 s / ≤ 0.2 s | 0.3 s | 5–6 s fast, 16–24 s slow (13–15 MB) |
| CBR, no header | 0.3 s / ≤ 0.2 s | 14.5 s fast, 50 s slow (whole 29 MB file) | instant |
| VBR + Xing header | 0.3 s / up to 9 s | 0.3 s | 0.5 s fast, 4–6 s slow (3.5 MB) |
| VBR, no header | 0.3 s / up to 46 s | 3.7 s fast, 13 s slow (whole 7.7 MB file) | instant |

## What it decides

The issue's rule is "turn the key on for streams if it costs under about 1 s at start; otherwise only once downloaded". Three of
the four kinds of stream cost far more than that, and the fourth (CBR with a header) costs seconds on the first seeks while
needing nothing, because a CBR file seeks accurately without the key. So streams keep the default and the key stays on for
downloaded files. The one case that is both broken and cheap is **VBR with a Xing/VBRI header**, which a first-frame probe could
identify before the player is built; that is filed separately.
