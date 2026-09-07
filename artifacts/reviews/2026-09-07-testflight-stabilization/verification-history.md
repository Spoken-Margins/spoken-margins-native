# TestFlight stabilization — 2026-09-07

Implementation is on `codex/provisional-next`, based on `90d08c19ddf957c70b8a34077f73a58f92771544`. The workspace also contains pre-existing audio-policy and comprehensive-test-infrastructure work. Nothing has been uploaded, promoted, or human validated by this task. GitHub issues remain open.

## Candidate identity

The project still declares version 0.1 (25). The release plan records internal Build 25 and external Build 19; September 5 issues refer to Build 26-era testing without an upload record found in this review. Do not treat this working tree as distributed Build 25, infer a Build 26 upload, or allocate another upload number until App Store Connect identity is reconciled. Verification manifests identify both HEAD and the complete input hash, including uncommitted changes.

## Implementation and evidence boundaries

- #98/#102: source completion has a durable optional item-level `sourceCompletedAt` timestamp. Existing payloads decode without that field. Mark Complete preserves historical session percentages and assistant-turn state. Library filters consume item completion. Automatic queue removal preserves committed manifests; explicit rendering remains allowed. Live playback waits for manifest creation and each durable chunk commit before advancing synthesis; it creates no speculative preparation job. AI/summary and overview-prefixed speech cannot look up source-only artifacts. Orphaned queue entries are removed without deleting representations. Cancellation is checked between inference stages. Live playback begins with one ready chunk while the import preparation target remains two. Slow chunk generation has a 15-second fallback bound; this is a conservative initial limit requiring device assessment, not a measured device latency claim.
- #103/#104: canonical text seeking supports assistant and summary turns without changing source completion; paused transport preserves pause. Retry targets the current response and source offset immediately. Generated-speech navigation already prioritizes the requested chunk forward; existing and expanded tests preserve that behavior.
- #99/#101/#91: source suggestions carry their originating item and reject late results for another item/source. Item-derived website suggestions require feed membership evidence. Direct manual feed discovery remains supported. Distinct candidate feeds expose their URLs for selection. Feed import carries title, source, author and episode reference through the exact import call, without overwriting active playback. Existing article extraction uses an isolated WebKit content world and typed fallback; a real representative article-flow/device acceptance remains outstanding.
- #95: existing long-response import, playback and interjection retrieval regressions are retained in the app verification suite. No claim that apparently missing historical user notes were recovered.
- #93/#97: Quick Add derivation is cached until its inputs change. This removes repeated sorting/deduplication on unrelated view updates. There is no physical-device before/after trace yet, so this is an implementation improvement, not closure of the responsiveness reports.

## Required remaining evidence

The product owner's content-heavy physical iPhone was offline when checked. #93/#97 still require paired idle/loaded-workload traces on that device and an accepted responsiveness comparison. Include native text with many stale items, repeated Quick Add, scrolling and navigation while preparation is active. Do not substitute a clean simulator library.

Safari PDF proof exists at `artifacts/validation/provisional-next/2026-09-04-safari-pdf-manual-proof.md`, with Library-arrival and opened-item screenshots. It records the exact Safari Share route and developer verification, not product-owner validation. Repeat on the final candidate when that path changes. #84 still needs the combined sticky-drag/post-seek-advance product-owner check.

#14 remains the external sharing/distribution gate. Figure narration and broad UI redesigns were deferred by the approved review scope.

## Audit criteria

Reject the candidate if: playback waits indefinitely for a chunk; old completed sources trigger speculative synthesis; compatible completed audio is invalidated by completion state; assistant progress changes source completion; Retry only changes future preferences; a stale follow result crosses item identity; imported feed titles fall back to `audio` despite known metadata; or tests are missing, skipped unexpectedly, interrupted, or run against changed inputs.

Retain every failed-run manifest. An earlier app run reported a transient `persistence_failed:step_save` in the imported-podcast transcription fallback test; the subsequent full app run passed that test. The same error recurred once. A later full app run (`20260907-114039-257155-app`) and 15 consecutive focused podcast-test iterations passed. Write errors now include SQLite extended error codes and messages. The prior failure remains undiagnosed; passing reruns do not establish a fix.

## Verification record

- Final-input shared-simulator attempt: `artifacts/test-runs/20260907-114442-939413-release/manifest.json`, interrupted/incomplete. All 389 app/adapter tests and the 212-second speech canary passed, but UI logs show `org.monhegan.fieldcamera.r0` interrupting the app and three hit-target/layout failures. Those failures are inconclusive until isolated reproduction; they are not waived. A dedicated release simulator (`4AAAFEBA-6DA8-4166-8347-4106165C38C2`) was created for a clean rerun.
- Earlier release attempt `20260907-112647-039652-release` was deliberately interrupted to fix preparation identity/order; partial speech/UI evidence is not a gate pass.
- Release attempt `20260907-114329-424162-release` failed compilation on a property-name error; corrected before the final-input run.
- App `20260907-114039-257155-app`: all 379 app tests passed before the final focused additions.
- `podcast-repeat.xcresult` / `podcast-repeat.log`: 15 consecutive targeted iterations passed; diagnostic run, not a substitute for the full gate.
- Product-owner checklist: `product-owner-checklist.md`. Every acceptance row remains pending.

### Fresh-simulator follow-up

The first dedicated-simulator run (`20260907-115245-522899-release`) exposed two pre-existing test assumptions and was stopped before completing UI routes. Batch export attempted to unwrap a session before handling first-run Supertonic consent. The test now explicitly selects the system-voice path and restores its speech preferences. A 21-page PDF import exceeded the test helper's one-second limit during cold setup; that specific operation now has a five-second deadline, preserving every chapter assertion. An intermediate test build (`20260907-120103-704968-release`) caught a private-key access in the setup change; the test uses the existing persisted key literal instead.

The generic iOS device build passed (`device-build.log`) before these test-only changes. No runtime source changed afterward. Device signing/build success is not an archive/upload or physical-device flow check.

### Complete isolated run before diagnostics test correction

The restarted dedicated-simulator release run is `artifacts/test-runs/20260907-120649-055063-release/manifest.json`, input SHA-256 `acee0cc47b4376f998f4763dd97f7bd13cbd1b81a0540f7ececf0048409ffc95`. Its 389 app/adapter tests passed, including both cold-setup test corrections. The preceding `20260907-120134-371401-release` recorded no completed Xcode tests: testmanagerd was waiting to pair with the test bundle while the app ran without XCTest loaded. Restarting only the dedicated simulator cleared that startup condition. The startup samples and testmanager log are retained in this directory. Neither interrupted run counts as a release pass.

## Issue disposition for handoff

| Issues | Current boundary |
|---|---|
| [#98](https://github.com/uncomposed/spoken-margins-native/issues/98), [#102](https://github.com/uncomposed/spoken-margins-native/issues/102) | Playback/preparation ownership and durable source-completion fixes implemented; final candidate/device acceptance pending. |
| [#103](https://github.com/uncomposed/spoken-margins-native/issues/103), [#104](https://github.com/uncomposed/spoken-margins-native/issues/104), [#95](https://github.com/uncomposed/spoken-margins-native/issues/95) | Assistant navigation and Retry fixes implemented, long-response regression coverage retained; historical-note recovery is not established. |
| [#99](https://github.com/uncomposed/spoken-margins-native/issues/99), [#101](https://github.com/uncomposed/spoken-margins-native/issues/101), [#91](https://github.com/uncomposed/spoken-margins-native/issues/91) | Item-scoped follow evidence and feed metadata fixes implemented; representative real article/browser acceptance remains pending. |
| [#93](https://github.com/uncomposed/spoken-margins-native/issues/93), [#97](https://github.com/uncomposed/spoken-margins-native/issues/97) | Quick Add derivation cached; content-heavy physical-device profiling remains required. |
| [#84](https://github.com/uncomposed/spoken-margins-native/issues/84), [#14](https://github.com/uncomposed/spoken-margins-native/issues/14) | Combined playback-control owner check and external sharing gate remain open. |

No issue was closed or updated on GitHub by this task. Deferred figure narration (#105) and broad UI proposals (#100/#106/#107/#108/#109) were not implemented.

### Diagnostics assertion correction

The complete `20260907-120649-055063-release` run executed all 413 app/adapter/UI tests: 412 passed and only `testDiagnosticsCopyShowsLocalConfirmation` failed. Its local **Copied** assertion passed. The subsequent global-banner query began more than four seconds after tapping, but `UserFeedbackBanner` dismisses successful feedback after three seconds. The UI test continues to require local confirmation. The new app test `testDiagnosticsCopyPublishesSafePayloadAndSuccessFeedback` independently asserts the exact success event, valid exported JSON schema, retained nonprivate diagnostics and exclusion of source content, without racing view dismissal. Product timing and runtime code were not changed to accommodate the test.

### iPad coverage and later device observation

The fresh iPad initially failed four playback-start routes because the pre-1.0 voice migration ran after the UI-test system-voice override, leaving `supertonicVoicePendingTermsV1=supertonic:M2` with no accepted terms. The test-only override now runs after migration and clears the pending choice when explicitly selecting system speech. Normal first-run consent behavior is unchanged. The next iPad run passed four routes and exposed a phone-only geometry assertion (`app.tabBars`): debugger inspection confirmed top/adaptive tab identifiers `navigation.tab.library`, `navigation.tab.sources`, and `navigation.tab.margins`. The assertion now preserves the phone bottom-clearance check and verifies each adaptive control is hittable and does not intersect the mini-player.

The scrubber's summary/raw-text fallback now follows the engine: an empty optional summary does not hide usable raw text, and raw-text offsets retain the engine's untrimmed length. `device-build-final.log` passed after these runtime corrections; later adaptive-navigation changes are test-only.

At 12:40 EDT, the physical iPhone became available. `physical-installed-app.json` records a developer-installed version 0.1 (25), not a verified uploaded artifact or a known source SHA. Spoken Margins was running. A coordinated existing-library workload was requested for profiling and is awaiting an owner reply. This supersedes the earlier offline observation; it does not supply paired performance evidence or prove that Build 26 was never uploaded.
