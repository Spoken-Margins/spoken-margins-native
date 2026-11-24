# Core journeys

These are the checks that decide whether a build works. Unit tests protect the pieces; journeys show that the pieces add up to something a listener can use.

**How to run them**

- **Agent in the simulator.**
  - Build the current commit and install it on one simulator. Drive it with the iOS simulator tool (never computer use or Device Hub): real taps and screenshots, with no injected state or test-only launch arguments.
  - The Test Desk gives each journey to a helper agent of its own and keeps screenshots at half scale, about 15 per journey ([journey skill](../.claude/skills/journey/SKILL.md), Driving and Screenshot budget).
  - For each step, record what you observed: the screen, which item or Margin is playing, and whether its clock advanced.
  - Stop at the first failure, then report the step, expected and observed behavior, and a screenshot.
  - You cannot hear audio. A clock that advances shows the app believes it is playing, not that the right words are audible, so mark audible content "owner to confirm".
- **Owner on the phone.** Run the same journeys, listening. This is the only way a journey becomes `human_validated`.

Simulator driving pitfalls observed September 24:
- After typing text with the simulator tool, take a screenshot and confirm the whole value is present before tapping a submit button. Keystrokes and taps travel on different channels, so a quick tap can arrive before queued keystrokes. The app then receives a truncated URL, which shows up as a 404, `-1011` or "couldn't provide anything at that address" error rather than a real app bug.
- The app's Paste button reads the simulator pasteboard. `xcrun simctl pbcopy` did not reach it, so type values instead.
- iOS keyboard tips can appear over the keyboard and swallow the next tap. Screenshot before tapping near the bottom of the screen.
- Wait a few seconds after launch before the first tap. A cold Debug launch can show a blank screen for about 5 s.
- **The first listen on a fresh install opens the Terms of Use sheet. This is expected, not a bug.** Since #2853 it is one short screen ("Before you listen"): a summary, a "Read the complete Terms" link, and the two buttons, "Agree and Enable On-Device Voice" and "Use iOS Voice", all in view without scrolling (`SpokenMarginsTermsView.swift`). Tap "Use iOS Voice" (or Agree, if the run needs the on-device voice) and the play starts. Choosing an on-device voice in Settings still opens the complete Terms, with the two buttons at the end of the long text: swipe up until a swipe changes nothing on screen before deciding the sheet has no way out.
- **Before reporting a control as missing or a step as blocked, check the code.** Search the app source for the control's label (`grep -rn "<label>" App/SpokenMarginsApp/Sources`) and see where it is placed. If the code puts it somewhere you haven't reached (further down a scroll, behind a menu, after a sheet), go there first. Quote the file and line in a FAIL that still stands.

Driving with AXe (no simulator panel), observed October 18 on iOS 26.5 with Xcode 27:
- **Always pass `--tap-style physical`.** The default style answers "completed successfully" and changes nothing on screen.
- **The first AXe call after a boot or a launch can fail** with "No translation object returned for simulator". Wait a few seconds and try once more; the second call worked both times.
- **The accessibility tree includes views covered by a sheet.** With the "Follow a few favourites" sheet open, the Library's Start buttons were still listed, and a tap on one landed on the sheet. Close sheets first, and check with the OCR reader or a screenshot what is actually on top.
- **Some identifiers appear twice** (a group and its button share one). AXe then refuses the tap; use the label or the point instead.
- **In `axe batch`, a selector tap right after swipes can miss** an element that is plainly on screen (the complete Terms' "Use iOS Voice" button, reached from Settings), probably from a stale snapshot taken mid-scroll. Run the tap as its own command after the swipes, or pass `--ax-cache perStep`.
- **Long text is listed in full.** The complete Terms put every paragraph in the tree, about 7k characters; grep the ax-look output for what you need.

**Scripted journeys.** Some journeys also have a script: a UI test in `App/SpokenMarginsAppUITests/` that runs in the integration run, on probation until the Test Desk has seen it pass twice (`TestPlans/scripted-journeys.json`; rules in `docs/workstreams/test-lane.md`, Scripted journeys). A script never replaces the agent run or the owner's pass for the same journey.

Use a Library that already has content, not only a fresh install. Many of the worst bugs appeared only with real history: old containers, earlier builds' data, long episodes.

Steps are written in terms of what the listener wants, not exact button labels, so they stay valid as the UI changes.

**Starting state.** A journey step says where the listener starts, not only which screens they pass through (#4102). Name each of these that the step depends on:

- the item: not started, part way, at the end (99% and over), or marked complete;
- the listener's own Margins on it: none, or some, and whether any are friends' that they have not heard;
- the listener: first run or returning (a Library with history);
- what else is playing, and the entry point (Library row, item screen, Now, a link, the Share sheet).

A step that is true for "whatever state" (or "any", "every") must have a test for each state it names, or say which states have none. Unnamed states are where the owner's bugs have been: #4097 sat in "an item finished at 99%", which no step or test named. The states a PR or a Design comment must name are in [device-conditions.md](workstreams/device-conditions.md), "Listener history".

## J1 — Listen to an article

1. Add a web article, by pasting a URL or sharing from Safari.
2. Start listening.
   - Pass: speech starts within a few seconds and the position advances.
3. Pause, lock the phone, then resume from the Lock Screen (owner step).
   - Pass: it resumes from the same sentence.
4. Read the article's text from More, step to another chapter and back without leaving the reader (#1579).
   - Pass: the chapter title changes and returns, a way back to the playing chapter shows while away, and playback is unchanged. The sentence being read is marked by a highlighter fill and a thick underline under every line it spans, in light and dark (#3736); the underline is what tells it apart, so check it without relying on the fill's colour.

## J2 — Podcast playback survives relaunch

1. Add a podcast episode and let it download.
   - Pass: once added, the Library row shows the episode's length, and the item screen's first pill shows the same length.
2. Play it, then scrub to about 20:00.
   - Pass: audio continues from 20:00.
3. Pause, force-quit the app, and reopen it.
   - Pass: the Library row and the item screen's length pill show the same length after reopening.
4. Scrub to a different point, or jump to a chapter, before pressing play. Then press play.
   - Pass: playback starts at the new point. There is no "seek failed" error and it does not jump back.

## J3 — Record a Margin and rejoin it

1. While a podcast plays, record a spoken Margin of about 10 seconds, then finish it.
   - Pass: the podcast resumes a few seconds before where it paused (3 seconds). An article, read live or played as prepared audio, resumes at the start of the sentence it paused in. The Margin appears on the item's timeline.
2. Keep listening for a minute, then open the Margin from the timeline and play it.
   - Pass: the Margin's own voice plays to the end.
3. Let the Margin play to its end. (The source was playing when you started the Margin.)
   - Pass: the source plays again by itself, where you were. It must not stay silent or stuck, and there is no Return to tap. On a podcast, your later spoken Margins play as playback reaches them. Stopping the Margin yourself leaves the source paused, and so does playing it over a source you had already paused. (Owner's call, 2026-10-14, #1538. "Play this moment" instead continues from its lead-in.)
4. Force-quit, reopen the app, and play the same Margin again.
   - Pass: it still plays. It must not say the recording is unavailable.

## J4 — Old Margins still play after an update

1. Install the previous shipped build and record a Margin on a podcast and on an article.
2. Install the new build over it. Don't delete the app.
3. Play both Margins, and use "play this moment" / context on the podcast Margin.
   - Pass: both voices play and the source context opens.

## J5 — Share podcast Margins with someone else

This journey needs two installs: the sender's phone and a second device or simulator as the recipient.

The owner's one-phone version, with prepared packets and an episode that shares its intro with another, is the [sharing test kit](sharing-test-kit/README.md).

1. The sender shares an item that has several podcast Margins.
   - Pass: the packet is created without an error. A Margin with incomplete positioning evidence is flagged, not silently dropped.
2. The recipient opens the packet. They have not added the podcast beforehand.
   - Pass: the episode's screen opens with no Import sheet, saying who sent how many Margins; the episode is in their Library, and the shared Margins are listed with a placement status (placed, or placed roughly). A file that fails its check opens nothing and says "This file couldn't be opened." (#3291)
3. The recipient plays a placed Margin.
   - Pass: a short two-note chime, then the sender's voice plays, labeled with the sender's name, and the recipient's episode is at the Margin's moment. The owner checks by ear that the podcast audio matches what the Margin is about.
4. The recipient plays an unplaced Margin.
   - Pass: the same chime, then the voice, and the app does not pretend to know the position. This holds when the Margin is tapped in the Timeline too (#932). A muted layer has no chime.
5. Import the same packet again.
   - Pass: the episode's screen opens and nothing more is said: no duplicate Margins and no duplicate episode.

## J6 — Import a Listening Edition from Shortcuts

1. Run the webpage → Ask ChatGPT → Assemble → Import Shortcut described in `docs/pkm-workflows.md`.
   - Pass: the app opens on the imported item with its chapters, and playback has not started.
2. Pass malformed output, for example ChatGPT prose around the JSON.
   - Pass: a readable error names the problem.

## J7 — PDF

1. Import a text-based PDF and listen.
   - Pass: headers, footers and "Downloaded on …" stamps are not read aloud, and body text is.
2. Record a written Margin, then reopen it later.
   - Pass: it opens at the right passage.
3. Word (#4594). Copy `Contracts/fixtures/word/plain-paragraphs.docx` into the simulator's Files (On My iPhone), then Library, **+**, **Import from Files**, and pick it.
   - Pass: a Text row titled "The Gettysburg Address" (the title in the document's properties, not the file name). Play reads "Four score and seven years ago…" and the clock advances. A written Margin shows on the sentence it was written at.
   - Also pick `password-protected.docx` and `old-format.doc` from the same folder: nothing is added, and the banner says why (a password; the older .doc format, save it as .docx).
4. Word with Margins (#4595). On the Gettysburg item from step 3, write two written Margins on two different sentences, then tap **⋯** on the item screen.
   - Pass: the menu has **Export Word document with Margins** (it is not there on a PDF item or on an article, and it is dimmed on this item before any Margin exists). The sheet "Word document with your Margins" lists both Margins in text order with "On its sentence", no page numbers, and the footnote. **Export 2 comments** opens the share sheet with `The Gettysburg Address (with Margins).docx`; Save to Files, then open it in Files' preview or Quick Look and record whether the comments show (recorded, not required). The original `plain-paragraphs.docx` in Files is the same size as before.
5. Table and figure cards on Now (#4588). Import a PDF that has a captioned table and a captioned figure (a paper from `research/C1/corpus/manifest.json`, CC BY), open Now and play.
   - Pass: the table's picture sits in the text just before its caption, the figure's before its caption, each a white card with a hairline edge and no words on it. While the caption is read, the card stays at the top of the text with the caption under it, then the text goes back to its usual line. Tapping a card opens the full-screen picture, **Done** returns, and the clock kept advancing. A PDF imported before pictures were kept, an article and a podcast show no card. VoiceOver reads a card as "Table 2, page 7" with the hint that playback doesn't change.

## J8 — Collections

1. Long-press a Library item, choose Add to Collection, and make a collection such as "HIST 210" on the spot.
   - Pass: the collection is listed with this item checked.
2. Open Margins and open the scope picker.
   - Pass: the collection is listed above the single items. Choosing it shows only the Margins of items in it, and Export Sessions starts with only those sessions selected.
3. Delete the collection from the same sheet.
   - Pass: its items and their Margins are still there.

## J9 — Hear a friend's new Margins before carrying on

1. Listen to a podcast episode well past its start, save a Margin of your own, and pause. Get a co-op packet from a friend for the same episode, with one Margin from before the place you reached, and import it.
   - Pass: the item screen shows two choices, "Play" and "Skip to <friend>'s Margins · N min" (the friend's name when one named friend sent them, otherwise "the Margins"), when no new Margin sits behind the place the listener has reached (not started, or the Margin is ahead of the place). When one does, the two choices follow the place (#4125): "Hear <friend>'s Margins first · N min" and "Listen without them", or "Play from the start" when the place is the very end (99% up to, not including, 100%); J14 step 2 has the rows. The Margin is marked new in the Timeline. Each fact is on the screen once above the choices (#3855): one "From <friend>" (the sender line; the card's own line is dropped while the intro shows and there is one friend) and one "1 Margin · about 1 min" (no chip). Scripted for not started, with that count (`testItemScreenOffersTwoChoicesForAFriendsNewMargin`) and part way (`testHearAFriendsNewMarginThenCarryOnWhereYouWere`); no script for finished or at 99% (#4097).
2. Press "Play".
   - Pass: the episode plays at once, with no question first, and the friend's Margin plays in place when the episode reaches it. Until it does, the pinned card says "Next Margin in N min" (whole minutes, no clock; "in N sec" in the last 20 s) and "Plays by itself when you get there." (a Margin at the sender's own clock, from a packet whose episode length differs from the playing copy's by 10 s or more, says instead "Your copy is about 35 seconds shorter than <friend>'s, so Margins may be that far off.", or "longer", or "so Margins may not line up." past 20% of the length (#4175); with no length on either side or a smaller difference it keeps "Approximate position: ads can differ between copies."; the Test Desk checks both with a sharing-test-kit packet whose `durationMs` is changed by 33 s and one left as is), and its button says "Skip to just before <friend>" ("Skip to just before it" with no name); tapping it jumps to the lead-in and the button becomes "Skip to <friend> now". One button, never "item" or "review"; the card is as tall as its words, with no blank row. A Margin from before the place the listener is at is not skipped: the big button then reads "Hear <friend>'s Margins first" and plays it, with no question (owner, 2026-11-12, #4125; J14 step 2). "Skip to <friend>'s Margins" plays it. (Continue on the item's row in the Library still asks whether to hear the new Margin first.)
3. Back out, then choose "Skip to <friend>'s Margins" on the item screen (or "Hear new Margins first" on the Library row's question).
   - Pass: the episode jumps to about 20 s before the friend's Margin and plays on. The card is pinned at the top of the Now screen and says "Margin from <friend>" ("Shared Margin" when the packet names nobody), and never "1 of 1"; with two or more Margins it counts "1 of 2". A short two-note chime, then the friend's voice. For a Margin the friend wrote, the chime is followed by the iPhone's voice saying "<name> wrote:" and then the words, and the card says "Your phone's voice is reading <name>'s words." (never that the friend is speaking). The owner checks by ear that the lead-in sounds natural and that the reading does not pass for the friend's own voice. At the largest accessibility text size (AX5) the card stays on the screen, no taller than 75% of it, with every button tappable and the dock's play button still reachable; `J9HearNewMarginsJourneyUITests/testTheMarginCardFitsAtTheLargestTextSize` scripts that for the lead-in and the playing stage (#3597).
4. Let the voice finish.
   - Pass: the episode plays on from where the Margin ended, with no jump back (owner, 2026-11-06). The one exception is a Margin from before the place the listener had reached (step 1): when the review ends, the episode goes back to that place and carries on. The Margin is no longer marked new.
5. Repeat with three new Margins, one of them close to another. Use "Skip this Margin" (while a Margin plays, even when more follow; it ends the voice and the episode plays on), "Skip to just before <friend>" then "Skip to <friend> now" (between Margins, to move to the next one) and, at a lead-in, "Stop Margins" once each. While a Margin plays there is no Stop, only "Skip this Margin", "Start a minute earlier" and the pause control (the second not at AX3 and above; a can't-play listening keeps its quiet Stop Margins, because it has no lead-in to leave from, and has no "Start a minute earlier"). The title does not move between the Margins. Also press "Start a minute earlier" once inside a lead-in (between "Skip to <friend> now" and "Stop Margins") and once while a friend's voice plays (#4171).
   - Pass: close Margins play without an extra jump back. Stop pauses the episode where it is; if no Margin of the review has played yet, it goes back to where the listener was. Pause and Stop behave as they do for "Play this moment". "Start a minute earlier" moves the episode a minute further back than the lead-in it was in (from the voice, a minute before that Margin's own lead-in), the countdown grows by about a minute ("Margin from <friend> in 1:19"), the voice stops at once with no second voice over it, the same Margin plays again when the episode gets there, and the count ("2 of 3") stays. It is never on your own Margin, never far out between Margins (where "Skip to just before <friend>" shows), and not shown when the lead-in already starts at 0:00. A friend's Margin playing by itself (no review) offers it too, and the press starts a one-Margin lead-in of a minute; the episode plays on after it.
6. Back on the Now screen with the episode paused before the friend's Margins (#4447), with the item's own Margins and the friend's both ahead, press the Skim arrows either side of the chapter title, then open the Margins tab and tap the play button on a friend's row and on one of your own.
   - Pass: both Skim arrows are on the screen as soon as the Margins are, with no tap or play first, and the forward one is bright. Each press lands where its words say (the next Margin's lead-in, or the Margin itself when already inside it; a friend's Margin that is never read aloud is a stop too, step 8) and the pinned card names the Margin. Each Margins-tab play button jumps to 30 s before that Margin and plays it. A friend's Margin that is never read aloud (reading turned off by the sender or by you, no voice on this phone for its words, or no readable words) has a Go-to button in place of Play, with an arrow and "Go to this moment" for its label, and "Not read aloud" at the end of its detail line (#4934): its tap moves the episode to the Margin's own place, with no lead-in and no voice and no tone, and plays on; the pinned card on Now says "Margin from <friend> is here" with the Margin's words and a Dismiss, and goes when you Dismiss it, press Skim, scrub away or the playhead is 30 s past. A Margin that cannot play says why, in words, and never does nothing. Every Margins-tab play tap also leaves one `margin.tap` line (a Skim that lands on a friend's Margin leaves one too) in the Diagnostics export (`origin` own or shared; `outcome` started, waiting, refused or dropped; `reason` for the last three), so a tap that did nothing says why (#4447); check the line for each play tap. A Go-to tap leaves no `margin.tap` line. Report what each press did and where the playhead landed. Owner-found regression: build 37, 2026-11-17. Scripted for the case behind the listener (#4447): `testMarginsTabPlayReachesAFriendsMarginFromFarPast` (the friend row's Play, saved near 20:00, the friend's Margin at 5:00, "Listen without them") and `testSkimArrowsAreOnTheNowScreenAndGoBackToAFriendsMargin` (both arrows are drawn, backward is enabled and lands at the Margin). A third script covers a silent Margin's Go-to from the same position (#4934, `testMarginsTabGoesToASilentFriendMarginWithNoVoice`, which relaunches with `SPOKEN_MARGINS_UI_TEST_COOP_SILENT=1`; the episode lands at 5:00 and the card shows). None covers a Margin ahead of the listener or your own Margin's row. Skim stopping at a silent Margin is step 8.
7. The same on an article or PDF (#4447): import a friend's packet for an article in the Library, open the article, open the Margins tab and tap the play button on the friend's row.
   - Pass: the play button is enabled whenever the row shows a place, jumps the text to that passage and offers the friend's Margin there (the pinned card names it). A friend's Margin that is never read aloud has the Go-to button here too: it moves the text to the passage and reading carries on from there, with the Margin's words on the pinned card (#4934). A Margin with no place in this copy says why, in words, and never does nothing. With that friend's Margins switched off, the button is disabled for a Margin at a passage (and a tap by any other route says they are off). Before this the button was disabled for every Margin placed by its text, because it asked for a time in the item. Each play tap leaves one `margin.tap` line, as in step 6 (`shared/refused/margins_off` for a Margin whose friend is switched off).
8. Skim at a friend's Margin that is never read aloud (#4934): with the item screen's choice taken ("Listen without them"), the friend's Margin behind the listener (saved near 20:00, the Margin at 5:00) and again with the episode paused before it, press Skim backward and Skim forward.
   - Pass: a silent Margin is a Skim stop like a chapter. The press moves the episode to the Margin's own place, with no lead-in, no voice and no tone, and plays on (a paused episode starts playing), and the pinned card on Now says "Margin from <friend> is here" with the Margin's words and a Dismiss. The next press in the same direction goes on to the stop beyond it, or finds none, and never lands on the same silent Margin again, whether the seek landed a second early or the listener played a little on. A Margin the sender or you turned reading off for, or whose words no voice on this phone can read, behaves the same; turn reading back on and it is a voiced stop again, with its lead-in. The Skim press leaves one `skim.press` line with `outcome` `went_to_silent_margin`. Scripted for both directions (`testSkimGoesToASilentFriendMarginBothWays`; "never the same stop again" is checked by the app-hosted `testBackTwiceFromTheEndDoesNotRepeatTheSilentStop`, not by this script, which relaunches with `SPOKEN_MARGINS_UI_TEST_COOP_SILENT=1` and sits on probation). The article half stays with the Test Desk's run: there is no article co-op seed. That nothing is spoken is the owner's by ear.

## J10 — Everything local works with the product server unreachable

The offline check (#1842): no cloud is needed to listen, capture or export. Install a Debug build and launch it with the product server's host swapped for one that never resolves:

`xcrun simctl launch <udid> com.spokenmargins.native -SMServerHost offline.invalid`

Every server feature (server config, share links, Listening Maps, the bridge and source catalog, the guided tour) then fails as if the server were down, and the app sends the real server nothing. Release builds ignore the argument. Relaunch without it to go back to the real server.

1. Import an article and a PDF; play each with Kitten and with an iOS voice.
   - Pass: both play and the clock advances, with no wait on the network.
2. Record a spoken and a written Margin.
   - Pass: both show on the item.
3. Export a `.spokenmargins` packet and import it on a second simulator. While the Test Desk has only one simulator slot, reinstall the app on the same simulator and import it there.
   - Pass: the item and its Margins arrive, and each Margin opens at its passage.
4. While an item plays, open a share link: `xcrun simctl openurl <udid> 'https://spokenmargins.com/l/0123456789abcdef0123456789abcdef#AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'`. The app still recognises the real host and fetches the packet from the swapped one. Keep the `#` part: a link without its key is called cut off before the app asks the server, so it would never test the network. If Safari opens instead of the app, the universal link didn't route on this simulator: report that, and don't count it as a pass or a fail. (The app has no way to create a share link yet, only to open one.) Then play a podcast episode, which asks for its Listening Map.
   - Pass: the share link shows a sheet headed "You're offline." with Try Again and Close (#3801); closing it leaves the item as it was, the map is quietly absent, and playback keeps going.

The script `J10OfflineJourneyUITests` runs part of this with the host swapped: it plays a seeded article and an imported PDF with the iOS voice, records a spoken and a written Margin on the article, builds and verifies the packet up to the import review, and opens step 4's share link. Hosted simulators never route the universal link, so the script hands the same link over inside the app's own scheme, `spokenmargins://ui-test-share-link?url=<the link, percent-encoded>`, which only a Debug UI-test launch accepts (#1842). Importing an article yourself, Kitten, the second simulator and the Listening Map stay with this agent run, and a script pass never stands in for it.

## J11 — A new listener reaches a first Margin

The first minute (#2855, #2854). Start from a fresh install: delete the app from the simulator (not just a relaunch), install the candidate, and launch it. Write each step as what the listener wants; the buttons are only where they find it.

Measure while you go. Start a stopwatch at the first launch, and count every tap from that moment. Report, for each of the two finish lines below, the seconds and the taps, next to the previous candidate's numbers from the last J11 report (the Test Desk keeps them in its journey notes). A candidate that needs more taps than the previous one, or more than 6 to the first Margin, is a failure of this journey even if every step passes.

1. Open the app for the first time and pick something to hear: follow one show or a Substack from the drawer that opens, then tap Done.
   - Pass: the newest episode (or the Substack's latest post) of the first thing picked starts, without a visit to the Library. If the Terms screen comes first, it is one short screen with both buttons in view, and accepting or choosing the iOS voice starts the play.
   - Finish line 1: audio is playing. Record seconds and taps from launch. Whether it is audible is "owner to confirm".
2. Open the app for the first time again and tap Done without picking anything.
   - Pass: the Welcome sample plays.
3. While audio plays, add your first Margin.
   - Pass: exactly one prompt, "Tap to add a Margin", asks for it. The tour coach and the checklist strip are not on screen with it. Tapping it explains the microphone in a sentence, then iOS asks. Allow it (a test simulator always allows, per AGENTS.md): the recording starts, and saving it puts the Margin on the item. The prompt does not come back.
   - Finish line 2: the first Margin is saved. Record seconds and taps from launch. Microphone behaviour on a real phone is "owner to confirm".
4. Repeat step 3 from a fresh install, and answer "Don't Allow" to the microphone.
   - Pass: a written Margin opens at the same place, with a line saying the microphone is off.

The script `J11FirstMinuteJourneyUITests` runs steps 2 and 3 with stand-in microphone and speech services (`SPOKEN_MARGINS_UI_TEST_FIRST_RUN=1` wipes the defaults and the Library, then seeds nothing), asserts the Terms buttons are reachable, and attaches the seconds and taps. Picking a show or a Substack needs the network, so step 1, the real microphone prompt and the "Don't Allow" fallback stay with this agent run, and a script pass never stands in for them.

## J12 — The sharing loop, from the sender to a friend and back

The whole loop (#3222, part of #3216), with an eye on the human side: how many taps, how long each wait is, and where a first-time friend could get lost. It needs two installs (a second simulator), or a prepared packet in place of the friend ([sharing test kit](sharing-test-kit/README.md)). Count taps and time each wait with a stopwatch, and report both for every step.

1. The sender adds a podcast episode by searching for its name, and plays well into it.
   - Pass: the episode is in the Library and plays. Record taps from launch to the first audio.
2. The sender records two Margins, one after the other.
   - Pass: each saves on the item without leaving the playback screen, and the episode carries on. With a third Margin recorded, the sender taps the star at the right of two of the three rows in Nearby Margins (the Margins pane has the same star): each fills at once, its row reads "My Margin · Starred", the episode does not pause, and no sheet opens (#4173). Share then starts from the two stars, both included in the list. With nothing starred, Share starts with every Margin selected, as before.
3. The sender taps Share and sends the Margins to the friend.
   - Pass: the Share Margins list (#4647) shows every Margin in one column, each included card with all the words that go, and Share opens the system share sheet; "Preview what your friend gets" shows the file size. Record the packet size at this send, the seconds from Preview what your friend gets to the size showing, and the taps from the playback screen to the share sheet. The route is Share on the playback screen, then Share on the list (#1507): two taps, with no scrolling; more than two is a fail. From the item screen the route is Share in its header (or Share Margins in its options menu), then Share on the list (#4229): also two taps. Every Share of an item's Margins (the playback screen, the item screen and the Margins tab) holds your Margins from every listening pass of the item, not only the newest (#4688). With nothing of the listener's own to send, that Share shows the "Nothing to share yet" alert instead. On a Margin recorded seconds ago on a podcast (#3839), the card opens with a clock step, "Finding the exact moment for this Margin. Keep the episode playing a few more seconds." while the episode plays, or "Play the episode for about 12 seconds…" when it is paused or another item plays; the same step sits above Share link in the pinned bar, and both go on their own when the sample lands, with Share never blocked. A Margin recorded seconds ago usually has no words yet either: its card then starts with a words step, "Getting this Margin's words ready. It's added when they're ready.", the badge "Waiting for words", and the pinned line "Getting the words ready for your new Margin. A few seconds." (the only pinned line when both waits are on). When the words land, the card shows them with no step or badge and the sender stays where they are, unless the sender had typed their own words over the stand-in, which stay as typed (their other choices never hold the words back); a Margin shared before they land goes with its stand-in words. Record a capture of the card with the step showing, one with it gone, one with the words step showing then gone, and one of an older podcast Margin, which shows the quiet "find this Margin by its words" note and no step. Then each included card reads, top to bottom (#4647): the header row (Starred or Margin, the version, and the Included switch; a tap anywhere on it switches the Margin in or out), the steps, "Your words" (or "Your words, with changes") and all the words, the change summary, "Show what changed" or "Edit words", the cleanup line, "Your friend gets" as a menu with its caption, one Listen button named for the version (none with Words only), the run-up row where #4171 adds it, and "More for this Margin". With cleanup on, the words show cleaned at once and only "Listen without ums" and the preview row wait for the voices; Share tapped while they are made shows "Getting N Margins ready…" with "Stop sharing", then goes on by itself. Count scroll reversals from opening the list to the share sheet. On an item whose Listening Map has model-written scene text and whose source isn't marked public (a PDF from Files after Prepare Listening Map), the list (Review on a reply sheet) shows "Listening Map titles and summaries for N scenes won't be sent, because this source isn't confirmed as freely available online." above the Margins, and Preview's What is included says "Listening Map included, without titles and summaries for N scenes"; on the tour's podcast neither shows (#4635).
4. The friend (second simulator) opens the packet. They have not added the episode beforehand.
   - Pass: the episode appears in their Library and the Margins are listed. The Margins tab and the Now tab show the Margins without leaving the screen or restarting (#3263). Record the seconds from opening the packet to the Margins being listed.
5. The friend hears the Margins in both modes (the big button, and "Hear new Margins first").
   - Pass: a short two-note chime, then the sender's voice, at the right place in the episode. A Margin the sender wrote is read aloud by the iPhone's voice, introduced as "<name> wrote:", after the same chime; if the reading is still being made when the listener taps, a short "getting ready" line shows and the card stays up. It then plays, or a line says it could not be read aloud (a short note takes a few seconds; a stuck speech service takes up to about half a minute, or more for a very long note, and can take longer when earlier readings are also stuck). A note with nothing the voice can read (only emoji or only a link) is not offered at all. A note that no installed voice can read whole (a script with no installed voice, or Urdu, Persian or Kazakh letters the Arabic voice skips) is offered, then says "This Margin can't be read aloud on this iPhone.", stays new and plays nothing. Record the seconds from import to the first audio and the taps it took. The owner checks by ear that the voice and the place match.
6. The friend replies to a Margin, in voice once and in writing once, then sends the replies back.
   - Pass: each reply is saved at that moment of the episode. Record the packet size at this send. The route is Share on the playback screen, then Share link (or Share in a build without links): two taps, with no scrolling, as step 3 (#3792). The sheet is headed "Share replies with <friend>" (or "Share your Margins with <friend>" when none of the new Margins is linked as a reply) and opens on its review with one row for each Margin going and no editor open until a row is tapped; the cleanup question does not appear; the first link shows "Share as a link?" once. Check it for an answer made within 20 seconds of the friend's Margin and for one made later.
7. The sender opens the replies packet.
   - Pass: the item says who the replies are from and how many ("Replies from <friend>", "2 replies to your Margins"), with no line explaining what a Margin is (#3889). In "Skip to <friend>'s replies" each reply plays right after the Margin it answers (#3257), the written one read aloud as "<name> wrote:" and the words. When the episode plays on instead, a reply plays at its own place without the Margin it answers. The sender can reply again.

The script `J12SharingLoopJourneyUITests` runs step 2, step 3 up to the package details (not the system share sheet; it counts the taps and fails above two), and, with the friend's packet as a fixture (`SPOKEN_MARGINS_UI_TEST_COOP`, as J9), steps 4 and 5's offer, the in-place play and the Margins tab. It attaches the taps and seconds per step and the packet size. A test, `testFriendArrivalToFirstMarginSeconds` (#3788), opens the friend's item from the Library, taps "Skip to …" as soon as it shows and attaches the seconds from the item screen's first frame to the friend's Margin playing (about 10 s is the goal; it is reported, never asserted); the episode is already in the Library there, so the Files route with the episode absent stays with the agent run. A second test, `testAnAnswerOpensTheReplySheetOnItsReceipt` (#3792), records one Margin on the friend's item and checks step 6's sheet: the reply heading, one row, no editor, no navigator, Share reachable at one tap past the player's Share. The fixture imports the friend's Margin at launch, so the script cannot catch #3263 (Margins missing until a restart); step 4 of the agent run does. Adding the episode by search needs the network, the system share sheet and the second install are outside what a script can drive, and replying then importing back needs both, so step 1's search, step 3's share sheet, and steps 6 and 7 stay with the agent run. A script pass never stands in for them, and audible content stays with the owner. Two more methods script step 3's item-screen route (#4688): `testTheItemScreenSharesYourMarginsInTwoTaps` (Share in the header, the review, at most two taps, then ⋯ with Share Margins above Export, and Export opening the Export screen) and `testTheItemScreenSaysWhyWithOnlyAFriendsMargins` (the “Nothing to share yet” alert, and the item screen after OK).

## J13 — Following lists friends and shows together, newest first

Following puts every friend who sent Margins and every followed show in one list, ordered by what changed most recently (#3343, part of #3216). A friend sorts by the later of their newest Margin's recorded time and when the listener received the packet; a show sorts by its newest episode that no rule sets aside (with no rule on, simply its newest episode; #4046). Quiet shows stay in their own section below.

1. Use a Library with at least five friends and three shows. Some friends should be newer than some shows and older than others. Include one show with no episodes and one friend whose packet was recorded long ago but opened today.
2. Open Following. Record the rows top to bottom with each row's name and its second line ("3 Margins on 1 episode" for a friend, the new-episode count for a show).
   - Pass: friends and shows are mixed, newest first. The friend whose old packet was opened today sits with today's rows, not a month down. The show with no episodes is last among the shows. The Quiet section is below the list.
3. Tap a friend who sent Margins on one item.
   - Pass: that item opens directly.
4. Go back and tap a friend who sent Margins on several items.
   - Pass: an items screen opens, newest first. Each item shows its title, the Library's kind and source line, progress or played state, and "N Margins" with how many are new, in words. Tapping an item opens it.
5. Import a packet from a friend who gave no name (a nameless file, or the web page's "Your friend"), then open Following.
   - Pass: an "A friend" row sits first with "N new" tag on its initial, and tapping it opens the item (or the items screen when there are several). A friend who does have a name keeps their own row.
6. With an empty Library, open Following.
   - Pass: "You're not following anything yet" shows. With the offline profile, "Showing the last local snapshot" shows above the list.

Check the row text against #3291 ("Cole", "3 Margins on 1 episode") and that VoiceOver reads each friend row as "<name>, <summary>, N new" (the last part only when something is new). A show's "N new" sits on its picture (a friend's on the initial), "99+ new" above 99, and VoiceOver still says the exact count. A show's date and "In Library" each sit on whole lines, never broken inside a word. At the largest accessibility size the row stacks (picture, Play and › on top, text at full width below), no title breaks inside a word, and the last row scrolls fully clear of the mini player. No step may rely on red or green alone. The ordering rules have host tests (`FollowingFeedTests`); this journey covers what they cannot: the built list, the quiet section and the items screen.

## J14 — Coming back to a friend's Margins after hearing the episode

A listener with history on an episode receives a friend's Margins (#4100, part of the flow audit; the owner met this on his phone on 2026-11-11, #4097 and #4098). No other journey starts from a listener who has already finished the episode. Each step says where it starts, in one line. Run each row on its own, from a Library that has the episode with the history named.

**Rows** (the listener's history on the episode):
- **Row 1, heard to the end:** a saved place at 99% (about 24:50 of 25:00). Continue resumes it at its end. By hand: play the episode, scrub to about 24:50 and pause.
- **Row 2, marked complete:** marked complete by hand, with no saved place. By hand: "Mark complete" on a fresh episode.
- **Row 3, not started:** no saved place, not marked.
- **Row 4, finished by listening:** the session reached 100%. Continue starts again from 0 ("Replay"). By hand: let an episode play to its end.

**Packet** is the friend's first packet unless a step says it is a reply to the listener's own Margin. **Entry point** is where the listener starts.

1. Start from a row above, with the friend's packet not yet imported. Packet: first packet, one Margin five minutes in, which is behind the place in rows 1 and 4 and ahead of it in rows 2 and 3. Import it. Entry point: the packet opened from Files or a share.
   - Pass: the episode is in the Library, and its row shows the friend's Margin as new. The Library's state filter hides an episode whose history is "complete", so use "All" to see it; note what the default view shows.
2. Open the episode's screen. Entry point: the Library row, then the item screen.
   - Pass, rows 2 and 3 (the Margin is ahead of the place or there is none): two choices, "Play" and "Skip to <friend>'s Margins · N min". The Margin is marked new in the Timeline. Pass, row 1 (the Margin is behind the place, which is at the end): the choices are "Hear <friend>'s Margins first · N min" and "Play from the start" (#4125). The big button plays the Margin with no question and then goes back to the saved place (owner, 2026-11-12: "If I haven't heard her margin before and I just imported her margins ... play should do that"); "Play from the start" begins at 0, with the Margin ahead and new. At a mid-way place with the Margin behind it the second choice reads "Listen without them" and resumes the place. Row 4 (finished at 100%) is "Replay" with the Margin ahead of 0. Step 4 is the Library row's Continue, which asks (#4097).
3. Choose "Skip to <friend>'s Margins".
   - Pass: the episode goes to about 20 s before the Margin (about 4:40) and the pinned card says "Margin from <friend>" with a lead-in, then the Margin plays. The episode does not start at its end, and the clock is nowhere near the listener's old place.
4. Back out, and press Continue on the episode's Library row. Entry point: Library row Continue. Row 1 only, where Continue would otherwise resume at the end.
   - Pass: Continue asks "hear the new Margins first?" before anything plays (#4097, #474); it never lands at the end with the friend's Margins skipped. The question's second choice follows the place as the item screen's does (#4125): "Play from the start" when the place is 99% up to, not including, 100% (row 1), "Listen without them" at a mid-way place. Row 4 (Replay) and rows 2 and 3 (Continue plays from the start) ask nothing, and the Margin plays in place when the episode reaches it.
5. Leave playback to the Library.
   - Pass: the episode can be found again from the Library with the filter on "All", with its place or its completed mark as it was.
   - **Fails today, issue #3794:** in the Library's default view an episode that is complete (rows 1, 2 and 4: marked complete, or listened to 99% or more) is hidden ("Completed hidden"), and nothing there says where the friend's Margins went. Record what the default view shows after leaving playback, and do not count the default view as a pass until the issue closes.
6. Reply case: Start from row 1 or 4 after the listener has recorded a Margin of their own at 12:00. Packet: the friend's reply to that Margin. Import it. Entry point: the packet opened from Files or a share, then the Margins tab, scope Everything, filter Shared.
   - Pass: each reply is listed under its episode, and an item heading opens the episode's screen (step 2), where "Skip to <friend>'s replies" plays the first reply. "Play" on that screen resumes the listener's own place.
   - Also pass (#4098, #4105): the Shared list groups by item, newest arrival first, with the caption "Newest arrivals first · Margins in play order"; each row reads "Name · time" and tapping one plays that moment (or opens its details when it has no place); on Mine, while friend Margins are unheard, the top row "N new Margins from <friend> · <item>" opens the item, and the Shared chip shows "N new". The owner's words, 2026-11-11: "no way to open up the item I was just sent by my phone that I want to listen to". Record screenshots of Mine (with the row) and Shared.
7. After step 1's import, from rows 1, 2 and 4 (an episode that counts as finished), with a Library that has newer items. Entry point: the Library tab with its default view and sort (Unfinished, Recently Added), then Following, then the Margins tab (#4101).
   - Pass: the default Library view lists the episode first, below the Continue row when another item is loaded, with the friend's Margins marked new. Following lists the friend first with "N new". The Margins tab shows the "N new Margins from <friend>" row on Mine and the episode's group first on Shared. Hear the Margins, and the episode leaves the default view again. Host test: `FriendArrivalDoorsTests` (SessionKit); the screens themselves stay with the agent run.

The script `J14ComeBackToAFriendsMarginsJourneyUITests` runs rows 1 (from the Library row, from the item screen's big button with a check of both button labels, and from the item screen's big button asking nothing, #4125), 2 and 3, one test each, each with its own history from the seed hooks `SPOKEN_MARGINS_UI_TEST_PODCAST_PLACE` (a saved place, in seconds) and `SPOKEN_MARGINS_UI_TEST_PODCAST_COMPLETED=1` (marked complete by hand). Both apply only to the launch that seeds the podcast; the relaunch with `KEEP_LIBRARY=1` and `COOP=1` imports the friend's Margin the way J9 does, so the import in step 1 and the packet's own file are not covered. The script checks steps 2, 3 and 5 for rows 1 to 3 and step 4 for row 1. It sets the Library to "All" because the default view hides a completed episode (#3794, step 5), so it proves the episode is findable once the filter allows it, and nothing about the default view; its step 5 asserts only that the Library row exists. Row 4 is seeded by `PODCAST_PLACE=1500` (the end of the episode, a finished session); the script does not run it yet, because no run has shown what its item screen offers. Step 1's import from Files, step 6 and the default Library view (step 5) stay with the agent run. A script pass never stands in for them, and audible content stays with the owner.

## J15 — Import a meeting transcript

A listener adds a transcript file from a meeting app (#2997, Design plan PR 4). Zoom gives a `.vtt` or a `.txt`, Teams a `.vtt` or a `.docx`, Meet and Webex a `.vtt` or `.srt`, Otter a `.txt`. The file becomes its own Library item, read aloud with the speaker named when the speaker changes, and it takes Margins. Open In and AirDrop (PR 5a) add steps 13 to 16; the share sheet (PR 5b) adds steps 17 to 21.

**Fixtures:** `WRITE_TRANSCRIPT_FIXTURES=1 swift test --filter TranscriptFixtureFilesTests` (in `Packages/SessionKit`) writes the eight fixtures, a Teams-style `.docx`, and a short essay as `.txt` and `.docx` to `artifacts/transcript-fixtures/`. Copy them into the simulator's Files (On My iPhone).

1. Library tab, **+**, **Import from Files**. The Add sheet's tile reads "A document, book, transcript, audiobook or Margins packet". Pick `teams.vtt`.
   - Pass: `.vtt`, `.srt` and `.docx` are selectable in the picker (greyed out before). The sheet closes. A banner says "Added <title> to Library." with **Play now** (without Play now, and "without changing Now Playing", when something is loaded). The new row reads "about N min · Transcript" with a speech-bubble icon, at the top of Recently Added.
2. Open the row.
   - Pass: the screen is titled "Transcript". Under the title a meeting line reads, for example, "Meeting on Wed 4 Mar, 10:00 · under 1 min · Alice Example and Ben Sample" (the date form depends on the file: time of day only, or no start, for a file without a date).
3. **Start listening**.
   - Pass: Now Playing reads "Alice Example: Welcome everyone…", then "Ben Sample: …" when the speaker changes. The clock advances. No timestamp is spoken.
4. Add a written Margin (the pencil), then open the Margins tab.
   - Pass: the Margin's place line shows the meeting clock where a text item shows "paragraph N", for example "00:06 · Today".
5. Import `teams.vtt` again.
   - Pass: the same banner, no second row, the row back at the top of Recently Added. The Margin from step 4 is still on the item.
6. Import `generic.srt`, a Teams-style `.docx`, and the Zoom captions `.txt`, one at a time.
   - Pass: each is a Transcript row (the `.srt` and `.vtt` of one meeting are one item, because the id comes from the words).
7. Import the essay `.txt`.
   - Pass: a Text row, exactly as before this feature. The banner is today's.
8. Import the essay `.docx`.
   - Pass: a Text row, as for the essay `.txt` (#4594: a Word file that isn't a transcript is a document).
9. Pick `teams.vtt` and `notes.md` together.
   - Pass: one banner, "Imported 2 files." When one of them can't be added, it says "Imported 1 file. 1 couldn't be added: <name>."
10. Share the Margins of the transcript item from its Margins tab.
    - Pass: the review does not offer to include the whole text (a transcript is never embedded); it shows the line it shows for a text item the friend must supply.
11. Quick Folder: with the Zoom captions `.txt` in the folder, tap **Add and open** on it.
    - Pass: the transcript's item screen opens, and the file leaves the folder list.
12. Run J1, J3 and J7 step 2 on the transcript item.
    - Pass: they pass as for any text item.
13. In Files (On My iPhone), touch and hold `teams.vtt`, tap **Share** and pick Spoken Margins in the list of apps (or tap the file, then **Share**, then Spoken Margins; **Open In** reads the same on an iPad). Do it with the Library open, then again with something loaded in Now Playing.
    - Pass: the app comes forward on the screen it was on, with no navigation: a live session or a recording in progress is not disturbed. A banner says "Added <title> to Library." (with **Play now** only when nothing is loaded; "without changing Now Playing" when something is). One Transcript row, at the top of Recently Added.
14. Open the Zoom captions `.txt` and the essay `.txt` the same way, then `notes.md`.
    - Pass: the Zoom file is a Transcript row; the essay and `notes.md` are Text rows with today's banner ("Imported 1 source file."). No screen changes.
15. Open a `.csv` (any file with another plain-text type) with Spoken Margins.
    - Pass: nothing is added; a banner says "Spoken Margins can't add “<name>”. It adds meeting transcripts (.vtt, .srt, .docx, .txt) and text or Markdown files."
    - Also select two transcripts in Files at once and share them to Spoken Margins: both are added, one after the other, and neither is refused with "Another source is already importing."
16. Open the same `.vtt` from a file in iCloud Drive that is not downloaded.
    - Pass: it downloads and is added, or the banner says "“<name>” couldn't be read. If it's in iCloud Drive, open it in Files so it downloads, then try again." Nothing is left half-added.
17. In Files (On My iPhone), touch and hold `teams.vtt`, tap **Share**, and in the list of actions below the row of apps tap **Spoken Margins** (the share extension, with the waveform icon; not an app in the top row, which is Open In, steps 13 to 16). Do it again with `generic.srt` and a Teams-style `.docx`.
    - Pass: the card says "Sent <name without its extension> to Spoken Margins." and closes by itself (it stays until Done with VoiceOver on). Nothing is parsed in the extension. Open Spoken Margins: a banner says "Added <title> to Library." (with **Play now** when nothing is loaded), the screen is the one it was on, and there is one Transcript row at the top of Recently Added. With several files shared one after another before opening the app, one banner says "Added N to Library." (Selecting two files and sharing them at once copies only the first, as every other share does.)
18. Share the Zoom captions `.txt`, then the essay `.txt`, the same way.
    - Pass: the card says "Sent <name> to Spoken Margins." for both. In the app the Zoom file is a Transcript row; the essay is a Text row with today's banner. No screen changes.
19. Share the essay `.docx` the same way.
    - Pass: the card says "Sent essay to Spoken Margins." In the app nothing is added and a banner says "“essay.docx” isn't a meeting transcript. To add it as a document, use + › Import from Files." It is not offered again at the next foreground.
20. Share a `.vtt` larger than 10 MB (`python3 -c "print('WEBVTT\n' + ('00:00:01.000 --> 00:00:02.000\nA: x\n\n' * 400000))" > artifacts/big.vtt`, about 14 MB).
    - Pass: the card says "“big.vtt” is larger than 10 MB, so nothing was added." with **Done**. Opening the app adds nothing.
21. Share `teams.vtt`, then force-quit Spoken Margins (swipe it away in the app switcher) before opening it. Open it, wait, then send it to the background and open it again.
    - Pass: one Transcript row. The banner appears once. The second foreground adds nothing.

Not testable in a simulator: AirDrop from a Mac and a real iCloud download (steps 13 to 16). The owner's check is in the issue (C8 in `docs/design/live-sessions/SITUATIONS.md`). Also phone-only: that Spoken Margins is offered in the Share action list for a real `.vtt` and `.srt` from Files (the extension's activation rule matches `public.text`, `public.url` and Word).

Airplane Mode changes nothing (J10): the whole flow is local. The script for this journey is not written: scripts follow breaks found on the phone.

## J16 — Move a misfiled Margin from a live session to an item

A listener made Margins in a live session (a quick session from the Watch or the Action button, or a named one) that belong on a Library item (#4233, Design 7a). Move to an Item puts them on the item: at the place the item was playing when each was made, when that place was saved, and otherwise on the item without a place. The move can be undone from its banner.

**Starting state:** a podcast with a known length that has been played (J1), and a quick live session holding three Margins: one spoken while that podcast played, one spoken with nothing playing, and one Mark. A written Margin may stand in for a spoken one.

1. Open the live session, then its Margins pane.
   - Pass: the pane's header has **Move…** (`liveSession.margins.move.button`). Each Margin row offers the VoiceOver action "Move to an Item".
2. Tap **Move…**.
   - Pass: the "Move to an Item" sheet reads "Moving 2 Margins" (the Mark is not counted), with **Choose…** beside it. Under "Playing when you made it" the podcast reads "Was playing then"; other started items are under "Recently played". The search field reads "Search your Library".
3. Tap **Choose…**.
   - Pass: "Choose Margins" lists all three in the pane's order. The two that can move show a filled circle and VoiceOver reads them as Selected. The Mark is dimmed with "A Mark has no words or recording to move." and can't be ticked. Untick both: **Done** dims. Tick both again and tap **Done**.
4. Type part of the podcast's title in the search, in another case or without its accents.
   - Pass: the podcast is still listed. Type a word no title has: "No started item matches “<word>”."
5. Clear the search and tap the podcast.
   - Pass: the dialog asks "Move 2 Margins to “<title>”?" and says 1 will sit where it was playing and 1 had no playback place saved. The button reads "Move 2 Margins".
6. Tap **Move 2 Margins**.
   - Pass: the sheet closes. A banner says "Moved 2 Margins to “<title>”." with **Undo**. The live session now shows only the Mark.
7. Open the podcast's Margins tab and its Timeline.
   - Pass: the placed Margin sits at the time it was made (not at the podcast's resume point) and plays from there. The other reads "No place" and sorts after every placed entry. Neither is listed twice. The spoken Margin that had no words gains them once transcription finishes.
8. Back in the live session, tap **Undo** on the banner while it shows (or repeat steps 2 to 6 and then Undo).
   - Pass: "Margins put back." Both are in the live session again, with any words found meanwhile. The podcast no longer lists them.
9. Move one Margin from its own sheet: open a spoken Margin in the pane, tap **Move to an Item…** (`marginDetail.move.button`).
   - Pass: the sheet reads "Moving this Margin", with no **Choose…**; the back button returns to the Margin.
10. In a quick session that was never renamed, move every Margin it has (no Mark).
    - Pass: the session closes after the move and is gone from the list of sessions. Undo brings it back with its Margins.
11. Move a Margin, then star or edit it on the item, then tap Undo.
    - Pass: nothing changes; the banner says "Couldn't put the Margins back. They've changed on “<title>”."
12. On the finish card of a live session with Margins, tap **Move Margins to an Item…** (`liveSession.finish.move.button`).
    - Pass: the same sheet, with a **Cancel** button. With no Margins left, Line Up and Save as Notes are dimmed.

Not testable in a simulator: a Margin spoken on the Watch while the phone played, and a move interrupted by force-quitting the app (the next launch removes the moved Margins from the session before the Watch inbox is filed). The owner's check is on the issue.

The script for this journey is not written: scripts follow breaks found on the phone.

## Writing scripted journeys

The Test Desk keeps this guide. Threads writing a first pass follow it, and the desk corrects it when a script teaches it something.

- **One script per journey.** Name the class after the journey (for example `J3RecordAndRejoinJourneyUITests`) and follow the journey's steps in order, one `XCTContext.runActivity` per step, so a failure names the step.
- **Find controls by identifier.** Use the app's `accessibilityIdentifier`s (`home.screen`, `playback.screen`, `playback.play.button`, and so on, dot-separated with the area first), never visible text, which changes with copy edits. If a control has no identifier, add one in the same PR.
- **Wait, don't sleep.** Use `waitForExistence(timeout:)` or an `XCTNSPredicateExpectation` on the state you need, with a timeout of a few seconds and a message that says what didn't appear. No fixed `sleep` except to prove that something does *not* change, such as a paused clock.
- **Starting state.** The hooks exist only in Debug builds; a Release build ignores `--ui-testing` (#517). A script launched with `--ui-testing` resets the app's library and seeds its own, so the desk runs scripts before building the journey library. Seed only through the `SPOKEN_MARGINS_UI_TEST_*` hooks, which `UITestingLaunchSeed` in SessionKit lists: `SOURCE_TEXT` for an article, `PODCAST=1` for a downloaded 25-minute episode, `PDF=1` for a generated PDF imported through the Files import, `RECORDING=1` for a recorder that saves a real tone file and a fixed transcript, `KEEP_LIBRARY=1` on a relaunch that must keep what the first launch left, and `COOP=1` on that relaunch to import one new Margin from a friend ("Sam", five minutes in) onto the seeded podcast, `PODCAST_PLACE=<seconds>` and `PODCAST_COMPLETED=1` beside `PODCAST=1` for a listener with history on the episode, a saved place or marked complete by hand (J14), and `FIRST_RUN=1` for a fresh install that seeds nothing: the app's defaults and the Library are wiped, and the first-run flow (Welcome sample, drawer, Terms, first Margin prompt) runs as shipped instead of being kept out of the way (J11).
- **What to assert.** What a listener could see: the screen, the item or Margin that is playing, a clock that advances or holds, a control that is there and enabled. Not audio, not exact times or percentages, not layout pixels, and not anything that "looks wrong" but isn't a state; those stay with the agent run and the owner.
- **Keep it short.** A script should finish in a few minutes. A long soak test is not a journey script.
