# Recipient window correction handoff — September 23, 2026

Status: audit P1/P2 corrections implemented and host verified on `codex/co-op`; app runtime and product validation remain pending. No simulator boot, commit, merge, distribution, device installation, or server work.

## Corrections

- `AudioAdapters.swift` now loads the exported audio track's playable time range and container duration. `SourceAudioWindowTranscription` and acquired windows return measured source bounds. Exports missing more than 250 ms at either edge fail; smaller measured deficits stay short in the returned evidence, so recipient coverage still cannot promote them. The 250 ms quality bound accommodates export timescale and AAC frame rounding without declaring missing time covered.
- `Gate1AppModel.swift` now has a distinct recipient in-flight set. It deletes only the window cache IDs created by that recipient job; it no longer purges episode-map transient files or ledger entries. A ready event during a sweep queues the URL; after the old job finishes, it hashes the current file off the MainActor and starts a new job immediately only when the edition digest changed. A replacement arriving after completion also bypasses the old edition's throttle.
- `PodcastAnchorEvidence.swift` coalesces nearby Margin hints to at most four local/widened centers and caps a job at 44 total requests, including the 36-chunk episode sweep. All Margins still use the completed episode timeline for uniqueness.
- `SharingTests.swift` checks short-export measured bounds, a small deficit that remains incomplete, a late playable start, and request coalescing. `SpokenMarginsPackageHandoffTests.swift` compiles a paused-window replacement-ready scenario that requires a new edition-bound sweep.

## Verification

- `fast` passed: `artifacts/test-runs/20260923-164227-134533-fast/manifest.json`, 333 package tests passed, one expected corpus skip, zero failures. Log: `recipient-window-correction-fast.log`.
- Generic `SpokenMarginsApp` `build-for-testing` passed, compiling the app test target without running it. Log: `recipient-window-correction-app-test-build.log`.
- `git diff --check` passed.
- Prior handoff's count was corrected to the prior manifest's 331 passed and one expected skip; its 313 number was only the XCTest subset.

## Remaining limits

The app test and actual AV export behavior have not run because the simulator XCTest runner connection stall remains unresolved. The pure host boundary test injects measured playable bounds; the generic build verifies the AVFoundation measurement path compiles. The sweep is not durable across restart, and a second speech-recognizer fallback and cross-item speech queue remain outstanding. No held-out zero-false-confident-placement or p95 gate is claimed.

## Final uniqueness audit correction

`PodcastAnchorEvidence.swift` now treats nearby repeated transcript passages as distinct whenever their token spans do not overlap. Both-sided matching scans every similarly scoring pair and distinguishes either separate prefix or separate suffix occurrence; one-sided matching also scans every similarly scoring disjoint range. Fuzzy clustering no longer merges disjoint ranges by midpoint distance. The existing merged-timeline deduplication still removes the same audio transcribed by overlapping sweep chunks.

`SharingTests.swift` adds a complete-sweep regression with two exact prefix/suffix pairs five seconds apart and a nearby repeated one-sided prefix. The full `fast` plan passed again: `artifacts/test-runs/20260923-164722-078402-fast/manifest.json`, 334 package tests passed, one expected skip, zero failures. Log: `recipient-uniqueness-fast.log`. `git diff --check` passed. No app integration changed in this correction, so the prior generic app test build remains the compilation evidence; no simulator test was run.
