# Live sessions: situations, the session model, and the iPhone side

Written 2026-10-23 for #2481 and #1989, from [BRIEF.md](BRIEF.md). The Watch itself is in `WATCH.md`, written in parallel. Here the Watch is a device that can record a Margin and start or stop a session. Status: a design, nothing built. No pixels or colours; where a state matters, it is named in words.

**Review note (2026-10-23):** this file is now an appendix to [DESIGN.md](DESIGN.md), which the owner reads. Where the reviewer changed a call here, a review note says so. DESIGN.md's decisions and defaults replace section 7's list.

**Second review (2026-10-23):** DESIGN.md was checked against the code on `main` and walked through state by state. Its sections 2, 4, 9 and 11 change rules this file restates: the filing rule, quick sessions, Resume after an End, the meeting's assumed 0:00, and the session store. Where the two differ, DESIGN.md wins.

## In one minute

1. **A session is a stretch of time spent on one thing outside the app.** A meeting, a book, a lecture, a video. It holds the Margins taken during that time, and what the listener said about where they were.
2. **It starts in two taps or one sentence, and it runs at once.** "Where are you now?" is a field on the running screen, already filled with the likely answer. It never blocks the start.
3. **One session runs at a time per person.** Every Margin is filed by its own clock time, into the session whose time span holds it.
4. **No silent orphans.** A Margin taken with nothing running starts a **quick session**, which shows in the Library and on the Margins tab like any other.
5. **Confirmation means filed.** The Watch and the Lock Screen say "Filed in Budget meeting" only after the phone has filed it. Before that they say "Saved on Watch, waiting for iPhone".
6. **Ending a meeting is one tap, and the session is a Library item at once.** Line up with a transcript is on that item, and on any transcript file opened in the app, so it works the next day.

---

## 1. The session model

### 1.1 What a session is

A session is:

1. **a time span**: when it started and when it ended, by the clock;
2. **a kind**: Meeting, Audiobook, Paper book, or Something else. The kind only changes wording and whether the end asks a question. Nothing depends on which app or service plays the source;
3. **a name**, optional. The default is the kind and the time, like "Meeting, Thu 14:05". A transcript's title replaces it if the name is still the default;
4. **checkpoints**: pairs of a clock time and a position the listener gave. "0:00 at 14:05". "Chapter 7, 12:30 at 15:40". "Page 112". Start and end are just the first and last checkpoint;
5. **its Margins**: each with its clock time, where it was taken (phone, Watch, Lock Screen, Siri), and its evidence.

A session is never a recording of the source. The only audio it holds is the listener's own spoken Margins.

### 1.2 Who can start one

| From | How | Opens the app? | Verified? |
| --- | --- | --- | --- |
| The phone, in the app | Library, plus, then Meeting, Audiobook, Paper book or Something else | Yes | Exists today, as 3 taps |
| Control Center, the Lock Screen, the Action button | A "Start session" control. It starts the last kind used | No | Unverified for us, check C6 |
| Siri | "Start a Spoken Margins session", or "Add a Margin" with nothing running | No | Unverified, check C7 |
| The Watch | Start on the Watch (details in `WATCH.md`) | No | Not built |

The Live Activity's buttons are Record, Mark and End. They need a session already running. They don't start one.

### 1.3 One at a time

1. **One session runs at a time per person,** across the phone and the Watch.
2. **Starting a second one while one runs asks one question,** in place of the four kind buttons: "Meeting, started 14:05, is running. Go to it, or End it and start a new one."
3. **Our own player is separate.** A Margin made in Now Playing belongs to the item playing there, as today. A session never takes Margins from Now Playing.
4. **When the phone and the Watch each started a session while apart,** the later start ends the earlier one at that moment. The earlier session's item says, in words, "Ended when you started a session on your Watch". Margins split by their clock times.

### 1.4 A Margin with no session

**It starts a quick session.** Today such a Margin waits in a hidden inbox until the next session starts, and is then filed into it, even hours later. That inbox goes.

1. A quick session is an ordinary session of kind Something else, named by its time: "Quick session, Thu 14:05".
2. It starts at its first Margin. Further Margins within 30 minutes of its last one join it. After 30 quiet minutes it ends at its last Margin.
3. The Watch, the Lock Screen and Siri say "Filed in a quick session" when it happens.
4. On its row and its Margins group there are two actions: **Rename** (name and kind), and **Move to another session**.
5. Line up works on it the same way, because every Margin keeps its clock time.
6. **Second review (2026-10-23):** a quick session never blocks a named session, overlapping quick sessions merge, and a named session that covers a quick session's time takes its Margins (DESIGN.md section 2, point 7). While Spoken Margins itself is playing an item, a Margin goes onto that item instead (point 12).

Why this and not a visible inbox list: a quick session needs no new kind of place. It also makes forgetting to start almost free, which is the most common failure in every situation below.

### 1.5 Asking for positions without nagging

1. **At the start, the question is a field, not a gate.** The running screen's top line reads "Where are you now?", filled in by kind:
   - Meeting: 0:00, with the hint "the meeting clock".
   - Audiobook: empty, with the hint "the time your app shows, or chapter and time".
   - Paper book: empty, with the hint "page".
   - Something else: empty.
2. **Typing in it adds a checkpoint at the moment of typing,** not at the session's start. Someone who types "2:00" forty seconds in is not 40 seconds wrong.
3. **Sessions started away from the app** (the control, Siri, the Watch) start with no checkpoint, except a meeting's assumed 0:00. The session's screen and item show "Where were you at the start? Add it to place Margins better." This is a line in the screen, never a pop-up, and never a notification.
4. **At the end, only an audiobook or a paper book asks one question,** "Where did you stop?", with the app's estimate filled in, and Skip. A meeting and Something else end with one tap. The owner's rule: the end matters for audiobooks, "a meeting, it's less important."
5. **During a spoken Margin, the placing hint is shown while it records,** on every surface that records. Meeting: "Say something that helps place this, like 'Johnny was just talking about the budget'". Audiobook and paper: "like 'I think this is chapter 5'". Today the hint is only the written field's placeholder.
6. **The listener may nudge one Margin's time,** as today (plus or minus 5 seconds, plus or minus 1 minute). Never required.
7. **Every checkpoint can be fixed afterwards** on the item's screen, and every estimate recomputes. A transcript match still outranks the estimate, and both are kept.

### 1.6 Where the session lives

**While it runs:**

1. **Library:** a row pinned at the top, labelled Live, with the kind, the name, the running clock and the Margin count. Tapping it opens the running session.
2. **Margins tab:** the first group, headed Live. Under the Four tabs objective, groups are ordered by their newest Margin, so a running session is naturally first.
3. **Lock Screen and Dynamic Island:** the Live Activity, with the clock, the count, the last filed Margin ("Filed: Watch Margin, 14:12") and the buttons Record, Mark and End.
4. **Watch:** the session's name and clock (see `WATCH.md`).

**After it ends:**

1. **Library:** an ordinary item row, labelled Session with its kind. A meeting with no transcript also says "Not lined up", in words.
2. **Margins tab:** an ordinary group, with Share as Markdown on its heading, as for any item today.
3. **The item's screen:** when it ran, its checkpoints (editable), each Margin with where it came from, **Line up with a transcript or recording**, and **Share as Markdown**.

### 1.7 Lining up afterwards

1. **From the item:** Library row, then Line up. The file picker opens at once. Picking the file applies the line-up and shows the result. That's 3 taps.
2. **From the file itself:** a transcript opened or shared with Spoken Margins (AirDrop from a laptop, Files, Teams' or Zoom's download) goes straight to the line-up. The session is found by its times. When more than one session could fit, the screen names its pick at the top with Change. That's 2 taps, and it rests on check C8.
3. **The result is applied at once, with Undo.** Every Margin shows its position and all of its evidence: the estimate, the listener's own setting, the transcript match with its score, speaker and words, and the placing hint. Nothing is thrown away.
4. **A recording** can be added the same way, before or after the transcript. With a recording the item plays it, as today.

### 1.8 Confirmation means filed

1. Each Margin has four states, said in words on the Watch and the Live Activity: **Recording**, **Saved on Watch**, **Waiting for iPhone** (only after 15 seconds with no answer), and **Filed in <session>**. **Review note (2026-10-23):** this was three states; it now matches `WATCH.md` section 2.6, so both devices use the same words.
2. The phone sends the "filed" answer back to the Watch for each Margin. Until it arrives, the Watch keeps the recording and shows how many are waiting.
3. The phone's Live Activity count rises only when a Margin is filed.
4. A Margin that arrives after its session ended is filed into that session's item, labelled "arrived after the session ended", and placed with the same line-up if there is one.
5. **How a Margin finds its session.** Its own corrected time decides, and the session id it carries settles the rest:
   1. If a session's span holds the Margin's time (corrected for the Watch's clock, `WATCH.md` 3.5), it files there.
   2. Otherwise, if the id names a session that has ended, it files there, labelled "after the session ended".
   3. Otherwise, if the id names a session the phone has never seen (the Watch started it out of range), the phone creates that session.
   4. Otherwise it starts a quick session (1.4).
   **Second review (2026-10-23):** step 2 now applies only within 30 minutes of the session's end, and our own player comes before a quick session. The full rule is DESIGN.md section 4, point 6.
   **Review note (2026-10-23):** section 1.9 said time span only, and `WATCH.md` said session id only. Time alone can't place a Margin from a session the Watch started out of range. The id alone files a Margin into an old session after the phone has started a new one. This rule keeps both strengths.

### 1.9 What in today's code stays, changes, or goes

**Stays:**

1. `LiveSession` and `LiveSessionMargin`: the time span, kind, Margins, spoken Margins with `audioPath` and `spokenOn`.
2. `ElsewhereKind`, with one wording change: "Something else" becomes "Lecture, video or something else".
3. `LiveSessionFileWorker` for every disk read and write.
4. `TranscriptAlignment`, the VTT, SRT, docx and txt parsers, and `LiveSessionAlignment.best`: match, then listener, then estimate, with every piece kept.
5. `LiveSessionMarkdown` and `LiveSessionRecord`. The record is what makes a later line-up possible, so it becomes essential, not an export helper.
6. The Live Activity and its Mark button, and `LiveSessionMarkInbox`'s race-free keys.
7. `WatchMarginTransfer` and `WatchMarginReceiver`'s move-into-the-container step.
8. A finished session saved as an ordinary Library item.

**Changes:**

1. **Start:** the setup card and Start Session become four kind buttons that start at once. The position becomes an inline field on the running screen.
2. **Positions:** `startPositionMs` and `endPositionMs` become the first and last of a list of checkpoints, each a clock time and a position. A session saved by an earlier build still reads, as two checkpoints. `LiveSessionPositionMap` reads the list.
3. **End:** a meeting ends with one tap and becomes an item at once. Only an audiobook or paper book shows the end sheet.
4. **Line Up:** moves from the ended-session screen to the item's screen, and gains an entry for opened or shared transcript files.
5. **Filing:** `LiveSessionWatchMatch` files by the rule in 1.8, point 5: time span first, then the Margin's session id. The fallback to "the most recently started session" goes, because it can file a Margin into a session hours away from it.
6. **Back-channel:** the phone tells the Watch when each Margin is filed, and the Watch shows it.
7. **Lock Screen Marks taken outside any session** are filed by time, like Watch Margins. Today `start()` throws them away.
8. **The running session is reachable** from the Library's Live row, the Margins tab and the Live Activity, not only through the plus sheet's route.
9. **Phone spoken Margins** show the placing hint while recording, and say plainly when a call holds the microphone.

**Goes:**

1. The hidden Watch inbox that waits for the next session.
2. "Save as Notes" and "Discard Session" as steps. Deleting a session uses the item's normal delete, with its existing Undo.
3. The full-screen cover inside the Add sheet as the only way back to a running session.

---

## 2. What fails, and what the listener sees

These failures come up in every situation. Each situation below says which ones bite hardest, and adds its own.

| # | What goes wrong | What the listener sees |
| --- | --- | --- |
| F1 | **Forgot to start.** Margins taken from the Watch, Siri or the app with nothing running. | "Filed in a quick session" on the device that took it. A Quick session row in the Library and on the Margins tab. Rename or Move to another session on it. |
| F2 | **The phone app was closed or killed.** | The Live Activity stays, with Mark and End working (check C9). The Watch shows "Saved on Watch, waiting for iPhone" until the phone app runs again. Reopening the app shows the Live row in the Library. |
| F3 | **The Watch is out of range.** | The Watch records anyway. It shows "2 waiting for iPhone", and its session line says "as of 14:05". Each Margin files by its own time when the phone is back. |
| F4 | **No transcript exists.** | Margins keep "about 12:40", the estimate, with the placing hint in the Margin's text. The item says "Not lined up" in words. Nothing asks again. |
| F5 | **Wrong start position.** | The item's screen shows the start checkpoint, editable. Changing it moves every estimate. A transcript match still wins and both are shown. |
| F6 | **Two sessions overlap.** | Starting a second asks one question: Go to it, or End it and start a new one. Sessions started apart on the phone and the Watch: the later one ends the earlier, and the earlier item says so in words. |
| F7 | **Forgot to end.** | Starting something else ends it (F6). Otherwise it ends itself 8 hours after its start, when the Live Activity must end (check C9). Its end is set to its last Margin, and the item says "Ended automatically". This holds for sessions started on the Watch too; only quick sessions close after 30 quiet minutes. |
| F8 | **The phone's microphone is busy** (a call holds it). | Speak and the Live Activity's Record say "Your call is using the microphone. Speak on your Watch, or write." If the app can't tell beforehand (check C1), Speak tries, fails cleanly and says the same. Nothing half-saved. |
| F9 | **A Margin arrives after its session ended.** | Filed into that session's item, labelled "arrived after the session ended". |

---

## 3. Situations

Times are approximate, counted from the moment the listener decides to start. "Phone" means iPhone.

### S1. A friend in a Teams or Zoom call on his phone

**Who.** The friend who asked for this. He already types notes in meetings. Speaking them is the value he wants. Meetings are the main use case.

**Devices.** Phone running the call. Sometimes AirPods, sometimes the speaker. Sometimes a Watch.

**Hands and eyes.** Eyes on the call, often on video. One hand holds the phone, or it lies on the desk. He is usually muted.

**What the platform allows (verified by the owner, 2026-10-22):** during a Teams call on the phone, even muted, the phone's microphone is unavailable to other apps. Voice Memos on the Watch recorded fine during the same call. So **on the phone, Margins are written or Marks. Spoken Margins come from the Watch.** With AirPods, the AirPods microphone also belongs to the call (inference, high confidence; check C1).

#### S1a. With a Watch

1. **-0:30.** The meeting is about to start. On the Watch he taps Start, then Meeting (`WATCH.md`). Or on the phone: Control Center, then Start session (2 taps, no app opened).
2. **0:00.** The Watch shows "Meeting, 0:00". Started from Control Center, the Live Activity appears on the phone at once. Started from the Watch, it may appear only once the phone app next comes forward. **Review note (2026-10-23):** the original said it appears at once from the Watch too. iOS lets an app start a Live Activity from the foreground or from an App Intent; a Watch message that wakes the app in the background may not be enough (inference; check C12).
3. **0:02.** He joins the Teams call. The meeting clock and the session clock run together, so 0:00 is right without asking.
4. **12:40.** Someone says something worth answering. He checks he's muted. He raises his wrist and taps Record. The Watch shows the placing hint: "Say something that helps place this, like 'Johnny was just talking about the budget'".
5. **12:41.** He says: "Priya's point on the Q3 budget, we already cut that line. Check with finance." He taps Stop.
6. **12:42.** The Watch says "Saved on Watch", then a second or two later "Filed in Meeting, 14:05" (check C4). The phone's Live Activity count goes from 2 to 3.
7. **During.** He never left the call.
8. **48:00.** The call ends. He long-presses the Dynamic Island and taps End, or taps End on the Watch. The session is an item.
9. **Next day, 9:10.** Teams has the transcript. On his laptop he downloads the .vtt or .docx and AirDrops it to the phone. The phone opens it in Spoken Margins and lines it up with yesterday's meeting, found by its times. He sees each Margin beside what was said, with the match score and the speaker.
10. **9:12.** Share as Markdown from the item or the Margins tab. The export lists each Margin, its time, its evidence and its transcript.

#### S1b. Without a Watch, AirPods or speaker

1. **0:00.** Start from Control Center, or from the app: plus, then Meeting.
2. **12:40.** He long-presses the Dynamic Island and taps Mark. That's 2 taps, and he stays on the call. There is no Record button, because the call holds the microphone (F8).
3. **12:41.** If he wants words now: tap the Live Activity, type into the Mark's row in Spoken Margins, and switch back. The call keeps going while he types (Teams audio continues in the background, inference; video may go to picture-in-picture, unverified).
4. **After the call.** The session's screen lists his Marks, each with "add words to help place it". Typing "Johnny on the budget" lets the line-up place it.
5. **Next day.** Line up as in S1a.

**Speaker or AirPods:** for him this changes nothing on the phone, because the call holds the microphone either way. It matters for the Watch: on the speaker, the Watch microphone also picks up other people's voices behind his Margin (see section 6, Consent).

**Failures that bite here:**

1. **F8,** the busy microphone, every time. The Record button must not appear on the Live Activity during the call.
2. **Unmuted while speaking a Margin.** The meeting hears him. While a Meeting session runs, the Watch's recording screen says "Muted in the call?" above the hint. The app can't read the call's mute state (inference: no public API exposes another app's mute state).
3. **F1, forgot to start.** Watch Margins go into a quick session. The next day he picks the transcript from the quick session's row, and the line-up works on clock time.
4. **F3, Watch out of range.** Rare when the phone is in his hand, but the waiting count covers it.

### S2. The same meeting on a laptop, with the phone beside it

**Who.** The same friend at his desk, or the owner.

**Devices.** A laptop runs Teams or Zoom. The phone lies on the desk. Maybe a Watch. Headphones on the laptop, or its speakers.

**Hands and eyes.** Eyes on the laptop. Hands on the keyboard. The phone is within reach and can stay on the session screen.

**What the platform allows:** no call is on the phone, so the phone's microphone should be free (inference; it is the same question as check C2, without another app in front).

1. **-0:30.** On the phone: plus, then Meeting. The session screen stays open on the desk.
2. **0:00.** He joins the meeting on the laptop.
3. **12:40.** He mutes on the laptop and taps Speak on the phone, which shows the placing hint. He speaks, then taps Stop. Two taps, and his eyes leave the call for about two seconds.
4. **13:00.** He could tap Mark on the Lock Screen instead, if the phone is locked.
5. **48:00.** He taps End on the phone, one tap.
6. **48:05.** Teams posts the transcript later. Next day he downloads it on the laptop and AirDrops it to the phone. The line-up opens with the meeting already picked.
7. **48:10.** He exports Markdown and pastes it into the meeting notes.

**Failures that bite here:**

1. **Laptop speakers.** The phone's microphone hears the meeting behind his Margin. Headphones on the laptop keep other voices out. See section 6, Consent.
2. **Unmuted on the laptop.** The meeting hears his Margin. The phone's recording state says "Muted in the meeting?" above the hint, as on the Watch.
3. **The transcript lives on the laptop.** The share-or-open entry (check C8) is what keeps this at 2 taps. Without it, he has to save it to Files and use Line up from the item.
4. **Screen lock.** The phone locks while it lies on the desk. The Lock Screen's Live Activity still has Record and Mark (check C3).

### S3. An Audible book on a walk

**Who.** The owner, or any listener with an audiobook in another app.

**Devices.** Phone in a pocket. AirPods. Maybe a Watch.

**Hands and eyes.** Eyes on the street. Hands free or carrying something. Taking the phone out is a real cost.

**What the platform allows:**

1. AirPods double-press goes to the app that owns Now Playing, which is Audible, not us (inference, high confidence; check C10). So the headphone double-press can't add a Margin here.
2. Whether our app can start the phone's microphone while Audible plays in front is unverified (check C2).
3. Whether starting a recording pauses or ducks Audible, and whether Audible resumes after, is unverified (check C3). We cannot pause another app directly.
4. Audible shows time within the chapter, not time in the book, in its main view (unverified, check C11). So a position may be "chapter 7, 12:30".

#### The flow

1. **-0:20.** At home he opens Audible and sees "Chapter 7, 12:30". In Spoken Margins: plus, then Audiobook. He types "ch 7 12:30" into "Where are you now?". Or he starts from the Watch and adds the position later.
2. **0:00.** He presses play in Audible and walks out. Phone in pocket.
3. **18:00.** Something lands. With a Watch: raise wrist, tap Record, and see the hint "like 'I think this is chapter 8'". He says "Chapter 8, the bit about the river trade. That's the same argument as the Liv Boeree episode." Then Stop, and "Filed in Audiobook, 15:40". Audible keeps playing unless check C3 shows we can pause it.
4. **18:00, no Watch.** "Hey Siri, add a Margin" through the AirPods (check C7), or take the phone out, long-press the island, then Record and Stop (3 taps, check C2).
5. **52:00.** Home. He opens Spoken Margins and taps the Live row, then End. "Where did you stop?" shows the estimate, "ch 8, about 31:00". He checks Audible, types "ch 8 29:10", and taps End.
6. **52:05.** The end checkpoint corrects for pauses and playback speed. Every Margin's estimate recomputes.
7. **Next day.** He finds the session at the top of the Library. Each Margin shows "about chapter 8, 14:20" with his spoken hint. There's no transcript to line up against. The export says so.

**Failures that bite here:**

1. **F7, forgot to end.** Likely on a walk. Ending later still asks where he stopped. If he answers "I don't know", Skip leaves the estimates from the start alone, labelled as estimates.
2. **Paused Audible for ten minutes at a shop.** Wall time overestimates. The end checkpoint fixes it, and a mid-walk checkpoint is one field on the running screen.
3. **F3, Watch out of range.** He left the phone at home and walked with the Watch on cellular or alone. The Watch keeps everything, and it files by time when he's back.
4. **Speed.** At 1.5x, wall time and book time differ. Only the start and end checkpoints can correct it. The app never assumes a speed.

### S4. A lecture in a room

**Who.** A student, or someone at a talk.

**Devices.** Phone on the desk or in a bag. Maybe a Watch. Maybe a laptop for notes.

**Hands and eyes.** Eyes on the speaker and the slides. Speaking aloud is rude, so whispering into the Watch or writing is the norm.

1. **-1:00.** Plus, then "Lecture, video or something else". He names it "Week 6, Kant". The meeting-style 0:00 doesn't apply, and he leaves the position empty.
2. **0:00.** The lecture starts.
3. **22:00.** He taps Mark on the Lock Screen when slide 14 makes him think. Later he types "slide 14, categorical imperative" into it.
4. **35:00.** He whispers a Margin into the Watch: "ask about the lying example".
5. **75:00.** End, one tap.
6. **Two days later.** The course page posts the lecture recording with a captions file (.vtt). He downloads it to the phone and opens it in Spoken Margins. The line-up places the Marks with "slide 14" as their hint, and the whispered Margin by its words.

**Failures that bite here:**

1. **No transcript, ever** (F4). Common for in-person talks. Marks with typed hints are then the only placement, and the item says so.
2. **Background voices.** A whispered Margin picks up the lecturer behind it. It is the listener's own short clip, not a recording of the lecture. See section 6, Consent.
3. **Continuous recording** of the room is the Watch designer's question and the owner's consent call. The phone side never records the lecture.

### S5. A YouTube video on the phone

**Who.** Someone watching a talk or an explainer. The owner calls this secondary.

**Devices.** Phone in hand, maybe AirPods. No call.

**Hands and eyes.** Eyes on the video. Leaving the app breaks the experience.

**What the platform allows:** the owner's test showed iOS Screen Recording captured YouTube's audio. We don't capture it ("I don't want to toe the line"). Whether our microphone can start while YouTube is in front is check C2, and what happens to YouTube's audio is check C3.

1. **-0:10.** Control Center, then Start session (2 taps). It starts as the last kind used, so he long-presses the island and taps the kind later, or leaves it.
2. **0:00.** He plays the video from 4:12. He opens the session (tap the Live Activity), types 4:12, and switches back. Or he skips it and says the time in his first Margin.
3. **9:30.** He long-presses the island and taps Record. The hint shows. He says "At 9:30 in the video, the chart is mislabelled". Then Stop. He stays in YouTube.
4. **20:00.** He ends from the island.
5. **Afterwards.** He exports Markdown. There's no line-up, because the app doesn't fetch the video's captions (we don't fetch publishers' pages without the listener's action, and this design adds nothing source-specific).

**Failures that bite here:**

1. **YouTube pauses when recording starts,** or stops and doesn't resume (check C3). If it pauses and resumes, that may be welcome. If it doesn't resume, Record needs a warning or goes from the island.
2. **Wrong start** (F5): he forgot to type 4:12. Every estimate is 4 minutes early. Fixing the start checkpoint on the item corrects them all.
3. **Picture-in-picture** may cover the island. The Lock Screen and the Watch remain.

### S6. A paper book

**Who.** A reader in a chair, with a pencil.

**Devices.** Phone on the side table. Maybe a Watch.

**Hands and eyes.** Both hands on the book, eyes on the page. The phone is out of reach of the hands' natural path, and the Watch is on the wrist.

1. **-0:10.** Plus, then Paper book. "Where are you now?" asks for a page. He types 112.
2. **0:00.** He reads.
3. **14:00.** He raises his wrist, taps Record, and the hint reads "like 'page 118'". He says "Page 118: this contradicts chapter 2." Then Stop, and it's filed.
4. **14:00, no Watch.** "Hey Siri, add a Margin" with the phone on the table (check C7), or pick up the phone and tap Speak on the session screen.
5. **50:00.** End. "Where did you stop?" asks for a page. He types 131.
6. **Afterwards.** The session reads "Pages 112 to 131". Each Margin carries its spoken page. There's no clock position. Time is meaningless for a book on paper, and the app never shows one.

**Failures that bite here:**

1. **F7,** he puts the book down and forgets. A named session doesn't end after 30 quiet minutes; only a quick session does. It runs until he ends it or 8 hours pass. When he ends it, the question still asks for a page.
2. **No page said.** A Margin with no page has only its time and the session's page range. The export says "between pages 112 and 131".

---

## 4. Jobs, in taps

The jobs are in [live-sessions.json](live-sessions.json), a proposal against `Design/flow-map/flow-map.json` in the same format as `Design/proposals/four-tabs.json`. Taps come from `Design/proposals/compute-taps.py`, unchanged.

```bash
python3 Design/proposals/compute-taps.py docs/design/live-sessions/live-sessions.json --check
python3 docs/design/live-sessions/job-table.py
```

The flow map was drawn before live sessions existed, so the script's "as built" column is empty for these jobs. **Today** is counted by hand from the code on `main`.

### Cost rules added

compute-taps.py's rules stand: a tap is 1, a menu item is 2, typing is not counted, and the confirming tap is. Added here, in their own columns, so they don't bend its numbers:

1. **Long-press the Dynamic Island** is 1 tap. It's the system's expand gesture.
2. **Open Control Center, or press the Action button,** is 1.
3. **A spoken command to Siri** is 1, in the Voice column. Waking Siri is not counted.
4. **Watch actions** are counted apart from phone taps: a wrist raise, a Watch tap, a double-tap gesture and a crown turn are 1 each. A glance with no touch is 0, but it is listed.
5. **Leaves the other app:** yes when the other app (the call, the book, the video) leaves the screen. In a video call, that is eyes off the call.
6. **Rests on:** the device checks in section 5 that must pass for the count to hold.

### The table

| Job | Today | Proposed | Leaves the other app | Watch | Voice | Rests on |
| --- | --- | --- | --- | --- | --- | --- |
| Start a meeting session in the app | 3 | 2 | no | none | 0 | nothing new |
| Start a session without leaving the other app | not possible | 2 | no | none | 0 | C6 |
| Start a session by voice | not possible | 1 | no | none | 1 | C7 |
| Add a spoken Margin, session screen open | 2 | 2 | already out | none | 0 | nothing new |
| Add a spoken Margin without leaving the other app (no call) | not possible | 3 | no | none | 0 | C2, C3 |
| Add a Margin during a call on the phone, no Watch | 2 | 2 | no | none | 0 | nothing new |
| Add a spoken Margin during a call, with a Watch | 2 | 2 | no | raise wrist, 2 taps (or 1 double-tap gesture each) | 0 | C4 |
| Go back to the running session from the other app | 1, or 4 if the app was closed | 1 | yes | none | 0 | nothing new |
| End a meeting session | 4, or 6 if the app was closed | 2 | no | none | 0 | nothing new |
| End an audiobook session with where you stopped | 4, or 5 if the app was closed | 3 | yes: the question needs the app | none | 0 | nothing new |
| Line up with a Teams transcript the next day, from the Library | 6, or impossible once saved | 3 | n/a | none | 0 | nothing new |
| Line up from the transcript file itself | not possible | 2 | n/a | none | 0 | C8 |
| Find yesterday's session | 1 | 1 | n/a | none | 0 | nothing new |
| Export a session as Markdown | 2 | 2 | n/a | none | 0 | nothing new |
| Find a Margin taken with no session running | not possible | 1 | n/a | none | 0 | nothing new |
| Fix a wrong start position afterwards | not possible | 3 | n/a | none | 0 | nothing new |

What to read off it:

1. **Every job is at or under the three-tap ceiling.** Six jobs that are impossible today become possible.
2. **The biggest gains are not taps.** They are the four "not possible" rows about leaving the other app, finding orphans, and lining up the next day.
3. **Five rows rest on unverified platform behaviour.** If check C2 or C3 fails, "spoken Margin without leaving the other app" falls back to Mark (2 taps) plus words later, which is today's state.

### Screens

Three screens are added: Live session, End session (audiobook and paper only) and Lined up. Five outside-the-app places are added to the map: the other app, the Live Activity, the Start session control, Siri and the Watch. Nothing is removed from the base map, because it never had today's live-session screens. Against the code, the setup card and the ended-session card go.

---

## 5. Device checks

Each platform claim this design leans on, how sure it is, and the check that settles it. "Verified" means the owner saw it on his phone. "Documented" means Apple documents it, but it is unchecked in our app. "Inference" means reasoning only.

| # | Claim | Status | The check |
| --- | --- | --- | --- |
| C1 | The app can tell a call holds the microphone before trying (for example through CallKit's call observer, if Teams and Zoom report their calls to it). | Inference | During a Teams call and a Zoom call on the phone, open a session and see whether Speak shows the "call is using the microphone" state before a tap. |
| C2 | The app can start the phone's microphone while another app is in front and no call runs. | Unverified (BRIEF, test 4) | YouTube, then Audible, in front: tap Record in the expanded island and check that a non-empty Margin is filed. Repeat with the phone locked (`hands-free-margins.md` section 5.1). |
| C3 | Recording from the Live Activity starts without opening the app, and the other app's audio pauses, ducks or keeps playing, and does or doesn't resume. | Documented in part (an audio-recording App Intent run from a Live Activity), unverified for us | The same runs as C2. Note what YouTube and Audible do at Record and at Stop. |
| C4 | Our Watch app records during an iPhone call, and the phone files the Margin with the app in the background or closed. | Verified in part: Voice Memos on the Watch recorded during a Teams call. Filing is not observed | Teams call on the phone, Spoken Margins closed. Record on the Watch. See "Filed in" on the Watch, and the Margin in the session afterwards. |
| C5 | The Watch can hold Margins while out of range and deliver them later, and the phone can tell the Watch each one is filed. | Documented (WatchConnectivity queues transfers), unverified for us | Phone in another room, out of range. Record two Margins, come back, and watch the waiting count reach 0. |
| C6 | A Control Center or Lock Screen control can start a session and its Live Activity without opening the app. | Documented (Controls, iOS 18), unverified for us | Add the control. Start from inside Teams and check the island appears and Teams stays in front. |
| C7 | Siri runs "Start a Spoken Margins session" and "Add a Margin" with no Shortcuts setup, while another app plays, and the Margin records after Siri finishes speaking. | Documented in part (App Shortcuts need no setup), unverified for us | With Audible playing on AirPods, say each phrase. Check the session starts and the Margin has the listener's words, not Siri's. |
| C8 | Spoken Margins appears in the share sheet and in Open In for .vtt, .srt, .docx and .txt files. | Needs app work (document types and the share extension), then a check | AirDrop a Teams .vtt and a Zoom .txt from a Mac, and open each one from Files. |
| C9 | The Live Activity survives the app being closed, ends after 8 hours, and its Mark and End buttons work with the app closed. | Documented (8-hour limit), unverified for us | Start a session, close the app from the app switcher, tap Mark and End, then reopen and check both took effect. |
| C10 | AirPods double-press goes to the app that owns Now Playing (Audible), not to us, while Audible plays. | Inference, high confidence | Audible playing, a session running, double-press. See which app reacts. |
| C11 | Audible's main view shows time within the chapter, not time in the book. | Inference | Look at Audible's player. It decides the hint for an audiobook's "Where are you now?". |
| C12 | A session started on the Watch puts the Live Activity on the phone's Lock Screen without the phone app coming forward. | Inference: probably not (an app starts a Live Activity from the foreground or an App Intent) | Phone locked, app in the background. Start a session on the Watch. Wake the phone and look for the Live Activity. |

---

## 6. Consent

1. **Margins are the listener's own voice.** That raises no consent issue (BRIEF).
2. **A spoken Margin can carry other voices behind it:** a call on the speaker, laptop speakers, a lecturer. It is a short clip of the listener talking, not a recording of the meeting, and the app never transcribes the background on purpose. It is still a recording that can hold other people's words. Illinois requires every party's consent to record a private conversation.
3. **What this design does:** in a Meeting session, the first spoken Margin shows one line, once per listener: "Your Margin records your voice. If the meeting is on a speaker, other voices may be in the background. Headphones keep them out." This is Default taken 12 in [DESIGN.md](DESIGN.md).
4. **What it doesn't do:** record the meeting, the lecture or the room. Continuous recording is the Watch design's question, and it needs the owner's consent call.

---

## 7. Open decisions

### For the owner (product taste, or close to the law)

1. **A Margin with no session starts a quick session.**
   - My pick: a quick session, named by its time, that later Margins within 30 minutes join, with Rename and Move to another session.
   - The alternative: a visible "Not in a session" list at the top of the Margins tab, where each Margin is moved by hand.
   - The cost of my pick: sessions the listener never meant to make, cluttering the Library.
   - What would show it's wrong: in his first two weeks, he moves or deletes more quick sessions than he keeps.
2. **Ending a meeting makes the item at once, and the line-up is applied without a review step, with Undo.**
   - My pick: no Save as Notes step, and no "review, then Save" in the line-up.
   - The alternative: today's end card (Line Up, or Save as Notes), and a review before saving.
   - The cost: a bad transcript match is applied before he looks. The evidence is shown, and Undo restores it.
   - What would show it's wrong: he taps Undo on a line-up more than once in his first five.
3. **A one-time note about background voices in meeting Margins.** **Review note (2026-10-23):** moved to DESIGN.md's Defaults taken. It is one line of text, reversible, and the legal question goes on the attorney list either way.
   - My pick: show the note once, on the first spoken Margin in a Meeting session.
   - The alternative: no note. Or ask the attorney first and add it to `docs/legal/attorney-questions.md`.
   - The cost: one more line of text, once.
   - What would show it's wrong: the attorney says the clips need more than a note, or none at all.

### Defaults taken (technical, veto by number)

4. **One session at a time per person,** and a later start ends the earlier one. The alternative is parallel sessions, such as a book and a meeting. Wrong if a listener asks for two at once.
5. **A forgotten session ends itself at 8 hours,** at its last Margin. That matches the Live Activity's limit. The alternative is to run until ended. Wrong if real sessions over 8 hours turn up, such as a conference day.
6. **Start and end become checkpoints,** with the old fields read as two checkpoints. The alternative is to keep start and end only. Wrong if nobody adds a third checkpoint in a month of use. Then the list is extra weight, but harmless.
7. **Filing by time span first, then the Margin's session id** (1.8, point 5), dropping today's "most recent session" fallback. The fallback can file a Margin into a session hours away.
8. **Rename "Something else" to "Lecture, video or something else",** keeping four kinds. The alternative is adding Lecture and Video kinds. Wrong if the kinds start to need different behaviour, and today they don't.
9. **Quick sessions close after 30 quiet minutes.** Wrong if a lecture's Margins split into two quick sessions often. Then raise it to 90.

### Not decided here

- Everything about the Watch's own screens, continuous recording and raise-to-mouth is in `WATCH.md`.
- A Mac or web place to line up from the laptop directly is out of scope. AirDrop is the bridge for now.
