# Verification workflow

Tests verify implementation claims. Only the product owner establishes `human_validated` behavior. The release lane in `docs/release-lanes.md` remains authoritative; no test plan authorizes distribution.

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

`adapters` runs the separated real-media, audio-session and bundled inference cases serially. Other app tests still exercise some AVFoundation adapters with injected dependencies: AppBehavior is not advertised as a completely platform-free target. `ui` runs five scripted routes covering dense Library layout, exclusive recording, ambiguous import presentation, recipient source reconciliation, and accessibility-size keyboard/mini-player clearance. Existing geometry assertions remain executable checks; attached screenshots are review evidence, not pixel-diff assertions.

`--plan smoke` runs one Library route, checking readiness, operability and a screenshot against the app built from the current inputs. It is a launch check, not an app or release gate.

For speech-input or speech-adapter changes, also run:

```sh
.venv/bin/python scripts/verify-tests.py --plan speech-canary
```

This deliberately longer plan preserves the exact emoji article with real playback and pause/resume. Keep it out of the ordinary editing loop. The held-out podcast corpus remains an explicit `scripts/run-podcast-anchor-benchmark.sh` invocation when alignment changes; its normal-package skip is recorded and allowed by name.

Before a release handoff, `--plan release` runs the fast checks plus every active app and UI test, including the speech canary. Run the UI plan on both phone and iPad destinations for layout changes. Choose destinations explicitly with `--device UDID`; inspect them with `xcrun simctl list devices available`. The default is the first available iPhone, not a hard-coded model name. Lack of a required device is inconclusive, not a pass.

Generic device builds and exact archive/export checks remain required when integration or distribution changes. Physical-device checks still own audible balance, Bluetooth/Lock Screen behavior, actual background scheduling and thermal behavior. Safari PDF sharing retains its explicit manual-path proof requirement from the release lane; helper or bundle checks do not waive it.

## Selection and evidence

Use `--plan app --list` (or another plan) to inspect selected test IDs without execution. `TestPlans/*.xctestplan` is the source for Xcode selections. AppBehavior and AudioAdapters must partition all active app tests. Release must contain every active app and UI test. Invalid or stale selectors fail inventory validation.

Each run writes an ignored `artifacts/test-runs/<timestamp>-<plan>/manifest.json`, raw logs and, for Xcode, a result bundle. The manifest includes source SHA, an input-content hash including uncommitted implementation files, toolchain/destination, commands, durations, selected test IDs and actual per-test results. A command succeeding with missing tests or an unexpected skip is a failure. A timeout retains partial evidence and is never reported as verified. There are no automatic passing retries.

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

`Contracts/fixtures/persistence/build19.sqlite` and `build25.sqlite` were written by the unmodified SessionKit and persistence sources pinned at the external build-19 and internal build-25 TestFlight commits. Their schema-checked provenance records the source commit and database digest. The fixtures contain synthetic data, not a device-captured library. Tests copy it, open it with today's store, check two sessions with colliding note IDs, update one position, reopen the store, and check isolation and absence of quarantine. This is independent of today's encoder. Existing hand-authored migration and corruption cases remain enabled.

Only regenerate intentionally with `.venv/bin/python scripts/generate-prior-build-fixture.py`, reviewing the database and provenance changes together. The generator uses an isolated temporary Swift package and does not alter the historical checkout. Device-captured upgrade evidence is still a release-handoff responsibility; this fixture does not claim it.
