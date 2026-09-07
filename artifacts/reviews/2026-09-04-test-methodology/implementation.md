# Test methodology implementation — 4 September 2026

Implemented on `codex/provisional-next`, starting at `90d08c19ddf957c70b8a34077f73a58f92771544`, with the existing uncommitted audio-policy work preserved. Product-owner authorization is recorded in `docs/release-lanes.md`. This work changes verification infrastructure and focused regression coverage; it does not authorize distribution or establish human validation.

## What changed

| Concern from the review | Implementation | Detection responsibility |
| --- | --- | --- |
| Gate labels hid omissions | Named Xcode plans, source inventory, selected-versus-executed reconciliation | Stale selectors, zero execution, missing tests, unexpected skips and failures all reject the run |
| Broad simulator overhead in routine work | Separate app-only scheme; `fast`, `app`, `adapters`, `smoke`, `ui`, `speech-canary`, `release` commands | Keep all cheap coverage; assign expensive checks to an explicit plan |
| Arbitrary/stale build reuse | Exact per-scheme build location and content/toolchain/runtime/plan fingerprint | Reject source changes during verification; never pick an unrelated DerivedData app |
| Root fixtures diverged from Contracts | Swift fixture/profile loading and surface references now resolve into `Contracts/` | Validators and replay inspect the same runtime inputs |
| Trace omissions and weak assertions | Seventeen individually reported traces; explicit dispositions for six unselected traces; runtime anchor, chapter, selection, deletion and complete-text checks | Detect incorrect state rather than asserting fixture declarations |
| Export “isolation” checked a size label | Rename the UI claim to reachability; add actual export-content isolation with equal-length sentinel notes | Same-size wrong-session content must still fail |
| Scheduling and incidental waits | Controlled render gates, cancellation expectations and player-start confirmation | Seek cancellation and background-start behavior no longer depend on fixed sleeps in the changed tests |
| Synchronous unavailable-voice lookup stalled the suite | Inject the availability decision for the policy test; retain real adapter checks in their own plan; externally bound child processes | A blocked system lookup cannot silently consume an unbounded routine run |
| Prior-build compatibility depended on today's encoding | Synthetic databases written by pinned, unmodified Build 19 and Build 25 model/persistence sources | Open schema 4/5 data, preserve colliding logical note IDs in separate sessions, update one position, reopen and check both sessions |
| Browser helper evidence stopped before the bundle | Inspect the built app UTI and share-extension metadata; execute the built preprocessing resource | Catch absent resources, unresolved principal classes, missing declarations and broken Safari JavaScript entrypoints |

The historical database fixtures have schema-validated provenance and content digests. The generator uses an isolated temporary Swift package, enables testable access to the old model initializer, and consolidates SQLite journals before exporting each standalone file. These are old-source-produced synthetic libraries, not device-captured libraries.

## Failures resolved

- Source-window transcription could start through the acoustic-evidence failure fallback before the saved Margin's transcription finished. Scheduling now defers while that note is pending and deduplicates in-flight source-context work. The existing controlled-order test passes.
- The BBC retry test expected a Wi-Fi wait without providing the network condition that requires waiting. It now explicitly supplies unavailable networking.
- The private episode-map policy assertion predated the authorized private-map feature. It now checks explicit request routing and absence of unsolicited full-source transcription.
- The older-session restoration fake reported a five-minute duration even when configured with a one-hour episode. It now honors configured media duration, retaining the exact-position assertion.
- A background-render test used a 350-ms sleep to infer completion. The complete app run exposed this race; the test now controls release of the render and waits for the playback-start callback.

No failing assertion was removed to conceal an unresolved failure. Earlier failed and incomplete runs remain in the local evidence directories.

## Checks on the checks

The infrastructure tests deliberately exercise missing/extra tests, zero execution, unexpected skips, renamed selectors, unclassified fixtures/traces, empty schema selections, a broken JavaScript entrypoint, process timeout, and a failure followed by passing retries. The parser retains the failing attempt.

Two strict, narrowly scoped expected-failure tests exercise the actual trace assertion code with a missing recording anchor and changed source text. If the old permissive behavior returns, these tests fail because the required counterexample failure disappears. These expected failures are counterexample tests, not quarantined product regressions.

## Verification evidence

The complete September 7 audits ran all 407 active app/UI cases and exposed the failures described below. All 383 app cases pass on the latest source. Every phone UI case has passed across complete audit and focused corrections, including the real emoji speech canary. The latest focused run (`20260907-104054-722587-focused-app-ui-repairs`) passed all 383 app cases and the strengthened accessibility layout test. This is not a single clean Release pass; original failing runs remain failed.

The fast suite passed ten infrastructure tests, eleven browser tests, all validators and 261 package tests with one explicitly named held-out-corpus skip. The five iPad UI seams remain incomplete: first-boot Core Location migration stalled before test execution in two bounded attempts, including after a dedicated simulator restart. Build/bundle checks passed; migration/service samples and exact resume instructions are retained. Final fast verification is `20260907-105138-000270-fast`; whitespace and wrapper shell syntax checks pass. See `docs/work-packets/test-methodology-handoff.md` for exact run directories and current status. Raw logs, selected IDs, per-test results, build fingerprints and Xcode result bundles remain under ignored `artifacts/test-runs/`.

## Boundaries retained

- Only the product owner establishes `human_validated` behavior.
- Built Safari metadata and payload checks do not establish extension discovery or successful Safari PDF handoff. The release lane's exact manual-path proof remains required.
- Physical-device audio balance, background behavior and release archive/signing checks retain their own evidence requirements.
- Watch remains archived. Deferred trace scenarios are named with reasons; they are not counted as executed.
- The held-out podcast corpus remains an explicit alignment benchmark, with its ordinary-package skip allowed by exact test ID.
- No benchmark or speedup claim is made. The machine was concurrently doing research, TTS and video rendering; the user requested correctness over benchmarking.


## September 7 continuation

The first completed Release audit (`20260907-093848-953460-release`) passed all 383 app cases and 18 of 24 UI cases. Corrections preserved the behavior assertions:

- The speech canary observes completion and pause/resume while allowing the legitimate transition Home.
- Item navigation uses the current Library row identifier.
- UI test mode no longer injects the obsolete compact-controls debug panel. Both the negative panel assertion and native system playback-state route pass.
- Sender tests open Sharing options using its exposed label and assert the switch value changes before checking stale-preview invalidation. Captured hierarchies demonstrate parent stage identifiers overriding child identifiers. Git commit `8bca934` intentionally changed share-sheet dismissal to Review; the route now verifies that return and reopens the verified preview.
- Recipient Add Source is scrolled clear of pinned actions using the actual ScrollView. The test retains source-return, import, provenance and no-autoplay assertions.
- Deletion waits for the keyboard and Add Source sheet to disappear, follows the current recoverable Library deletion action, and retains permanent-deletion confirmation and non-restoration checks.

The interaction evidence establishes a specific test-design rule: `exists` can match a screen behind a modal, and `isHittable` alone does not establish full clearance from a pinned footer or keyboard accessory. A ScrollView's accessibility frame can also extend beneath the keyboard. Gesture start/end points must stay within the visible scroll surface and avoid nested editors. The stronger accessory-toolbar geometry assertion passes after correcting the gesture, with the original Add Source runtime retained. An experimental custom toolbar was reverted after it did not resolve the test; there is no retained Add Source layout change or demonstrated need for one.

A correction run exposed intermittent `step_metadata_write` failure in the populated podcast import test. SQLite initialization writes migration metadata. Creating its inspection connection before starting asynchronous model work removes that competing setup writer while preserving actual persisted wrong-item and reconstruction checks. Repeated subsequent complete app selections passed. This is not a claim of general multi-connection migration hardening.

A pre-test simulator attachment stall remains recorded in `20260907-093437-295068-release`, with diagnostic samples and explicit interruption status. The runner now waits for simulator boot readiness under a separate deadline; this is not a claim that every XCTest attachment failure is fixed.

Input fingerprints include browser sources/tests under `Tools/` and root surface schemas under `schemas/`. A new infrastructure counterexample mutates each input independently and requires the fingerprint to change.
