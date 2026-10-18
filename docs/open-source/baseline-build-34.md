# Build 34 baseline (Solid Ground)

Recorded 2026-10-17. Part of #1382 (OS-01). This page records facts; it changes no code, tag or release.

It exists so that "behaviour preserved" has a reference. Anyone comparing the public or extracted code against the shipped app can name the exact source, toolchain and test results of `Solid Ground`, and can see which checks only the owner's phone can make.

## Source

| What | Value |
|---|---|
| Tag | `testflight/0.1-build-34` (annotated; tag object `76c873575c4c5c23f677601e714498da5155cffa`) |
| Commit | `485b144961133f0baeaa8717821a252c294dddbe`, dated 2026-10-16 19:20 -0500 |
| What the commit is | The merge of #1772, on top of `7257db6c4eda3611aee342a5ada345e72ee28388` (the merge of #1768). #1772 moved the local model's interjection-summary rules and error type from the app into SessionKit; it changed five files, all local-model code and its tests. |
| Build number | `CURRENT_PROJECT_VERSION` 34 on every target, `MARKETING_VERSION` 0.1, both in `project.yml` at that commit |
| Shipped | Uploaded to App Store Connect on 2026-10-16 (the tag message) |

## Toolchain

Each row says where the value comes from. The archive log lives on the owner's Mac and is not in this repository, so nothing below is read from it.

| What | Value | Source |
|---|---|---|
| Xcode and SDK | Xcode 27 with its iOS 27 SDK; the patch version is not recorded for the archive Mac | `docs/testing.md` ("Use Xcode 27 and its iOS 27 SDK") at the tag. `.github/workflows/hosted-app-macos.yml` (added after the tag) says the lane Mac runs Xcode 27.0 |
| Swift language mode | 6.0 | `SWIFT_VERSION: "6.0"` in `project.yml`; `// swift-tools-version: 6.0` in `Packages/SessionKit/Package.swift` |
| Swift compiler patch version | Not recorded | No source in the repository states it. The archive log or `xcrun swift --version` on the lane Mac would |
| Deployment target | iOS and iPadOS 26.0; SessionKit also builds for macOS 15 | `project.yml` and `Packages/SessionKit/Package.swift` |
| Simulator used by the integration runs | iPhone 17, iOS 26.5 | The lane reports quoted under "Test results" |

### SwiftPM pins

Both resolved files pin the same two packages, both with `exact:` requirements in `Packages/SessionKit/Package.swift`:

| Package | Version | Revision |
|---|---|---|
| `onnxruntime-swift-package-manager` | 1.24.2 | `b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2` |
| `ZIPFoundation` | 0.9.20 | `22787ffb59de99e5dc1fbfe80b19c97a904ad48d` |

On Linux, `Packages/SessionKit/Package.swift` swaps the dependency list for ZIPFoundation 0.9.20 (same pin) and `swift-crypto` 3.15.1, and drops the Apple-only targets; `Package.resolved` above is the Mac's.

The files are `Packages/SessionKit/Package.resolved` and `SpokenMarginsNative.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

## Build and test commands

Run from the repository root.

1. Host tests, the default loop: `.venv/bin/python scripts/verify-tests.py --plan fast` (set up the environment first with `scripts/bootstrap-python-tools.sh`).
2. SessionKit alone on a Mac: `scripts/run-sessionkit-tests.sh`. On Linux: `scripts/run-sessionkit-linux-tests.sh`.
3. App-hosted tests in one simulator: `.venv/bin/python scripts/verify-tests.py --plan app`.
4. App build for the simulator: `scripts/xcodebuild-lane -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -destination 'generic/platform=iOS Simulator' build-for-testing`.
5. App build for a device: `scripts/xcodebuild-lane -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -destination 'generic/platform=iOS' build`.
6. The project file is generated: `xcodegen generate` from `project.yml`, and both are committed.

`scripts/xcodebuild-lane` takes xcodebuild's own arguments and adds the Mac's build slots. The first two commands need no simulator.

## Test results at this commit

Each number links to the report it came from. Nothing here was re-run or re-derived.

| Check | Result | Where it was recorded |
|---|---|---|
| SessionKit tests (Mac) | 3885 passed | [Lane report on #1772](https://github.com/uncomposed/spoken-margins-native/pull/1772#issuecomment-6227296795). The runner tested the merge at `67ad9e5` and ruled its SessionKit inputs identical to `485b144`, so it reused that run |
| Contract validators and browser suites (`--plan fast`) | Passed. No count is in the report | Same report ("host tests (--plan fast): passed" on the merge commit) |
| SessionKit tests on Linux | 3,017 passed (the Linux build leaves out the Apple-only targets, so it is a smaller set than the Mac's) | The author's note on #1772 |
| App-hosted tests (`--plan app`) | 1217 passed, 0 failed, on `7257db6`, the commit's first parent | [Integration run on #184](https://github.com/uncomposed/spoken-margins-native/issues/184#issuecomment-6227445502) |
| App-hosted tests, a later tip | 1196 passed of 1196 expected on `bf64c8c5`, a descendant of the tag; the report explains the drop from 1229 on an earlier tip as 45 tests removed and 12 added | [Integration run on #184](https://github.com/uncomposed/spoken-margins-native/issues/184#issuecomment-6227631492) |

Neither app row is this commit's own count. No `--plan app` run was made on `485b144` itself. #1772 moved its interjection-summary tests from the app test bundle to SessionKit (the PR comment says 21), so the app count at the tag is lower than 1217 by the tests that moved. It was not recorded and is not guessed here.

The Test Desk built the tag once (scheme `SpokenMarginsReleaseTests`, `build-for-testing`) and ran the scripted journeys on it; see its [Build 34 baseline report](https://github.com/uncomposed/spoken-margins-native/issues/184#issuecomment-6229617190):

| Scripted journey | Result on Build 34 |
|---|---|
| J1 listen | Failed once, passed on re-run (flake on the first run after a fresh device boots) |
| J1 text chapters | Failed ("Article never started playing"); also fails on later tips, tracked in #1815 |
| J2 podcast survives relaunch | Passed |
| J3 record and rejoin | Passed |
| J7 PDF | Failed once, passed on re-run (the same flake) |
| J8 collections | Passed |
| VoiceOver audit | 3 of 4 failed on hit-area size; the same on later tips, tracked in #151 |

By hand through the simulator, J1 steps 1 and 2 passed (a link was added and the highlighted sentence advanced). J1 step 4 and J2 to J8 were not run by hand on this build.

## Prior-build compatibility checks

These are the checks that existed at this tag. They are against Build 29, the build they were frozen to. The page does not claim each ran on this commit: the Mac database check and `shipped-build-compat.yml` run only on pull requests touching storage, sharing or stored types, and #1772 touched none of those paths. What did run at this commit is the SessionKit suite (3885 passed), which includes the packet tests in item 2.

1. `scripts/freeze-shipped-reader.sh --check` fails if the frozen packet reader in `Packages/SessionKit/Tests/ShippedReader` differs from the `testflight/0.1-build-29` sources.
2. The packet tests (`Packages/SessionKit/Tests/SessionKitTests/SharingTests.swift` and `Packages/SessionKit/Tests/SessionKitTests/ShippedReaderGateTests.swift`) read every exported packet back with that frozen reader, so a packet Build 29 cannot open fails the SessionKit suite.
3. `scripts/check-build29-database.sh` writes a database with the current code and opens it with Build 29's own persistence code (`scripts/build29-db-reader`).
4. `.github/workflows/shipped-build-compat.yml` runs the first and third on pull requests that touch storage, sharing or a stored type.
5. `Packages/SessionKit/Tests/SessionKitCoreTests/PriorBuildPersistenceTests.swift` opens libraries written by earlier builds (Build 19 and Build 25, not Build 29) with the current code.

The tag holds no frozen reader or database check for Build 32. `AGENTS.md` on `next` says packet compatibility is tested against Build 32 and Build 34; the tag does not contain those checks.

## Regression boundaries

Where each boundary is checked. "Host" means `--plan fast` on any machine with the toolchain; "app" means the app-hosted plan on a simulator; "journey" means a numbered journey in `docs/journeys.md`.

| Boundary | Host or app checks | Journey | Needs the owner's phone |
|---|---|---|---|
| Playback | Host: `Packages/SessionKit/Tests/SessionKitCoreTests/PlaybackContinuationRulesTests.swift`, `Packages/SessionKit/Tests/SessionKitTests/MediaSeekRecoveryTests.swift`, `Packages/SessionKit/Tests/SessionKitTests/RealPlayerMarginMomentTests.swift`. App: `App/SpokenMarginsAppTests/Gate1AppModelWorkflowTests.swift` | J1, J2 | Whether it sounds right |
| Capture | Host: `Packages/SessionKit/Tests/SessionKitCoreTests/MarginCaptureSupervisorTests.swift`, `Packages/SessionKit/Tests/SessionKitTests/RecordingFileFinalizerTests.swift`. App: `App/SpokenMarginsAppTests/FinalizedRecordingIntegrityTests.swift` | J3 | Microphone input and levels |
| Anchoring | Host: `Packages/SessionKit/Tests/SessionKitTests/PortableArticleAnchorResolverTests.swift`, `Packages/SessionKit/Tests/SessionKitTests/PacketAnchorContextTests.swift`, `Packages/SessionKit/Tests/SessionKitTests/PodcastLateAnchorPlacementTests.swift` | J3, J5 | A shared Margin lands at the right place in a real copy |
| Persistence | Host: `Packages/SessionKit/Tests/SessionKitCoreTests/PriorBuildPersistenceTests.swift`, `Packages/SessionKit/Tests/SessionKitCoreTests/Build29PersistedShapeTests.swift` | J4 | Upgrading over the owner's real Library |
| Import and export | Host: `Packages/SessionKit/Tests/SessionKitTests/SharingTests.swift`, `Packages/SessionKit/Tests/SessionKitTests/SharedMarginExportTests.swift`, `Packages/SessionKit/Tests/SessionKitTests/PacketReaderRejectionTests.swift`. App: `App/SpokenMarginsAppTests/Build23RecipientSharingExperienceTests.swift` | J5, J6 | Share sheet and Shortcuts hand-offs on a real phone |
| Offline use | Host: `Packages/SessionKit/Tests/SessionKitCoreTests/OfflinePlayabilityTests.swift`, `Packages/SessionKit/Tests/SessionKitCoreTests/OfflineStorageLedgerTests.swift` | None | Airplane-mode listening, recording and export end to end (#1842) |
| Packet and database compatibility | Host: the Build 29 checks above, including `Packages/SessionKit/Tests/SessionKitCoreTests/Build29DatabaseFixtureTests.swift` and `Packages/SessionKit/Tests/SessionKitTests/ShippedReaderGateTests.swift` | J4 | Opening a packet exported by the shipped build on a real phone |
| Audible content | Not machine-verifiable | | Voice quality, loudness balance between voices and Margins |
| Bluetooth | Not machine-verifiable | | Route changes, headset controls |
| Lock Screen and background | Not machine-verifiable | | Lock Screen controls, narration with the phone locked, background refresh |
| Thermal behaviour | Not machine-verifiable | | Voice fallback on a hot phone |

The last four rows are checked only on the owner's phone (`docs/device-validation.md`); no agent or lane can hear audio or reproduce heat.

## Acceptance

Owner acceptance: not recorded

The owner has not yet said he accepts and ships `Solid Ground`. When he does, a later pull request fills this line and quotes him.
