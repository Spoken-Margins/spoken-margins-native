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

## Blind listen (owner, 2026-09-28)

Ratings are 1–5 per passage (narrative / scientific / dialogue). Letters were revealed after the ratings were saved. Raw data: [results/blind-listen-2026-09-28.json](results/blind-listen-2026-09-28.json).

| Letter | Candidate | Ratings | Average | Acceptable as the fallback? |
| --- | --- | --- | ---: | --- |
| G | Kokoro-82M fp32 | 5 / 5 / 5 | 5.0 | yes |
| B | Pocket TTS (alba) | 5 / 5 / 5 | 5.0 | yes |
| E | Supertonic 3, 8 steps (today) | 4 / 4 / 4 | 4.0 | yes |
| A | Piper ljspeech high | 4 / 3 / 3 | 3.3 | yes (blocked on license anyway) |
| D | KittenTTS nano fp32 | 3 / 3 / 3 | 3.0 | yes |
| C | Supertonic 3, 4 steps | 2 / 3 / 2 | 2.3 | **no** |
| F | Samantha (the system voice today) | 2 / 2 / 2 | 2.0 | no |

## Mac results (partial, 2026-09-28)

From the Mac session's commit 819b006 ([results/darwin/](results/darwin/)):

| Candidate | Speed ×RT, 4 thr / 1 thr | First audio |
| --- | ---: | ---: |
| Supertonic 3, 8 steps | 5.1 / 2.5 | 1.7 s |
| Supertonic 3, 4 steps | 9.6 / 4.5 | 0.9 s |
| Pocket TTS (alba) | 4.2 / 3.5 | 1.5 s (first streamed audio 0.07 s) |
| Samantha | 15.3 | — |

Kokoro, Kitten and Piper produced no Mac numbers, because espeak-ng couldn't find its data on macOS. `engines/kitten.py` now passes the data path explicitly; this is untested on a Mac. misaki already does this for Kokoro and still failed there, so the Mac session needs to look at Kokoro directly.

## Recommendation (owner direction, 2026-09-28)

The owner loved Pocket TTS, but worried it's too heavy for older iPhones. They found Kokoro too heavy even on their iPhone 17 Pro, and judged KittenTTS "not very pleasant, but not bad".

**Decision: bundle KittenTTS nano 0.8 as the fallback voice. Keep Pocket TTS as a candidate for a later, optional voice, not the bundled fallback.**

- **The worry about Pocket is borne out by the numbers.**
  - Pocket manages 3.5× real time on one Mac core.
  - Scaled to an A13 by single-core speed, and then cut for Low Power Mode and heat, that lands around 1.5–2.5×, at or below the brief's 2× floor. And that's before any iOS runtime overhead.
  - Kitten does 4.6× on one core of the slow cloud Xeon, so it clears the A13 floor with room to spare.
- **Kitten meets the brief's three bars:**
  - **Speed:** on track for ≥2× on the derived A13 budget. The phone benchmark confirms it.
  - **License:** Apache-2.0 weights, once its espeak-ng front end is replaced.
  - **App size:** about 60 MB (about 27 MB if int8 is fast on Apple silicon).
- **What it costs in M3:** a non-GPL front end that turns text into the phonemes Kitten was trained on (espeak-style IPA), for example CMUdict plus rules for unknown words, together with the I14 text normalizer. That's the main work and the main quality risk. The phone benchmark sidesteps it by using pre-tokenized input.
- **It beats what listeners get today:** Kitten scored 3.0 and acceptable; Samantha scored 2.0 and not acceptable.
- **Pocket TTS, later:** worth a separate issue as an optional voice the listener chooses on phones that pass its benchmark. It would be downloaded rather than bundled, so it adds no app size. It's out of M2 scope.
- **Unchanged:** Supertonic 8 steps stays the preferred voice whenever policy allows it. After a memory warning, the system voice stays the labelled last resort.

## What's waiting

**(Mac)** One command on the Mac, about 20 minutes, from this folder on branch `ws/c2-voice`:

```sh
./mac/run-mac.sh
```

It installs the harness, fetches the models, runs every benchmark (`results/darwin/`), renders **Samantha** with `say` (`mac/samantha.sh`), and rebuilds the listening page with the Samantha clip under letter F. Then commit `results/darwin/` and `listening/` (the audio stays local; it's git-ignored), and republish `listening/index.html` to the same artifact URL (pass it as `url`), with the audio files. Also build the phone benchmark from [phone-bench/README.md](phone-bench/README.md).

**(owner)** In this order:

1. **Blind listen:** done 2026-09-28.
2. **Phone benchmark:** once the Mac session has built it, run it warm, in Low Power Mode, as described in [phone-bench/README.md](phone-bench/README.md), and share the JSON on #192.
3. **App-size cost:** accepted by the owner on 2026-09-28 (about 60 MB for KittenTTS nano fp32; int8 at about 27 MB only if it is as fast on the phone).

## Files

- `passages.json`: the three test passages (narrative, scientific, essay with dialogue).
- `harness.py`, `bench.py`, `run_all.sh`: the benchmark. `engines/*.py` has one wrapper per engine. `engines/supertonic.py` is a Python port of the app's `SupertonicRuntime.swift`, using the same INT8 files, sha256-matched to `asset-manifest.json`.
- `intelligibility.py`: the Whisper word-error check.
- `build_page.py`, `listening_template.html`: build the blind page (seeded letters, loudness-matched 96 kbps MP3).
  - The clips aren't in git (`listening/audio/` is ignored), so no audio enters `next`'s history. They're still served by the published page.
  - To rebuild them: `./fetch_models.sh`, `./run_all.sh`, `mac/samantha.sh` (on a Mac, for F), then `.venv/bin/python build_page.py`. Fresh renders differ slightly from what the owner rated, because Pocket TTS and Kitten sample randomly.
- `summarize.py`, `candidates.json`: the table above.
- `fetch_models.sh`, `requirements.txt`: reproduce. Models, WAVs and the virtual environment are git-ignored.
- `I14-draft.md`: **draft** rules for seam I14 (engine selection, one rate, I13 roles, text normalization). C2 M1 publishes the real one.
- `phone-bench/`: spec and pre-tokenized inputs for the phone benchmark build.
- `mac/`: the Mac scripts.
