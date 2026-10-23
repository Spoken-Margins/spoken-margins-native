# Live sessions and the Watch: the design

Written 2026-10-23 for #2481, #2487 and #1989. This is the one document to read. Two appendices hold the detail: [SITUATIONS.md](SITUATIONS.md) (the situations and the iPhone side) and [WATCH.md](WATCH.md) (the Watch and its contract with the phone). The owner's goal and rules are in [BRIEF.md](BRIEF.md). Nothing here is built.

## What this is

1. A **live session** is a stretch of time spent on something outside the app: a meeting, an audiobook, a lecture, a video, a paper book. You take Margins during it, by voice or in writing.
2. Every Margin lands in a session you can see, and the app tells you where it went only once it is really there.
3. Afterwards, a transcript or recording from Teams, Zoom or anywhere else lines the Margins up with what was said. The Watch is both a recorder of its own and a remote for the phone.

---

## 1. The situations, briefly

Each is told second by second in [SITUATIONS.md, section 3](SITUATIONS.md#3-situations).

1. **A Teams or Zoom call on the phone.** The main use. The call holds the phone's microphone, so on the phone you can only write or Mark. Spoken Margins come from the Watch.
2. **The same meeting on a laptop, phone on the desk.** The phone's microphone is free. Two taps on the phone make a spoken Margin.
3. **An audiobook on a walk.** Phone in a pocket. The Watch is the easy way. Ending asks where you stopped, because pauses and speed make the clock wrong.
4. **A lecture in a room.** Whisper into the Watch, or Mark and write later. A captions file, if the course posts one, lines them up.
5. **A YouTube video on the phone.** Record from the Dynamic Island without leaving YouTube, if the device checks pass.
6. **A paper book.** Positions are pages. The Watch takes "page 118, this contradicts chapter 2".

---

## 2. The session model

1. **One session runs at a time,** across the phone and the Watch. Starting a second one asks "Go to it, or End it and start a new one".
2. **Start from anywhere:** the app, Control Center, Siri or the Watch. On the phone, plus then a kind button, and it is running. Two taps.
3. **Four kinds:** Meeting, Audiobook, Paper book, and Other (lecture, video). The kind changes wording and whether the end asks a question. Nothing depends on which app plays the source.
4. **Where you are is a field, not a gate.** The running screen shows "Where are you now?", already filled in for a meeting (0:00). Typing or turning the crown stamps a checkpoint at that moment. Sessions started away from the app show a line asking for it later, never a pop-up.
5. **Only an audiobook or a paper book asks where you stopped,** with the estimate filled in and Skip. A meeting ends in one tap. Your rule: "a meeting, it's less important."
6. **A Margin with no session starts a quick session.** It shows in the Library and the Margins tab like any other, and you can rename it or move its Margins. Margins within 30 minutes of the last one join it. This is decision 1.
7. **A forgotten session ends itself after 8 hours,** at its last Margin, and says so. Only a quick session closes after 30 quiet minutes.
8. **The placing hint shows while you speak,** on every device: "Say something that helps place this, like 'Johnny was just talking about the budget'." It is never a separate step.
9. **You may nudge a Margin's time, and fix any checkpoint later.** Every estimate recomputes. A transcript match outranks the estimate, and all of the evidence is kept and shown in the Markdown export.
10. **A finished session is an ordinary Library item,** with Line up and Share as Markdown on it.

---

## 3. The Watch's two roles

1. **A remote for a phone session.** The Watch always knows the phone's session and joins it with no step. Raise, tap the complication, speak, double-tap to stop. It also offers Mark and End.
2. **A recorder of its own.** Start a session on the Watch with the phone in a bag or another room. Everything records and waits on the Watch, and files when the phone is back.

Its Home screen always says which of three states it is in, in words and with an icon shape, never colour alone:

1. "No session". Record still works, and makes a quick session.
2. "Budget meeting · on iPhone · about 12:40".
3. "Lecture · on Watch · 14:02".

When the phone can't be reached and the state is old, it says so: "as of 14:05".

Later, and only if you say yes to decision 2, the Watch can also record the whole session, so a Margin is a double-tap mark inside a recording that can't be lost.

---

## 4. The Watch–phone contract, in plain words

1. **Every Margin carries an id and a session id,** made by the device that records it. Nothing waits for the other device to hand out a number.
2. **The Watch keeps the audio until the phone says "filed".** Today it deletes its copy as soon as the transfer finishes, even if the phone then fails to store it.
3. **The phone stores the file first, then files it, then answers.** The answer is one of: filed, with the session's name and the estimated position; already filed; or rejected, with the reason in plain words. A rejected Margin stays on the Watch and is listed on the phone.
4. **Two lanes.** A fast one, when the Watch app is open, answers in a second or two and wakes the phone app. A sure one always runs as well, queues while out of range, and arrives later. The fast lane only speeds things up; it is never the only copy.
5. **"Hello" on opening.** The Watch lists what it still holds. The phone answers with the current session and any filed answers the Watch missed. That clears a stuck "waiting" list.
6. **How the phone picks a Margin's session,** in order:
   1. the session whose time span holds the Margin's time, after correcting for the Watch's clock;
   2. else the ended session the Margin names, labelled "after the session ended";
   3. else a new session with that id, because the Watch started it out of range;
   4. else a quick session.
7. **Filing twice is harmless.** The phone files each id once, so every retry is safe.
8. **Clocks are measured, not trusted.** Each fast round trip measures the Watch's offset from the phone. The evidence keeps the raw and the corrected time.
9. **Nothing changes in the `.spokenmargins` packet,** and new stored fields are additions the last shipped build still reads.

The four words the Watch uses, each with its own icon: **Recording**, **Saved on Watch**, **Waiting for iPhone** (after 15 seconds with no answer), **Filed in Budget meeting**. "Sent" never appears.

---

## 5. What failed in the first build, and what prevents it

You tried build `dbaa231`: "it said it was sent to the phone, but when I look at the phone, I don't see it."

| What failed | Why, in the code | What prevents it now |
| --- | --- | --- |
| No way to start or link a session | The Watch had only Record | Start session and End on the Watch; Home always shows the session state |
| It never checked for a session | The phone sent no session state the Watch used | The state board, refreshed by "hello" on every open, with "as of" when it is old |
| "Sent" when nothing showed | "Sent" meant the transfer was queued | The only success word is "Filed", sent back by the phone after it stores the Margin |
| The Margin was invisible | With no session open, the phone held it in a hidden inbox | The inbox goes. A Margin with no session makes a quick session you can see |
| The Watch could lose a Margin | It deleted its copy when the transfer finished | It deletes only after "filed" for that exact id |

The first slice below fixes all five, and its check repeats what you did on your wrist.

---

## 6. Platform facts

**Seen on your own devices (2026-10-22):**

1. During a Teams call on the iPhone, even muted, other apps can't use the phone's microphone.
2. During the same call, Voice Memos on the Watch recorded fine.
3. iOS Screen Recording captured YouTube's audio but not the call's. We don't capture other apps' audio anyway.

**Documented by Apple:**

1. Watch apps have no speech-to-text, so the phone transcribes everything. No Apple Intelligence is needed.
2. Double-tap works for apps on Series 9 and later, only with the screen awake. So it is "raise, then double-tap".
3. The phone's Live Activity appears in the Watch's Smart Stack on its own.
4. Watch-to-phone transfers queue and survive the app being suspended. A message from an open Watch app wakes the phone app; the phone can't wake the Watch app.
5. Watch-to-phone transfers can't be tested in the simulator, so every contract check runs on your real devices.
6. Watch "extended runtime" sessions are for workouts, mindfulness and the like, not note-taking, so we don't use them.

**Reported by Apple engineers on the developer forums, not promised in documentation:**

1. A Watch recording must start with our app in front, and can then carry on with the wrist down.
2. After a call or Siri interrupts it, it can't restart by itself; it needs one tap.

**Unconfirmed.** Each has a check below.

1. Our own Watch app recording during a phone call, and the phone filing it with its app in the background.
2. Whether a session started on the Watch can put the Live Activity on the phone's Lock Screen. Probably not until the phone app next comes forward; the design doesn't rely on it.
3. Whether the Watch can use AirPods that are connected to the phone without stopping what they play.
4. Whether the phone's microphone can start from the Dynamic Island while YouTube or Audible is in front, and what that app's sound does.
5. Whether the Control Center control and Siri start a session without opening the app.
6. Where a button on the Live Activity runs when pressed from the Watch.
7. Whether the app can tell a call holds the microphone before trying.
8. Whether App Review accepts recording in the background on the Watch.
9. How much battery an hour of Watch recording costs.

### Device checks, each under five minutes

A check needs the build named in brackets. Two can run on today's build.

1. **AirPods double-press during Audible** (today's build, 1 minute).
   1. Start a live session in Spoken Margins: plus, then Live Session.
   2. Play Audible through AirPods.
   3. Double-press an AirPod. Note which app reacts. We expect Audible, which means the headphone double-press can't add a Margin while another app plays.
2. **What Audible shows** (no build, 30 seconds). Open Audible's player and note whether the time is within the chapter or within the book. That sets the audiobook hint.
3. **Watch Margin during a call, phone app closed** (slice 1, 3 minutes).
   1. Close Spoken Margins on the phone from the app switcher.
   2. Join a Teams call on the phone.
   3. On the Watch, tap Record, say a sentence, tap Stop.
   4. Watch for "Filed in" on the Watch. Afterwards, find the Margin on the phone.
4. **Out of range** (slice 1, 3 minutes).
   1. Turn Bluetooth off on the phone.
   2. Record two Margins on the Watch. It shows "Waiting for iPhone", 2.
   3. Turn Bluetooth on. Time how long until both say "Filed".
5. **Lock Screen after a Watch start** (slice 1, 1 minute). Lock the phone. Start a session on the Watch. Wake the phone and see whether the Live Activity is there.
6. **AirPods on the Watch** (slice 1 test page, 4 minutes).
   1. AirPods on the phone, a phone call running. On the Watch's test page, tap Record for 10 seconds, then play it back. Note what the test page lists as the microphone.
   2. Hang up. Play Audible on the phone through the AirPods. On the test page tap "Try headphones" and record 10 seconds. Note whether Audible kept playing in your ears.
7. **Live Activity button from the Watch** (slice 4, 2 minutes). Start a session on the phone. On the Watch, raise, find the session in the Smart Stack, tap Mark. On the phone, the session's log says which device ran it.
8. **Recording from the Dynamic Island with another app in front** (slice 5, 4 minutes).
   1. Start a session. Play a YouTube video.
   2. Long-press the island, tap Record, speak, tap Stop. Note what YouTube's sound did, and whether it came back.
   3. Repeat with Audible, then once with the phone locked from the Lock Screen.
   4. Open the session. Each Margin should have your words.
9. **Start without leaving the app; Siri** (slice 5, 3 minutes).
   1. Add the Start session control to Control Center. Inside Teams, open Control Center and tap it. Teams should stay in front, and the island should appear.
   2. With Audible playing on AirPods, say "Add a Margin in Spoken Margins", then your thought. The Margin should hold your words, not Siri's.
10. **Recording resumes after a call** (slice 6, 3 minutes). Start whole-session recording on the Watch. Have someone call the phone; decline it. The Watch buzzes three times. Tap the notice to resume. The session shows the gap, marked "call".
11. **Battery** (slice 6, 1 minute of your time). Note the Watch's battery before and after a one-hour meeting with whole-session recording on. 15% or less is fine; over 25% limits it to short sessions.

---

## 7. Jobs, in taps

The full table, with the cost rules added for the wrist and for "did you leave the other app", is in [SITUATIONS.md, section 4](SITUATIONS.md#4-jobs-in-taps) and [WATCH.md, section 2.14](WATCH.md#214-every-job-with-its-cost). Run `python3 docs/design/live-sessions/job-table.py` to recompute it.

1. Every phone job is at or under the three-tap ceiling. Six jobs that are impossible today become possible.
2. No Watch job makes you look at the phone or leave the call.
3. The cheapest Margin is raise, tap the complication, speak, double-tap. With whole-session recording on, it is raise, double-tap, speak, double-tap, one-handed.

---

## 8. Build slices, in order

Each slice works on its own. Each has a check that takes you under five minutes.

### Slice 1: Know the session, and say "filed"

Fixes what failed on your wrist. Phone: the filing rule, quick sessions, the hidden inbox goes, store then answer. Watch: the three states, Start session and End, keep audio until filed, "hello", and a test page for check 6.

**Your check:**
1. With nothing running on the phone, open Spoken Margins on the Watch. It says "No session".
2. Tap Record, say "Testing, no session", tap Stop. Within a few seconds it says "Filed in a quick session". On the phone, the Library shows the quick session with that Margin.
3. On the Watch, tap Start session, then Meeting. Open the app on the phone: a live session is running.
4. Join a Teams call on the phone. On the Watch, record "Johnny was talking about the budget". It says "Filed in Meeting, about 1:10" or similar.
5. Tap End on the Watch. On the phone the session has ended, with its Margins.

### Slice 2: The phone session, cheaper and visible

Kind buttons that start at once, the "Where are you now?" field, checkpoints, the Live row at the top of the Library and the Margins tab, one-tap end for a meeting, "Where did you stop?" for audiobooks and paper books, the placing hint while you speak, and a plain message when a call holds the microphone.

**Your check:**
1. Library, plus, Audiobook. Type "ch 7 12:30". Two taps to running.
2. Speak a Margin. The hint shows while you speak.
3. Go back to the Library. The Live row is on top. Tap it, then End. Answer "Where did you stop?".
4. Start a Meeting and end it. One tap, no question.

### Slice 3: Line up afterwards

Line up from the session's item, and from a transcript file opened or AirDropped to the phone. The result is applied with Undo, and every piece of evidence is shown.

**Your check:**
1. AirDrop a Teams `.vtt` from your Mac to the phone and open it in Spoken Margins. Yesterday's meeting is picked.
2. Each Margin shows the matched words, the speaker and the score beside its estimate.
3. Tap Share as Markdown and read the export.

### Slice 4: One raise to a Margin

A complication that opens straight into recording, double-tap to stop, the Watch's Live Activity with Mark, and hints by kind. Runs check 7.

**Your check:** add the complication to your watch face. Start a session on the phone. With the wrist down, raise, tap the complication, speak, double-tap. It says filed. Raise again, tap Mark in the Smart Stack. On the phone: one Margin, one Mark.

### Slice 5: Margins without leaving the other app, on the phone

The Live Activity's Record, Mark and End, the Control Center start control, and the Siri phrases. Runs checks 8 and 9, and they are the check.

### Slice 6: Whole-session recording on the Watch

Only if decision 2 is yes. One-minute pieces kept until the phone has them, double-tap marks, the consent screen, and one tap to resume after a call. Runs checks 10 and 11.

**Your check:** start an Other session on the Watch with whole-session recording on. Play a talk on the phone's speaker for three minutes. Double-tap, say a Margin, double-tap. Do check 10. End. On the phone: one recording, one Margin with its transcript, one gap.

### Slice 7: Siri on the Watch

An App Shortcut that opens the Watch app into recording. Siri on the Watch needs a one-time opt-in, so this is less magical than on the phone.

**Your check:** accept the Siri prompt once. During a session, raise and say the phrase. Speak, stop, see "Filed".

### Slice 8: Raise-to-mouth, watching only

Logs "would have marked here" for two weeks while you keep double-tapping. A page on the phone shows hits, false triggers and misses per hour. It switches on only at one false trigger an hour or fewer, and 8 hits in 10 marks.

**Your check:** after a session, open the page and read three numbers.

---

## 9. Today's code: stays, changes, goes

**Stays:**

1. The live session model (`LiveSession`, `LiveSessionMargin`, `ElsewhereKind`) and `LiveSessionFileWorker` for all its disk work.
2. The transcript parsers and the line-up (`TranscriptAlignment`, `LiveSessionAlignment`), with every piece of evidence kept.
3. The Markdown export, and the record that makes a later line-up possible.
4. The Live Activity and its Mark button, and the Mark inbox's race-free keys.
5. The Watch's recorder (AAC, the record category), and the phone's step that moves a received file into the app's container.
6. A finished session saved as an ordinary Library item.

**Changes:**

1. Start: four kind buttons that start at once; the position becomes a field on the running screen.
2. Start and end positions become a list of checkpoints. A session saved by an earlier build reads as two.
3. Ending: a meeting ends in one tap. Only an audiobook or paper book asks where you stopped.
4. Line up moves to the session's item, and gains an entry from an opened transcript file.
5. Filing: the rule in section 4, point 6. `LiveSessionWatchMatch`'s fallback to "the most recently started session" goes.
6. The Watch keeps each recording until the phone says filed, instead of deleting it when the transfer finishes.
7. The phone answers each Margin, and sends a fuller session state to the Watch.
8. Lock Screen Marks taken with no session file into a quick session. Today they are thrown away.
9. The running session is reachable from the Library, the Margins tab and the Live Activity.

**Goes:**

1. The hidden Watch inbox (`fileWatchInbox`). Anything left in it files by the new rule.
2. "Sent to your iPhone" on the Watch.
3. "Save as Notes" and "Discard Session" as steps. Deleting uses the item's normal delete and Undo.
4. The full-screen cover inside the Add sheet as the only way back to a running session.

---

## 10. Decisions for the owner

Each takes one word. My pick is first.

1. **A Margin taken with no session running starts a quick session.**
   - Pick: **yes**. It is named by its time, later Margins within 30 minutes join it, and you can rename it or move its Margins.
   - Alternative: a "Not in a session" list at the top of the Margins tab. Cost: you file every one by hand.
   - Wrong if: in your first two weeks you move or delete more quick sessions than you keep.
2. **Build whole-session recording on the Watch, off by default, with one consent tap each session.**
   - Pick: **yes**. The tap says "This records everyone your Watch can hear", with buttons "Everyone agreed, record" and "Margins only". The recording stays on your devices and never goes in a shared packet.
   - Alternatives: **remember** it per kind (lectures and audiobooks only; cost: less thought before recording a room), or **no** (cost: no recording to fall back on, and raise-to-mouth can't happen, because it needs that recording).
   - Wrong if: you turn it on nearly every session and the tap annoys you. Then remember it for lectures and audiobooks, never for meetings.
3. **Ending a meeting makes the Library item at once, and a line-up applies at once with Undo.**
   - Pick: **yes**. No "Save as Notes" step, and no review before a line-up is applied.
   - Alternative: today's end card, and a review step before saving. Cost: two or three more taps every meeting.
   - Wrong if: you tap Undo on more than one of your first five line-ups.

## 11. Defaults taken

Engineering calls, made so the work can go on. Veto any by number.

1. **One session at a time.** If the phone and the Watch each start one while apart, the later one ends the earlier one at that moment, and the earlier item says so. *Review: WATCH.md kept the earlier session and moved the other's Margins into it; that moves Margins by guesswork.*
2. **Filing by time first, then by the Margin's session id** (section 4, point 6). *Review: the two drafts disagreed, time only against id only, and each alone misfiles a case the other gets right.*
3. **Named sessions end themselves after 8 hours; quick sessions after 30 quiet minutes,** on both devices. *Review: WATCH.md closed every Watch session after 30 minutes with no Margin, which would end a quiet meeting.*
4. **Four kinds on both devices:** Meeting, Audiobook, Paper book, Other (lecture, video). *Review: the Watch draft had Lecture and no Paper book.*
5. **The Watch starts a session with one kind tap; its position is a crown field afterwards,** as on the phone.
6. **The Watch uses its own microphone, even with AirPods on the phone and no call,** until check 6 shows the AirPods can be used without stopping what they play. Then it tries the headphones, as you suggested. *Review: WATCH.md's pushback rests on how Bluetooth works, but nothing has been observed, so check 6 moves into the first Watch build and decides it.*
7. **The Watch's Live Activity shows Mark only.** Tapping it opens the Watch app to Record. The phone's shows Record, Mark and End.
8. **The design doesn't rely on a Watch start putting the Live Activity on the phone** (check 5). The Watch shows the session until the phone app comes forward.
9. **Double-tap marks a span (start and stop)** in whole-session recording, closing itself after 10 quiet seconds.
10. **Recording in the background uses the audio background mode,** explained in the Notes for Review. If review refuses it, recording runs only while the app is in front.
11. **Raise-to-mouth's bar:** one false trigger an hour or fewer, and 8 hits in 10, after two weeks of watching only.
12. **A one-time note on the first spoken Margin in a meeting:** "Other voices may be in the background. Headphones keep them out." The question of background voices in short clips goes on the attorney list. *Review: SITUATIONS.md had this as an owner decision; it is one line and reversible.*
13. **"Muted in the call?" shows above the hint** while recording in a meeting. No app can read another app's mute state.
14. **The Watch's 15-second wait before "Waiting for iPhone",** and its retry every 10 minutes for anything not yet answered.
