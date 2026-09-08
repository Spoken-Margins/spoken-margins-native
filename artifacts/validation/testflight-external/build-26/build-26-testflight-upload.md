# Build 26 internal TestFlight handoff

Status: uploaded successfully, processed by Apple, and confirmed Testing in the internal Margins group with six testers. No external distribution or Beta App Review submission.

## Identity and acceptance

- Version: 0.1 (26).
- Exact candidate source: `9c967793e7a0e86c26a3030390818e87d830723b`.
- Accepted runtime before numbering: `cd2bf54b5b6e11d7bce3036861f19aad1978636d`.
- Source lane: `codex/provisional-next`.
- Owner acceptance: `artifacts/validation/gate-1/2026-09-08-build-26-acceptance.md`; owner reports validation passed and requests internal distribution.
- Bundle: `com.spokenmargins.native`; team `J8SWC6J3VY`.
- Supported devices: iPhone and iPad, iOS/iPadOS 18.0 or later. Vision document enhancement and local model capabilities retain their existing newer-OS/device requirements.
- Intended destination: existing internal `Margins` group, six testers observed in App Store Connect before upload.

## Scope

This candidate includes the accepted post-Build-25 preparation, completion/replay, Library, source/PDF import, playback-control, optional audio mixing, and Follow prompt work. Follow discovery now handles redirected feed aliases, deduplicates equivalent candidates, rechecks subscriptions after discovery, and remembers the source when a suggestion is accepted. Developer diagnostic recording remains opt-in.

External TestFlight, Beta App Review, main promotion, new Watch functionality, and new product work are out of scope. Owner acceptance is recorded for this candidate; this handoff does not invent separate per-device or per-flow acceptance results.

## Upgrade, sample, and diagnostics

Upgrade through TestFlight without resetting the Library. Preserve existing items, audio, sessions, and Margins. No reset is required for this release. For a deliberately disposable test library, Settings → Developer tools → Reset Library and Load Sample is destructive and loads the seeded sample; do not use this on the owner's content-heavy Library. Existing sample references include **Welcome to Spoken Margins** and **You Can't Inspect the Pill**.

Use Settings → Copy Privacy-Safe Diagnostics after a failure. For responsiveness/preparation/playback investigations, use the opt-in Developer diagnostic recording and its export. Include device/OS, item, observed behavior, and Build 26 when reporting a problem.

## Owner and distribution checklist

- [x] Owner reports Build 26 validation passed.
- [x] Internal distribution explicitly authorized.
- [x] Full release verification passed.
- [x] Signed archive and App Store export verified.
- [x] Upload succeeded and Apple processing completed.
- [x] Build 26 available to internal Margins group.

Existing historical reports remain preserved in their original evidence files. This release decision supersedes their pending acceptance status for the current candidate; it does not rewrite historical failures or claim that unrelated lost historical data was recovered.

## Archive and export evidence

- Release archive succeeded: `.build/release-artifacts/build-26/archive.log`.
- Archived app and all three embedded extensions report 0.1 (26), minimum iOS 18.0, and pass strict signature verification.
- App Store Connect export succeeded: `.build/release-artifacts/build-26/export-system-path.log`.
- Exported IPA SHA-256: `a11c79926eabdc2bbf64e845bb47bfc9f654353c97cf5fc5c18f05d4ba4570a9`.
- Exported app and extensions pass strict signature verification, with `beta-reports-active = true` and `get-task-allow = false`.
- First export failed during IPA packaging because Apple's rsync invoked an incompatible Homebrew rsync (`--extended-attributes: unknown option`). Rerunning the same archive with `PATH=/usr/bin:/bin:/usr/sbin:/sbin` succeeded. The original failure remains in `.build/release-artifacts/build-26/export.log`; no runtime change was needed.

## Release verification

Full `--plan release` passed at exact candidate source `9c967793e7a0e86c26a3030390818e87d830723b`: 425 app/adapter/UI tests, including the real speech canary and physical scrubber drag. Fast checks also passed. Manifest: `artifacts/test-runs/20260908-100107-133593-release/manifest.json`; input SHA-256 `3846876bfc270c0f7133ab18d505932e2702753b50b3f08e949072ec25506bcb`. No source changes occurred between verification and archive upload.

## Upload

Xcode reports `Upload succeeded` at 10:28:42 Eastern on 2026-09-08. Chrome shows Build 26 processing, created at 10:28 AM. Upload evidence: `.build/release-artifacts/build-26/upload.log`. App Store Connect build ID: `085bcaaf-bffa-4824-8964-f5d32210d73e`.

Apple reported a non-blocking missing ONNX Runtime dSYM warning for UUID `CDAE680A-26DA-32CE-9699-80A67B5BA0AD`; upload succeeded. Framework crash symbolication may be limited. The internal Margins group's existing distribution policy is Automatic for Xcode Builds.

The exact uploaded source is preserved by `testflight/0.1-build-26`; `codex/testflight-triage` was advanced by fast-forward to that exact source after successful upload.

## Final Chrome confirmation

On 2026-09-08, the Margins group's Builds page showed **Internal Group · 6 Testers · 13 Builds** and **Build 0.1 (26): Testing**. Automatic internal distribution completed successfully. Group page: https://appstoreconnect.apple.com/teams/e6c69191-84a0-4c60-a714-a2475ac42c17/apps/6792790885/testflight/groups/464d1674-98b4-4322-94d3-fb1eb152710e/builds .

Build 21 remains the external baseline. No external group assignment, tester membership change, Beta App Review submission, or main promotion was performed.
