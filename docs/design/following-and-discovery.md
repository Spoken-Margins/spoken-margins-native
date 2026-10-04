# Following and discovery, reimagined

Design session for #549 (the Following redesign Cole asked for on 2026-09-30). Written 2026-10-04 against `next` at `1744dff`. No code, no issues filed, no labels changed.

## The short version

1. **Following becomes "Today's picks": a short, finished list, not an endless inbox.** Up to eight new things, best first, each with one plain reason ("You finished the last 6"). Everything else waits on its show's page. When you've dealt with the picks, the screen says you're done. You can actually be caught up.
2. **Each pick has a big Play button.** Playing is the explicit choice. Today you tap, wait for the import, land on a detail page, then tap Play.
3. **You can hear the picks instead of reading them.** "Hear today's picks" turns the list into a short spoken rundown. It's built as a Listening Edition, which the app already plays, so there's no new audio path.
4. **Shows get their own page.** Artwork, what's new, the back catalogue, your Margins on that show, and its settings, all in one place.
5. **One "Find" field for everything.** Type a show's name or paste any link. The app works out which you meant. Search by name, OPML import and the catalog are already built in SessionKit; only the screens are missing.

My pick is direction A below, with B's show pages as the second layer. Build it in 12 slices; the first four need no new SessionKit beyond what's open today.

---

## 1. Where Following is today

What a listener sees on `next` (`ExperienceSourcesScreen.swift`):

- A toolbar with Settings and Refresh.
- One row, "16 feeds · Manage", which opens Manage Feeds (#141, merged in #604).
- Filter chips: All, Feeds, Quick Folder, then kind chips (Podcasts, Articles…) and a Subject menu (#485).
- A "New" list, newest first. Each row has a generic radio icon, the title, the feed name and a two-line summary.
  - Tap: adds the item to the Library and opens its detail page.
  - Swipe right: Add. Swipe left: Dismiss, with no undo.
- Manage Feeds: an RSS link field, Browse top podcasts (the catalog drawer), Read Later Services, Import Listening Edition, and a flat list of feeds. Each feed's menu has "Let me pick / Add every new item", Mute and Unfollow.

Behind it (`FollowedSourceCoordinator.swift`): each feed keeps its 25 newest entries. Feeds refresh only while the app is open, at most every 6 hours unless forced, one feed at a time. Conditional refresh headers are sent but never saved, so every refresh downloads the whole feed.

### Pain points

1. **It never ends.** 60 feeds × 25 entries is up to 1,500 rows. A daily news show buries a monthly show you love. "You're caught up" is unreachable for anyone who follows more than a few shows.
2. **It's a sorting job, not a listening surface.** The row's main action is "add to Library", not "listen". Playing something new takes a tap, a wait, a second screen and a second tap.
3. **No sense of cost.** Rows don't show length, even though `FeedEntry` stores `audioDurationMs` and `bodyWordCount`. You can't see "this is 12 minutes" vs "this is 2 hours".
4. **Every row looks the same.** Same icon, same layout, no artwork. For a dyslexic listener, recognising a show by its picture is much faster than reading its name.
5. **No home for a show.** You can't see a show's older episodes, what you've done with it, or why it's there. Settings for a show are three levels deep in a menu.
6. **Finding new things is scattered.** RSS paste is in Manage Feeds. The catalog drawer is mainly a first-run screen. There's no search by name (#471). Following what's playing lives on the playback screen. OPML import is built but has no screen (PR #564 open).
7. **Nothing explains itself.** No row says why it's there, or why it's in that position (ranking is PR #570, open).
8. **Dismiss is final and silent.** No undo (#477), no "less of this show", no "not today, maybe later".
9. **Reading-heavy.** Two lines of grey summary text per row. Nothing can be heard.

### Already built and waiting for a screen

These matter because the redesign can lean on them instead of starting new work:

| Piece | Where | State |
|---|---|---|
| Search by show name | `ITunesSearchSourceResolver.swift` | Built, 50/50 on the fixture. No UI (#471). |
| Offline name search over the catalog | `CatalogSourceResolver` in `SourceResolution.swift` | Built. No UI. |
| Merging results from several resolvers | `SourceResolverRegistry.merge` | Built. No UI. |
| OPML import preview and export | `SessionKitFeeds/OPML.swift` | Built. Import UI in PR #564. |
| Listening signals (I4) | PR #567 | Open, in the lane. |
| Score with a reason, Pin, Less of this show | PR #570 (#484) | Open, needs screenshots. |
| Catalog of 200 shows and writers, with subjects and artwork | `Site/onboarding/catalog/v1/` | Shipped. |
| Per-show "add every new item" | `FeedNewItemPolicy` | Shipped. |
| Follow suggestion after 25% or a Margin | `offerFollowSuggestionIfEligible` | Shipped. |
| Listening Edition with scenes and summaries | `ListeningEdition.swift` | Shipped. Skim already plays scene summaries. |
| Episode duration, article word count | `FeedEntry` | Stored, never shown. |

---

## 2. Three directions

### A. Today's picks (an edition, not an inbox) — **my pick**

Following opens on a short, ranked list with an end. Think of a morning paper, not an email inbox.

- **Up to eight picks**, at most one per show (two for a pinned show). Each has artwork, length, one reason, and a Play button.
- **Below the picks, "Also new"**: everything else, folded into one line per show ("Odd Lots · 3 new"). Tap a show to open its page.
- **A length filter** in thumb reach: Any · Under 20 min · 20 to 60 · Over an hour. "I'm walking to the shop" becomes one tap.
- **A real ending**: once each pick is played, kept, or passed, the screen says "That's today's picks" and offers "Find something new".
- **Hear it**: "Hear today's picks" plays a one-to-three-minute rundown of the list.

Why it's bold: it's the opposite of every podcast app's "New Episodes" list. It treats attention as the scarce thing and says so.
Cost: medium. The list builder is a pure SessionKit function. Ranking is already in PR #570; without signals it falls back to newest with the per-show cap, which is already better than today.
Risk: a listener who wants "show me everything" may feel hidden from. Answer: "Also new" is right there, and every show page lists everything.

### B. The shelf (shows first)

Following opens on your shows, not your episodes. A grid of artwork tiles, each with a "3 new" badge in a corner and a one-line relationship ("12 Margins · finished 8"). Tap a tile for the show's page.

Why it's bold: it makes the show the unit of attention, the way people actually think ("is there a new Odd Lots?"). Recognition by picture is the best possible case for a dyslexic listener.
Cost: medium. Needs artwork saved for followed feeds (today only catalog shows have it), and a show page.
Risk: with 60 shows the grid itself becomes the wall again, and it doesn't answer "what should I listen to now?" across shows.

### C. Fill my time (a playlist you don't build)

Following opens on one question: "How long have you got?" Pick 15 min, 30, 1 hour, or "the drive" (a saved length). The app builds an up-next list that fits, best first, and starts playing. Swipe to skip one; the list refills.

Why it's bold: it removes choosing altogether, which is the real job for a walk or a drive. It's also hands-free friendly.
Cost: large. The app has no play queue: when an item finishes, the session closes and returns to the Library. A queue is a playback-coordinator change (A2 M2), and AGENTS.md forbids adding another playback state machine before then.
Risk: the most likely of the three to feel "wrong" when it picks badly, because the listener didn't choose.

### Why A, with B's show pages

- A is the only one that fixes pain points 1, 2, 3, 7 and 8 together, and it can ship in slices on top of what exists.
- B's best idea, the show page, slots under A as the second level. The "Also new" rows are where B's tiles would have been.
- C's best idea, the length filter, ships inside A as a filter. The full auto-playlist waits for the playback coordinator and can come later as "Play these in order" on the picks.

---

## 3. The recommended design in detail

### 3.1 Navigation

Tabs stay Library · Following · Margins. Following has three levels:

1. **Today's picks** (the tab's first screen).
2. **A show's page**, pushed from any pick, any "Also new" row, or the shelf.
3. **Find**, a sheet opened from the search button in the top bar, from the empty state, or from "Find something new" at the end of the picks.

Manage Feeds (from #141) becomes **Your shows**: the same list, now with artwork, unread counts and a row per show that pushes its page. Settings per show move onto the show page; the menu stays as a shortcut.

Home (D2) doesn't exist yet. When it does, it shows the top one or two picks with their reasons, through I6. This design gives Home its "start this next" card for free.

### 3.2 Today's picks

Top to bottom on an iPhone 17, with the mini player and tab bar at the bottom:

| Row | What it holds |
|---|---|
| Top bar | Title "Today", subtitle "8 picks · 3 h 10 m". Search (opens Find) on the right. Settings moves to the Library tab's top bar (it's reachable from every tab today; one place is enough). Refresh becomes pull-to-refresh. |
| Hear button | "Hear today's picks" with a speaker icon. One line, full width. |
| Length filter | Any · Under 20 · 20–60 · Over 1 h. A segmented control, 44 pt tall. |
| Picks | Up to eight cards. |
| Also new | One row per show with new items not in the picks: artwork, show name, "3 new". Muted shows aren't listed. |
| From your folder | Quick Folder files, if any, as one row: "2 new files". |
| End line | "That's everything new. Last checked 9:41." |

The length filter sits above the picks rather than in the bottom thumb zone, because the bottom is the mini player. The picks themselves, and their Play buttons, are where the thumb rests once you scroll one card.

#### A pick card

```
┌─────────────────────────────────────────────┐
│ [art]  Odd Lots                    42 min   │
│ 56pt   Why copper is the new oil            │
│        ◆ You finished the last 6            │
│                                   ( ▶ Play )│
└─────────────────────────────────────────────┘
```

- **Artwork** (56 pt) on the left. Articles without artwork show a page icon on a tinted square. Podcasts without artwork show the first letter of the show.
- **Show name** in small semibold text, **length** on the right in the same line. Articles show "12 min listen", estimated from the word count at your current speech rate.
- **Title**, two lines, then "…". The full title is on the show page and in the long-press preview.
- **Reason**, one line, after a small shape that says what kind of reason it is (see 3.8). No summary text on the card. The summary is one long-press away.
- **Play**, a 44 pt pill, bottom right. It adds the item to the Library and starts it, in one tap. This is the explicit choice the product boundary requires, so nothing changes there.

Card actions:

| Gesture | Result |
|---|---|
| Tap Play | Adds to Library and plays. The card shows "Playing" and stays put. |
| Tap the card (not Play) | Opens the show's page scrolled to this episode. |
| Swipe right | **Keep for later.** Adds to Library without playing. The card shows "Kept" for a moment, then collapses into a "Kept today · 2" line at the top. |
| Swipe left | **Not today.** The card goes; a bar at the bottom says "Moved to Odd Lots' page · Undo" for 6 seconds. It isn't dismissed for good: it's still on the show page. |
| Long press | Menu: Play now · Keep for later · Not today · **Not for me** (dismiss for good) · **Less of this show** · **Pin this show** · Unfollow Odd Lots · Show details (summary, date, full title). |

Swipe actions also exist as visible buttons on the card for VoiceOver and Switch Control, and as named accessibility actions.

The first time Following opens after this ships, one card shows a small hint under it: "Swipe right to keep, left for not today." It goes after the first swipe, or after three opens.

#### Which eight

`FollowingEdition` (new, SessionKit) builds the list. It's a pure function, so it's host-testable.

- **Inputs:** feed entries in state `unseen` or `seen`, not already in the Library; subscriptions (muted ones excluded); Pin and Less-of choices from #484's file; scores from #484's scorer when present; the length filter; now.
- **Rules, in order:**
  1. Pinned shows first, newest episode each.
  2. Then by score if there are signals, otherwise newest first.
  3. At most one item per show (two for pinned).
  4. "Less of this show" shows can appear only if fewer than eight others qualify.
  5. Entries older than 30 days never become picks. They're still on the show page.
  6. Stop at eight.
- **Stable while you look.** The list is built when Following opens, on pull-to-refresh, and after a background refresh that happened while it was closed. It never reorders under your thumb. A new episode that arrives while you're looking shows as "1 new pick · Show" at the top, and only joins when tapped.
- **Reasons.** Every pick has exactly one. With no signals yet: "New today", "New this week", or "You follow this". With signals, from #484: "You finished the last 6", "You made 12 Margins on this show", "You shared Margins from this show", "Pinned".

#### The ending

When every pick has been played, kept or passed:

> **That's today's picks.**
> 11 more new on your shows' pages.
> [ Find something new ]

When nothing is new at all:

> **Nothing new yet.**
> Last checked 9:41. Your 16 shows publish about 20 episodes a week.
> [ Find something new ]

### 3.3 Hear today's picks

A short spoken rundown of the list, for when reading is the hard part or your hands are busy.

**What you hear** (about 15 seconds a pick):

> Eight picks, three hours ten in all.
> One. Odd Lots. Why copper is the new oil. Forty-two minutes. You finished the last six.
> Two. …

**How it's built.** The app writes a Listening Edition: the text is one block per pick, and each pick is a scene whose summary is the episode's own summary. Then it plays it through the normal text playback path. That gets all of this for free:

- the installed voice and speed the listener already chose;
- Now Playing, Lock Screen and headphone controls;
- "next paragraph" moves to the next pick;
- **Skim plays a pick's summary**, so "tell me more about this one" already works;
- Add a Margin works, if they want to say "listen to this one on Saturday".

**Acting on a pick while it plays.** While the rundown plays, Following highlights the pick being read with a ring and a large "Play this" button. Tapping it starts that episode (the rundown session ends normally; it's a short item and nothing is lost). "Keep" is the swipe as usual.

**What it isn't:** no new audio path, no new playback state, no speech recognition. Voice commands ("keep that one") belong to the hands-free thread, not this one.

**Where the rundown lives.** It's an item in the Library, titled "Today's picks · Sat 4 Oct". The app never deletes it (owner data rule). It's filtered out of the Library's default view by its `edition-` item id prefix, under a "Rundowns" filter, so it doesn't clutter. Decision 3 below asks Cole about this.

### 3.4 A show's page

Pushed from any pick, "Also new" row, Your shows, or a Find result.

| Section | What it holds |
|---|---|
| Header | 120 pt artwork, show name, author. One line of your history: "Following since June · finished 8 · 12 Margins". For a show you don't follow: a Follow button instead. |
| Controls | Three chips: **New episodes** (Let me pick / Add every new one) · **Pinned** on or off · **Muted** on or off. Unfollow is at the bottom of the page, in plain text, with the existing confirmation. |
| New | Every new episode, newest first, as compact rows with length and a Play button. Same swipes as picks. |
| Your Margins here | Your three latest Margins on this show, each with a play button, then "All 12". This is what no other podcast app can show. |
| Earlier | The rest of what the feed lists (up to the 25 kept), marked "Played", "In Library" or neither. |
| About | The feed's description, link, last checked time. If the last refresh failed: "Couldn't reach this feed at 9:41. We'll try again." with a Retry button. |

Shared Margins from other people on this show come later, when F1 gives packets a "from" that can be grouped by show.

### 3.5 Find

One sheet, one field at the top: **"Show name or link"**.

- **Typing a name** (two or more letters, about 300 ms pause): results from the catalog appear instantly, offline. iTunes Search results join under them when they arrive (`SourceResolverRegistry.merge` already de-duplicates). Each row: artwork, title, author, Follow. A show that's only on Spotify or Apple shows "Can't follow: no public feed" in plain text.
- **Pasting a link**: the field notices it's a link and runs today's follow path: RSS, Apple, Spotify, Substack, any web page with a feed. Several matches show the existing chooser.
- **Empty field**: the catalog's subject chips and rows, as in the drawer today, plus three rows at the bottom: "Import from another app (OPML)", "Read Later services", "Import a Listening Edition".
- **Following from Find** never adds episodes to the Library. A new show's latest episode becomes a pick next time the list is built, with the reason "You just followed this".

The first-run drawer becomes this same sheet, opened on the catalog. One screen to maintain instead of two.

### 3.6 Your shows

The renamed Manage Feeds. A list (not a grid: names stay readable at large text sizes), each row: artwork, name, "3 new" or "Up to date", and small tags "Pinned", "Muted", "Adds every episode" or "Can't reach" when they apply. Sort: Most listened · A to Z · Recently added. Tap a row for the show page. Swipe left for Mute and Unfollow. Export all as OPML at the bottom.

### 3.7 Edge cases

| Case | Behaviour |
|---|---|
| First run, follows nothing | Following shows Find, open on the catalog, with "Follow three to five shows to get your first picks." No empty picks screen. |
| Follows one or two shows | Picks show what exists; the end line suggests "Find something new". |
| A daily news show and a monthly essay show | The per-show cap gives the monthly one a fair slot. |
| 60 shows, 200 new items | Eight picks; "Also new" folds the rest into at most 60 rows (one per show). |
| Just followed a show with 25 old episodes | Only the newest becomes a pick. The rest is on its page under "Earlier", not counted as new. Matches today's first-fetch rule for "Add every new item". |
| "Add every new item" show | Its new episodes go to the Library as today. They don't appear as picks; the show's row in Also new says "2 added to Library". |
| Muted show | Not in picks or Also new. Still on Your shows with a "Muted" tag. |
| Offline | Picks built from the last refresh, with "Offline · last checked 9:41" under the title. Play still works for downloaded items; others say "Needs a connection" on the button. |
| A feed fails to refresh | Its show row says "Can't reach". The picks never show an error card. |
| Item already in the Library from elsewhere | Never a pick (today's de-duplication by URL and show plus title). |
| Unknown length | The card shows no length. It's included under "Any" only. |
| Article from a newsletter | Page icon, "12 min listen", and Play starts narration. |
| Quick Folder | One "From your folder" row. Its files never become picks; they aren't ranked. |
| Very long titles | Two lines on the card, then "…". |
| Accessibility text sizes | The card stacks: artwork above, Play full width at the bottom. Reasons wrap instead of cutting. |
| iPad | Picks in two columns; the show page opens beside them. |

### 3.8 Accessibility (Cole is dyslexic and listens; red-green colorblind)

- **Fewer words per card.** Show, length, title, one reason. The summary moved off the card.
- **Recognition by picture.** Artwork on every row, everywhere.
- **Everything can be heard.** The rundown, and VoiceOver labels written as sentences: "Odd Lots. Why copper is the new oil. 42 minutes. You finished the last 6. Play."
- **No colour carries meaning on its own.** Reason kinds use shape plus a word:
  - ◆ solid diamond: something you did ("You finished…", "Your Margins…").
  - ○ ring: new or followed ("New today").
  - ▲ triangle: pinned.
  - Status tags ("Muted", "Can't reach", "Kept") are words in outlined pills, never a coloured dot.
- **Targets.** Play, chips and segmented controls are at least 44 pt. Swipe actions are also menu items and visible buttons.
- **Dynamic Type** at every size, including accessibility sizes, with the stacked card layout above.
- **Reduce Motion** turns the card collapse into a fade.
- **Fonts.** Show names and titles use the app's existing type; no all-caps labels, no italics for meaning.

### 3.9 Tap budgets

| Task | Today | Redesign |
|---|---|---|
| Follow a podcast by name | Not possible unless it's in the top 200 (Following › Manage › Browse › subject › Follow: 4–5). Otherwise find its RSS link outside the app. | Search › type › Follow: 2 taps. |
| Play a new episode | Tap the row, wait, tap Play: 2 taps and a screen change. | Play: 1 tap. |
| Deal with 10 new items | 10 swipes, no undo. | 8 picks at most; swipe the ones you don't want, with undo. |
| Pick something under 20 minutes | Not possible. | 1 tap on the length filter. |
| Unfollow a show from its episode | Following › Manage › show menu › Unfollow › confirm: 4. | Long press › Unfollow › confirm: 3. |
| See a show's older episodes | Not possible. | Tap any of its cards: 1. |
| Import follows from another app | Not possible (PR #564 adds it). | Search › Import from another app › pick file: 3. |

---

## 4. What it needs underneath

### SessionKit (host-testable)

1. **`FollowingEdition`**: builds picks, Also new and the folder row from entries, subscriptions, choices and scores. Pure function. The heart of the redesign.
2. **`ListenLength`**: entry length in minutes from `audioDurationMs`, or from `bodyWordCount` and the speech rate. Buckets for the filter.
3. **`EditionRundown`**: turns a list of picks into a valid `ListeningEdition` (text blocks and scenes). Uses the existing validator.
4. **`ShowHistory`**: per-show counts (finished, Margins, shares, since) from I4 (PR #567) and the store's Margins. No new storage.
5. **`FindQuery`**: decides whether the field holds a link or a name, and runs the right path: today's follow path for links, `SourceResolverRegistry` with `CatalogSourceResolver` then `ITunesSearchSourceResolver` for names.
6. **"Not today" state.** A pick passed for today is remembered in the same small side file as #484's Pin and Less-of (not the database), keyed by entry id, cleared after 7 days. Entries keep their `seen` state in the database as today.
7. **Feed artwork.** Saved per subscription in a small side cache keyed by subscription id: the catalog entry's artwork when there is one, otherwise the feed's `<itunes:image>` or `<image>` (`FeedParser` doesn't read the channel image yet, so slice 1 adds that). A side file, not a database column, so Build 29 opens the database unchanged.

### App

- New focused views in `ExperienceSourcesScreen.swift` (or new files, which means `xcodegen generate` on the Mac): picks, card, show page, Find, Your shows.
- `Gate1AppModel` gets thin call sites only: it already has `importFollowedSourceEntry`, `dismissFollowedSourceEntry`, `followCatalogFeed`, `unfollowSource`, mute and the new-item rule. "Play" is `importFollowedSourceEntry` followed by the existing start. No new playback state.

### Feeds and refresh (not this design's job, but it makes it feel alive)

- Save `ETag` and `Last-Modified` so refreshes are cheap (B1 M3).
- Background refresh (#170), so picks are ready in the morning.
- Refresh feeds a few at a time instead of one by one.

### Server

Nothing required. All ranking stays on the phone and nothing about a listener's follows leaves it. Search goes from the phone to iTunes, as the link resolver already does. Two optional later ideas, both privacy-preserving:

- **"Shows like this"** on a show page, computed when the catalog is built (`research/B1/build_catalog.py`) from shared subjects and charts, and shipped inside the catalog file.
- **A bigger catalog** with real curated starter rows (all five rows are still `chart-seed`). Subject to the open licensing question (#718).

---

## 5. Slices

Each is S or M. Tiers per `docs/workstreams/test-lane.md`. "Absorbs" means an existing issue or PR that this slice builds on or replaces; nothing has been filed or relabelled.

| # | Slice | Size | Where | Needs | Absorbs |
|---|---|---|---|---|---|
| 1 | **Length and artwork on rows.** Show length (podcasts) and estimated listen time (articles) on today's rows; save feed artwork in a side cache and show it. | M | cloud | — | #477 (article icon) |
| 2 | **Play from the row.** A Play button that adds and starts in one tap; long-press menu with Play now, Keep, Not for me, Unfollow. | S | cloud | — | #478 |
| 3 | **Undo and "Not today".** Swipe left becomes Not today with a 6-second Undo; Not for me moves to the menu. Side file for Not today. | S | cloud | 2 | #477 (undo) |
| 4 | **Find, one field.** Names and links in one field; catalog first, iTunes under it; opens from the top bar and the empty state. | M | cloud | — | #471, PR #564 (OPML row) |
| 5 | **`FollowingEdition` in SessionKit.** Picks, per-show cap, 30-day limit, Also new, folder row, stability rule. Host tests only. | M | cloud | — | — |
| 6 | **Today's picks screen.** Picks, Also new, folder row, the ending. Newest-first reasons until 9 lands. | M | cloud | 1, 2, 5 | #479 (scroll position) |
| 7 | **Length filter.** The four-way control and `ListenLength` buckets. | S | cloud | 6 | — |
| 8 | **Show page.** Header, controls, New, Earlier, About, refresh errors. Your Margins section once 10 lands. | M | cloud | 1 | — |
| 9 | **Reasons from ranking.** Feed #484's scores and Pin / Less of into `FollowingEdition`. | S | cloud | 5, PR #570 | #484 |
| 10 | **Show history.** "Following since · finished · Margins" on the show page, from I4 and the store. | S | cloud | 8, PR #567 | — |
| 11 | **Hear today's picks.** `EditionRundown`, the button, highlighting the pick being read, Rundowns filter in the Library. | M | Mac | 6 | — |
| 12 | **Your shows.** Rename Manage Feeds; artwork, counts, tags, sort, OPML export. | S | cloud | 1, 8 | #141's screen |

Slices 1 to 4 make today's screen much better on their own, before the picks exist. If only those ship, the four worst pain points (no length, no Play, no undo, no search) are gone.

After 12: "Play these in order" on the picks (the auto-playlist from direction C) once the playback coordinator (A2 M2) exists. Shared Margins grouped by show on the show page once F1 lands.

### Must not break, for every slice

- Following's behaviour when nothing is customised: muting, unfollowing, import de-duplication, "Add every new item".
- Nothing enters the Library without an explicit choice (Play, Keep, or "Add every new item").
- The database Build 29 opens: side files only, no schema change.
- Packets: untouched.
- J6 (Listening Edition import) for slice 11; J2 (podcast playback) for slices 2, 6 and 11.
- Owner data: the rundown items are never deleted by the app.

---

## 6. Decisions for Cole

Each has my pick. A one-word answer per line is enough.

1. **Direction.** A (Today's picks), B (The shelf) or C (Fill my time)? **Pick: A**, with B's show pages under it.
2. **How many picks.** Five, eight or twelve? **Pick: eight.** Enough for a day, short enough to finish.
3. **Rundowns in the Library.** Keep each day's rundown as a Library item under a "Rundowns" filter, or don't save them (they'd need a separate small store, which is more work)? **Pick: keep them,** because it reuses everything and never deletes anything.
4. **Settings button.** Move it off Following to the Library's top bar? **Pick: yes,** so Following's top bar holds only Search.

Once Cole picks, the next round is a clickable phone mockup like the playback session's, and then the picks become `ready` issues with Done when items, as #549 describes.

---

## Sources read

- `AGENTS.md`, `Contracts/docs/recovery-mvp.md`, `docs/workstreams/streams/D1-design.md`, `D2-home.md`, `D3-following.md`, `D5-player.md`, `F1-coop.md`, `B1`, `B2`, `B3`, `E3`, `G2`.
- Issues #141, #146, #176, #196, #429, #471, #477, #478, #479, #484, #485, #549, #77. PRs #564, #567, #570, #604, #739, #749–#751.
- The playback design session artifact (round two), for format and depth.
- Code on `next` `1744dff`: `ExperienceSourcesScreen.swift`, `CatalogDrawer.swift`, `FollowedSourceCoordinator.swift`, the follow and import functions in `Gate1AppModel.swift`, `SourceFollowingModels.swift`, `FollowingFilter.swift`, `SourceResolution.swift`, `ITunesSearchSourceResolver.swift`, `OPML.swift`, `ListeningEdition.swift`, `research/D3/`, `Site/onboarding/catalog/v1/catalog.json`.

Inferred, not checked on a device: the tap counts for today's flows come from reading the code. Point sizes and timings are design targets, not measurements.
