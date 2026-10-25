# Spoken Margins Tester Walkthrough Video Guide

> Historical walkthrough: runtime exclusions and screenshots in this guide predate Build 22. Use the Build 22 quality-of-life handoff for current validation scope.

Prepared against Spoken Margins 0.1 (build 9) and the active Recovery MVP on
July 24, 2026.

## Recommended Deliverables

Make two videos from the same source footage:

1. A 3–4 minute tester walkthrough for YouTube. An unlisted video is fine during
   the beta. Link it from the TestFlight Beta App Description, the build's
   What to Test notes, and eventually the Spoken Margins support page.
2. A separate 15–30 second App Store App Preview. Do not try to compress the
   complete tutorial into this cut. Its job is to communicate the core promise:
   import, listen, interject, discuss, and export.

Apple documents App Previews as App Store product-page media, but does not
document a comparable hosted-video field for TestFlight. TestFlight provides a
Beta App Description, What to Test information, a feedback email, and, when
available, approved App Store screenshots in the invitation experience. A
YouTube or support-page URL is therefore the practical tutorial route for beta
testers. Place the full URL in the TestFlight text even if the current
TestFlight client does not render it as a tappable link.

Apple's current App Preview guidance says to use footage captured on a device.
Use the Simulator for the YouTube walkthrough and editing rehearsal. For the
App Store cut, recapture the chosen sequence on a physical iPhone to follow that
guidance and to show device-dependent behavior accurately.

## The Story the Video Should Teach

Spoken Margins is a conversational listening workspace:

```text
bring in something worth hearing
→ listen and navigate
→ interrupt with an anchored spoken note
→ optionally summarize or discuss with OpenAI
→ export the useful context
```

The video should teach this loop before showing every intake method or setting.
The user does not need an OpenAI API key for importing, listening, interjections,
Timeline review, or export. AI features additionally require a user-supplied
key, a network connection, and explicit data-sharing permission.

## Recording Setup

### Protect secrets and personal material

- Load the API key before recording.
- Never show the key being pasted or reveal it in a clipboard manager,
  notification, terminal, edit history, or text overlay.
- If Settings appears, the SecureField should remain masked. It is safe to show
  the provider name and a successful Probe result.
- Use a purpose-made article and podcast, not private reading material.
- Disable Mac and Simulator notifications, Focus banners, and password-manager
  overlays.
- Review every exported frame before publishing.

### Prepare a clean demo state

- Use Spoken Margins 0.1 build 9, or replace the version/build references in
  this guide if a later TestFlight build is recorded.
- Start with the seeded **Welcome to Spoken Margins** item visible.
- Add one short, public-domain or creator-owned article with clear headings.
- Prepare one short podcast episode or direct-audio URL that resolves reliably.
- Generate or apply the article's Listening Map before the main take unless the
  generation step itself is being demonstrated.
- Preflight one short AI summary and follow-up so the network and selected
  models are known to work.
- Allow microphone and Speech permissions before the polished take, unless the
  permission explanation is intentionally part of the video.
- Set text large enough to remain readable after YouTube compression.
- Keep the Simulator in portrait orientation and at a stable scale.

### Record picture first, narration second

Do not narrate the polished take live. During **Interject**, Spoken Margins needs
the microphone for the user's note; a live tutorial narration would become the
note. Record the app flow first, speak only the deliberate sample interjection,
then add the tutorial voiceover in the editor.

A good sample interjection is:

> This makes me wonder whether listening changes which details I notice.

Leave one or two seconds of silence around taps and screen changes. They are
useful edit points.

### Simulator capture

The Simulator menu command **File → Record Screen** is sufficient for the
YouTube source cut. The command-line equivalent is:

```bash
xcrun simctl io booted recordVideo --codec=h264 ~/Desktop/spoken-margins-walkthrough.mov
```

Press Control-C to finish. If the home indicator, cursor, or simulator chrome is
included, crop consistently in the editor. Record at the Simulator's native
pixel size when possible; do not upscale a small window capture.

## Main Tester Walkthrough: Shot List and Voiceover

Target length: 3–4 minutes. The timings are edit targets, not requirements.

### 0:00–0:15 — The promise

**Picture**

- Open on the Home library.
- Hold on **Welcome to Spoken Margins**, the Getting Started card, and the
  **Add Source** button.

**Voiceover**

> Spoken Margins turns articles, notes, PDFs, and podcasts into listening
> sessions. While you listen, you can leave spoken notes at the exact point
> that prompted them, discuss those notes with AI if you choose, and export the
> whole exchange.

### 0:15–0:40 — Bring in content

**Picture**

- Tap **Add Source**.
- Briefly show the Podcast Link field, Plain Text fields, **Import Text or PDF
  Files**, and Quick Folder.
- Paste a prepared title and short article, then tap **Add and Listen**.

**Voiceover**

> Start with Add Source. You can paste text, import Markdown, plain-text, or
> text-based PDF files, choose a quick folder, or add a podcast episode, RSS
> feed, or direct-audio link. Safari can also send selected text or a readable
> article into the library.

**Do not claim**

- Scanned or image-only PDFs work; they require OCR before import.
- The in-app link field extracts ordinary web articles; it is for podcast, RSS,
  or direct-audio links. Safari handles article capture.

### 0:40–1:00 — Item and Listening Map

**Picture**

- Show the item detail page.
- Scroll from Overview to Listening Map and Resolved Chapters.
- If a map is already present, tap or point to a chapter. If generation is fast
  and reliable, show **Generate Listening Map** in a separate cut.
- Tap **Start Listening**.

**Voiceover**

> Each item can have a Listening Map: an overview and chapter structure that
> restores some of the skimming and navigation you lose in audio. Markdown
> headings can create structure locally, or you can request an AI-generated map
> when OpenAI is configured. A map is helpful, but it is not required to listen.

### 1:00–1:30 — Listen and navigate

**Picture**

- Let playback run.
- Show play/pause and previous/next.
- Open the playback-speed control.
- Tap **Text** to show the native source text, then close it.
- Open Timeline and jump to a source chapter.
- Return to Home for a moment so the persistent mini-player is visible, then
  reopen Now Playing.

**Voiceover**

> Spoken Margins reads text with an on-device app or installed iOS voice.
> Pause, resume, change speed, view the text you are hearing, or move by
> sentence, paragraph, or section. Returning to the library does not end the
> session—the mini-player keeps your place and brings you back.

**Optional podcast insert**

> Podcasts use their native audio timeline instead, with scrubbing and
> configurable back and forward intervals.

### 1:30–1:58 — Make an interjection

**Picture**

- Tap **Interject**.
- Speak only the prepared sample note.
- Tap **Done**.
- Allow playback to resume.

**Live recorded note**

> This makes me wonder whether listening changes which details I notice.

**Voiceover, added after the capture**

> When something catches your attention, tap Interject, say the thought, and
> tap Done. The note is saved to this session and anchored near the text or
> media position you were hearing. Playback resumes while transcription can
> finish in the background.

### 1:58–2:20 — Review the Timeline

**Picture**

- Open **Timeline**.
- Tap the new interjection.
- Show the recording/transcript and nearby before-and-after context.
- Show the one-action copy control, then close the detail.

**Voiceover**

> The Timeline holds source chapters, your interjections, and later AI turns.
> Open a note to review its recording or transcript and the nearby context.
> You can copy a single note with its anchors or keep it for the full-session
> export.

### 2:20–2:55 — Optional AI

**Picture**

- Tap **Summarize Notes**.
- If this is the first request, show the data-sharing consent sheet long enough
  to read its purpose, then grant consent.
- Show the streamed summary appearing.
- Tap **Discuss**, enter a short follow-up, and submit it.
- Briefly show that an AI turn can be played or receive its own interjection.

**Suggested follow-up**

> Turn my note into one question I could use to revisit this article.

**Voiceover**

> AI is optional. Summarize Notes synthesizes the interjections in this session.
> Discuss answers a follow-up using relevant source, note, and conversation
> context. Spoken Margins asks for separate permission before sending that text
> to OpenAI, does not send the recorded audio, and disables response storage.
> Responses stream into the Timeline and can be listened to like the source.

### 2:55–3:20 — Export

**Picture**

- Open **Export**.
- Show the session picker.
- Switch between **AI Handoff Markdown** and **Full JSON Archive**.
- Show Original, Source Notes, and Full Session scopes.
- Leave useful inclusions enabled and show the preview.
- Tap **Copy** or open **Share Session**.

**Voiceover**

> Export is how the session leaves Spoken Margins. Choose the listening pass,
> Markdown or JSON, and how much source, map, note, and AI context to include.
> Copy the result into another chatbot or share the session as a file.

### 3:20–3:45 — Other daily-driver features

**Picture**

Use a quick montage:

- A podcast item showing download state.
- Safari's **Send to Spoken Margins** extension.
- Settings showing voice choice, speaking rate, text navigation, and media skip
  intervals.
- A recoverable Recently Deleted item.
- **Share Diagnostics**.

**Voiceover**

> Spoken Margins also supports Safari and share-sheet intake, offline podcast
> downloads, selectable voices and navigation units, recoverable deletion, and
> diagnostics you can share for beta feedback. Help inside the app always
> contains the same guided tour and source-specific instructions.

### 3:45–3:55 — Close

**Picture**

- Return to the Home library or Help checklist.
- Hold long enough to make the end edit feel intentional.

**Voiceover**

> The loop is simple: bring something in, listen, leave a margin note, and keep
> the useful context. Thanks for helping test Spoken Margins.

## 30-Second App Store Preview

This is a product preview, not a tutorial. Recapture the selected shots on a
physical iPhone and use only screen captures of Spoken Margins itself. Narration
and explanatory text overlays are allowed under Apple's current review
guidelines.

| Time | Picture | Voiceover or overlay |
| --- | --- | --- |
| 0–4s | Home library → Add Source | “Turn articles, notes, PDFs, and podcasts into listening sessions.” |
| 4–9s | Item overview and Listening Map → Start Listening | “Navigate ideas with a Listening Map.” |
| 9–15s | Playback controls → Interject → Done | “Leave a spoken note exactly where the thought occurred.” |
| 15–22s | Timeline note → streamed AI summary or discussion | “Optionally summarize and discuss with your own OpenAI key.” |
| 22–27s | Export options and preview | “Export the source, notes, and conversation.” |
| 27–30s | Home library or Help completion screen | “Spoken Margins — listen, respond, keep the useful parts.” |

For App Store delivery, verify the exact current requirements before export.
As of July 24, 2026, Apple documents:

- 15–30 seconds per preview.
- Up to three previews per supported device size and language.
- Up to 500 MB.
- H.264 or ProRes 422 HQ, no more than 30 fps.
- `.mov`, `.m4v`, or `.mp4` for H.264.
- Stereo audio at 44.1 or 48 kHz; H.264 audio uses 256 kbps AAC.
- Device-size-specific accepted resolutions.
- App-only screen capture; narration and textual overlays may explain the UI.

Sources:

- [Apple: App Previews](https://developer.apple.com/app-store/app-previews/)
- [Apple: App Preview specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/app-preview-specifications)
- [Apple: Upload app previews and screenshots](https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots)
- [Apple: App Review Guidelines, 2.3.4](https://developer.apple.com/app-store/review/guidelines/)
- [Apple: Provide Test Information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information/)

## TestFlight Copy

Replace `[VIDEO URL]` after the YouTube upload.

### Beta App Description

> Spoken Margins is a personal conversational listening app for articles,
> notes, text-based PDFs, and podcasts. Listen with native audio or an
> on-device voice, leave spoken interjections anchored to what you were
> hearing, optionally summarize or discuss them with OpenAI, and export the
> complete context. A user-supplied OpenAI API key is required only for AI
> features. Walkthrough: [VIDEO URL]

### What to Test

> Start with the Welcome to Spoken Margins item or the guided tour in Help.
> Please test: (1) import or open an item, (2) listen and navigate, (3) record
> and review an interjection in Timeline, (4) optionally summarize or discuss
> it using your OpenAI key, and (5) copy or share the session export.
>
> Also try one intake path you normally use: Safari article capture, the share
> sheet, a Markdown/plain-text/text-based PDF file, or a podcast episode link.
> Playback, notes, Timeline review, and export work without AI.
>
> Full walkthrough: [VIDEO URL]
>
> For feedback, take a screenshot in TestFlight. When useful, attach Settings →
> Help & Privacy → Share Diagnostics. Please report the device,
> iOS version, expected result, actual result, and whether it reproduces.

## Complete Feature-Coverage Checklist

The main video should demonstrate the core loop and mention the rest. A feature
does not need equal screen time merely to count as covered.

### Core loop — demonstrate

- [ ] Home is a library, not an import form.
- [ ] Welcome item and resumable guided tour.
- [ ] Open an item and start or continue a listening session.
- [ ] Play/pause and semantic text navigation.
- [ ] Playback speed and native text view.
- [ ] Listening Map overview and chapter navigation.
- [ ] Return Home without losing the session; reopen from the mini-player.
- [ ] Record, finish, and save an interjection.
- [ ] Review the interjection in Timeline with nearby context.
- [ ] Copy one interjection.
- [ ] Explain AI as optional.
- [ ] Summarize Notes.
- [ ] Discuss with a follow-up.
- [ ] Show streamed/playable AI content in Timeline.
- [ ] Export AI Handoff Markdown or Full JSON.
- [ ] Copy or share a session.

### Intake — show or mention accurately

- [ ] Paste plain text with a title.
- [ ] Import UTF-8 plain text.
- [ ] Import Markdown or Obsidian clips.
- [ ] Import a text-based PDF.
- [ ] State that scanned/image-only PDFs require OCR.
- [ ] Choose and reuse a Quick Folder.
- [ ] Add a podcast episode, RSS feed, or direct-audio URL.
- [ ] Safari extension: selected text or readable page.
- [ ] iOS share sheet: web page, Markdown, text, PDF, or supported media link.
- [ ] State that the in-app Link field is not ordinary article extraction.
- [ ] Failed shares can be retried or deleted in Import Inbox.

### Playback and system behavior — mention; use a physical device for proof

- [ ] Select the app voice or an installed iOS voice.
- [ ] Change speaking rate.
- [ ] Choose sentence, paragraph, or section text navigation.
- [ ] Podcast scrubber with configurable skip intervals.
- [ ] Podcast streaming and automatic Wi-Fi download/cache behavior.
- [ ] Lock Screen/Now Playing controls.
- [ ] Listening Live Activity.
- [ ] Background playback and route/interruption behavior.

Do not present Simulator footage as validation of Lock Screen, Live Activity,
microphone, Bluetooth, share-extension, Safari-extension, or background behavior
on a physical device.

### Library, sessions, and recovery — show or mention

- [ ] Continue Listening resumes the latest unfinished session.
- [ ] Start New Session creates a distinct listening pass and notes.
- [ ] Closing the mini-player saves the place and stops playback; it does not
  delete the session.
- [ ] Batch export saves one Markdown file per selected session.
- [ ] Move an item to Recently Deleted and undo or restore it.
- [ ] Permanent deletion requires another confirmation.

### AI, privacy, and support — show or mention

- [ ] API key remains masked and is never present in footage or export.
- [ ] Provider Probe succeeds before recording AI scenes.
- [ ] Separate model identifiers exist under Advanced model settings.
- [ ] First live AI request asks for data-sharing consent.
- [ ] Explain that source/context text may be sent, but recorded audio, local
  paths, and internal database identifiers are not.
- [ ] Explain that OpenAI response storage is disabled.
- [ ] Revoke data sharing and delete the key are available in Settings.
- [ ] Privacy Policy, Terms, Support, and on-device voice legal information.
- [ ] Share Diagnostics for beta feedback.

### Explicitly out of scope for this release — do not advertise

- [ ] Apple Watch app.
- [ ] Standalone Home Screen widgets.
- [ ] Dedicated CarPlay UI.
- [ ] Arbitrary AI providers.
- [ ] OCR for scanned/image-only PDFs.
- [ ] Embedded Piper or Kokoro/MLX runtime.

## Final Publication Audit

### Content

- [ ] Every claim matches the build being distributed.
- [ ] The core promise is stated in the first 15 seconds and the full core loop
  is demonstrated within the first two minutes.
- [ ] AI is labeled optional and as using the tester's own API key.
- [ ] Intake paths are not conflated: Safari handles web articles; Add Link
  handles podcast/RSS/direct audio.
- [ ] The video does not imply that automated checks or Simulator footage are
  physical-device validation.

### Privacy and rights

- [ ] No API key, private source, email, file path, device identifier, personal
  notification, or private diagnostic appears.
- [ ] Article, podcast, music, and imagery are owned, licensed, public domain,
  or used with permission.
- [ ] Export previews contain only demo material.

### Technical

- [ ] Voiceover is clear on phone speakers and headphones.
- [ ] Text remains readable at normal YouTube playback size.
- [ ] Taps have enough visual dwell time to follow.
- [ ] Captions are uploaded and manually corrected.
- [ ] The App Preview is independently checked against Apple's current duration,
  resolution, codec, audio, and file-size requirements.
- [ ] The selected App Preview poster frame communicates the app without autoplay.
- [ ] The final upload is watched once from beginning to end after processing.

### Falsification pass

Before publishing, ask a fresh viewer to answer these without coaching:

1. What is the app for?
2. How do you add an article versus a podcast?
3. What happens when you make an interjection?
4. Which features require an API key?
5. How do you get the session out of the app?

If any answer is wrong or missing, revise the relevant scene or voiceover. Stop
publication if the video exposes a secret, advertises an out-of-scope feature,
or shows a flow that does not work in the exact distributed build.
