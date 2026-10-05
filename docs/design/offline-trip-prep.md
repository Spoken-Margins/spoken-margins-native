# Packing for the road: offline trip prep, reimagined

Spoken Margins · design doc · 4 October 2026 · designed against `next` at `1744dff`

Mockups only. Nothing here is built, filed or tried on a device. Code facts are cited by file and line on `next`. Time and size estimates are marked as estimates; the real render speed on your phone has never been measured (#64 still asks for it).

## The short version

1. **You pack for a trip the way you'd pack a bag.** Tell the app how long you'll be listening ("6 hours, leaving tomorrow at 8"). It fills a **Pack** to that length from what you're in the middle of, what's waiting in your Library, and new Following items you say yes to. You reorder or drop things.
2. **Ready is measured in hours, not gigabytes.** One meter says "4 h 10 min of 6 h ready". Every item says in words what it still needs ("download, 84 MB", "voice, about 20 minutes plugged in"). The app gets it ready overnight or while you keep the phone plugged in, and tells you when it's done or stuck.
3. **On the road it just keeps playing.** The Pack plays in order. When one item ends, the next one starts, with a short spoken line ("Next: The Shape of Attention, 18 minutes"). Anything that isn't ready is skipped out loud, never left in silence. When the Pack runs out, the app says so and offers to keep going with whatever else plays offline.
4. **Coming home closes the loop.** "Trip recap: 7 Margins you made on the road", and "Free 2.1 GB from this trip?"
5. **The commute is a Pack that refills itself.** "Keep 1 hour ready" tops itself up each night on the charger.

The key technical move: a Pack is an **`ItemCollection` (already in SessionKit, #489) plus one new sidecar record**. New record kinds are invisible to Build 29, so the database stays compatible. "What plays next" is a pure SessionKit decision that the playback coordinator asks at the end of an item; the Pack holds no playback state, so it doesn't add the state machine AGENTS.md forbids.

## 1. Where this flow stands today

### What exists (on `next`)

| Step | What happens today | Where |
|---|---|---|
| Podcast downloads | Every added episode downloads automatically on Wi-Fi. On cellular it only streams unless you tap Download Now. No network means "Waiting for Wi-Fi". Background URLSession, so downloads survive the app closing. Files are excluded from iCloud backup. | `PodcastDownloads.swift:152` (`PodcastDownloadPolicy`), `PodcastDownloadCoordinator.swift:49-116, 370-386, 446-448` |
| Article and PDF voice | Each new text item renders a 2-chunk "opening buffer" (about 30 s). A full render happens only if you tap **Prepare Offline**, or if Settings > Automatic Audio Preparation is **While Charging**. The default is **Off**. | `Gate1AppModel.swift:914-916, 1079, 5723, 15040` |
| Where rendering happens | Supertonic (on-device neural voice, ONNX, CPU) renders 240-character chunks. A background job runs only on external power. | `AudioPreparationBackgroundController.swift`, `PreparedAudioModels.swift` |
| Heat and Low Power Mode | Any preparation pass, even an explicit Prepare, refuses to start in Low Power Mode or when the phone is hot. Heat is checked only when a pass starts. PR #765 (open, armed) checks before every chunk, saves "paused for heat", and lets an explicit Prepare continue in Low Power Mode. | `Gate1AppModel.swift:15196-15202`, PR #765, #64 |
| Structured PDFs | The new PDF reader's papers can't be prepared at all yet: "This PDF plays with live speech; preparing its audio ahead isn't available yet." | `Gate1AppModel.swift:15044-15047`, #336 |
| Seeing what's ready | Library filter "Offline" (All · Preparing · Ready offline · Needs update · Online only). Row labels "Ready offline", "Preparing". An "Offline Rendering" queue screen with Prioritize, Move earlier/later, Render Now. | `ExperienceLibraryScreen.swift:288, 456, 510`, `ExperienceAudioPreparationQueueScreen.swift` |
| Storage | One budget (1, 2, 5, 10 or 20 GB, default 5) over podcasts, prepared voice, recordings and more. Auto-eviction only touches reproducible, unprotected files, and never recordings, Margins or imported audiobooks. Settings > Offline Storage shows Protected · Reproducible · Reserved and a "Clear reproducible audio" button. | `OfflineStorageModels.swift`, `OfflineStorageLedger.swift`, `ExperienceStorageScreen.swift` |
| What plays next | Nothing. There is no Up Next, no playlist and no auto-advance. When an item ends, playback stops. | No end-of-item handler found; `Gate1PlaybackAutoplayQueue` queues AI turns only |
| Losing signal | Only the podcast downloader watches the network. There's no app-wide "you're offline" state. A streamed episode that can't start says "Podcast playback did not start. Use Download Again in More…", which is wrong when you simply have no signal. | `PodcastDownloadCoordinator.swift:60`, `Gate1AppModel.swift:6246` |
| In the car | Lock Screen, Live Activity and Now Playing controls work, so CarPlay's Now Playing screen and steering-wheel buttons should control playback (inferred from the Now Playing code, not tried in a car). There's no CarPlay browsing screen. | `Gate2LiveActivityWidget.swift`; no CarPlay code |
| Siri and Shortcuts | Add Article and Listening Edition intents only. No "play" or "get ready" intent, no `AppShortcutsProvider`. | `AddArticleShortcutIntent.swift` |

### What gets in the way

1. **Nothing plays after the current item.** On a six-hour drive this is the biggest problem. Every item ends in silence, and starting the next one means picking up the phone while driving.
2. **Getting a text item ready is a hidden, per-item chore.** Articles and PDFs need **Prepare Offline**, one at a time, from a row's button. The automatic setting is off by default, and its name ("Automatic Audio Preparation: While Charging") doesn't say "this is how you get ready for a trip".
3. **You can't tell how much listening you have.** The app shows per-item badges and gigabytes. Nothing answers "do I have enough for the drive?", which is the question you actually have.
4. **The car is the worst place to render a voice.** A phone on a dashboard mount, in the sun, running maps and charging, is exactly when it gets hot. Today an unprepared article rendered live in the car is likely to hit the heat limit and drop to the iOS voice. Preparing *before* you leave is the fix, but nothing nudges you to.
5. **"Ready" can quietly become "not ready".** Eviction can delete a reproducible download or prepared voice when the budget is tight. There's no way to say "keep these for the trip". (Reproducible means it can be re-made, which isn't true on a highway with no signal.)
6. **Running out is silent and confusing.** A streamed episode that loses signal stalls and then blames the saved audio. A partly prepared article falls back to live rendering. Nothing says what's happening or offers what *would* play.
7. **Streamed episodes behave worse.** Resuming after a Margin takes 2.6-9.3 s on a stream, against 1.1 s downloaded (`docs/build-29-findings.md`, #160). Packing them as downloads helps even with signal.
8. **Following doesn't feed trips.** New episodes from shows you follow have to be added one by one, and only in the foreground (feed refresh has no background task).
9. **Some prep is blocked outright.** Low Power Mode blocks even an explicit Prepare until #765 lands. Structured PDFs can't be prepared until #336. Preparing near the storage limit can delete its own chunks (#645).
10. **Small accessibility gaps.** The storage bar's Protected and Reproducible parts used to differ by red and green alone (#503, fixed with patterns on `next`). Readiness is a small word on each row; there's no spoken summary.

## 2. Three bold directions

### A. Pack for a trip (plan-first)

A trip is a thing you make. You say how long, the app builds a list to fit, you get it ready, and it plays as a list. A Pack has a beginning (getting ready), a middle (the drive) and an end (recap and cleanup).

- **Good:** it answers the real question ("do I have enough?") in hours. It gives every hidden step (download, prepare, keep, order) one home. It makes "prepare before you leave" the natural thing. It reuses `ItemCollection`, the ledger, explicit preparation and the download coordinator.
- **Bad:** it's another screen to learn, and it needs a plan ahead of time. For a daily commute, building a Pack every morning would be a chore.

### B. Always ready (invisible)

No trips, no lists. The app keeps a rolling window of what you're likely to play next (in-progress items, newest from your top shows) downloaded and prepared, every night on the charger. You just get in the car.

- **Good:** zero effort when it works. Great for the commute.
- **Bad:** it guesses, and guesses wrong on the days that matter most (a long trip needs ten times the usual amount). It breaks the consent rule the design work set: following must never download or import on its own (`Design/SpokenMarginsOverhaul/research/use-cases-and-flows.md`). It also burns battery and storage on things you may never play, and you can't tell whether today is covered.

### C. Road mode (in-the-moment)

Focus on the drive itself. A big-button driving screen, auto-continue, spoken announcements, smart fallbacks when something isn't ready, and Siri for everything. No planning at all; it makes the best of whatever is on the phone.

- **Good:** fixes the worst pain (silence after each item) without asking you to plan. Safe to use while driving.
- **Bad:** it can't make content appear that isn't on the phone. On a long drive with no signal, it gracefully runs out instead of not running out.

### Why A, with C built in and B kept for the commute

A on its own still leaves the drive clunky; C on its own still runs out. So the recommendation is **A's planning, with C's driving behaviors as the way a Pack plays**. B survives as a scoped, opt-in version: an **Everyday Pack** you set up once ("keep 1 hour ready"), which refills only from sources you named. That keeps the consent rule (you chose it) and gives the commute its zero-effort path.

## 3. The recommended design in detail

Screens are described top to bottom so they read well aloud.

### 3.1 Where you start

- **Library toolbar: a suitcase button, "Pack".** Opens the Pack sheet. If a Pack is active, it opens that Pack instead.
- **Any item's long-press and More menu: "Add to Pack".** Adds to the active Pack, or starts one.
- **Siri and Shortcuts: "Pack for a trip"** (asks how long) and **"Play my Pack"**. Both appear in Shortcuts with no setup, through an `AppShortcutsProvider`.
- **No automatic prompts.** The app never decides you're going on a trip.

### 3.2 Building a Pack

**Step 1, the sheet's top half: how long and when.**
- "How long will you be listening?" Big chips: **30 min · 1 hour · 3 hours · 6 hours · Other**. Other opens an hours-and-minutes picker.
- "When do you leave?" Chips: **Now · Tonight, for the morning · Pick a time**. This sets how much prep time there is.
- A name field, prefilled "Trip · Sat 4 Oct". Most people never touch it.

**Step 2, the list.** As soon as you pick a length, the list fills to it, in this order:
1. What you're in the middle of (Continue order), from where you left off.
2. Unplayed items already in your Library, newest added first.
3. Shared Margins waiting for you, as their items ("3 Margins from Sam on this episode").
4. New items from shows you follow, in a separate group headed **"From Following, add?"**. Each one has an Add button and nothing downloads until you tap it. "Add all 4" is there for speed.

Above the list, the **time bar**: "5 h 40 min of 6 h". It counts time at your listening speed, so a 60-minute episode at 1.5x counts as 40 minutes. When the list is over the target, the extra items sit below a line: "Past your 6 hours. Kept as spares."

Each row, top to bottom:
- Title (two lines at most), then show or source.
- Length at your speed, and a kind icon (podcast, article, PDF).
- **Readiness, as a word plus an icon** (never color alone):
  - **Ready** (checkmark in a circle).
  - **Needs download · 84 MB** (arrow down).
  - **Needs the voice prepared · about 20 min plugged in** (waveform). Estimate.
  - **Live voice only** (speaker with a small lightning mark) for structured PDFs until #336 lands. It still plays offline; the voice renders as it goes, which uses more battery and may switch to the iOS voice when the phone is hot.
  - **Needs signal** (cloud with a slash) for anything that can't be stored, such as a followed article not yet imported.
- Drag handle to reorder, swipe to remove (with Undo), tap to open the item.

At the bottom: **Add from Library** (opens a picker with search and the Offline filter) and the main button.

**Step 3, the "Get ready" card** (replaces the main button once there's work to do):
- "To get this ready: download 3 episodes (420 MB) and prepare 2 articles (about 45 min plugged in)."
- "Best: plug in and stay on Wi-Fi. It keeps working with the screen off, but iPhone decides when. Keeping this screen open while plugged in is faster."
- If space is short: "This needs 1.2 GB more than your 5 GB budget. **Clear 1.4 GB of finished episodes** · **Raise budget to 10 GB** · **Remove spares**." Clearing lists exactly what goes; recordings and Margins are never on the list.
- Button: **Get ready**.

If everything is already ready, the button is **Play Pack** and the card says "All 5 h 40 min plays offline."

### 3.3 Getting ready

The Pack screen becomes a readiness screen.

- **The meter:** a thick bar and big text, "3 h 10 min of 5 h 40 min ready". Ready time is filled solid; time still to do is drawn with a hatch pattern, so the two differ by shape as well as shade. VoiceOver reads the sentence.
- **Status line under it, in plain words:**
  - "Working. About 40 minutes left." (estimate)
  - "Paused: the phone is warm. It picks up again when it cools."
  - "Paused: unplugged. Plug in to keep going." (automatic work only; see edge cases)
  - "Waiting for Wi-Fi for 2 episodes (310 MB). **Use cellular now**."
  - "Done. Everything plays offline."
- **Rows** as in step 2, each with its own small progress ("12 of 30 parts" for a voice, "45%" for a download), in Pack order. The first item gets ready first, so a short notice still gives you the start of the trip.
- **"Keep working with the screen on"** toggle, shown only while plugged in. It keeps the app open with a dim, mostly black screen showing the meter, so rendering runs at full speed instead of waiting for iPhone's background time. Unplugging turns it off.
- **A notification** when the Pack is ready, and one if it's stuck for more than 30 minutes (heat, no Wi-Fi, full storage), saying what it needs.

### 3.4 Before you go: the ready check

Opening the Pack on the day (or saying "Play my Pack") shows, and offers to read aloud, one sentence:

- "Your trip Pack is ready: 9 items, 5 hours 40 minutes, all offline."
- Or: "4 hours 50 minutes is ready offline. 2 articles will use the live voice. One episode isn't downloaded and will be skipped without signal."

Then **Play Pack**. The speaker button reads the sentence with the iOS voice, which needs no preparation.

### 3.5 On the road

- **It plays straight through.** At the end of each item the next one starts after a short spoken bridge: "Next: The Shape of Attention, by Maya Chen. 18 minutes." Bridges can be turned off in the Pack's More menu.
- **The playback screen** gains one line above the title: "Pack · 3 of 9 · 3 h 12 min left". Tapping it shows the Pack list with the current item marked.
- **Live Activity and Lock Screen** show the same line, and the Live Activity gets a **Next item** button.
- **Steering wheel and CarPlay buttons keep doing what they do now** (skip back and forward by your skip interval). Skipping back 15 seconds matters more while driving than jumping items. Next item is a button on screen and in the Live Activity, and a Siri phrase ("Skip to the next one in my Pack").
- **Margins while driving** use whatever hands-free capture the "hands-free Margin capture" design lands on. The Pack only records which Margins happened during the trip, for the recap.
- **Order stays yours.** Finishing an item ticks it off; skipping it leaves it in the list marked "Skipped".

### 3.6 When things run out or go wrong

| Situation | What the listener hears and sees |
|---|---|
| Next item isn't ready (no download, no signal) | Spoken: "Skipping 'Housing Futures'; it isn't on the phone. Next: …". The row is marked "Skipped, not downloaded". It never sits in silence. |
| Next item is a streamed episode and there is signal | It streams. The row said "Needs download" at the ready check, so this isn't a surprise. |
| Signal drops in the middle of a streamed episode | After the player's buffer runs dry: "Lost signal, and this episode isn't downloaded. Moving to the next item that plays offline. I'll keep your place." Its position is saved, and it returns to the end of the Pack as "Unfinished". This replaces today's misleading "Use Download Again" message. |
| Article only partly prepared | Prepared parts play as files. After that, the live voice takes over (today's behavior). If the phone is hot, the existing rule switches to the iOS voice and says why. Spoken once: "The rest of this article uses the live voice." |
| Phone hot in the car | Playing prepared files and downloads is light work and continues. Rendering pauses (PR #765) and resumes when it cools. |
| Battery under 20% | Live rendering is avoided: an unprepared article is moved after the prepared items, with a one-line notice. Prepared files keep playing. |
| Pack finished | A soft chime, then: "That's the end of your Pack. 2 hours 10 minutes of other things play offline. Keep going?" Saying or tapping **Keep going** plays Continue-order items that play offline. Otherwise playback stops. |
| Storage fills during prep | Prep stops at what fits. The card says how much is ready and offers the same choices as 3.2. Pack items are never evicted to make room for other Pack items. |
| App killed or phone restarts | The Pack and its position are saved in the database; "Play my Pack" resumes the current item where it was. |
| You add a new item mid-trip | It joins the end of the Pack, marked with what it needs. |
| Following has new episodes at a Wi-Fi stop | Nothing happens on its own. The Pack's "From Following" group shows them next time you open it. |

### 3.7 Coming home

A Pack ends when its last item finishes, or the day after you mark it done. A card on the Pack:

- **"Trip recap"**: "7 Margins you made on the road", played back-to-back or opened in the Margins tab (the existing "which Margins belong to this collection" query, #490).
- **"Free 2.1 GB from this trip"**: lists the downloads and prepared voices of items you finished. Recordings, Margins and unfinished items are never on it.
- **"Keep as a collection"**: the Pack's list stays as a named collection (it already is one).

### 3.8 The Everyday Pack (commute)

Set once from the Pack screen: **"Keep ready every day"**, with a length (30 min, 1 hour, 2 hours) and a source rule (what I'm in the middle of, plus the newest episode from shows I pick).

- Each night on the charger and Wi-Fi it tops up to the length: downloads and voices, in Continue order, from only what you allowed.
- In the morning it plays like any Pack.
- Finished items drop out and their files become normal reproducible files again.

This is the only automatic piece, and it only ever acts on sources you named.

### 3.9 Accessibility (you're dyslexic, listen to replies, and are red-green colorblind)

- **Hours, not gigabytes.** The main number is listening time. Megabytes appear only where a choice depends on them (cellular, storage).
- **Every state is a word plus an icon.** Ready, Needs download, Needs voice, Live voice only, Needs signal. The meter uses solid against hatched. No red-green pair anywhere; where tint helps, use blue and orange.
- **It can be heard.** The ready check, skips, bridges and the end of the Pack are all spoken. Everything on the Pack screen has a VoiceOver label that starts with the item title and ends with its readiness.
- **Short words.** "Pack", "Get ready", "Play Pack", "Keep going". No "reproducible", "eviction" or "render" in the main flow; Settings > Offline Storage keeps its detail for anyone who wants it.
- **Big targets.** Chips and the main button at least 56 pt. The driving controls stay in the bottom half, in thumb reach.
- **Dynamic Type** to the largest accessibility size: rows stack, the meter stays one sentence.
- **Driving safety.** Nothing in the drive needs reading. Every action has a Siri phrase.

## 4. What it needs technically

### Data (database stays readable by Build 29)

- **The Pack's list is an `ItemCollection`** (SessionKit, stored as `kind: "item_collection"`, `SQLiteSessionStore.swift:567`). Build 29 reads by explicit kind, so it never sees it.
- **A sidecar `ListeningPack` record** (`kind: "listening_pack"`), keyed to the collection id: target length, leave time, mode (trip or everyday), everyday source rule, current item, finished and skipped ids, cellular choice, bridges on/off, created, ended. Also invisible to Build 29. `schema_version` stays 5.
- **No new values in existing enums.** Build 29 decodes `OfflineProtectionReason` and `OfflineAssetCategory` strictly (`Packages/SessionKit/Tests/ShippedReader/SessionKit/OfflineStorageModels.swift`), so adding a "kept for trip" protection to asset rows would make Build 29 fail to read them. Instead, eviction gets the pinned item ids at planning time (next bullet).
- **Packets are untouched.** Packs are never exported.

### SessionKit (host-tested)

- **`PackFiller`**: given the Library, Continue order, sessions, shared-Margin inbox, Following entries, target length and speed, returns the suggested list and the spares. Pure function.
- **`PackReadinessPlanner`**: for each item, its readiness, bytes still needed and estimated prep time; for the Pack, ready time, total bytes against the budget, and the status line. Inputs are download records, prepared-audio manifests, the ledger snapshot, network state and a render-speed estimate.
- **`RenderSpeedEstimate`**: a rolling average of seconds of audio per second of rendering, fed by the per-chunk render time that PR #765 adds to the `preparation.render.begin` / `preparation.committed` diagnostics. Until there's a measurement, a conservative default. This is also how #64's device measurement turns into something useful.
- **`OfflinePlayability`**: "plays offline", "plays partly offline", or "needs signal" for one item. Used by the Pack, the Library rows and the pre-play check.
- **`PackSequencer.next(after:pack:playability:battery:)`**: decides what plays next, what to skip and what to announce. It holds no state; it answers a question. The playback coordinator asks it when an item ends.
- **`OfflineStoragePlanner.evictionPlan(requiredBytes:assets:pinnedItemIds:)`**: the existing planner (`OfflineStorageModels.swift`) gets one more input, the items in active Packs. Pinned items are skipped unless the listener clears them.

### App (thin call sites, focused types)

- **Pack screens** in their own files (`PackSheet`, `PackReadinessView`), not in `Gate1RootView.swift`.
- **Getting ready** calls what exists: `PodcastDownloadCoordinator` with `userInitiated` (cellular only if you said yes), and `enqueueExplicitAudioPreparation` in Pack order (`Gate1AppModel.swift:15040`). With #380 it already prepares one item at a time.
- **`ConnectivityMonitor`**: lift the `NWPathMonitor` out of `PodcastDownloadCoordinator.swift:60` into one shared monitor that the downloader, the readiness screen and the pre-play check all read.
- **Screen-on mode**: `isIdleTimerDisabled` while the readiness screen is open and the phone is plugged in, plus dimmed UI. Turned off by unplugging or leaving the screen.
- **Auto-continue** needs an end-of-item hook. Today nothing handles the end of an item. This belongs in the A2 playback coordinator (#320 and A2 M2), and should wait for it; bolting it onto the old playback paths is what broke the 24 Sept attempt.
- **Spoken bridges** use the iOS voice (`AVSpeechSynthesizer`). They are short and play between items, never over other audio.
- **Notifications** reuse `ListeningReadyNotifications.swift` for "Pack ready" and "Pack stuck".
- **App Intents**: `PackForTripIntent` (length parameter), `PlayPackIntent`, `NextPackItemIntent`, in an `AppShortcutsProvider`, so Siri works with no setup.
- **Live Activity**: the Pack line and a Next item button, alongside the existing next chapter / next shared Margin intents (`Gate2LiveActivityIntents.swift`).
- **Everyday Pack** top-up runs in the existing charging-only `BGProcessingTask` (`AudioPreparationBackgroundController.swift`), plus Wi-Fi downloads. A followed-feed refresh in the background needs a `BGAppRefreshTask` identifier added to Info.plist.

### What has to land first (already filed)

- PR #765 (heat check before every chunk; explicit Prepare works in Low Power Mode). Armed.
- PR #380 (prepare one item at a time). Armed.
- #645 (preparing near the storage limit deletes its own parts). Ready.
- #336 (structured PDFs can be prepared). In progress.
- #320 and the A2 playback coordinator, for auto-continue only.

### Found along the way

- `podcastCacheLimitChanged`, `clearPodcastDownloads` and `renderedSpeechCacheLimitChanged` have no callers (`Gate1AppModel.swift:6220, 6279`); the unified ledger replaced them. Worth deleting in a tidy-up.
- The "Use Download Again" stall message (`Gate1AppModel.swift:6246`) is wrong when the episode was streaming and there's no signal. Slice 1 fixes it.

## 5. Decisions for you

I've taken a default on each; veto by number.

1. **Cellular downloads for a Pack.** Default: Wi-Fi only, with a "Use cellular now (310 MB)" button when something is waiting. Why: it matches today's rule for automatic downloads and never surprises a data plan.
2. **Steering-wheel buttons in a Pack.** Default: keep skip back and forward; Next item lives on screen, in the Live Activity and in Siri. The other choice is to make the wheel's "next" button jump to the next item, which loses the 15-second skip. This one is taste, so tell me if you'd rather have it the other way.
3. **Spoken bridges between items.** Default: on, one short sentence in the iOS voice. Taste again.
4. **CarPlay browsing screen.** Not in the slices. CarPlay's Now Playing screen should already work, because the app publishes Now Playing controls (inferred, not tried in a car). A browsing screen (pick a Pack from the car display) needs Apple to grant the CarPlay audio entitlement, which is a request to Apple in your name. Say if you want it and I'll draft the request.

## 6. Proposed slices

Each is S or M, one PR, into `next`. Cloud means it can be built and host-tested without the Mac.

| # | Slice | Size | Where | Waits on |
|---|---|---|---|---|
| 1 | **Say when something won't play offline.** `OfflinePlayability` + shared `ConnectivityMonitor`. With no signal, tapping a streamed-only episode says "This episode isn't downloaded, and there's no signal", and the stall message stops blaming the saved audio. | S | cloud (SessionKit) + small app change | — |
| 2 | **Pack store.** `ListeningPack` sidecar record on an `ItemCollection`; save, load, end, delete. Host tests with real SQLite: survives reopen, `schema_version` stays 5, Build 29's reader ignores it. | S | cloud | — |
| 3 | **Pack filler and readiness planner.** `PackFiller`, `PackReadinessPlanner`, `RenderSpeedEstimate` with host tests (speed scaling, spares line, bytes against budget, estimate with and without a measurement). | M | cloud | 2 |
| 4 | **Pin Pack items against eviction.** `evictionPlan(…pinnedItemIds:)`, called by the ledger with active Pack items. Test: a pinned download survives a budget squeeze; unpinned ones go first. | S | cloud | 2, #645 |
| 5 | **Pack sheet.** Length and leave-time chips, filled list, time bar, readiness words, reorder, remove, From Following group, Add from Library. | M | Mac | 3 |
| 6 | **Get ready.** Queue downloads and preparation in Pack order, the Get ready card, space choices, cellular button, readiness screen with status line. | M | Mac | 4, 5, #765, #380 |
| 7 | **Screen-on mode and notifications.** Keep working with the screen on while plugged in; "Pack ready" and "Pack stuck" notifications. | S | Mac | 6 |
| 8 | **Play through the Pack.** `PackSequencer` + the end-of-item hook in the playback coordinator: auto-continue, skip what isn't ready (spoken), lost-signal move-on, end of Pack and Keep going. Pack line on the playback screen and Live Activity. | M | Mac | 6, A2 coordinator (#320) |
| 9 | **Spoken ready check and bridges.** | S | Mac | 8 |
| 10 | **Siri and Shortcuts.** Pack for a trip, Play my Pack, Next item, in an `AppShortcutsProvider`. | S | Mac | 6 (8 for Next item) |
| 11 | **Trip recap and cleanup.** Recap of the trip's Margins (uses #490), free space from finished items, keep as collection. | S | Mac | 6, #490 |
| 12 | **Everyday Pack.** Keep N hours ready each night on the charger and Wi-Fi, from named sources only; background feed refresh. | M | Mac | 6, 8 |
| 13 | **Tidy-up.** Remove the dead podcast-cache and rendered-speech-cache setters. | S | cloud | — |

Slices 1-4 and 13 can start now in the cloud. 5-7 give you a usable "get ready for a trip" on their own, before auto-continue. 8 is the one that changes the drive, and it rides on the playback coordinator.

**Journeys.** This adds one: **J8, Pack for a trip.** Build a 1-hour Pack with an episode and an article, get it ready, turn on Airplane Mode, play the Pack and confirm it moves from item to item, skips an item that isn't ready with a spoken line, and ends with the end-of-Pack message. Must not break: J1, J2, J3, J7, the Build 29 database, packets, and the owner's Library and recordings (Packs never delete an item, and cleanup only offers reproducible files of finished items).

## 7. How this lines up with existing work

- **C2 voice** (#64, #765, #380, #645, #336): the Pack is the reason those fixes matter to a listener. They make "Get ready" reliable; the Pack makes them visible.
- **D5 player** (#429, #447): the Pack line sits above the title in the Now view; the Pack list could later be a fourth view in the switch, but doesn't need to be.
- **D3 following** (#484 ranking): the "From Following, add?" group can use the ranking once it exists, and shows newest first until then.
- **Collections** (#489, #490): a Pack is a collection, so its Margins can be reviewed by collection afterwards.
- **Hands-free Margin capture** (sibling design thread): the drive uses whatever it lands on.
- **Getting back to notes** (sibling design, `getting-back-to-notes.md`): its "Listen Back" episode is a natural thing to put in a Pack, and the trip recap could be one.

---
_Design thread "Reimagine offline trip prep". If something specific went wrong on your road trip, tell me and I'll check this covers it._
