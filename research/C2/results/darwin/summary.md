| Candidate | Speed ×RT, 4 threads | Speed ×RT, 1 thread | First audio, s (4 thr) | Natural pace, wpm | Word errors: everyday / scientific | Added app size | License verdict |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Supertonic 3 INT8, 8 steps (today) | 5.1 | 2.5 | 1.68 | 139 | 1% / 16% | 0 (bundled, 148 MB) | OK (MIT code, OpenRAIL-M model, no phonemizer). Already shipping behind the Terms gate. |
| Supertonic 3 INT8, 4 steps | 9.6 | 4.5 | 0.90 | 139 | 1% / 27% | 0 | OK, same model. |
| Kokoro-82M fp32 | — | — | — | — | — | 326 MB + 6 MB lexicon | OK *if* espeak-ng fallback is replaced (Apache weights, Apache misaki lexicon; espeak fallback GPL). |
| Kokoro-82M int8 | — | — | — | — | — | 92 MB + 6 MB lexicon | Same as Kokoro fp32. |
| KittenTTS nano 0.8 fp32 | — | — | — | — | — | 57 MB + 3 MB voices | Weights OK (Apache). Front end is espeak-ng (GPL); needs a non-GPL G2P that mimics espeak IPA. |
| KittenTTS nano 0.8 int8 | — | — | — | — | — | 24 MB + 3 MB voices | Same as Kitten fp32. |
| Piper ljspeech high | — | — | — | — | — | 114 MB + espeak data | Blocked as-is: piper1 engine is GPL-3 and phonemizes with espeak-ng (GPL). Voice data public domain. |
| Piper lessac medium | — | — | — | — | — | 63 MB + espeak data | Blocked: GPL front end, and the lessac voice is research-only (Blizzard 2013 licence). |
| Kyutai Pocket TTS (alba) | 4.2 | 3.5 | 1.48 (stream 0.07) | 163 | 1% / 29% | 219 MB fp32 + 6 MB voice | OK (MIT code, CC-BY-4.0 weights, alba voice CC-BY-4.0, no phonemizer). Needs attribution. Avoid built-in voices from Expresso/EARS (non-commercial). Needs a non-PyTorch runtime on iOS. |
| Samantha (Mac, `say`) | 15.3 | — | — | 232 | 2% / 8% | 0 (system) | OK (system voice). |
