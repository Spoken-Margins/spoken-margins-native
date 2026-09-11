# Internal-to-external readiness candidate — September 11, 2026

> Superseded source, September 11 follow-up: the owner subsequently requested generated-scene scrolling/Timeline fixes and improved podcast-description chapter extraction. The archived IPA and verification below identify the earlier candidate only. The current working tree requires a new release gate and archive before upload; development verification for the follow-up is recorded separately.


Status: engineering implementation, full release verification, iPad UI verification and signed export complete. Build 27 is prepared locally for the internal rollout sequence. This record is not an upload or human-validation claim.

## Identity and release sequence

Lane: `codex/provisional-next`. Base commit: `ec2155707b3f416932123c4bf56d939fb209d4ba`, plus the preserved second-edition work and this task's uncommitted fixes. A base commit alone does not identify the candidate; the candidate verification input SHA-256 is `2aa8a3706e0e468402e88c1b30fffc2bb7504c9f27be20a3935d10c95e696f71`. Its complete verification-input source snapshot and per-file hashes are preserved in `.build/release-artifacts/build-27/candidate-source.tar.gz` and `source-identity.json` (snapshot SHA-256 `1d3f674ed3aaa5813ca8b119740862be0551eb8eaa7c84ff7a734acf2d3d479d`). This remains an uncommitted working-tree candidate, not a claim that the base commit contains these fixes. Local candidate version is 0.1 (27). This is NOT distributed Build 26 at `9c967793e7a0e86c26a3030390818e87d830723b`.

Live App Store Connect reconciliation completed in the owner's signed-in Chrome tab on September 11: Build 26 is still the newest upload, Complete, created September 8. The internal Margins Builds page shows Build 26 as Testing; the group now has seven testers. Build 21 remains Testing with External Beta. Build 27 is absent and is the next observed available upload number. The earlier sign-in/locked-Mac interruption is resolved for browser inspection. No new upload, group assignment, Beta App Review submission, remote Git mutation or baseline advancement has occurred.

Evidence pages: [iOS build list](https://appstoreconnect.apple.com/teams/e6c69191-84a0-4c60-a714-a2475ac42c17/apps/6792790885/testflight/ios), [internal Margins builds](https://appstoreconnect.apple.com/teams/e6c69191-84a0-4c60-a714-a2475ac42c17/apps/6792790885/testflight/groups/464d1674-98b4-4322-94d3-fb1eb152710e/builds).

Required sequence: finish implementation and verification; preserve the exact candidate source; verify archive/export and reconcile the upload number; upload to internal Margins when authorized; confirm Apple processing and internal Testing state; owner exercises this candidate and accepts the bounded sharing policy; then prepare/submit external review with accurate metadata. Do not treat an internal upload or approval of a different candidate as external readiness.

## In scope

- Skim completion: immediate resume at the same destination preserves the pending navigation transaction; a different target/destination still supersedes it.
- #110: primary and explicit imported-Margin pause/resume, system transport ownership, paused-state wording, natural completion and once-only Return to Source.
- #112: source and assistant/summary-turn coordinate spaces remain distinct in Timeline; parent/child grouping, persisted anchor and export evidence.
- #95: bounded long-response composer, action above text, import starts playback; retain explicit import-only choice in the separate Paste Response sheet.
- #98: opening-preparation progress remains visible alongside an actionable Listen now route.
- #14: acoustic opt-out covers stored edition spines as well as per-note signatures; verified-preview rights, attribution, excerpts, provenance and recipient-copy disclosures; new-install private export omits full source text by default while preserving existing saved preferences.
- Preserved second-edition native redesign, written capture and other work present at task start. Its full owner checklist remains applicable.

Out of scope: Watch expansion, new cloud/accounts, co-op replies, public publishing, commercial creator editions, blanket rights or legal-permission conclusions. This is not a reimplementation of the wider GitHub roadmap.

## Setup, reset and sample content

Supported: iPhone and iPad, iOS/iPadOS 18.0+. Automated destinations were iPhone 17 Pro / iOS 26.5 and iPad Pro 11-inch (M5) / iPadOS 26.5, as detailed in the verification record. Newer-device/OS local intelligence requirements remain conditional; deployment targets do not prove those capabilities.

Keep the personal Library intact. No reset is required for an in-place update. For a disposable Simulator library only, use Library → Settings → Developer tools → Reset Library and Load Sample and confirm Reset Library. Tests use explicit isolated fixtures, not the owner's real Library. Seeded material includes You Can't Inspect the Pill and synthetic source/assistant notes; actual-audio tests create temporary tone files for source and imported Margin players. Those tones prove advancement/freeze/return, not human speech quality.

Diagnostics: Library → Settings → Copy Privacy-Safe Diagnostics. For a physical-device reproduction, opt into Record Device Diagnostics, reproduce once, then export. Keep exact build/input identity, item/session, device/OS, steps and observed audio behavior with the checklist below. Do not include credentials or private source material in public issue comments.

## Product-owner checklist

Record device, OS, exact candidate, date, pass/fail and observations for every row. Only the product owner can establish `human_validated` status.

| Flow | Expected result | Owner result |
| --- | --- | --- |
| Existing Library upgrade | Items, source positions, sessions, recordings, written Margins and imported layers survive in-place update | Pending |
| Imported voiced Margin on podcast/local audio | Listen pauses source; primary Pause freezes Margin; Play resumes the same Margin; source stays paused | Pending |
| Imported voiced Margin on native text | Same transport ownership in manual Companion and opt-in Guided modes | Pending |
| Return/completion | Return to Source and natural Margin completion restore the appropriate source state exactly once | Pending |
| Remote audio | Lock Screen/Control Center play/pause, headphone removal and interruption act on the Margin; returning restores source controls | Pending |
| Optional mixed audio | With another audio app playing, check imported-Margin pause, completion and return with mixing and Lower Background Audio both on and off; audible balance and restoration remain owner checks | Pending |
| AI response import | A realistically long response has bounded text area and reachable action; Import and play starts without another transport tap | Pending |
| AI response notes | Notes at 0%, 25%, 50% and near the end stay under the correct response after reload and export; ordinary source notes remain at source positions | Pending |
| Preparation recovery | Open an item while its opening audio is preparing; Listen now remains available and useful; no indefinite trapped screen | Pending |
| Rights and preview | Review `docs/external-testflight-sharing-decision.md`; accept or amend the bounded policy and visible copy | Pending |
| Acoustic opt-out | Disable acoustic evidence before preview; no per-note or edition-wide acoustic signatures leave in the file | Pending |
| Package review/import | Review excerpts/voices/derivatives, change a selection after preview, rebuild, import on another owned device; import itself never autoplays | Pending |
| Privacy-minimal export | A fresh preference state leaves full source text off; deliberately enabling it is visible before export | Pending |
| Second edition | Complete the preserved native redesign checklist at `artifacts/validation/gate-1/second-edition/product-owner-checklist.md` | Pending |

## Verification record

The initial fast plan passed at `artifacts/test-runs/20260911-115457-361578-fast/manifest.json`.

The initial app run (`20260911-115541-410496-app`) retained one new-test failure: the test assumed presentation/store return order was capture order. The correction selects notes by exact identity and compares persisted records by ID; it does not relax target or offset assertions.

The initial adapter run (`20260911-120151-039848-adapters`) retained one new-test failure: it expected a real source player to publish playing synchronously on resume, despite the valid starting transition. The correction waits within a bounded deadline and still requires actual source advancement plus playing state.

The intermediate release run `20260911-120431-106799-release` was deliberately interrupted before completion while a stale source-resume cleanup issue was corrected. It is not a release pass.

The final-numbered first release attempt `20260911-121947-294665-release` passed fast checks and build-for-testing, but the XCTest harness remained waiting to pair with the launched host and executed no recorded tests. The app's sampled main thread was idle in its event loop and no XCTest bundle appeared in its loaded-image sample. This attempt was interrupted and retained; the disposable Simulator was restarted for one unchanged-source retry. This is an infrastructure diagnosis, not product verification.

Before final numbering/contrast correction, 405 app-hosted tests passed (`20260911-121125-691802-app`). Three focused real-player and long-response UI tests also passed (`20260911-readiness-focused`). These are intermediate support; the final release run must cover the numbered source.

The unchanged-source retry `20260911-122449-075229-release` started normally after the Simulator restart. It found a real Skim/source-resume regression in `LocalAudioListeningPackageTests.testExactAudioImportActivatesMapResolvesMarginsAndSurvivesReconstruction`: source audio remained at 5,000 ms with `media_seek_failed:media_seek_superseded` instead of advancing. The run was interrupted after diagnosis to fix the affected boundary; it is not a release pass. A direct regression exercises navigation followed synchronously by resume at the same destination, plus a different-destination negative case.

The direct regression failed before the fix (`20260911-readiness-seek-before-retry`) and passed afterward alongside all imported-Margin transport and local-audio reconstruction checks: six tests, zero failures (`20260911-readiness-seek-after`). The initial direct pre-fix attempt also encountered the host-attachment problem and was interrupted before a fresh-Simulator retry reproduced the expected assertion failure.

`20260911-123335-144663-release` encountered another host-attachment stall before recorded tests. It was retained as incomplete. The dedicated Simulator app and UI runner were uninstalled so the final run installs fresh test hosts; archive/build operations complete before the next run. The possible interaction with concurrent Xcode builds is an inference, not an established application defect.

The clean-host run `20260911-123712-112738-release` executed normally and passed the corrected audio checks. The new assistant-anchor test exposed an isolated-fixture omission: its default voice needed first-use consent before starting a session. Assigning the system-voice property alone was insufficient because a pending first-use choice remained; `20260911-123914-731499-release` retained that same fixture failure. The final fixture completes the actual decline/continue-with-system-voice path, matching its Noop audio intent without bypassing or changing the application’s consent gate. The corrected test passed independently from a fresh installation in `20260911-readiness-anchors-fresh`. This incomplete run is retained; it is not a release pass. This last correction changes test code only; the final archived runtime is unchanged.

Final full release passed at `artifacts/test-runs/20260911-124304-179832-release/manifest.json` on iPhone 17 Pro / iOS 26.5: **444 tests (416 app/audio and 28 UI), zero failures or skips**. Fast gates also passed, including 285 passed package tests, browser checks, runner tests, contract/surface/inventory validators, and bundle checks. One package test is the explicitly allowed held-out podcast-corpus skip, run separately by its benchmark script. No resolver/benchmark algorithm changed in this task.

The final source digest matches the preserved candidate snapshot. The long-response screenshot is at `artifacts/validation/internal-external-readiness/screenshots/final-phone/9B735F16-D2DF-4280-BB6F-898DB6EC38F7.png`; it confirms a bounded editor and legible action above the text. The original pre-contrast-correction capture remains in the parent folder as intermediate evidence.

Final iPad UI verification passed at `artifacts/test-runs/20260911-130630-007201-ui/manifest.json` on iPad Pro 11-inch (M5) / iPadOS 26.5: **11 tests, zero failures or skips**, including the long-response/autoplay route, accessibility layouts, physical scrubber dragging and written capture. The inspected tablet capture is `artifacts/validation/internal-external-readiness/screenshots/final-ipad/E01B8A53-2937-4A66-BE70-031E21ECD714.png`; the action is legible above the bounded editor. The pre-Skim archive is retained separately under the final superseded-evidence section.

## Final candidate archive and export

- Signed Release archive and generic iOS Simulator build passed: `.build/release-artifacts/build-27/archive.log` and `generic-simulator-build.log`.
- App Store export passed using `Config/ExportOptions-TestFlight.plist`, whose destination is export only: `.build/release-artifacts/build-27/export.log`.
- IPA: `.build/release-artifacts/build-27/export/SpokenMarginsApp.ipa`; SHA-256 `a6f51bc6c1781b3a3618b8a4ab7552e87c5d472f6f65defd8ac7621806c85ee5`.
- Main app and all three extensions report 0.1 (27), minimum iOS 18.0, and pass strict signature verification. Exported bundles have `get-task-allow = false` and `beta-reports-active = true`. Machine-readable checks: `.build/release-artifacts/build-27/bundle-verification.json`.
- Archived Safari preprocessing and document/share-extension bundle contracts passed.
- The only source change after archiving is the test fixture's first-use voice choice in `Gate1AppModelWorkflowTests.swift`. Per-file comparison in `source-identity.json` versus `archive-source-identity.json` confirms every application, package, resource, configuration and project file is unchanged. The final test-source snapshot is preserved alongside the archive.
- Proposed internal TestFlight notes: `artifacts/validation/internal-external-readiness/what-to-test.md`. They have not been posted.
- Live number reconciliation is complete. Before actual upload, preserve the exact source in the release Git lane and establish uploader authentication, then follow the recorded internal-then-external sequence. The owner's device/product and #14 policy decisions remain required before external submission.

## Superseded archive evidence (before Skim correction)

- Signed Release archive succeeded: `.build/release-artifacts/build-27-before-skim-fix/archive.log`.
- App Store export succeeded with `Config/ExportOptions-TestFlight.plist` (destination `export`, not upload): `.build/release-artifacts/build-27-before-skim-fix/export.log`.
- Exported IPA: `.build/release-artifacts/build-27-before-skim-fix/export/SpokenMarginsApp.ipa`; SHA-256 `36a5b95959b3c9e820d39720e83a60f4101d4f2159d3fecdc58c83000b7cdecf`.
- Main app and all three extensions report 0.1 (27), minimum iOS 18.0, and pass strict signature verification. Exported bundles have `get-task-allow = false` and `beta-reports-active = true`. Machine-readable checks: `.build/release-artifacts/build-27-before-skim-fix/bundle-verification.json`.
- Safari preprocessing and document/share bundle contracts passed against the archived app.
- Export emitted an Xcode account-token warning but succeeded with available signing material. Live App Store Connect authentication/upload readiness is not established by the successful export.
- No upload, processing confirmation, internal group assignment, external submission, commit, tag, remote push or baseline advancement occurred.

