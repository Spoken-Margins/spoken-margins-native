# PKM developer verification

Local source: `codex/provisional-next`, base SHA `ac85375759f2533f320225affef9fb3296bbbf9e`, development version 0.1 (27), uncommitted implementation. Not the distributed Build 27. No commit, push, upload or human validation is claimed.

Final implementation input SHA-256: `600f404c021ead16092d23f76400f06cb998d2c410f98a04cb1b0bb7579602df`. The preceding broad-suite input was `af04a39acd232093b58de14dc67b2dd70b24df3ac6c85c5d77c969a719c0afe9`. The only later production change dismisses the JSON editor keyboard when Preview is tapped; its UI test now asserts keyboard dismissal. Audio, interchange, provider and persistence code are unchanged between those inputs.

## Completed evidence

- Fast plan passed: `artifacts/test-runs/20260912-175135-714473-fast/manifest.json`. Package suite, browser suites, runner regression tests, schemas, surface contracts and test inventory passed. The package suite includes the public edition fixture, exact Unicode preservation, scene coverage, identity/revision, real audio-boundary mapping and both provider adapters.
- Clean app gate passed all 420 tests: `artifacts/test-runs/20260912-175215-643295-app/manifest.json`.
- Clean adapter gate passed all 11 tests: `artifacts/test-runs/20260912-173423-998447-adapters/manifest.json`.
- Phone UI plan passed all 12 cases: `artifacts/test-runs/20260912-172125-841845-ui/manifest.json`, iPhone 17 Pro / iOS 26.5. `iphone-edition-preview.png` is the inspected preview screenshot. This is developer evidence, not owner acceptance.
- Speech canary passed after a clean simulator restart: `artifacts/test-runs/20260912-173521-883831-speech-canary/manifest.json` (218.6 seconds test execution).
- iPad UI plan passed all 12 cases: `artifacts/test-runs/20260912-173917-030033-ui/manifest.json`, iOS 26.5. `ipad-edition-preview.png` records the new preview.
- Generic simulator and device app builds passed: `artifacts/test-runs/20260912-180128-pkm-final-builds/manifest.json` and accompanying logs, at the final source input.
- Built App Intents metadata contains `ListeningMapPromptIntent`, `AssembleListeningEditionIntent`, and `ImportListeningEditionIntent`. Actual Shortcuts discovery and model action binding still require the owner’s device.

The final focused preview tests passed on both devices, with an explicit keyboard-dismissal assertion: `phone-preview` and `ipad-preview` steps in `artifacts/test-runs/20260912-175447-pkm-keyboard/manifest.json`. Both final screenshots were inspected. That combined run retains an overall failure because its later generic simulator build failed while signing the cached ONNX framework. Moving only the generated embedded copy aside and rebuilding serially (`-jobs 1`) passed both generic destinations in the final build run above. No signing implementation or app code was changed for that retry.

The already-passing broad phone/iPad suites and audio/speech suites were retained for the unchanged paths; only the affected preview seam, fast checks, complete app tests and generic builds were repeated after the focus adjustment.

## Retained failures and diagnosis

Initial package compile optional-value errors and a mistaken Unicode test expectation were corrected before the final fast pass. The first app build used stale generated top-level SessionKit module products, which were moved out of the generated build search path; no source or user data was removed.

App run `20260912-165900-953742-app` hung before the test runner connected. Restarting only the test simulator allowed a complete app pass (`20260912-170826-369576-app`). After the final foreground-notification adjustment, `20260912-171159-401262-app` executed 420 passing tests, but a URLSession error interleaved one console completion line. The strict runner retained a missing-test failure. `app-result-reconciliation.json` records the independent xcresult evidence; the original failure was not overwritten. A further clean app gate is recorded below.

The first adapter attempt (`20260912-171358-725866-adapters`) timed out without executing a test. The subsequent speech-canary startup (`20260912-171905-236384-speech-canary`) was interrupted by the simulator restart and is incomplete. Neither is a pass. Remaining retries restart the test simulator between plans, without resetting its data.

## Limits

Runtime UI evidence covers iOS 26.5; the iOS 18 deployment target was compiled, not separately exercised on an iOS 18 simulator in this task. No live Reader/Raindrop accounts or chosen model subscriptions were exercised. Physical notification delivery, security-scoped vault access and background scheduling remain owner checks. Native background map generation is not promised. See `owner-checklist.md` and `docs/pkm-workflows.md` for exact setup, reset instructions, sample data and pending flows.
