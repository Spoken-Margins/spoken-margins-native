# Reliability candidate — September 15, 2026

Status: **engineering candidate verified and ready for owner validation**. Full gate passed: 491 app/adapter/UI tests, 303 package tests plus one declared corpus skip, 12 browser tests, 10 runner tests, and all contract/inventory checks. Product flows remain pending owner acceptance. No commit, physical-device installation, or distribution performed.

The candidate patch and per-file hashes are in `candidate.patch` and `candidate-identity.json`. The local device build and binary hashes are in `device-build-identity.json`. No additional broad testing is required for unchanged inputs.

## Candidate and scope

- Lane: `codex/provisional-next`.
- Base commit: `6432044bdc5ebff4691a69bee2699c309222ebac`, plus the preserved working-tree changes. This SHA alone does not identify the candidate.
- App version/build: 0.1 (27). The reused build number is not a new TestFlight release or unique source identifier.
- Exact source-input hash and test inventory: `artifacts/test-runs/handoff-readiness-2026-09-15-final/manifest.json` (verified). Input SHA-256: `cd1c246eb016b34e0794fc336d5b137a32d42ae57e9ac6768390b7d1553121f7`.
- Supported app targets: iPhone and iPad, iOS 18+. Automated verification uses iOS 26.5; earlier iOS 18.6 simulator audio output failed, as recorded below.
- In scope: podcast startup and same-player skips; download cancellation/reconstruction/adoption; recipient shared-Margin edition binding; speech whitespace and stale callbacks; offline preparation presentation; Margin retrieval and Follow eligibility; bounded automatic diagnostics; recurring media-progress work.
- Out of scope: distribution, Git-history publication repair, account-backed provider validation, Watch interaction redesign, and claims about physical-device background execution, memory/thermal behavior or audible quality.

## Repairs and evidence

| Boundary | Result | Evidence |
|---|---|---|
| Background download ownership | URLSession task metadata carries item, generation and reservation. Relaunch can recover ownership; late/deleted attempts cannot publish over a replacement. HEAD preparation is cancellable; leaving Wi-Fi invalidates automatic preparation. | `PodcastDownloadCoordinatorTests`, including controlled suspended HEAD, reconstructed reservation, old completion versus replacement, and HTTP/oversize cleanup cases. |
| Durable adoption | Unique staging/destination files prevent overwrite by late callbacks. Availability follows ledger, audio-asset and download-record persistence. Successful URLSession completion does not release a reservation before asynchronous adoption finishes. | Lifecycle tests; `lifecycle-edition-tests.log` (23 tests at the earlier checkpoint); final gate covers current inputs. |
| Same-session podcast transport | A background download no longer changes transport on an ordinary skip, pause/resume or interjection. Explicit Download Again requests transport replacement, including from a paused session; routine source preparation does not. A new session can select the local file. | Core transport tests assert offsets and asset identity, including the explicit replacement path. This does not prove byte identity across a new remote request or process restart. |
| Recipient audio edition | Persist the recipient file digest on imported podcast layers. Changed/unknown editions invalidate old note times and map projections before rematching. Retain stronger old evidence only for the same known edition. Late transient transcripts from a replaced URL are rejected. | Durable invalidation/reopen and same-versus-different/unknown-edition policy tests; portable package schema unchanged. |
| Speech callbacks | Retired or unrelated synthesizer callbacks cannot confirm, cancel or advance the current request. Reapplying an unchanged speech rate avoids a needless restart. | Retired-synthesizer regression test. Separate whitespace repair was already demonstrated failing-before in the original audit. |
| Progress cost | Stable duration/session updates skip the redundant percentage-repair scan. Note writes, duration changes and explicit session inspection trigger repair. | 0/100/1000-note regression: 20 progress ticks use 20 note loads instead of 40. The counterexample restores the old scan and fails six count assertions. This measures repository work, not device frame rate or memory. |
| Independent database writers | SQLite now waits up to one second for a brief writer transaction instead of immediately losing a save. Contention beyond that still fails explicitly. | A deterministic raw SQLite write-lock test failed before the fix (save missing), then all 9 storage safety tests passed. |
| Earlier audit repairs | Final preparation state, durable Margin membership and selected-item Follow eligibility remain covered. Automatic transport history is bounded to 300 events and excludes high-frequency samples. | Original audit artifacts plus current full gate. |

Some SQLite-backed test fixtures previously removed their files while asynchronous model/URLSession work still held open connections. Those test fixtures now remain in the simulator temporary directory until process cleanup; they no longer deliberately unlink active WAL files. Production storage behavior is unchanged by this test adjustment.

## UI failure triage

All six failures from the earlier audit passed unchanged in focused iOS 26.5 runs:

- Long-response import/autoplay and written-Margin save/search/detail: `ui-isolation.log`, 2 passed.
- Maximum Dynamic Type controls, physical scrub drag, exclusive voice capture/save/cancel, and seeded Library/export/settings: `ui-remaining.log`, 4 passed.

The iOS 18.6 manual long-response reproduction reported Core Audio `Prime: failed (-66680)` and advanced 1,375 characters to completion in roughly a second. See `simulator-audio-failure.log` and `long-response-events.json`. This is concrete environment evidence, not proof that every earlier UI failure had the same cause. No UI assertions were weakened. The final full gate passed on the exact candidate, including all six formerly failing UI routes.

## Verification execution notes

- Fast gate: 303 package tests passed, one declared corpus skip; 10 runner tests and 12 browser tests passed; contracts, surface inventory and test inventory passed.
- Generic iOS device build: passed (`device-build-final.log`); no installation performed.
- The repository's generic Watch command could not run because `SpokenMarginsWatch` is absent from the active project. Watch runtime is explicitly excluded by this release lane; no Watch target was added or enabled. See `watch-build.log`.
- Initial full-gate attempt stopped before any XCTest case connected. A process sample showed an idle app main run loop; audio-service errors were present. It is recorded as incomplete (0/490), not passed. A simulator reboot restored execution. The retry exposed a real independent-writer SQLite failure and a fixed-sleep Supertonic test; it was stopped to repair those findings, not relabeled as green. The final gate passed on new stable inputs.
- The Supertonic render-gap test previously attempted to finish chunk two before it started; that finish could be a no-op. It now waits for each player start and explicitly blocks/releases render three. It requires no active file during the held render, the intermediate waiting state, forward source progress and zero fallback calls. A longer fixed wait alone did not fix the test. The runtime was not changed for this failure.
- Focused four-case UI execution completed successfully before its post-test diagnostic collection stalled. Only the `simctl diagnose` child was interrupted; Xcode finalized with `TEST SUCCEEDED`. Test execution was not interrupted.

- A follow-up phone launch and an iPad launch also stalled before XCTest connected; both are incomplete, with no pass inferred. The successful final gate used a new iPhone simulator (`D0C61450-3252-4DCE-B840-8C5AD56C3D1B`) to isolate retained simulator state.

## Known limits and remaining owner checks

- The reported Pod Save America failure/backward Lock Screen skip has not been reproduced or attributed conclusively. The original incident lacks a matching trace and exact installed source identity.
- Publishers that reject HEAD, omit its length, or return a larger GET rendition may still fail offline download safely. Streaming remains a separate path. The implementation does not yet reserve/grow storage for unknown-size transfers.
- Keeping a session on its chosen transport prevents automatic local substitution; it cannot guarantee that a server returns the same ad rendition after a fresh remote request, nor establish durable audio identity for legacy sessions across process restart.
- Legacy imported shared-Margin positions may become temporarily unresolved because their old recipient edition was never recorded. Note text and assets remain preserved; matching must establish new evidence.
- Physical Lock Screen/headphone commands, real network loss, jetsam/thermal behavior, background download process relaunch and audible speech quality still require owner/device evidence. Simulator and deterministic tests do not establish `human_validated` status.
- Git publication remains separately blocked by oversized historical videos; no history rewrite was authorized here.

## Reset, samples and diagnostics

Use synthetic simulator data for destructive resets. Launch with `--ui-testing` to reset/seed the fixture Library, including **You Can't Inspect the Pill** and the guided tour. Text-route tests seed **A walk with room to think** or a long synthetic paragraph source. Do not run this reset against the owner's real Library.

Automatic playback history is stored at the app container's `Library/Caches/DeveloperDiagnostics/playback-events.json`. Detailed opt-in recording remains `Library/Caches/DeveloperDiagnostics/latest.json`; Settings → Developer tools exposes the diagnostic controls/export. Automatic events contain state and hashed identities, not source prose. Preserve/export history promptly after a failure because it is bounded.

For the real podcast incident, use the Apple Podcasts item supplied in the task: Pod Save America, **Artificial Intelligence, Actual Idiots**. Keep the existing Library/session; do not delete/reimport as a diagnostic reset. Capture the installation identity and diagnostics along with approximate time, command surface and before/after position.

## Owner validation checklist (pending; no acceptance inferred)

| Flow | Pass/fail notes |
|---|---|
| Start the reported episode from Following and reach normal playback | Pending |
| Lock Screen +60 and −15 before and after download completion | Pending; record before/after positions |
| Pause, resume and save/cancel a Margin after download completion | Pending; retain source position |
| Relaunch during a real background download; confirm offline availability | Pending |
| Shared Margins remain attached after same-edition reopen; changed editions rematch without old timestamps | Pending |
| Long-response autoplay; written Margin save/search/star/play moment | Pending |
| Dynamic Type controls and dragging the playback scrubber | Pending |
| Export diagnostic history after any unexpected jump or failed start | Pending |

Record owner observations under this gate directory before marking any flow `human_validated`.
