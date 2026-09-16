# Verification ledger

**The final manifest is verified and closes the engineering gate.** Earlier checkpoints used earlier source inputs and are retained for diagnosis.

| Evidence | Result / interpretation |
|---|---|
| `download-tests.log` | Initial 12 download tests passed. Later ownership/network changes are covered by final-gate selection. |
| `lifecycle-edition-tests.log` | 23 download and shared-package tests passed at the edition-binding checkpoint. Post-test simulator diagnostics were interrupted, not test execution. |
| `transport-performance-regressions.log` | Four focused core tests passed: deferred versus explicit transport, retired speech callbacks and measured repair work. |
| `performance-counterexample.log` | Intentionally removed the repair cache guard, ran the count test, restored the file in `finally`. Six assertions failed (40 vs 20 loads; 42 vs 22 after duration change). Final fast gate retests the restored implementation. |
| `sqlite-contention-before.log` | Independent write lock caused an immediate failed save and missing item, as expected before the fix. |
| `sqlite-contention-after.log` | All nine SQLite safety tests passed after adding the bounded busy timeout. |
| `ui-isolation.log` | Long-response autoplay and written-Margin route passed, unchanged assertions. |
| `ui-remaining.log` | The other four historical UI failures passed, unchanged assertions. Post-test `simctl diagnose` was interrupted only after all four ended; Xcode finalized successfully. |
| `final-boundaries.log` | 13 download cases and feed-import case passed. Supertonic case still failed after replacing only the final fixed sleep; this led to the controlled-render test correction. |
| `render-gap-controlled.log`, `ipad-final-boundaries.log` | Test launch did not connect. Interrupted/incomplete; no product result inferred. |
| `artifacts/test-runs/handoff-readiness-2026-09-15-release/manifest.json` | Initial full gate: fast checks passed, zero Xcode tests connected. Interrupted/incomplete. |
| `artifacts/test-runs/handoff-readiness-2026-09-15-release-retry/manifest.json` | Reboot restored execution. Found the independent-writer failure and Supertonic sequencing failure. Stopped to repair; incomplete, not green. |
| `artifacts/test-runs/handoff-readiness-2026-09-15-final/manifest.json` | **Verified: 491/491 passed, zero failures or skips**, stable source input `cd1c246eb016b34e0794fc336d5b137a32d42ae57e9ac6768390b7d1553121f7`. Fast checks green (303 package passes, one declared skip). Includes every active app/adapter/UI/canary test. |
| `device-build-final.log`, `device-build-identity.json` | Current generic iOS device build passed. Exact local binary hashes recorded; no installation/distribution. |
| `watch-build.log` | No Watch scheme in active project; Watch runtime excluded by authoritative release lane. Not counted as a passing build. |

The final run passed all 461 app/adapter cases and all 30 UI cases, including the full-article speech canary, explicit Download Again, feed import and controlled render gap. Xcode completed normally; no diagnostic child interruption was needed for this final run. Source input identity remained unchanged.

## Environment evidence

`simulator-audio-failure.log` plus `long-response-events.json` demonstrate the earlier iOS 18.6 speech output failure and implausibly rapid completion. `test-launch-sample.txt` shows the later stalled test host's idle main run loop. These distinguish environment failures from passing product checks; they do not erase failed/incomplete runs.

## Stopping rules

- No repeated unchanged test retry without new failure evidence, changed source or an identified environment repair.
- No missing or interrupted test counted as passed; final inventory must match executed cases.
- Once the final required gate passes, no extra broad reruns without a new concern or changed input.
- Owner acceptance, real background/Lock Screen behavior and hardware memory/audio claims remain separate from automated verification.
