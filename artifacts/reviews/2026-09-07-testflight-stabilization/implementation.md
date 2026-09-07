# TestFlight stabilization — 2026-09-07

Implemented on `codex/provisional-next`. Final automated release verification passed. Nothing has been uploaded, committed, or human validated by this task, and no GitHub issue was closed or changed.

## Candidate identity

- HEAD: `90d08c19ddf957c70b8a34077f73a58f92771544`, with uncommitted changes.
- Final input SHA-256: `827ebc43e6cc0a8674c12be6ae2ca8b4bb3e251a54c8e12baa894ecbbc79b554`. The verification hash includes the pre-existing audio-policy and comprehensive-test-infrastructure work that this task preserved.
- Configured version: **0.1 (25)**, iPhone/iPad, iOS/iPadOS 18+. Automated runs use iOS/iPadOS 26.5; the connected physical phone reports iOS 26.6.1.
- The physical phone has a developer-installed **0.1 (25)**, with no established source SHA. That is not proof it contains this candidate or that Build 26 was never uploaded. Reconcile App Store Connect and assign an exact committed candidate before upload. Watch scope remains archived.

## Changes and issue boundaries

| Issues | Implemented change | Remaining evidence |
|---|---|---|
| [#98](https://github.com/uncomposed/spoken-margins-native/issues/98), [#102](https://github.com/uncomposed/spoken-margins-native/issues/102) | Durable item-level source completion; Mark Complete preserves historical sessions. Live speech owns rendering, starts with one available chunk, and awaits manifest/commit ordering. Completed artifacts survive eligibility changes. Live/AI speech creates no speculative source jobs; stale orphan jobs cannot block the queue. Cancellation is checked between inference stages. | Device acceptance of bounded fallback and playback/preparation behavior. The initial 15-second generation bound is not a measured device-latency claim. |
| [#103](https://github.com/uncomposed/spoken-margins-native/issues/103), [#104](https://github.com/uncomposed/spoken-margins-native/issues/104), [#95](https://github.com/uncomposed/spoken-margins-native/issues/95) | Assistant/summary scrub and seek preserve source completion and pause. Retry acts on the current target and offset. UI text length matches engine fallbacks. Existing long-response and interjection regressions remain covered. | Product-owner interaction checks; no claim that historical missing notes were recovered. |
| [#99](https://github.com/uncomposed/spoken-margins-native/issues/99), [#101](https://github.com/uncomposed/spoken-margins-native/issues/101), [#91](https://github.com/uncomposed/spoken-margins-native/issues/91) | Late follow discovery cannot cross item/source identity. Item-derived feed suggestions require membership evidence. Feed import preserves known title, source, author and episode reference without replacing active playback. Distinct candidates expose their URLs. | Representative article/browser flow and owner acceptance. |
| [#93](https://github.com/uncomposed/spoken-margins-native/issues/93), [#97](https://github.com/uncomposed/spoken-margins-native/issues/97) | Quick Add derivation is cached until its inputs change; unrelated view updates no longer repeat its sort/deduplication. | Paired traces and accepted responsiveness on the original content-heavy physical phone. |

First-run test setup now explicitly selects the intended voice after migration. The iPad geometry check verifies adaptive navigation controls, retaining the phone bottom-tab clearance assertion. Diagnostics export feedback/payload are tested at the app layer, while the UI requires its local **Copied** confirmation instead of racing a three-second global banner. These test fixes preserve normal consent behavior and product feedback timing.

## Verification

| Check | Result / evidence |
|---|---|
| Final full release gate | **Verified: 414 app/adapter/UI tests passed, zero failed/skipped**, including the exact speech canary. Fast checks passed: 262 package tests plus one named permitted benchmark skip, browser suites and contract/surface/inventory validators. Evidence: `artifacts/test-runs/20260907-125017-904309-release/manifest.json`. |
| iPad focused UI | **Passed all 5 tests**: `artifacts/test-runs/20260907-124523-268051-ui/manifest.json` |
| Generic iOS device build | **Passed**: `device-build-final.log`; later changes are test-only. |
| Earlier complete isolated release run | 412/413 app/adapter/UI tests passed; the only failure was the diagnosed transient-banner assertion. Retained in `artifacts/test-runs/20260907-120649-055063-release/manifest.json`. It is not a release pass. |

See [verification-history.md](verification-history.md) for retained failures, startup samples, simulator interference evidence, test-assertion corrections and the 15-repeat podcast diagnostic run. Interrupted, missing or unexpectedly skipped tests never count as passed. The package suite explicitly permits only its named held-out benchmark skip.

## Remaining release decisions and risks

- The physical phone became available and its installed build was inspected. The owner was asked to prepare the existing library for a coordinated Quick Add/scrolling trace; that workload is still pending. Do not replace it with a clean simulator or reset the existing library.
- An imported-podcast test twice reported `persistence_failed:step_save`, then passed subsequent full app runs and 15 consecutive targeted iterations. SQLite write errors now include extended codes/messages. The earlier failure remains undiagnosed; passing reruns do not establish a fix.
- [#84](https://github.com/uncomposed/spoken-margins-native/issues/84) still needs the combined sticky-drag/post-seek-progress owner check. [#14](https://github.com/uncomposed/spoken-margins-native/issues/14) remains the external sharing/distribution gate.
- Safari PDF developer proof exists at `artifacts/validation/provisional-next/2026-09-04-safari-pdf-manual-proof.md`; it is not owner acceptance of this candidate.
- Figure narration (#105) and broad UI proposals (#100/#106/#107/#108/#109) remain deferred.

The [product-owner checklist](product-owner-checklist.md) contains device scope, sample items, safe reset guidance, diagnostics export and pass/fail fields. Every human-acceptance row remains pending.

## Audit / stopping criteria

Reject release readiness if playback can wait indefinitely, completed sources trigger speculative synthesis, compatible audio is invalidated by completion state, assistant progress changes source completion, Retry only affects a future start, follow evidence crosses item identity, known feed titles become generic, or required verification is incomplete. Preserve first-failure evidence and compare source facts, rendering work, navigation targets and validation evidence separately. Release readiness also requires the repository's owner acceptance and content-heavy device evidence.

The final release and iPad manifests both report `verified` against the same input hash. `git diff --check` passed. All earlier failures remain retained and are not counted as successful verification.
