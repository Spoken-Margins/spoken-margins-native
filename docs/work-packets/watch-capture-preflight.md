# Watch Capture Preflight Packet

## Objective

Prepare the deterministic seams for issue #96 without exposing a user-facing
Watch feature or claiming that Watch-owned recording works with a locked
iPhone. The packet restores a standalone Watch build target and defines the
capture, cached-anchor, durable-outbox, acknowledgement, and import-ledger
contracts needed before physical-device work.

## Feature-Request Survey

The 2026-08-30 GitHub survey found 52 open feature requests, including 27
explicitly marked Post-MVP. Issue #96 is the newest Watch-specific request and
defines the package's primary outcome: capture an interjection from the Watch
while the phone is locked without pretending that phone reachability proves
recording availability.

The strongest supporting requests are intentionally split by role:

- **Required mechanism:** take only the durable Watch outbox, retry, and phone
  import slice from #75. Full untethered package playback is not required for
  the first capture proof.
- **Required storage invariant:** apply #72's distinction between replaceable
  media and irreplaceable recordings so an unacknowledged Watch recording
  cannot be automatically evicted.
- **Useful prepared input:** #64's prepared-audio foundation can support the
  walking loop later, but the preflight does not add Watch TTS or broaden its
  rendering scope.
- **Best recall follow-ons:** #92 supplies summary-first Margin presentation
  and #94 adds Margin-text search once low-friction capture starts increasing
  Margin volume. #86 remains distinct because it searches library metadata,
  not Margin text.

This produces one auditable package—**Wrist Capture & Recall**—with capture
integrity first, retrieval second. Skim (#88-#90), sleep timers, cloud
processing, AI execution on Watch, and full #75 playback remain omission-check
items rather than hidden dependencies.

## Typed Boundaries

- **Capture fact:** immutable event ID, recording filename, capture time,
  duration, and the latest cached anchor receipt available when capture began.
- **Anchor receipt:** the phone-published session, item, target, source
  revision, snapshot revision, canonical media position, and observation time.
  It is evidence to validate, not permission to attach to a different source.
- **Delivery state:** saved locally, queued for phone, transferring audio,
  awaiting import, synced, or failed.
- **Import evidence:** a deterministic ledger records an event ID once. A
  duplicate transport delivery does not create another import.
- **Storage:** recording audio remains non-reproducible and protected until an
  acknowledgement makes its outbox record synced.

## Authorized Files

- `docs/release-lanes.md`
- `docs/work-packets/watch-capture-preflight.md`
- `project.yml`
- `Packages/SessionKit/Package.swift`
- `Packages/SessionKit/Sources/SessionKit/WatchCaptureModels.swift`
- watchOS availability guards in `SessionKitAudio` needed to compile the
  existing Watch audio dependency against the current SDK
- `Packages/SessionKit/Tests/SessionKitTests/WatchCaptureOutboxTests.swift`
- matching Watch contract schemas, fixtures, and validator routing
- generated Xcode project files after a clean `xcodegen generate`

Do not edit Build 23 sharing seams, shipping navigation, iPhone capture UI, the
historical Watch playback UI, or the current package-transfer runtime in this
packet.

## Automated Evidence

Run:

```bash
./scripts/bootstrap-python-tools.sh
.venv/bin/python scripts/validate-contracts.py
.venv/bin/python scripts/validate-surface-contracts.py
swift test --package-path Packages/SessionKit
xcodegen generate
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsWatch -destination 'generic/platform=watchOS' build | xcbeautify
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -destination 'generic/platform=iOS Simulator' build | xcbeautify
```

When Xcode package-manifest sandboxing is unavailable, the package and Watch
source layers can still be checked directly against the SDK before rerunning
the generic Xcode build in a normal developer shell:

```bash
WATCH_SDK="$(xcrun --sdk watchos --show-sdk-path)"
swift build --disable-sandbox --skip-update --package-path Packages/SessionKit --target SessionKit --triple arm64-apple-watchos11.0 -Xswiftc -sdk -Xswiftc "$WATCH_SDK" -Xcc -isysroot -Xcc "$WATCH_SDK"
swift build --disable-sandbox --skip-update --package-path Packages/SessionKit --target SessionKitAudio --triple arm64-apple-watchos11.0 -Xswiftc -sdk -Xswiftc "$WATCH_SDK" -Xcc -isysroot -Xcc "$WATCH_SDK"
xcrun --sdk watchos swiftc -typecheck -parse-as-library -module-name SpokenMarginsWatch -target arm64-apple-watchos11.0 -sdk "$WATCH_SDK" -I Packages/SessionKit/.build/arm64-apple-watchos/debug/Modules App/SpokenMarginsWatch/Sources/SpokenMarginsWatch/*.swift
```

### 2026-08-30 Preflight Result

- Contract and surface validators passed.
- All eight `WatchCaptureOutboxTests` passed.
- `SessionKit`, `SessionKitAudio`, and all existing Watch app sources compiled
  or type-checked for `arm64-apple-watchos11.0` against the watchOS 26.5 SDK.
- The full macOS package suite executed 228 tests with zero failures and one
  held-out benchmark skipped.
- `xcodegen generate` and the generic iOS Simulator app build succeeded.
- The generic Watch Xcode build remains unverified on this Mac because Xcode's
  watchOS 26.5 platform component is not installed, leaving no eligible Watch
  destination. Direct SDK compilation is green; the generic build remains a
  required check after installing that Xcode component.

Automated checks can establish `verified` preflight contracts and generic
buildability. They cannot establish `human_validated` recording behavior.

## Physical-Device Feasibility Checklist

Record device models, watchOS/iOS versions, build number, commit, audio route,
and diagnostics for every run.

1. Start iPhone-owned source playback through AirPods, lock the iPhone, and
   start a Watch-owned recording.
2. Verify the actual input route. Do not infer AirPods input from output route
   or pairing state.
3. Finish the recording and terminate the Watch app before transfer. Confirm
   the audio and saved-local outbox record survive relaunch.
4. Repeat while the phone is temporarily unreachable. Confirm queued state and
   later delivery.
5. Replay the event and audio delivery. Confirm one phone import and one
   acknowledgement.
6. Change the active item, session, and source revision before reconnecting.
   Confirm mismatched captures are held for resolution rather than silently
   attached.
7. Verify pause/resume behavior around recording and document whether source
   playback uses AirPods, the iPhone speaker, or another route.

## Stopping And Falsification Rules

- Stop if the Watch cannot durably save its own recording while the iPhone is
  locked; do not fall back to delegated phone recording.
- If AirPods input is unsupported or unreliable, document and present the
  Watch microphone fallback explicitly.
- A success indicator before atomic audio and outbox persistence is a failure.
- Loss after termination, deletion before acknowledgement, duplicate import,
  wrong-session attachment, or a false synced state is a release blocker.
- Simulator audio behavior, generic builds, and `WCSession.isReachable` do not
  falsify the locked-phone or delivery risks.

## Reset Instructions

The preflight packet does not register or expose the Watch app inside the
shipping iPhone app. Reverting its isolated commit series and regenerating the
Xcode project returns the repository to the Build 23 target set. Device-phase
fixtures and recordings must use a dedicated test container and provide an
explicit delete-test-data action before product-owner validation.
