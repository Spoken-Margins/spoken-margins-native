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
- `window.py`: the window server for unattended lane tests (below, "In a lane T3"). `test_window.py` tests it on the host.
- `build-app.sh`, `recorder-app/`: build the same `loopback.swift` as `SpokenMarginsLaneRecorder.app`, the recorder the lane uses (below, "The recorder app"). `setup-recorder-app.sh` is the owner's one-time setup. `test_recorder_app.py` tests the app's build and its launch on the host, without asking for any permission.
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
| `loopback transcribe <file.wav> [--locale en-US]` | On-device transcript of one file as it is, as JSON, with word timings. For recordings use `loopback.py transcribe` (below), which splits at pauses. |
| `python3 loopback.py transcribe <file.wav>` | On-device transcript of a recording, cut at pauses longer than 0.8 s and transcribed one stretch of speech at a time; word starts are in the recording's time. Exits 1 with `empty_reason` when no words came back. |

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

Terminal can ask for both; allow them once and they stick (System Settings → Privacy & Security → Microphone, and → Speech Recognition). Claude Code can't: on 2026-10-16 macOS stopped `transcribe` run from a Claude Code session ("attempted to access privacy-sensitive data without a usage description", exit 134), because the Claude Code process carries no Speech Recognition usage text. So an agent can record and run `check`, but transcription runs from Terminal, from the Claude desktop app's terminal pane (allowed on 2026-10-17), or from a lane job whose parent app has been allowed. `check --expected` reports "could not check the words" in that case and fails, rather than passing a check it didn't run. The levels, stalls and repeats need no permission beyond Microphone.

The lane can't use any of those: macOS charges both permissions to the GitHub runner's `node`, which refuses them without asking. The lane uses the recorder app instead (next section).

A headless CI runner has no one to click those prompts. On a GitHub-hosted macOS runner, the Microphone permission must be granted ahead of time (see below), and transcription may not be available; the analysis (levels, stalls, repeats) still runs without it.

## The recorder app

**Why it exists.** macOS gives Microphone and Speech Recognition to the "responsible" app: the one that started the command. On the lane that's the GitHub runner's bundled `node` (`actions-runner-spoken-margins/externals/node20/bin/node`). It has the hardened runtime and no audio-input entitlement, so macOS refuses it without a prompt and the recorder hears digital silence (tccd log, 2026-10-18 15:01:57, #1790). No lane setting fixes that.

**What it is.** `SpokenMarginsLaneRecorder.app` is `loopback.swift` built as a small Mac app: its own bundle identifier (`com.spokenmargins.ops.lane-recorder`), plain-words Microphone and Speech Recognition usage text, and the `com.apple.security.device.audio-input` entitlement. It has no window and no Dock icon. It's ad-hoc signed (`codesign -s -`), so macOS treats every rebuild as a new app and asks again. Rerun the setup after `loopback.swift` changes; until then a window that can't listen says the installed app is older than the source.

**How the lane uses it.** `window.py` runs `loopback route -- loopback.py app-run -- record …`. `app-run` starts the app through LaunchServices (`open -n -g -a ~/Applications/SpokenMarginsLaneRecorder.app --args --job <folder> record …`), so the app is its own responsible process. Transcription goes the same way, one `transcribe` job per stretch of speech.

- **Results come back through files.** An app that `open` starts has no stdout or exit status its caller can read. With `--job <folder>` the app writes `stdout`, `stderr` and, last, `status` there. `app-run` waits for `status`, passes `stderr` through as it grows, and copies the recording and the app's log into the run's evidence folder (`<id>.wav`, `<id>.recorder.log`).
- **The job folder is under `~/Library/Caches/SpokenMarginsLane/recorder-jobs/`.** The repo lives under `~/Documents`, which macOS guards with a third permission, so the app never reads or writes there.
- **Stopping.** `open` can't pass a signal on, so the caller asks the app to stop by creating `stop` in the job folder. TERM to `route` reaches `app-run`, which does that and waits for the app before route puts the default output back.
- **It never asks on its own.** In a job, `record` and `transcribe` don't ask for a permission they lack, because nobody is there to click. They fail with what's missing ("Microphone access for this app is not asked yet"), and the window reports UNAVAILABLE: the T3 is INCONCLUSIVE, never PASS or FAIL. Only `permissions`, which the setup runs, asks.
- **Not proven on the lane yet.** The runner's LaunchAgent sets `SessionCreate`. If that stops `open` from starting apps, the window reports `could not start …` with `open`'s own error.

### One-time setup, at the Mac (the owner)

It takes about two minutes. Do it while you're at the Mac, because macOS shows two boxes that need a click.

1. Open the **Terminal** app. (Not a Claude session: Terminal shows the boxes reliably.)
2. Type this, then press Return. It goes to the project folder:

   ```zsh
   cd ~/Documents/GitHub/spoken-margins-native
   ```

3. Type this, then press Return:

   ```zsh
   ops/audio-loopback/setup-recorder-app.sh
   ```

4. It prints "Step 1 of 4: building the recorder app" and works for about a minute.
5. It prints "Step 2 of 4". Then a box appears: "Spoken Margins Lane Recorder" would like to access the microphone. Click **Allow** (some versions say **OK**).
6. A second box appears: "Spoken Margins Lane Recorder" would like to access Speech Recognition. Click **Allow** (or **OK**).
7. It prints "Step 4 of 4: a 10-second test". You won't hear anything; the test voice goes to BlackHole.
8. It ends with "Done. The recorder heard and understood the test sentence." You can close Terminal.

If it ends with "Not done yet", a box was missed or refused. It then prints where to turn the two switches on in System Settings (Privacy & Security, then Microphone, and then Speech Recognition). Turn them on and run step 3 again.

If it ends with "the 10-second test didn't pass", the permissions are set but something else is wrong. Tell Claude; nothing else is needed from you.

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

### In a lane T3 (unattended)

Name an `AudioLoopback` test in a `/lane T3` request (`tests: AudioLoopbackPlaybackTests`); [test-lane.md](../../docs/workstreams/test-lane.md#audio-checks-hearing-what-the-simulator-played-1790) has the request and the report line. The pieces:

- `window.py serve --dir <folder>` is the window server. `scripts/lane_audio_window.py` starts it beside an app test run whose request names an `AudioLoopback` test and passes the folder to the test as `SM_AUDIO_WINDOW`. The Simulator reads and writes that folder on the Mac's disk.
- `AudioLoopbackWindow` (app tests) asks for a window: its length, the expected text, and the limits. It waits until the Mac records, plays, then waits for the verdict. FAIL fails the test; UNAVAILABLE skips it (INCONCLUSIVE on the lane).
- One window at a time, Mac-wide: an flock at `~/Library/Caches/SpokenMarginsLane/audio-window.lock`, beside the simulator slots. A routing `loopback.py capture` takes the same lock, because two routes at once would each save the other's BlackHole as the device to put back.
- **The pilot tone.** Before the test plays, the server plays 0.3 s of 1 kHz straight to BlackHole and cuts it from the recording afterwards. A recording with no pilot means the recorder can't hear: the process running the lane may lack Microphone access. That answers UNAVAILABLE rather than blaming the app for silence. A recording with the pilot and then silence is the app's fault: FAIL.
- **Only the app's sound.** The lock keeps windows apart, not other sound: while BlackHole is the default output, a second simulator job or the Mac's own player lands in the same recording, and a second voice reads as the app's fault. So the server answers UNAVAILABLE when another lane simulator slot is held at the window's start or end, and when the 1 s pre-roll it records before the pilot already has sound in it.
- **Restoring the default output.** The recorder runs inside `loopback route`, which puts the old default output back when the window ends, fails or is stopped. The server stops it with TERM when the test run ends, and a `kill -9` is undone by the next route.

To write another audio test: open a window before playing, `waitUntilRecording()`, play the item, then `require(try await verdict())`. Keep the window longer than the audio and use `allowTrailing`, unless the test is about audio that stops early.

### By hand

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

On 2026-10-17, `prove-host.sh` with words, run from the Claude desktop app's terminal pane: 5.16 s of sound, all 15 words heard, word error rate 0.0, PASS.

## Transcription: why recordings are cut at pauses

macOS's on-device recogniser forgets what it heard when a pause of more than about a second follows it. Its final result keeps only the speech after the last long pause, and is empty when the file ends in silence. Found on 2026-10-17 (#1790), from the terminal pane, with clean `say` speech at 16 kHz:

| File | Final transcript |
| --- | --- |
| The phrase alone, or with 1, 3 or 5 s of silence before it; 16 kHz, 44.1 kHz or `.aiff` | Every word |
| The phrase, then 1 s of silence | Every word |
| The phrase, then 2, 3 or 5 s of silence | Empty, though the partial results just before had every word |
| Two sentences with a 2 s or 5 s pause between them | Only the second sentence |
| 6 s of silence | Error 1110, "No speech detected" |

Every recording ends in silence, because the record window runs past the audio, so the 10-17 `prove-host.sh` runs all came back empty. A recording of an app that stalls (#1763) has long pauses inside it too. So `loopback.py transcribe`, and `check --transcribe` or `--expected`, find the stretches of sound, join those less than 0.8 s apart, pad each with 0.2 s of silence and transcribe them one by one. The on-device speech model was installed throughout; nothing was downloaded.

When no words come back, the transcript says why in `empty_reason`: no sound in the recording, "no speech detected", or the recogniser heard words and then dropped them at a pause. `check --expected` then fails with "could not check the words: …" instead of a word error rate of 1.0.

## How the analysis works

- The recording is mixed to mono and averaged down to 16 kHz.
- Loudness is measured every 10 ms over 30 ms. Anything above `--silence-db` (default −45 dBFS) is sound. Pauses under 0.25 s are joined, so ordinary pauses between words don't count as gaps.
- **Repeats:** the loudest moment of each syllable is a landmark. Every pair of landmarks up to 30 s apart votes for the delay between them. A delay that four or more nearby landmarks agree on is a candidate. It counts only if the loudness of the two stretches tracks within 4 dB, frame by frame, for at least 0.6 s, with a correlation of 0.9 or more. A replay of the same rendered speech matches to within a fraction of a dB. Different words, or the same word in a new sentence, don't hold that match for 0.6 s; the tests check ten pairs of different synthetic speech for false repeats.
- Music, or anything with a steady beat, will look like repeats. Pass `--allow-repeats` for those.
