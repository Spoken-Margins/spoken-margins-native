# Recipient local transport proof — 2026-09-23

Status: **implemented and host verified; app runtime blocked**.

`Gate1AppModel.recipientPositionSeekReadiness` now requires `AVPlayerStreamPlaybackClient.isUsingPlaybackURL` to positively report the requested local recipient URL before Confirm can arm. A missing media-player probe is false, rather than proof. A DEBUG-only injected URL probe keeps the existing test fixture explicit: its recipient confirmation test first asserts that absent and remote-only observations cannot arm Confirm, then supplies the exact local URL/item observation for the success, persistence, and changed-edition path. The test source parses, but these new assertions have not executed because the app runner remains stalled before suite startup.

Checks after the two-file correction:

- `.venv/bin/python scripts/verify-tests.py --plan fast`: **verified**, 330 package tests passed, 1 expected skip; `final-transport-proof-fast.log`, manifest `artifacts/test-runs/20260923-145048-859797-fast/manifest.json`.
- `xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -destination 'generic/platform=iOS Simulator' build`: **BUILD SUCCEEDED**; `final-transport-proof-generic-build.log`.
- `swiftc -frontend -parse App/SpokenMarginsAppTests/Build23SharingSeamsTests.swift` and `git diff --check`: passed.

The app runtime gate remains **blocked, not passed**. The prior full-app manifest `artifacts/test-runs/20260923-141405-747326-app/manifest.json` records 0/477 tests completed and exit 65; the second focused attempt `recipient-confirmation-seek-focused-final.log` also stalled before suite execution. Per owner instruction there was no simulator boot or retry in this correction. Product-owner validation remains outstanding.

Frozen source SHA-256 values:

```
afcba4d4bbf578de2eca09715da2114b44f71cdbe299e1e814f441844bbd440b  App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift
c3f0bcb811e6baf3ceed972824083150c8e9bbc211ce7ae51884f130bb38df52  App/SpokenMarginsAppTests/Build23SharingSeamsTests.swift
```

Log paths above are relative to this artifact directory. All prior dirty work was preserved; no commit, merge, distribution, or device install occurred.
