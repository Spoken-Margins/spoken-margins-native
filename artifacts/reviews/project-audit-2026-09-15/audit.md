# Project reliability and regression audit — September 15, 2026

## Conclusion and scope

**Yes: earlier repairs introduced identifiable regressions. They do not establish the cause of the reported podcast incident.** The strongest new example is September 14's incremental offline-progress presentation: finalization saves `readyOffline`, then an older `preparing` snapshot replaces the Library row with `onlineOnly`. A new regression test demonstrated that exact contradiction. This audit repairs it. A separate July system-speech safety change deletes whitespace controls before normalization, joining consecutive words/domain-list entries; a failing regression demonstrates this too, and it is repaired.

Single-agent audit on `codex/provisional-next`, base `6432044bdc5ebff4691a69bee2699c309222ebac`, with pre-existing uncommitted repairs preserved. Reviewed recent history, issue inventory/bodies, playback/download/persistence, native narration/preparation, sharing/edition resolution, import/chapter/PDF paths, performance hotspots, PKM delivery and verification infrastructure. Used synthetic simulator data. No commit, device install, distribution, issue closure, account-provider mutation or owner-data reset. Build number alone does not identify the owner's Xcode-installed source.

## Diagnostic model

- **Resources:** one playback owner, main actor time, bounded memory/disk, durable session/asset/job records, finite owner attention and a 65% account-usage reserve.
- **Lifecycle boundaries:** stream → downloaded rendition; preparing → finalized artifact; asynchronous request → cancellation/deletion/restart; old recipient edition → new recipient edition; source characters → speech projection; stored session → presentation.
- **Failure mechanism:** a locally reasonable repair can be wrong at an adjacent boundary: replacing transport changes the audio clock; publishing stale preparation state undoes completion; removing unsafe controls removes word separators; retaining verified positions can retain evidence for an old edition.
- **Evidence layers:** user-observed symptom; deterministic failing boundary test; static reachable path; simulator observation; physical-device/OS/provider behavior. These are not interchangeable.
- **Decision rule:** repair deterministic narrow defects; preserve failing-before evidence; run the inventory-aware suite; leave identity/lifecycle changes open when they need a larger persistence design or physical-device proof. A passing suite does not establish product acceptance.

## Findings and attribution

| Priority / status | Finding | History and evidence | Consequence / next falsification |
|---|---|---|---|
| P1, repaired earlier in this investigation | Active podcast skip could restart transport and adopt a pending local override | Deferred override introduced `6c28924` (Aug 20); active skip still restarted playback. Strengthened core test failed five assertions before repair; now uses seek on current player. | Plausible contributor to a large jump with dynamically inserted ads, **not proof** of this incident. Verify real Lock Screen skip before/after a background download on the same episode. |
| P1, repaired in this audit | Final preparation snapshot downgrades completed offline row | `6432044` (Sep 14) added incremental progress update. `preparation-counterexample.log`: actual onlineOnly vs expected readyOffline while persisted manifest remains readyOffline. | Final snapshot now consults persisted state only when all chunks are committed and no active job remains. Intermediate progress retains cheap incremental behavior. |
| P2, repaired in this audit | System speech joins lines/tabs into words | `4862874` (July 22), “Sanitize system speech input before playback.” Not newly caused by Sep 4 extraction refactor. `speech-before.log`: four failed assertions, including #111 excerpt. | Preserve whitespace as mapped ASCII space before unsafe-scalar filtering. `speech-after.log`: six speech-projection tests pass. Does not prove pronunciation quality or identify #111's selected engine. |
| P2, repaired in this audit | Margin retrieval and Follow eligibility depend on delayed Library cache | Sep 14 `6432044` made Home refresh asynchronous; three existing integration tests failed after direct fixture insertion followed by navigation. | Margin membership now comes from stored active items; selected-item Follow eligibility uses its loaded sessions. Original race/identity assertions retained, with no extra sleeps or weakened expectations. |
| P1, open, static lifecycle defect | Relaunched background download loses its in-memory storage reservation | `31eab6a` (Aug 27) added reserved downloads. `PodcastDownloadCoordinator` restores task IDs but not `reservationsByItemId`; completion requires that map entry and deletes downloaded file if absent. | Test a persisted URLSession completion across coordinator/process reconstruction. Persist task/generation/reservation association and reconcile with ledger before adoption. |
| P1, open, static race | Deleting an item while asynchronous HEAD/reservation is pending can recreate a download record | `removeItem` removes records/assets but leaves active identity; `beginDownload` checks only item ID after awaits and can persist captured record/start a task. | Controlled test: begin → suspend HEAD → delete → resolve HEAD. Require generation-scoped ownership and release reservation on rejected completion. |
| P2, open, static lifecycle defect | HTTP/adoption failure can strand reservation until expiry | `fail` only updates record; release in completion-error path does not cover all nil-transport-error failures. | Fail HTTP/file adoption after reserve and inspect ledger after reconstruction; centralize terminal cleanup without releasing a replacement task's reservation. |
| P1, open, edition-identity risk | Old verified shared-Margin position survives a newly unresolved match without an edition equality check | `6432044` preservation rule in `resolveImportedPodcastCommentary`; previous per-note result retained on unresolved/absent evidence. Podcast local identity does not supply exact edition hash at that rule. | Real risk when re-download replaces ad rendition; no reproduced misplacement in this audit. Require old/new recipient digest equality or invalidate/reverify; retain good evidence only for the same edition. |
| P2, open, measured cost not established | Media progress repeatedly scans saved interjections | `da04bb9` (July 24) percentage repair; each media-position update invokes `repairMediaPercentages`, which loads session interjections even when duration is unchanged. | A concrete O(number of notes) recurring persistence path; CPU/jank magnitude unknown. Count loads with 0/100/1000 notes, then invalidate only on duration/session/note changes. |
| P2, open, compatibility risk | Offline download requires successful HEAD with positive exact length | Reserved-download path before GET. Desktop source currently supports this, but other servers may not; dynamic GET size may differ. | Test HEAD 405/missing length/different GET length. Use bounded incremental reservation or a documented fallback; do not assume feed startup failure has this cause. |

## Other feature issue review

| Area / issue | Audit disposition |
|---|---|
| #111 domain narration | Concrete projection defect repaired; audible quality, source truncation and selected voice remain unproven. |
| #119 description chapters | Issue already documents repaired Apple fallback and followed-entry description parsing, with owner retry pending. Existing Library entries are not backfilled. Do not present that as a newly introduced failure. |
| #122 memory termination | Reviewed existing streaming hash/cache/lifecycle repairs and transition boundaries. Small seeded simulator success is not a jetsam test. Need exact owner item, device memory trace and podcast → native-text transition. |
| #93 scrolling / #97 Quick Add | Recent incremental presentation reduces reload scope but introduced the final-state bug above. Repeated core note scans remain. No frame-time comparison or physical iPhone 14 performance claim. |
| #83 AirPod pause during partial render | Distinct trigger remains open; ordinary simulator Play/Pause cannot reproduce physical route removal + partial neural rendering. Preserve bounded earlier owner acceptance. |
| #78 PDF structure | Existing canonical-map/header rules and regression coverage reviewed; repeated-header/body-content ambiguity not reproduced. No speculative new defect assigned. |
| #17/#18/#27 shared packages | Edition preservation risk above; conservative unresolved policy is intentional. Package tests cover archive/identity paths; new ad-rendition retention boundary needs regression coverage. |
| #90 Skim | Existing transport regression coverage included in broad suite. No new live repeated-Skim defect reproduced here. |
| #56 local summary | Existing failure/retry state handling reviewed; availability and output behavior require physical model-capable hardware. No claim that the nine-note owner case is repaired. |
| PKM Markdown / read-later | Existing journaling, conflict protection and disconnect code inspected. Empty credential save deletes the keychain entry; no bug claimed there. No authenticated live provider or folder-provider integration exercised. |

## Verification infrastructure findings

1. `scripts/run-sessionkit-tests.sh` assumed one `SessionKitPackageTests.xctest` bundle. This installed toolchain emits separate `SessionKitTests` and `SessionKitTraceTests` products. First broad run failed before executing package tests. Replaced hard-coded launch with `swift test`; outer runner still checks every expected test ID and allowed skips.
2. Full package run then exposed a stale sharing assertion: no acoustic evidence expected `absentFromRecipientEdition` although Sep 14's documented policy intentionally returns `unresolved`. Updated the assertion and retained `localMediaTimeMs == nil`, preserving the prohibition on timestamp fallback.
3. The broad app run found three additional failures at the delayed-Library boundary (Margin retrieval and two Follow races). These exposed a runtime dependency, not just test timing. Repaired data ownership rather than adding waits. Interrupted that already-failing run before remaining long UI cases; it is explicitly incomplete. A new stable-input release run follows.
4. First preparation-test attempt stalled before XCTest began; sampled host main thread was idle. Interrupted, rebooted simulator, retried. The first executed attempt found a test-fixture database lock from resetting an already-open store; corrected fixture initialization. The subsequent counterexample failed on the intended offline-state assertion. Logs retain all three distinctions.

## Simulator observations

On iOS 18.6 small-phone simulator `09B39C91-F60E-497E-9F7C-AAD8740FBAC3`, launched the synthetic `--ui-testing` app. Source playback advanced through 3%, 13%, and 36%; opened Timeline, paused, then opened Export. Export showed the selected session at 36% with one Margin, matching Timeline. Screenshots: `ios18-timeline.png`, `ios18-export.png`. This was an intermediate audit build, before the final preparation and speech repairs; final automated evidence is recorded separately. No share/export was sent externally. No acoustic intelligibility, physical route, battery, jetsam or frame-rate claim.

## Omission checks and stopping rule

The original failure lacks a contemporaneous detailed playback trace and exact installed SHA. The supplied developer trace predates the export; do not use it to reconstruct the skip. Dynamic ad editions, OS network/background suspension and actual Lock Screen callbacks remain alternatives. Current endpoint reachability cannot falsify a past outage. No regression is attributed merely because its commit is recent.

Audit stops after focused negative cases, complete applicable automated verification (or an explicitly recorded environmental blocker), and an actionable risk register. Broad non-actionable re-runs and speculative fixes are excluded. Remaining download/edition work requires controlled lifecycle tests before implementation. Only the owner can mark flows human_validated. This is an engineering audit, not a release authorization or request to accept the product.

See `verification.md` for final counts/status and `../../validation/gate-1/reliability-sweep-2026-09-15/review.md` for the earlier reliability repairs.

## Recommended repair order

1. **Download lifecycle ownership:** preserve a durable task/generation/reservation association, then test restart, deletion during HEAD, replacement download and every terminal failure. This is the strongest remaining mechanism for apparently downloaded content disappearing or never becoming usable.
2. **Rendition identity:** require recipient-byte identity for retaining shared-note positions and for treating stream/download clocks as interchangeable. The active-skip repair narrows one transition; an explicit later resume can still adopt a different dynamic-ad rendition. Neither URL equality nor equal duration proves equal timeline.
3. **Measured main-thread work:** count note loads and profile the owner's large shared-Margin session during playback/navigation, then remove redundant duration repairs with explicit invalidation. Preserve correct final rendering state with the added regression.
4. **Physical-only failure cases:** capture the new bounded automatic event history for actual Lock Screen/AirPod controls and collect a memory trace for podcast → native text. Do not infer those outcomes from simulator controls or a seeded small Library.

These priorities follow destructive/lost-position risk first, then recurring performance cost, then device-only evidence gaps. They are not a claim that every open issue is a current defect or that all were reproduced.

## Why these escaped earlier checks

The September 14 commit combined performance, PDF, preparation and sharing changes. Incremental progress coverage checked an intermediate chunk but not the post-finalization snapshot. Existing Follow and Margin retrieval tests already expressed useful invariants, but failed when finally run against asynchronous Home refresh. The package runner also stopped before package execution on this toolchain, and a sharing assertion drifted from an intentionally changed policy. These are specific verification gaps, not proof that all recent repairs are suspect. Preserve before/after tests at lifecycle boundaries and run the existing inventory-aware fast/app gates after cross-cutting changes; use device evidence for the physical-only cases.

## Broad simulator sweep: unresolved UI results

The completed iPhone 17 Pro / iOS 26.5 release run executed all 483 expected Xcode cases: **476 passed, 7 failed**. One failure was the new preparation fixture; six were UI checks below. Do not describe this candidate as release-verified. The runtime is the same as the subsequent app retry; only preparation-test fixture ownership changed afterwards.

| UI check | Observed evidence | Classification / next discriminator |
|---|---|---|
| Long Timeline response | Import reached playback; captured `playback.play.button` label stayed `Play`, not `Pause`, for the 15-second expectation. Editor/action checks passed. | Reproduced autoplay-state failure in simulator (#95 family); capture adapter status/start acknowledgement around imported response to locate the cause. |
| Long title + maximum accessibility text | Test could not find `playback.interject.button`. Saved screenshot visibly shows Record, play controls and More. | Accessibility lookup mismatch, **not proven clipping**. Inspect live accessibility tree at failure and test source-completion timing before changing layout. Corrects the initial interpretation in progress commentary. |
| Physical scrub drag | First requested 70% drag yielded slider value `100 percent`. | Reproduced simulator gesture/result mismatch; distinguish slider geometry from rendered-audio clock mapping with gesture/seek diagnostics. No claim that this is the owner's Lock Screen bug. |
| Voice Margin save | After finish, label was `Replay in a new session`, expected `Pause`. | Unexpected finished-session state; determine whether short seeded source finished before capture/resume. Not yet attributed to the recent finish repair. |
| Seeded Library flow | `library.row.item-pill` missing after export; captured tree shows Unfinished filter and `Completed items hidden`. | Completion/filter/fixture expectation needs reconciliation; cannot infer data loss. |
| Written Margin detail | Search found a row and detail opened, but expected exact transcript static text was absent. | Detail-content/accessibility failure remains untriaged; distinguish wrong row selection, hidden/collapsed content and accessible text representation. |

Screenshots/debug attachments are under `accessibility-evidence/`, `long-response-evidence/` and `failures/`; full results are in `artifacts/test-runs/project-audit-2026-09-15-complete/tests.xcresult`. All test cases finished before Xcode's post-test `simctl diagnose` dump was interrupted to permit result finalization. Test execution itself was not interrupted in this run.

The app-only rerun after correcting the preparation fixture passed that regression but failed five previously passing cases: local-audio package playback, feed import, and three Supertonic cases. Audio-service errors (including no system audio object) and one SQLite lock accompanied them. A single focused retry after simulator reboot covers these five plus the four repaired app-boundary cases. Its outcome is recorded in `verification.md`; never replace the broad failed gate with an aggregate green claim.

## Authorized handoff-readiness continuation

The owner subsequently authorized repairs down to 50% account usage remaining. Download generation/reservation reconstruction, recipient-edition binding, same-session transport retention and measured percentage-repair overhead are now implemented in the working tree. Six previously failing UI cases pass unchanged in focused iOS 26.5 runs; full current-source verification subsequently passed (491 app/adapter/UI tests, 303 package tests plus one declared skip). See `artifacts/validation/gate-1/handoff-readiness-2026-09-15/handoff.md` for current status and limits. The earlier failed full-gate evidence above remains historical evidence and is not relabeled as a pass.
