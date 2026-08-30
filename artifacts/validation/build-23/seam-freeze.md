# Build 23 seam-freeze evidence

Status: Build 23 source integration and the sharing-experience seams are
`implemented` and automatically `verified` by the evidence recorded here. The
remaining Ultra experience work and the release itself are not yet `verified`
or `human_validated`.

## Candidate state

- Version/build: Spoken Margins 0.1 (23)
- Branch: `codex/build-23-release`
- Integrated sharing merge: `7d47876`
- Initial executable seam: `2a6fd9d`
- Expanded frozen projection seam: `fca95cb75b4ef6a1a10091c25433ed12615cf5eb`
- Frozen kickoff ref: `build-23-ultra-seam-freeze` after the documentation commit
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

## Known limits and pending decisions

- Build 22 is not uploaded, accepted, or `human_validated`.
- Issue #14 is still the external-sharing policy gate.
- The old dense sharing/import sheets remain registered until the Ultra steward
  integrates the new gate-local views.
- The experience source evidence has known layout rough edges assigned to the
  polish gate; no claim of product fit is made here.
- Real share targets, security-scoped files, microphone/audio routes, podcast
  edition matching, Live Activity interaction, and no-autoplay behavior remain
  physical-device/product-owner checks.

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
- [ ] Product owner resolves #14 before externally enabled sharing.
- [ ] Product owner validates Build 22.
- [ ] Ultra thread implements and verifies the completed Build 23 experience.
- [ ] Product owner validates Build 23 on supported devices.
