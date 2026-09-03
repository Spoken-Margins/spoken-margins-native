# Build 24 internal TestFlight upload and product-owner handoff

Status: uploaded successfully, processed by App Store Connect, and available to
the internal `Margins` group; not added to `External Beta`, submitted for Beta
App Review, or `human_validated`.

## Candidate

- Upload date: 2026-09-01
- Marketing version/build: 0.1 (24)
- Source commit: `a7c9e29ceab6831ff24a3376c4b21f1f9ae39e59`
- Build 23 release-record base: `a933cb92d119519549e75f0b27cb6fec36be8d37`
- Team: `J8SWC6J3VY`
- Bundle: `com.spokenmargins.native`
- Supported devices: iPhone and iPad on iOS/iPadOS 18.0 or later
- Internal group: `Margins`, six testers

## Release scope and boundaries

Build 24 is a bounded internal follow-up to Build 23. It declares Spoken
Margins as the owning app for `.spokenmargins` documents, exports the package
type as `public.content` and `public.data`, stamps outgoing system-share items
with `com.spokenmargins.package`, accepts the exact package through the Share
extension as a fallback, and consumes that app-group handoff into the existing
verified recipient import flow. Import and Add Source actions are pinned above
the bottom safe area so scrolling through package details is optional.

No Quick Look preview or YAML summary was added. The unrelated in-progress
canonical followed-source URL work in the product owner's worktree was excluded
from the clean candidate commit. Co-op replies, accounts, hosted storage,
external distribution, issue #14 acceptance, and any claim of product-owner
validation remain out of scope.

## Verification and upload evidence

- Clean detached candidate checkout: pass.
- Xcode project regeneration reproducibility: pass.
- Contract validator: pass; 22 Supertonic files validated.
- Surface-contract validator: pass.
- Complete SessionKit test build: pass.
- Recipient/share focused tests: 9 passed, 0 failed.
- Generic iOS device build: pass.
- Release archive: pass.
- Archived identity: version 0.1 (24), arm64, iOS 18.0 minimum.
- App and embedded-extension strict signature verification: pass.
- Non-uploading App Store Connect export: pass.
- Exported IPA SHA-256:
  `ae2c0907dfb86c77b13ddbb0d16b38826ed3ff268c4c88ae2331b613e66342c7`.
- Exported app and Share-extension identity: Apple Distribution, Store
  provisioning, `beta-reports-active = true`, `get-task-allow = false`, and the
  shared `group.com.spokenmargins.native` application group.
- Xcode upload: `Upload succeeded`; package and SPI analysis passed.
- App Store Connect processing: complete; Build 24 reports `Ready to Submit`.
- Internal distribution: Build 24 is assigned to `Margins`, with six testers and
  a 90-day expiry.
- External distribution: not assigned to `External Beta` and not submitted for
  Beta App Review.

Apple emitted the known non-blocking symbol-upload warning because the upstream
`onnxruntime.framework` has no matching dSYM for UUID
`914A233F-430A-34ED-A5DF-D5D34535E1A0`. The application upload and processing
succeeded; crashes inside that framework may have limited symbolication.

## Known issues and falsification checks

- Direct tap dispatch from Messages and AirDrop is owned by iOS and remains a
  physical-device product-owner check. Test with a newly generated packet after
  both devices install Build 24; an older message attachment may retain its old
  type metadata.
- iOS Share extensions cannot force-launch their containing app. The long-press
  Share fallback stores the exact packet safely; opening Spoken Margins then
  stages the normal recipient import.
- Finder drag-and-drop and **Share > Simulator** may fail before a file reaches
  the iOS Files app. The failure is reproducible with an ordinary text control
  file and is not evidence that `.spokenmargins` ownership failed. Use the
  [Simulator file-import workaround](../../../../docs/simulator-file-import-workaround.md)
  for developer testing; physical-device Messages and AirDrop checks remain
  authoritative.
- Stop and record FAIL if a fresh message attachment still opens YAML instead of
  Spoken Margins, Spoken Margins is absent from the long-press Share sheet, the
  fallback changes package bytes, Import requires scrolling, successful import
  returns to the prior screen, or playback starts automatically.

## Reset, samples, and diagnostics

- Upgrade first without resetting. Existing library items, prepared media,
  private Margins, stars/notes, and imported Shared Margins should remain.
- Clean reset: delete the TestFlight app and reinstall Build 24. When the debug
  developer route is present, Settings > Developer > Developer tools > Reset
  Library and Load Sample performs an intentional full reset.
- Seeded sample: the bundled **Welcome to Spoken Margins** item.
- Sharing sample: create a new linkless pasted-text item with at least one
  Margin, generate a fresh `.spokenmargins` packet, and send that new packet.
- Diagnostics: Settings > Copy Privacy-Safe Diagnostics. Package-handoff results
  are recorded under the `pendingSpokenMarginsPackage:*` and
  `lastSpokenMarginsPackageImport` diagnostic keys.

## Product-owner checklist

Only the product owner can mark these flows `human_validated`. Record PASS or
FAIL plus device, OS, and brief notes.

- [ ] Install Build 24 from TestFlight on both sender and recipient devices.
- [ ] Generate a new packet and send it in Messages; tap it once and confirm
  Spoken Margins opens directly into the recipient import flow.
- [ ] Long-press the same attachment, choose Share, and confirm Spoken Margins is
  available and accepts the packet.
- [ ] Exercise AirDrop and confirm the received file opens in Spoken Margins.
- [ ] Confirm Import or Add Source is visible without scrolling; optional details
  may still be scrolled.
- [ ] Complete import and confirm the app lands on item detail with the imported
  layer available and playback stopped.
- [ ] Confirm a malformed or renamed non-`.spokenmargins` file is rejected.
- [ ] Confirm the upgrade preserves existing library and sharing data.

Product-owner result: Pending.

Product-owner notes: Pending.
