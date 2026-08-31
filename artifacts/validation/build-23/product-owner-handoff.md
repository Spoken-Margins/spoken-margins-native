# Build 23 product-owner validation handoff

Status: Spoken Margins 0.1 (23) is `implemented`, automated-`verified`, uploaded,
processed, and available to the internal TestFlight `Margins` group at runtime
SHA `8bca9340ec810fe7f227396b8e7b2c3f10448b6a`. It is not `human_validated`.
Every checklist result below is pending until the product owner records a
hands-on result for this exact candidate.

## Candidate and environment

- Build: Spoken Margins 0.1 (23)
- Branch: `codex/build-23-release`
- Runtime SHA: `8bca9340ec810fe7f227396b8e7b2c3f10448b6a`
- App Store Connect: processing complete; `Ready to Submit`; internal `Margins`
  group with six testers; not assigned to `External Beta`
- Supported devices: iPhone and iPad
- Supported OS: iOS/iPadOS 18.0 or later
- Recommended validation: an iPhone and an iPad, installed over an existing
  library first, followed by a clean-install pass if needed
- Product-owner result: Pending
- Product-owner device/OS: Pending
- Product-owner notes: Pending

Build 22 is a separate product-owner gate and issue #14 is a separate policy
decision. The product owner authorized this internal-only distribution as a
bounded exception. Do not distribute Build 23 externally or claim broader
acceptance while either remains unresolved, even if this checklist passes.

## In-scope flows

- A compact sender flow with selection and primary actions at the top, optional
  recipient preview, and direct system sharing after background verification.
- First-share consent for automatic cleanup, a remembered `Clean selected`
  default, and turning it off restoring only automatically cleaned drafts while
  preserving explicit per-Margin cleanup.
- Select All/None, tap-to-include Margin cards, one expanded editor at a time,
  readable inline transcript edits, collapsed anchors, and truthful cleanup
  summaries.
- Starred shortlist as a default distinct from authoritative Include choices.
- Rights/transport disclosures for reference, embedded-text, recipient-supplied,
  and app-authored items.
- One detailed Margin editor at a time, word/pause removal, Undo/Redo,
  Original/Cleaned/Text representations, bounded context, audio previews, and
  bounded batch preparation with cancellation/fallback.
- Preview derived from the exact written and verified `.spokenmargins` archive;
  package-affecting edits invalidate it; native share uses that same file.
- Recipient integrity/unsigned preview, explicit import/cancel, missing-source
  Add Source return without reopening the package, and no autoplay.
- Separate imported-layer provenance, enabled/muted state, reveal mode,
  Companion default, Item-detail and Timeline placement, persistence, and
  duplicate-package idempotency.
- Companion/Guided playback, conservative anchor handling, rate preservation,
  ordered chapter/Margin navigation, and authenticated Live Activity actions.
- Compact iPhone, iPad, accessibility Dynamic Type, VoiceOver, dark/light,
  keyboard, sheet, safe-area, and persistent mini-player product fit.

## Explicitly out of scope

- New Watch playback, transfer, rendering, connectivity, or synchronization.
- Co-op replies, accounts, trust networks, hosted storage, public distribution,
  remote revoke, or AI-generated/synthesized sharing content.
- A claim that an unsigned sender label proves identity.
- Embedding podcast audio or original PDF/EPUB containers.
- External sharing enablement before issue #14 is resolved.
- Build 22 acceptance; it must be recorded against its own candidate.

## Known issues and limits

- Build 22's #84 seek behavior is pending product-owner acceptance and blocks
  broader or external Build 23 distribution; the product owner authorized the
  completed internal-only exception recorded above.
- Issue #14's rights/provenance policy is unresolved and blocks externally
  enabled sharing.
- Physical-device behavior for microphones, acoustic sampling, real share
  destinations, security-scoped Files imports, Live Activity authentication,
  podcast cross-edition placement, and audible playback is not established by
  simulator checks.
- The complete SessionKit suite has one intentional held-out podcast benchmark
  wrapper skip; its external benchmark artifact remains the relevant evidence.
- Generic builds emit pre-existing AVFoundation chapter-loading deprecation
  warnings in `LocalSourceImporters.swift`.

## Upgrade, reset, samples, and diagnostics

- First install over the current app. Existing library items and imported
  Shared Margins should remain. Do not reset, uninstall, or delete the app in
  response to a schema/library-access error; preserve the device and report the
  displayed error.
- To remove only one imported layer, use **Delete Shared Margins** in that
  item's Shared Margins section.
- Only for an intentional complete DEBUG reset: open **Settings → Developer →
  Developer tools → Reset Library and Load Sample**, then confirm the reset.
- The seeded app-authored sample is **Welcome to Spoken Margins**. For broader
  validation, create one URL-backed text item, one linkless pasted-text item
  with at least two Margins, and one real podcast Margin. Use a second supported
  device or clean installation as the recipient when practical.
- In DEBUG, open **Settings → Developer → Developer tools → Refresh
  Diagnostics**. Inspect `lastSharedPackage`,
  `lastSpokenMarginsPackageImport`, `podcastAnchorEvidence:<interjection-id>`,
  and `importedPodcastAnchorResolution:<item-id>`.
- Use **Settings → Copy Privacy-Safe Diagnostics** to export the redacted
  report. Attach it with device, OS, exact checklist row, and reproduction steps
  for every failure.

## Automated verification summary

- Contract and surface-contract validators: pass.
- SessionKit: 220 executed, 219 passed, 1 intentional held-out benchmark skip,
  0 failed.
- Original integrated Build 23 focused app tests: 18 passed, 0 failed at
  `10f7fd1`.
- Final sharing-experience delta at `8bca934`: 9 focused app tests passed, 0
  failed; contract and surface validators passed; SessionKit test build passed;
  clean iOS Simulator test build and signed Release archive passed.
- Generic iOS Simulator and iOS device builds: pass.
- Three scoped UI routes: sender, recipient, and accessibility/layout each
  passed with 0 failures.
- Exact archive round-trip, stale-preview invalidation, Add Source return,
  no-autoplay fixture state, non-color provenance, and the three layout
  regressions have focused automated evidence.

See [`automated-verification.md`](automated-verification.md) for commands,
result bundles, audit boundaries, and omission checks. This evidence establishes
`verified`, not `human_validated`.

## Product-owner checklist

Record `PASS`, `FAIL`, or `NOT RUN`, plus device/OS and notes for every row.

1. [ ] **Upgrade without reset.** Install over the existing app. Confirm the
   prior library, prepared media, private Margins, stars/notes, and previously
   imported Shared Margins remain. Result/notes: Pending.
2. [ ] **Select is immediate.** Open Share from an item with starred and
   unstarred Margins. Confirm the selection controls and primary action are at
   the top, Select All/None works, tapping a Margin card toggles inclusion, the
   private starred shortlist remains distinct from Include, and transport or
   rights consequences remain truthful. Result/notes: Pending.
3. [ ] **Cleanup consent and remembered default.** On a first share, accept
   automatic cleanup and confirm included eligible Margins are prepared. Open a
   later share and confirm `Clean selected` defaults on without another prompt.
   Turn it off and confirm only auto-applied cleanup is undone; explicitly clean
   one Margin, toggle the preference on and off, and confirm that explicit edit
   remains. Repeat from a reset while declining the first prompt and confirm the
   remembered default is off but available. Result/notes: Pending.
4. [ ] **Review is compact and reversible.** Confirm exactly one Margin editor
   is expanded, long instructional text and anchors do not precede the primary
   work, Original/Cleaned/Text only offers available representations, and
   Restore Original appears only after an edit. Exercise readable inline words
   and bracketed pauses, Undo/Redo, collapsed context, cleanup summary, and
   available audio preview. Reopen the private Margin and confirm its source
   recording/transcript was not rewritten. Result/notes: Pending.
5. [ ] **Batch preparation is bounded.** Use many eligible Margins. Confirm
   visible completed/total progress, responsive cancellation, retry, and
   per-Margin fallback without blocking other results. Result/notes: Pending.
6. [ ] **Rights and transport variants.** Check a URL-backed item, linkless
   rights-confirmed text/PDF/EPUB-derived item, the same linkless type without
   confirmation, and the app-authored Welcome sample. Confirm disclosures and
   recipient requirements match the reviewed choice and no original container
   or podcast audio is claimed. Result/notes: Pending.
7. [ ] **Optional exact recipient preview.** Build Recipient Preview when
   desired, inspect its
   included/excluded summary, then change sender label, Include state,
   transcript token, representation, anchor, evidence, or rights. Confirm the
   preview and share readiness disappear and Review is required again.
   Result/notes: Pending.
8. [ ] **Direct real system share.** Use Share without requiring a separate
   preview pass. Confirm background verification completes and the native
   system sheet presents one `.spokenmargins` file. When optional preview was
   used, confirm the destination receives the exact file reviewed. Result/notes:
   Pending.
9. [ ] **Recipient preview and cancel.** Open the transferred file on the
   recipient. Confirm integrity-checked but unsigned sender language, item and
   transport, Margin count, asset categories, inclusion/exclusion, and the
   no-autoplay promise. Confirm Cancel imports nothing. Result/notes: Pending.
10. [ ] **Missing-source round trip.** For a recipient-supplied text/PDF/EPUB
   package, choose Add Source. Add a nonmatching item first and confirm import
   remains blocked while the staged package survives. Add the matching source,
   return to the same pending preview without reopening the file, then import
   explicitly. Result/notes: Pending.
11. [ ] **Import boundaries.** Confirm import does not start playback, does not
    change source ownership, and creates a separate Shared Margins layer. Check
    sender/integrity/resolution with label plus symbol/shape and VoiceOver, not
    color alone, in both Item detail and Timeline. Result/notes: Pending.
12. [ ] **Layer behavior and persistence.** Confirm unresolved/default behavior
    is Companion. Exercise enable, mute, Fresh/Companion/Guided, relaunch, and
    duplicate-package import; state must persist and no duplicate layer may
    appear. Result/notes: Pending.
13. [ ] **Podcast evidence is conservative.** Exercise progressive playback,
    closely spaced Margins, seek/item-change interruption, an unsupported
    stream fallback, exact edition, and a real cross-edition case. Any wrong
    confident placement stops acceptance. Result/notes: Pending.
14. [ ] **Playback behavior.** Cross verified text and podcast Margins in
    Companion and Guided modes, including mute and explicit Listen/Dismiss.
    Confirm the cue/order, no import-time autoplay, source resume, and 1×/1.75×
    rate preservation. Result/notes: Pending.
15. [ ] **Live Activity and ordering.** After authentication, exercise Listen
    and Dismiss in the applicable Live Activity layouts. Confirm next navigation
    orders publisher chapters and resolved Shared Margins by position, and
    never offers ambiguous/unresolved Margins. Result/notes: Pending.
16. [ ] **Compact iPhone accessibility.** At the largest Dynamic Type, with
    VoiceOver, darker colors, reduced motion, and dark/light appearances,
    confirm Library hero/search/filter controls, all sharing stages, provenance,
    Add Source actions above the keyboard/sheet edge, Timeline content, and the
    persistent mini-player remain readable and operable. Result/notes: Pending.
17. [ ] **iPad product fit.** Repeat the sender, recipient, Add Source,
    imported-layer, and mini-player paths in portrait and landscape without
    clipping, obscured actions, or misleading empty space. Result/notes:
    Pending.
18. [ ] **No-network and recovery.** Repeat reference resolution and
    recipient-supplied import with networking unavailable, cancel/reopen safe
    points, and relaunch. Confirm truthful fallback, no lost staged package, no
    duplicate layer, and no library loss. Result/notes: Pending.
19. [ ] **Diagnostics.** Refresh and export privacy-safe diagnostics after one
    successful package and one deliberately failed/fallback path. Confirm the
    four diagnostic families above are useful and contain no package/item
    payload. Result/notes: Pending.

## Acceptance and stopping rules

Mark Build 23 `human_validated` only after the product owner records acceptance
for this exact runtime candidate on supported physical devices. A partial pass
advances only the explicitly accepted rows; do not infer the rest.

Stop acceptance on a stale or different shared archive, item payload without
the displayed rights basis, leaked private curation metadata, private-original
mutation, transcript insertion, cleanup overlapping aligned speech, wrong
confident podcast placement, navigation to unresolved content, unreviewed
representation export, autoplay during import, source-ownership mutation,
color-only provenance, duplicate imported layer, or library disappearance.

Product-owner result: Pending.

Product-owner notes: Pending.
