# Building Spoken Margins

This page takes a fresh clone to a built app and passing host tests. `scripts/check-fresh-clone.sh` runs these same steps in an empty temporary clone, so the page is checked rather than remembered.

## What you need

| Tool | Version | Where that comes from |
| --- | --- | --- |
| macOS | one that runs Xcode 27 | `docs/testing.md` |
| Xcode | 27 (iOS 27 SDK) | The app builds for iOS/iPadOS 26 and later with Xcode 27. The hosted CI job pins `/Applications/Xcode_27.0.app`. |
| Swift | 6.0 language mode (Xcode 27 ships 6.2 or newer) | `SWIFT_VERSION: "6.0"` in `project.yml`, `swift-tools-version: 6.0` in `Packages/SessionKit/Package.swift` |
| iOS deployment target | 26.0 | `project.yml` |
| Python | 3 (checked on 3.13) | Used by the validators and the test runner. |
| Node | 22 | Used by the browser-extraction tests (checked on 22). |
| git and git-lfs | any recent | The voice model files are Git LFS objects. |

Without a Mac you can still run the contract validators, the browser tests and SessionKit's core tests (see "On Linux").

## Before you clone

Install git-lfs and turn it on once, before cloning:

```sh
git lfs install
git clone https://github.com/Spoken-Margins/spoken-margins-native.git
cd spoken-margins-native
git lfs pull
```

If you cloned first, `git lfs pull` fills in the model files afterwards. Without it the files under `App/SpokenMarginsApp/Resources/Kitten/` are tiny text stubs, and the app's bundled Kitten voice won't load. Supertonic's model isn't in the repository: listeners download it in Settings › Voices, and `scripts/voice-catalog fetch supertonic-3-int8` puts a copy in `artifacts/` for the tests that render with it (#1820).

## Python tools and contract checks

```sh
scripts/bootstrap-python-tools.sh
.venv/bin/python scripts/validate-contracts.py
.venv/bin/python scripts/validate-surface-contracts.py
```

The bootstrap makes `.venv/` and installs the pinned packages from `requirements-dev.txt`. These tools check the repository only; none of them ships in the app.

## Node packages and browser tests

```sh
npm ci
npm run test:browser-extraction
```

## Host tests

SessionKit holds the domain logic and its tests run on the Mac without a simulator:

```sh
cd Packages/SessionKit && swift test
```

The same suite plus the contract validators, the browser tests and the script tests, the way a pull request is checked:

```sh
.venv/bin/python scripts/verify-tests.py --plan fast
```

### On Linux

Only SessionKit's core tests run. Use the wrapper, not `swift test`, because SwiftPM on Linux rewrites `Packages/SessionKit/Package.resolved` and the wrapper puts it back:

```sh
scripts/run-sessionkit-linux-tests.sh
```

## Build the app for the simulator

No Apple developer account is needed:

```sh
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

The hosted CI job's device build uses the same scheme and `CODE_SIGNING_ALLOWED=NO` (its simulator job builds the `SpokenMarginsAppBehavior` scheme instead). `SpokenMarginsNative.xcodeproj` is committed; you only need `xcodegen generate` after editing `project.yml`.

## Run on your own iPhone

The signing team is not in the repository. A device build reads it from `Config/Local.xcconfig`, which is git-ignored:

1. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and put your team ID on its `DEVELOPMENT_TEAM` line.
2. The bundle identifiers are still the owner's, and your team can't sign them. In `project.yml`, replace every `com.spokenmargins.native` bundle identifier (app, widget, Safari extension, share extension) with your own, and the App Group `group.com.spokenmargins.native` in every file that names it. List them with `grep -rl group.com.spokenmargins.native App`; they are the `.entitlements` files and some Swift files.
3. Remove the `applinks:` associated domain from the app's entitlements. Universal links belong to the owner's domain.
4. Run `xcodegen generate`, open `SpokenMarginsNative.xcodeproj` in Xcode, pick your iPhone and run.

Do not commit the edits in steps 2 and 3 to a pull request.

## What does not run without the owner's services

- Share links, the voice catalog and the voice downloads talk to the owner's server. The app works without them; those features show nothing or fail quietly.
- TestFlight uploads, the phone-build shortcut and signing use the owner's accounts and Mac.
- The lane runner, the audit, the Dial and the other `ops/` jobs run on the owner's machines. A pull request does not need them to be read or tested here.

## Check this page

`scripts/check-fresh-clone.sh` clones the committed `HEAD` into an empty temporary folder, with no `.venv`, no `node_modules` and nothing from another checkout, and runs the steps above. It stops at once if git-lfs is missing. It skips any other step whose tool is missing and then says `PARTIAL PASS`, never `PASS`. Add `--app-build` for the simulator build on a Mac.
