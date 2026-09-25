# Recipient transcript window handoff — September 23, 2026

Status: implemented and host verified; app runtime and product validation remain pending. This is a bounded #27 engineering slice on `codex/co-op`, not a release handoff. No simulator was booted, no commit or merge was made, and no physical device, distribution, or server work was performed.

## Changed files

- `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift`: replaces recipient full-source ASR with one in-flight per-item job of local, widened, and chunked episode windows. Uses actual local-file duration, exact SHA-256 before and after each ASR call, digest/version/interval-bearing cache IDs, and transient cache cleanup. A local hit cannot be passed to fusion until episode coverage is complete. Keeps a transcript job alive when a new layer starts an acoustic resolution. Rechecks digest after persistence off the MainActor and invalidates stale positions. Speech-service failures suspend further automatic attempts for that item until a new ready event.
- `Packages/SessionKit/Sources/SessionKitAudio/PodcastAnchorEvidence.swift`: bounded sweep planning (at most 36 episode chunks of 210 seconds, stepped by 190 seconds), coverage test, overlap deduplication, and an incomplete-coverage resolver guard.
- `Packages/SessionKit/Tests/SessionKitTests/SharingTests.swift`: distant repeat, overlapping duplicate, incomplete sweep, and budget exhaustion cases.
- `App/SpokenMarginsAppTests/SpokenMarginsPackageHandoffTests.swift`: controllable window client rejects full-source ASR; digest replacement before window completion cannot verify placement. This test source compiled but was not executed.

## Evidence

- `fast` passed: `artifacts/test-runs/20260923-163242-895971-fast/manifest.json`; runner/contracts/surfaces/inventory/browser/package all passed. Log: `recipient-window-fast.log`. The package plan reported 331 passed, one expected corpus skip, zero failures (313 of those were XCTest cases).
- Generic `SpokenMarginsApp` `build-for-testing` passed and compiled the app test target without booting a simulator. Log: `recipient-window-app-test-build.log`.
- `git diff --check` passed after the code freeze.

## Remaining limits

- The sweep is memory-only within one job, not durable/resumable across process restart. Episodes longer than the chunk budget remain transcript-unresolved; existing acoustic positions and direct voice playback remain available.
- The speech adapter has no explicit second recognizer route exposed at this boundary. A recognizer/service failure aborts the sweep; a bounded fallback and service-specific diagnostics remain future work.
- Other item jobs can run concurrently; a global speech-service queue and fair cross-item scheduling are not included in this slice.
- The app test assertions have not run because the XCTest runner connection stall remains unresolved. No app-plan, adapters, speech-canary, UI, held-out benchmark, physical-device resource, or owner-validation gate is claimed.
