# SessionKit

SessionKit is the domain logic of Spoken Margins: listening sessions, Margins, sources and their anchors, the SQLite store, `.spokenmargins` packets, feeds, EPUB reading and the on-device voice runtimes. The iOS app is a thin layer over it. Almost all of it builds and tests on a Mac without a simulator, and its Foundation-only modules build and test on Linux.

## Modules

| Library | What it holds | Platforms |
|---|---|---|
| `SessionKit` | sessions, Margins, sources, anchors, listening editions, narration planning | iOS, macOS, Linux |
| `SessionKitPersistence` | the SQLite store and its migrations | iOS, macOS, Linux |
| `SessionKitAI` | AI provider descriptions (OpenAI-compatible and a test fixture) | iOS, macOS, Linux |
| `SessionKitEPUB` | EPUB reading | iOS, macOS, Linux |
| `SessionKitFeeds` | podcast and article feeds, followed sources | iOS, macOS, Linux |
| `SessionKitSpeechFrontEnd` | text front end for the Kitten voice | iOS, macOS, Linux |
| `SessionKitAudio` | playback adapters, podcast anchor evidence (AVFoundation) | iOS, macOS |
| `SessionKitSharing` | packet export and import | iOS, macOS |
| `SessionKitSupertonic`, `SessionKitPocket` | neural voice runtimes on onnxruntime | iOS, macOS |
| `ShippedPacketReader` | the last shipped build's packet reader, frozen for compatibility tests | iOS, macOS |

The executables (`speech-bench`, `tour-render`, `substack-canary`) are developer tools. The app never links them. `coop-packet` and `phone-plan` are in their own package, [`Packages/SessionKitTools`](../SessionKitTools/Package.swift), which depends on this one by path, so a project depending on SessionKit doesn't resolve them (#1873).

Outside dependencies are pinned exactly in `Package.swift`: ZIPFoundation 0.9.20 and onnxruntime 1.24.2 (on Linux, swift-crypto 3.15.1 stands in for CryptoKit). `Package.resolved` is committed.

## Building and testing

On a Mac, from the repository root:

- `scripts/run-sessionkit-tests.sh`: the whole package (what `scripts/verify-tests.py --plan fast` runs).
- `scripts/check-sessionkit-standalone.sh [--test]`: copies the package somewhere with nothing next to it and builds (and tests) it there, to prove it stands alone.

On Linux: `scripts/run-sessionkit-linux-tests.sh` builds the Foundation-only modules and runs `SessionKitCoreTests`. The Apple-only targets are left out by an allowlist at the end of `Package.swift`, so a new target stays Mac-only until it is added there.

## What the tests read from outside the package

The package's sources read nothing outside it. Some tests read files the package doesn't own, and each of those is a named input in [`Tests/TestInputs/TestInputs.swift`](Tests/TestInputs/TestInputs.swift):

- `Contracts/`: the canonical schemas, fixtures and traces. `SESSIONKIT_CONTRACTS_DIR` can point somewhere else.
- `Site/`: the onboarding catalog the website publishes.
- `research/`: recorded fixtures and reference vectors.
- `voiceAssets`: the bundled Kitten voice (`App/SpokenMarginsApp/Resources/Kitten`). `SESSIONKIT_VOICE_ASSETS_DIR` can point somewhere else.
- `supertonicModel`: Supertonic's model, a download in neither the repository nor the app (#1820). `scripts/voice-catalog fetch supertonic-3-int8` puts it in `artifacts/voice-catalog/files/supertonic-3-int8`, checked against `Contracts/voice-models/sources.json`, and `SESSIONKIT_SUPERTONIC_DIR` can point somewhere else. Without it the Supertonic render tests skip and say how to fetch it; `SM_REQUIRE_MODELS` makes them fail instead.
- The app's sources and tests, for a few guards that check the app still calls an extracted helper.

Inside the spoken-margins-native checkout all of them are found. In a package checked out alone, a test that needs one is reported as skipped, with the input named; it never passes silently. `scripts/sessionkit_pass.py` lists the same folders, so the lane's cached-pass key changes when any of them does.

The Kitten tests (`KittenFrontEndTests`, `KittenRendererTests`) read the voice and the reference vectors through these inputs. `speech-bench` takes `--kitten <folder>` and `--supertonic <folder>` and has no default.

Not converted yet: the Pocket tests still find their model in `research/C2/` on their own. They move to the download registry with #1392, and `scripts/tests/test_sessionkit_pass.py` lists them until then.

## Versions

The app uses this package by local path (`project.yml`), so the app and the package always build from the same commit, and that commit is the pin.

For anyone else, versions are git tags named `sessionkit/vMAJOR.MINOR.PATCH`. The API is not stable yet, so versions stay below 1.0: a minor bump may break the Swift API, and a patch bump does not. What never breaks without the owner's explicit say-so, at any version: packets written by a newer build still import into the last shipped build, and a database written by a newer build still opens in the previous one.

SwiftPM can fetch a package by URL only when its `Package.swift` is at the repository root. When an outside project needs SessionKit by URL, publish a mirror with `git subtree split --prefix Packages/SessionKit` and tag it there (#1385).
