# Sharing-next product-owner validation handoff

Status: `implemented` and `verified`; not `human_validated`.

Branch: `codex/sharing-next`

Implementation commits:

- `aa187a2` (`Complete rights-aware sharing review flow`)
- `84fd071` (`Refine shared Margin review and playback prompts`)

Local build setting: version 0.1 (21)

Build 21 is already reserved for the accepted hotfix line. Allocate a new build number before distributing this sharing revision through TestFlight. Installing the new build over the existing app is the expected upgrade path; a reset is not required.

## Supported validation environment

- iPhone or iPad running iOS/iPadOS 18.0 or later.
- Simulator compilation and focused state tests are verified.
- Microphone capture, acoustic anchor generation, podcast download matching, and the listening experience require product-owner validation on a physical device.

## Implemented user path

From playback, tap the Share icon. The first panel on the resulting **Share** screen is **Share Margins**; session Markdown/JSON remains available separately under **Export listening session**.

The sender review now supports:

- choosing which Margins leave the device;
- tapping aligned words or inline bracketed pauses to remove or restore them, with explicit Undo and Redo and no text-insertion route;
- one compact transcript instead of padded word capsules plus a duplicate vertical edit list;
- automatic filler cleanup plus acoustic leading, trailing, and internal pause tightening;
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

## Podcast anchoring and recipient experience

- Podcast audio is never included.
- When the exact downloaded sender edition was available during capture, optional ShazamKit signatures provide high-reliability, non-playable cross-edition evidence.
- Recipient resolution can use exact-edition, transcript, acoustic, and fused evidence. Ambiguous, absent, wrong-item, and unresolved results never become confident interruptions.
- Recipient import is integrity checked but the sender identity remains unsigned and is labeled unverified.
- Import does not autoplay. Imported commentary remains a distinct Shared Margins layer with Fresh, Companion, and Guided behavior.
- Companion mode pauses the source at a verified text or podcast anchor, sounds the cue unless the layer is muted, and presents **Listen** and **Dismiss** in playback and the Live Activity. Listening resumes the source when the Margin ends; Dismiss resumes immediately.
- Guided mode sounds the cue and starts the Margin after the cue. **Auto-play shared Margins** on the playback screen maps enabled layers to Guided when on and Companion when off, preserving the existing persisted reveal-mode model.
- The Live Activity carries no Margin transcript. Its sender label is privacy-sensitive, while Listen and Dismiss remain visible controls and open the app to perform the in-process audio handoff reliably.
- **Create Recipient Test Session** still exercises the real archive, verification, import, persistence, resolver, and listening route on one device.

## Cleanup behavior

- Filler and word removal require aligned recognition timing.
- Acoustic cleanup examines the immutable recording, treats recognized speech as protected, shortens quiet runs of at least 360 ms, retains 80 ms at recording edges and 140 ms internally, and renders a derivative with 15 ms crossfades.
- The private recording and private transcript are never rewritten.
- Older Margins without aligned timing remain eligible for original-voice or text-only sharing, but word deletion and automatic cleanup are unavailable for them.
- Item actions now precede optional Listening Map tools, and the duplicate Generate Listening Map action was removed from the empty-chapters panel.

## Out of scope and known constraints

- EPUB ingestion itself belongs to the active quality/completion lane; the sharing schema and transport already represent EPUB-derived listened text once that item type is available to the app.
- Offline phone generation of Listening Maps, proposal activation, summary bridge playback, and Skim controls remain out of scope. Portable Listening Map proposals may travel but remain inert.
- Co-op replies, remote revocation, accounts, trust networks, hosted storage, public distribution, and AI-generated summaries are not implemented.
- High-reliability acoustic podcast evidence is available only when the exact sender edition was downloaded when the Margin was captured. The sender UI preserves the warning when evidence is absent, including after audio cleanup.
- A text-only Margin is readable but has no voice playback.
- Live Activity Listen and Dismiss open Spoken Margins because a suspended widget process cannot safely own the app's in-process source and Margin audio players.

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
- SharingTests: 26 executed, 25 passed and 1 dedicated held-out benchmark wrapper skipped by design, 0 failed.
- Focused app-state and compact-surface tests: 22 distinct tests passed, 0 failed, including verified text/podcast anchor eligibility, word-delete Undo/Redo, legacy and current Live Activity state, prompt publication, URL/queue compatibility, and compact playback policy.
- Focused item-screen UI route: 1 passed, 0 failed; Start/Continue Listening is hittable before scrolling and no second chapter-panel map generator exists.
- Generic iOS Simulator app build: passed.
- Generic physical iOS app build: passed.
- Diff whitespace check: passed.
- Existing benchmark artifact: 232 anchors, 226 eligible and 6 deliberately absent; fused/monotonic placement had zero wrong confident placements, 4 ms p95 error, and declined all 6 absent passages. See `podcast-anchor-benchmark.md` and `podcast-anchor-benchmark-result.json`.

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
11. **Podcast cross-edition case.** Download a podcast, record well-separated Margins, export to a recipient edition with different ads, and confirm only evidence-backed placements interrupt. Any wrong confident placement is release stopping. Result: ___
12. **Companion prompt.** With auto-play off, cross a verified text Margin and a verified podcast Margin. Confirm the source pauses, the double cue sounds, and Listen/Dismiss appear in playback and the Live Activity. Confirm Listen plays the Margin then resumes the source, while Dismiss resumes without playing it. Result: ___
13. **Guided and explicit controls.** Turn auto-play on and confirm the cue completes before the Margin starts, then source playback resumes. Turn it off and confirm opt-in behavior returns. Validate Fresh and muted-cue behavior separately. Result: ___
14. **Persistence and idempotency.** Relaunch and confirm the layer, auto-play/reveal mode, mute state, resolution, and Timeline rows persist. Reimport the same package and confirm no duplicate layer is created. Result: ___
15. **System share sheet.** After **Share Reviewed Margins**, tap **Share File** and send the `.spokenmargins` file through the desired real sharing channel. Result: ___

## Acceptance and stopping rules

Mark the MVP `human_validated` only after accepting the sender disclosure, linkless rights-on and rights-off paths, linked-item reconstruction, word/audio review, a real system-share transfer, recipient import, Companion and Guided listening, persistence, and conservative podcast behavior.

Stop on any wrong confident cross-edition placement, podcast/item-audio leakage, item embedding without the displayed rights basis, transcript insertion, unreviewed representation export, private-original mutation, autoplay during import, duplicate imported layer, or library disappearance after upgrade.
