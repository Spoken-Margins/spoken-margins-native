# Bundled Kitten voice: sources and licenses (#849)

No GPL code or data ships. espeak-ng (GPL) is not used; `research/C2/frontend/lexmap.py` only imitates its spelling conventions.

| File | What it is | Source | License |
|---|---|---|---|
| `kitten_tts_nano_v0_8.onnx` | KittenTTS nano 0.8, fp32 | Hugging Face `KittenML/kitten-tts-nano-0.8-fp32`, revision `7a1db645b1f3ab9420761d87428e042b9cec3f26`, sha256 `320564d2615f235de972ca27a7f39551c94185cfa24ca85b07a29084135f1e5e` | Apache-2.0 |
| `voice.f32` | The "Jasper" voice style rows (`expr-voice-2-m`, 400 x 256 float32) | Same repository, `voices.npz` | Apache-2.0 |
| `lexicon.tsv` | Pronunciations, mapped to espeak-style IPA | misaki 0.9.4 `us_gold.json` (hexgrad) plus CMU Pronouncing Dictionary | Apache-2.0 and the CMU BSD-style license |
| `g2p_weights.bin`, `g2p_weights.json` | Letter-to-sound GRU weights | g2p_en 2.1.0 `checkpoint20.npz` (Kyubyong Park, Jongseok Kim) | Apache-2.0 |

The CMU Pronouncing Dictionary (github.com/cmusphinx/cmudict, Carnegie Mellon University) is used under its BSD-style license, which requires its copyright notice and disclaimer to travel with it. Copy that license text verbatim from the repository's `LICENSE` file into this folder before the first TestFlight build that includes this voice (open item on #849).

Regenerate the derived files with `research/C2/frontend/export_for_swift.py`.
