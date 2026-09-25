# Recipient confirmation seek correction — 2026-09-23

Status: **implemented and host verified; app runtime gate remains blocked**. This is a bounded correction of the two findings in `recipient-confirmation-correction-audit.md`; it does not add recipient transcript recovery.

`SessionEngine.playOnPlaybackTransportAndSeek` now activates a replacement transport before issuing the navigation seek. For a paused remote episode, it resumes on the recipient's local file first, so the seek cannot target the old remote player. `Gate1AppModel` uses that ordered command. A single readiness evaluator now keeps the review pending while a matching seek is accepted but playback or the local transport is still starting. It rejects failed/superseded requests and stopped playback; the app poll also stops on request, item, generation change, or its 3-second timeout. Confirmation only arms when the seek, playing state, media position, and local transport are observed together.

Deterministic host regressions cover a paused remote-to-local swap with the active URL recorded **at seek time**, plus pending and accepted-but-not-playing/local-ready states, readiness, failed seek, changed request, and failed playback. The existing app regression source covers paused review, rejected seek, persistence/reopen, edition replacement, and direct voice access, but the final paused assertion remains unexecuted because the simulator runner stalled before suite start.

Checks after the correction:

- `.venv/bin/python scripts/verify-tests.py --plan fast` — **verified**; `recipient-confirmation-final-correction-fast.log`, manifest `artifacts/test-runs/20260923-144240-351300-fast/manifest.json` (330 package tests passed, 1 expected skip).
- `xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -destination 'generic/platform=iOS Simulator' build` — **BUILD SUCCEEDED**; `recipient-confirmation-final-correction-generic-build.log`.
- `git diff --check` — passed.

Per owner instruction, no simulator boot or retry followed the two pre-suite stalls. The full app plan remains **blocked, not passed**: `artifacts/test-runs/20260923-141405-747326-app/manifest.json` records 0/477 completed and exit 65. The second focused attempt `recipient-confirmation-seek-focused-final.log` was terminated before suite execution. Product-owner validation is outstanding.

Frozen source SHA-256 values for independent review:

```
f8572a6da69417860d9db29c8adfe41543df7d222524de7d9f0ca9da1a03f82c  App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift
2aaf87d6965cb2a5c368c4a57543bbeae56c8c5c048d7e8fce789cfdfb8772d0  Packages/SessionKit/Sources/SessionKit/Models.swift
f7260613b783f02285dd8d2698514b0275468eeb3eabe7c6d054a75d0a3c099b  Packages/SessionKit/Sources/SessionKit/SessionEngine.swift
b480cab0545c1cfcc4e5a0c68f34ce9724a603787be62a86a9a45ffee2ca7012  Packages/SessionKit/Tests/SessionKitTests/SessionKitCoreTests.swift
```

Log paths above are relative to this artifact directory. Existing dirty work is preserved; no commit, merge, distribution, or device install occurred.
