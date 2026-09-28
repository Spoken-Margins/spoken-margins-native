# C2 M2: picking a fallback voice (research)

Stream C2 `voice`, milestone M2. Tracking issue #192. Brief: [docs/workstreams/streams/C2-voice.md](../../docs/workstreams/streams/C2-voice.md).

This folder compares candidate bundled voices for the fallback: what they cost in app size, whether their licenses fit the App Store, how fast they render, and how they sound. The cloud part (Linux numbers, licenses, audio samples, the blind listening page) is done. The Mac benchmark, the Samantha sample, the phone benchmark and the blind listen are prepared and waiting; see [What's waiting](#whats-waiting).

**Listening page:** https://claude.ai/artifact/2tihSftwJBfSpT4qX34f9y (private to the owner). The source is [listening/index.html](listening/index.html). The answer key is in [listening/answer-key.md](listening/answer-key.md); don't open it before rating.

## Candidates

| Letter on the page | Candidate | Why it's here |
| --- | --- | --- |
| E | **Supertonic 3 INT8, 8 steps**: what the app renders today (voice M2) | Baseline |
| C | **Supertonic 3 INT8, 4 steps**: the same model doing half the denoising work | A fallback that costs no app size and keeps the listener's voice |
| G | **Kokoro-82M v1.0** fp32, voice af_heart | The best-known small open voice |
| D | **KittenTTS nano 0.8** fp32, voice Jasper | The smallest and fastest neural candidate |
| A | **Piper** ljspeech high | The lightweight engine the app already half-supports |
| B | **Kyutai Pocket TTS**, voice alba | Streams audio; no phonemizer at all |
| F | **Samantha** (Mac) | The system voice the app falls back to today. It can only be rendered with `say` on a Mac. |

Also measured but left off the listening page: Kokoro int8, Kitten nano int8, and Piper lessac medium. Lessac is Piper's most popular voice, but its license rules it out.

## Results on this Linux CPU

Intel Xeon @ 2.8 GHz, 4 vCPU, onnxruntime 1.30 (PyTorch 2.14 for Pocket). Every engine gets the same chunks: the first sentence alone, then chunks of up to 240 characters, the app's Supertonic chunk size, joined with a 0.25 s gap. Speed is the best of 2 runs (4 threads) or a single run (1 thread). "First audio" is the median over the three passages of the time to render chunk 1 with the model loaded. Word errors come from Whisper small.en transcribing each clip: a check that the words come out right, not a naturalness score. Raw numbers: [results/linux/](results/linux/).

| Candidate | Speed ×RT, 4 threads | Speed ×RT, 1 thread | First audio, s (4 thr) | Natural pace, wpm | Word errors: everyday / scientific | Added app size | License verdict |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Supertonic 3 INT8, 8 steps (today) | 3.6 | 2.2 | 2.29 | 139 | 1% / 17% | 0 (bundled, 148 MB) | OK (MIT code, OpenRAIL-M model, no phonemizer). Already shipping behind the Terms gate. |
| Supertonic 3 INT8, 4 steps | 6.2 | 3.9 | 1.33 | 139 | 2% / 29% | 0 | OK, same model. |
| Kokoro-82M fp32 | 2.8 | 1.1 | 2.43 | 152 | 2% / 5% | 326 MB + 6 MB lexicon | OK *if* espeak-ng fallback is replaced (Apache weights, Apache misaki lexicon; espeak fallback GPL). |
| Kokoro-82M int8 | 0.6 | 0.4 | 11.30 | 152 | 2% / 4% | 92 MB + 6 MB lexicon | Same as Kokoro fp32. |
| KittenTTS nano 0.8 fp32 | 10.1 | 4.6 | 0.74 | 136 | 3% / 27% | 57 MB + 3 MB voices | Weights OK (Apache). Front end is espeak-ng (GPL); needs a non-GPL G2P that mimics espeak IPA. |
| KittenTTS nano 0.8 int8 | 2.2 | 1.7 | 3.26 | 136 | 4% / 24% | 24 MB + 3 MB voices | Same as Kitten fp32. |
| Piper ljspeech high | 3.8 | 1.3 | 1.84 | 140 | 2% / 19% | 114 MB + espeak data | Blocked as-is: piper1 engine is GPL-3 and phonemizes with espeak-ng (GPL). Voice data public domain. |
| Piper lessac medium | 18.2 | 8.0 | 0.31 | 163 | 2% / 15% | 63 MB + espeak data | Blocked: GPL front end, and the lessac voice is research-only (Blizzard 2013 licence). |
| Kyutai Pocket TTS (alba) | 1.7 | 1.3 | 3.59 (stream 0.20) | 168 | 2% / 24% | 219 MB fp32 + 6 MB voice | OK (MIT code, CC-BY-4.0 weights, alba voice CC-BY-4.0, no phonemizer). Needs attribution. Avoid built-in voices from Expresso/EARS (non-commercial). Needs a non-PyTorch runtime on iOS. |

How to read these numbers:

- **They rank candidates; they don't predict the phone.** Apple silicon is much faster per core than this cloud Xeon. Kyutai reports about 6× real time for Pocket TTS on a MacBook Air M4, against 1.3–1.7× here. The pass/fail test is the phone benchmark ([phone-bench/](phone-bench/)).
- **int8 is slow on this x86 CPU** for Kokoro and Kitten (dynamic-quantized convolutions). ARM kernels differ, so the Mac run re-measures int8 before it's written off. If int8 is fast on Apple silicon, Kokoro drops to 92 MB and Kitten to 24 MB.
- **App size** is the uncompressed on-disk size. onnxruntime is already in the app for Supertonic, so the ONNX candidates add only their model files. Pocket TTS would also need an iOS runtime (a community ONNX export or MLX), which isn't included in its number.
- **Scientific word errors are mostly text normalization**, not the voice. Supertonic, the app's own voice today, reads "hazard ratio, 0.88; 95% CI, 0.75 to 1.04; p = 0.12" as "hazard ratio, EO, EU.85% CI and 0.175 to 1.14". Kokoro gets it right because its front end (misaki) expands numbers. Normalizing numbers, units and statistics before any engine sees the text fixes this for every voice, including the fallback. That's in the I14 draft (§5).

## Licenses: what blocks what

- **espeak-ng is GPL-3.0.** The App Store's terms are widely treated as incompatible with GPL, so nothing that links espeak-ng or its data can ship. That rules out Piper as packaged (the `piper1` engine is itself GPL-3, and the older MIT `piper` still calls `piper-phonemize` → espeak-ng). It also rules out KittenTTS's reference front end, `phonemizer` (GPL-3) plus espeak-ng, and Kokoro's out-of-lexicon fallback. sherpa-onnx is Apache-2.0 but bundles espeak-ng for these models, so it doesn't escape the problem.
- **Kokoro can avoid it.** Its English front end, misaki, is Apache-2.0 and lexicon-first (about 6 MB of US gold and silver dictionaries). Only unknown words go to espeak. A shipping build needs a non-GPL fallback for unknown words. On the three passages the only unknown words were `Anacortes`, `=`, `25-hydroxyvitamin`, `ng/mL`, `[12` and `et`, and the I14 normalizer removes most of those.
- **KittenTTS is harder.** It was trained on espeak's exact IPA output, so a replacement front end has to imitate espeak (for example CMUdict mapped to espeak-style IPA). That's real work and a quality risk.
- **Voice data:** Piper lessac is research-only (Blizzard 2013). Piper hfc_female is CC BY-NC-SA. Two of Pocket TTS's built-in voices (cosette from Expresso, jean from EARS) are CC BY-NC. alba (CC BY 4.0) and marius or javert (CC0) are fine. Kokoro and Kitten voices ship under the model's Apache-2.0 license.
- **Supertonic 3:** MIT code, OpenRAIL-M model (use-based restrictions), already handled by the app's Supertonic Terms gate.
- **Pocket TTS:** MIT code and CC BY 4.0 weights, so the app needs an attribution line. The voice-cloning weights are gated with a prohibited-use list; the ungated no-cloning weights are enough.

## Recommendation (provisional until the Mac, phone and listening results are in)

**Make the fallback Supertonic 3 at 4 steps, and keep the system voice only as the last resort.**

- **It meets the bars as far as the cloud can tell.** It renders 1.8× faster than today's 8 steps (3.9× real time on one Xeon thread, where 8 steps manages 2.2×). It adds 0 MB. There's no license work: it's the same files, already behind the Terms gate. One code change is needed: `SupertonicNarrationRenderer.render` accepts only 5–12 steps (`SupertonicNarrationRenderer.swift:172`), so the guard has to allow 4. It keeps the listener's chosen voice (M2 stays M2), which is what the brief's outcome is really about. The first audio arrives in about 1.3 s instead of 2.3 s.
- **What would change it:**
  - **If the blind listen rates C clearly below E**, or the phone benchmark puts 4 steps under **4× real time in Low Power Mode while warm**, the runner-up is **KittenTTS nano fp32**. It's the fastest neural voice here (4.6× on one thread, about 60 MB), but it needs a non-GPL front end built first (about a week of work, with a quality risk).
  - **Kokoro** has the best words-right score and is the likely listening favourite, but at 326 MB fp32 and 1.1× on one thread it doesn't fit a fallback budget unless int8 turns out fast on Apple silicon (the Mac run checks this).
  - **Pocket TTS** is license-clean and streams from 0.2 s, but it needs an iOS runtime port and was the slowest here. Watch it; don't pick it now.
  - **Piper** is out on licensing.
- **Two cases it doesn't cover.** It's the same 148 MB model on the same CPU, only doing about half the work:
  - After a **memory warning**, 4 steps uses the same memory as 8 steps.
  - At thermal **`.critical`**, any neural rendering adds heat.
  - For those two conditions the system voice stays the fallback, visibly labelled, per the I14 draft. At thermal **`.serious`**, 4 steps is the fallback, provided the phone benchmark shows it holding 4× real time when warm. If it doesn't, `.serious` goes to the system voice as well.
- **App-size cost to accept:** 0 MB for the recommendation. If the runner-up is needed instead: about 60 MB for Kitten nano fp32 (about 27 MB if int8 is fast on the phone).

## What's waiting

**(Mac)** One command on the Mac, about 20 minutes, from this folder on branch `ws/c2-voice`:

```sh
./mac/run-mac.sh
```

It installs the harness, fetches the models, runs every benchmark (`results/darwin/`), renders **Samantha** with `say` (`mac/samantha.sh`), and rebuilds the listening page with the Samantha clip under letter F. Then commit `results/darwin/` and `listening/`, and republish `listening/index.html` to the same artifact URL (pass it as `url`), with the audio files. Also build the phone benchmark from [phone-bench/README.md](phone-bench/README.md).

**(owner)** In this order:

1. **Blind listen** (about 15 minutes, headphones): open the listening page on the phone, rate every clip 1–5, answer "Acceptable as the fallback?" per letter, and tap **Save ratings**. You can do this now; the Samantha clip (F) is added after the Mac run, and you can rate it then.
2. **Phone benchmark:** once the Mac session has built it, run it warm, in Low Power Mode, as described in [phone-bench/README.md](phone-bench/README.md), and share the JSON on #192.
3. **Accept the app-size cost:** 0 MB for the recommendation, or about 60 MB if the listen or the phone sends it to Kitten.

## Files

- `passages.json`: the three test passages (narrative, scientific, essay with dialogue).
- `harness.py`, `bench.py`, `run_all.sh`: the benchmark. `engines/*.py` has one wrapper per engine. `engines/supertonic.py` is a Python port of the app's `SupertonicRuntime.swift`, using the same INT8 files, sha256-matched to `asset-manifest.json`.
- `intelligibility.py`: the Whisper word-error check.
- `build_page.py`, `listening_template.html`: build the blind page (seeded letters, loudness-matched 96 kbps MP3).
- `summarize.py`, `candidates.json`: the table above.
- `fetch_models.sh`, `requirements.txt`: reproduce. Models, WAVs and the virtual environment are git-ignored.
- `I14-draft.md`: **draft** rules for seam I14 (engine selection, one rate, I13 roles, text normalization). C2 M1 publishes the real one.
- `phone-bench/`: spec and pre-tokenized inputs for the phone benchmark build.
- `mac/`: the Mac scripts.
