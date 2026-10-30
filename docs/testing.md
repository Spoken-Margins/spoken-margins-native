# Verification workflow

Tests verify implementation claims. Only the product owner establishes `human_validated` behavior. No test plan authorizes distribution.

**Strategy (September 24, 2026).** Verification has three layers, described in `AGENTS.md`:

1. host component tests (`--plan fast`)
2. app compile and app-hosted unit tests (`--plan app`)
3. journey checks in `docs/journeys.md`, driven by an agent with the iOS simulator tool and then by the owner on a device

The scripted UI route plans below (`ui`, `speech-canary`, `release`, `smoke`) are retired from routine use and kept only as a reference. They were slow, crashed simulators, and passed while real journeys failed. This file remains the reference for the runner's options.

## Commands

Bootstrap once after checkout, then use the named runner:

```sh
./scripts/bootstrap-python-tools.sh
.venv/bin/python scripts/verify-tests.py --plan fast
.venv/bin/python scripts/verify-tests.py --plan app
.venv/bin/python scripts/verify-tests.py --plan adapters
.venv/bin/python scripts/verify-tests.py --plan ui
```

`fast` runs runner regression tests, contract and surface validators, inventory checks, both browser suites, and the complete macOS SessionKit suite. It executes tests, not just compilation. `app` runs all app-hosted tests except the explicitly separated adapter cases. Run it for app orchestration changes; a fast-only pass is not an app gate.

`adapters` runs the separated real-media, audio-session and bundled inference cases serially. Other app tests still exercise some AVFoundation adapters with injected dependencies: AppBehavior is not advertised as a completely platform-free target. `ui` runs fourteen scripted routes covering dense Library layout, exclusive recording, ambiguous import presentation, recipient source reconciliation, accessibility-size keyboard/mini-player clearance, export navigation after changing sessions, and seeded playback with single-card mini-player clearance, stable player controls with a long title at accessibility text size, and written capture → search → star → explicit playback plus discard recovery. The eleventh route pastes a long AI response, checks that its bounded editor stays below the import action, and verifies that import starts playback. The twelfth route previews a portable Listening Edition and checks that its explicit import action remains reachable. The thirteenth checks session export from the scoped Margins workspace and its persistent destination action. Existing geometry assertions remain executable checks; attached screenshots are review evidence, not pixel-diff assertions.

`--plan smoke` runs one Library route, checking readiness, operability and a screenshot against the app built from the current inputs. It is a launch check, not an app or release gate.

For speech-input or speech-adapter changes, also run:

```sh
.venv/bin/python scripts/verify-tests.py --plan speech-canary
```

This deliberately longer plan preserves the exact emoji article with real playback and pause/resume. Keep it out of the ordinary editing loop. The held-out podcast corpus remains an explicit `scripts/run-podcast-anchor-benchmark.sh` invocation when alignment changes; its normal-package skip is recorded and allowed by name.

Before a release handoff, `--plan release` runs the fast checks plus every active app and UI test, including the speech canary. Run the UI plan on both phone and iPad destinations for layout changes. Choose destinations explicitly with `--device UDID`; inspect them with `xcrun simctl list devices available`. The minimum supported runtime is iOS 26. Use `--ios 26` or `--ios 27` to require a major OS version; combining `--ios` with `--device` checks both constraints. A requested unavailable or unsupported destination fails rather than falling back. Without `--device`, the runner identifies phones by device type (including renamed devices), prefers a booted supported phone, then the newest installed supported runtime. Explicit iPad UDIDs remain supported. Lack of a required device is inconclusive, not a pass.

Generic device builds and exact archive/export checks remain required when integration or distribution changes. Physical-device checks still own audible balance, Bluetooth/Lock Screen behavior, actual background scheduling and thermal behavior. Safari PDF sharing retains its explicit manual-path proof requirement from the release lane; helper or bundle checks do not waive it.

## Supported OS matrix

Use Xcode 27 and its iOS 27 SDK to build the iOS/iPadOS 26+ app and all extensions. Exercise app, adapter, and scoped UI plans on both iOS 26 and 27 before a platform-support handoff. Run destinations serially and shut down the previous simulator before booting the next to bound RAM. Keep iPad coverage for layout changes and speech-canary coverage for speech changes. A runtime being installed does not require it to be booted. iOS 18 is outside the supported matrix; old evidence remains historical. Simulator runtime/data deletion is a separate maintenance operation.

```sh
.venv/bin/python scripts/verify-tests.py --plan app --ios 26
.venv/bin/python scripts/verify-tests.py --plan app --ios 27
```

OS compatibility checks do not establish product-owner acceptance or physical-device background/audio behavior.

## Selection and evidence

Use `--plan app --list` (or another plan) to inspect selected test IDs without execution. `TestPlans/*.xctestplan` is the source for Xcode selections. AppBehavior and AudioAdapters must partition all active app tests. Release must contain every active app and UI test. Invalid or stale selectors fail inventory validation.

Each run writes an ignored `artifacts/test-runs/<timestamp>-<plan>/manifest.json`, raw logs and, for Xcode, a result bundle. The manifest includes source SHA, an input-content hash including uncommitted implementation files, toolchain/destination, commands, durations, selected test IDs and actual per-test results. A command succeeding with missing tests or an unexpected skip is a failure. A timeout retains partial evidence and is never reported as verified. There are no automatic passing retries. During simulator commands, the runner watches new crash reports for the selected device across all process names. An isolated report is recorded in the manifest as a warning and the run continues. Three or more reports from the same process within 60 seconds (a crash flood) fail the run, terminate the active command, and shut down that simulator; the runner does not blacklist the runtime or retry it. Crash-report delivery can be delayed, so this cannot guarantee that no dialog appears. The runner disables Xcode’s verbose simulator sysdiagnose collection (`-collect-test-diagnostics never`), which stalled after all app tests completed under Xcode 27 during the September 16 baseline work. Raw logs, per-test reconciliation, failures, timeouts, and result bundles remain required; collect targeted process samples or simulator diagnostics separately when a failure needs them.

The runner boots the selected simulator when needed and waits for boot readiness under a separate deadline before test execution. The runner bounds child processes externally, including synchronous system-service stalls. Xcode test timeouts provide an additional limit. A result bundle can be incomplete after a forced interruption; the raw log and manifest retain that distinction. Keep the first failure when performing a targeted diagnostic rerun.

Xcode uses a fixed per-scheme DerivedData directory under `.build/verification`. Build-for-testing results are reused only for the same implementation input hash, toolchain, simulator runtime, scheme and plan. `--rebuild` forces the build action. The runner rejects source changes during verification. Each Xcode plan also inspects the built app’s package UTI and share-extension declarations and executes its bundled JavaScript entrypoint with the PDF regression payload. This checks bundled wiring, not OS predicate evaluation or Safari delivery. Use one verification runner at a time; audio-session tests remain serial. Never reuse an arbitrary app found in another DerivedData directory.

## Contracts and traces

Runtime fixtures and trace payloads live under `Contracts/`. Surface metadata and its registries remain under `validation/` and its schema under `schemas/surface-contract.schema.json`; their fixture and trace references resolve into `Contracts/`, just like Swift replay. Older root-level fixture/trace copies are historical, not runtime inputs.

`validation/test-inventory.json` explicitly classifies every trace as active, deferred or archived. Each active trace has an individual XCTest method. New fixture JSON must match an existing schema selection, or intentionally update the schema/validator/runtime/tests together. Empty reserved selections require a reason. Archived Watch tests remain outside active app testing and do not authorize Watch development.

Trace expectations name distinct observations: navigation uses the runtime anchor builder, recording uses the captured anchor, and completed interjections use their published anchor. Source preservation compares complete source text. Chapter expectations inspect actual turn chapters. Representation deletion observes pre/post values; it establishes explicit command behavior, not a UI-confirmation flow. Export UI tests claim reachability; content isolation belongs to tests inspecting real exports.

## Adding regression coverage

Prefer the cheapest layer that exercises the failed boundary. Keep the production app model/router/archive/store in integration tests; inject costly resolution, rendering or OS lookup. Start from a populated library with distinct identities when testing imports. Exercise both completion and recovery, and inspect persisted results after reconstruction.

For asynchronous bugs, explicitly control completion order: start A, start B, finish A late; seek then pause; cancel then deliver completion; mutate a reviewed package after preview. Prefer expectations or controllable gates to fixed sleeps. Real-time waits remain appropriate only for bounded OS/media behavior. Do not compute expected results by calling the production policy under test.

Before trusting a regression assertion, introduce a bounded counterexample in an isolated experiment or test its negative case: wrong-session text of the same size, stale item identity, wrong anchor kind, missing trace selection, zero executed tests. The check must fail for the intended reason. Do not weaken a failing expectation until the current release contract and runtime evidence establish why it is stale.

Measure build, setup and test-body time separately. Compare repeated warm runs and a separately labeled cold run before promising a speedup. Broad cheap coverage stays enabled; a slow test is removed from the routine plan only when its detection responsibility has an explicit owner elsewhere.

## Prior-release persistence evidence

`Contracts/fixtures/persistence/build19.sqlite` and `build25.sqlite` were written by the unmodified SessionKit and persistence sources pinned at the external build-19 and internal build-25 TestFlight commits. Their schema-checked provenance records the source commit and database digest. The fixtures contain synthetic data, not a device-captured library. Tests copy it, open it with today's store, check two sessions with colliding note IDs, update one position, reopen the store, and check isolation and absence of quarantine. This is independent of today's encoder. Existing hand-authored migration and corruption cases remain enabled. `build29.sqlite` holds podcasts as Build 29 leaves them (streamed episodes with no stored length, Margins by media time, a finished episode) and an article; `Build29UpgradeProgressTests` plays every Margin and a seek on it and checks that no item's completion changes and no progress jumps (#352). It was generated on Linux, where swift-crypto stands in for CryptoKit. `build32.sqlite` and `build34.sqlite` were written the same way by the Build 32 and Build 34 sources (#1900); `PriorBuildPersistenceTests` opens both with today's store, and Build 34's also holds a podcast with a saved download, a Margin by media time and an imported file linked to its episode, which the test reads whole and rewrites with nothing quarantined. In the other direction, `scripts/check-build29-database.sh` (kept under that name because `shipped-build-compat.yml` runs it) writes a database with today's code, including the same podcast records, and opens it with the persistence code of Build 29, 32 and 34 (`BUILD29_TAG=<tag>` checks one tag). Needs a Mac, so it runs in that workflow, not in `--plan fast`.

Only regenerate intentionally with `.venv/bin/python scripts/generate-prior-build-fixture.py`, reviewing the database and provenance changes together. The generator uses an isolated temporary Swift package and does not alter the historical checkout. Device-captured upgrade evidence is still a release-handoff responsibility; this fixture does not claim it.
