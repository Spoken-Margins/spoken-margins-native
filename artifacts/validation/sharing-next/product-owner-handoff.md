# Sharing-next product-owner validation handoff

Status: `implemented` and `verified`; not `human_validated`.

Branch: `codex/sharing-next`

Implementation commits:

- `aa187a2` (`Complete rights-aware sharing review flow`)
- `84fd071` (`Refine shared Margin review and playback prompts`)
- `b3f0d5e` (`Capture podcast anchors from post-Margin playback`)
- `a002330` (`Prepare Margins in bulk and match playback rate`)
- `22901aa` (`Curate Margins for sharing from the timeline`)
- `9c74a57` (`Close shared Margin playback gaps`)

Local build setting: version 0.1 (21)

Build 21 is already reserved for the accepted hotfix line. Allocate a new build number before distributing this sharing revision through TestFlight. Installing the new build over the existing app is the expected upgrade path; a reset is not required.

## Supported validation environment

- iPhone or iPad running iOS/iPadOS 18.0 or later.
- Simulator compilation and focused state tests are verified.
- Microphone capture, decoded-stream acoustic sampling, podcast matching, and the listening experience require product-owner validation on a physical device.

## Implemented user path

From playback, tap the Share icon. The first panel on the resulting **Share** screen is **Share Margins**; session Markdown/JSON remains available separately under **Export listening session**.

The sender review now supports:

- opening Timeline Margins normally while using a separate visible star control to build a private sharing shortlist;
- persisting an optional private sharing note on each Margin without placing that note in an export or recipient record;
- defaulting the review to starred Margins when any exist, with explicit All/Starred filtering and per-export Include controls remaining authoritative;
- showing at most 10 measured transcript lines initially, with an explicit expansion control only when the transcript actually overflows;
- choosing which Margins leave the device;
- preparing every included Margin with aligned word timing from one bulk action, with visible progress, cancellation, and per-Margin fallback;
- tapping aligned words or inline bracketed pauses to remove or restore them, with explicit Undo and Redo and no text-insertion route;
- one compact transcript instead of padded word capsules plus a duplicate vertical edit list;
- automatic filler cleanup plus aligned-speech and acoustic leading, trailing, and internal non-speaking-gap tightening, including sustained noisy gaps between recognized words;
- Original voice, Cleaned voice, or Text only, with previews;
- bounded anchor-context review and optional non-playable podcast acoustic evidence; and
- the item-transport disclosure described below.

## Item transport and rights behavior

The package now distinguishes a reusable **source** such as a podcast feed from the discrete **item** being listened to.

| Sender item | Sender disclosure | Package behavior | Recipient behavior |
| --- | --- | --- | --- |
| HTTPS-backed article or podcast episode | No rights toggle | Sends the item reference, never the item payload | Reconstructs or matches the item, then resolves Margins |
| Linkless pasted text, PDF-derived text, or future EPUB-derived text | “I’m sharing this privately and have the right to share this item” enabled | Includes the exact listened-to text as a digest-covered artifact | Adds or matches that listened-to item, then resolves Margins |
| Same linkless item | Rights confirmation not enabled | Sends Margins and item identity only | Requires the recipient to add the matching item before import |
| App-authored welcome sample | Provenance is known by the app | Includes the exact listened-to text without asking the user to attest | Adds or matches the sample item |

The embedded representation is the exact text Spoken Margins listened to, not the original PDF/EPUB container, its layout, or any podcast audio. Packages that contradict the disclosure—for example a URL-backed item marked recipient-supplied, mismatched PDF/EPUB type, embedded podcast content, absent rights basis, or digest mismatch—are rejected.

The pre-release `.spokenmargins` schema was replaced in place as authorized by the release lane. Packages exported by the earlier sharing prototype are intentionally unsupported. Existing locally imported Shared Margins records do retain a backward decoder so upgrading this branch does not make those records or the rest of the library disappear.

Timeline stars and private sharing notes are local curation metadata. They persist across relaunch, but are deliberately excluded from reviewed revisions, session JSON/Markdown exports, `.spokenmargins` packages, and recipient records. A star changes the initial shortlist only; the sender's **Include this Margin** choice remains the final authority for each export. If no Margins are starred, review retains the existing all-included behavior.

## Podcast anchoring and recipient experience

- Podcast audio is never included.
- After a podcast Margin finishes, playback arms one bounded 12-second sample of the decoded audio the sender is about to hear. The resulting ShazamKit signature provides high-reliability, non-playable cross-edition evidence without a rolling buffer or a second podcast download.
- Closely spaced Margins share the same playback tap while retaining independent bounded signatures. The app stores no sampled podcast audio.
- Recipient resolution can use exact-edition, transcript, acoustic, and fused evidence. Ambiguous, absent, wrong-item, and unresolved results never become confident interruptions.
- Recipient import is integrity checked but the sender identity remains unsigned and is labeled unverified.
- Import does not autoplay. Imported commentary remains a distinct Shared Margins layer with Fresh, Companion, and Guided behavior.
- Companion mode pauses the source at a verified text or podcast anchor, sounds the cue unless the layer is muted, and presents **Listen** and **Dismiss** in playback and the Live Activity. Listening resumes the source when the Margin ends; Dismiss resumes immediately.
- Guided mode sounds the cue and starts the Margin after the cue. **Auto-play shared Margins** on the playback screen maps enabled layers to Guided when on and Companion when off, preserving the existing persisted reveal-mode model.
- Private and received Margin voice uses the item's current playback rate, including 1.75×. The notification cue remains at normal speed, and the item resumes at its prior rate after the Margin.
- The Live Activity carries no Margin transcript. Its sender label is privacy-sensitive.
- Listen and Dismiss are now real shared `LiveActivityIntent`/`AudioPlaybackIntent` actions compiled into both the app and widget targets, so iOS executes the handoff in the app process without requiring the widget extension to own audio. Both medium and supplemental small prompt presentations contain the actions. iOS still requires authentication before a control performs on a locked device.
- The next-navigation slot merges publisher chapters with verified upcoming Shared Margins by source position. With no publisher chapters it shows the next Margin; otherwise it shows whichever chapter or Margin comes first. Selecting a Margin moves to its verified local anchor, sounds the cue when enabled, and either waits for Listen/Dismiss or auto-plays according to the layer. This is a presentation projection: it never rewrites publisher chapter data, and unresolved or ambiguous Margins are excluded.
- **Create Recipient Test Session** still exercises the real archive, verification, import, persistence, resolver, and listening route on one device.

## Cleanup behavior

- Filler and word removal require aligned recognition timing.
- Speech-aware cleanup examines the immutable recording, treats aligned words as protected, and combines two signals: aligned non-speaking intervals of at least 750 ms even when they contain sustained background sound, plus acoustically quiet runs of at least 360 ms. It retains 80 ms at recording edges and 140 ms internally and renders a derivative with 15 ms crossfades.
- **Prepare All Included** processes eligible Margins serially rather than rendering them concurrently. This intentionally bounds memory, heat, and battery use for sessions with dozens of Margins, while showing completed/total progress and allowing cancellation.
- A failed Margin does not stop the queue. It is labeled with its fallback and retains Original voice when available or reviewed Text otherwise; successful and failed Margins remain individually reviewable.
- The private recording and private transcript are never rewritten.
- Older Margins without aligned timing remain eligible for original-voice or text-only sharing, but word deletion and automatic cleanup are unavailable for them.
- Item actions now precede optional Listening Map tools, and the duplicate Generate Listening Map action was removed from the empty-chapters panel.

## Out of scope and known constraints

- EPUB ingestion itself belongs to the active quality/completion lane; the sharing schema and transport already represent EPUB-derived listened text once that item type is available to the app.
- Offline phone generation of Listening Maps, proposal activation, summary bridge playback, and Skim controls remain out of scope. Portable Listening Map proposals may travel but remain inert.
- Co-op replies, remote revocation, accounts, trust networks, hosted storage, public distribution, and AI-generated summaries are not implemented.
- The sender must continue podcast playback long enough to collect at least 3 seconds of decoded audio; the target window is 12 seconds. A request expires after 60 seconds if playback never supplies audio.
- Progressive podcast media that AVFoundation exposes as decoded PCM can use the stream sample without a complete download. Unsupported playback forms, a seek or item change before completion, and too little audio decline acoustic evidence and retain transcript/identity fallback rather than claiming a verified anchor.
- Exact-local-file evidence remains available when the active playback item itself is a validated local download. A parallel download of a dynamic-ad episode is not treated as the exact edition the sender heard.
- A text-only Margin is readable but has no voice playback.
- Live Activity actions cannot bypass iOS lock authentication. After authentication, their shared intents run in the app process and hand off to the canonical source/Margin players; the widget process never owns audio.

## Reset, samples, and diagnostics

- Install this build over the existing app. Do not reset or uninstall in response to a schema/library-access error.
- Remove one imported layer from the item's **Shared Margins** section with **Delete Shared Margins**.
- Only for an intentional complete DEBUG reset: **Settings → Developer → Developer tools → Reset Library and Load Sample**.
- The app-authored Welcome to Spoken Margins item is a seeded linkless embedding sample.
- In DEBUG, use **Settings → Developer → Developer tools → Refresh Diagnostics** and inspect `lastSharedPackage`, `lastSpokenMarginsPackageImport`, `podcastAnchorEvidence:<interjection-id>`, and `importedPodcastAnchorResolution:<item-id>`.
- **Settings → Copy Privacy-Safe Diagnostics** exports diagnostics without package or item payloads.

## Automated verification

- Contract validator: passed.
- Surface contract validator: passed.
- SessionKit build with tests: passed.
- Complete SessionKit package suite: 197 executed, 196 passed and 1 dedicated held-out benchmark wrapper skipped by design, 0 failed.
- SharingTests: 29 executed, 28 passed and 1 dedicated held-out benchmark wrapper skipped by design, 0 failed. Coverage verifies that only the armed post-resume window is signed, the signature remains below 1 MB, and the anchor offset is derived from playback media time. It also verifies private Timeline curation boundaries and that a continuous high-energy background-noise gap is removed without any proposed range overlapping aligned words.
- Session lifecycle coverage verifies that the 12-second request is armed before source playback resumes after a podcast Margin.
- Complete `Gate2CompactControlTests`: 24 passed, 0 failed, including verified text/podcast anchor eligibility, legacy and current Live Activity state, prompt publication, app-group URL/queue target compatibility, compact playback policy, chapter/Margin ordering, and jumping to a verified received-Margin anchor.
- Focused item-screen UI route: 1 passed, 0 failed; Start/Continue Listening is hittable before scrolling and no second chapter-panel map generator exists.
- Generic iOS Simulator app build: passed.
- Generic physical iOS app build: passed.
- Diff whitespace check: passed.
- Existing benchmark artifact: 232 anchors, 226 eligible and 6 deliberately absent; fused/monotonic placement had zero wrong confident placements, 4 ms p95 error, and declined all 6 absent passages. See `podcast-anchor-benchmark.md` and `podcast-anchor-benchmark-result.json`.
- New bulk/rate app-model tests: 4 passed, 0 failed. A 53-Margin fixture verified exactly 53 serial renders with maximum concurrency 1, byte-for-byte private-original preservation, and Undo/Redo after preparation. Dedicated cases verified cancellation restores eligibility, renderer failure falls back to Original voice, and 1.75× maps unchanged to Margin playback while invalid rates are bounded.
- Focused Timeline curation test: passed. It verifies relaunch persistence, the 500-character private-note bound, starred-first review selection, all-included fallback after removing the final star, and measured 10-line overflow behavior. The previously focused word-delete Undo/Redo and 53-Margin bulk tests also passed in the same run.
- App Intents metadata extraction succeeded for both the app and Live Activity widget during simulator and physical-device builds.
- Full `Gate1AppModelWorkflowTests` omission check: 72 executed; all 4 new tests and 67 other tests passed. One unrelated PDF visual-heading expectation failed because the implementation preserved a `Front Matter` chapter that the older assertion excludes; no sharing, Margin, playback-rate, or changed file participates in that result.
- System TTS voice discovery is now deferred until the Settings screen appears, where the catalog was already refreshed. This removes a simulator/app-launch stall without changing the voice-selection surface.

Automated evidence establishes `verified`, not `human_validated`.

## Product-owner checklist

Record Pass, Fail, or Not run, with device/OS and notes.

1. **Upgrade without reset.** Install over the current app. Confirm the existing library and any earlier imported Shared Margins layers remain present. Result: ___
2. **Open sharing from playback.** Start listening to an item with at least one Margin, tap Share, and confirm **Share Margins** is the primary first option while session export is clearly separate. Result: ___
3. **Review one inline transcript.** Confirm words read like a compact transcript rather than padded capsules. Tap words, verify they strike through, and verify no insertion control exists. Exercise Undo and Redo. Result: ___
4. **Tighten voice inline.** Use **Remove Fillers & Tighten Pauses** on a recording containing “um,” removable “uh,” semantic “you know,” a leading/trailing gap, and an internal pause. Confirm removed fillers strike through as words and pauses appear as crossed-out bracketed tokens in the same transcript. Tap tokens to restore/reapply them, then compare Original and Cleaned. Result: ___
5. **Validate private immutability.** Restore Original, reopen the Margin outside sharing, and confirm the private recording/transcript was never rewritten. Result: ___
6. **Linkless rights enabled.** On pasted text or an imported PDF, enable **I’m sharing this privately and have the right to share this item**, export, and import on a clean recipient installation. Confirm the exact listened-to text is added and no original document container is claimed to be included. Result: ___
7. **Linkless rights declined.** Export the same item without the confirmation. On a recipient without that item, confirm import explains that the matching text/PDF/EPUB is required and cannot attach the Margins. Add the same item, reopen the package, and confirm import becomes available. Result: ___
8. **App-authored sample.** Share the Welcome sample. Confirm it no longer fails for lack of a canonical URL and that the app-authored disclosure is shown. Result: ___
9. **Linked item.** Share a URL-backed item. Confirm the disclosure says reference-only and the preview/package never claims to contain the full item. Result: ___
10. **Imported item entry point.** Open the imported item. Confirm Start/Continue Listening is available before a long scroll, the empty-chapters panel says mapless playback is available, and only one Generate Listening Map action is shown. Result: ___
11. **Podcast post-Margin capture.** Stream a progressive MP3 or M4A podcast without pre-downloading it, record a Margin, then let the podcast play for at least 12 seconds. Confirm the sender warning clears and diagnostics report `complete:decoded_playback_post_resume`; confirm no second full podcast download occurs. Repeat with two closely spaced Margins and confirm both obtain evidence. Result: ___
12. **Podcast interruption and fallback.** While a post-Margin sample is pending, seek or change items and confirm the sender reports unavailable evidence rather than success. Try a stream form that does not expose decoded PCM and confirm it times out/falls back without blocking sharing. Result: ___
13. **Podcast cross-edition case.** Export the streamed sender package to a recipient edition with different ads and confirm only evidence-backed placements interrupt. Any wrong confident placement is release stopping. Result: ___
14. **Companion prompt.** With auto-play off, cross a verified text Margin and a verified podcast Margin. Confirm the source pauses, the double cue sounds, and Listen/Dismiss appear in playback and the Live Activity. Confirm Listen plays the Margin then resumes the source, while Dismiss resumes without playing it. Result: ___
15. **Guided and explicit controls.** Turn auto-play on and confirm the cue completes before the Margin starts, then source playback resumes. Turn it off and confirm opt-in behavior returns. Validate Fresh and muted-cue behavior separately. Result: ___
16. **Persistence and idempotency.** Relaunch and confirm the layer, auto-play/reveal mode, mute state, resolution, and Timeline rows persist. Reimport the same package and confirm no duplicate layer is created. Result: ___
17. **System share sheet.** After **Share Reviewed Margins**, tap **Share File** and send the `.spokenmargins` file through the desired real sharing channel. Result: ___
18. **Bulk preparation at scale.** Create or seed a session with many aligned Margins, include the desired ones, and tap **Prepare All Included**. Confirm completed/total progress advances, the UI remains responsive, Cancel stops the queue, retry remains available for the interrupted Margin, and one failed recording falls back without blocking the rest. Review several results and exercise per-Margin Undo/Redo. Result: ___
19. **Margin playback rate.** Set item playback to 1.75×. Play a private Margin, then cross a received Margin in Companion and Guided modes. Confirm each voice plays at 1.75×, the cue remains normal speed, and the item resumes at 1.75× afterward. Repeat at 1×. Result: ___
20. **Timeline sharing shortlist.** While listening, star several Margins from their Timeline rows. Confirm the star does not open the Margin, the rest of the row still does, and the starred state persists after relaunch. Result: ___
21. **Private sharing note.** Open a Margin, add and save a sharing note, then confirm it appears on the Timeline and in sender review as private context. Export the package and session archive, import on another installation, and confirm the note is absent everywhere outside the sender's local library. Result: ___
22. **Starred review filtering.** With at least one star, open Share and confirm the initial view and inclusion set contain only starred Margins. Switch between All and Starred, then use **Include this Margin** to make a different final export choice. Remove every star, reopen Share, and confirm the legacy all-included default returns. Result: ___
23. **Bounded transcript review.** Review one transcript shorter than 10 rendered lines and confirm there is no unnecessary expansion control. Review a longer transcript and confirm it starts at no more than 10 lines, expands to the complete inline word/pause editor, and collapses again without losing edits. Result: ___
24. **Noisy non-speaking gap.** Record a Margin with speech, a long pause containing steady fan/traffic/music-like background sound but no speech, and more speech. Prepare cleanup, confirm the gap appears as one reversible bracketed proposal, preview Cleaned, and verify the noise gap is shortened without clipping either spoken phrase. Result: ___
25. **Authenticated Lock Screen response.** In Companion mode, lock the phone before a verified received Margin. After the cue, wake and authenticate the phone, then confirm Listen and Dismiss are visible and actionable in the Live Activity. Exercise both actions and repeat if iOS shows the supplemental small presentation. Result: ___
26. **Ordered chapter/Margin navigation.** On a podcast with no chapters, confirm the Live Activity's next entry becomes the next verified Shared Margin. Repeat with publisher chapters and confirm the nearer chapter or Margin is shown. Select a Margin and verify playback moves to its resolved anchor, applies the cue/reveal policy, and returns to the source; confirm unresolved/ambiguous Margins never appear. Result: ___

## Acceptance and stopping rules

Mark the MVP `human_validated` only after accepting the sender disclosure, linkless rights-on and rights-off paths, linked-item reconstruction, Timeline curation/privacy behavior, bounded word/audio review including a noisy non-speaking gap, a real system-share transfer, recipient import, authenticated Lock Screen response, ordered chapter/Margin navigation, Companion and Guided listening, persistence, and conservative podcast behavior.

Stop on any wrong confident cross-edition placement, podcast/item-audio leakage, item embedding without the displayed rights basis, private curation metadata in an export, transcript insertion, a cleanup proposal overlapping aligned speech, navigation to an unresolved Margin, unreviewed representation export, private-original mutation, autoplay during import, duplicate imported layer, or library disappearance after upgrade.
