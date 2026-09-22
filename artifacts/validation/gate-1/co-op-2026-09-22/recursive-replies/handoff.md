# Recursive replies and editable listening context

Engineering handoff, September 22, 2026. State: **implemented; verification partial**.
This is not product-owner validation or a release handoff.

- Lane: `codex/co-op`.
- Base commit: `564a16ddb5614f40380480e02460be3f55896689`; changes remain uncommitted.
- Project version remains 0.1 (27). No new distribution build, installation, archive,
  merge, or commit was created. The previously preserved Build 28 archive is untouched.
- Supported app deployment: iPhone/iPad, iOS/iPadOS 26+. Host package tests use macOS.
  No iOS 27 runtime-verification claim is made.

## Implemented paths

1. Open a source Margin or shared Margin and choose Voice reply or Written reply.
   Playback also exposes these actions. Capture shows the referenced parent;
   original source coordinates remain independent of the reply reference.
2. Replies can themselves receive replies. Conversation details expose descendants
   and sibling replies, including references to older revisions. Play with context
   follows the selected exact parent chain. Voice ancestors advance; text ancestors
   expose Next reply. Skim also advances along that chain.
3. Response & Context edits the parent or source lead-up. Native text/PDF uses a
   highlighted text selection; native audio uses start/end controls within the
   preceding five minutes. Save and play previews the selection. Complete parent
   Margins are the first supported parent-context unit.
4. The existing item Share action remains the quick path. Its optional disclosure
   permits context edits and explicitly reviewed inclusion of referenced Margins.
   Leaving inclusion off sends references without forwarding their bodies.
5. A completed recent Margin can suggest attaching a newly captured source Margin
   as a reply for 30 seconds. The user must choose it. There is no automatic
   reparenting based on proximity.
6. Stable contribution/revision references survive archive round trips. Overlapping
   packets union new revisions, preserve forks and missing-parent references, and
   reject conflicting immutable content or cycles before import writes.

Source matching still uses portable anchor evidence. Listening hints do not replace
that evidence. Repeated text is checked at the resolved anchor-relative position;
otherwise a unique quote is required before using custom text context. The normal
context fallback remains available. PDF stamp cleanup from the first slice is
unchanged. Replies on generated assistant/summary turns are outside this slice.

## Verification

Final evidence is recorded in `verification.json` beside this file.

- Host fast plan: runner tests, contract/surface/inventory validators, browser tests,
  and complete SessionKit execution. The held-out external podcast corpus has its
  existing explicit skip; it is not a newly skipped regression.
- New executed package tests cover three-person forks, reverse arrival order,
  overlapping packets with different package IDs, immutable revision conflicts,
  SQLite rollback/reconstruction, missing ancestors, cycles, and forwarded audio
  digest retention through an actual archive.
- New app tests cover recursive capture and playback, original-position retention,
  corrected context, invalid selections/cycles, explicit forwarding consent and
  stable revision identity. Build-for-testing compiles them but does not run them.
- Generic simulator/test-target and generic iOS device builds require no simulator
  boot. Their success is compilation evidence, not playback or UI verification.
- App, adapters, speech-canary, and UI runtime plans remain **not executed for this
  change**. The iPad SpringBoard/XCTest teardown incident remains unresolved. No
  affected-simulator boot, recovery claim, or alternate-device bypass was attempted.
  See [incident evidence](../springboard-incident/incident.md).

One intermediate fast run finished its checks after source inputs changed and was
correctly rejected by the runner. Only the later unchanged-input verified run is
used in the final evidence.

## Boundaries and remaining work

- No server, VPS changes, S3 bucket, accounts, synchronization, or AI context selection.
- No automatic whole-item highlight reel; playback follows a selected reply path.
- Parent excerpts are whole Margins. Finer trimming of parent recordings/transcripts
  is deferred. Source context editing is implemented now.
- Author labels/IDs are attribution, not authenticated identity. New packages require
  the conversation capability; older apps must reject it. Old packages still import.
- Exact referenced revisions retain their transcript and audio for replies. Deleting
  a visible local Margin or hiding an imported collection does not rewrite existing
  conversation history. Retained audio needs future storage-management UX.
- Runtime correctness, accessibility layout, selection-handle ergonomics, recording
  permission/cancellation behavior, and physical-device performance remain unverified.
- The context chooser currently prepares available local targets synchronously;
  large collections/recordings require physical-device responsiveness measurement.

## Owner exercise after runtime verification is unblocked

No product-owner acceptance is claimed. Suggested pass/fail checklist:

- [ ] A sends a selected source Margin to B and C; both reply and send back. Both
      branches appear once, including after repeated imports and relaunch.
- [ ] A replies to B's reply. Listen to A → B → A with Skim/Next reply and return to
      the original position. Repeat with voice, written text, and a mixed chain.
- [ ] Receive a child before its parent. Show the missing parent without guessing;
      import the parent later and follow the completed chain.
- [ ] Shorten a PDF/text lead-up with selection handles; shorten a podcast range.
      A second Skim tap still skips the lead-up. Verify on phone and iPad at large text.
- [ ] Record shortly after a friend's Margin; capture remains source-attached until
      the optional suggestion is accepted. Correct a missed target manually.
- [ ] Compare exported files with referenced-body inclusion off and on. Verify the
      selected bodies/voices and author labels, including a parent’s older version.
- [ ] Cancel written/voice capture and deny microphone permission; the next ordinary
      Margin must not inherit a stale parent.

Use test data on a separate development installation when runtime testing resumes.
Existing seeded `item-pill` is used by the app regressions; synthetic Alice/Bob/Carol
packets are generated by `SharingTests.testConversationForksRoundTripAndDeduplicateAcrossDifferentPacketsAndRestart`.
Do not reset the owner's Library. Removing imported test collections is a visibility
change, not a full history reset; use a disposable test database for clean-import tests.
Diagnostics/build logs are retained beside this handoff and in the linked runner
manifest. The previous first-slice handoff remains historical evidence only.
