# Sharing test kit: one pass over the sharing failure modes

About twenty minutes, on your phone, one time through. It uses four prepared packets made from public content, so you don't need a friend or the original setup. It is for issue #848.

Short on time? Do parts 1 to 5 and part 10 of step 1, then steps 2 to 5, and stop. Skip parts 6 to 9 of step 1, part 5 of step 2, and steps 6 and 7. That is about ten minutes. It leaves the streamed share (#536) and the article for another day.

Each step says what you should see. When a step works, say "works" for that step number in the project thread. When it doesn't, say what you saw or heard, and attach a screenshot if you can. Claude updates the issues. Only you mark anything validated.

## What is in the kit

Four files. The plan they came with has them attached.

| File | Sender label | What it is |
| --- | --- | --- |
| `kit-1-episode-a.spokenmargins` | Ada (synthetic test) | 4 Margins on episode A, an episode you add first |
| `kit-2-episode-b.spokenmargins` | Ben (synthetic test) | 3 Margins on episode B, a second episode of the same show that you do not add |
| `kit-3-wrong-cut.spokenmargins` | Cy (synthetic test, wrong cut) | 4 Margins that say they are on episode A but were placed by listening to episode B |
| `kit-4-article.spokenmargins` | Dee (synthetic test) | 3 Margins on a web article you do not add at first |

Every sender label says "synthetic", and every voice is a computer voice. Each voice names itself, for example "Margin A one", so you can tell which Margin you are hearing.

Both episodes come from Hacker Public Radio, which is licensed CC BY-SA 4.0. A is by Archer72 and B is by Ken Fallon. Both start with the same 6 seconds of intro music and voice. That shared intro is the point of steps 4 and 5. The article is the Declaration of Independence from the National Archives.

**Nothing in this pass removes the app or touches your other items.** It adds three items: episode A, episode B and the article. Step 8 is an optional way to put them away.

## Before you start (1 minute)

1. Open Spoken Margins. On the Library screen, tap the circle with three dots, top left. Tap **Settings**.
2. Scroll to the bottom. **Version** should end with the build in the plan.
3. Close Settings.
4. Find the four files in the project thread. To open one: tap the file, tap the share icon, then pick **Spoken Margins**. If Spoken Margins is not offered, pick **Save to Files**, then open the file from the Files app.

## 1. Add episode A and stream it (5 minutes)

This is issue #536: sharing Margins from an episode that is streaming, not downloaded. On Wi-Fi the app downloads a new episode at once, so this step turns Wi-Fi off first. It pauses any download of your other episodes, and they start again when Wi-Fi is back. With no cellular data, leave Wi-Fi on and say so. The episode then downloads, and this step tests sharing from a downloaded episode instead.

1. Open Control Center and turn Wi-Fi off. Keep cellular on.
2. Copy the whole grey block below. Tap and hold in it, then tap **Copy**, or use the copy button.

```
https://hpr.nyc3.cdn.digitaloceanspaces.com/eps/hpr4737/hpr4737.mp3
```

3. In Spoken Margins, on the Library screen, tap **Add** (the + at top right).
4. Tap **Paste & go**, at the bottom of the sheet. iOS may ask to allow paste. Allow it.
5. Open the new item from the Library.

**You should see:** one new item, about 8 minutes long. The app names it after the file, so expect "hpr4737". The page says **Streaming available** and has **Download Now**. If it says **Downloading** or has **Download Again**, the phone fetched it anyway. Say so, and go on.

6. Tap play. Leave it playing for two minutes with the app open. It takes that long because the app saves fingerprints of a streaming episode only after about 70 seconds of playing.
7. Drag the scrubber back to about 1:00. Let it play for 15 seconds.
8. Record a Margin. Tap the record button on the mini player, or **Add a Margin** on Now Playing. Say one short sentence. Tap **Save & resume**.
9. Open the **Margins** tab. Find "hpr4737" and tap **Share** next to its name. The **Share Margins** sheet opens. Tap **Review 1**, at the bottom. If it asks "Clean selected Margins automatically?", tap **Not now**. Tap **Share 1**.

**You should see:** the iOS share sheet opens. Cancel it. That is the pass for #536.

If sharing fails, the screen should say what went wrong and offer **Share without episode matching**. Take a screenshot.

10. Turn Wi-Fi back on. The page starts **Downloading** by itself. If it still shows **Download Now**, tap it. Wait until the page shows **Download Again**. That is how the page says the episode is downloaded. The next steps need the downloaded file.

## 2. Import Margins onto an episode you already have (3 minutes)

This is the normal case. Do it once the page for episode A shows **Download Again**.

1. Open `kit-1-episode-a.spokenmargins` in Spoken Margins.

**You should see**, on a sheet titled **Shared Margins**:
- the episode title, "HPR4737: Keep spare parts for Ethernet run", and "Shared by Ada (synthetic test)" under it;
- **Integrity checked**;
- **Margins** says 4;
- **Source transport** says **Source reference**, and **Item contents** says **Item not included in package**;
- the buttons **Import** and **Cancel**.

2. Tap **Import**.

**You should see:**
- the page of episode A opens, and a short message says imported, playback has not started;
- still one copy of episode A in the Library, not two;
- under **Shared Margins**, a card "Shared by Ada (synthetic test)" with **Separate imported layer** and a **Source resolution** line;
- under **Margin placement**, four Margins with their words. At first each may say **Placing in your copy…**. Wait up to two minutes. Then they should read 0:30, 2:00, 4:30 and 7:00 (a second either way is fine), each with **Combined evidence** or **Audio verified**. Both mean the app found the sound in your copy. Write down any other label and which Margin had it.

3. Tap **Listen** on Margin A one.

**You should hear:** Ada's voice say "Margin A one. I belong at thirty seconds into the Ethernet episode." **Listen** plays the voice only. There is no chime, and the episode does not move.

4. Margin A four has no voice. It shows its text and no **Listen** button.
5. Optional. Play episode A and drag the scrubber to about 0:20. Let it play.

**You should see and hear:** at about 0:30 the episode pauses, you hear a two-note chime, and a card appears with **Shared Margin 1 of 4**, **Listen** and **Dismiss**. Tap **Listen** and Ada's voice plays. If no card appears, say so, with the label you wrote down for Margin A one.

## 3. Import the same packet again (30 seconds)

1. Open `kit-1-episode-a.spokenmargins` again.

**You should see:** no sheet this time. The app opens episode A and says these shared Margins are already in your library. Ada's card still holds four Margins, and there is still one copy of episode A. Eight Margins, a second card from Ada, or two copies of the episode is a bug.

## 4. A packet made on a different cut of the episode (2 minutes)

This is issue #456. The packet says it is about episode A, but its places were worked out from episode B. Both begin with the same 6 seconds, so a wrong match inside that intro is the risk.

1. Open `kit-3-wrong-cut.spokenmargins`.

**You should see:** the same sheet, with "Shared by Cy (synthetic test, wrong cut)" and **Margins** says 4.

2. Tap **Import**. Open episode A if the app doesn't. Scroll to **Shared Margins**. Wait up to two minutes for **Placing in your copy…** to finish.

**You should see:**
- Cy's card sits beside Ada's card. Ada's four are unchanged, at 0:30, 2:00, 4:30 and 7:00;
- none of Cy's four shows a time with **Audio verified** or **Combined evidence**. Margin C one sits in the shared intro. If it shows either label with a time, say so, because that is the bug this step is for;
- any other label is fine, but write down what each of Cy's four says, and the **Source resolution** line on Cy's card.

3. Tap **Listen** on Margin C two.

**You should hear:** "Margin C two. I was made on the key fob episode, at one minute." in Cy's voice.

## 5. Import onto an episode you do not have (2 minutes)

This is the case where the packet's source isn't in your Library. It is also the other half of issue #456, because episode B shares its intro with episode A.

1. Open `kit-2-episode-b.spokenmargins` in Spoken Margins.

**You should see:** "Shared by Ben (synthetic test)", **Margins** says 3, **Source reference**, **Item not included in package**, and **Import** is available.

2. Tap **Import**.

**You should see:**
- a new item in the Library that you did not add yourself, about 5 minutes long. The app names it after the file, so expect "hpr4736". Write down any other name;
- the item downloads by itself: **Downloading**, then **Download Again** when it is done. The app fetches the episode when a packet needs it;
- on it, Ben's card with three Margins. After up to two minutes they read 0:04, 1:00 and 4:00, with **Combined evidence** or **Audio verified**;
- nothing from Ben on episode A. Open episode A again and check that it still shows only Ada's card and Cy's card.

3. On episode B, tap **Listen** on Margin B one.

**You should hear:** "Margin B one. I belong at four seconds, inside the intro that both episodes share." in Ben's voice.

## 6. A web article you do not have (3 minutes)

1. Open `kit-4-article.spokenmargins` in Spoken Margins.

**You should see:** "Declaration of Independence: A Transcription", "Shared by Dee (synthetic test)", **Margins** says 3, **Source reference**, **Item not included in package**.

2. Tap **Import**.

**You should see:** a message that the Margins are imported. No new item appears in the Library, because the app does not fetch an article for a packet. Open the **Margins** tab and tap **Shared**. Dee's three Margins are listed there under "Declaration of Independence: A Transcription". The tab opens on **Mine**, which does not show them.

3. Now add the article. Copy the grey block below. Tap **Add**, then **Paste & go**.

```
https://www.archives.gov/founding-docs/declaration-transcript
```

**You should see:** the article in the Library. If its title differs, write it down.

4. Open `kit-4-article.spokenmargins` again.

**You should see:** the **Shared Margins** sheet again, because the first import left Dee's Margins without an article. Tap **Import**. The article opens, and Dee's card shows three Margins on the quoted words. Write down the position and label of each. If they all say **Placing in your copy…** after two minutes, say so. If the article does not open, say so: the app did not take your copy for the article in the packet. Margin D three has no voice, only text.

5. Tap **Listen** on Margin D one.

**You should hear:** "Margin D one. I am attached to the sentence that begins, we hold these truths."

## 7. Send Margins back out from an episode that holds imported Margins (1 minute)

Episode A is downloaded now and holds Ada's and Cy's Margins. It also holds the Margin you recorded in step 1. If you skipped that Margin, record one now (step 1, part 8).

1. Open the **Margins** tab, on **Mine**. Find "hpr4737" and tap **Share** next to its name.

**You should see:** the **Share Margins** sheet opens on **Choose Margins**, and the list holds only your own Margin. Ada's and Cy's Margins are not offered. A packet from here never re-sends someone else's Margins.

2. Tap **Review 1**, then **Share 1**, both at the bottom of the sheet.

**You should see:** the iOS share sheet opens. Pick **Save to Files**, or AirDrop it to a Mac, and attach the file in the project thread. Claude reads it with the Build 29 reader.

## 8. Put the test items away (optional, 1 minute)

Only these three items came from the kit. Touch only these:
- hpr4737, which is episode A
- hpr4736, which is episode B
- Declaration of Independence: A Transcription

Press and hold the item in the Library. Tap **Move to Recently Deleted**. Recently Deleted keeps it, so you can put it back. Moving episode A also moves the Margin you recorded on it.

Leave them in if you want to run the pass again. Importing a packet a second time is safe, as step 3 shows.

## What each Margin says

Tap **Listen** on any Margin and check that the voice names the Margin you tapped.

Ada, episode A, `kit-1-episode-a.spokenmargins`:
- **Margin A one**, at 0:30, with voice.
- **Margin A two**, at 2:00, with voice.
- **Margin A three**, at 4:30, with voice.
- **Margin A four**, at 7:00, text only.

Ben, episode B, `kit-2-episode-b.spokenmargins`:
- **Margin B one**, at 0:04, inside the shared intro, with voice.
- **Margin B two**, at 1:00, with voice.
- **Margin B three**, at 4:00, with voice.

Cy, made on episode B but sent as episode A, `kit-3-wrong-cut.spokenmargins`. Every one says it was made on the key fob episode:
- **Margin C one**, at 0:04, inside the shared intro.
- **Margin C two**, at 1:00.
- **Margin C three**, at 2:00.
- **Margin C four**, at 4:00.

Dee, the article, `kit-4-article.spokenmargins`:
- **Margin D one**, on the words "We hold these truths to be self-evident", with voice.
- **Margin D two**, on the words "Life, Liberty and the pursuit of Happiness", with voice.
- **Margin D three**, on the words "a long train of abuses and usurpations", text only.

## If something goes wrong

1. In Spoken Margins, tap the **Settings** tab at the bottom right.
2. Scroll to **Help & Privacy**. Tap **Share Diagnostics**.
3. Send the file in the project thread and say which step it was. The file holds the titles and links of items in your Library, but no audio.

## Not covered

- The #536 failures that need a very long episode (more than 500 fingerprints) or an episode whose link is not https. Host tests cover both. Both episodes here are short and use https links. Your own phone check of #536 on 2026-10-07 used a long episode.
- A packet with exactly one Margin inside a shared intro. SessionKit still places that one, a known limit written up in the podcast anchor plan.
- Replies to a friend's Margin. The kit has no reply threads.
- Hearing the voices through Bluetooth or the Lock Screen. That is your own listening pass.

## Links

Open these in Safari to see the sources the Margins sit on:

- Episode A: https://hackerpublicradio.org/eps/hpr4737/index.html
- Episode B: https://hackerpublicradio.org/eps/hpr4736/index.html
- The article: https://www.archives.gov/founding-docs/declaration-transcript

The issues:

- Issue #848, this kit: https://github.com/uncomposed/spoken-margins-native/issues/848
- Issue #456, the wrong episode with the same intro: https://github.com/uncomposed/spoken-margins-native/issues/456
- Issue #536, sharing a streamed podcast: https://github.com/uncomposed/spoken-margins-native/issues/536
