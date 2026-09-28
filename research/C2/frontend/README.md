# C2 M3: a license-safe text front end for KittenTTS

KittenTTS nano 0.8 fp32 is the bundled fallback voice (M2, #192). Its reference front end turns text into phonemes with espeak-ng, which is GPL-3.0 and can't ship on the App Store. VoiceBench avoided the problem by feeding pre-tokenized input, so the app has no front end yet. This folder is the replacement, built and measured in the cloud. The Swift port is a (Mac) step.

**A/B listening page:** https://claude.ai/artifact/Nfkm6t2FNcixPT67QQnvXR (private to the owner). Nine passages, each read by the same Kitten voice with espeak's front end and with this one, blind. The answer key is [listening-ab/answer-key.md](listening-ab/answer-key.md). The page's clips are one render each. Fixes made after publishing (see Files) didn't change the phonemes of any of the nine passages.

## How it works

Kitten was trained on espeak's phoneme spelling, so the job is to produce **espeak-style IPA without espeak's code or data**. Per word, in order:

1. **Text normalization** ([normalize.py](normalize.py)): the published I14 rules.
   - Numbers, years, ordinals and clock times.
   - Statistics (`p < 0.001`, `95% CI`), units after a number (`ng/mL`, `mM`, `°C`), and Greek letters.
   - Mixed codes are spelled out (`HbA1c` → "H B A one C").
   - Citation markers are silent, and "et al." becomes "and colleagues".
   - It's self-contained: no num2words, which is LGPL.
2. **Function words** ([frontend.py](frontend.py) `FUNCTION`): about 70 words in hand-written reduced forms ("the" → ðə, or ðɪ before a vowel; "a" → ɐ; "to" → tə).
3. **Dictionaries:** misaki's US gold dictionary first, then the CMU Pronouncing Dictionary, both rewritten into espeak's conventions by [lexmap.py](lexmap.py).
   - The rules cover diphthongs, long vowels, r-coloured vowels, linking r, secondary-stress habits and reduced vowels.
   - They were derived by comparing the dictionaries with espeak output on common words. espeak is used only as a measuring stick.
4. **Spelled-out letters:** abbreviations (`PBS`) and words with no vowel letter (`km`).
5. **Glued compounds** are split into two dictionary words (`hydroxyvitamin`).
6. **Neural fallback** for everything else ([neural_g2p.py](neural_g2p.py)). This reimplements g2p_en's small GRU letter-to-sound model: 3.3 MB of weights trained on CMUdict, and plain matrix math, so the Swift port is direct. It matches g2p_en's own output exactly on the words checked.

## Results (Linux, 2026-09-28)

**Audio: Whisper word errors** for Kitten nano fp32 reading each passage (lower is better).
- The reference is what I14 says should be heard, so silent citation markers aren't counted.
- **Kitten samples randomly:** the same sentence rendered twice gives different audio, and a single render can swing a passage's score by ±15 points. So each figure is the mean of 3 renders; the per-run numbers are in `results/linux/frontend-ab.json`.

| Passage | espeak front end | This front end |
| --- | ---: | ---: |
| Narrative | 3% | 4% |
| Scientific (M2 passage) | 30% | 10% |
| Essay with dialogue | 3% | 0% |
| Names and numbers | 30% | 15% |
| Statistics | 43% | 26% |
| Lab methods | 16% | 15% |
| Rare words | 13% | 9% |
| Citations | 69% | 0% |
| Dialogue | 12% | 9% |
| **Mean** | **24%** | **10%** |

These figures come after the comma fix below (2026-09-28). Narrative is within noise: its three runs were 5%, 3% and 3%.

Most of the gain is normalization. espeak reads "95% CI" as "sigh", "ng/mL" as "N G slash M L", "p < 0.001" as "P0-001", and reads "[4, 7–9]" and "et al." aloud.

**Phonemes: agreement with espeak**, because Kitten was trained on espeak's spelling:

| Words | Exact match | Mean character difference |
| --- | ---: | ---: |
| 2,000 most common words (dictionary path) | 79% | 3.3% |
| All 12,182 common words in the dictionary | 70% | 4.2% |
| 500 rarer words, dictionary path | 47% | 8.4% |
| The same 500, pretending they're unknown (neural path) | 39% | 12.5% |
| 2,000 most common words, **CMUdict only** (no misaki) | 74% | 4.3% |

The remaining differences are mostly unstressed vowel quality (ə against ɪ or ᵻ), which is hard to hear. The listen decides whether they matter.

## Owner A/B listen (2026-09-28)

Saved on the A/B page. The letters were decoded with the answer key after saving.

| Passage | Preferred |
| --- | --- |
| Narrative, Scientific, Essay with dialogue, Statistics, Lab methods | **new front end** |
| Rare words, Dialogue | same |
| Names and numbers, Citations | espeak front end |

- **Result:** the new front end wins 6, espeak 2, with 2 ties. That passes the bar: at least "Same" on narrative, essay and dialogue.
- **The owner's note:** "both have trouble with numbers with commas in them (e.g. 1,124 kg)". Kitten drops "one thousand" from "one thousand two hundred fifty" (heard as "250", 3 of 3 renders). With a comma after the scale word ("one thousand, two hundred fifty") it's heard correctly 3 of 3, and the same holds for "1,284 adults". `int_words` now adds that comma.
- **Follow-up, same day.** The owner still heard "two [uh] eighty-four".
  - Number words now use hand-written forms in Kitten's training style: "hundred" as hˈʌndɹɪd, "eighty-four" as one word, and teens stressed first.
  - On a four-way number check (https://claude.ai/artifact/VqXcYqZRPdxCdUEFW4stR1), the owner heard A (comma after "thousand" only) choke into static on "hundred", and C ("twelve hundred eighty-four") cut off. B (with "and") and D (a comma after "hundred" as well) were clean. **The owner picked D:** "one thousand, two hundred, eighty-four". `int_words` now does that. This affects the Names and numbers passage the owner preferred espeak on, whose clips were rendered before the fix.

## Licenses of what would ship

| Part | License | Size |
| --- | --- | --- |
| Front-end code (normalizer, mapping rules, function words, neural inference) | ours | small |
| misaki US gold dictionary, mapped (`lexicon.tsv`, merged with CMUdict; keys keep their case, lookup is exact then lowercase) | Apache-2.0 (misaki repo). Its original sources aren't documented | 4.4 MB raw, 1.3 MB gzip, 181,999 entries |
| CMU Pronouncing Dictionary | BSD-style (keep CMU's copyright notice) | included above |
| g2p_en neural weights | Apache-2.0 | 3.3 MB |
| KittenTTS nano 0.8 fp32 weights | Apache-2.0 | 57 MB + 3 MB voices |

- misaki's silver dictionary is left out on purpose. Its origin is unclear, and the gold dictionary plus CMUdict and the neural fallback cover the same ground.
- If misaki's undocumented provenance ever becomes a concern, **CMUdict alone** loses little (4.3% against 3.3% on common words).
- None of espeak-ng, phonemizer, piper or misaki's code ships. A test fails if the front end imports any of them.
- **Total added for the front end: about 5 MB compressed**, on top of the 60 MB the owner already accepted for Kitten.

## Files

- `normalize.py`, `lexmap.py`, `neural_g2p.py`, `frontend.py`: the front end (Python reference).
- `test_frontend.py`: 17 host tests, including the I14 examples, cases from a fresh review (decades, plain 4-digit numbers, currency, minus, hyphen ranges, dotted abbreviations, acronyms, capitalised dictionary entries), the no-GPL guard and the reference vectors. Run with `.venv/bin/python -m unittest discover -s frontend` from `research/C2`.
- `eval_lex.py`: phoneme agreement with espeak. `ab_eval.py`: renders and scores the audio A/B.
- `hard_passages.json`: the six harder passages.
- `export_for_swift.py`: writes `lexicon.tsv` and the neural weights as raw float32 with a manifest (both git-ignored, regenerate any time), and `test_vectors.json`. The vectors map text to normalized text, phonemes and Kitten ids, and are what the Swift port must reproduce.
- `build_ab_page.py`, `ab_template.html`: the A/B page. Its audio is git-ignored.

## What's waiting

**(owner)** The A/B listen, about 10 minutes with headphones.
- Pick X better, Same or Y better for each passage, then tap Save choices.
- **Pass:** the new front end is at least "Same" on the everyday passages (narrative, essay, dialogue). The scientific passages should favour it.

**(Mac)** The Swift port, in SessionKit so it's host-testable:
- the normalizer, the lexicon loader (`lexicon.tsv`, bundled gzip), the function words, letter spelling, compound split, the GRU inference over `g2p_weights.bin`, and the `espeakify` rules for neural output;
- then Kitten's symbol table and the ONNX call already written for VoiceBench.

**Done when:**
- `swift test` reproduces every entry in `test_vectors.json` exactly.
- Kitten plays through it inside the app, as M3's automatic fallback, with a short first chunk.
