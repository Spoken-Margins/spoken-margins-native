# Phone benchmark (Mac build, owner run)

M2's last open item is render speed on the owner's iPhone 17 Pro, measured in Low Power Mode while the phone is warm. The main question is whether **KittenTTS nano**, the chosen fallback, holds **4× real time or better** under those conditions.

## Owner decisions (2026-09-28, relayed by the Mac triage session)

- **A separate throwaway app**, bundle ID `com.spokenmargins.voicebench`. It is never a screen in Spoken Margins, so it can't replace the owner's app or touch their Library.
- **Engines:**
  - KittenTTS nano 0.8 fp32 and int8.
  - Supertonic 3 at 8 steps (today's voice).
  - Samantha (today's fallback).
  - No Kokoro and no Pocket TTS (Pocket is #212).
- **Models are bundled in the app.** The owner runs it from Xcode.
- A dedicated Mac session builds it, pushes to `ws/c2-voice`, and posts the numbers on #192.

## The app

`VoiceBench.xcodeproj` is generated from [`project.yml`](project.yml) (`xcodegen generate` in this folder). It is its own project, and the shipping app's `project.yml` doesn't mention it.

- **Build it:** run `./fetch_models.sh` once. It downloads the two Kitten files into `VoiceBench/Models/` (git-ignored) at pinned Hugging Face revisions and checks their sha256. The build copies them, and `App/SpokenMarginsApp/Resources/Supertonic`, into the app. The phone downloads nothing. Since #1820 that folder holds only Supertonic's licences: run `scripts/voice-catalog fetch supertonic-3-int8` and point `project.yml` at `artifacts/voice-catalog/files/supertonic-3-int8` (as a folder named `Supertonic`) before measuring Supertonic.
- **Scheme:** Run uses the Release configuration, so Supertonic's Swift code is optimized as it is in the shipping app.
- **`VoiceBench/VoiceBenchRunner.swift`: the runners.**
  - Kitten runs on onnxruntime 1.24.2 from pre-tokenized ids and style rows, with no phonemizer on the device. It runs fp32 and int8, each on 1 and 2 threads.
  - Supertonic runs through `SessionKitSupertonic`'s `SupertonicNarrationRenderer` (voice M2, 8 steps).
  - Samantha renders offline through `AVSpeechSynthesizer.write`.
  - Every run measures time to first audio, speed and peak `phys_footprint`, and records Low Power Mode and thermal state at the start and end. The report is saved as JSON in Documents.
  - Time to first audio is the time to render a passage's whole first chunk, which holds 7–20 s of audio. It is an upper bound on what the app would see with a short first chunk.
- **`VoiceBench/VoiceBenchView.swift`: the one screen.** Run all, the Kitten fp32 verdict, per-engine results, and a Share button for the JSON.
- **`VoiceBench/VoiceBenchInputs.swift`:** generated from [`inputs.json`](inputs.json) by `make_inputs_swift.py`. Rendering from these inputs matches the Python engine to within 9e-6.
- **Host check:** the same runner files, compiled into a macOS command-line tool on the Mac (M-series, 2026-09-28), gave Kitten fp32 6.2× on 1 thread and 11.9× on 2, int8 4.9× and 6.1×, Supertonic 4.3× and Samantha 6.7×. Those are Mac numbers, not the phone's.

## How the owner runs it

1. Run VoiceBench from Xcode once so it installs, then press Stop and unplug the phone.
2. Warm the phone: about 10 minutes of narration playback, unplugged.
3. Turn on **Low Power Mode**.
4. Open VoiceBench from the Home Screen and tap **Run all** (about 5 minutes).
5. Tap **Share results JSON** and AirDrop it to the Mac. It lands in Downloads.
6. Optional: run it again with Low Power Mode off, so the Low Power Mode penalty is known.

## Pass mark (derived A13 budget)

- The brief asks for **2× real time on an A13 under stress**.
- The single-core CPU ratio from an A19 Pro to an A13 is about **1.8**. The Geekbench 6 figures behind it are about 3,500–3,800 for the A19 Pro and about 2,000–2,100 for the A13, and the A13 figure is unconfirmed; the Mac session should check both at browser.geekbench.com.
- So **Kitten fp32 on the owner's phone, in Low Power Mode and warm, must reach 4× real time or more**, with first audio under 1.5 s.
- If int8 is as fast, it's the one bundled (about 27 MB instead of about 60 MB).
