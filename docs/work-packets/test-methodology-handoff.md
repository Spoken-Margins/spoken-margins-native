# Test methodology handoff — 2026-09-07

## Current state

The owner resumed this work after the September 4 usage-limit stop. Branch: `codex/provisional-next`; HEAD: `90d08c19ddf957c70b8a34077f73a58f92771544`. Implementation remains uncommitted. No branch, commit, release, distribution or automation was created. Existing audio-policy changes are preserved. Read `docs/release-lanes.md` and `AGENTS.md` before further implementation; this methodology work is authorized on this lane, single-agent only.

The methodology implementation and phone failure repairs are complete. All 383 app cases pass on the latest source. Every one of the 24 phone UI cases has passed across the complete audit and focused correction runs. This is **not one clean complete Release pass**: original failures remain recorded, and unchanged routes were not repeatedly rerun after test-only corrections. The five-route iPad UI plan is **incomplete**: its first boot repeatedly stalled in Apple Core Location migration before any app test started, including after a controlled restart. The dedicated simulator is shut down; no verification process remains running.

Read next:

- `docs/testing.md`: routine commands, selection and evidence boundaries.
- `artifacts/reviews/2026-09-04-test-methodology/implementation.md`: changes and findings.
- `artifacts/reviews/2026-09-04-test-methodology/review.md`: original history-backed review.

## Verification evidence

All paths below are under ignored `artifacts/test-runs/`; each includes a manifest, exact commands and raw logs. Xcode runs include result bundles.

| Run | Result and purpose |
| --- | --- |
| `20260907-093437-295068-release` | Failed/incomplete: zero test starts, pre-test attachment stall. Manually interrupted after diagnosis; process samples retained. |
| `20260907-093848-953460-release` | Complete audit: 383 app passes; 18 UI passes, six UI failures. Fast/build/bundle checks passed. |
| `20260907-100250-708425-release` | Complete correction audit: 382 app passes, one SQLite inspection-setup failure; 21 UI passes, three UI failures. |
| `20260907-105138-000270-fast` | Final verified: ten infrastructure tests, eleven browser tests, all validators, 261 package passes and one named intentional corpus skip. |
| `20260907-102303-545035-focused-app-ui-repairs` | All 383 app cases plus recipient and deletion passed; sender and stronger keyboard assertion failed. |
| `20260907-102856-340688-focused-app-ui-repairs` | All 383 app cases plus recipient and deletion passed. Layout experiment did not pass; sender exposed a stale post-share expectation. |
| `20260907-103506-271671-focused-app-ui-repairs` | All 383 app cases plus sender, recipient and deletion passed. Only keyboard gesture/clearance remained failing. |
| `20260907-104054-722587-focused-app-ui-repairs` | Verified: all 383 app cases plus the stronger accessibility layout route passed. Original Add Source runtime retained. |
| `20260907-104318-740988-ui` | Failed/incomplete: iPad boot readiness timed out during CoreLocationMigrator; zero app/UI tests started. Migration sample retained. |
| `20260907-104820-879594-ui` | Failed/incomplete: same pre-test migration stall after dedicated simulator restart and scoped locationd restart; service sample and recovery notes retained. |

Final `git diff --check` and wrapper shell syntax checks pass. `audit-coverage.json` beside the final phone focused run maps all 407 last passing observations to their source runs and explicitly disclaims a single clean Release pass.

The complete September 4 release attempt was interrupted at the owner's request; its partial pass record is historical, not a release pass. No benchmark or empirical speedup claim is made.

## September 7 findings and repairs

- Emoji speech completion legitimately returns Home; preserve observed completion and pause/resume while allowing that transition. The real speech canary passed in the complete correction audit.
- Item-detail navigation used an obsolete `queue.row` selector; the current Library row route passes.
- UI test mode injected obsolete compact debug controls into Now Playing. Removed only that injection; native system playback-state and no-debug-panel tests both pass. Pre-existing mixed-audio UI work is unchanged.
- SwiftUI parent stage identifiers replace the exposed identifiers on Sharing options and its switch. Use the actual button/switch labels, verify the switch value changes, and retain stale-preview assertions. Commit `8bca934` deliberately changed system-share dismissal to Review; require native sheet disappearance, Review, and a reopened verified preview.
- Recipient Add Source can initially be under the pinned Import footer. Scroll the explicitly typed recipient ScrollView, assert full clearance, and then exercise return/import/provenance/no-autoplay.
- The deletion test tapped under a keyboard toolbar and accepted the Library behind a modal as readiness. Dismiss the keyboard and require Add Source sheet disappearance. Current Library deletion goes directly to recoverable Recently Deleted; permanent deletion still requires confirmation and must remain non-restorable.
- Stronger keyboard geometry includes the accessory toolbar. A naive swipe uses a ScrollView frame extending under the keyboard, or is consumed by a nested text editor. Drag the form margin within its actually visible bounds. This passes with the original runtime. An experimental custom toolbar was reverted; do not describe it as a retained product fix or claim the original layout was proven defective.
- Opening a second SQLite store performs schema metadata writes. Prepare the inspection connection before asynchronous import work, then retain the persisted wrong-item and re-import assertions. All 383 app tests passed repeatedly after this setup correction. This does not claim general concurrent-migration hardening.
- Fingerprints now include `Tools/` and root `schemas/`, with a negative-case infrastructure test. The runner performs separately bounded simulator boot/readiness before execution.

## Remaining closeout and later work

1. Resolve the dedicated simulator's first-boot Core Location migration stall, then run:

   ```sh
   .venv/bin/python scripts/verify-tests.py --plan ui --device BEBBB4FD-E13C-457C-A41F-DD7DF02B5C51
   ```

   The tablet build/bundle checks passed, but neither boot-readiness attempt reached test execution. Do not bypass readiness or count the nominal Booted state as success. See both failed manifests, `migration.sample`, `locationd.sample` and `recovery-notes.txt`. Phone: iPhone 17 Pro / iOS 26.5, `856FA6EF-5E03-4120-939B-F0EF42A804E8`. Dedicated tablet: iPad Pro 11-inch (M5) / iOS 26.5, `BEBBB4FD-E13C-457C-A41F-DD7DF02B5C51`. Do not erase the owner's separate TestFlight simulator.
2. Before an actual release handoff, require a new clean `--plan release` on the chosen final source; focused corrections do not retroactively turn failed release manifests green.
3. Optional later improvements: controlled late-import/recovery histories; device-captured upgrade libraries complementing synthetic prior-source databases; carefully baselined rendered snapshots/accessibility audits; explicit shared-store concurrency/cleanup coverage. These are incremental extensions, not hidden passing claims.

## Implementation map

- `scripts/verify-tests.py`, `scripts/test_inventory.py`, `scripts/tests/test_verification.py`: bounded execution, compatible build reuse, selected/executed reconciliation, retained first failures, process lock and evidence.
- `TestPlans/`, three new shared Xcode schemes and additions to `project.yml`: AppBehavior 375; AudioAdapters 8; UISeams 5; Smoke 1; SpeechCanary 1; Release 407.
- Existing `verify-gate1-routine.sh`, `verify-gate1.sh`, `verify-gate2.sh`, `smoke-simulator.sh` now delegate to explicit plans. Gate 1 closeout requires `IPAD_UDID` and runs Release on phone plus UISeams on tablet.
- `validation/test-inventory.json`: all 23 traces classified (17 active, three deferred product-surface traces, three archived Watch traces), with one documented empty JSON fixture selection.
- `TraceReplayTests.swift`, `Fixtures.swift`, surface validator: canonical Contracts inputs and strengthened runtime assertions. Two strict expected-failure tests are counterexamples checking the assertion machinery, not suppressed product failures.
- `Contracts/fixtures/persistence/`: standalone synthetic databases produced by exact old sources for external Build 19 and internal Build 25. Schema/provenance/digest checks and `PriorBuildPersistenceTests.swift` cover reopening and session isolation. Do not regenerate during ordinary verification. Generator is `scripts/generate-prior-build-fixture.py`.
- `ExportIsolationRegressionTests.swift`: actual equal-length, distinct-note export content; UI export test renamed to its real reachability claim.
- `verify-bundle.py`, `check-share-preprocessor.cjs`: built UTI/share-extension declarations and actual bundled PDF preprocessing entrypoint.
- Production delta from this task: SystemSpeechPlaybackClient availability injection; read access for @testable trace anchor observations; source-context scheduling waits for note transcription and deduplicates pending work.

## Working-tree preservation

Pre-existing changes include Gate1AppModel, Gate1RootView, SupertonicSpeechPlaybackClient, app workflow and speech tests, SessionKit Protocols/AudioAdapters/core tests, Xcode project and release-lane docs; deleted PlaybackGainAudioMix source/tests; untracked MixedPlaybackAudioSessionTests and PlaybackAudioSessionPolicy. These belong to existing audio-policy work. Do not revert or attribute them to this task.

The initial tracked diff is saved at `/tmp/test-methodology-start.diff` (includes the newly recorded methodology authorization). Comparing against it confirmed the pre-existing Gate1RootView, SupertonicSpeechPlaybackClient, workflow-test, Protocols and core-test diffs are unchanged. The app-model delta from that snapshot is just the six-line scheduling guard/comment; the AudioAdapters delta is the availability injection. This file is local convenience evidence, not the only recovery record.

## Evidence boundaries and later expansion

Safari PDF delivery is still subject to the exact manual-flow proof required by the release lane. Bundle checks do not establish that the flow is fixed. Physical-device audio/background behavior and archive/signing evidence remain separate. The prior-release databases are synthetic old-source output, not device captures. Watch stays archived; deferred trace execution remains explicitly unclaimed.

The implemented async improvements cover seek cancellation, background-start completion and the discovered transcription race. Broader controlled late-import/recovery histories and model-output quality corpora can be extended incrementally from the original review; there is no new generic virtual-clock framework or agent-driven per-commit UI dependency. No empirical speedup is claimed.

