# I14 · Speech engine selection (§1–3 draft; §4–5 published)

> **Status:** §4 (roles and markers) and §5 (normalization) are published in `docs/workstreams/interfaces.md` under I14 (2026-09-28). That page is authoritative for them. §1–3 (engine selection, rate, chunk boundaries) remain a draft until C2 M1 (#183).

I14 answers three questions for every narration path: which engine and voice render, and why; how fast they speak; and how each I13 role sounds.

## 1. Which engine and voice, and why

Every render decision produces a **selection**: `{engine, voice, modelRevision, reason}`. The player shows the reason whenever it isn't `userChoice`, and every selection change is logged with the old selection, the new one and the reason.

| Reason | When | Allowed to change the voice? |
| --- | --- | --- |
| `userChoice` | Normal case: the voice the listener picked renders fine. | — |
| `thermalSerious`, `thermalCritical` | `ProcessInfo.thermalState` reaches `.serious` or `.critical`. Observed through `thermalStateDidChangeNotification`, not only polled. | Yes, visibly. |
| `memoryWarning` | Within 60 s of a memory warning. | Yes, visibly. |
| `cannotKeepUp` | Measured render speed falls below 1.3× real time for the upcoming chunks *and* the buffer holds less than 10 s of audio. | Yes, visibly. |
| `modelUnavailable` | The model isn't installed, the Supertonic Terms aren't accepted, or it failed to load. | Yes, visibly. |
| `renderFailed` | The engine threw for this chunk. | Yes, visibly, for that chunk onward until the next retry. |
| Low Power Mode, charging | **Never reasons on their own** (#183). Low Power Mode makes the app *measure* (it can lead to `cannotKeepUp`), not switch. Charging is not an input at all. | No. |

Rules:

- **Order of preference:** the chosen voice → the bundled fallback voice (picked in C2 M2/M3) → the system voice. The system voice is the last resort, not the first fallback.
- **Switch only at a sentence boundary** that is already queued, never mid-sentence.
- **Come back:** when the reason clears and stays clear for 30 s (thermal back to `.nominal` or `.fair`, 60 s after a memory warning, speed back above 2× for the lookahead), the next unrendered sentence uses the chosen voice again. Audio already rendered by the fallback plays out.
- **Voice identity (#64):** prepared audio records the selection it was rendered with, per segment. A segment rendered by a fallback is marked so and can be re-rendered later with the chosen voice.

## 2. One rate

- The app has **one rate number `r`** (1.0 = the engine's calibrated natural pace). It is the only rate. The system accessibility speech rate is never multiplied in: no `prefersAssistiveTechnologySettings = true` on narration utterances, and no reading of the accessibility rate.
- Each engine gets a **calibration factor** so that `r = 1.0` sounds equally fast on every engine (target about 165 words per minute on body text). Switching engines at the same `r` keeps the listener's pace. The research harness measures each candidate's natural words per minute (`results/*.json`, `wpm`).
- Neural engines render at their native speed parameter within its safe range (Supertonic 0.7–2.0). Anything outside that range is applied at playback by time-stretching (pitch preserved), not by pushing the model.
- AVSpeechSynthesizer maps `r` to `utterance.rate` through one function, with `r = 1.0 → AVSpeechUtteranceDefaultSpeechRate`, calibrated to the same words per minute.

## 3. Chunk boundaries

Playback state is the listener's intent, not the renderer's. A chunk ending, a new chunk starting, or a selection change never shows as pause/resume in the player, Now Playing or the Live Activity. If the renderer can't deliver in time (an underrun), the player shows buffering and the transport stays "playing".

## 4. How I13 roles are spoken

Roles are advisory (I13). These are the defaults; per-role settings can come later.

| I13 role | Default | How it sounds |
| --- | --- | --- |
| body | Read | As written, after normalization (§5). |
| heading | Read | About 0.7 s pause before and 0.4 s after. The word "heading" isn't spoken. A section number is read ("2.1 Methods" → "two point one, Methods"). |
| caption | Announced | Read where the reading order places it, never inside a sentence: "Figure 2." with a short pause, then the caption text. While it's read, the player can show the figure (I13 position). |
| table | Announced, not read | "Table 3: *caption*. Table not read." The cells are skipped. |
| footnote | Skipped | Footnote text isn't read in place. The marker in the body is silent. |
| reference (bibliography) | Skipped | Announced once, "References skipped." Reading continues with the next non-reference segment (an appendix, for example). |
| header, footer | Skipped, silent | Running heads and page numbers are never read. |

**Markers inside body text:**

- **Numeric citations** (`[12]`, `[12, 14]`, `[3–5]`, superscript numbers after a word or punctuation) are silent.
- **Parenthetical author–year citations** (`(Smith et al., 2020; Lee, 2019)`) are silent.
- **Narrative citations**, where the name is part of the sentence ("reported by Pittas et al."), are read, and "et al." is spoken as "and colleagues".
- **Footnote markers** (superscript letters, symbols, numbers not matched as citations) are silent.

## 5. Text normalization before any engine

This is engine-independent and applies to every engine, including the system voice, so switching engines doesn't change *what* is said. Evidence from the research: on the scientific passage, Kokoro's lexicon had no entry for `=`, `25-hydroxyvitamin`, `ng/mL`, `[12` or `et`. Each engine mangles these differently.

- Numbers: thousands separators (`1,284` → "one thousand two hundred eighty-four"), decimals ("sixty-one point three"), ranges (`0.75 to 1.04`, `10–20` → "10 to 20").
- Statistics: `p = 0.12` → "p equals 0.12", `p < 0.001` → "p less than 0.001", `95% CI` → "95 percent confidence interval", `±`, `×`, `≥`, `≤`.
- Units: `ng/mL` → "nanograms per milliliter", `mg`, `kg`, `µm`, `°C`, `IU` → "I U". Unit handling needs a number before the unit.
- Greek letters: `α`, `β`, `κ` and so on are spoken by name.
- Leave chemical names, gene names and unknown tokens to the engine. Don't spell out anything that is pronounceable as a word.

## Open for C2 M1

- The `cannotKeepUp` thresholds (1.3×, 10 s) are guesses. Set them from the phone benchmark.
- Whether a fallback-rendered prepared segment is re-rendered automatically once the chosen voice returns.
- Where the listener sees the reason (player chip, Now Playing subtitle, or both). D1 design decides.
