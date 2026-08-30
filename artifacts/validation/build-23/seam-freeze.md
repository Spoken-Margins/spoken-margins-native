# Build 23 seam-freeze evidence

Status: the frozen seams and completed Build 23 experience are `implemented`
and automatically `verified`. Build 23 is not `human_validated`, and this
evidence does not authorize distribution.

## Candidate state

- Version/build: Spoken Margins 0.1 (23)
- Branch: `codex/build-23-release`
- Integrated sharing merge: `7d47876`
- Initial executable seam: `2a6fd9d`
- Expanded frozen projection seam: `fca95cb75b4ef6a1a10091c25433ed12615cf5eb`
- Frozen kickoff ref: `build-23-ultra-seam-freeze` at
  `4e87dcb5161eda1507e44be4cb6aa61cb357b630`
- Verified runtime candidate:
  `10f7fd192f59f1fc8dc024d6defda2c2f41b7693`
- Supported deployment: iPhone and iPad on iOS/iPadOS 18.0 or later
- Physical-device validation: pending

## Integration evidence

- `codex/experience-overhaul` entered `codex/quality-of-life-next` once at
  `9118c11`.
- The exact verified #84 patch and Build 22 evidence entered Build 23 at
  `81a7c11`; Build 22 remains a separate pending product-owner gate.
- `codex/sharing-next` entered Build 23 once at `7d47876`.
- Structural conflicts retained the experience navigation/composition, sharing
  archive/import/playback semantics, and the additive persistence union.
- `SessionKitSharing`, `SessionKitEPUB`, and `SessionKitFeeds` all remain in the
  unified package manifest and app target.
- Package locks and the Xcode project were regenerated from resolved manifests.
- All app and extension targets are versioned 0.1 (23).

## Frozen seam evidence

- The canonical sender stage order is Select, Review, Recipient Preview, Share.
- Sender and recipient UI can consume projections and dispatch actions without
  direct `Gate1AppModel` or persistence access.
- Recipient preview reads the actual written archive with
  `SpokenMarginsPackageArchive.read` and exposes that same verified file URL.
- Package-affecting sender state is fingerprinted; a mutation invalidates the
  preview and removes the share URL.
- Recipient-supplied imports retain their verified package while Add Source is
  shown and can reconcile the pending review on return.
- Imported layers expose integrity, resolution, enabled/muted state, reveal
  mode, inert proposal count, and Margin placement as a typed projection.

Focused app test:

```text
Build23SharingSeamsTests
  testSenderStageVocabularyIsFrozenInReleaseOrder: pass
  testRecipientPreviewComesFromVerifiedFileAndMutationInvalidatesIt: pass
Executed 2 tests, 0 failures.
```

The round-trip test writes a real text-only `.spokenmargins` file, verifies and
projects its recipient contents, asserts the old ready sheet is not substituted
for the new flow, then mutates the sender label and proves the preview/file URL
are invalidated.

## Automated checks completed before the freeze

| Evidence | Result |
| --- | --- |
| Contract validator after source integration | Pass |
| Surface-contract validator after source integration | Pass |
| `swift test --package-path Packages/SessionKit` | 220 executed, 219 passed, 1 intentional held-out benchmark skipped, 0 failed |
| `xcodegen generate` | Pass; generated project remained deterministic |
| Generic iOS Simulator build with frozen seam | Pass |
| Generic iOS device build with frozen seam | Pass |
| Focused Build 23 seam app tests after generation | 2 passed, 0 failed |
| `git diff --check` | Pass |

Final pre-Ultra verification ran on 2026-08-30. The intentional skip is
`testHeldOutPublicDomainPodcastAnchorCorpus`; its own test message requires
`scripts/run-podcast-anchor-benchmark.sh`, so it is not counted as a passing
local test. The final focused app result bundle is:

```text
/Users/colemiller/Library/Developer/Xcode/DerivedData/SpokenMarginsNative-frwvcspidefdamboxsgsdxxaxbwj/Logs/Test/Test-SpokenMarginsApp-2026.08.30_14-54-37--0500.xcresult
```

Both app builds succeeded with the pre-existing AVFoundation chapter-loading
deprecation warnings in `LocalSourceImporters.swift`; no new warning class was
accepted as release evidence.

## Ultra implementation and integration evidence

The steward started from a clean `codex/build-23-release` worktree and verified
that `HEAD` and `build-23-ultra-seam-freeze^{commit}` both resolved to
`4e87dcb5161eda1507e44be4cb6aa61cb357b630`. The frozen source tips still
resolved to quality/experience `9118c11`, sharing `de887f6`, and experience
source `b118e01`; none advanced during the work.

Exactly three named gates worked against non-overlapping ownership:

| Gate | Initial integration commit | Focused repair commit |
| --- | --- | --- |
| Sender experience | `5777e4f` | `13db95b` |
| Recipient experience | `96f2909` | `37dac54` |
| Experience polish | `820313c` | None |

The steward integrated only after all three handoffs, then committed root/model
wiring at `10f7fd1`. Ownership, duplicate-symbol, backend-request, contract,
shared-vocabulary, fixture, trace, and frozen-source audits were clean. Gate
agents did not use git, generate the project, run `xcodebuild`, or edit outside
their ownership. No backend request was recorded.

The final runtime composes one `Gate1AppModel` and one
`Build23SharingCoordinator`; replaces the old sender and recipient sheet hosts;
keeps a verified recipient-supplied package staged across Add Source; resumes
that pending import on return; never autoplays after import; and presents the
separate imported layer in both Item detail and Timeline. The sender's native
share surface receives only the URL of the exact archive used to produce the
verified recipient preview. A package-affecting edit removes that URL and
returns the state machine to Review.

`xcodegen generate` ran exactly once after integration. `project.yml`, the root
`Package.resolved`, and `Packages/SessionKit/Package.resolved` did not change;
the generated Xcode project changed only to register the new source and test
files.

## Final automated verification

Final verification ran on 2026-08-30 against runtime candidate `10f7fd1`.
Detailed command, result-bundle, coverage, and omission evidence is in
[`automated-verification.md`](automated-verification.md).

| Evidence | Result |
| --- | --- |
| Python tooling bootstrap | Pass |
| Contract validator | Pass; 22 Supertonic contract files validated |
| Surface-contract validator | Pass |
| Complete SessionKit suite | 220 executed, 219 passed, 1 intentional held-out benchmark skip, 0 failed |
| Build 23 focused app tests | 18 passed, 0 failed |
| Generic iOS Simulator build | Pass |
| Generic iOS device build | Pass |
| Sender scoped UI route | 1 passed, 0 failed |
| Recipient scoped UI route | 1 passed, 0 failed |
| Accessibility/layout scoped UI route | 1 passed, 0 failed |
| Final whitespace check | Pass |

The three scoped UI routes verified the sender's four stages, stale-preview
return, system share presentation, recipient Add Source return, explicit import
without autoplay, non-color imported provenance, compact Library layout, Add
Source action clearance, and Timeline clearance above the mini-player at the
largest accessibility text size with darker colors and reduced motion.

## Known limits and pending decisions

- Build 22 is not uploaded, accepted, or `human_validated`.
- Issue #14 is still the external-sharing policy gate.
- Real system share targets, security-scoped Files import, microphone/audio
  routes, podcast edition matching, Live Activity interaction, iPad product
  fit, VoiceOver quality, no-network behavior, and real-scale bulk preparation
  remain physical-device/product-owner checks.
- The final UI routes verify the absence of autoplay in the simulator fixture;
  audible behavior on physical hardware still requires product-owner evidence.
- The complete SessionKit suite intentionally skips
  `testHeldOutPublicDomainPodcastAnchorCorpus`; the external benchmark artifact
  remains the evidence for that held-out corpus.

## Freeze audit checklist

- [x] One authorized Build 23 branch contains all three source ancestries.
- [x] Build 22 and Build 23 validation states remain distinct.
- [x] Source branches are frozen and do not receive Build 23 follow-up work.
- [x] Sender/recipient action and projection vocabulary compiles.
- [x] Exact verified-archive preview has a focused regression.
- [x] Post-preview mutation invalidation has a focused regression.
- [x] Missing recipient source has an Add Source return seam.
- [x] Parallel file ownership and merge order are explicit.
- [x] Commands, snapshot fields, delegation modes, traces, and fixture policy are explicit.
- [x] Ultra thread implemented and automatically verified the Build 23 experience.
- [x] Exact verified file reaches the native system share surface.
- [x] Imported layers use non-color provenance and never autoplay in the scoped route.
- [x] Compact/large-type layout regressions have scoped route evidence.
- [ ] Product owner resolves #14 before externally enabled sharing.
- [ ] Product owner validates Build 22.
- [ ] Product owner validates Build 23 on supported devices.
