# First run: a Margin is waiting

**Flow:** from installing Spoken Margins to hearing your own first Margin played back.
**First written:** 4 October 2026, against `next` at `1744dff`.
**Refreshed:** 19 November 2026, against `main` at `e3366c1ad`, for #4676, to the onboarding direction of 2026-11-18 (#4679).
**Status:** design only. Section 1 is read from code; nothing here was built, run in a simulator or tried on a phone for this refresh. Claims marked *(not checked)* were not traced to code.

The 4 October version, with its three directions, voice-pick screens and doors screen, is in git history (`d1723d1a0`). This version keeps what still applies and says what happened to each of its 15 slices (section 5).

## The short version

1. **Most of the 4 October quick fixes have shipped.** Podcasts no longer meet the Terms, the Terms are one plain screen, the microphone is explained before iOS asks, a slow Allow no longer reads as a refusal, the import message has Play now, and a friend's file on first launch comes before everything else.
2. **The core idea is still never shown on a cold install.** A new listener meets a podcast drawer, then hears a text Welcome read aloud or a show they picked. Nobody's voice is pinned to a moment, so the app's one trick is something they're told about, not something that happens to them.
3. **The 2026-11-18 direction changes the frame.** Every first run is an arrival. A share link is an arrival from a friend; a cold download is an arrival from Cole. So a cold install should run the same arrival path a friend's file already runs, with Cole's Margin waiting on a short welcome piece.
4. **What's dropped:** the hello screen, the voice-pick screens and the doors screen. The voice choice moved to Settings (#2853), new listeners start on Phonon (#2858), and the drawer stops being the front door. No question is asked before the first Margin.
5. **What's added:** one defined event, **"first Margin heard"**, that #4672 ("Where should this go?") waits for. Section 3 defines it.
6. **Five slices remain** (section 5). One needs Cole's recording: one spoken Margin, about 20 seconds, which he agreed to on 5 October.

---

## 1. What happens today on `main`

Paths are under `App/SpokenMarginsApp/Sources/SpokenMarginsApp/` unless they start with `Packages/`. Read from code at `e3366c1ad`; not run.

### Step by step

1. **Launch on an empty Library.** The app seeds two items, then opens a sheet.
   - The Welcome sample, a text item ("Welcome to Spoken Margins"), is seeded when the Library is empty (`Gate1AppModel+LibrarySeeding.swift:55-69`). Its Markdown now lives in SessionKit (`Packages/SessionKit/Sources/SessionKit/WelcomeSample.swift:11-38`). It is text, so the app's voice reads it.
   - The "Guided Tour: Add and Prepare Sources" item is still seeded, from a bundled fallback (`Gate1AppModel+LibrarySeeding.swift:70-79`, `Gate1AppModel+GuidedOnboardingContent.swift:7-10`). Its richer audio still comes from a remote manifest on the product server (`Packages/SessionKit/Sources/SessionKit/GuidedOnboardingCoordinator.swift:42`), set up at `Gate1AppModel.swift:2904`.
   - The sheet is still the first-run drawer, "Follow a few favourites" (`CatalogDrawer.swift:419`, presented at `Gate1RootView.swift:78-83`). It now has search by name (#471, `CatalogDrawer.swift:26-33`) and OPML import (#463, `CatalogDrawer.swift:63-64, 210`).
   - The drawer no longer opens as the root view appears. It waits for the launch to settle, so a file the system hands over arrives first (`Packages/SessionKit/Sources/SessionKit/FirstLaunchWelcomeOrder.swift:7-12, 88-92`; wired at `Gate1RootView.swift:64` and `CatalogDrawer.swift:763`).
2. **A friend's file or link on first launch comes first** (#3291). An untouched drawer is withdrawn and the friend's item opens; the drawer comes back on the next visit to the Library, and Done with nothing picked then plays nothing over the friend's episode (`FirstLaunchWelcomeOrder.swift:94-110, 56-58`). A failed link brings the drawer back (`:112-123`, #3801).
3. **Drawer Done plays something** (#2851). The first pick's newest episode or latest post plays; with no pick, the Welcome sample plays (`Gate1AppModel+FirstListen.swift:12-31`, rule in `Packages/SessionKit/Sources/SessionKit/FirstRunListenChoice.swift:10-23`).
4. **The Terms.**
   - They appear only for text read by an on-device voice. A podcast or imported audio never meets them (#781): `PlaybackTermsGate.mayRequireTerms` and `requiresTerms` (`Packages/SessionKit/Sources/SessionKit/PlaybackTermsGate.swift:28-48`), called from `Gate1AppModel+TermsGate.swift:7-33`.
   - A first Play gets a one-screen summary with both buttons; other ways in get the complete text (#2853, `PlaybackTermsGate.swift:10-23`, `SpokenMarginsTermsView.swift:13-17`). The buttons still say "Agree and Enable On-Device Voice" and "Use iOS Voice" (`SpokenMarginsTermsView.swift:133, 146`).
   - So on a cold install today, picking a show reaches sound with no Terms. Done with no pick plays the text Welcome, which does meet them.
5. **The voice.** A fresh install starts on Phonon, and the backup voice reads until Phonon downloads, which waits for the Terms and Wi-Fi (#2858, `Packages/SessionKit/Sources/SessionKit/FirstRunVoiceDefault.swift:18-52`, `Gate1AppModel+FirstRunVoice.swift:11-55`). There is no voice pick on first run; it lives in Settings.
6. **The first Margin.**
   - Once audio plays, one card says "Tap to add a Margin" (#2852, `FirstMarginPromptCard.swift:17-18`, shown at `PlaybackScreen.swift:100`). It shows once (`Packages/SessionKit/Sources/SessionKit/OnboardingProgress.swift:109-117`, `Gate1AppModel+Onboarding.swift:46-55`).
   - Tapping it explains the microphone first: "To record your Margin, Spoken Margins needs the microphone…" (`Packages/SessionKit/Sources/SessionKit/MicrophonePrimer.swift:8`). The slow-Allow bug is fixed (#217, closed 12 October).
   - While a friend's Margins play, the card hides, and the friend's end card asks instead: "That was Cole's last Margin. To answer Cole, add a Margin of your own." (`Packages/SessionKit/Sources/SessionKit/PinnedMarginCard.swift:207-209, 251-252`; `Gate1AppModel+Onboarding.swift:76-84`, #3790).
   - Speech Recognition is still asked lazily, inside the first transcription, right after saving (`Packages/SessionKit/Sources/SessionKitAudio/AudioAdapters.swift:4321-4324`). Declining no longer says "Transcript failed" (#268).
   - **After saving, nothing plays the listener's Margin back.** I found no code that replays a newly saved Margin (searched for any post-save call into `playMarginMoment`, `Gate1AppModel.swift:1104`). The listener has to open the Timeline and tap it.
7. **The tour, still there.** The Library still shows "Start with a two-minute tour" (`ExperienceLibraryScreen.swift:97, 191`). The tour overlay's words are fixed ("Practice making a Margin", "Add a Margin", `PlaybackScreen.swift:1673, 1683`), but its last step is still "Open Session Export" (`PlaybackScreen.swift:1708-1714`).
8. **Adding your own.** The add confirmation offers Play now when nothing is playing (#784, `Gate1AppModel+AddedToLibrary.swift:19-23`). Help now says the Link field takes episodes, feeds, articles and PDFs (`HelpScreen.swift:87`).
9. **J11 covers this** (#2854): fresh install, drawer, Done, first Margin, with taps and seconds, and a script for steps 2 and 3 (`docs/journeys.md:159-176`).

### What changed since 4 October, against its pain list

| 4 October pain | On `main` |
|---|---|
| The first thing asked is legal | Only for text read by an on-device voice, as one short screen |
| Terms block podcasts | Fixed (#781) |
| Can't hear a voice before choosing | Moot: no voice choice on first run; Phonon is the default (#2853, #2858) |
| First James playback renders live | Still true for text; the backup voice reads until Phonon arrives *(stall behaviour not checked)* |
| Drawer and tour card compete | Still two surfaces, but sequenced: the tour coach waits for the first-Margin card |
| Two seeds say the same thing | Still true |
| The core idea is never shown | **Still true**, except for a friend's arrival |
| Permission prompts arrive cold | Fixed for the microphone; Speech Recognition still asked mid-save |
| Adding never offers to play | Fixed |
| The first finish is flat | Still true *(the finish label was not re-read)* |
| Nothing works offline on first launch | Partly: the tour has a bundled fallback; the drawer needs the network to pick a show |
| Nothing is spoken | The Welcome is read aloud; the screens are not |

---

## 2. The direction (2026-11-18), and what it changes here

From #4679, Cole and Claude:

1. **Every first run is an arrival.** A share link is an arrival from a friend; a cold download is an arrival from Cole. Personas are handled by which Margin is waiting, not by branches in the app.
2. **One question, after the first Margin:** "Where should this go?" (#4672). Nothing is asked before the first Margin.
3. **Demoted:** the drawer as the front door, the tour, and any persona survey up front.

What that means for this design:

- **A cold install runs the friend's arrival path, with Cole as the friend.** The arrival code built for #3247 and #3291 (friend's item first, the pinned card, "To answer Cole, add a Margin of your own") is the same moment the 4 October design drew as "Cole left a Margin here". Reusing it means one arrival to keep right, not two.
- **The drawer moves to after the first Margin.** It stays in Following, and #4672's "Bring my shows" offers it at the right time. A cold launch stops opening it.
- **No hello screen, no voice pick, no doors.** The first thing a new listener does is hear Cole.
- **The finish card is replaced** by #4672's question after the first Margin, and by "Follow this show" at the end of an episode for link arrivals (#4672 rule 5).

---

## 3. The design for a cold install

### The flow

Starting state (#4102 rows): `first-run`, nothing playing, entry point is the app icon. No friend's file.

1. **Launch.** The Library holds one item, "Welcome" (the welcome piece). Its Now screen opens and the piece starts, because opening the app for the first time is a request to hear something and nothing else is playing. *(Whether autoplay at launch is acceptable is Cole's call; the alternative is one big Play on the item screen, one extra tap.)*
2. **The piece plays.** About two minutes of recorded audio, so there are no Terms (`PlaybackTermsGate.playsRecordedAudio`: a native audio file never meets them), no rendering and no network.
3. **Cole's Margin plays at its moment.** It is a friend's Margin on the welcome item, so the pinned card shows it as a friend listen: "Cole's Margin is here", then his voice.
4. **Your turn.** After Cole's only Margin, the end card reads "That was Cole's last Margin. To answer Cole, add a Margin of your own." (today's wording). The piece pauses there and waits, with "Not now" to carry on. Add a Margin goes through the microphone primer, then iOS.
5. **Hear it land.** As soon as the Margin is saved, the app plays it back in place: a few seconds of the piece before it, then the listener's own voice, then the piece carries on. The card line reads "That's yours now, pinned to this moment."
6. **Speech Recognition** is asked after that playback, not during saving: "Want your Margins as text too? Then you can search them and copy them into your notes." [Yes] [Not now].
7. **"Where should this go?"** (#4672) appears now, because the first Margin has been heard.

A written Margin works the same way: if the microphone is denied, the card offers "Write it instead", and step 5 shows the written Margin at its place instead of playing it.

### What changes on the friend-arrival card for Cole's welcome

The friend's card after an answer says "To send it to Cole, tap Share below" (`PinnedMarginCard.swift:250`). On the welcome item that's wrong: sending every new listener's first Margin to Cole isn't the point. On the welcome item the line after an answer is the hear-it-land line, and Share is not offered there. *(Design choice, not a code fact.)*

### The event "first Margin heard"

#4672 needs one trigger. Defined here so both the cold install and a link arrival use it:

1. **What fires it.** On this install, the first time a Margin the listener made themselves plays to its end through the Margin-moment player (`MarginMomentConductor`, the path "Play this moment" uses). Either the automatic hear-it-land playback (step 5) or the listener's own tap counts.
2. **A written Margin** fires it when saved and shown at its place, since there is nothing to hear.
3. **What doesn't fire it.** A friend's or Cole's Margin playing; a Margin saved but not yet played back; a playback stopped before its end. A stopped playback leaves the event for the next full one.
4. **Fires once, and is stored.** It is a new `OnboardingStep` raw value, `heard_first_margin`, stored with the other steps in UserDefaults. Older builds drop unknown step names (`OnboardingProgress.swift:15-16` relies on this for `saw_first_margin_prompt`), so no packet or database change.
5. **It carries its entry point:** `coldInstall` (Cole's welcome) or `friendArrival` (a friend's file or link on first launch). #4672 shows the full question for `coldInstall` and the gentler end-of-episode version for `friendArrival` (its rule 5).
6. **An existing Library never fires it.** On the first launch of the build that ships the step, a Library that wasn't empty at launch gets `heard_first_margin` marked as already done, so an upgrade is never asked (#4672 rule 3). A fresh install starts without it. This is a one-time migration, not evidence read at each launch, so a new listener who saved a Margin and quit before hearing it still gets the event later.

### Arriving through a friend

Unchanged in shape, and mostly built (#3291, #3247). The only additions here: the friend's arrival fires the same "first Margin heard" event with `friendArrival`, and hear it land applies to a reply too.

### Edge cases

| Starting state or situation | What happens |
|---|---|
| `first-run` with a friend's file | The friend's arrival, as today; Cole's welcome is still in the Library but doesn't autoplay *(rule to set in slice C)* |
| `returning` (any Library with content, an upgrade) | No welcome, no autoplay, no event; `heard_first_margin` marked done once |
| `other-item-playing` | Can't happen on a cold launch; the welcome never takes over something playing |
| Listener taps "Not now" at Cole's Margin | The piece plays on; the first-Margin card stays due for their next listen, as today |
| No network | Everything on the welcome path is bundled |
| Microphone denied | "Write it instead"; the event fires on the written Margin |
| Speech Recognition denied | The Margin keeps its audio; today's #268 wording applies |
| Listener deletes Welcome | Stays deleted (tombstoned, as the tour is today) |
| VoiceOver | The card announces "Cole's Margin is here", then "To answer Cole, add a Margin of your own" *(not checked on device)* |

---

## 4. What it needs, technically

1. **The welcome piece**, bundled as recorded audio: about two minutes, written for the ear, in four short chapters (what this is, talking back, bringing your own, sharing), rendered on the Mac in one bundled voice and stored as mono HE-AAC at about 24 kbps, roughly 0.4 MB. Its text goes with it for the reader view.
   - Which voice: the one a new listener starts on (Phonon), if its license allows shipping a render; otherwise James. Shipping pre-rendered audio from a bundled voice goes to the same legal check the 4 October version named *(not checked)*.
2. **Cole's Margin** in a bundled `.spokenmargins` packet on the welcome item, imported through the normal packet path, so it is a real friend's Margin. *(Not checked: whether a packet can anchor to an item seeded from a bundled audio file, or whether the item has to come from the packet. Slice C decides.)*
3. **SessionKit** (host-tested): an entry point for "arrival from Cole" in `FirstLaunchWelcomeOrder`, the "first Margin heard" rule, and the one-time migration. `Gate1AppModel` gets call sites only.
4. **The welcome item replaces both seeds and the remote tour manifest.** The text Welcome and the tour item stop being seeded on fresh installs; existing Libraries keep theirs. The Library tour card and the tour overlay go for new installs.
5. **The drawer stops opening on a cold launch.** It stays in Following and moves to #4672's "Bring my shows".

### What it must not break

- **Packets.** The bundled packet is a normal packet that the last shipped build can import. No new manifest capability.
- **The database.** No schema change. First-run state lives in UserDefaults.
- **Owner data.** Nothing is seeded into, or removed from, a Library that had content at launch.
- **The Terms.** An on-device voice still never synthesises text before acceptance. The welcome path is recorded audio.
- **Journeys.** J11 changes (slice C updates it); J12 and the friend's arrival must not change.

---

## 5. Slices

### The 4 October slices, today

| # | 4 October slice | Now | Reason and evidence |
|---|---|---|---|
| 1 | Terms gate only for text read by a bundled voice | **Done** | #781; `PlaybackTermsGate.swift:28-48`, `Gate1AppModel+TermsGate.swift:24` |
| 2 | Wording: usage strings, tour typos, Help copy | **Done** | `Info.plist:90-93` match the design's strings; `PlaybackScreen.swift:1673, 1683`; `HelpScreen.swift:87` |
| 3 | Microphone primer and the #217 timeout | **Done** | #2852, #217; `MicrophonePrimer.swift:8` |
| 4 | Speech Recognition after the first Margin plays back | **Still needed**, smaller | #268's wording shipped, but the ask is still inside transcription (`AudioAdapters.swift:4323`). Filed as slice E. |
| 5 | "Play now" on the import message | **Done** | #784; `Gate1AppModel+AddedToLibrary.swift:19-23` |
| 6 | `FirstRunCoordinator` in SessionKit | **Still needed**, re-scoped | `FirstLaunchWelcomeOrder`, `OnboardingProgress` and `FirstRunListenChoice` cover ordering and the drawer. Missing: the arrival from Cole and the "first Margin heard" event. Filed as slice A. |
| 7 | Record the hello and voice samples | **Dropped** | No hello screen and no voice pick: the voice choice moved to Settings (#2853) and Phonon is the default (#2858). |
| 8 | Hello and voice-pick screens | **Dropped** | Same as 7; the Terms are now one screen at first Play of text (#2853). |
| 9 | The doors screen | **Dropped** | The drawer is no longer the front door (#4679). Paste & go and the drawer move to after the first Margin (#4672). |
| 10 | Write and record the welcome piece; Cole's Margin | **Still needed** | No welcome audio or packet exists (`WelcomeSample.swift` is text). Filed as slice B. |
| 11 | Welcome item replaces both seeds and the remote manifest | **Still needed**, merged | Both seeds and the manifest are still there (`Gate1AppModel+LibrarySeeding.swift:59-79`, `GuidedOnboardingCoordinator.swift:42`). Merged into slice C. |
| 12 | The waiting Margin, "Your turn", "Hear it land" | **Split** | "Your turn" exists as the friend end card (`PinnedMarginCard.swift:207-209, 251-252`); slice C points the welcome at it. "Hear it land" has no code: filed as slice D. |
| 13 | The finish card | **Dropped** | Replaced by #4672's question after the first Margin, and "Follow this show" for link arrivals (#4672 rule 5). |
| 14 | Arriving through a packet or pending share | **Done** for files and links | #3291; `FirstLaunchWelcomeOrder.swift:94-123`. A Safari share made before the first launch was not re-read *(not checked; not filed)*. |
| 15 | Journey J0 | **Dropped** | J11 covers a fresh install (#2854, `docs/journeys.md:159`). Slice C updates J11 instead. |

### The slices to build now

| | Slice | Issue | Size | Where | Depends on |
|---|---|---|---|---|---|
| A | SessionKit: the arrival from Cole and the "first Margin heard" event, with the one-time migration. Host tests. | #4711 | M | Cloud | Nothing |
| B | The welcome piece and Cole's welcome Margin, bundled | #4712 | M | Mac, plus Cole (20 seconds) | Nothing |
| C | A cold install is an arrival from Cole: welcome item replaces both seeds and the manifest, the drawer stops opening on launch, the tour card goes for new installs, J11 updated | #4714 | M | Cloud, captures on the lane | A, B, D |
| D | Hear it land: play a newly saved first Margin back in place, and fire the event | #4713 | M | Cloud, captures on the lane | A |
| E | Ask for Speech Recognition after the first Margin plays back | #4715 | S | Cloud | D |

#4672 ("Where should this go?") waits on A (#4711) for its trigger and on D (#4713) for the event to fire in practice.

**Cole's recording (slice B).** One spoken Margin, about 20 seconds (15 to 25 is fine), recorded on his phone on the welcome item at the "talking back" moment, then sent as a packet the usual way (J5). What it says: who he is, why he made the app, that this is a Margin pinned to this moment, and a question to the listener, ending with "your turn". He agreed on 5 October; this is the same recording.

---

## 6. Decisions

1. **Answered yes (Cole, 5 October):** Cole records a Margin of about 20 seconds for the welcome piece.
2. **Answered (Cole, 5 October):** bundled audio about 1 MB or less. The two-minute piece in one voice is about 0.4 MB.
3. **Answered yes (Cole, 5 October):** first-run choices start playing right away when nothing else is playing. This design reads that as allowing the welcome to start on first launch; slice C confirms it in its Design comment.
4. **Settled by #2853:** the Terms are one plain screen at the first Play of text, and the voice choice lives in Settings. The 4 October open question about a plain-language summary is answered by that.
5. **Default taken here:** the welcome piece is rendered in the voice new listeners start on, unless the license check says otherwise.

## Related

#4679 (direction), #4672 (after the first Margin), #4344, #3247, #3291, #2851, #2852, #2853, #2854, #2858, #781, #784, #217, #268, #463, #471, #1538 (source stays paused after playing your own Margin), #3782 (after installing from a link, no way back to it), #4102, #187.
