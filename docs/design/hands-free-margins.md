# Hands-free Margins: say it without touching the phone

*Spoken Margins · design proposal · 4 October 2026 · written against `next` at `1744dff`*

Mockups and code are not part of this. Nothing here is built or tried on a device. Claims about the current app cite `file:line` on `next`. Claims about what iOS allows are marked **(spike)** wherever they still need proving on your phone.

---

## In one minute

1. **Today, a spoken Margin needs the screen.** Every way to start one opens the app, and the only way to finish one is the Save button on the recording screen. The Lock Screen mic button is a link that unlocks the phone and opens the app. AirPods and car buttons can't start or stop a Margin.
2. **The big idea is "press, talk, keep going".** You use a button you already have: a double-press on your AirPods, the steering-wheel skip button, the Action button, or "Hey Siri, Margin". A tone tells you it's listening. You talk. When you stop talking, a second tone tells you it's saved, the episode backs up three seconds and carries on. You never look at anything.
3. **Saying nothing still saves something.** If you trigger a Margin and stay quiet, you get a **flag** at that spot instead of a Margin. A flag is a silent dog-ear for when you can't talk, such as when other people are in the car. Later, a hands-free **replay** walks you through your flags and Margins, and lets you answer each flag out loud.
4. **The first job is a one-day test on your phone.** Nobody has proved yet that iOS lets the app start the microphone while the phone is locked in your pocket. That is the one thing that can sink the design, so it comes before anything else.
5. **I found one real bug along the way.** If a phone call or Siri interrupts a Margin, the recorder stops silently and the screen still says "Recording" (section 2, pain point 6). It's worth fixing now whatever you decide here.

---

## 1. What it should feel like

Three moments this design is built for.

**Walking, AirPods in, phone locked in a pocket.**
The guest says something you disagree with. You double-press your AirPods. The podcast pauses and you hear a short rising tone. You say "That's not what the 1970s data showed. Check the Piketty chart." You stop talking. After about two seconds you hear a falling tone. The podcast backs up three seconds, so you catch the end of the guest's sentence again, and carries on. Your hand never left your side.

**Driving, phone on the mount, no CarPlay.**
You press the skip-forward button on the steering wheel. This is the same signal as an AirPods double-press, so the same thing happens, and the car's microphone records you. If your kids are talking and you'd rather not, you press it and say nothing. Six seconds later you hear a soft double tick, and that spot is flagged.

**Washing up, phone on the counter, hands wet.**
"Hey Siri, Margin." Siri pauses the episode and you hear the tone. You talk, stop, and it carries on.

**That evening.**
At the end of the episode, the recap row offers **Replay today's Margins**. Each one plays the ten seconds of the episode before it, then a soft chime, then your own voice. When it reaches a flag, it plays the lead-in and then the rising tone, so you can say what you meant now or stay quiet to skip. You can do the whole replay with the phone in your pocket, too.

---

## 2. What exists today, and where it hurts

### The current flow

| Step | What happens today | Where |
|---|---|---|
| Start | Tap Add a Margin on the playback screen, the mic in the mini player, or the Lock Screen Live Activity mic. | `PlaybackScreen.swift:290`, `Gate1RootView.swift:329`, `Gate2LiveActivityWidget.swift:278` |
| Lock Screen | The Live Activity mic is a `Link` to a `spokenmargins://` URL, not a button that runs in place. It asks you to unlock and brings the app forward. | `Gate2LiveActivityWidget.swift:279` |
| Source | Paused (not ducked). The anchor is saved first. | `SessionEngine.swift:1256-1295` |
| Microphone | The session switches to `playAndRecord` with Bluetooth headset input allowed, so AirPods or a car's microphone are used automatically. | `AudioAdapters.swift:3304-3310` |
| While recording | A full-screen recording view with a timer. Every remote command (AirPods, car, Lock Screen play/pause) is dropped. | `Gate1RootView.swift:19`, `Gate1AppModel.swift:9596-9599` |
| Finish | Only the on-screen Save & resume button (in the bottom row where Add a Margin was, with Cancel small on its left; #148). | `ExperienceRecordingScreen.swift` (`finishControl`) |
| Resume | At exactly the saved spot, with no step back. | `SessionEngine.swift:1666-1669` |
| Afterwards | Transcribed on the device in the background. Podcast anchor evidence is captured either side of the pause. | `Gate1AppModel.swift:12781`, `SessionEngine.swift:1631-1656` |
| Later | The Margin appears on the timeline. "Play this moment" plays a 30-second lead-in, then the Margin, then carries on. | `MarginMoment.swift:26-60`, `MarginMomentConductor.swift` |

### Pain points

1. **You must look and touch to start.** No physical button, Siri phrase, Action button or Control can start a Margin. The Live Activity mic unlocks the phone. That's the worst case on a walk, and unsafe in a car.
2. **You must look and touch to finish.** Nothing but the on-screen Save ends a Margin, so even a Margin started some other way would trap you on the screen.
3. **There's no sound for any of it.** Recording starts and stops silently, with no tone and no haptic. Without looking you can't tell whether it's recording, which matters most for someone who listens rather than reads.
4. **There's no way to say "not now, but remember this".** Bookmarks are parked as #117. In a car with passengers, the only choices are to talk aloud or lose the thought.
5. **You come back mid-word.** Resume is exact, so after a Margin you land in the middle of a sentence. The early prototype called for a "reorienting rollback" (`docs/prototype-lessons.md:94-98`). The phone never got one.
6. **Interruptions corrupt a Margin silently.** There's no interruption or route observer while recording. A phone call or Siri mid-Margin stops the recorder, the screen still says "Recording", and Save keeps a cut-off file. *(Read from the code; not yet reproduced on a device.)*
7. **There's no length limit.** A Margin started by accident in a pocket would record until you noticed.
8. **Watch capture is switched off.** Watch-owned recording exists but isn't in `project.yml`, and phone-side Watch recording is hard-rejected (`Gate1AppModel.swift:9464-9469`) because the phone couldn't reliably start recording while locked (`docs/gate3-watch-tethered-closeout.md:28-30`). That is the same risk this design has to retire first.
9. **Replay is a screen activity.** Hearing your Margins again means opening the timeline and tapping each one.

---

## 3. Three directions

### A. Press, talk, keep going *(recommended spine)*

Any trigger you already carry starts a voice Margin without the screen. Tones mark the start and the save. Silence ends it. The source backs up a few seconds and continues. Saying nothing makes a flag.

- **Why it's strong:** it uses hardware people already have (AirPods, steering wheel, Action button, Siri) and needs nothing new to learn beyond "double-press, talk".
- **Cost:** medium. Most of it is plumbing into code that exists: the remote commands, the Live Activity intents and the recorder.
- **Risk:** whether iOS lets the app start the microphone from the background while locked **(spike)**. If it doesn't, the Lock Screen and Siri paths still work through Apple's dedicated recording intent (section 5), and only the headphone path is in doubt.

### B. Just talk (open mic)

There's no button at all. During a hands-free session the app keeps the microphone open and listens for your voice. When you start talking over the podcast it pauses and records you. It feels like talking to a friend in the passenger seat.

- **Why it's tempting:** zero gestures. It's the purest version of "conversational listening".
- **Why not now:**
  - Keeping AirPods' microphone open usually forces them into call-quality audio for the whole listen, so the podcast would sound like a phone call. iOS 26 adds a high-quality AirPods recording option that might avoid this on newer AirPods **(spike)**.
  - Passengers, radio, the podcast itself through car speakers, and street noise would all trigger it falsely.
  - The orange microphone dot stays on the whole time, and the battery cost is higher.
- **Keep as:** a later, opt-in "conversation mode", but only if the spike shows the AirPods audio holds up.

### C. Flag now, talk later

Hands-free capture is always a silent flag (one press, no pause, no voice). The talking happens later in a calm replay, which walks you through each flag with its lead-in and records your answer.

- **Why it's strong:** it's the safest option in a car, works with people around, and never interrupts the episode.
- **Why not alone:** the thought you had is gone by the evening. The voice in the moment is what makes this app different from a bookmark.
- **Keep as:** the "say nothing" branch of A, plus the replay.

---

## 4. Recommended: A, with C's flags and a hands-free replay

### 4.1 The gestures

One rule covers every trigger: **trigger → tone → talk → silence → tone → carry on.**

| Where you are | Start | Finish early | Cancel |
|---|---|---|---|
| AirPods / wired headphones | Double-press (the "next track" signal), once the setting is on | Not possible: with the microphone open the headset is in call mode, so a press is its mute. Stop talking, or use the screen. | Stay silent: it becomes a flag. Then delete it later. |
| Car, Bluetooth only | Steering-wheel skip-forward (the same signal) | Play/pause on the wheel | Same as above |
| Car, CarPlay | The **Margin** button on the CarPlay Now Playing screen, or Siri | The same button (it shows a stop icon) | Same |
| Phone locked | The Live Activity mic (runs in place, no unlock **(spike)**), the Action button, or a Lock Screen control | The same button again | Same |
| Hands busy | "Hey Siri, Margin in Spoken Margins" | Stop talking | Same |
| Apple Watch (later, #96) | A Watch button or the complication | Tap again | Same |
| On screen | Add a Margin, as today | Save & resume (moving to the bottom in #148) | Cancel, as today |

**Owner's call (2026-10-30, replaces the 2026-10-17 default):** double-press keeps skip forward by default, and **Add a Margin** is a setting he turns on ("Headphone double-press: Skip forward / Add a Margin"). He tested it on his phone: a double-press adds a Margin, but no headphone press ends one (a single press only makes the call-mode mute "ba-dump"), and he thinks a default-on double-press would confuse people (#2957). Triple-press stays as skip back. Press-and-hold is reserved by iOS (Siri and noise control), so the app can't use it.

### 4.2 The recording, step by step

1. **Trigger.** The source pauses and the anchor is saved, exactly as today (`SessionEngine.swift:1256`).
2. **Start tone.** A short rising two-note tone plays *before* the microphone opens, so it isn't recorded. A light haptic plays on a Watch, later.
3. **Listening window.** You have **6 seconds** to start talking.
   - If you don't, the falling double tick plays and a **flag** is saved at the anchor. The source carries on.
4. **Talking.** You talk as long as you like, up to **5 minutes**. A soft tick at 4:30 warns you.
5. **End on silence, or on a command.** About **2.5 seconds** of quiet after you've spoken ends it. A play/pause or skip-forward command ends it immediately, but not from headphones: on the owner's phone, with the microphone open, a headphone press only toggles the call-mode mute and does not reach the app as an end command (tested 2026-10-30). A steering-wheel button is untested. When one does arrive, it ends it immediately and keeps what you said, including quiet words that stayed under the speech threshold, the same as the silence timer. Only a Margin with nothing said becomes a flag. Saying "end margin" or "stop margin" aloud is a possible later option; it needs on-device speech recognition while recording, so it is not built yet.
   - Before speech crosses the threshold, a level more than **4 dB above the measured room** counts as an attempt to talk and is kept. Exactly 4 dB or less stays a flag. This rule is the same for an end command and the silence timeout.
6. **Save tone.** A falling two-note tone plays. The Margin is saved before the tone plays, so the tone means "it's safe".
7. **Rejoin.** The source **backs up 3 seconds** (a podcast) or **to the start of the sentence** (an article), then plays.
8. **Afterwards.** Transcription and anchor evidence run exactly as today.

**The first three hands-free Margins talk you through it:**
- At the start: "Margin. Talk now, then pause to save."
- At the end: "Saved at twenty-one minutes."

After the third, it's tones only. This teaches the gesture without a manual. A setting keeps the spoken version on permanently for anyone who wants it.

All numbers above are single constants, so you can tune them on the phone.

### 4.3 What can go wrong, and what happens

| Situation | Behaviour |
|---|---|
| Phone call or Siri arrives mid-Margin | Keep what was recorded if it has at least a second of speech. Mark it "cut short". Play the save tone when the call ends. Resume the source only if iOS says to resume. |
| AirPods taken out mid-Margin | Finish and save, then leave the source paused, so the episode never starts blasting from the phone speaker. |
| Microphone permission never granted | iOS can't ask on the Lock Screen. Play a low "couldn't record" tone, save a flag instead, and say once: "Open Spoken Margins to allow the microphone." |
| Nothing playing or paused | Siri says "Nothing's playing in Spoken Margins." Headphone presses don't reach the app at all then, which is fine. |
| "Mix with other audio" is on | Spoken Margins doesn't own the headphone buttons in that mode (`Contracts/docs/recovery-mvp.md`, Active Boundary). Siri, the Lock Screen and the Action button still work. Settings says so next to the double-press option. |
| Double-press arrives twice (a bounce) | The same guard window as #148 (0.5 s) ignores the second. |
| Accidental trigger in a pocket | Silence makes only a flag, and the 5-minute cap bounds any noise recording. Flags are one swipe to delete. |
| App killed while recording (memory) | The audio so far must survive. Today the file is an AAC `.m4a` that may not be readable if never finished **(spike)**. Record in a crash-safe format and convert on save. |
| Streamed podcast | Anchor evidence still runs. The 3-second step back must not confuse the post-resume evidence sample (`SessionEngine.swift:1636-1646` arms it from the anchor time). Test this. |
| Very noisy street or car | The silence detector adapts to the background level measured in the first half-second. If it still can't hear a pause, the press-to-finish and the 5-minute cap still work. |
| Transcription can't run in the background | Queue it, and finish it the next time the app opens or the phone is charging. The Margin plays by voice meanwhile. |

### 4.4 Safety while driving

- **No step needs the screen.** Every action has a sound, and nothing asks you to read or choose.
- **CarPlay shows one button,** Margin, on Apple's standard Now Playing screen. There are no lists and no text to read while moving. Replay and flag review are blocked on CarPlay while the car is moving; Siri can start the replay as audio only.
- **The app never asks a question you'd have to answer by tapping.** Silence is always a safe answer (it makes a flag).
- **Tones are short and distinct, and never louder than the episode.**

### 4.5 Accessibility

- **Built for listening first.** Every state has a sound. The spoken coaching covers the first uses and can stay on. Nothing depends on reading.
- **Colour-blind safe.** Today the Live Activity shows recording with a red indicator (`Gate2LiveActivityWidget.swift:116, :192`). Replace it with a shape and a word: a pulsing ring plus "Recording 0:12", and a checkmark plus "Saved" afterwards. Flags use a folded-corner shape, distinct from the Margin diamond, so no colour carries meaning on its own.
- **VoiceOver.** Labels read, for example, "Add a Margin, double-press your headphones or tap here", then "Recording, 12 seconds, pause to save".
- **Motor.** No precise taps are needed. Every hands-free trigger is a whole-button press or a phrase.

### 4.6 Playing it back later

1. **On the timeline,** hands-free Margins look like any other Margin. A small "said on the go" note marks the ones a trigger started, so you know why the transcript is still pending.
2. **Flags** appear on the timeline and the split-track bar (#428) as folded-corner marks. Tapping one plays its lead-in and offers Record or Write.
3. **Replay today's Margins (new).** This is offered from the end-of-item recap row (`PlaybackScreen.swift:240`) and by Siri: "Replay my Margins in Spoken Margins". It plays, in order:
   - For each Margin: 10 seconds of the source before it, a chime, then your voice.
   - For each flag: the same lead-in, then the start tone. You talk, which turns the flag into a Margin, or you stay quiet, which skips it.
   - **Double-press during a Margin** records a follow-up to it. That becomes a reply once replies exist (#203, #472).
   - It's built on `MarginMomentSequence` (`MarginMoment.swift`) with a shorter lead-in, not a new player.
4. **"Play this moment"** keeps working as it does now.

### 4.7 What I deliberately left out

- **Ducking instead of pausing.** You'd be recording over the episode, and the car microphone would pick it up.
- **Voice commands inside a Margin**, such as saying "cancel". Live speech recognition while recording adds cost for little gain over "stay quiet".
- **Sending flags or hands-free provenance in shared packets.** That's covered in 5.4.

---

## 5. What it needs technically

### 5.1 The spike that decides everything

**Can the app start recording while the phone is locked and the app is in the background?** Test it on your phone, for each trigger:

| Trigger | Mechanism | Expectation (to prove) |
|---|---|---|
| AirPods double-press during playback | `MPRemoteCommandCenter.nextTrackCommand` handler switches the active session from `.playback` to `.playAndRecord` and starts the recorder | Uncertain. May fail with `cannotStartRecording`. The Gate 3 Watch attempt failed, but that started from a cold background wake, not from an already-playing session. |
| Live Activity mic | An intent conforming to `AudioRecordingIntent` and `LiveActivityIntent`, running in the app's process | Apple's intended path for starting a recording from the Lock Screen. As of iOS 18, a Live Activity must stay up while recording, which this app already has. Whether a locked phone asks for Face ID first needs checking. |
| Action button / Lock Screen control | A `ControlWidgetButton` running the same intent | The same as the Live Activity, and how Voice Memos does it. |
| Siri | An App Shortcut running the same intent, after Siri's own audio ends | Likely works. The timing of Siri releasing audio needs measuring. |

Also measure on the same day:

- AirPods audio quality while the microphone is open, with and without iOS 26's high-quality AirPods recording option.
- How quickly the car's microphone takes over on your car's Bluetooth.
- Whether a half-written `.m4a` survives the app being killed.

**If the headphone path fails,** the fallback is to start every hands-free Margin through the recording intent. In that case the remote-command handler would ask the system to run the intent instead of starting the recorder itself **(spike)**. If even that fails, the double-press makes a flag, and only the Lock Screen, Action button and Siri can record. That's still a big step up from today.

### 5.2 New pieces, and where they live

- **`HandsFreeMarginCoordinator`, in SessionKit, host-tested.** A small capture state machine with these states: idle → start tone → listening window → speaking → trailing silence → saving → rejoining.
  - **Inputs:** a trigger and where it came from, voice-level samples, a clock, interruption and route events.
  - **Outputs:** commands. It does not own playback. It calls the existing `SessionEngine` begin, finish and cancel. That keeps it clear of AGENTS.md's ban on another playback state machine.
  - **In `Gate1AppModel`:** one thin call site.
- **Silence detection.** Start with the recorder's built-in level metering (`AVAudioRecorder.averagePower`), with the threshold learned from the first half-second. It's pure arithmetic on samples, so it's host-testable. `InterjectionSilenceDetector` already exists for trimming files at share time and may share thresholds.
- **Recorder robustness** (`SystemRecordingClient`, `AudioAdapters.swift:3195`):
  - observe interruptions and route changes while recording, and save the partial;
  - add the 5-minute cap;
  - use a crash-safe file format.
- **Triggers:**
  - Register the Margin action on `nextTrackCommand` in both registrars (`Gate2CompactControlController.swift:1111-1136` and `AudioAdapters.swift:2873-2921`).
  - Let play/pause through while recording, as "finish". Today `Gate1AppModel.swift:9596` blocks it.
- **Intents:**
  - One `StartMarginIntent` conforming to `AudioRecordingIntent` and `LiveActivityIntent`.
  - It's reused by the Live Activity (replacing the `Link`), a Control, and an `AppShortcutsProvider` with phrases such as "Margin in Spoken Margins" and "Add a Margin in Spoken Margins".
  - The existing App Group command queue (`Gate2LiveActivityIntents.swift`) is the delivery path.
- **Tones.** Four tiny bundled sounds (start, saved, flag, couldn't), played through the active session before the microphone opens. The 880/1175 Hz shared-Margin chime (`Gate1AppModel.swift:7443-7470`) is the model to follow.
- **Rejoin.** An optional step-back on resume in `SessionEngine.finishInterjection`, which today resumes exactly by design (`:1666`): 3 seconds for media, previous sentence start for text.
- **Replay queue.** A list of Margin moments fed through the existing `MarginMomentConductor` with a 10-second lead-in.

### 5.3 CarPlay

- The app needs Apple's CarPlay audio entitlement. You request it from Apple, which is an outward-facing step only you can take.
- With it, a minimal `CPNowPlayingTemplate` with one custom Margin button is enough.
- `Contracts/docs/recovery-mvp.md` currently says "do not add … dedicated car UI", so this needs your OK to change the boundary.
- **Without CarPlay,** the steering-wheel path in 4.1 covers most cars already.

### 5.4 Data, packets and Build 29

- **Hands-free Margins are ordinary spoken Margins.** No packet change and no new manifest capability.
- **Flags must not be a new kind of Margin.** `InterjectionCaptureKind` is a plain enum with only `audio` and `written` (`Models.swift:101-104`). Build 29 would fail to decode an unknown value, which is exactly the co-op trap AGENTS.md warns about.
  - Keep flags in their own small local table.
  - Never export them in a packet.
  - Check them with the `ShippedReader` copy of the Build 29 reader in `Packages/SessionKit/Tests/ShippedReader/`.
- **Where a Margin came from** (headphones, Siri, Lock Screen) is local-only. Put it in diagnostics or a new optional field that Build 29 ignores, the way `replyTo` is handled (`Models.swift:1288`). Don't export it.

---

## 6. Slices to build it

In order. Each is S or M and can be its own issue. "Where" follows the project's conventions.

| # | Slice | Size | Where | Waits on |
|---|---|---|---|---|
| 0 | **Device spike:** the table in 5.1 on your phone, with AirPods, car Bluetooth and the speaker, phone locked and unlocked. Output: a filled table and a go/no-go per trigger. | S | `where:mac` + owner phone | nothing |
| 1 | **A call or Siri mid-Margin no longer corrupts it:** save the partial, mark it, and resume correctly. AirPods removed: save and stay paused. Host tests with injected interruption and route events. *(A bug today, independent of the rest.)* | S | cloud (SessionKit) | nothing |
| 2 | **`HandsFreeMarginCoordinator` in SessionKit:** all states, a fake clock, voice-level input, host tests for flag, save, cap, interruption and bounce. No UI. | M | cloud | nothing |
| 3 | **Silence detection and the 5-minute cap** wired to the real recorder level meter. Crash-safe recording format. | M | Mac | 2 |
| 4 | **Tones and the first-three-uses spoken coaching.** A setting to keep the coaching on. | S | cloud + Mac build | 2 |
| 5 | **Headphone and steering-wheel trigger:** a setting (off by default) makes double-press start a Margin; a headphone press can't finish one (#2957). | M | Mac | 0, 2, 3, 4 |
| 6 | **Rejoin step-back** (3 s or previous sentence), checked against podcast anchor evidence on a stream. J3's wording "resumes where it paused" gets updated to "a few seconds before". | S | cloud (SessionKit) | 2 |
| 7 | **Live Activity mic runs in place** through `StartMarginIntent`, with a colour-blind-safe recording state (ring + word). | M | Mac | 0, 2 |
| 8 | **Siri:** "Margin in Spoken Margins", "Replay my Margins in Spoken Margins". | M | Mac | 7 |
| 9 | **Action button and Lock Screen control** using the same intent. | S | Mac | 7, owner OK on the boundary |
| 10 | **Flags:** local table, timeline and bar marks, one-swipe delete, Build 29 compatibility test, never exported. Revives #117. | M | cloud + Mac | 2 |
| 11 | **Replay today's Margins:** recap-row entry, flags as prompts, double-press to follow up. | M | Mac | 10, `MarginMomentConductor` |
| 12 | **Transcription catch-up** in a background task, for Margins said with the phone locked. | S | Mac | nothing |
| 13 | **CarPlay** Now Playing with a Margin button. | M | Mac | owner requests the entitlement; boundary OK |
| — | **Watch capture (#96)** reuses the coordinator and tones. | later | | 2, 4 |

**Smallest useful release:** slices 0, 1, 2, 3, 4 and 5. That's "double-press, talk, it's saved", without the Lock Screen, Siri or flags review. Slices 6, 7 and 10 make it complete, and 8, 9, 11, 12 and 13 round it out.

Related issues: #96, #117, #121 (closed into #96), #126, #148, #203, #428, #472.

---

## 7. Decisions only you can make

1. **Double-press means Add a Margin by default.** Decided 2026-10-30: no. It is a setting that is off by default, because a default-on double-press would confuse people. Triple-press still skips back.
2. **Step back 3 seconds when a Margin ends.** My pick: yes, for every Margin, not only hands-free ones. It changes the wording of J3.
3. **Widen the product boundary** in `recovery-mvp.md` to allow a Control (Action button and Lock Screen) now, and CarPlay later. My pick: the Control now. Request the CarPlay entitlement only after the spike shows recording works with the phone locked.

None of these blocks slices 0 to 4.
