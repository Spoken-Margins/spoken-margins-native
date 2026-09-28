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
| Samantha (Mac, `say`) | — | — | — | — | — | 0 (system) | OK (system voice). |
