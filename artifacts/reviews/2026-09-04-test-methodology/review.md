# Test methodology review — 4 September 2026

The best next investment is stronger tests of transitions across production boundaries, backed by explicit test selection. The repository already contains substantial, valuable behavioral coverage. Adding more broad simulator journeys indiscriminately would increase cost without reliably catching the failures visible in history.

## Scope and evidence limits

Reviewed `codex/provisional-next` at `90d08c19ddf957c70b8a34077f73a58f92771544`, including existing uncommitted audio-policy changes. No implementation, test, release-lane, or project files were edited for this review. Read the release plan before inspection; this is a review and proposal, not authorization to expand release scope.

Inspected the log of the 247 commits reachable from HEAD, searched all local refs for corrective commits, and examined selected diffs and contemporary verification/device reports. Inspected all test-suite boundaries, runners, project selection, trace harness and validators, with detailed sampling of playback, imports, sharing, persistence, preparation, AI policies, browser extraction and UI assertions. This is not a line-by-line proof of every assertion, a historical bisect, or evidence that every later fix was introduced by the preceding feature commit. Claims below distinguish documented failures, implementation gaps, and inference.

Source inventory: 243 package test methods in 10 Swift files; 388 app test methods in 28 files; 24 UI test methods in two files; approximately 23,000 Swift test/helper lines. These are source counts: project configuration excludes `Gate4WatchPackageRenderTests.swift`, and platform/environment gates affect execution. There are no tracked `.xctestplan` files or GitHub workflow files. That does not establish whether external CI or branch protection exists.

Raw measurements and inventory accompany this report. Timings describe one local run with existing caches and a dirty working tree, not cold-build performance or a statistically stable baseline. Automated results establish implementation evidence, never `human_validated` behavior.

## Model of the problem

The product's challenge is maintaining one coherent listening session while representations, asynchronous work, persistent records, navigation and OS ownership change underneath it.

Keep five layers distinct:

| Layer | What matters here |
| --- | --- |
| Product targets | Playback continuity, durable Margins, correct source identity, truthful readiness, reachable controls, privacy, recoverability |
| Failure mechanisms | Late callbacks, stale selection, incomplete artifacts, incompatible stored state, wrong coordinate systems, OS delivery/permission constraints, occlusion |
| Test work | Policy assertions, state sequences, real adapter integration, rendered layout checks, OS routes, release artifact inspection, human acceptance |
| Execution resources | Compiler/cache, test process, simulator boot and app launch, inference/audio service, physical device, human time, agent tokens |
| Evidence | Observable outcomes and artifacts tied to source/build/environment; explicit omissions and skips |

The decision criterion is additional important failures detected per unit of developer waiting and maintenance, subject to mandatory coverage for data loss, privacy, identity and playback recovery. Test count and line coverage alone cannot answer it. Use full cheap suites broadly; use expensive environments when their particular boundary is at risk.

## Historical failure patterns

| Sequence | What the evidence establishes | Better protection |
| --- | --- | --- |
| `62d7a6e` playback scrubbing fix → `22caa72` seek reconvergence fix | The later issue-84 report explicitly describes recurring defects: gesture ticks displaced the thumb; after release, pending seek handling froze derived state or failed transport while audio continued. This is the clearest repeated-fix example. | Observe pending, accepted/rejected, then multiple advancing player ticks through router, engine and persistence. Current tests already provide a good foundation. |
| Sharing completion/verification (`f96194a`, `38f5e12`) → `4d3d311` schema-five compatibility | A sharing build installed over a schema-5 library rejected the store, presented it as empty, and broke every import route. The device report identifies incompatible lane-written data, not a deleted library. | Upgrade tests using independent previous-build data, including unknown fields/record kinds, plus a bootstrap-error presentation assertion. |
| Build 23 verified candidate (`10f7fd1`, `5c79d44`) → Build 24 opening (`a7c9e29`) → `cda41a3`, `4708088`, `6f61718` | Subsequent code fixes bind imported podcast commentary to the imported item rather than stale selection, recover wrong associations, and extend cross-edition alignment. These show incomplete recipient coverage; they do not prove Build 23 newly introduced every defect. | A real package into a populated recipient database, delayed resolution, selection changes, reopen/retry, and different podcast editions. Assert durable association and absence of autoplay. |
| `ad332ce` PDF sharing improvements → `90d08c1` Safari fix | The manual proof explicitly records three failures beyond representation tests: extension activation excluded Safari's payload set, required JS entry instance was missing, and viewer CSS was imported before PDF detection. | Execute the bundled preprocessor, evaluate final activation metadata against observed payload sets, test routing precedence, then one actual Safari route. |
| `6b2d27c` emoji marker fix → `d668153` exact article gate → `4862874` speech sanitation | A marker-level fix was followed by broader speech-input projection changes and a preserved real article. This is iterative hardening; no bisect was performed to label its origin. | Unicode/source-offset invariants and small adversarial strings on every relevant change; retain the exact real-audio article as an adapter canary. |
| `596bdce` Now Playing remediation; contemporary 18 August device recheck | A visible system card was insufficient: percentage progress had been represented as synthetic 100-second duration, and ambiguous import review could appear only after another import started. | Assert semantics of metadata and immediate presentation after asynchronous completion, not only existence of a card or sheet. |
| `afb86b5` disables Watch interjection; Watch closeout | Real-device use showed reachability did not imply safe locked-phone recording. Capability was explicitly withdrawn. This is a platform feasibility correction, not simply inadequate unit coverage. | Keep unsupported behavior unavailable; physical-device capability check before promising it. Do not reactivate archived Watch work for this review. |
| Build 13 upload → `3f8eb5e` framework metadata correction | Upload succeeded but App Store processing rejected ONNX minimum-OS metadata inconsistent with the binary. | Inspect the exact archived/exported bundle and retain processing evidence. Simulator tests cannot establish distributability. |

Supporting records: `artifacts/validation/testflight-triage/2026-08-30-issue-84-media-seek.md`, `artifacts/validation/sharing-next/schema-five-library-recovery.md`, `artifacts/validation/build-23/automated-verification.md`, `artifacts/validation/provisional-next/2026-09-04-safari-pdf-manual-proof.md`, `artifacts/validation/recovery-mvp/2026-08-18-testflight-device-recheck.md`, `artifacts/validation/recovery-mvp/build-14-testflight-upload.md`, and `docs/gate3-watch-tethered-closeout.md`.

The recurring inference is that a locally correct state or adapter call is too often treated as sufficient evidence for an end-to-end claim. The later, better fixes follow completion through the production boundary and check what survives afterward. There is also genuine product learning: scope withdrawals must not be counted as regressions to inflate the diagnosis.

## What is already strong

- `SessionKitCoreTests` covers delayed seek acknowledgment, superseded completions, routed-client forwarding, repeated seek/interjection cycles, session-isolated export, source-offset projection and prepared/live transitions. Extend these patterns rather than replacing them with UI journeys.
- `SQLiteSessionStoreSafetyTests` exercises real SQLite, concurrency, migration, quarantine and unknown-record preservation. Prepared-audio tests reconstruct coordinators and reject corrupted committed chunks. These are more valuable than mocks alone.
- Sharing tests verify archive boundaries, privacy, ambiguity and negative cases. The anchor benchmark compares acoustic, fused, timestamp-only and transcript-only methods, has a frozen-rule held-out partition, and rejects wrong confident placements. Preserve that methodology; expand corpus diversity separately from routine test execution.
- App tests exercise real app orchestration with injected dependencies, including source imports while playback continues and imported-package repair. Browser tests execute bundled JavaScript as well as source helpers.
- UI tests already contain useful hittability, frame and keyboard-clearance assertions. The repository explicitly distinguishes implementation verification from product-owner acceptance.

## Findings, ordered by expected value

### 1. Execution coverage is inconsistent with the apparent gate names

`scripts/verify-gate1-routine.sh` runs validators and package tests, but neither app tests nor browser tests. `verify-gate1.sh` adds a build and selects only `SpokenMarginsAppUITests/Gate1FlowUITests`, on phone and iPad. It does not execute the app unit suite or the separate emoji UI class. `verify-gate2.sh` uses narrower selections and omits the surface validator. Meanwhile AGENTS' fast command `swift build --build-tests` compiles tests but does not run them; the routine script does run them.

Thus “gate passed” needs the exact test plan, not just a gate label. Broad UI gates can consume minutes while cheaper relevant app tests are absent. The available simulator inventory during review also has no iPad and no exact `iPhone 17` device, so the scripts' automatic selection cannot complete their defaults here without configuration.

Propose versioned Fast, AppBehavior, UISeams and Release plans plus a runner emitting selected/executed/skipped counts, build/source identity and result location. Treat unexpected zero tests as failure. Explicitly classify archived tests; do not run dormant Watch routes simply to raise coverage. Unknown change categories should select a conservative superset. Validate any selection policy against occasional full runs before trusting exclusions.

### 2. Some assertions are weaker than the claim in the test name

In `TraceReplayTests.swift`, `chapters` checks that the expected JSON array is empty, without checking runtime chapter state. `requiresExplicitIntent` and `explicitSelectionOverridesDefaultScope` compare fixture booleans to true. Adjacent assertions may still cover portions of those behaviors, but these particular checks add no runtime evidence. `sourceTextUnchanged` only checks that one known URL remains; other source changes can escape.

The anchor-type assertion is more direct: it accepts either an actual match **or an expected value of `text`**. Consequently a trace expecting text can pass with a different or missing actual anchor type. Replace that permissive branch with explicit normalized equality and add a wrong-anchor counterexample.

`testExportAfterTwoSessionsStaysSessionIsolated` reads `export.preview.label`, which the view explicitly defines as “Export preview, [size]”. Comparing that label compares summary metadata, not exported content. Session isolation has stronger lower-layer coverage already; this UI test should either claim only preview reachability or use an independently observable complete export with session-distinct sentinel content.

Layout policy constants and registered color-pair math are useful cheap checks, but do not establish that the rendered view uses those choices. Prompt wording assertions verify construction, not model output quality.

First repair these assertions. Then try a small set of deliberately wrong implementations in an isolated experiment: wrong-session note with equal-size text, stale import item, stale seek completion, stale preview digest, runtime chapters retained after invalid map. Each important regression assertion should fail for the intended reason. This proposal does not require a repository-wide mutation-testing framework.

### 3. Contract validity and executable coverage can diverge

The Swift harness hard-codes 17 trace names; `Contracts/traces` has 23. Unselected: browser-video, car-basic, listening-map-ingestion-and-repair, and three Watch traces. Some are legitimately out of current scope. They need explicit active/deferred/archived classification and reasons, rather than accidental omission. Three XCTest methods currently aggregate the 17 traces, obscuring per-scenario timing and failures.

The main validator and Swift harness read `Contracts/`; the surface validator reads root-level `schemas`, `fixtures`, `traces`, and `validation`. Comparison found three differing root fixtures and four differing traces, plus differing/missing schemas. For example the root Lock Screen capability fixture lacks the media-time and rate-observation entries in `Contracts/`. Both validators passed despite this divergence.

Propose one authoritative mapping for surface references and runtime fixtures, plus an inventory check: every applicable fixture matches a schema or an explicit exemption; every trace has executable coverage or an intentional disposition; every supported expectation observes runtime behavior. Preserve fail-closed handling of unknown expectations. Resolve differences intentionally rather than copying one tree over the other.

### 4. Test asynchronous histories explicitly; stop paying for incidental waiting

App tests contain many 20-ms polling loops and real sleeps, including delayed renderer fakes. These can pass or fail depending on scheduler timing, and fixed waiting only proves absence during that interval. Existing expectation-based adapter tests are a better pattern.

Introduce controllable completion gates for resolver/render work and a clock for application-owned deadlines. Enumerate short adversarial sequences: request A, request B, complete A late; seek, pause, complete seek; cancel render, deliver a late result; edit after preview; background expiration between writing a chunk and committing its manifest. Assert identity, final state, persisted data and absence of stale side effects.

Start with 2–4 competing events in the highest-risk workflows. Do not enumerate every product permutation. Keep real time for real AVFoundation callbacks and bounded adapter canaries; a virtual clock does not test OS audio. Preserve an independently written expected model so the test does not simply repeat the production transition logic.

### 5. Integration tests should keep the real boundary and replace the expensive dependency

Use a real app model, router, package parser and temporary SQLite/filesystem, with controllable network/render completion. Good package-import and reconstruction tests already do much of this. Add a shared fixture builder with a populated unrelated session, distinctive IDs and per-test preferences, rather than always starting from a clean single item.

For Safari, a native import helper cannot establish extension discovery. Preserve observed payload shapes and replay them through the bundled entrypoint and native selection logic; inspect built Info.plist activation/UTI metadata. Keep one real Safari smoke for delivery. For persistence, include fixtures produced independently by supported prior distributed builds; generating old data using today's encoder can hide compatibility defects.

For local AI, retain prompt/privacy and deterministic rejection tests in the fast suite. Separately evaluate frozen examples and paraphrases for omission, attribution, question preservation and unsupported additions on a model-capable device. One exact listener anecdote is a useful regression fixture, not a general quality estimate.

### 6. UI testing need not involve an agent deciding every click

Keep scripted XCUITest for deterministic interaction. An agent is useful for discovering unfamiliar failure paths and reviewing ambiguous visual changes, but need not run in the execution loop. Compile discovered problems into smaller deterministic checks where feasible.

Use three complementary UI checks:

1. Directly seeded rendered states: Library preparing/failed/ready, recording guard, sender stale preview, recipient needs-source, keyboard plus mini-player. Assert hittability and usable geometry. Add stable screen/component snapshots where appearance matters; captured screenshots alone are evidence, not regression assertions. Fix locale, content size, clock and appearance; review baseline changes rather than automatically accepting them.
2. A small real-navigation set: import into active playback; play/interject/resume; sender edit invalidates preview; recipient missing-source returns to the pending package; one Safari handoff. Seeding a screen bypasses navigation, so it cannot replace these.
3. Bounded device acceptance for audible balance, Bluetooth/Lock Screen ownership, permissions, real background scheduling and thermal behavior. Keep product-owner acceptance separate from automation.

Use a small coverage matrix: compact phone/standard text, compact phone/accessibility text, iPad regular width, plus relevant dark/keyboard states. Pairwise sampling is a starting point; explicitly include known risky combinations such as accessibility text plus mini-player plus keyboard. Avoid the full Cartesian product.

Apple provides test-plan configurations and `performAccessibilityAudit` for rendered accessibility checks. These complement the existing color math and geometry assertions; they do not judge comprehensibility or audible experience. See [Apple test plans](https://developer.apple.com/documentation/xcode/organizing-tests-to-improve-feedback) and [accessibility audits](https://developer.apple.com/documentation/accessibility/performing-accessibility-audits-for-your-app).

## Speed and execution proposal

Measured initial local sample:

| Work | Wall time | Result |
| --- | ---: | --- |
| Contract validator, including Supertonic file hashes | 1.199 s | Pass |
| Surface validator | 0.776 s | Pass |
| Browser extraction suites | 0.670 s | 11 passed |
| Package runner including build | 11.358 s | 243 executed, one intentional corpus skip, zero failures |
| Package XCTest body | 6.880 s | Included in preceding row |

The first four commands total 14.0 seconds. The package's slowest individual cases were silence detection (1.757 s), synthetic acoustic ambiguity (1.742 s), SQLite concurrency (1.043 s), and long map splitting (0.618 s). This is not a reason to weaken them. Asset hashing currently costs too little to justify an integrity cache.

### Full app-suite attempt: failures and a blocked OS call

Ran the complete app-unit selection on iPhone 17 Pro / iOS 26.5 with parallel testing disabled, using the existing generated project and DerivedData. Four completed test methods failed before execution stalled:

| Test | Observed mismatch | Interpretation / next falsification |
| --- | --- | --- |
| `PodcastDownloadCoordinatorTests.testRetryMigratesPreviouslyFailedBBCDownloadWithoutReimport` | `.downloading` versus expected `.waitingForWiFi` | Inspect explicit retry/network policy; fix the setup or expectation only after confirming intended behavior. |
| `SourceLinkImportTests.testDefaultReleaseDoesNotTranscribePodcastForAIGeneratedListeningMap` | Private map request is enabled rather than rejected | Strong evidence of a stale expectation: the 2 September release-plan revision authorizes private episode maps. Replace with current capability/privacy boundaries, not blanket removal of coverage. |
| `SourceLinkImportTests.testInterjectionTranscriptionFinishesBeforeSourceWindowTranscriptionStarts` | Source request already occurred; note remains scheduled / transcript nil | Possible scheduling regression or ambiguous test identity/setup. Exercise controlled tasks and assert the captured interjection ID, rather than dismissing it as flaky. |
| `SourceLinkImportTests.testOlderPodcastSessionKeepsExactPositionAfterOpeningAndClosingNewSession` | Observed adapter time 0 versus expected 2,100,000 ms | Could be asynchronous seek acknowledgment or a runtime regression. Check pending/accepted semantics and eventual persisted/adapter convergence. |

These are observations on the dirty working tree, not proof of four newly introduced product bugs. They also show why a package-only pass is insufficient for the app boundary.

`SupertonicSpeechTests.testUnavailableConfiguredSystemVoiceDoesNotSilentlyUseGenericVoice` then stopped making progress for over two minutes. A two-second process sample shows the test in `SystemSpeechPlaybackClient.playbackSpeechPreviewMode()`, inside `AVSpeechSynthesisVoice(identifier:)`, waiting on a semaphore. Requested interruption after approximately five minutes; process exit including teardown took 383.232 seconds. The log contains 375 completed methods: 371 passed and four failed. It is **incomplete**, not a passing full suite and not a measured complete-suite duration. Xcode also failed to finalize its result bundle after interruption (exit 73). The partial `.xcresult` is under `/tmp/spoken-margins-test-review-20260904/app-tests.xcresult`; use the accompanying raw log, timing, summary and sampled stack as evidence rather than assuming the result bundle is readable.

Separate the missing-voice policy from the system lookup via dependency injection, and give real-service tests an externally enforced timeout. A timeout inside the same blocked main actor cannot reliably rescue a synchronous OS call. This is a measured reason to split adapter tests from ordinary app behavior, rather than only a theoretical optimization. No automatic retry or assertion changes were made to turn this run green.

Historical UI evidence records 85.619 s sender, 55.711 s recipient and 71.655 s layout: 213 s for three routes, before separate build/setup costs. The exact emoji article recorded 191.860 s and has a 720-s deadline. These are historical measurements, not current reruns or expected durations for every test.

| Frequency/trigger | Run | Deliberate boundary |
| --- | --- | --- |
| Normal development | Both validators, all package tests, browser tests, changed app behavior group | Preserve broad inexpensive protection |
| App/session/import integration change | Complete app unit suite on one simulator; short relevant UI seam if navigation changed | Include app orchestration, not just SessionKit |
| Audio adapter/OS/dependency change | Relevant real-audio and extension canaries; exact emoji article when speech projection or adapter changes | Keep synthetic state tests and actual OS integration distinct |
| Before release acceptance | Complete active behavior suites, scoped phone/iPad UI matrix, prior-build database upgrade, archive/export inspection, required device handoff | Exact candidate evidence and recorded omissions |

Implement explicit app-only and UI test configurations so selecting unit tests need not build unrelated UI runners. During this review, `-only-testing:SpokenMarginsAppTests` still compiled/copied the UI runner under the shared scheme. Reuse compatible builds with `build-for-testing` and `test-without-building`, keyed by source including dirty changes, Xcode/SDK, architecture and configuration. Apple documents this separation in [TN2339](https://developer.apple.com/library/archive/technotes/tn2339/_index.html).

Remove `clean build` from routine smoke execution, retaining a cold-build gate when warranted. Pin DerivedData/output identity: `smoke-simulator.sh` currently selects an app from all DerivedData using `find ... | tail -1`, which does not prove it is the app just built. Its successful launch plus screenshot also does not establish healthy runtime state. Add a bounded readiness assertion and exact artifact selection.

Do not blindly parallelize audio-heavy tests. Several app tests use shared preferences and AVAudioSession. Isolate defaults, database roots, notifications and temporary artifacts first; serialize process-global audio tests. Split pure presentation/policy code out of the app-hosted target incrementally if measured rebuild/launch cost justifies it. Do not start with a broad architectural rewrite or a framework migration.

## Proposed implementation order and audit

1. **Make evidence truthful.** Named plans, exact execution manifest, explicit skips, trace/fixture inventory, repair weak assertions. Keep current runtime behavior intact. Success: a documented command runs every intended active group, and the targeted wrong implementations fail.
2. **Strengthen the known escapes.** Controlled async histories for seek/render/import; populated recipient and independently captured prior-build data; bundled Safari contract checks. Extend existing good tests. Success: reproduce historical failure mechanisms without long UI routes, and prove reconstruction/continuity afterward.
3. **Reduce simulator overhead.** Separate app-only build configuration, compatible build reuse, focused rendered-state checks and a small real-navigation set. Success: compare full before/after wall time and failures on the same machine/toolchain, with no silently dropped checks.
4. **Reserve expensive realism for its purpose.** Audio/device/corpus/release artifact gates selected by changed boundary and release status. Agent exploration gets a bounded mission and produces reproducible fixtures; it is not a permanent per-commit dependency.

Collect approximately ten comparable warm runs plus a separately labeled cold run before setting latency targets. Record build, boot/install/launch and test-body time separately, alongside first-attempt failures, reruns, skips and selected IDs. For flaky behavior, preserve the initial failure; a passing retry is not a clean pass. Repetition is justified while diagnosing nondeterminism, not as a default tax.

Audit alternatives explicitly: retaining today's full UI routes costs more but provides broad wiring evidence; selecting fewer tests reduces delay but risks omissions; unit-only execution misses OS boundaries; agent-only UI exploration is costly and less repeatable. The proposed combination retains cheap full coverage and a small expensive layer with explicit responsibilities.

Stopping rules: unexpected omissions/skips or a wrong-session/data-loss/privacy counterexample block the gate. An unavailable OS/device check is inconclusive, not passed. Do not remove a slow canary until its unique failure-detection responsibility has another owner. If selection misses a failure found by the full suite, broaden the rule before trusting it again. If optimization does not reduce measured waiting or maintenance, stop expanding it.

This method is designed to catch the prior pattern of “a test passed at one layer, therefore the user flow works.” Every claim should name the boundary actually exercised and the outcome actually observed.
