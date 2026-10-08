# Sharing test kit: one pass over the sharing failure modes

About ten minutes, on your phone, one time through. It uses four prepared packets made from public content, so you don't need a friend or the original setup. It is for issue #848.

Each step says what you should see. When a step works, say "works" for that step number in the project thread. When it doesn't, say what you saw or heard, and attach a screenshot if you can. Claude updates the issues. Only you mark anything validated.

## What is in the kit

Four files. The plan they came with has them attached.

| File | Sender label | What it is |
| --- | --- | --- |
| `kit-1-episode-a.spokenmargins` | Ada (synthetic test) | 4 Margins on episode A, an episode you add first |
| `kit-2-episode-b.spokenmargins` | Ben (synthetic test) | 3 Margins on episode B, a second episode of the same show that you do not add |
| `kit-3-wrong-cut.spokenmargins` | Cy (synthetic test, wrong cut) | 4 Margins that say they are on episode A but were placed by listening to episode B |
| `kit-4-article.spokenmargins` | Dee (synthetic test) | 3 Margins on a web article you do not add |

Every sender label says "synthetic", and every voice is a computer voice. Each voice names itself, for example "Margin A one", so you can tell which Margin you are hearing.

Both episodes come from Hacker Public Radio, which is licensed CC BY-SA 4.0. A is by Archer72 and B is by Ken Fallon. Both start with the same 6 seconds of intro music and voice. That shared intro is the point of steps 4 and 5. The article is the Declaration of Independence from the National Archives.

**Nothing in this pass removes the app or touches your other items.** It adds three items: episode A, episode B and the article. The last step is an optional way to take them out again.

## Before you start (1 minute)

1. Open Spoken Margins. On the Library screen, tap the circle with three dots, top left. Tap **Settings**.
2. Scroll to the bottom. **Version** should end with the build in the plan.
3. Close Settings.
4. Find the four files in the project thread. To open one: tap the file, tap the share icon, then pick **Spoken Margins**. If Spoken Margins is not offered, pick **Save to Files**, then open the file from the Files app.

## 1. Add episode A and download it (2 minutes)

1. Copy the whole grey block below. Tap and hold in it, then tap **Copy**, or use the copy button.

```
https://hpr.nyc3.cdn.digitaloceanspaces.com/eps/hpr4737/hpr4737.mp3
```

2. In Spoken Margins, on the Library screen, tap **+** (top right).
3. Tap **Paste & go**, at the bottom of the sheet. iOS may ask to allow paste. Allow it.
4. When the sheet closes, open **HPR4737: Keep spare parts for Ethernet run** from the Library.
5. If you see **Download Now**, tap it. Leave it to finish while you do step 2. The matching in steps 2 to 4 needs the downloaded file.

**You should see:** one new item in the Library, "HPR4737: Keep spare parts for Ethernet run", about 8 minutes long. The Item page shows it downloading, then downloaded.

## 2. Import Margins onto an episode you already have (2 minutes)

This is the normal case. Do it once the download from step 1 has finished.

1. Open `kit-1-episode-a.spokenmargins` in Spoken Margins.

**You should see**, on the **Import Shared Margins** sheet:
- the episode title, and "Ada (synthetic test)" under it;
- "Integrity checked · Sender identity is not verified";
- **4 shared Margins**;
- the line "Spoken Margins found this item in your library and will resolve the shared anchors against it. Nothing will play automatically.";
- under **Package contents**: Voice files: 3, and Acoustic anchor signatures with a number above zero.

2. Tap **Import & Resolve Margins**.
3. Open episode A from the Library. Scroll to **Shared Margins**.

**You should see:**
- still **one** copy of episode A in the Library, not two;
- a card "Shared by Ada (synthetic test)" holding four Margins, with the words of each Margin and where it sits;
- on each Margin, a placement label. For the same file on your phone, expect **Audio verified** on most or all four. Write down any other label and which Margin had it.

4. Tap **Listen** on Margin A one.

**You should hear:** a short two-note chime, then "Margin A one. I belong at thirty seconds into the Ethernet episode." in Ada's voice. The episode clock should read about 0:30.

5. Margin A four has no voice. It should show its text and no **Listen** button.

## 3. Import the same packet again (30 seconds)

1. Open `kit-1-episode-a.spokenmargins` again. Tap **Import & Resolve Margins**.

**You should see:** Ada's card on episode A still holds **four** Margins, and there is still one copy of episode A. Eight Margins, or two copies of the episode, is a bug.

## 4. A packet made on a different cut of the episode (2 minutes)

This is issue #456. The packet says it is about episode A, but its places were worked out from episode B. Both begin with the same 6 seconds, so a wrong match inside that intro is the risk.

1. Open `kit-3-wrong-cut.spokenmargins`. Tap **Import & Resolve Margins**.
2. Open episode A. Scroll to **Shared Margins**.

**You should see:**
- the sheet said **4 shared Margins** from "Cy (synthetic test, wrong cut)", and "found this item in your library";
- on episode A, Cy's card sits beside Ada's card. Ada's four are unchanged and still **Audio verified**;
- **none** of Cy's four says **Audio verified**. Margin C one sits in the shared intro. If it says **Audio verified**, say so, because that is the bug this step is for. Any other label is fine, but write down what each one says.

3. Tap **Listen** on Margin C two.

**You should hear:** the chime, then "Margin C two. I was made on the key fob episode, at one minute." The app must not claim an exact place for it.

## 5. Import onto an episode you do not have (2 minutes)

This is the case where the packet's source isn't in your Library. It is also the other half of issue #456, because episode B shares its intro with episode A.

1. Open `kit-2-episode-b.spokenmargins` in Spoken Margins.

**You should see:** "Ben (synthetic test)", **3 shared Margins**, and the line "Spoken Margins will reconstruct this linked item and then resolve the shared anchors. Nothing will play automatically."

2. Tap **Import & Resolve Margins**.

**You should see:**
- a new item in the Library, "HPR4736: How to replace the battery in a car key fob", about 5 minutes long, that you did not add yourself;
- on it, Ben's card with three Margins. This episode is not downloaded, so a placement that is a guess is fine, if it is labelled as one;
- nothing from Ben on episode A. Open episode A again and check that it still shows only Ada's card and Cy's card.

3. On episode B, tap **Listen** on Margin B one.

**You should hear:** the chime, then "Margin B one. I belong at four seconds, inside the intro that both episodes share."

## 6. A web article you do not have (2 minutes)

1. Open `kit-4-article.spokenmargins` in Spoken Margins.

**You should see:** "Dee (synthetic test)", **3 shared Margins**, and "Spoken Margins will reconstruct this linked item and then resolve the shared anchors."

2. Tap **Import & Resolve Margins**. If it can't fetch the page, add the article yourself and import again: copy the grey block below, tap **+**, tap **Paste & go**, then open the file once more.

```
https://www.archives.gov/founding-docs/declaration-transcript
```

**You should see:**
- a new item in the Library, "Declaration of Independence: A Transcription";
- on it, Dee's card with three Margins. Each Margin's place is the quoted words it was made on, and the placement label is about the article text. Write down the labels;
- Margin D three has no voice, only text.

3. Tap **Listen** on Margin D one.

**You should hear:** the chime, then "Margin D one. I am attached to the sentence that begins, we hold these truths."

## 7. Send Margins back out from a streamed episode (2 minutes)

This is issue #536. Episode B is not downloaded, so it streams.

1. Open episode B and tap play. Let it play for about 30 seconds.
2. Tap the record button on the mini player, or **Add a Margin** on Now Playing. Say one short sentence. Tap **Save & resume**.
3. Open the **Margins** tab. Find episode B and tap **Share** next to its name.
4. On the **Share Margins** screen, keep your Margin selected. Tap **Review 1**, then **Share 1**.

**You should see:** the iOS share sheet opens. Cancel it, or pick **Save to Files** and attach the file in the project thread. Claude will read it with the Build 29 reader.

**The bug was** "episode fingerprint spine is out of bounds" and a sheet that sat there. If sharing fails, the message should now say what went wrong and offer **Share without episode matching**. Take a screenshot.

5. Do steps 2 to 4 once more on episode A, which now holds Ada's and Cy's Margins and is downloaded.

**You should see:** the same share sheet. Only the Margin you just recorded is listed to share, not Ada's or Cy's.

## 8. Take the test items out (optional, 1 minute)

Only these three items came from the kit. Remove only these:
- HPR4737: Keep spare parts for Ethernet run
- HPR4736: How to replace the battery in a car key fob
- Declaration of Independence: A Transcription

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

1. In Spoken Margins, on the Library screen, tap the circle with three dots, top left. Tap **Settings**.
2. Scroll to **Support & Privacy**. Tap **Share Diagnostics**.
3. Send the file in the project thread and say which step it was. The file holds the titles and links of items in your Library, but no audio.

## Not covered in the ten minutes

- The #536 failures that need a very long episode (more than 500 fingerprints) or an episode whose link is not https. Host tests cover both. Both episodes here are short and use https links.
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
