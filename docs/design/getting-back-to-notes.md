# Getting back to what you noted: a reimagining

Spoken Margins · design doc · 4 October 2026 · designed against `next` at `1744dff`

Phone mockups of the recommended design: https://claude.ai/artifact/JQzUk9YTKjqUVMkPyJd9Jt

Mockups only. Nothing here is built, filed or tried on a device. Sizes and counts come from the code and the owner's E1 export, as cited.

## The short version

1. **Your Margins become a show you listen to.** Once a week (or for one episode, or for one topic) the app stitches a short audio episode: a few seconds of the source, then your own voice, then the next one. You play it in the normal player, on a walk, with the Lock Screen.
2. **You sort them by ear.** While it plays, three buttons do the reviewing: **Let go**, **Bring back later**, and **Add to this thought**. Doing nothing means keep.
3. **Each item gets a notebook page.** Your Margins sit inside the episode's chapters or listening-map scenes, in the order they happened, each with a one-line gist and a play button. The page you see is the note that goes to Obsidian.
4. **The week ends with a note.** The kept Margins, your new thoughts and what's coming back, written to your notes folder.

The key technical move: the weekly episode is **rendered to one audio file with chapters** and played by the existing player. That avoids a new playback state machine (AGENTS.md forbids one), and it doesn't have to wait for the A2 playback coordinator, which E2's audio mode waits on today.

## 1. Where this flow stands today

### What exists (on `next`)

| Surface | What it does | Where |
|---|---|---|
| Margins tab | Search field, a scope picker listing every item, chips for Mine · Starred · Shared, then every Margin grouped by item. Rows show 3 lines of the transcript and "Source · 42%". Long-press offers Play this moment, Copy with Context, Star. | `ExperienceMarginsScreen.swift` |
| Margin detail | A sheet: full words, "Attached to: Source", position, context (collapsed), Copy with Context, Play Margin, Retry, Open Item. "Play this moment" is pinned at the bottom. | `ExperienceMarginDetailView.swift` |
| Item page | "Recent Margins" (first 3), a "Review Margins" button that jumps to the Margins tab filtered to the item, the Listening Map scenes, and a session list with a share button per session. | `ExperienceItemDetailScreen.swift` |
| Timeline | One session in listening order, with "Reflect on this session" (on-device Summarize, or paste in another chatbot's answer). | `ExperienceTimelineRailScreen.swift` |
| Export | Five routes: Export Session (AI Handoff Markdown or JSON, three scopes, five toggles), Export Sessions to a folder, automatic notes folder (one note per Margin; per item on completion is coming in #587/#766), Share as Markdown (#493, in progress), Copy with Context. Readwise (#172) and Zotero (#206) await your check. | `ExportScreen.swift`, `BatchExportScreen.swift`, `MarginNotesDelivery.swift` |
| Collections | Store exists (`ItemCollection`); the Margins scope for it is #490 (ready). | `SessionKit/ItemCollection.swift` |
| Play this moment | Lead-in, your Margin inline, then your other Margins as they come up. | `MarginMoment.swift`, `MarginMomentConductor.swift` |
| Leveled Margin audio | A loudness-matched copy of each Margin's voice. | `MarginLoudnessLeveler.swift` (#566) |

Planned but not started: E2 "reflect" (weekly review, then an audio mode) and D2 "home" (a week card). E1 "structure" (kind views like "my open questions") stopped after research.

### What gets in the way

1. **Your Margins are long, and the list shows their first words.** On your own 497-Margin export, the median Margin is **103 words of spoken monologue**, often making several points (#200, owner set, 28 Sept). Three lines of preview show the warm-up ("So I think what's interesting here is…"), not the point.
2. **Reading is the hard way in.** Reviewing means reading transcripts. For you, listening is the natural way to take in words, and the app is a listening app. Yet there is no way to *listen* to your Margins as a group, only one at a time from a sheet.
3. **Within an item, Margins run backwards.** Rows sort newest session first, then newest Margin first (`Gate1AppModel.refreshMarginRows`, around line 2097). An episode's Margins read in the reverse of the order you heard them.
4. **Position is a percent.** "Source · 42%" doesn't tell you where you were. The chapter name and the clock time do.
5. **Margins and the episode's structure live apart.** The item page shows chapters and scenes in one section and Margins in another. You can't see "chapter 3, and the two things I said about it".
6. **Nothing comes back.** Nothing resurfaces a Margin after you make it. There's no week view, no "you asked this last month", no reminder.
7. **Search only matches exact words in your own text.** It doesn't look at what you were hearing (the context), and a search for "housing" won't find "house prices".
8. **Export is five different places with jargon.** "AI Handoff Markdown", "Source Notes", "Interjections", "AI Turns". The note that reaches Obsidian looks nothing like anything you saw in the app.
9. **Shared Margins are a separate list.** A friend's Margin on the same episode doesn't sit next to yours.
10. **Small accessibility gaps.** The "needs attention" row is coral beside evergreen icons. The shapes differ, so it isn't color-only, but it's a red-and-green pair. The VoiceOver label carries the date, and the visible row doesn't.

## 2. Three bold directions

### A. The Commonplace Book (reading-first)

Your Margins become a browsable knowledge base. Every Margin is broken into its points, tagged by kind (question, claim, to-do), people, places and works, and linked to related Margins. Home shows "your open questions", "people you talk about", and a graph of how your thinking connects.

- **Good:** it's the PKM dream, and it matches your 28 Sept order of uses (kind views, then people/places, then links).
- **Bad:** it rests on E1, and E1's honest numbers on your own Margins are weak: statement kind 0.47 whole-Margin, 0.71 split by sentence, against 0.69 for always guessing "claim" (#200). Question precision was 0.33. A view of "your open questions" that's wrong one time in three isn't one you'd trust. And it's the most reading-heavy design of the three.

### B. Listen back (audio-first) — recommended

Your Margins become a short show. You review them the way you made them: by ear, hands free. A weekly episode, an "all my Margins on this episode" episode, and a "things I asked to come back" episode. You sort while listening, and the week ends with a note. Each item gets a notebook page that's also its exported note.

- **Good:** fits a listening app and fits how you take in words. Uses parts that already exist: lead-ins, leveled Margin audio, two speech engines, the player, chapters and the Lock Screen. Needs no AI to work. Completes E2 (both milestones) and gives D2's Home its week card.
- **Bad:** rendering audio takes a few seconds and some storage. Lead-ins need the episode on the phone (there's a fallback, below).

### C. It comes back to you (recall-first)

Turning listening into memory through retrieval practice. The app asks, in your chosen voice, "Two weeks ago, listening to Planet Money, you wondered why housing costs outpace wages. Did you find out?" You answer by voice, and the answer becomes a follow-up Margin. Spaced like flashcards: a day, a week, a month.

- **Good:** the strongest idea for actually *remembering*. Short daily sessions.
- **Bad:** it needs to know which Margins are questions or claims worth testing. That's E1 again. Asked about the wrong Margins, it nags.

### Why B, with the best of A and C folded in

B works on day one with no inference. It takes C's best idea as an explicit button: **Bring back later** lets *you* choose what comes back, so there's no guessing. It takes A's best idea in a form that doesn't depend on tagging: the **notebook page** puts each Margin in the episode's own structure, which is the most reliable "context" there is. When E1 later earns trust, its kind views slot into the same Margins tab and the planner can bring back questions automatically.

## 3. The recommended design in detail

The visual language matches the playback round-two design (#429): a solid amber diamond is yours, a hollow blue diamond is shared. Shape and fill carry the meaning, never color alone.

### 3.1 The Margins tab

Top to bottom:

1. **Your week** card.
   - "14 Margins from 5 episodes and articles · about 12 minutes".
   - A big **Play** button (60 pt) and a smaller **See the list**.
   - Shown when there's at least one Margin from the last 7 days that you haven't reviewed.
2. **Coming back** row, when any are due: "3 Margins you asked to hear again" with its own Play.
3. **Notebooks**: one row per item with Margins, most recently active first. Artwork, title, "6 Margins · Tuesday", and a 44 pt play button that plays that item's Margins as a Listen Back episode.
4. **Search**, pinned at the top when you pull down or tap the magnifier. Results are flat rows, each with the gist, the item and chapter, and the matched words in **bold and underlined** (not colored).
5. **Filters**, under search: Mine · Shared · Starred · Needs attention · and your collections (#490).

What goes: the long scope picker (collections and the notebook list replace it), and "Source · 42%".

### 3.2 A Margin row (everywhere)

- **Line 1, the gist:** one line, about 12 words, in bold. On devices with Apple Intelligence it's written on the device for Margins over about 40 words. Elsewhere it's the first meaningful sentence after removing filler ("so", "um", "I think what's interesting is"), using the existing cleanup. Short Margins show their own words.
- **Line 2:** "Ch. 3 · 21:03 · Tue" (chapter or scene, clock time or "paragraph 12" for text, day).
- **Right:** a play button (44 pt) that plays the moment: lead-in, then your voice.
- **Left:** the diamond (solid amber yours, hollow blue shared), or a triangle with the words "Needs attention".
- **VoiceOver** reads: "Your Margin. Housing costs keep outrunning wages. Chapter 3, 21 minutes 3 seconds, Tuesday. Double-tap to open; actions: play the moment."

### 3.3 The item notebook page

Opened from a notebook row, from the item page ("Your notebook" replaces "Review Margins"), or from search.

- **Header:** title (the #295 title rule), show or site, "Listened Tue 30 Sept · finished".
- **Two buttons:** **Play all my Margins** (a Listen Back episode for this item) and **Share this note**.
- **Body, in source order:**
  - Each chapter, publisher chapter or listening-map scene is a heading, with its one-line scene summary when a map exists.
  - Under it, the Margins made there: your own and shared, interleaved by position, using the row above.
  - A recap Margin made at the end (#142) sits under "At the end".
  - Items with no structure get headings every 10 minutes ("0–10 min") or every 10 paragraphs.
- **Footer**, when the notes folder is on: "This page goes to Obsidian when you finish the item" (with #587's per-item mode), or "Each Margin goes to Obsidian as you make it".

**What you see is what you send.** The same presenter builds this page and the per-item note (#587) and Share as Markdown (#493). So the note in Obsidian has the same headings, the same order and the same gists.

### 3.4 The Margin page

Replaces the detail sheet. It opens full screen and **swipes left and right through the notebook's Margins**, so reviewing doesn't mean open, close, open.

Top to bottom:

1. **Gist**, large serif, up to two lines.
2. **"Ch. 3 · 21:03 · Tue 30 Sept · Voice"**.
3. **What you were hearing:** three sentences of the context, with the moment's sentence marked by a bar in the left margin plus a light tint and bold. A small "Read aloud" button speaks it. "Show more" expands to the full window.
4. **What you said:** the full words. Never cut off.
5. **Bottom, in thumb reach:**
   - A wide **Play the moment** button (lead-in, then your voice).
   - **Play my voice** beside it.
   - Below them, a row: **Star** · **Bring back** · **Add to this thought** · **Share** · **More** (copy with context, retry transcript, open item, delete).

"Attached to: Source" goes away. It's jargon and it's nearly always "Source".

### 3.5 Listen Back, the episode

**What it is.** One audio file the app renders on the phone, imported as a special local audio item with one chapter per Margin. It plays in the normal Now Playing screen. Speed, sleep timer, the scrub bar, chapters, Skim, the Lock Screen and AirPods all work as they do for any episode.

**What one Margin sounds like:**

1. A soft chime (0.4 s).
2. A short spoken intro in your chosen voice: "Planet Money. Middlegarchs. Chapter 3. Tuesday." The intro is said once per item, not before every Margin. Later Margins in the same item just say the chapter.
3. **The lead-in.** About 8 seconds of the source just before the Margin, from your own copy of the episode, faded in and out.
4. **Your voice**, from the leveled copy, so a quiet Margin isn't buried after a loud podcast.
5. Half a second of space, then the next one.

For a written Margin, step 4 is your words read aloud in your chosen voice. For an article, step 3 is the sentence or two before the Margin, read in the same voice the article plays in. A shared Margin plays the friend's voice, introduced by name: "Sam said…"

**Three kinds of episode:**

| Episode | What's in it | Where you start it |
|---|---|---|
| Your week | Margins from the last 7 days you haven't reviewed, grouped by item, items in the order you listened | Margins tab card; later the Home card (D2) and Siri |
| One item | Every Margin on the item, yours and optionally shared, in source order | Notebook page; notebook row |
| Coming back | Margins whose "bring back" date has arrived | Margins tab row; also appended to the end of Your week |

**Sorting while you listen.** The Now Playing dock keeps its layout (#429), but for a Listen Back episode the Margin row changes:

- **Let go**: this Margin leaves your reviews. It is **never deleted** and stays on its item and in search.
- **Bring back**: a small menu with "next week", "in a month" and "in three months". Default: in a month.
- **Add to this thought** (the microphone, where Add a Margin always is): records a follow-up. It's saved as a new Margin on the *original* item at the *original* position, linked to the Margin it follows. Playback pauses while you talk and picks up after, the same as now.
- **Doing nothing keeps it.** No tap is needed to keep a Margin, so a walk with the phone in your pocket still counts as a review.

The Now view's top half shows the current Margin: gist, item, chapter, "Margin 3 of 14", and your choice so far ("Kept" / "Let go" / "Back 4 Nov"), as words, not colors. The Timeline view shows the whole queue with those choices.

**Lock Screen and AirPods.** The chapter title on the Lock Screen is the gist. Next track and previous track move between Margins. No button you can't see does anything destructive. Let go is on screen only, and the end-of-episode screen offers undo.

**When it ends:** a short spoken wrap-up ("That's your week. You kept 11, let 3 go, and 2 are coming back next month."), then an end screen:

- **Save the week's note** (one tap; goes to the notes folder, or the share sheet if no folder is set).
- **Undo** for anything you let go during this episode.
- **Done.**

### 3.6 The week's note

A Markdown file, "Week of 28 Sept 2026 — Margins.md":

- Frontmatter in the #491 shape: `title`, `created`, `tags: [spoken-margins, week]`, counts.
- One section per item: title, source link, then each kept Margin as its gist (as a heading), its time, the context quote, your full words, and its deep link back into the app (`MarginDeepLink`).
- Follow-ups indented under the Margin they follow.
- A short "Coming back" list at the end.
- It follows the notes-folder rule already in SessionKit: a note you've edited in Obsidian is never overwritten.

### 3.7 Edge cases

| Case | What happens |
|---|---|
| The episode isn't on the phone (streamed, or evicted to save space) | The lead-in becomes the context text read aloud: the last sentence you heard before the Margin, from the on-device context window. If there's no context either, it skips the lead-in and says the chapter. Nothing is downloaded to make a recap. |
| A Margin's transcript failed | It still plays. Its gist reads "Voice Margin, no words yet", and it carries the "Needs attention" triangle. |
| A Margin has no recording (written) | Read aloud in your chosen voice. |
| The item is in Recently Deleted | Its Margins are left out. |
| A phone call or Siri interrupts | The player's normal interruption handling applies, because it's an ordinary episode. |
| You record a new Margin while a week episode plays | It's "Add to this thought", tied to the Margin playing. A fresh Margin that isn't a follow-up goes on the real item. |
| 200 Margins in a week | The week episode caps at about 30 minutes; the card says "first 30 minutes, then the rest next time", oldest first. |
| A Margin is edited or deleted after the episode was rendered | The episode is re-rendered the next time you open it. Rendering takes a few seconds and shows "Getting your week ready…". |
| Shared Margins | Off by default in Your week (they're someone else's thoughts). On by default in a one-item episode, where you'd want them. |
| Packets | Listen Back items and review state never go in a packet. Follow-up Margins share like any Margin. |
| Old builds | Build 29 opening the database sees follow-ups as ordinary Margins, and doesn't see review state. See section 4 on the episode item. |

### 3.8 Accessibility (you're dyslexic, listen to replies, and are red-green colorblind)

1. **Listening is the main path.** Every list row and every page has a play control. A full review never requires reading.
2. **Gists over walls of text.** One short line per Margin, in plain words. The full words are always there but never required.
3. **Meaning never rides on color.** Mine is a solid diamond, shared is hollow. Choices are words ("Let go", "Back 4 Nov"). Needs attention is a triangle plus words. The palette avoids red/green pairs (blue and orange, as in the playback design).
4. **Reading comfort.** Left-aligned, no italics or all caps for body text, short lines, Dynamic Type up to the accessibility sizes. The gist and words never truncate on the Margin page.
5. **Targets** of 44 pt or more, the primary actions in the bottom half.
6. **VoiceOver** reads gist, place and day in that order, and offers "play the moment" as a custom action on every row.
7. **No timed actions.** Nothing has to be tapped before a timeout.

## 4. What it needs technically

New logic goes into focused types, in SessionKit where it can be host-tested. `Gate1AppModel` and `Gate1RootView` get thin call sites only.

| Piece | Where | What it does | Reuses |
|---|---|---|---|
| `MarginGist` | SessionKit | The one-line gist: on-device model output when present, else the first meaningful sentence after filler removal. | `InterjectionCleanup`; the listening-map summary validator's rule against invented names and numbers |
| `MarginRowWording` | SessionKit | "Ch. 3 · 21:03 · Tue" from the anchor, chapters and scenes. | `MarginDeepLink.clockPosition`, chapter lookup |
| `ItemNotebook` presenter | SessionKit | Weaves chapters/scenes with own and shared Margins in source order. Feeds the page, the per-item note (#587) and Share as Markdown (#493). | `SkimStops` positions, `SharedMarginPlaybackPosition` |
| Review state | SessionKitPersistence | A **new record kind**, `margin_review`, in the existing `records` table (kept / let go / bring back on date / gist / gist producer / last reviewed). No table or column changes and `schema_version` stays 5, the same pattern as `structured_document` and `publisher_audio`: Build 29 selects records by kind and never reads this one. Nothing changes in the Margin records. Never in packets. | `SQLiteSessionStore` |
| Follow-up link | SessionKitPersistence | A field on the follow-up's `margin_review` record (parent Margin id). The follow-up itself is an ordinary Margin, so Build 29 shows it. | — |
| `ListenBackPlanner` | SessionKit | Pure: picks Margins for a week, an item or "coming back"; orders them; works out each lead-in range and its fallback; writes the intro lines; returns segments and chapters. | `SkimStops` lead-in, `SourceAnchorContext` |
| `ListenBackRenderer` | SessionKitAudio | Renders a plan to one `.m4a` and a chapter list: clips from the local episode file, the leveled Margin voice, speech for intros and fallbacks, chime and gaps. Host-tested on macOS with real AVFoundation decoding. | `AVMutableComposition` (already used in `PodcastAnchorEvidence`, `InterjectionAudioCleanup`), `MarginLoudnessLeveler`, `SystemVoiceChunkRenderer` |
| Listen Back item | App | Imports the file like a local audiobook (the import path already accepts `.m4a` and carries chapters), passing chapters from the plan rather than writing chapter metadata into the file. Hidden from the Library list; shown from the Margins tab. One week file kept at a time. | `LocalSourceImporters.importAudiobook`, offline storage ledger |
| Dock variant | App | For a Listen Back item, the Margin row offers Let go · Add to this thought · Bring back, keyed to the current chapter's Margin. | #429 dock |
| Week's note | SessionKit | Renderer for the weekly Markdown. Delivery uses the existing notes-folder rule. | `MarginNoteFrontmatter`, `MarginNoteDelivery` |
| Siri / Shortcuts | App | "Play my week in Margins" App Intent. | Existing App Intents setup |

**Why render a file instead of playing live.** A live sequence across many items needs the playback coordinator to switch sources, pause and resume, many times. That's the class of state machine the Sep 24 failure came from, and AGENTS.md says not to add another. A rendered file has one source, one player, real chapters and free Lock Screen support. Re-rendering is cheap: a 12-minute episode is under 10 MB at podcast quality.

**Privacy.** Everything is on the phone. Clips come from your own copy and never leave it. The gist model is on-device only and only reads your own Margins, never your vault (your E1 rule).

## 5. Decisions for you

Only two, both about your data:

1. **The Listen Back item in the database.** It's stored as a local audio item. Build 29 would show it in its Library as an ordinary audio file called "Your week · 28 Sept" if you ever opened that build again. **My pick: accept that.** It's harmless and playable. The alternative is a separate store, which costs a slice and adds a second way to play audio.
2. **Let go and exports.** **My pick: Let go only affects reviews.** Notes already in your folder stay. Per-item notes (#587) still include every Margin, so your notes stay complete. The alternative is to leave let-go Margins out of later notes.

Defaults I'd take without asking (veto any): 8-second lead-ins; "Bring back" defaults to a month; shared Margins off in Your week and on for one item; the week is a rolling 7 days; a 30-minute cap; no notifications (a Home card instead, when D2 lands).

## 6. Proposed slices

Each is S or M, and each ships something you can see. They're ordered so value lands early and the riskiest piece (rendering) is proven on its own. "Cloud" means it can be built and tested without the Mac.

| # | Slice | Size | Where | Tier | Notes |
|---|---|---|---|---|---|
| 1 | Margin rows: one-line gist (filler-removed first sentence), "Ch. 3 · 21:03 · Tue" instead of a percent, Margins within an item in source order | S | Cloud (SessionKit) + small app change | T1 | Fixes pain points 1, 3 and 4 on its own |
| 2 | `ItemNotebook` presenter: chapters/scenes woven with own and shared Margins | M | Cloud (SessionKit) | — | Host tests: podcast with chapters, map only, nothing, text item, shared Margin unplaced |
| 3 | Notebook page in the app; "Your notebook" replaces "Review Margins" on the item page | M | Mac | T3 | Builds on #493's helper if merged |
| 4 | Per-item note and Share as Markdown use the notebook presenter | S | Cloud | — | After #587/#766 and #493; same bytes as the page's order and headings |
| 5 | Margin page: full screen, swipe between Margins, context with the moment marked, actions in thumb reach | M | Mac | T3 | Replaces `ExperienceMarginDetailView` |
| 6 | Review state as a `margin_review` record kind (kept / let go / bring back / gist / follow-up link) | S | Cloud (SessionKit persistence) | — | Codex audit (persistence). `schema_version` stays 5; test that Build 29's frozen reader still opens the database |
| 7 | On-device gists for long Margins, with the no-invented-names check | M | Mac | T3 | Producer recorded; fallback stays slice 1 |
| 8 | `ListenBackPlanner` (week, one item, coming back; lead-ins and fallbacks; intros; chapters) | M | Cloud (SessionKit) | — | Pure; the big host-test surface |
| 9 | `ListenBackRenderer`: plan to `.m4a` plus chapters, real AVFoundation on macOS | M | Mac | T1 | Audio: Codex audit. Prove timing (each chapter starts within 50 ms of its voice) |
| 10 | Play a one-item Listen Back from the notebook page | M | Mac | T3, then owner by ear | The first audible slice. Hidden from Library |
| 11 | Dock variant: Let go · Add to this thought · Bring back, keyed to the current Margin; end screen with undo | M | Mac | T3 | `hot-file` risk; keep to call sites |
| 12 | Margins tab top: Your week card, Coming back row, notebook list; search and filters move up | M | Mac | T3 | Week episode uses slices 8 to 11 |
| 13 | The week's note: renderer and delivery | S | Cloud (renderer) + Mac (wiring) | T1 | Uses the notes-folder rule |
| 14 | "Play my week in Margins" App Intent | S | Mac | T1 | Optional |
| Later | Kind views and automatic "bring back" for questions, once E1 earns trust | — | — | — | Same tab, same planner |

**Waits on the shared moment type (added 4 Oct, owner review).** Slices 8, 9, 10 and 12 don't start until #807 merges. #807 is one SessionKit type that owns every lead-in: Play this moment (30 s), a friend's cut (20 s) and this design's 8 s. The planner and renderer take their lead-in ranges and fallbacks from it instead of working them out here.

**Owner check, once slices 10 to 12 land (about ten minutes on the phone):** play your week on a walk, let one go, bring one back, add one thought, then save the week's note and open it in Obsidian.

**Must not break:** J3 (record and rejoin), J4 (old Margins still play), J5 (packets), the Build 29 database, notes-folder per-Margin delivery for anyone on the default, and your Library and recordings (Let go never deletes).

## 7. How this lines up with the existing streams

- **E2 · reflect:** this is E2, done audio-first. Slice 12 plus 13 meets M1's "triage with at most one tap per Margin" (zero taps to keep), and slices 9 to 11 meet M2 without waiting for A2 M2. The "answer a few prompts" part becomes "Add to this thought", which is a prompt you choose. Fixed prompts could be added to the wrap-up later.
- **D2 · home:** the Your week card is the E2 card D2 already expects through I6.
- **D4 · share:** the notebook presenter becomes the one body for per-item notes and Share as Markdown.
- **D5 · player / #429:** the Listen Back episode is just another item in the new dock, with one row swapped.
- **E1 · structure:** nothing here waits on it. When its views are trustworthy, they plug into the same tab and planner.

Related: #142, #172, #195, #200, #201, #206, #429, #490, #491, #493, #566, #587, #766.
