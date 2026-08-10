# Recovery MVP Product-Owner Device Pass

- Date: 2026-08-10
- Reporter: product owner
- Installed build number: not supplied
- Installed commit SHA: not supplied
- Device and OS: not supplied
- Diagnostics path: not supplied
- Private evidence: a 47,081-byte AI-handoff Markdown export for the native-audio item `What makes for a dream job? | Benjamin Todd` was supplied through Codex. The private export is not copied into the repository because it contains listener transcripts and source context.

## State Rules

This record preserves only the bounded product-owner results actually reported. It does not infer the installed build, commit, device, OS, or acceptance of unmentioned checks.

## Human-Validated Objectives

The product owner reported the following numbered objectives as validated:

1. Long-title library presentation and deterministic Listening Maps for structured pasted text, including predictable mapless behavior for unstructured text.
2. Opening the correct item detail from the playback item/chapter title without stopping playback.
3. Cancel and confirm behavior for Empty Recently Deleted, including the resulting empty state.
4. Starting native-audio playback from a selected publisher chapter without the prior error.
5. The bounded Live Activity/interjection path, including the accepted removal of the unreliable Live Activity play/pause affordance. The product owner requested a separate enhancement to use available playback-header space for the next chapter as a tappable skip target.
6. Generated-response playback/progress and return to the preserved native-audio position. The supplied handoff contains an AI Response and a later AI-response-targeted interjection; the product-owner report supplies the actual device acceptance.
8. The large Share Session export preview and complete export path. The product owner requested that Source Text be unavailable or visibly disabled for native-audio items.
9. Automatic final-audio session closure and cleanup.

These direct reports advance the bounded flows above to `human_validated` even though the build and device identity were not supplied. They are not evidence for a different candidate build.

## Objective 7: Partial; Not Human-Validated

The product owner reported that the generated interjection summaries were generally good, but found two defects:

- some summaries retained verbal fillers such as “uhm” and “ah”;
- a generated summary included an interjection that the product owner had deleted.

The supplied handoff supports the deleted-interjection report. Its source timeline contains eight surviving source interjections, while its Interjection Summary contains nine bullets. The unmatched first bullet begins `is a test interjection to see if it properly locates`; no corresponding surviving source-interjection entry appears in the exported timeline.

The supplied summary does not itself contain the reported “uhm” or “ah” tokens. That observation is recorded as direct product-owner device evidence rather than attributed to the attachment.

Because current-record scoping and cleanup of spoken fillers are acceptance properties of the summary flow, objective 7 and GitHub issue #56 remain not `human_validated`.

## Native-Audio Export Boundary Feedback

The product owner accepted the large-export flow but reported that Source Text should not be selectable for a native-audio item and suggested disabling or graying out the option.

The runtime already prevents full native-audio source text from being included when the option is selected; the remaining issue is that the export UI presents a misleading control. This feedback does not revoke the bounded large-preview acceptance.

## Supertonic / Issue #34

The product owner reported:

- cold latency: acceptable;
- 30-minute narration: great;
- thermal behavior: fine;
- AirPods behavior: great;
- James and Lily voice quality: great.

Those physical-device checks are now `human_validated`. The report did not explicitly cover the documented 100-chunk memory trend or interruption/reset cases, so this record does not infer those results.

## Legacy / Issue #40

The product owner reported that Safari intake works but needs a UX pass:

- selected-text intake is unnecessary;
- intake should require fewer button presses;
- both the Share extension and Safari extension occupy too much screen space and feel visually unfinished;
- a UI pass should improve feel and user efficiency.

This is partial acceptance of Safari intake functionality, not full human validation of issue #40. The report did not cover the remaining legacy speech, podcast/Now Playing, recovery, or normal/legacy isolation checks.

## App Store Screenshots / Issue #41

The product owner agreed to defer App Store screenshot work until the release UI is frozen.

## Follow-Up Boundaries

Keep the following work separate so validated flows do not silently absorb new scope:

1. Summary correctness: remove remaining filler from generated summaries and ensure deleting an interjection invalidates, regenerates, or otherwise removes its derived representation from active summaries and exports.
2. Playback-header efficiency: show the next chapter in available space as a tappable skip target without replacing the current item/chapter identity.
3. Native-audio export clarity: disable or hide Source Text for native-audio items while preserving bounded source context and listener-authored exports.
4. Share/Safari extension UX: reduce footprint and taps, remove selected-text intake if confirmed as out of scope, and preserve page/article and podcast-link intake.

## Product-Owner Result

- Objectives 1–6, 8–9: **PASS / `human_validated`** for the tested build.
- Objective 7: **PARTIAL / not `human_validated`**.
- Issue #34 stated device checks: **PASS / `human_validated`**.
- Issue #40 Safari intake: **PARTIAL**; broader validation remains open.
- Issue #41: intentionally deferred.

## Follow-Up Implementation And Automated Evidence

After recording the product-owner result, the requested follow-ups were implemented in the working tree:

- the playback header now offers the following chapter as a one-tap target;
- deleted interjections are excluded from summary candidates, eligibility, displayed derived summaries, and exports, and spoken-note cleanup removes the reported filler variants;
- Source Text remains visible but disabled for native-audio exports, with an explanation of the bounded-context boundary;
- Safari article capture now runs from one toolbar action without a selected-text mode, and the Safari and Share extension surfaces use compact status UI.

These changes are `verified`, not `human_validated`. Evidence collected on 2026-08-10:

- contract and surface-contract validators passed;
- SessionKit built successfully and its 142-test suite passed with zero failures;
- browser extraction's 8-test suite passed with zero failures;
- the full `SpokenMarginsAppTests` suite passed 175 tests with zero failures on an iPhone 16 Pro simulator running iOS 18.6;
- generic iOS Simulator builds passed for both `SpokenMarginsApp` and `SpokenMarginsLegacy`, including their Share and Safari extensions.

Only the four changed flows above require a focused product-owner recheck. The earlier bounded passes do not need to be repeated unless the next candidate differs beyond this recorded scope.

## Focused Recheck Results

Later on 2026-08-10, the product owner tested the four follow-ups and reported:

1. **FAIL** — the next-chapter shortcut was not present in the Live Activity, and native-audio playback was reported as gone. A supplied lock-screen screenshot shows the chaptered text item `Moving Forward from Hot Fable Summer` paused in the medium Live Activity with unused space beside the Interject button and no next-chapter affordance. The report does not identify a separate native-audio item or exact in-app reproduction path, so the native-audio observation remains a distinct unresolved device regression rather than an inferred cause.
2. **FAIL** — summary output removed `um` but remained an insufficiently compressed transcript. The supplied handoff preserves `well`, `you know`, repeated `I think` framing, a generic acknowledgement, and nearly all original wording. Summary acceptance therefore requires verbal-tick removal and material compression, not only filler-token cleanup.
3. **PASS / `human_validated`** — Source Text is correctly unavailable for native-audio export.
4. **PASS / `human_validated`** — the compact one-action Safari and Share extension UX was accepted.

The product owner also retired the iOS 16.7 legacy app because its final intended user now has a device that supports the normal app. Legacy parity and normal/legacy isolation are no longer release objectives; this is a product-scope decision, not a claim that the legacy checks passed.

## Remediation After Focused Recheck

The next-chapter affordance was moved from the in-app playback header to the Live Activity control row. Its state now carries the exact following source-chapter title and identifier, and the tap opens the normal app directly into a canonical chapter jump. Source timeline current-chapter detection now covers text, transcript-backed native audio, and browser-owned media.

The on-device summary contract now:

- treats `yeah`, `well`, `okay`, `so`, `you know`, `I mean`, and `I think` framing as removable verbal ticks;
- sets a per-note compression budget capped at 24 words;
- rejects lightly cleaned transcripts that are not materially shorter;
- retries with an explicit strict-compression prompt before using a listener-note-only fallback;
- preserves meaningful uncertainty rather than deleting negation or qualifications.

These remediations are implemented and automated-verified only. Objectives 1 and 2 remain not `human_validated` until a new traceable device build passes. The native-audio playback observation also remains open pending a reproducible device path or a passing device recheck.

Current automated evidence collected after the focused-recheck remediation:

- contract and surface-contract validators passed;
- SessionKit passed 142 tests with zero failures, including native-audio import, start, chapter jump, transport, rate, skip, and interjection/resume coverage;
- browser extraction passed 8 tests with zero failures;
- focused Live Activity and summary-policy suites passed 20 tests with zero failures;
- the full normal-app unit suite passed 178 tests with zero failures on an iPhone 16 Pro simulator running iOS 18.6;
- the normal app and its three supported extensions passed a generic iOS Simulator build;
- the generated project contains no legacy app, legacy extension, or legacy scheme.

GitHub issue #40 was closed as `not planned` to record the product decision without misrepresenting the unrun legacy checks as accepted.

## Native Lock-Screen Playback Clarification

The product owner clarified that “native audio playback is gone” means the system Now Playing playback card is absent from the lock screen; it does not mean that podcast playback fails inside the app.

The remediation keeps transport-command ownership with the canonical native player while also republishing its current Now Playing metadata through the compact-control coordinator. This closes the metadata-ownership gap after pause, backgrounding, or a playback-route handoff. The app also explicitly refreshes Live Activity and Now Playing surfaces when its scene becomes inactive or enters the background.

This lock-screen remediation is `implemented` and automated-verified, not `human_validated`. The focused device recheck is: start or resume a native/prepared-audio item, lock the phone, confirm the system Now Playing card is present beside the Live Activity, then verify play/pause and seek operate the same session.

## Second Focused Recheck: Text Now Playing And Live Activity Tap Scope

The product owner clarified the remaining result on a later device pass:

- **PASS / `human_validated`** — the next-chapter affordance is visible in the Live Activity and jumps to the following chapter.
- **FAIL** — during native text narration, the Apple Now Playing card is absent. Consequently the lock screen has no system play/pause or skip controls. This supersedes the earlier record's description of the failing route as native/prepared audio: the reported failing item is a native text item.
- **FAIL** — tapping outside the visible next-chapter affordance also performs the chapter jump instead of merely opening Spoken Margins. The chapter link had become the Live Activity's effective global tap destination.

The first result advances only the visibility and canonical chapter-jump behavior to `human_validated`. It does not validate the tap boundary or native text Now Playing controls.

## Remediation After Second Focused Recheck

The chapter link is now a bounded Live Activity App Intent button carrying the exact chapter identifier through the shared command queue. Only that button queues `jumpToChapter`; it opens the app to let the canonical runtime perform the jump. The rest of the Live Activity retains the system's normal app-opening behavior.

For native text narration, the Now Playing coordinator now keeps both Apple play and pause commands registered throughout the session, including while paused, and reasserts the existing playback audio session when Now Playing metadata is published or refreshed for lifecycle changes. Skip-back and skip-forward remain canonical compact commands rather than duplicate Live Activity controls.

These changes are `implemented` and automated-verified, not `human_validated`. Evidence collected after this remediation:

- contract and surface-contract validators passed;
- SessionKit built successfully with tests enabled;
- the focused `Gate2CompactControlTests` suite passed 15 tests with zero failures on an iPhone 17 Pro simulator;
- the full normal-app unit suite passed 181 tests with zero failures on the same simulator;
- the focused test build compiled and embedded the normal app and Live Activity widget extension, including App Intent metadata extraction;
- the normal app and all three supported extensions passed a signed generic iOS device build;
- queue regression coverage proves the bounded intent preserves its chapter identifier and still decodes older queued commands without that field;
- Now Playing policy coverage proves native text keeps play, pause, toggle, skip-back, and skip-forward registered in the paused state.

The shortest remaining device recheck is: begin native text narration, lock the phone and exercise Apple play/pause and skip; tap the non-button portion of the Live Activity and confirm it opens the app without moving position; then relock and tap the next-chapter button and confirm exactly one canonical chapter jump.
