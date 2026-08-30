# Podcast anchor benchmark — sharing-next

Status: `verified` on 2026-08-29. This is automated evidence, not product-owner validation.

Implementation commit: `f96194a` (`Complete testable one-way sharing experience`)

Machine-readable result: `podcast-anchor-benchmark-result.json`

## Release decision

The automatic podcast-placement gate passes for the production fused/monotonic resolver:

| Method | Confident eligible | Declined eligible | Correctly declined absent | Wrong confident | p95 placement error | Decision |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Acoustic, two-flank | 215 / 226 | 11 | 6 / 6 | 0 | 4 ms | Eligible |
| Acoustic + transcript corroboration + monotonic guard | 210 / 226 | 16 | 6 / 6 | 0 | 4 ms | Production gate passes |
| Sender timestamp only | 226 / 226 | 0 | 0 / 6 | 188 | 65,000 ms | Rejected |
| Transcript only | 175 / 226 | 51 | 6 / 6 | 95 | 4,560 ms | Context only; rejected for placement |

The release criterion recorded in `docs/release-lanes.md` is zero wrong confident placements and p95 error no greater than 1.5 seconds on at least 200 held-out anchors. The fused/monotonic method has zero wrong confident placements and 4 ms p95 error across 232 total anchors, including 226 eligible anchors and 6 passages deliberately absent from the recipient edition.

Production policy derived from this result:

- Exact-edition digest matches can use the sender media time.
- Cross-edition placement requires unambiguous acoustic evidence. When both before and after signatures are declared, both must agree on the same placement.
- Transcript evidence may corroborate an acoustic match but cannot place a Margin by itself.
- The monotonic guard declines both anchors involved in an ordering inversion.
- Ambiguous, absent, unresolved, and wrong-source results never enter inline playback.
- Timestamp fallback is disabled. Equal total duration cannot prove timeline equivalence when an insertion and deletion offset each other.

## Held-out corpus

The held-out source was chapter 4 of the public-domain [LibriVox recording of *The Adventures of Sherlock Holmes* (version 5)](https://archive.org/details/the_adventures_of_sherlock_holmes_v5_1904_librivox), marked [Public Domain Mark 1.0](https://creativecommons.org/publicdomain/mark/1.0/). Chapter 5 supplied the inserted speech segment. No source audio, model, transcript, or generated recipient edition is committed.

The runner deterministically creates a recipient edition with:

- a 45-second inserted speech advertisement at source time 240 seconds;
- deletion of source seconds 480–500;
- a repeated source passage after the 700-second boundary;
- deletion of source seconds 900–906; and
- MP3-to-AAC re-encoding with a different sample rate and bitrate.

Anchors are sampled every 5 seconds. The edit manifest determines the expected recipient location or marks the source passage absent. The corpus is identified as `held_out_after_rule_freeze` in the JSON result.

## Calibration and falsification history

Chapter 1 was used only for calibration. It exposed a false confident placement when one side of a declared two-flank signature matched and the other did not. The resolver was tightened to require agreement from both declared flanks. The rules were then frozen before running chapter 4 as the held-out partition.

Additional falsification checks cover:

- a synthetic inserted-ad case in which conflicting acoustic matches must be ambiguous;
- an equal-duration insert/delete counterexample that must not permit timestamp fallback;
- repeated transcript phrases and transcript/acoustic contradiction;
- monotonic ordering inversions;
- tampered packages and unknown required artifacts; and
- removed recipient passages that must be declined.

The production stopping rule is conservative: a decline is acceptable; one wrong confident placement fails the method.

## Reproduction

Run from the repository root:

```bash
./scripts/run-podcast-anchor-benchmark.sh
```

The script uses a temporary cache outside the repository, builds current SessionKit code, downloads the public-domain corpus and a `whisper.cpp` base English model if absent, transforms the audio, executes only the held-out XCTest, and rewrites the JSON result. The run recorded here generated all evidence in 7.87 seconds and resolved it in 1.10 seconds on the development Mac; those timings are developer evidence, not a phone battery or thermal measurement.

## Remaining uncertainty

This result covers one held-out long-form spoken-work pair with representative insertion, deletion, repetition, silence editing, and transcoding changes. It does not establish performance across every podcast production style, music-heavy show, dynamically mixed ad boundary, or physical iPhone thermal state. Product-owner device testing should therefore look for conservative declines as well as correct placements. Any wrong confident placement stops external release and requires a new held-out falsification case before changing the resolver.
