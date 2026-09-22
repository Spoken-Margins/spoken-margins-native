# Co-op listening first slice — September 22, 2026

Candidate: `codex/co-op`, base `82e61bcec35e309dd9ad38eb64f824ae5e45766b`
plus uncommitted changes. Configuration version 0.1 (27); the separate Build 28
archive is untouched. No commit, merge, physical-device installation, server access or distribution.
Automated checks install only into the selected test simulators.

Supported baseline: iPhone/iPad, iOS/iPadOS 26+. Verification uses iOS 26.5.
The documented iOS 27 simulator service blocker is not retried by this task.
Only the owner can establish product acceptance.

## Scope

Item-wide source Margins in Timeline, existing Skim controls with source context
and chapter fallback, All/Margins/New selection, direct shared-Margin playback,
and conservative PDF page-margin download-stamp cleanup. Session export ownership
and source text of existing items are preserved. See `docs/co-op-listening.md`.

Deferred: recursive replies, group merges, automatic whole-reel advancement, hosted
transport, object storage, AI context selection, fuzzy PDF identification, Watch.
Text-only contributions display their approved text; no new synthetic voice is
introduced. Text lead-up duration is approximate and sentence-bounded. New-Margin
state is local to this installation, not a participant read receipt.

## Owner exercise (all pending)

| Exercise | Owner pass/fail |
| --- | --- |
| Finish an item, import a friend's Margins, start another session; older local notes remain in Timeline | Pending |
| In Timeline or More listening options select Margins; Skim reaches context, another tap reaches the same Margin | Pending |
| Hear an imported voice and an earlier local recording without reopening the capture session | Pending |
| Change context duration; skip it; return to original position | Pending |
| Two contributions at the same position remain individually reachable | Pending |
| New Margins hides reviewed text/completed recordings; muted layers stay out of Skim | Pending |
| PDF/native text navigation uses the correct passage across narration speeds | Pending |
| Unresolved shared voice is playable directly but cannot seek to an invented source position | Pending |
| Ordinary summary second-tap and chapter navigation remain comfortable on phone/iPad | Pending |

## Safe samples, reset and diagnostics

Use a separate sample item, such as the seeded "You Can't Inspect the Pill" in
UI-testing builds. Write a Margin after Next chapter, start another session, and
select Margins from Timeline. For PDFs, import two copies differing only in an
explicit download-date stamp in the physical page margin. Cleanup applies to new
imports; do not reset or rewrite the owner's existing Library to test it.

Return to original position exits conversation playback. Choose All to restore
normal timeline selection. Settings provides diagnostics; developer playback logs
remain under the app's DeveloperDiagnostics location. Test manifests/logs/results
are under `artifacts/test-runs/`. No acceptance is inferred from their results.

## Verification

Application implementation is complete for the first slice. Owner acceptance is
pending. **System-clean iPad verification is blocked by a SpringBoard crash during
UI-test teardown**, reported by the owner after the runner ended. The affected iPad
is shut down; no recovery/reboot is claimed. See
[specific incident evidence](springboard-incident/incident.md).

| Check | Evidence directory under `artifacts/test-runs/` | Result |
| --- | --- | --- |
| App | `20260922-121517-732387-app` | 463 passed |
| Final fast checks | `20260922-124122-536863-fast` | Passed |
| Audio adapters | `20260922-122149-038495-adapters` | 11 passed |
| Phone UI full run | `20260922-115722-964479-ui` | 15 passed, one fixture/layout expectation failed |
| Corrected phone route | `20260922-121345-561786-ui-focused` | Passed; all 16 routes now have passing evidence across runs |
| iPad UI | `20260922-122224-759672-ui` | 16 passed; **SpringBoard crashed 135 ms after suite completion** |
| Speech canary | `20260922-123602-901302-speech-canary` | Passed real article playback, pause/resume, and completion |
| Device build | `device-build.json`, `device-build.log` | Passed, no physical-device installation |

App/adapter/iPad source fingerprint:
`493a6aaf675400e96495835fc2c3da26d958e8320a21e1824888df548ce56890`.
The later speech-canary change only isolates that test's launch and Library
filters. Each test manifest records its exact input hash; the device manifest
records its build input separately. No application behavior changed afterward.

Retained failures: initial behavior assertions exposed session-only assumptions and
source-target identity differences; those were corrected. The first phone UI run
failed five routes, including keyboard-toolbar overlap with Save. Moving keyboard
Done into the navigation bar restored a clear save target; focused write/share/Co-op
routes passed. Long transcripts now scroll independently of the pinned transport.
An app attempt intermittently failed actual source progress after summary exit
(position remained at 5,000 ms); two later app runs passed. No transport repair is
claimed for that intermittent observation. The first speech canary failed during
fixture lookup before playback; explicit app termination and filter isolation fixed
its setup, and the subsequent real-speech run completed.

Screenshots from phone and iPad automated flows:
- [Phone timeline](screenshots/coop-margin-timeline.png)
- [Phone Margin after second Skim](screenshots/coop-margin-after-second-skim.png)
- [iPad timeline](screenshots/ipad-coop-margin-timeline.png)
- [iPad Margin after second Skim](screenshots/ipad-coop-margin-after-second-skim.png)

These are developer evidence, not owner acceptance. The iPad crash supersedes any
earlier statement that all simulator verification was clean.

## Test-isolation findings

UI-test fixture seeding now runs synchronously before background scene tasks can
open the previous route's database. This is restricted to `--ui-testing`. The
end-to-end navigation test pauses narration and includes completed items before
its Library layout assertion because its forward skip can finish the short source.
The corrected route passed in `20260922-121345-561786-ui-focused`.

The final adapter attempt `20260922-121621-731035-adapters` timed out before running
any tests. The app process was idle in its main run loop; its sample is retained in
`adapter-host-timeout-sample.txt`. Terminating that test-owned app and retrying on
the same simulator succeeded. No simulator restart or runtime switch was used.
