# Sharing Foundation Core Reconciliation

Date: 2026-08-26
Status vocabulary: `implemented` means a package/runtime path exists; `verified` means automated developer evidence supports it; `human_validated` is reserved for product-owner acceptance.

## Branch, ancestry, and scope

- Working branch: `codex/sharing-next`.
- Starting SHA: `9dedf3baf208fd931e682a6c50344a7da49cf831`.
- Implementation SHA before this evidence-only commit: `56b15cf`.
- Starting `main`: `9dedf3baf208fd931e682a6c50344a7da49cf831`.
- Starting `codex/testflight-triage`: `22788cb96a6763d186a607961ee229c5b01d6156`.
- Historical source branch and tip: read-only `codex/sharingV1` at `8764c9549aab5c1275ff8bbbc82ccdfe0e8fb052`.
- Relevant historical implementation commit: `493af509661b030dff77d3e079c05475e08422c1` (`Implement sharing v1 and visible article acquisition`).
- Merge base between the starting sharing lane and historical branch: released Build 19 source `738c743e202f5e700f4d6975adee52862f63c69f`.
- `9dedf3b` is not an ancestor of `codex/sharingV1`; the historical branch lacks later governance/packet commits. The extraction therefore used deliberate current-source adaptations. No merge or cherry-pick was attempted, and no merge conflict was encountered.
- Authorized issues: #17, #18, #67, and reconciliation #81. #68 presentation and #19 replies remain outside this slice.
- The separate TestFlight-triage worktree remained on `codex/testflight-triage`; this work used a new worktree at `/Users/colemiller/Documents/GitHub/spoken-margins-native-sharing-next` for the existing authorized branch.
- Starting worktree and final implementation worktree were clean at their recorded checkpoints. No user or unrelated changes required preservation.

## Challenge model and audit criteria

The resources were the current sharing lane, historical sharing commit/branch, existing JSON-record persistence, current SessionKit package, and stable contract validator. The execution topology remained package-only: contract validation -> immutable domain models -> archive/builder/import services -> append-only repository records -> focused/full package tests. App UI and playback were not consumers.

The main failure modes were a wholesale historical merge, package data leakage, package IDs becoming recipient primary keys, nondeterministic or partial duplicate import, ambiguous source material being confidently placed, cleanup corrupting substrings/private capture, and accidental edits to triage-owned files. Evidence paths were schema validation, deliberately invalid fixtures, deterministic archive comparison, hostile archive tests, in-memory and SQLite import tests, anchor-resolution tests, changed-path audit, and the full SessionKit suite.

Stopping rules remained: any forbidden-surface dependency, accepted-triage conflict, unapproved trust/rights/transport choice, destructive migration, nondeterministic malformed/tampered/duplicate outcome, or baseline failure that obscured regression attribution. None fired.

## Historical file disposition

The following table accounts for the historical branch diff inspected with `git diff --name-status codex/sharing-next...codex/sharingV1`. “Rewritten” means a bounded current-compatible implementation was created; no whole historical file was restored.

| Historical path | Disposition | Reason or current destination |
| --- | --- | --- |
| `App/Gate2Shared/Sources/Gate2CompactCommandQueue.swift` | Deferred/rejected | Forbidden compact-control/app surface; package core has no playback commands. |
| `App/Gate2Shared/Sources/Gate2LiveActivityAttributes.swift` | Deferred/rejected | Forbidden app presentation state. |
| `App/SpokenMarginsApp/Info.plist` | Deferred/rejected | File-type/app enablement is outside this disabled core. |
| `App/SpokenMarginsApp/Resources/Legal/ZIPFoundation-MIT.txt` | Rejected for this slice | The app does not consume the new product; SwiftPM dependency metadata is recorded in `Package.resolved`. App attribution belongs with future app integration. |
| `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift` | Deferred/rejected | Explicitly forbidden and overlaps active triage. |
| `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1RootView.swift` | Deferred/rejected | Explicitly forbidden sender/recipient UI. |
| `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate2CompactControlController.swift` | Deferred/rejected | Presentation/playback integration. |
| `App/SpokenMarginsApp/Sources/SpokenMarginsApp/LocalFoundationModels.swift` | Rejected | App-local integration was not required for package models. |
| `App/SpokenMarginsApp/Sources/SpokenMarginsApp/PublicPodcastLinkResolver.swift` | Rejected | Later historical visible acquisition/podcast change; not package core. |
| `App/SpokenMarginsApp/Sources/SpokenMarginsApp/SharingExperience.swift` | Deferred/rejected | Sender preview, share sheet, recipient UI, and replies remain disabled/out of scope. |
| `App/SpokenMarginsApp/Sources/SpokenMarginsApp/StreamingSpeechQueue.swift` | Rejected | Explicitly forbidden triage-owned playback. |
| `App/SpokenMarginsApp/Sources/SpokenMarginsApp/SupertonicSpeechPlaybackClient.swift` | Rejected | Explicitly forbidden triage-owned playback. |
| `App/SpokenMarginsAppTests/Gate1AppModelWorkflowTests.swift` | Deferred | App flow tests wait for authorized app integration. |
| `App/SpokenMarginsAppTests/Gate2CompactControlTests.swift` | Deferred | Compact presentation/playback is out of scope. |
| `App/SpokenMarginsAppTests/SourceLinkImportTests.swift` | Rejected | Visible source acquisition is not required for canonical source representation. |
| `App/SpokenMarginsAppTests/StreamingSpeechQueueTests.swift` | Rejected | Later triage/playback history. |
| `App/SpokenMarginsAppTests/SupertonicSpeechTests.swift` | Rejected | Later triage/playback history. |
| `App/SpokenMarginsGate2Widget/Sources/Gate2LiveActivityWidget.swift` | Deferred/rejected | Explicitly forbidden widget presentation. |
| `App/SpokenMarginsShareExtension/Sources/SourceLinkShareViewController.swift` | Deferred/rejected | Share-extension enablement is outside this package slice. |
| `Contracts/docs/runtime-capability-model.md` | Rejected | No new runtime capability or UI gate was authorized. |
| `Contracts/docs/sessionkit-contract.md` | Rewritten | Added only reviewed-sharing/package/import boundaries and fixture registration; historical playback-command language was not copied. |
| `Contracts/fixtures/capabilities/phone-tablet-offline.json` | Rejected | Sharing remains unavailable to ordinary runtime profiles. |
| `Contracts/fixtures/capabilities/phone-tablet-online.json` | Rejected | Sharing remains unavailable to ordinary runtime profiles. |
| `Contracts/fixtures/interjection-packages/minimal-article.json` | Reused and tightened | Retained as stable text-only root-package fixture; added explicit private-representation omission. |
| `Contracts/fixtures/interjection-packages/podcast-cleaned-audio.json` | Reused and tightened | Retained as stable explicitly selected cleaned-audio fixture; added explicit private-representation omission. |
| `Contracts/fixtures/interjection-packages/reply-child-guided.json` | Rejected | Explicit #19 reply fixture. |
| `Contracts/fixtures/sharing/cleanup-revision.json` | Reused | Stable share-revision fixture registered with its schema. |
| `Contracts/fixtures/sharing/imported-commentary-control.json` | Deferred/rejected | Presentation/playback control state is not required by the imported-layer persistence core. |
| `Contracts/schemas/imported-commentary-control.schema.json` | Deferred/rejected | Same control/presentation boundary; no new compact command IDs were introduced. |
| `Contracts/schemas/interjection-package.schema.json` | Rewritten and tightened | Strict selected-representation combinations, bounded anchors, and eight mandatory privacy assertions; reply-to field removed. |
| `Contracts/schemas/interjection-share-revision.schema.json` | Reused and tightened | Typed immutable revision/status bounds aligned with runtime model. |
| `Contracts/schemas/interjection.schema.json` | Rejected | The private capture contract was not expanded with reply targets or flattened imported data. |
| `Contracts/schemas/runtime-capability-profile.schema.json` | Rejected | No app capability or external enablement. |
| `Packages/SessionKit/Package.resolved` | Adapted | Added only pinned ZIPFoundation `0.9.20`. |
| `Packages/SessionKit/Package.swift` | Adapted | Added isolated `SessionKitSharing` product/target and focused test dependencies; no app/project linkage. |
| `Packages/SessionKit/Sources/SessionKit/CompactControls.swift` | Rejected | Imported playback controls are presentation/playback work. |
| `Packages/SessionKit/Sources/SessionKit/InMemoryRepository.swift` | Rewritten minimally | Separate revision/layer/interjection stores and atomic idempotent import; no local-capture replacement. |
| `Packages/SessionKit/Sources/SessionKit/InterjectionCleanup.swift` | Reused and extended | Deterministic segment cleanup plus bounded nearest-context selection; immutable inputs/results. |
| `Packages/SessionKit/Sources/SessionKit/Models.swift` | Rejected | Historical imported-reply target and private-capture mutations were not copied; sharing types live in `SharingModels.swift`. |
| `Packages/SessionKit/Sources/SessionKit/Protocols.swift` | Rewritten minimally | Added revision persistence and atomic imported-layer operations only. |
| `Packages/SessionKit/Sources/SessionKit/SessionEngine.swift` | Rejected | Explicitly forbidden; no playback/session runtime behavior changed. |
| `Packages/SessionKit/Sources/SessionKit/SharingModels.swift` | Rewritten | Immutable revisions, typed representations/provenance, package model, and distinct recipient-local layer/note models; reply graph types removed. |
| `Packages/SessionKit/Sources/SessionKitAudio/AudioAdapters.swift` | Rejected | Explicitly forbidden playback/audio surface. |
| `Packages/SessionKit/Sources/SessionKitAudio/InterjectionAudioCleanup.swift` | Deferred | Audio waveform rewriting is not needed to verify deterministic text cleanup and would cross into audio-owned work. |
| `Packages/SessionKit/Sources/SessionKitPersistence/SQLiteSessionStore.swift` | Rewritten minimally | Existing JSON record table stores new kinds atomically; no schema-version bump, destructive migration, or flattening. |
| `Packages/SessionKit/Sources/SessionKitSharing/InterjectionPackageArchive.swift` | Reused and hardened | Strict JSON shape, deterministic digest/archive, archive bounds, explicit malformed/unsupported/tampered outcomes, no reply fields. |
| `Packages/SessionKit/Sources/SessionKitSharing/PortableArticleAnchorResolver.swift` | Reused and extended | Conservative quote resolver plus distinct wrong-source/ambiguous/context-only aggregate status. |
| `Packages/SessionKit/Tests/SessionKitTests/SessionKitCoreTests.swift` | Rejected as edit target | Existing core suite was run unchanged; focused sharing evidence lives separately. |
| `Packages/SessionKit/Tests/SessionKitTests/SharingTests.swift` | Rewritten and expanded | Fifteen tests cover the packet’s positive and falsification requirements using stable fixtures. |
| `Site/assets/site.css` | Rejected | Site is explicitly forbidden/unrelated. |
| `Site/index.html` | Rejected | Site is explicitly forbidden/unrelated. |
| `Site/share/index.html` | Rejected | Hosted share landing page is out of scope. |
| `SpokenMarginsNative.xcodeproj/project.pbxproj` | Rejected | Generated/project integration is explicitly forbidden. |
| `SpokenMarginsNative.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | Rejected | App project does not consume the new product in this slice. |
| `docs/interjection-sharing-and-article-acquisition.md` | Rewritten | Replaced broad historical app/reply claims with exact package-core boundary, deferrals, audit, and stopping rules. |
| `project.yml` | Rejected | Explicitly forbidden; no app target linkage. |
| `scripts/deploy-spoken-margins-site.sh` | Rejected | Hosted deployment is unrelated and forbidden. |
| `scripts/validate-contracts.py` | Reused and extended | Registered valid package/revision fixtures and negative fixture family; validation fails if a negative fixture unexpectedly passes. |

New current-only files are `SharingFoundation.swift` (reviewed builder/import service) and two negative fixtures (`unsupported-schema.json`, `privacy-redaction-disabled.json`). They close packet requirements that the historical implementation did not fully cover.

## Implemented

- #17 package core: immutable sender-reviewed share revisions, typed text-only/cleaned-audio selection, package builder, deterministic `.spokenmargins` archive, portable `preview.md`, SHA-256 integrity, strict privacy assertions, and explicit invalid-package errors.
- #18 import core: verified packages map package provenance IDs to distinct recipient-local IDs and persist as separate imported commentary layer/interjection record kinds. Duplicate digest import is stable and idempotent in both in-memory and SQLite repositories.
- #67 core: deterministic aligned-token filler cleanup, isolated “you know” handling, pause decisions, individually restorable decision IDs, substring safety, immutable private input, nearest 500-character context bounds, and conservative article anchor resolution.
- #81 package-level reconciliation: historical file inventory, current-source extraction, forbidden-surface audit, automated checks, exact deferrals, and local commits.
- Default package fields cannot carry raw capture, unselected/private representation, full source text/audio, diagnostic objects, API fields, or local paths. Selected cleaned audio is renamed to an archive-relative path.
- Unsupported schema, malformed archive, malformed JSON, attachment mismatch, invalid privacy proof, and digest mismatch are deterministic failures before import.

## Verified

- Both valid fixture families pass their schemas, both negative fixtures fail their schema as expected, and the validator would fail if a negative fixture passed.
- Identical manifest/audio input produces an identical digest and byte-identical archive; round-trip restores the verified manifest and selected audio.
- Hostile test packages distinguish malformed archive, malformed JSON, unsupported schema, tampered digest, and missing privacy proof.
- Text cleanup removes an aligned `um` but preserves `umbrella`; semantic “you know” is retained; an individual proposed edit can be restored without changing the private input.
- Anchor context is bounded to the closest 500 characters on each side.
- Import uses distinct local primary keys, never writes local `Interjection` records, and returns a stable duplicate result without adding records.
- SQLite persists the imported layer/note as separate record kinds with no quarantine or destructive migration.
- Wrong-source, ambiguous repeated quote, context-only, exact-edition, exact-quote, and normalized-quote outcomes remain distinct.
- No forbidden path changed between `9dedf3b` and implementation SHA `56b15cf`.

## Deferred

- #17: in-app revision editor, sender field/attachment preview UI, share-sheet/file-type registration, and ordinary-user enablement.
- #18: recipient confirmation UI, source acquisition/matching orchestration, layer controls, cueing, commentary playback, Now Playing ownership, return-to-source behavior, and diagnostics/export UI.
- #67: cleaned-audio waveform rendering/preview, recipient-specific podcast/transcript placement, and broader held-out anchor benchmarks.
- #68: all accessible, provenance-aware Timeline presentation.
- #81: app-level and product-owner flow validation after the above integrations; package-level historical reconciliation is complete.
- #19: reply targets, child/reply fixture, parent resolution, forks, and recursive conversation behavior. `parentPackageDigests` is stored only as opaque provenance by this core.
- Trust/rights: the digest is unsigned integrity only. External distribution remains blocked on the separate rights/provenance and sender-trust decisions.

## Rejected

- Historical app/UI, compact controls, widget, share extension, site/deployment, project generation, runtime capability enablement, visible article acquisition, and later playback/triage changes.
- Historical changes that inserted imported commentary into private `Interjection` target types or added reply fields to private capture records.
- Wholesale cherry-pick/merge of `493af50` or `codex/sharingV1`.

## Commands and results

### Preflight and baseline

```text
git status --short --branch
git rev-parse HEAD
git rev-parse main
git rev-parse codex/testflight-triage
git rev-parse codex/sharingV1
git log --oneline --decorate -8
```

Result: clean `codex/sharing-next`; starting values recorded above. `main` and sharing were identical, so no main-to-sharing merge was needed. Triage’s additional commits were not an accepted release on `main` and were not imported.

```text
./scripts/bootstrap-python-tools.sh
.venv/bin/python scripts/validate-contracts.py
.venv/bin/python scripts/validate-surface-contracts.py
swift build --build-tests --package-path Packages/SessionKit
```

Baseline result before edits: PASS. Contract validation passed; surface validation passed; SessionKit test build completed in 24.24 seconds. No pre-existing failure was observed.

### Historical audit

```text
git show --stat --summary 493af50
git diff --name-status codex/sharing-next...codex/sharingV1
git log --oneline --reverse codex/sharing-next..codex/sharingV1
```

Result: `493af50` changed 52 files with 4,478 insertions and 86 deletions. Later historical commits were `ee52649`, merge `14384d4`, and playback fix `8764c95`; they were not extracted. The file disposition table above records the branch-diff inventory.

### Intermediate falsification correction

The first new focused run executed 13 tests and reported four assertion failures:

```text
SharingTests.swift:131 XCTAssertFalse failed
SharingTests.swift:132 XCTAssertFalse failed
SharingTests.swift:133 XCTAssertFalse failed
SharingTests.swift:379 XCTAssertEqual failed: ("resolved") is not equal to ("ambiguous")
Executed 13 tests, with 4 failures (0 unexpected).
```

Cause: three privacy assertions matched the required redaction-proof key names (`diagnosticsOmitted`, `fullSourceTextOmitted`, `rawTranscriptOmitted`) rather than prohibited payload fields. The repeated-quote input also gave one candidate a better suffix score, so it was correctly resolved instead of ambiguous. The test inputs were corrected to search for payload field names and to create a true equal-context tie; implementation behavior was not weakened. The immediate rerun passed 13/13. Two additional boundary tests were then added, producing the final 15-test suite.

### Final verification

```text
git diff --check
./scripts/bootstrap-python-tools.sh
.venv/bin/python scripts/validate-contracts.py
.venv/bin/python scripts/validate-surface-contracts.py
swift build --build-tests --package-path Packages/SessionKit
swift test --package-path Packages/SessionKit --filter SharingTests
swift test --package-path Packages/SessionKit
```

Result:

- `git diff --check`: PASS, no output.
- Python bootstrap: PASS.
- Contract validator: PASS (`Validated 22 Supertonic files. Contract validation passed.`).
- Surface validator: PASS.
- SessionKit test build: PASS (`Build complete!`).
- Focused `SharingTests`: PASS, 15 tests, 0 failures.
- Full SessionKit suite: PASS, 165 tests, 0 failures (138 core, 15 sharing, 5 SQLite safety, 4 Supertonic, 3 trace replay).
- App build: not applicable. No app, project, extension, widget, or generated-project file changed, and the app does not consume `SessionKitSharing` in this disabled package-only slice.
- Broad UI routes: not run, as directed for this package-level slice.

The first non-incremental compile emitted one non-failing deprecation warning for synchronous `AVURLAsset.duration` inspection in the archive safety check. The final required build and tests passed. Migrating archive media inspection to async `AVAsset.load(.duration)` should accompany future app integration rather than introducing an asynchronous app API in this isolated core.

## Local commits and repository mutation

- `745a891` — `Add sharing package contracts and fixtures`
- `56b15cf` — `Add sharing package and imported-layer core`
- This evidence file is committed separately after verification.

No push, merge, pull request, issue close, GitHub mutation, external deployment, or app enablement occurred.

## Human validation

Not requested and not performed. This package-level slice is `implemented` and `verified`; it is not `human_validated`.

## Recommended next bounded step

Keep ordinary-user sharing disabled. The next safe work on `codex/sharing-next` is a separate #17 sender review/field-preview slice that consumes the verified builder without adding recipient playback or #19 reply behavior. Before app integration, reconcile any accepted TestFlight triage release from `main`, add required ZIPFoundation app attribution, and run the applicable simulator/device builds. #68 presentation should follow the one-way #17/#18 app path, and #19 should not begin until that foundation is implemented and verified.
