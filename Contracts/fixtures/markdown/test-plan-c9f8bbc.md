# Phone build `c9f8bbc`: what to try

Built 2026-10-12 11:42 from next at `c9f8bbc`. Settings > Version ends with `c9f8bbc`.

Changes since build `887c560`.

Checks before this build: host tests passed, app builds passed.

Latest integration run for this commit: PASS (integration-c9f8bbc, 48 of 48 journeys).

31 pull requests merged; 9 change something you see or hear.

## Try these (about ten minutes)

1. **Settings: Share Diagnostics as a file (#903)** (found on your phone)
   - Check: Open Settings and scroll to the bottom. Tap **Share Diagnostics**.
     The iOS share sheet opens with a file called `SpokenMargins-diagnostics.json`.
     Cancel the sheet. Nothing should be sent anywhere.
   - Links: [PR #1103](https://github.com/uncomposed/spoken-margins-native/pull/1103), [issue #903](https://github.com/uncomposed/spoken-margins-native/issues/903)

2. **Pause and play carry on from where you stopped (#585)** (found on your phone)
   - Check: Play any article for a minute. Pause it. Lock the phone for thirty seconds.
     Unlock and tap play.
     Speech starts within a few seconds, at or just before where you paused.
   - Links: [PR #1388](https://github.com/uncomposed/spoken-margins-native/pull/1388), [issue #585](https://github.com/uncomposed/spoken-margins-native/issues/585)

3. **Following: Top sort removed (#1440)**
   - Check: Open Following. Tap the sort control.
     There is no **Top** option; Newest and Oldest remain.
   - Links: [PR #1441](https://github.com/uncomposed/spoken-margins-native/pull/1441), [issue #1440](https://github.com/uncomposed/spoken-margins-native/issues/1440)

4. **Margin recorded in the background keeps its place (#180)**
   - Check: Play the item from check 2. Record a Margin and tap **Save & resume**.
     Swipe home at once and open another app.
     Narration starts again within a few seconds without you coming back.
   - Links: [PR #1352](https://github.com/uncomposed/spoken-margins-native/pull/1352), [issue #180](https://github.com/uncomposed/spoken-margins-native/issues/180)

## Also waiting on your check

- James keeps his voice through numbers (found on your phone) ([issue #708](https://github.com/uncomposed/spoken-margins-native/issues/708), [PR #809](https://github.com/uncomposed/spoken-margins-native/pull/809))
- Sharing Margins on a streamed podcast works ([issue #744](https://github.com/uncomposed/spoken-margins-native/issues/744), [PR #930](https://github.com/uncomposed/spoken-margins-native/pull/930)): needs [#538](https://github.com/uncomposed/spoken-margins-native/issues/538) on your phone first
- A half-read article picks up where you left off ([issue #854](https://github.com/uncomposed/spoken-margins-native/issues/854), [PR #907](https://github.com/uncomposed/spoken-margins-native/pull/907))

## Also changed (not in the ten minutes)

- Library: sort menu remembers its choice ([#1301](https://github.com/uncomposed/spoken-margins-native/pull/1301))
- Now Playing: the chapter list scrolls to the current chapter ([#1329](https://github.com/uncomposed/spoken-margins-native/pull/1329))

## Also changed (no phone check written)

You don't need to test these. If one seems off while you use the app, open a `found-on-phone` issue.

- Voice: the speech cache is cleared on a version change ([#1411](https://github.com/uncomposed/spoken-margins-native/pull/1411))
- Library: the empty state links to the welcome sample ([#1415](https://github.com/uncomposed/spoken-margins-native/pull/1415))

Behind the scenes: 22 more pull requests changed only tests, scripts, docs or the test lane.

## If something is wrong

Open an issue labelled `found-on-phone` and name this build: commit `c9f8bbc`.
