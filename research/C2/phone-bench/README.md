# Phone benchmark build (Mac), then run by the owner

M2 needs render speed measured on the owner's iPhone 17 Pro in Low Power Mode while warm. A cloud session can't build iOS, so this is the spec for a Mac session to build. Keep it small and throwaway. It belongs on this branch, not in the shipping app.

## What to build

- **Where:** a hidden **Voice benchmark** screen behind the existing diagnostics, in a debug build on `ws/c2-voice`. A separate scheme or a `#if DEBUG` screen is fine. Don't change what the shipping app does.
- **Engines**, all on the onnxruntime the app already links (CPU execution provider; record the thread count used):
  1. Supertonic 3 INT8, voice M2, **8 steps**, through the app's own `SupertonicRuntime`.
  2. The same at **4 steps**. `SupertonicNarrationRenderer.render` rejects fewer than 5 steps (line 172), so call the runtime directly or widen the guard in the debug build.
  3. KittenTTS nano 0.8 **fp32**, from pre-tokenized input ids.
  4. Kokoro-82M v1.0 **fp32**, from pre-tokenized tokens (style row = token count − 1, input wrapped as `[0, *tokens, 0]`, speed 1.0).
  5. **Pocket TTS (alba)**: the lead candidate after the blind listen. Try the community ONNX export (Hugging Face `KevinAHM/pocket-tts-onnx`) on onnxruntime first, then MLX. Check the export's license. Measure time to first streamed audio as well as time to first chunk. If neither runtime works on iOS, say so on #192; that's the finding.
  6. **Samantha** through `AVSpeechSynthesizer.write(_:toBufferCallback:)`, rate `AVSpeechUtteranceDefaultSpeechRate`.
- **Inputs:** [`inputs.json`](inputs.json) has the exact chunks and token ids for all three passages. That's why the phone needs no phonemizer (and no GPL code) for this benchmark. Model files come from `../fetch_models.sh`. Side-load them into the debug build's Documents folder; don't bundle them.
- **What to measure**, per engine and passage, with each engine warmed up on one short sentence first:
  - **Time to first audio:** wall time to render chunk 1.
  - **Speed:** total audio seconds divided by total render seconds.
  - **Peak memory** (`phys_footprint`).
  - The **thermal state** and **Low Power Mode** at start and end.
- **Output:** a results screen, plus a JSON file in Documents that the owner can AirDrop or paste into #192.

## How the owner runs it

1. Warm the phone: 10 minutes of normal narration playback (or any sustained app use) until it's warm to the touch, unplugged.
2. Turn on **Low Power Mode**.
3. Open Diagnostics, then **Voice benchmark**, and tap **Run all**. It takes about 3 minutes. Don't lock the phone.
4. Share the JSON to #192. Also run it once with Low Power Mode off, so the Low Power Mode penalty is known.

## Pass mark: the derived A13 budget

The oldest supported iPhones use the A13, and the owner doesn't have one, so the budget is scaled:

- The brief needs **≥ 2× real time on an A13 under stress**.
- CPU ratio from Geekbench 6 single-core: A19 Pro ≈ 3,500–3,800 (Geekbench Browser, iPhone 17 Pro and Pro Max). A13 ≈ 2,000–2,100 *(unconfirmed: Geekbench Browser returned 403 to this cloud session; the Mac session should confirm both numbers at browser.geekbench.com and record them here)*. That's a ratio of about **1.8**. Single-core is the right basis because a throttled phone renders on one or two cores.
- **Pass on the owner's phone (Low Power Mode, warm): speed ≥ 2 × 1.8 ≈ 3.6× real time. Use 4× for a safety margin.**
- Time to first audio should be under 1.5 s at the same conditions, so that pressing play doesn't feel broken.
