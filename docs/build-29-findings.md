# Build 29 findings and handoff

Date: 2026-09-25. Branch `anchor-reliability`, build number 29 (commit `0e17896`), not yet uploaded. Keep iterating on build 29; don't bump the number until the owner uploads.

Sources of evidence:

- The owner's phone pass on Build 29: a streamed Odd Lots episode, six spoken Margins, a diagnostics export and the exported packet `Hollywood-Was-Cooked-Before-AI-and-Now-It-s-Only-Getting-Worse-f8d93c6c.spokenmargins`.
- Agent journeys on the iPhone 17 simulator, run over an existing Library.
- Code reading, with file and line references below.

Labels used below:

- **Device**: the owner saw it on the phone.
- **Reproduced**: an agent reproduced it in the simulator or on the host.
- **Code**: confirmed by reading the code.
- **Inference**: likely, but not yet shown.

## Summary

| # | Issue | Finding | Evidence | New in 29? | Priority |
|---|---|---|---|---|---|
| 1 | #154 | Podcast anchor capture never produces evidence on a streamed episode, and possibly on downloaded ones too | Device + Code | No. Build 28 never ran capture at all | Blocks the anchor goal |
| 2 | #155 | Capture failures can't be diagnosed: the reason is overwritten, Margin IDs collide, diagnostics are lost on relaunch, and the export doesn't identify the build | Device + Code | No | Do first; it's cheap and unblocks 1 |
| 3 | #156 | Source context transcription fails on streams ("Operation Stopped"), so shared Margins carry no text context | Device + Code | No | High |
| 4 | #157 | Importing a shared podcast packet fails with a raw `shared_podcast_item_is_ambiguous` error (Omny / Odd Lots) | Reproduced + Code | No, same in Build 28 | High |
| 5 | #158 | Shared Margins that aren't placed can't be navigated to; the recipient has to scrub blindly | Device + Code | No | High (slice 6) |
| 6 | #159 | "Play this moment" plays the source from the Margin's anchor and never plays the Margin | Device + Code | No, this is how it was built | Product decision |
| 7 | #160 | Resuming after a spoken Margin on a stream takes 2.6–9.3 s (1.1 s on a downloaded episode) | Device + Code | Unknown | Medium |
| 8 | #161 | Main thread freezes for 1.6–2.7 s roughly every 17 s | Device; cause is inference | Unknown | Medium |
| 9 | #162 | A PDF download stamp is still read aloud when the page number shares its line | Device + Reproduced | Fix is new in 29 but incomplete | Low, easy |
| 10 | #144 | A web article pasted into "Link or Podcast" is rejected as "not a playable podcast/audio file" | Reproduced + Code | No | Medium |
| 11 | #163 | The microphone-denied banner says "interjections" | Reproduced | No | Low |
| 12 | #164 | App-hosted tests write test data into the simulator app's real container | Reproduced | No | Low |

## What passed

- **Checks:** the fast host plan, simulator and device builds, and the app-hosted XCTest plan all passed on `0e17896`.
- **J2 (seek after relaunch):** passed in the simulator and on the owner's phone. The log shows the paused seek to 3:01 was accepted and playback started there.
- **J3 step 1 (written Margin):** passed in the simulator. The owner recorded spoken Margins on the phone and they save and resume.
- **Imported Margins play their voice (J5 step 4):** passed on the phone.
- **The rest of the PDF check (J7):** passed on the phone. Only the stamp issue in finding 9 remained.

## Systematic patterns

These patterns explain more than one finding. Fixing them is worth more than any single bug.

1. **Tests fake the exact boundary that broke.**
   - Capture tests use a fake media client, or feed buffers straight into the tap context.
   - "Play this moment" and resume tests use no-op audio clients.
   - No test plays a real `AVPlayerItem`, and none uses a stream. This is why findings 1, 3 and 7 went unnoticed.
2. **Streamed and downloaded audio behave differently, and only downloads are exercised.**
   - Capture, source-window transcription and resume all degrade on streams.
   - The owner listens mostly to streams (the podcast here was `streaming_only`).
3. **Diagnostics can't answer the question they exist for.**
   - Reasons are overwritten, IDs aren't unique, values live only in memory, and the build isn't identified.
   - The always-on playback log was the one reliable source; every timing in this document comes from it.
4. **Raw internal codes reach users.** `persistence_failed:shared_podcast_item_is_ambiguous` appears in the import sheet, and "interjections" appears in a banner.
5. **Heavy work runs on the main actor.** See finding 8. `Gate1AppModel` is `@MainActor`, so any loop or query it runs blocks the UI.

---

## 1. Podcast anchor capture never produces evidence on a stream

**Seen (Device).**
- All six Margins show `podcastAnchorEvidence:ij-00N = unavailable:no_exact_local_playback_edition`.
- The episode was `streaming_only`.
- The exported packet has `evidence=0`. Each anchor is only `{anchorType: media, mediaTimeMs, roughPercent, machineEvidenceAssetIds: []}`.

**Root cause.**
- (Code) Streams aren't excluded on purpose. Streamed and downloaded episodes share one player (`AVPlayerStreamPlaybackClient`), and both the engine and the tap accept `.remoteStream`:
  - `Packages/SessionKit/Sources/SessionKit/SessionEngine.swift:2406-2413`
  - `Packages/SessionKit/Sources/SessionKitAudio/AudioAdapters.swift:2242`
- (Code) The continuous 20 s ring-buffer tap is installed only once, straight after `AVPlayerItem(url:)` is created (`AudioAdapters.swift:1776-1788`). The install gives up silently if `item.tracks` has no audio track (`AudioAdapters.swift:2243`), and it is never retried.
- (Inference, strong) A new `AVPlayerItem` has no tracks yet, so the continuous tap probably never installs. That affects downloaded episodes too. With no tap, the pre-window capture always returns false (`AudioAdapters.swift:1944-1946`).
- (Code) The post-window capture installs a tap mid-playback (`AudioAdapters.swift:1885-1935`).
  - We can't tell whether it failed straight away, or later: a 60 s timeout, too little audio, or no audio from the tap (`PostResumePodcastEvidenceCapture.swift:125, 244`).
  - That is finding 2: the reason was overwritten.
- (Code) When capture fails, `scheduleTranscription` falls back to `schedulePodcastAnchorEvidenceCapture`, which needs a downloaded file (`Gate1AppModel.swift:12364-12365, 12430-12442`).
  - On a stream the fallback records `no_exact_local_playback_edition`, which hides the real failure.

**Fix direction.**
1. Fix finding 2 first, so the next device run can be diagnosed.
2. Install the continuous tap when the item reaches `readyToPlay` and has an audio track, not when it is created.
3. Make the post-window result independent of the pre-window result. That's already listed for slice 3 in `docs/podcast-anchor-plan.md`.

**Tests that must fail first.**
- A macOS host test that plays a real local audio file through the real player and router for about 20 s. It then asserts that pre-window capture returns true and produces a signature. Expect it to fail today because the install happens while `tracks` is still empty.
- A second test that serves the same file over loopback HTTP, to cover remote items.

**Verify on device.** Record three spoken Margins on a streamed episode and three on a downloaded one. Copy diagnostics before closing the app. Every Margin should show `complete:N`, or a specific reason.

## 2. Capture failures can't be diagnosed

**Seen (Device).**
- The only capture reason exported was the fallback's.
- One `sourceWindowSignature:ij-001 = complete:2` entry appeared with no match among the six streamed Margins.
- The export's `developerBuild` reads `device-diagnostics-20260908-C`.

**Root cause (Code).**
1. **Reasons are overwritten.**
   - When post-window capture fails straight away, the Margin is marked `.unavailable`, and the fallback then overwrites both the diagnostic and the stored `podcastAnchorEvidenceFailureReason` (`Gate1AppModel.swift:12696-12703`).
   - On a later stream failure, `stream_failed:<reason>` is written and then overwritten by the same fallback (`Gate1AppModel.swift:12549-12552`).
2. **IDs collide.**
   - `ij-NNN` is a counter within one session (`SessionEngine.swift:1509, 1515`).
   - Diagnostics are one flat `[String: String]` (`Gate1AppModel.swift:620`).
   - So `ij-001` from a downloaded-episode session sits beside the streamed session's `ij-001`. (Inference: the `complete:2` entry is from the owner's earlier Margin on a downloaded episode.)
3. **Values live only in memory.** `RuntimeDiagnostics` is not saved, so force-quitting before copying diagnostics loses them.
4. **The build isn't identified.** `DeveloperDiagnosticRecording.swift:8` hard-codes `buildIdentity = "device-diagnostics-20260908-C"`. An export can't prove which build produced it.

**Fix direction.**
- Keep the first failure and append later ones.
- Key diagnostics by session and Margin.
- Include `CFBundleShortVersionString` and `CFBundleVersion` in the export.
- Save each Margin's capture status and reason with the Margin in SQLite. The fields already exist on `Interjection`, so export can read them after a relaunch.

## 3. Source context transcription fails on streams

**Seen (Device).** Every Margin shows `sourceWindowTranscription = failed:Operation Stopped` and `sourceWindowContextProvenance = unavailable`, and its anchor has no before or after text.

**Root cause.**
- (Code) Without a local file, the source window is taken from the episode's remote URL (`Gate1AppModel.swift:12212-12215`).
- (Code) The window is then exported with `AVAssetExportSession` (`AudioAdapters.swift:3388, 3404-3409, 3651-3664`).
- (Inference) "Operation Stopped" is AVFoundation's usual message for error -11838, which means the operation isn't supported for this media. The export fails, so speech recognition never runs.

**Why it matters.** With neither fingerprints nor text, a shared Margin carries only a bare timestamp. The recipient's app correctly refuses to trust it.

**Fix direction.** Build the window from the continuous tap's ring buffer (after the finding 1 fix), or download the byte range with `URLSession` into a temporary file first.

**Test.** Serve an MP3 over loopback HTTP, request the source window, and expect transcript text. It should fail today.

## 4. Importing a shared podcast packet fails

**Seen (Reproduced).** Opening the owner's Hollywood packet on the simulator, which has never had the episode, fails in the import sheet with `persistence_failed:shared_podcast_item_is_ambiguous`. This is J5 step 2.

**Root cause (Code, plus live data fetched on 2026-09-25).**
- `acquirePodcastForImportedPackage` (`Gate1AppModel.swift:7943-7990`) resolves the packet's canonical Omny URL.
- `PublicPodcastLinkResolver` fetches the episode page, but that page has no inline play metadata. The resolver never follows the RSS links the page carries (`omny.fm/shows/odd-lots/playlists/podcast.rss`).
- So it returns `needsReview` with one candidate that has:
  - `audioURL = nil`
  - `durationMs = nil`
  - a title from `og:title` with an undecoded `&#x27;` and " - Odd Lots" appended
- Neither selection rule can match that candidate (`Gate1AppModel.swift:7970-7985`).
- The real feed would match.
  - Its enclosure is byte-identical to the packet's, and its `guid` and `omny:clipId` equal the clip ID in the enclosure path.
  - Its title matches exactly, with a straight apostrophe.
- Duration would not have helped. The feed says 1,927 s, the packet says 2,406.6 s, and the tolerance is about 12 s (`Gate1AppModel.swift:8121-8124`). That's dynamic ad insertion, which the sender's own stream also showed mid-session (2,381 s, then 2,406 s).
- The error is shown raw: `spokenMarginsPackageImportError = error.localizedDescription` (`Gate1AppModel.swift` ~7814), displayed in `SharingExperience.swift` ~212.
- (Code) This isn't a regression. The same branch exists at `testflight/0.1-build-28`, and the resolver hasn't changed since. Build 29's `44d3c95` only handles the case where the fetch throws.

**Fix direction.**
1. In the resolver: when a page has no inline metadata, follow its RSS link and select the item by `link` or `guid`.
2. In the import match: compare enclosures after stripping tracking prefixes (podtrac, swap.fm, chtbl, pdst.fm) and the query string, and accept a `guid` or clip-ID match.
3. Treat duration as a loose tie-breaker, never as an identity check, for podcasts with dynamic ads.
4. When no candidate has audio, fall back to `packagePodcastLinkResolution`, as the fetch-error path already does.
5. Map `shared_podcast_*` codes to plain sentences.

**Test.**
- In `App/SpokenMarginsAppTests/SourceLinkImportTests.swift`, serve saved copies of the Omny page and feed through `PublicPodcastLinkResolver(asynchronousFetch:)`.
- Assert the result is playable with the packet's enclosure. Add a model-level import test that expects no ambiguity error.
- Saved copies (local only, git-ignored) are at `artifacts/build29/omny_sm.html` and `artifacts/build29/feed.xml`, and the unzipped packet is at `artifacts/build29/hollywood-packet-unzipped/`. Trim the feed to the two Hollywood items before committing it as a fixture.

**Verify.** Re-import the owner's Hollywood packet in the simulator. The episode should appear in the Library, and six shared Margins should be listed with a placement status.

## 5. Shared Margins that aren't placed can't be navigated to

**Seen (Device).** The imported Margins play their voices, but finding their place in the episode means scrubbing blindly.

**Code.**
- The shared-Margin sheet shows a label such as "Position not matched", plus "Open item and shared controls". It has no jump action (`ExperienceMarginsScreen.swift:221-265`, `ExperienceModels.swift:365-373`).
- `jumpToImportedCommentary` needs a verified local position; it's only reachable from compact controls (`Gate1AppModel.swift:7161-7182, 8223`).
- The sender's time is kept (`senderMediaTimeMs`, ~15811), but nothing jumps to it, and nothing records a spot the recipient confirms.

**Fix direction.** Slice 6 in the plan:
- Add "Listen around the suggested spot", which seeks a few seconds before `senderMediaTimeMs` and labels the position as a suggestion.
- Let the recipient confirm the position, stored as `recipientConfirmed`, never as acoustically verified.

## 6. "Play this moment" never plays the Margin

**Seen (Device).** From the Margins screen, "Play this moment" jumped the podcast back about two minutes and played it, but never played the Margin. "Play recording" works.

**Code.**
- `playMarginMoment` (`Gate1AppModel.swift:2156-2195`) seeks to the saved anchor, starts the source, and calls `stopInterjectionAudioPlayback()` at `:2181`.
- `SessionEngine.playInterjectionAnchor` (`SessionEngine.swift:1435-1488`) has no lead-in and nothing that plays the Margin afterwards.
- The documented intent is "hear its source again" (`Gate1AppModel.swift:2442`). So this works as built. It doesn't match what the owner expected.
- (Inference) The "two minutes back" is where the anchor was saved. The anchor is stamped when recording starts, and the owner kept listening after it.
- A 120 s lead-in with a following Margin existed on the parked branch (`564a16d`, `park/co-op-2026-09-24`). `docs/repo-review-2026-09-24.md:40` links it to a stall, so don't port it as-is.

**Owner decision (2026-09-25).** "Play this moment" should:

1. Start about 30 s before the Margin's anchor.
2. Let the listener skip straight to the Margin. If Skim can't treat Margins as skim targets yet, show a visible "your Margin is coming up" cue with a jump-now action.
3. Play the Margin inline when the anchor is reached.
4. Continue the podcast afterwards, and play the listener's other Margins on that item inline as they come up.

Implementation notes:

- Put the sequence in a small SessionKit type, not in `Gate1AppModel`.
- Reuse the imported-Margin anchor-crossing logic (`reconcileImportedCommentary`, `Gate1AppModel.swift:7085-7111`) rather than writing a second crossing detector.
- Related issues: #115 (show the Skim destination before skipping) and #90 (Skim transport).
- Add a host test, using a real local file, that asserts the Margin plays after the anchor is crossed and that the source resumes afterwards.

## 7. Resuming after a spoken Margin on a stream is slow

**Seen (Device).** Always-on log, time from "starting" to "playing":

| Margin | Delay |
|---|---|
| 1 | 2.6 s |
| 2 | 9.3 s |
| 3 | 3.2 s |
| 4 | 5.2 s |
| 5 | 3.0 s |
| 6 | 4.3 s |
| Earlier Margin on a downloaded episode | 1.1 s |

During the 9.3 s resume, the episode's reported length changed from 2,381,244 to 2,406,609 ms.

**Code (the item is not rebuilt).** Resume keeps the same `AVPlayerItem` (`AudioAdapters.swift:1756, 1772`). Between "starting" and "playing" it does four things:

1. Reactivates the audio session synchronously on the main thread (`AudioAdapters.swift:1790-1793`), after recording deactivated it (`:2975`).
2. Seeks unconditionally with 0.25 s tolerance, even though the player is already parked at that time (`:1799-1811`).
3. Waits for the buffer, because `automaticallyWaitsToMinimizeStalling = true` (`:1779`).
4. Installs a new `audioMix` tap on the paused stream (`:1885-1932`).

(Inference) On a progressive stream, the seek and the audio-mix change can drop the buffer and trigger a new range request through the ad-insertion redirect. That request can return a different ad edition, which would explain the length change.

**Fix direction.**
- Skip the resume seek when the current time is already within tolerance.
- Install the tap once, at `readyToPlay` (the same change as in finding 1).
- Consider keeping the audio session active through recording.

**Confirm first.** Log signposts at session reactivation, seek completion and `timeControlStatus` changes, together with `item.accessLog()`. A new access-log entry after resume proves the stream was re-fetched.

## 8. Main thread freezes about every 17 seconds

**Seen (Device).** The detailed recording shows `main.delayed` intervals at roughly 17–18 s spacing on the settings, home, playback and export screens: 1635, 1727, 2727, 1902, 1919, 1832, 1935, 1806, 1923, 1934, 1689 and 1626 ms.

**Leading candidate (Code, cause is inference).**
- `startAutomaticMarginOutput` (`Gate1AppModel.swift:9660-9669`) loops `deliverAutomaticMargins()` and then sleeps 15 s, on the main actor.
- Each pass decodes every session. For every active Margin it calls `engine.buildExport` (`SessionEngine.swift:2315-2327`), which re-decodes the item's whole transcript timeline JSON (`SQLiteSessionStore.swift:359`).
- 15 s of sleep plus 2–3 s of work matches the observed spacing.
- This only runs when automatic Margin delivery is on (`automaticMarginOutputEnabled`, `Gate1AppModel.swift:858`). The owner confirmed it is on for the phone that produced this export. That makes the candidate much stronger, but it isn't proven until the stall disappears with the setting off, or a signpost shows it.
- A related naming problem: the setting is "Automatically Save Margins" in the PKM settings (`PKMSettingsViews.swift:14`). It writes text Margins into a chosen Obsidian or Files folder. The owner understood it as controlling whether shared Margins autoplay. The label and its help text should say what it does, for example "Save Margins to your notes folder".

**Second candidate.** `enqueueAutomaticAudioPreparationJobs` (`Gate1AppModel.swift:14729-14783`) walks all 176 Library items on main. It isn't periodic, though.

**Confirm.** Put a signpost around `deliverAutomaticMargins`, or turn delivery off, and record again.

**Fix direction.**
- Gather Margins off the main actor.
- Run delivery only when a Margin changes.
- Decode each timeline once per session.

## 9. A PDF download stamp is still read aloud when it shares a line with the page number

**Seen (Device).** At the very end, the owner heard "…September 2026 3" once.

**Reproduced.**
- The test PDF has a footer line "Downloaded on 25 September 2026" and a page number on the same baseline.
- iOS PDFKit merges them into one line, `Downloaded on 25 September 2026 1`.
- After importing the PDF in the simulator, the stored item text contains all three stamps (`… 2026 1`, `… 2026 2`, `… 2026 3`).
- A macOS build of the extractor gives the same result.

**Root cause (Code).**
- `isDownloadStamp` (`App/SharedSources/PDFStructuredTextExtractor.swift:372-375`) requires the line to end right after the date or time, so a trailing page number defeats it.
- The repeated-margin rule can't catch it either. Its key keeps digits (`normalized`, `:384-388`), so each page's line is unique.
- Why the owner heard only one of the three isn't established. It may come from how speech is chunked.

**Fix direction.** In the stamp regex, allow a trailing page marker (a number or a Roman numeral) separated by whitespace. Keep the rule limited to margin bands so dates in body text survive.

**Test.** Add a case to `PDFStructuredTextExtractorTests.swift` that draws the stamp and a page number on the same baseline. It fails today. The test PDF is `artifacts/build29/pdf-stamp-test.pdf`, and its generator is `artifacts/build29/makepdf.swift` (run it with `swift makepdf.swift out.pdf`).

## 10. A pasted article URL is rejected

Already tracked as #144. Reproduced on Build 29.

**Seen (Reproduced).** Pasting `https://en.wikipedia.org/wiki/Marginalia` into Add → Link or Podcast returns "I found the page or feed, but not a playable podcast/audio file." The card promises "A web article, podcast episode, feed, or public audio link".

**Code.**
- `beginSourceLinkImportFromForm` sends the URL to `importSourceLinkAsync`, then the podcast resolver, which has no article fallback.
- Article extraction (`AppOwnedReadablePageExtractor`) exists and is used by read-later and followed sources, but not by this form.
- Unchanged since Build 28.

**Fix direction.** When the resolver returns `audio_enclosure_not_found` or `unsupported_link_type` for an HTML page, fall back to `readablePageExtractor.extract(url:)`. The alternative is to change the card's text.

## 11. The microphone-denied banner says "interjections"

**Seen (Reproduced).** "Microphone access is required to record interjections." The product term is Margins.

**Fix.** Change the copy, and search the user-facing strings for the word "interjection".

## 12. App-hosted tests write into the simulator app's real container

**Seen (Reproduced).** After `--plan app`, the booted simulator's real app container held test output:

- `Library/Application Support/SpokenMargins/IncomingPackages/*`
- `EpisodeMaps/local-test/*`
- many `tmp/podcast-tests-*`, `tmp/spoken-margins-tests-*` and `Library/Preferences/*Tests*` files

The owner's phone is not affected. The risk is that journeys run in the simulator start from a polluted Library.

**Fix direction.** Point app-hosted tests at a temporary root, or run them on a separate simulator from the journeys.

---

## Recommended order

1. Finding 2 (diagnostics). Cheap, and it makes the next device run count.
2. Finding 1 (install the tap at `readyToPlay`), with a real-player host test. Then a device run on both a streamed and a downloaded episode.
3. Finding 4 (shared import). It's the first step of J5 for any Omny-hosted show.
4. Finding 9 (PDF stamp). Small and self-contained.
5. Finding 3 (source context on streams). This depends on step 2.
6. Finding 7, then finding 8, after confirming each with signposts.
7. Findings 5 and 6, once the owner decides on "Play this moment".
8. Findings 10, 11 and 12.

Each item is one small commit, with a test that fails first. Keep packets importable by Build 28.

## Not verified

- No fix has been written. Every finding is at most reproduced.
- The cause of finding 8 is an inference until it's confirmed with signposts, or by checking whether automatic delivery is on.
- Whether capture works on downloaded episodes is unknown, because of the ID collision in finding 2.
- The simulator can't play or record audio audibly. Everything audible needs the owner's phone.
