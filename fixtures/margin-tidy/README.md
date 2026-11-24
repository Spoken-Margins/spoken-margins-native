# Spoken-Margin tidy eval (#4339)

Runs invented spoken Margins through Apple's on-device model and scores what comes back. Every Margin and passage here is
made up; no Library data belongs in this folder.

Needs a Mac with Apple Intelligence on (macOS 26.4 or later). Nothing here runs in CI.

## Files

- `build_cases.py` writes `eval-cases.json`: 36 Margins (short, numbers, names, quotes, negations, questions, a
  self-correction, Spanish, an injection attempt, profanity, sensitive history, misheard words, long rambles), each with
  the passage around it, the terms that must survive (`mustKeep`) and words that must not appear (`mustNotContain`).
- `variants.json` is the prompt history: every wording tried, oldest first. `app: true` sends what the app sends in one
  request; `proposer: true` runs the app's whole path (`MarginTidyProposer`: pieces, guard, filler-only fallback).
- `score.py` scores a results file.

## Run it

```zsh
cd Packages/SessionKit
swift build --product tidy-eval
.build/debug/tidy-eval --cases ../../fixtures/margin-tidy/eval-cases.json --variants ../../fixtures/margin-tidy/variants.json --only v6-app-proposer --out ../../artifacts/tidy-eval/run.jsonl
```

```zsh
python3 fixtures/margin-tidy/score.py artifacts/tidy-eval/run.jsonl --show
```

`--case id1,id2` runs only some Margins. `artifacts/` is git-ignored.

## What the scores mean

- **offered**: the app would show the model's version (it passed `MarginTidyGuard` and is not the same words).
- **kept**: every `mustKeep` term is still there and no `mustNotContain` word is.
- **clean**: no filler left, no preamble or refusal, ends in punctuation, same language, no name or passage words the
  speaker never said.
- **good**: offered, kept and clean. For the Margin that is already clean, kept and clean.

The scorer is a rough meaning check, not a reader. Read `--show` output before trusting a change of one or two points.
