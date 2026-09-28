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

## Starting point from the cloud session

[`VoiceBench/`](VoiceBench/) holds the app's code, written without a compiler. The Mac session builds it and fixes anything that doesn't compile. It's a starting point, not a constraint: replace any part of it.

- **`VoiceBenchRunner.swift`: the runners.**
  - Kitten runs on the onnxruntime Swift package from pre-tokenized ids and style rows, with no phonemizer on the device. It runs three times: fp32 on 1 thread, fp32 on 2 threads, and int8 on 1 thread.
  - Supertonic runs through `SessionKitSupertonic`'s public `SupertonicNarrationRenderer` (voice M2, 8 steps).
  - Samantha renders offline through `AVSpeechSynthesizer.write`.
  - Every run measures time to first audio, speed and peak `phys_footprint`, and records Low Power Mode and thermal state at the start and end. The report is saved as JSON in Documents.
- **`VoiceBenchView.swift`: the one screen.** Run all, per-engine results, and a share button for the JSON.
- **`VoiceBenchInputs.swift`:** generated from [`inputs.json`](inputs.json) by `make_inputs_swift.py`. The inputs were checked against the Python engine: rendering from them matches it to within 9e-6.
- **What the app needs:**
  - Dependencies: SessionKit (for `SessionKitSupertonic`) and onnxruntime 1.24.2, as in `Packages/SessionKit/Package.swift`.
  - Bundled resources: `App/SpokenMarginsApp/Resources/Supertonic` as a folder named `Supertonic`, plus `kitten-nano-0.8-fp32.onnx` and `kitten-nano-0.8-int8.onnx` (from `../fetch_models.sh`; the Hugging Face revisions and sha256 are in `VoiceBenchModel`).
  - Supertonic keeps its Terms: the owner has accepted them in the app, and this app is only for the owner's own device.

## How the owner runs it

1. Warm the phone first: about 10 minutes of narration playback, unplugged.
2. Turn on **Low Power Mode**.
3. Run VoiceBench from Xcode and tap **Run all** (about 3 minutes; keep the screen on).
4. Share the JSON to #192.
5. Run it once more with Low Power Mode off, so the Low Power Mode penalty is known.

## Pass mark (derived A13 budget)

- The brief asks for **2× real time on an A13 under stress**.
- The single-core CPU ratio from an A19 Pro to an A13 is about **1.8**. The Geekbench 6 figures behind it are about 3,500–3,800 for the A19 Pro and about 2,000–2,100 for the A13, and the A13 figure is unconfirmed; the Mac session should check both at browser.geekbench.com.
- So **Kitten fp32 on the owner's phone, in Low Power Mode and warm, must reach 4× real time or more**, with first audio under 1.5 s.
- If int8 is as fast, it's the one bundled (about 27 MB instead of about 60 MB).
