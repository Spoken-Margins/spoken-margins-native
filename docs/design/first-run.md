# First run, reimagined

**Flow:** from installing Spoken Margins to finishing the first article or episode.
**Written:** 4 October 2026, against `next` at `1744dff`.
**Status:** design only. Nothing here is built or tried on a device. No issues filed, no labels changed.

## The short version

1. **Today, the first thing a new listener meets is a legal document.** It appears when they press Play, even on a podcast that doesn't need the voice it's asking about.
2. **The app never shows its best trick.** You can talk back to anything you're hearing, and your voice stays pinned to that exact moment. A new listener never hears that happen.
3. **My pick: "A Margin is waiting."** The first thing you hear is the app's voice, chosen by ear. Then you hear a short welcome piece with a real Margin already in it, left by Cole. At that moment it asks you to answer with one of your own. Then it plays your voice back in place.
4. **That gives sound in one tap, and your first Margin in about five.** Today it's about four taps to sound, sometimes with a 15 second wait, and nobody is guided to a Margin unless they find the tour card.
5. **Cole's answers (5 October):** yes to recording his own Margin, yes to first-run choices playing right away, and the bundled audio cut to about 1 MB (it was 5 MB). Still open: a plain-language Terms summary, which is a legal question that goes with #455.

---

## 1. What happens today

This section is read from the code on `next`. Paths are under `App/SpokenMarginsApp/Sources/SpokenMarginsApp/` unless noted.

### Step by step

1. **Launch.** The app seeds two items into an empty Library, then puts a sheet over it.
   - The seeds are "Welcome to Spoken Margins", a text item, and "Guided Tour: Add and Prepare Sources" (`Gate1AppModel.swift:1838-1858`).
   - The tour's audio comes from a remote manifest on Cole's site (`GuidedOnboardingCoordinator.swift:42`). The quality-of-life notes say release was blocked on deploying it.
   - The sheet is "Follow a few favourites", the first-run podcast drawer (`CatalogDrawer.swift`, opened at `Gate1RootView.swift:74-78`).
2. **Behind the sheet, the Library.** It shows the two items and a "Start with a two-minute tour" card.
   - The card is the last row in the list, after the items and the "Offline rendering" summary, so on a phone it can sit below the fold (`ExperienceLibraryScreen.swift:84-87`).
3. **First Play.** On any first play, a full Terms of Use sheet appears and can't be swiped away. It holds about 600 words of legal text, then "Agree and Enable On-Device Voice" or "Use iOS Voice".
   - **It blocks podcasts too.** `requireTermsDecisionBeforePlayback` (`Gate1AppModel.swift:1480`) checks only whether a bundled voice is pending. It doesn't check what is being played.
   - **It never names the voice or lets you hear it.** The app has already quietly switched the voice from James to the iPhone voice (`:1404-1427`). So the listener is agreeing to a license for a voice they have never heard.
4. **First sound.** If they agree, James renders live, because offline preparation is refused until the Terms are accepted (`:5751`). The first sentence can take up to the 15 second render limit. In Low Power Mode or when the phone is warm, it quietly falls back to the iPhone voice.
5. **First Margin.** Nothing invites one, unless they found the tour card and pressed Practice.
   - The tour overlay says "Practice making an Margin" (a typo). Its button says "Make an Interjection", an old word (`PlaybackScreen.swift:1586, 1595`).
   - Pressing Add a Margin raises the microphone prompt with no lead-in. The prompt says "interjections" (`Info.plist`).
   - If the listener takes more than 10 seconds to read it and tap Allow, the app says they refused (#217).
   - Speech Recognition is then asked for in the middle of saving (`AudioAdapters.swift:3418`). If they decline, the Margin says "Transcript failed" (#268).
6. **First import of their own.** Paste & go and the Link field work well now. But every add ends with "Added X to Library without changing Now Playing", with no Play button on that message (`Gate1AppModel.swift:2670`). The listener has to go and find the new row.
   - A share from Safari's share sheet imports silently the next time the app opens. Failures go to Settings › Import Inbox.
   - The Safari extension needs turning on in Safari settings, and only prose in Help says so.
7. **First finish.** A small "Finished" label and a Share button. There's no next step, and nothing says what you made.
   - The tour's last required step is "Open Session Export", which is an odd thing to ask of someone who hasn't tried their own content yet.

### What the counts look like

| Task, from a fresh install | Today | Recommended design |
|---|---|---|
| Hear the app's voice | About 4 taps (close the drawer, open the item, Play, Agree), then up to 15 s of rendering | 1 tap, sound within a second |
| Choose a voice by ear | Not possible before agreeing. Settings › Compare voice playback renders live. | On the first screen, 1 tap per voice |
| Record your first Margin | Only guided if you find the tour card and press Practice | About 5 taps, guided by a real Margin |
| Hear your Margin in place | Not shown | Automatic, right after saving |
| Play something you pasted | 3 taps, then find the row and press Play | 2 taps (Paste & go plays it) |

Tap counts are read from the code and the mockups described below, not timed on a device.

### The pain, in one list

1. The first thing asked of you is legal, not musical.
2. The Terms block podcasts that don't need them.
3. You can't hear a voice before choosing it.
4. The first James playback renders live, so it can stall or quietly switch voices.
5. Two first-run surfaces compete: the drawer sheet and a tour card at the bottom of the list.
6. Two seeded items say nearly the same thing.
7. The core idea, talking back to what you hear, is never demonstrated.
8. Permission prompts arrive cold, in old wording, and one of them misreads a slow Allow as a refusal.
9. Adding something never offers to play it.
10. The first finish is flat.
11. None of this works offline on a first launch, because the tour audio is remote.
12. Nothing on the way is spoken aloud. A listener who'd rather hear than read gets a wall of text.

---

## 2. Three directions

### Direction A: Sound first

**The idea.** Remove every gate between install and sound, and change nothing else.

- The first screen is one big "Hear it" button. It plays a 20 second welcome that is pre-recorded in James's voice and bundled, so it's instant, offline, and can't stall.
- Under it are three voice cards, James, Lily and iPhone voice, each with its own sample. You choose by ear.
- The Terms moment moves to the voice choice, as a short plain-language summary. It never appears at Play, and never for podcasts.
- Then the existing drawer and Library, with the tour card at the top.

**Good:** small, low risk, and it fixes the worst first impression.
**Weak:** still doesn't show what makes the app different. You can hear things, but you never learn you can answer them.

### Direction B: A Margin is waiting (recommended)

**The idea.** Teach the app by having it happen to you. Direction A's foundations, then a short welcome piece where a real Margin, left by Cole in his own voice, plays at its moment and asks you to answer it. You record one, and the app plays it back in place so you hear your own voice land in the piece.

The same shape works when someone arrives through an invitation: the invite-beta plan already says "the first thing they see is a Margin on their own episode" (`docs/growth/invite-beta-plan.md`). In that case the waiting Margin is the sender's, on the recipient's own episode.

**Good:** the first five minutes are the product's core loop, done for real, through production paths (shared Margin import, "Play this moment", recording). It uses work already on `next`: Paste & go, the drawer, `MarginMomentConductor`, shared-Margin playback.
**Weak:** more parts. It needs a bundled piece and Cole's recording, and the guided moment has to be gentle enough that people who just want to listen aren't pushed.

### Direction C: Talk me in

**The idea.** Setup is a spoken conversation. James asks "What do you like to listen to?" You answer out loud: "Hard Fork, and anything about the history of science." The app finds the shows, follows them, and starts the newest episode.

**Good:** the most magical, and the most fitting for someone who listens rather than reads. Hands-free from the first second.
**Weak:** it asks for the microphone and Speech Recognition in the first ten seconds, before trust exists. It depends on podcast search by name, which isn't built (#471). Recognition mistakes in the first minute are expensive. Better as a later "Ask for a podcast" button than as the front door.

### How they compare

| | A: Sound first | B: A Margin is waiting | C: Talk me in |
|---|---|---|---|
| Shows the core idea | No | Yes, by doing it | Partly (speaking, not Margins) |
| Permissions asked up front | None | None (microphone asked at the moment you need it) | Microphone and Speech Recognition, immediately |
| Works offline on first launch | Yes | Yes | No |
| Depends on unbuilt work | No | #447's Now view helps but isn't required | #471 search, plus a new intent parser |
| Size | About 4 S/M slices | About 14 S/M slices | About 10, with more risk |

---

## 3. The recommended design: "A Margin is waiting"

### The principles

1. **Sound before reading.** Every first-run screen can be heard. The first tap makes sound.
2. **Ask at the moment of need, never before.** The microphone at your first Margin, Speech Recognition right after it, notifications only once you follow something.
3. **Do the real thing, through the real paths.** No tutorial-only screens. The welcome Margin is a real shared Margin, played by the real player.
4. **Every step can be skipped, and skipping costs nothing.** You land in a normal Library with everything still reachable.
5. **Never touch an existing Library.** First run appears only when the Library was empty at launch, which is the current rule (`libraryWasEmptyAtLaunch`).

### Screen 1: Hello

What it holds, top to bottom:

1. A short title: **"Listen to anything. Talk back to it."**
2. One large button: **"Hear it"** (the full width, at least 60 pt tall, in the bottom half).
3. Under it, a small "Skip" link.

Tapping "Hear it" plays a 20 second welcome in James's voice. It's pre-recorded and bundled, so there's no rendering and no network. The script is written for the ear:

> "Hi, I'm James. I can read you articles, newsletters and PDFs, and play your podcasts. When something you hear sparks a thought, you can say it out loud, and I'll keep it right there, at that moment. Let's pick the voice you'd like to hear."

While it plays, the words appear one sentence at a time, the current one lit. That serves people who read along, people who can't play sound right now, and VoiceOver users.

### Screen 2: Pick a voice

Three cards, one per voice. Each card has the voice's name, one line about it, and a play button with a 10 second sample of the same sentence.

| Card | Line | Notes |
|---|---|---|
| **James** | "Warm and steady. Runs on your phone." | Chosen by default. |
| **Lily** | "Bright and clear. Runs on your phone." | |
| **iPhone voice** | "Apple's built-in voice. Uses less battery." | Always available. |

Choosing James or Lily brings up the Terms, as a short card rather than a full page:

> **Before James can read to you**
> James runs on your phone, under an open license with a few rules. You agree not to use it to impersonate real people, mislead anyone, or harm anyone.
> [Agree] · [Read the full terms] · [Use the iPhone voice instead]

- The wording above is a placeholder. Whether a summary with a link to the full text is enough for the OpenRAIL-M license is a legal question. It belongs with the legal drafts in #455 and is listed under Cole's decisions below.
- If the answer is no, the full text stays, but in this place, after the listener has heard the voice, never at Play.
- Choosing the iPhone voice skips the Terms entirely.
- **Podcasts never trigger the Terms**, whatever the voice. This is a bug fix that should ship on its own first (slice 1).

### Screen 3: What first?

Three large doors, stacked in the bottom half of the screen so the thumb reaches them:

1. **"Start with ours, 2 minutes"**: the welcome piece. Marked as the suggestion.
2. **"Something I copied"**: the existing Paste & go `PasteButton`, so iOS shows no paste prompt. A link becomes a podcast or article, plain text becomes a text item.
3. **"A podcast I like"**: the existing first-run drawer, shown inside this screen rather than as a separate sheet that covers everything. Search by name joins it when #471 lands.

Under the doors, one line: "You can also share from Safari later. I'll show you how." That opens the Safari guide from G1 when it exists, and until then a short spoken explanation.

**Whichever door you pick plays straight away.** Tapping a door in the app is a clear request to listen. This doesn't conflict with the product rule that imports never replace what's playing, because nothing is playing yet.

The drawer stops appearing as a sheet on launch. It lives here, and in Following as it does now.

### Screen 4: The welcome piece

**What the piece is.** About two minutes, written for listening, in four short chapters:

1. "What this is."
2. "Talking back."
3. "Bringing your own."
4. "Sharing."

It's bundled as pre-recorded audio in James's and Lily's voices, plus the plain text for the reader view. The listener's chosen voice is the one that plays. If they chose the iPhone voice, the text is read live, which is always fast.

**The player.** It's the normal playback screen, not a tutorial overlay. Once #447's Now view lands, the guidance lives in the top half as one short line under the title. Until then it's a single card in the existing overlay slot, replacing today's five-step tour card.

**The moment.** At about 0:50, in the "Talking back" chapter, the piece reaches Cole's Margin. It's a real shared Margin on the welcome item, imported from a bundled `.spokenmargins` packet through the normal import path, so it shows in the Timeline with the shared style (a hollow diamond, plus the name "Cole").

1. Just before it, a soft tone, and the line in the top half reads: **"Cole left a Margin here."**
2. The piece pauses and Cole's Margin plays, through the same "Play this moment" path a shared Margin uses (`MarginMomentConductor`). Roughly:
   > "Hi, it's Cole. I made this app because I kept losing the thoughts I had while listening. This is a Margin: my voice, pinned to this sentence. Now you try. Hold the button at the bottom and say what you think, about anything."
3. Then the piece waits, paused. The line says: **"Your turn. Hold Add a Margin and speak."** Add a Margin gets a thicker outline (no pulsing when Reduce Motion is on). A small "Not now" carries on playing.

**Your first Margin.**

1. Holding Add a Margin for the first time shows a one-line primer before the system prompt:
   > "To record your Margin, Spoken Margins needs the microphone. Recordings stay on your phone."
   > [Continue]
2. Then the iPhone's own prompt. The 10 second timeout must not count while that prompt is on screen (#217).
3. Recording uses today's screen: Save sits where Add a Margin was.
4. **The magic moment: hear it land.** As soon as you save, the app plays the last few seconds of the piece, then your Margin, then carries on. The line reads **"That's yours now, pinned to this moment."** It uses the same "Play this moment" path on your own Margin. It's the first time the listener hears the product's promise come true, in their own voice.
5. If the listener denied the microphone, the line offers **"Write it instead"** and the piece carries on. Nothing here is a dead end.

**Speech Recognition, right after.** A small card, after your Margin has played back, not during saving:

> "Want your Margins as text too? Then you can search them and copy them into your notes."
> [Yes] · [Not now]

- [Yes] triggers the system prompt. [Not now] asks again only when the listener first tries to search or copy a Margin as text.
- If they decline, the Margin's status says Speech Recognition is off, with a Settings link (#268). Nothing says "failed".

### Screen 5: The first finish

When any first item finishes, the playback screen shows a finish card instead of a small "Finished" label:

1. **"You finished Welcome."** Then a count: "1 Margin of yours, 1 from Cole."
2. Three next steps, as large rows:
   - **"Add something of your own"**: opens the doors from Screen 3 again.
   - **"Send your Margin to a friend"**: the existing Share action, with the welcome item. It shows the loop going outward.
   - **"Set up Safari"**: a guide to turning on the extension and the share sheet.
3. If the listener followed a podcast in the drawer, one extra row: **"Tell me when new episodes are in?"** That's the only place notifications get asked for on first run.

From the second finish on, it becomes a quieter version: what you finished, your Margins on it, and "Up next" when Home (D2) or the Following inbox has something.

### Arriving through someone else's Margin

The invite-beta plan sends people a Margin on their own episode or post. In that case first run starts from the sender's Margin, not from the welcome piece:

1. **Opening the packet or link before the app has ever run.** First run opens on the recipient sheet: **"Sam left you 2 Margins on 'Episode title'."** It has one button: **"Hear the first one."**
2. **Voice pick.** It is skipped if the item is a podcast. For an article, it comes after the first Margin plays, not before.
3. **Playing.** The episode loads at the Margin's moment, with a short lead-in, then Sam's Margin plays (the J5 path, with #158 and #159).
4. **Answering.** The line then reads: **"Your turn. Add your own Margin here."** The rest is the same as Screen 4.
5. **Without the app.** If the listener installs from the link page (#486), iOS can't hand the link to the app automatically. So the first screen also offers **"Got a link from someone? Paste it."** (a `PasteButton`), and the link page tells people to tap the link again after installing.

The same goes for a share from Safari's share sheet made before the app has ever been opened: first run starts with that item, "You sent 'Title' from Safari. Play it?", instead of the doors.

### Edge cases

| Situation | What happens |
|---|---|
| No network on first launch | Everything on Screens 1-4 is bundled. The drawer uses its bundled catalog. The "Something I copied" door explains that links need a connection, and text still works. |
| Low Power Mode or a warm phone | The welcome and samples are pre-recorded, so they sound the same. For the listener's own articles, the existing fallback rules apply, but the voice line says so in words (C2, #183). |
| Listener skips everything | They land in the Library with one item, "Welcome", and one card at the **top**: "Start with a two-minute welcome". The card goes away after the welcome is finished or dismissed. |
| Listener taps "Not now" at the waiting Margin | The piece plays on. The card at the finish still offers the first Margin once: "Try a Margin on this piece?" Then never again. |
| Upgrading from Build 29, or any Library with content | No first run. Nothing is seeded. The Terms change applies (podcasts never blocked). |
| Reinstall | First run again. That's fine: the Library starts empty after a delete. |
| VoiceOver on | Every screen is in reading order: title, then the main button. "Hear it" is labelled "Hear the welcome, 20 seconds". The waiting Margin announces "Cole left a Margin here. Your turn: Add a Margin." The listener can also double-tap the Margin row. |
| Largest text sizes | Doors and cards stack to one column and grow. Nothing is cut. The welcome text scrolls with the sentence being read. |
| Microphone denied | "Write it instead" everywhere a recording is offered, plus "Open Settings" once. |
| Speech Recognition denied | Margins keep their audio. The status says "Speech Recognition is off", with a Settings link. |
| Explicit podcasts | Hidden in the drawer, as #544 does now. |
| The listener deletes Welcome | It stays deleted, as the tour does today (tombstoned). |
| iPad | Same screens, centred at phone width, with doors in the lower half. |

### Accessibility, for how Cole uses the app

- **Heard, not only read.** Every first-run screen has spoken content or can be read aloud with one tap. Text on these screens is short sentences, no more than about 12 words each, no jargon ("render", "chunk", "interjection" never appear).
- **Not by colour alone.** Shared and own Margins differ by shape (a hollow diamond against a solid one) and by name. Required and optional choices differ by position and wording, never only colour. Warnings use an icon plus words.
- **One-handed.** Every main action is in the bottom half and at least 44 pt, matching D5's rule.
- **Calm.** One thing asked per screen. No timers that rush a decision. Reduce Motion replaces any pulse with a thicker outline.
- **VoiceOver and Dynamic Type** as in the table above.

---

## 4. What it needs, technically

### New pieces

1. **`FirstRunCoordinator`, in SessionKit.** A pure state machine, host-tested on Linux and macOS.
   - Stages: `hello`, `voice`, `doors`, `welcomePlaying`, `marginWaiting`, `marginSaved`, `finished`, `done`.
   - Entry context: a cold start, a packet opened, or a pending share handoff.
   - It decides which screen to show and what the guidance line says. It records progress by evidence (a saved Margin, a finished item), like today's onboarding rules in the Recovery MVP doc.
   - It reads today's `onboardingCompletedStepsV1` so someone mid-tour isn't sent back to the start.
   - The views are thin. `Gate1AppModel` gets call sites only, no new state (AGENTS.md rule).
2. **Bundled audio** in the app, about 1 MB in all (Cole asked for less than the first 5 MB estimate):
   - the 20 second hello in James and Lily;
   - a 10 second sample for James and for Lily (the iPhone voice sample is spoken live, which is instant);
   - the two-minute welcome in James and Lily;
   - Cole's Margin, about 20 seconds, inside a bundled `.spokenmargins` packet.

   That's about 320 seconds of speech. Stored as mono HE-AAC at 24 kbps, a speech-quality setting iOS plays natively, it comes to about 3 KB a second, so roughly 1 MB. The first estimate assumed music-quality AAC at 64 kbps and a three-minute welcome.
   - **If 1 MB is still too much:** bundle the welcome in James only (about 0.6 MB). Listeners who pick Lily then hear the welcome read live, which can stall in Low Power Mode.
   - **Check by ear first:** slice 7 includes a listen at 24 and 32 kbps on the Mac. If 24 sounds thin, 32 kbps costs about 0.3 MB more.

   These are made once on the Mac with the bundled voice and checked in. Cole records his Margin on the phone and sends the packet, which is the J5 path he already knows.
3. **The welcome item** as a native-audio item with chapters and its text, built from the bundled file for the chosen voice. That makes it instant, scrubbable, and the same on every phone. It replaces both of today's seeds ("Welcome to Spoken Margins" and "Guided Tour") and the remote tour manifest, so first run no longer depends on Cole's site being up.
4. **Two small views:** `FirstRunHelloView` and `FirstRunDoorsView`. The doors reuse `PasteAndGoBar` and `CatalogDrawerView` as they are.
5. **A finish card view** for the finished state in `PlaybackScreen`.

### Changes to existing code

1. **The Terms gate applies only to text read by James or Lily.** `requireTermsDecisionBeforePlayback` should also check that the item will be spoken by a bundled voice. That is a host-testable rule, and it's a bug today.
2. **The Terms are asked at the voice choice,** and the `.system` switch at launch stays (James never speaks before acceptance).
3. **The import confirmation gets a "Play now" action** when nothing is playing (`UserFeedbackBanner`). First-run doors start playback directly.
4. **The microphone request** ignores its timeout while the system prompt is up (#217), and gets the primer line.
5. **Speech Recognition is asked explicitly** after the first Margin plays back, not lazily inside transcription.
6. **The usage strings in `Info.plist`** say "Margins", not "interjections":
   - Microphone: "Spoken Margins records your spoken Margins while you listen. Recordings stay on your phone."
   - Speech Recognition: "Spoken Margins turns your spoken Margins into text so you can search and copy them."
7. **The catalog drawer** stops opening as a sheet at launch. Today's `presentIfFirstRun` is replaced by the doors screen.
8. **Help copy** is updated. It still says the Link field is only for podcasts, and still mentions a Home screen that doesn't exist (`HelpScreen.swift:92, 95`).
9. **The tour overlay's text** is fixed for anyone on the old path until it's removed ("an Margin", "Make an Interjection").

### What it must not break

- **Packets.** The bundled welcome packet is a normal packet that Build 29 can import. No new manifest capability.
- **The database.** No schema change. First-run state lives in `UserDefaults`, like today's onboarding keys.
- **Owner data.** First run only runs on a Library that was empty at launch. It never seeds or changes an existing Library.
- **The Terms requirement.** James and Lily never synthesise anything before acceptance. Pre-recorded samples aren't the listener running the model, but that point goes to the legal check too.
- **Journeys J1 to J7.**
- **Share handoffs never autoplay.** Only a tap inside the app starts playback. A handoff gets "Play now" on its message.

### How it gets tested

- **Host:** the coordinator's stages for each entry context, skip paths, resuming from old onboarding keys, and the Terms rule (a podcast is never gated; an article with James is).
- **App-hosted (T3):** a fresh install reaches sound in one tap. A podcast plays with Terms not accepted. A share handoff from before first launch opens as the first item.
- **A new journey, J0 "First run",** in `docs/journeys.md`: fresh install, hear the hello, pick a voice, play the welcome, answer Cole's Margin, hear it land, finish, and add your own article. Each step has a tap count. Today no journey covers a fresh install.
- **Owner check on the phone:** delete the app, install, and go through J0 by ear, once with Low Power Mode on.

---

## 5. Slices to build it

Each slice is one PR. They're listed in build order, sized S or M, with where each can be done. None is filed yet.

| # | Slice | Size | Where | Depends on |
|---|---|---|---|---|
| 1 | Terms gate only for text read by a bundled voice, so podcasts never meet it. Host test that fails today. | S | Cloud | Nothing |
| 2 | Wording: `Info.plist` usage strings, tour typos, Help copy (Link field, Home). | S | Cloud | Nothing |
| 3 | Microphone primer line, and the #217 timeout fix. | S | Cloud (T3 on the lane) | Nothing |
| 4 | Ask for Speech Recognition after the first Margin plays back, with the #268 wording. | S | Cloud (T3) | 3 |
| 5 | "Play now" on the import message when nothing is playing. | S | Cloud (T2) | Nothing |
| 6 | `FirstRunCoordinator` in SessionKit, with host tests for every stage and entry context. | M | Cloud | Nothing |
| 7 | Record the hello and the voice samples in James and Lily, compare 24 and 32 kbps HE-AAC by ear, and bundle them. | S | Mac | Nothing |
| 8 | Hello and voice-pick screens, using 6 and 7, with the Terms moved to the voice pick. | M | Mac | 1, 6, 7, and Cole's Terms decision |
| 9 | The doors screen: welcome, Paste & go, the drawer. The drawer stops opening on launch. | M | Mac | 6, 8 |
| 10 | Write and record the welcome piece. Cole records his Margin and sends the packet. Bundle both. | M | Mac, plus Cole (20 seconds) | 7 |
| 11 | The welcome item replaces both seeds and the remote tour manifest. | S | Cloud (T3) | 10 |
| 12 | The waiting Margin: guidance line, pause, "Your turn", and "Hear it land" after saving. | M | Mac | 6, 10, 11; better after #447 |
| 13 | The finish card, with next steps and the follower-only notifications ask. | M | Mac | 6 |
| 14 | Arriving through a packet or a pending share: first run starts from it. | M | Mac | 6, 9 |
| 15 | Journey J0 in `docs/journeys.md`, and a scripted version for the Test Desk. | S | Cloud (doc), Mac (script) | 9, 12 |

Slices 1 to 5 are worth doing now whatever Cole decides about the rest. They fix the worst moments in today's first run without new design.

---

## 6. Decisions for Cole

1. **Open: a plain-language Terms summary at the voice pick, with a link to the full text?** This is a legal question, and belongs with the drafts in #455. My pick: yes, if the attorney agrees. If not, the full text stays, but moves to the voice pick. It blocks slice 8.
2. **Answered yes (Cole, 5 October):** Cole records a 20 second Margin in his own voice for the welcome piece. It's needed for slice 10.
3. **Answered (Cole, 5 October): "that's kinda a lot, can we lower it?"** Cut from about 5 MB to about 1 MB: a two-minute welcome and speech-quality compression, both voices kept. The smaller fallback is about 0.6 MB, with the welcome in James only. Details in section 4.
4. **Answered yes (Cole, 5 October):** choices on the first-run screen start playing right away, only when nothing else is playing.

## Related

#69, #145, #158, #159, #187, #217, #246, #268, #429, #447, #455, #463, #471, #486, #544, #632, #708. Streams B1 (onboard), C2 (voice), D2 (home), D5 (player), G1 (guides), G2 (growth).
