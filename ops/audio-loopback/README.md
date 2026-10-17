# Audio loopback

Lets an automated test hear what the app played (#1790). Until now an agent couldn't hear audio, so every audible bug reached the owner's phone. With [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole), a free virtual audio device, the Mac or a CI runner sends the app's sound into BlackHole instead of a speaker, records it, and checks it.

What a check answers:

1. **Did it play?** Sound segments, total sound time, peak and RMS level.
2. **Did it stop?** Gaps longer than N seconds, including silence to the end of the window. #1763 (audio stops a few seconds after locking) shows up as a long trailing gap.
3. **Did it say something twice?** Stretches of audio that replay an earlier stretch. #1762 (Supertonic repeats the first words of each chunk) shows up here, and as a repeated phrase in the transcript.
4. **Did it say the right words?** On-device transcription scored against the expected text: word error rate, missing and extra words, repeated phrases.

What it can't tell you: whether the audio sounds good (pitch, clicks, a voice that's the wrong voice but says the right words), and anything on a real phone: Bluetooth, the Lock Screen, heat. Those stay with the owner's phone.

## Files

- `loopback.swift`: the macOS tool (CoreAudio, AVFoundation and Speech; no dependencies). Build it with `./build.sh`; the binary goes to `.build/loopback`, which git ignores.
- `loopback.py`: the analysis and the `check` command. Standard library only.
- `prove-host.sh`: the host proof. Says a known phrase straight into BlackHole while recording it, then runs `check` with a stall, sound-time and word-error limit. It never switches the default output.
- `test_loopback.py`: host tests on synthetic speech-like wavs. They run in the fast plan (`verify-tests.py` runs every `ops/*/test_*.py` folder) and need no audio device.

## Quick start on the Mac

Build once:

```bash
ops/audio-loopback/build.sh
```

See the devices, and which one is the default:

```bash
ops/audio-loopback/.build/loopback devices
```

Record 30 seconds of whatever plays, with the default output switched to BlackHole for exactly that window:

```bash
python3 ops/audio-loopback/loopback.py capture --seconds 30 --out artifacts/loopback/run.wav
```

Check it: fail on a silence longer than 3 seconds, on repeated audio, or on a word error rate above 0.2:

```bash
python3 ops/audio-loopback/loopback.py check artifacts/loopback/run.wav --max-stall 3 --expected expected.txt --max-wer 0.2
```

`check` prints a JSON report and ends with `"verdict": "PASS"` or `"FAIL"` and the reasons; it exits 1 on FAIL.

## The tool's commands

| Command | What it does |
| --- | --- |
| `loopback devices [--json]` | Lists devices with UID, input and output channels, and the default input and output. |
| `loopback route --to <device> -- <command…>` | Makes `<device>` the default output, runs the command, then puts the previous default back. |
| `loopback restore` | Puts back a default output that a killed `route` left behind. |
| `loopback record --device <device> --seconds <s> --out <file.wav>` | Records that device's input to a 16 kHz mono 16-bit wav. |
| `loopback play --device <device> <file>` | Plays a file to one device without changing the default. |
| `loopback transcribe <file.wav> [--locale en-US]` | On-device transcript as JSON, with word timings. |

A device can be named by UID, by exact name, or by the start of its name (`BlackHole`).

## Safety

- **The default output always comes back.** `route` writes the previous device to `~/SpokenMarginsOps/audio-loopback/previous-default-output.txt` before switching, and restores it when the command ends, fails, or gets Ctrl-C, TERM, HUP, QUIT or ALRM. Only `kill -9` or a power cut can skip that, and then the next `route`, or `loopback restore`, puts the saved device back first.
- **Inputs are never changed.** `record` points only its own audio engine at BlackHole; the Mac's default input (the owner's microphone) stays as it is. The system alert sound device is never touched.
- **When BlackHole is already the default output, don't route.** Use `capture --no-route`; there's nothing to switch.
- **Prefer no switching at all.** When the source can play to BlackHole itself (`loopback play --device`, `say -a "BlackHole 2ch"`, or a Simulator set to BlackHole in its menu), use `capture --no-route`.

### Routing only the Simulator

Simulator has its own output choice: **I/O → Audio Output** in the Simulator app's menu bar. Its default, "System Default", follows the Mac's default output, which is what `route` switches. Picking BlackHole 2ch there sends only the Simulator's sound to BlackHole and leaves the Mac alone. That menu item has no command-line or `simctl` equivalent we could find; `defaults read com.apple.iphonesimulator` only keeps a list of recently used devices. Scripting the menu would need Accessibility access for the script, so the lane uses `route` for now, which is safe because it always restores.

## Permissions

macOS asks the first time, and it asks on behalf of the **app that started the command**, not this tool:

1. **Microphone**, for `record`, because BlackHole counts as an input device. Without it, macOS hands the recorder digital silence instead of an error. `check` warns when a recording is digital silence.
2. **Speech Recognition**, for `transcribe`. Recognition stays on the Mac (`requiresOnDeviceRecognition`); nothing is sent to Apple.

Terminal can ask for both; allow them once and they stick (System Settings → Privacy & Security → Microphone, and → Speech Recognition). Claude Code can't: on 2026-10-16 macOS stopped `transcribe` run from a Claude Code session ("attempted to access privacy-sensitive data without a usage description", exit 134), because the Claude Code process carries no Speech Recognition usage text. So an agent can record and run `check`, but transcription runs from Terminal or from a lane job whose parent app has been allowed. `check --expected` reports "could not check the words" in that case and fails, rather than passing a check it didn't run. The levels, stalls and repeats need no permission beyond Microphone.

A headless CI runner has no one to click those prompts. On a GitHub-hosted macOS runner, the Microphone permission must be granted ahead of time (see below), and transcription may not be available; the analysis (levels, stalls, repeats) still runs without it.

## Installing BlackHole

### On the Mac

Download BlackHole 2ch from <https://existential.audio/blackhole/> or with Homebrew:

```bash
brew install --cask blackhole-2ch
```

The installer asks for the Mac password. Then check it appears:

```bash
ops/audio-loopback/.build/loopback devices
```

If BlackHole is listed but playing to it hangs (on 2026-10-16, right after installing, even `say -a "BlackHole 2ch" test` hung while the built-in speakers worked), restart the audio server. It asks for the Mac password and comes back in a second:

```bash
sudo killall coreaudiod
```

### On a GitHub-hosted macOS runner

The runner user has password-less sudo, so the cask installs without a prompt. A workflow step (another thread owns `.github/`, so this is not wired in yet):

```yaml
- name: Install BlackHole 2ch
  run: |
    brew install --cask blackhole-2ch
    if ! system_profiler SPAudioDataType | grep -q "BlackHole 2ch"; then
      sudo killall coreaudiod
      sleep 3
    fi
    system_profiler SPAudioDataType | grep "BlackHole 2ch"
```

GitHub-hosted macOS runners have no audio hardware, so BlackHole is also what gives the Simulator an output at all there. Granting the runner Microphone access needs a write to the TCC database, which the hosted images allow for the runner's own processes; that step is still to be proven on a hosted run.

## Using it from a test

The window is: start recording, do the thing, stop. For the Simulator through the lane (a T4 request to the Test Desk; never boot a simulator from a thread):

1. Start `loopback.py capture --seconds <window> --out artifacts/loopback/<name>.wav` in the background.
2. Drive the journey (play an item, lock the Simulator, wait).
3. Run `loopback.py check` on the wav with the expectations for that journey. For #1763: `--max-stall 3` over a 60-second window after locking, without `--allow-trailing`, because audio that stops early *is* trailing silence. For #1762: the default repeat check, and `--expected` with the passage text.

`--allow-trailing` is for windows that are longer than the audio on purpose, like the host proof, where `say` takes a few seconds to start.

## Live proof, 2026-10-16

Through BlackHole 2ch on the owner's Mac, recorded with `record` while `play` or `say` sent audio to BlackHole:

| Input | Sound recorded | Result |
| --- | --- | --- |
| `prove-host.sh --no-words` (a 5.2 s `say` phrase) | 5.16 s; peak −1.9 dBFS and RMS −18.2 dBFS, the same as the source file | PASS |
| Two `say` phrases, back to back | 9.38 s | PASS, no repeats, no stalls |
| The second phrase restarting after 1.3 s (the #1762 shape) | 10.34 s | FAIL: "audio at 8.0 s replays 6.7 s for 1.21 s", correlation 1.0 |
| One phrase, then nothing (the #1763 shape) | 5.17 s | FAIL with `--max-stall 3`: 11.05 s of trailing silence |

Transcription wasn't part of it: it ran from a Claude Code session, which macOS doesn't allow (see Permissions).

## How the analysis works

- The recording is mixed to mono and averaged down to 16 kHz.
- Loudness is measured every 10 ms over 30 ms. Anything above `--silence-db` (default −45 dBFS) is sound. Pauses under 0.25 s are joined, so ordinary pauses between words don't count as gaps.
- **Repeats:** the loudest moment of each syllable is a landmark. Every pair of landmarks up to 30 s apart votes for the delay between them. A delay that four or more nearby landmarks agree on is a candidate. It counts only if the loudness of the two stretches tracks within 4 dB, frame by frame, for at least 0.6 s, with a correlation of 0.9 or more. A replay of the same rendered speech matches to within a fraction of a dB. Different words, or the same word in a new sentence, don't hold that match for 0.6 s; the tests check ten pairs of different synthetic speech for false repeats.
- Music, or anything with a steady beat, will look like repeats. Pass `--allow-repeats` for those.
