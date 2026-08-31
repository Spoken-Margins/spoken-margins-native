# Build 23 internal TestFlight upload and product-owner handoff

Status: uploaded successfully, processed by App Store Connect, and available to
the internal `Margins` group; not added to `External Beta`, submitted for Beta
App Review, or `human_validated`.

## Candidate

- Upload date: 2026-08-30
- Marketing version/build: 0.1 (23)
- Source commit: `8bca9340ec810fe7f227396b8e7b2c3f10448b6a`
- Integrated Build 23 base: `10f7fd192f59f1fc8dc024d6defda2c2f41b7693`
- Team: `J8SWC6J3VY`
- Bundle: `com.spokenmargins.native`
- Supported devices: iPhone and iPad on iOS/iPadOS 18.0 or later
- Internal group: `Margins`, six testers

## Release scope and boundaries

This is the integrated Build 23 candidate: the quality-of-life program, private
experience overhaul, one-way sharing foundation, and inherited verified Build
22 seek patch. The final delta streamlines sender sharing: immediate top actions,
Select All/None, tap-to-include cards, first-share automatic-cleanup consent and
remembered `Clean selected` default, reversible auto-applied cleanup, compact
plain-text transcript editing, collapsed anchors, optional recipient preview,
and direct sharing after background package verification.

The product owner authorized this internal-only upload before the separate Build
22 human decision. That exception does not accept Build 22, authorize external
distribution, clear issue #14's rights/provenance gate, or establish any
`human_validated` product flow. Co-op replies, accounts, hosted storage, public
distribution, remote revoke, AI synthesis, and new Watch behavior remain out of
scope.

## Verification and upload evidence

- Contract validator: pass; 22 Supertonic files validated.
- Surface-contract validator: pass.
- SessionKit test build: pass.
- Final sender-cleanup delta: 9 focused app tests passed, 0 failed on the clean
  candidate commit.
- Clean iOS Simulator test build: pass.
- Release archive: pass.
- Archived identity: version 0.1 (23), arm64, iOS 18.0 minimum.
- App, extensions, and embedded `onnxruntime.framework` strict signature
  verification: pass.
- Non-uploading App Store Connect export: pass after constraining `PATH` to use
  Apple's `/usr/bin/rsync`; the prior failure was a local Homebrew/openrsync
  option mismatch, not a package defect.
- Exported IPA SHA-256:
  `67de0b63aba7562f7b0815e4ebee8b7a41096988503e85e2e48a731d340e9c24`.
- Exported identity: Apple Distribution, Store provisioning,
  `beta-reports-active = true`, `get-task-allow = false`.
- Xcode upload: `Upload succeeded`; package analysis and SPI analysis passed.
- App Store Connect processing: complete; Build 23 reports `Ready to Submit`.
- Internal distribution: Build 23 is assigned to `Margins`, with six testers and
  a 90-day expiry.

Apple emitted the known non-blocking symbol-upload warning because the upstream
`onnxruntime.framework` has no matching dSYM for UUID
`ED3DCE5D-3741-33BE-B247-42318E55C195`. The application upload and processing
succeeded; crashes inside that framework may have limited symbolication.

The full integrated Build 23 verification matrix remains recorded under
`artifacts/validation/build-23/automated-verification.md`; its base runtime was
`10f7fd1`. The focused checks above cover the final `8bca934` sharing delta and
release package. They establish `verified`, not `human_validated`.

## Reset, samples, and diagnostics

- Upgrade first without resetting. Existing library items, prepared media,
  private Margins, stars/notes, and imported Shared Margins should remain.
- Clean reset: delete the TestFlight app and reinstall Build 23. When the debug
  developer route is present, Settings > Developer > Developer tools > Reset
  Library and Load Sample performs an intentional full reset.
- Seeded sample: the bundled **Welcome to Spoken Margins** item.
- Additional sharing sample: create a linkless pasted-text item with at least
  two Margins so Select All/None, cleanup consent, and explicit cleanup can be
  compared.
- Diagnostics: Settings > Copy Privacy-Safe Diagnostics. In debug builds,
  Settings > Developer > Developer tools > Refresh Diagnostics also exposes the
  detailed diagnostic families listed in the Build 23 product-owner handoff.

## Product-owner checklist

Only the product owner can mark these flows `human_validated`. Record PASS or
FAIL plus device, OS, and brief notes.

- [ ] Install Build 23 from TestFlight over the existing app and confirm library,
  prepared media, private Margins, stars/notes, and imported layers remain.
- [ ] Open Share with many Margins and confirm top actions, Select All/None,
  tap-to-include cards, starred defaults, and fast navigation are usable without
  scrolling through instructions.
- [ ] Accept the first-share cleanup prompt; confirm `Clean selected` is
  remembered on the next share and eligible included Margins clean automatically.
- [ ] Turn `Clean selected` off and confirm only auto-applied cleanup is undone;
  explicitly clean a Margin and confirm that explicit edit survives later
  preference toggles.
- [ ] Review one Margin at a time; confirm the transcript reads normally,
  word/pause edits and Undo/Redo work, anchors stay collapsed, unavailable
  representations are hidden, and Restore Original appears only after an edit.
- [ ] Share directly and confirm background verification reaches one native
  system share sheet without a mandatory second preview/review pass.
- [ ] Exercise optional Recipient Preview and confirm package-affecting edits
  invalidate stale preview bytes before sharing.
- [ ] Transfer the `.spokenmargins` file to a second supported installation;
  confirm integrity disclosure, explicit import, no autoplay, separate imported
  layer, and Companion/Guided behavior.
- [ ] Exercise playback, seek convergence, rate changes, background/foreground,
  Lock Screen actions, real podcast placement, accessibility, iPad layout,
  offline fallback, and privacy-safe diagnostics using the full Build 23
  checklist.

Product-owner result: Pending.

Product-owner notes: Pending.
