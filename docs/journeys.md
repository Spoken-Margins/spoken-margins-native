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

## J1 — Listen to an article

1. Add a web article, by pasting a URL or sharing from Safari.
2. Start listening.
   - Pass: speech starts within a few seconds and the position advances.
3. Pause, lock the phone, then resume from the Lock Screen (owner step).
   - Pass: it resumes from the same sentence.
4. Read the article's text from More, step to another chapter and back without leaving the reader (#1579).
   - Pass: the chapter title changes and returns, a way back to the playing chapter shows while away, and playback is unchanged.

## J2 — Podcast playback survives relaunch

1. Add a podcast episode and let it download.
2. Play it, then scrub to about 20:00.
   - Pass: audio continues from 20:00.
3. Pause, force-quit the app, and reopen it.
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
   - Pass: the episode appears in their Library automatically, and the shared Margins are listed with a placement status (placed, or needs confirming).
3. The recipient plays a placed Margin.
   - Pass: a short two-note chime, then the sender's voice plays, labeled with the sender's name, and the recipient's episode is at the Margin's moment. The owner checks by ear that the podcast audio matches what the Margin is about.
4. The recipient plays an unplaced Margin.
   - Pass: the same chime, then the voice, and the app does not pretend to know the position. This holds when the Margin is tapped in the Timeline too (#932). A muted layer has no chime.
5. Import the same packet again.
   - Pass: no duplicate Margins and no duplicate episode.

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

## J8 — Collections

1. Long-press a Library item, choose Add to Collection, and make a collection such as "HIST 210" on the spot.
   - Pass: the collection is listed with this item checked.
2. Open Margins and open the scope picker.
   - Pass: the collection is listed above the single items. Choosing it shows only the Margins of items in it, and Export Sessions starts with only those sessions selected.
3. Delete the collection from the same sheet.
   - Pass: its items and their Margins are still there.

## J9 — Hear a friend's new Margins before carrying on

1. Listen to a podcast episode well past its start, save a Margin of your own, and pause. Get a co-op packet from a friend for the same episode, with one Margin from before the place you reached, and import it.
   - Pass: the item shows "Review new Margins (1)", and the Margin is marked new in the Timeline.
2. Press Continue on the item (or on its row in the Library).
   - Pass: the app asks whether to hear the new Margin first, before anything plays.
3. Choose "Hear new Margins first".
   - Pass: the episode jumps to about 10 s before the friend's Margin and plays on. The card says "Reviewing new Margins · 1 of 1" with the friend's name. A short two-note chime, then the friend's voice. The owner checks by ear that the lead-in sounds natural.
4. Let the voice finish.
   - Pass: the episode goes back to where it was paused and carries on. The Margin is no longer marked new.
5. Repeat with three new Margins, one of them close to another. Use "Skip to the next Margin", "Play it now" and "Stop review" once each.
   - Pass: close Margins play without an extra jump back. Stop leaves the episode paused where it was. Pause and Stop behave as they do for "Play this moment".

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
4. While an item plays, open a share link: `xcrun simctl openurl <udid> 'https://spokenmargins.proximitytoprogress.com/l/0123456789abcdef0123456789abcdef#AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'`. The app still recognises the real host and fetches the packet from the swapped one. Keep the `#` part: a link without its key fails as damaged before the app asks the server, so it would never test the network. If Safari opens instead of the app, the universal link didn't route on this simulator: report that, and don't count it as a pass or a fail. (The app has no way to create a share link yet, only to open one.) Then play a podcast episode, which asks for its Listening Map.
   - Pass: the share link shows an error, the map is quietly absent, and playback keeps going.

The script `J10OfflineJourneyUITests` runs part of this with the host swapped: it plays a seeded article and an imported PDF with the iOS voice, records a spoken and a written Margin on the article, builds and verifies the packet up to the import review, and opens step 4's share link. Importing an article yourself, Kitten, the second simulator and the Listening Map stay with this agent run, and a script pass never stands in for it.

## Writing scripted journeys

The Test Desk keeps this guide. Threads writing a first pass follow it, and the desk corrects it when a script teaches it something.

- **One script per journey.** Name the class after the journey (for example `J3RecordAndRejoinJourneyUITests`) and follow the journey's steps in order, one `XCTContext.runActivity` per step, so a failure names the step.
- **Find controls by identifier.** Use the app's `accessibilityIdentifier`s (`home.screen`, `playback.screen`, `playback.play.button`, and so on, dot-separated with the area first), never visible text, which changes with copy edits. If a control has no identifier, add one in the same PR.
- **Wait, don't sleep.** Use `waitForExistence(timeout:)` or an `XCTNSPredicateExpectation` on the state you need, with a timeout of a few seconds and a message that says what didn't appear. No fixed `sleep` except to prove that something does *not* change, such as a paused clock.
- **Starting state.** The hooks exist only in Debug builds; a Release build ignores `--ui-testing` (#517). A script launched with `--ui-testing` resets the app's library and seeds its own, so the desk runs scripts before building the journey library. Seed only through the `SPOKEN_MARGINS_UI_TEST_*` hooks, which `UITestingLaunchSeed` in SessionKit lists: `SOURCE_TEXT` for an article, `PODCAST=1` for a downloaded 25-minute episode, `PDF=1` for a generated PDF imported through the Files import, `RECORDING=1` for a recorder that saves a real tone file and a fixed transcript, `KEEP_LIBRARY=1` on a relaunch that must keep what the first launch left, and `COOP=1` on that relaunch to import one new Margin from a friend ("Sam", five minutes in) onto the seeded podcast.
- **What to assert.** What a listener could see: the screen, the item or Margin that is playing, a clock that advances or holds, a control that is there and enabled. Not audio, not exact times or percentages, not layout pixels, and not anything that "looks wrong" but isn't a state; those stay with the agent run and the owner.
- **Keep it short.** A script should finish in a few minutes. A long soak test is not a journey script.
