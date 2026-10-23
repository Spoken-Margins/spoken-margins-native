# The Watch, designed from the wrist

Written 2026-10-23 for #2487 and #2481, answering `BRIEF.md`. A second designer covers the situations and the iPhone side in `SITUATIONS.md`. This file covers the Watch, and the contract between the Watch and the phone. Nothing here is built. Each platform claim says whether it is confirmed and gives its source; the sources are listed at the end.

---

## In one minute

1. **The Watch has one job: never lose what you said, and tell you the truth about where it went.** The first build failed both. It said "sent" when it only meant "queued", it never knew whether a session existed, and a Margin with no session waited in a hidden inbox.
2. **The Watch always knows the session.** It shows one of three states: no session, a session running on the iPhone, or a session running on the Watch. Starting a session works from either device, and the Watch joins a phone session on its own, with no step.
3. **"Filed" is the only success word.** The Watch says "Filed in Budget meeting, about 12:40" only after the phone has written the Margin into a session and answered. Until then it says "Saved on Watch". The Watch keeps the audio until the phone says filed.
4. **No Margin is ever homeless.** A Margin recorded with no session starts a session for itself, visible in the Library. The phone never parks a Margin out of sight.
5. **Three platform facts shape everything.**
   - Recording must *start* while our app is in front, but once started it can carry on with the wrist down (Apple engineers, on the developer forums). After a call or Siri interrupts it, it cannot restart by itself. So the safety net closes the audio safely and asks for one tap to resume.
   - Double-tap (`handGestureShortcut`) works on Series 9 and later, but only with the screen awake. So it is "raise, double-tap", never a blind gesture.
   - watchOS has no speech-to-text API for apps (neither `SpeechAnalyzer` nor `SFSpeechRecognizer` lists watchOS). All transcription happens on the phone.
6. **The first slice fixes exactly what failed on the owner's wrist:** session state on the Watch, start and join, filed-not-sent, and no hidden inbox. His check takes five minutes.

---

## 1. Platform facts

Each fact has a status:
- **Confirmed**: Apple documentation says so.
- **Reported**: an Apple engineer said so on the developer forums, or several developers report it. Not a documented promise.
- **Unconfirmed**: my inference, or nobody says. Each has a device check.

### 1.1 Microphones: the Watch's own, and headphones

1. **The Watch's built-in microphone works during an iPhone call.** Status: confirmed by the owner's own test on 2026-10-22 (Voice Memos on the Watch during a Teams call). Our app has not been tried in the same call yet; that is in slice 1's check.
2. **A Watch app can ask for a Bluetooth headset microphone.** Status: confirmed as an API. `AVAudioSession`'s `allowBluetoothHFP` option lists watchOS 11 and later, for the record and play-and-record categories. Whether AirPods actually appear as an input on the Watch is unconfirmed.
3. **During an iPhone call with AirPods, the Watch cannot use the AirPods' microphone.** Status: unconfirmed, inference. The call owns the AirPods' microphone on the phone, the same way it owns the phone's own microphone. The Watch's built-in microphone hears the wearer's voice and the room. It hears the other people in the call only if the phone is on speaker. With AirPods in, they are inside the wearer's ears, so the Watch should hear only the wearer.
4. **With no call, taking the AirPods for the Watch's microphone would probably pull them away from the phone.** Status: unconfirmed, inference. Headphones have one active route. If the Watch takes them as a hands-free input, the YouTube or Audible audio playing from the phone is likely to move or stop. That would break the very thing the listener is listening to.
5. **Device check for 3 and 4 (10 minutes):**
   1. AirPods connected to the iPhone, a phone call running. A test build lists `availableInputs` on the Watch and records 10 seconds. Write down which inputs are listed and play back the recording.
   2. AirPods connected to the iPhone, Audible playing, no call. The same build asks for `allowBluetoothHFP` and records. Write down whether Audible keeps playing in the AirPods, and what input was used.

### 1.2 Recording in the background, and for a long time

1. **Recording must start while our app is in front.** Status: reported. An Apple frameworks engineer: "Audio recording must begin when the app is in the foreground." (forum thread 751866).
2. **Once started, recording carries on with the wrist down.** Status: reported. Same engineer, another thread: recording "can then continue once the app moves to the background" (thread 750432). A DTS engineer says apps that start a recording in the foreground may "continue recording indefinitely in the background" (thread 776949). Apple's own background-execution page names only workouts, audio playback and location, so this is not written down as a promise.
3. **After an interruption, recording cannot resume by itself.** Status: reported. "Recording cannot be resumed when the app is in the background on watchOS. It must be a user-initiated event while the app is in the foreground." (thread 750432). Calls and Siri are the interruptions named. During a phone meeting, a *second* incoming call is the realistic case.
4. **While recording, our app stays the app on screen when the wrist comes up.** Status: reported. A DTS engineer lists "audio-recording" with workouts, location and background audio as sessions that keep an app frontmost and on Always On. This matters: during a recording session, a wrist raise lands in our app, so double-tap reaches our button.
5. **Extended runtime sessions do not fit.** Status: confirmed. Their types are self care (10 minutes), mindfulness (1 hour), physical therapy (1 hour) and smart alarm (30 minutes). Apple says to pick the type "based on the app's intended use — not based on the features that the session provides." None of them is note-taking. A workout session is for workouts. Using either for meetings would be the wrong use, and App Review guideline 2.5.4 says background services may only be used for their intended purposes.
6. **App Review and the audio background mode.** Status: unconfirmed. On iOS, at least one app was rejected because reviewers read the audio mode as playback only (thread 776949). The DTS engineer's reading is that recording in the background is allowed when the listener started it. My pick: use the audio background mode, show a clear always-visible recording state, and explain the feature in the Notes for Review. If review refuses it, fall back to "recording while the app stays in front", which loses only the wrist-down case. Check: the first TestFlight external review of a build with continuous recording.
7. **Battery.** Status: unconfirmed. Apple publishes no figure for microphone recording. Device check: from a full charge, run a 60-minute continuous Watch recording with the wrist mostly down, then note the battery percentage. My bar: 15% or less per hour is fine for a one-hour meeting; more than 25% makes continuous recording a feature for short sessions only.
8. **Storage.** At our settings (AAC, 22 kHz, mono, medium quality) a recording is roughly 15 to 30 MB per hour. That is my estimate from typical AAC bitrates; the device check above also records the file size.

### 1.3 Double-tap for apps (`handGestureShortcut`)

1. **It exists for apps, on Series 9 and Ultra 2 and later, from watchOS 11.** Status: confirmed. The owner's Series 9 qualifies. Older Watches don't, so every double-tap action also has an ordinary tap.
2. **One primary action per scene, and it must be on screen.** Status: confirmed. "Double tap only triggers your primary action if the control is on screen." The system highlights the control when it fires.
3. **It also works on widgets and Live Activities in the Smart Stack, "including remote live activities from iOS".** Status: confirmed (Apple's "Enabling the double-tap gesture" article).
4. **The screen must be awake.** Status: confirmed by Apple Support: raise your wrist and wait for the display to brighten. It also fails in Low Power Mode, Theater Mode, Sleep Focus and Water Lock, and may fail while walking on stairs, running or cycling.
5. **So double-tap is "raise, then pinch twice", one hand, no look needed after the first time.** The other hand stays on the keyboard or the steering wheel of the meeting.

### 1.4 Raise-to-speak, our own version

1. **Apple's Raise to Speak is Siri's, and apps can't use it.** Status: confirmed by absence; no API exists.
2. **What we can sense.** Status: unconfirmed, inference.
   - The app becoming active on a wrist raise. This is free and reliable while we are the frontmost app (1.2, point 4).
   - Watch motion from Core Motion while our process runs. Whether motion updates keep flowing while the app records in the background is unconfirmed.
   - Loudness. Speech a few centimetres from the Watch is far louder than speech across a room or from AirPods.
3. **Device check:** a test build logs wrist-raise moments, motion and loudness during a 30-minute meeting, while the owner double-taps whenever he speaks a Margin. Section 2.8 says how to score it.

### 1.5 Complications, Smart Stack, Controls and Live Activities

1. **Complications and Smart Stack widgets can open the app with one tap.** Status: confirmed (WidgetKit on watchOS). Just Press Record ships this pattern: one tap on its complication starts a recording.
2. **watchOS 26 adds Controls** for Control Center, the Action button and the Smart Stack. Status: confirmed by Apple's watchOS 26 announcement and press coverage; developer details not yet read. The owner's Series 9 has no Action button.
3. **An iPhone Live Activity appears on the Watch on its own, from watchOS 11.** Status: confirmed. "Live Activities from your iOS app are available in the Smart Stack on Apple Watch, even if you don't have a watchOS app yet." When it starts, the Smart Stack opens to it, and in watchOS 11 the Smart Stack "will remain visible when you put your wrist down."
4. **Tapping that Live Activity opens our Watch app** when one is installed. Status: confirmed ("When you tap on the Live Activity widget, you're taken into the app").
5. **Buttons in it.** Apple recommends one control, for play, pause or resume, and says double-tap can fire it. Where that button's intent runs, on the Watch or on the iPhone, is not stated. Status: unconfirmed. This matters: if a "Record" button there runs on the iPhone, it uses the phone's microphone and fails during a call. Device check: put a button on the Live Activity that writes which device ran it into the session's log, press it from the Watch, read the log.
6. **Design rule until that check passes:** the Live Activity on the Watch has no Record button. Tapping it opens our Watch app straight onto the Record screen. Its one button is **Mark**, which is device-neutral (a mark is a timestamp; it doesn't need a microphone).

### 1.6 Siri and App Intents on the Watch

1. **A Watch app can offer App Shortcuts from watchOS 9.2.** Status: reported by Matthew Cassinelli from Apple's WWDC23 session; App Intents on watchOS is documented.
2. **On the Watch, Siri matches the phrase exactly, and the listener must accept an opt-in prompt.** Status: reported (Cassinelli; forum thread 840647, where a declined prompt had no visible way back). So "add a Margin with no setup" is not yet true on the Watch.
3. **Siri on the Watch takes the microphone itself,** and recording must start with our app in front. Status: inference from 1.2. So a Siri "Add a Margin" on the Watch has to open our app, then start recording. Device check: build an App Shortcut that opens the app into recording, say the phrase during a phone call, and time it from the end of the phrase to the recording tone.

### 1.7 WatchConnectivity: delivery, waking the phone, acknowledgements

1. **`transferUserInfo` and `transferFile` are queued and keep going if our app is suspended.** Status: confirmed. User-info dictionaries are "queued on the other device and delivered in the order in which they were sent." File transfers may be throttled "to accommodate performance and power concerns."
2. **"Transfer finished" means the other device's system has the file, not that our app filed it.** Status: confirmed by how the API is shaped; the delegate call reports the transport. Today's Watch app deletes its copy at that moment (`WatchMarginRecorder.swift`, `didFinish fileTransfer`). If the phone then fails to store it, the Margin is gone on both devices. Slice 1 fixes this.
3. **`sendMessage` from the Watch, while our Watch app is active, wakes the iPhone app in the background.** Status: confirmed. The reverse is not true: the phone cannot wake the Watch app. A Watch app that is recording in the background may not count as "active and running" for this. Status: reported; one developer found messages from a background-recording Watch never reached the phone (thread 762327).
4. **So the contract uses two lanes.** A fast lane (`sendMessage` with a reply) when the Watch app is in front, for an answer in about a second. A sure lane (`transferUserInfo` and `transferFile`) always, which arrives eventually. Every message goes on the sure lane; the fast lane is a speed-up, never the only copy.
5. **Application context holds only the latest state.** Status: confirmed. Good for "what is the session now", useless for events.
6. **WatchConnectivity transfers can't be tested in the Simulator.** Status: confirmed ("Always test Watch Connectivity file transfers on paired devices"). Every check of the contract runs on the owner's real Watch and phone.

### 1.8 Out of range

1. **A Watch app runs normally away from the phone.** Status: confirmed by how watchOS works; the microphone and storage are the Watch's own.
2. **WatchConnectivity needs the phone nearby, over Bluetooth or the same Wi-Fi.** Status: unconfirmed for Wi-Fi. A cellular Watch on its own does not reach the iPhone app through WatchConnectivity (inference). Queued transfers wait and go when the phone is back.
3. **Device check:** turn Bluetooth off on the phone, record two Margins on the Watch, turn it back on, and time how long until both say "Filed".

### 1.9 Speech recognition on the Watch

1. **There is no speech-to-text API for watchOS apps.** Status: confirmed. `SpeechAnalyzer` lists iOS, iPadOS, Mac Catalyst, macOS, tvOS and visionOS 26, not watchOS. `SFSpeechRecognizer` doesn't list watchOS either. Only the system dictation sheet exists, which returns finished text and takes over the screen.
2. **So the Watch never transcribes.** The phone transcribes every Margin and every continuous recording after it arrives. The Watch's job is audio, timestamps and marks. No Apple Intelligence needed anywhere.

### 1.10 Clocks

1. **Watch and phone clocks normally agree closely** because the Watch takes its time from the phone and the network. Status: unconfirmed for how closely. The contract measures it on every round trip instead of trusting it (section 3.5).

---

## 2. The excellent version

### 2.1 Cost rules for the wrist

`Design/proposals/compute-taps.py` counts phone taps: a tap is 1, a menu item or swipe is 2. The Watch adds these:

1. **Raise**: bringing the wrist up to wake the screen. It costs 1. Every job starts with one unless the screen is already up.
2. **Tap**: a touch on the Watch screen. 1.
3. **Double-tap**: the finger pinch. 1, but it is **one-handed and blind-capable**, so the listing counts it apart from taps.
4. **Crown**: turning the Digital Crown to set a value. 1 per value, however far it turns.
5. **Glance**: reading the screen with no touch. Half a point, and it says how much there is to read.
6. **Eyes off the call**: did the listener have to look at the *phone*, or leave the app the call or book runs in? Yes or no. A Watch glance doesn't count, because a glance at a wrist is what people already do in meetings.
7. **Two hands**: does the job need the other hand on the Watch? Taps do; double-tap and crown-with-thumb mostly don't. Counted as yes or no.

A job's cost is written like this: **Raise 1 · Taps 2 · Double-taps 0 · Crown 0 · Glance 1 · Phone: no · Two hands: yes.**

### 2.2 The Watch's screens

Fewer is better. There are three, and the listener never navigates between them by hand; the state picks the screen.

1. **Home.** One line says the state, in words, with an icon whose *shape* carries it:
   - "No session" (an empty circle). One big **Record** button, and a smaller **Start session** below it.
   - "Budget meeting · on iPhone · about 12:40" (a phone outline). One big **Record** button. **Mark** and **End** sit below, reached by scrolling or the crown.
   - "Lecture · on Watch · 14:02" (a watch outline and a moving level meter). The level meter proves the microphone is live. One big **Margin** button. **End** below.
2. **Recording a Margin.** Full screen. The elapsed time, a level meter, the placing hint in large type, and a big **Stop**. Double-tap is Stop.
3. **Session start.** Three steps on one scrolling page: kind (Meeting, Audiobook, Lecture or Other; crown or tap), where you are (crown sets minutes; it starts at 0:00), and **Start**. A switch, off by default, says "Also record the whole session" (section 2.10).

Blue and orange tint the big button (blue for ready, orange while recording), as today. The words "Record", "Stop" and the icon shape carry the meaning on their own; tint is extra.

### 2.3 Seeing that a phone session is running

1. When the phone starts a session, its Live Activity appears in the Watch's Smart Stack by itself (1.5). The Smart Stack stays up when the wrist goes down. So the next raise shows the session. **Cost: Raise 1 · Glance 1.**
2. Our Watch app's Home shows the same, from application context, the moment it opens.
3. A Smart Stack widget of our own (later slice) says "No session" when none is running, so the listener knows before opening the app.

### 2.4 Starting or joining a session from the Watch

1. **Joining a phone session has no step.** The Watch is always joined to the phone's running session. Every Margin recorded while one runs carries that session's id. **Cost: 0.**
2. **Starting a session on the Watch.** Raise, tap the complication or the app, tap **Start session**, pick the kind, set the position with the crown if it isn't 0:00, tap **Start**.
   - **Cost: Raise 1 · Taps 3 (app, Start session, Start) · Crown 0 to 2 (kind, position) · Phone: no.**
   - The phone learns of it on the sure lane, makes the session at once, and its Live Activity starts. If the phone is out of reach, the session lives on the Watch and the phone catches up later.
3. **If the phone already has a session**, Home shows it and **Start session** is replaced by **End**. Two running sessions at once are not allowed. This prevents the "which session did that go to?" question entirely.

### 2.5 Recording a Margin, with the placing hint

1. **From a phone session, app not open.** Raise. The Smart Stack shows the session; tap it (it opens our app on Home). Tap **Record**, speak, tap **Stop** or double-tap.
   - **Cost: Raise 1 · Taps 2 · Double-taps 1 · Glance 1 · Phone: no · Two hands: yes, once.**
   - Today's build costs the same taps but files nothing visibly.
2. **From the complication.** A tap on our complication opens straight into recording, as Just Press Record does. The tap is the user-initiated foreground start that watchOS requires.
   - **Cost: Raise 1 · Taps 1 · Double-taps 1 · Phone: no.** This is the cheapest everyday path, and the default I'd put on the owner's watch face.
3. **During continuous recording (2.7).** Raise, double-tap, speak, double-tap. **Cost: Raise 1 · Double-taps 2 · Taps 0 · Two hands: no.**
4. **What the screen shows while recording.** The hint is spoken advice, not a step (owner's rule). It sits under the clock:
   - Meeting: "Say who was talking or what about: 'Johnny, on the budget'."
   - Audiobook: "Say where you are: 'chapter 5'."
   - Lecture or other: "Say what was just said, in a few words."
   - Below it, in small type: "about 12:40" when the session has a start position.
   - The hint changes after a few Margins to a shorter form ("Who, or what about?") so it doesn't become wallpaper.
5. **Tones and haptics.** A short haptic at start and two at stop. No sound, because the listener is in a meeting.
6. **A Margin under 1 second is kept** but labelled "very short" on the phone. It is never silently thrown away (see #937, the "Recording, capturing nothing" bug).

### 2.6 Confirmation that means filed

1. **Four states, in words, each with its own icon shape:**
   1. "Recording" (mic).
   2. "Saved on Watch" (watch outline). The audio file is closed and safe on the Watch.
   3. "Waiting for iPhone" (hourglass). Shown only if the phone hasn't answered within 15 seconds.
   4. "Filed in Budget meeting · about 12:40" (check mark). The phone has written it into a session and said so.
2. **Filed is the only word of success.** "Sent" never appears.
3. **When filed arrives while the screen is up**, a single light haptic. When the wrist is down, nothing buzzes; the next raise shows it.
4. **Home keeps a tally**: "4 filed · 1 waiting". Tapping it lists the waiting ones with their times. The listener can always see what the Watch still holds.
5. **Cost to confirm: Glance 1**, usually right after Stop, since the fast lane answers within a second or two when the phone is near.

### 2.7 With no phone session

1. **Record still works.** Tapping **Record** with no session records the Margin, then starts a session for it: kind Other, called "Watch Margins, Thu 23 Oct, 2:14 pm", with no start position.
2. The screen says so: "Filed in a new session: Watch Margins 2:14 pm". The phone shows it in the Library like any session. Later Margins in the next 30 minutes join it, because the session stays open until ended or 30 minutes pass with no Margin.
3. On the phone the listener can rename it or move its Margins into another session (that screen is `SITUATIONS.md`'s).
4. **Cost: the same as 2.5.** No extra step, no question asked at the worst moment.
5. Why not ask "Start a session?" first: that question comes exactly when the listener wants to speak. A session made for them is easy to tidy later; a Margin lost to a question is not. See decision 1.

### 2.8 Continuous recording, marks, and the safety net

The owner's words: "worst case scenario, it doesn't lose your recording."

1. **What it is.** The session records everything the Watch hears, from **Start** to **End**. A Margin is a marked span inside that recording, not a separate file. A mark that fires at the wrong time loses nothing, because the audio is there either way.
2. **Turning it on** is the switch on the start screen (2.2) with the consent screen (2.12). It can also be turned on from Home during a session with one tap.
3. **Marking a Margin.** Raise, double-tap: a haptic, and the screen turns to the Recording view with the hint. Speak. Double-tap again: two haptics, the span closes. If the listener forgets the second double-tap, the span closes after 10 seconds of quiet or 2 minutes, whichever comes first.
4. **Every mark is a moment as well as a span.** The phone keeps the double-tap moment as "you marked here" even if the span turns out to be silence. A silent mark becomes a flag, as `hands-free-margins.md` describes for silent triggers.
5. **The safety net. Audio is written in closed pieces.**
   1. The recording is cut into one-minute files. Each piece is closed and complete before the next starts, so a crash, a dead battery or the system ending the app loses at most the open minute.
   2. Each closed piece goes to the phone on the sure lane when the phone is near, and stays on the Watch until the phone says it has it.
   3. Each piece's start time and length are written down, so the phone joins them with no gaps hidden. A real gap is shown as a gap.
6. **When a call or Siri interrupts.** The system stops the recording, and watchOS won't let us restart it from the background (1.2, point 3).
   1. The open piece is closed and kept.
   2. The Watch gives a distinct haptic, three short taps, and posts a local notification: "Recording paused by a call. Tap to resume."
   3. One tap on the notification opens the app in front and resumes. That tap is the user-initiated start that watchOS requires.
   4. The gap is recorded as "Paused 14:02 to 14:05 (call)". The export shows it.
   - **Cost to resume: Raise 1 · Taps 1.**
7. **Storage guard.** Before starting, the Watch checks free space for at least two hours of audio. Under that, it says so and offers Margins only.
8. **Transcription** of the whole recording happens on the phone, after it arrives. Margin spans are transcribed first, then the rest when the phone is charging.

### 2.9 Raise-to-mouth, as an experiment

The owner's "Dick Tracy" dream. It runs only during continuous recording, so there is no start delay to hide: when the trigger fires, the Margin span begins about 1 second *before* the trigger.

1. **Signals**: the wrist raise that wakes our app (free while we're in front), Watch motion that ends with the screen tilted toward the face, and a jump in loudness consistent with speech a few centimetres away. All three must agree within about 1 second.
2. **Shadow mode first.** For two weeks the trigger only *logs* "would have marked here". It creates no Margins. The owner keeps using double-tap as normal.
3. **How to score it.** Double-tap marks are the truth.
   - A **hit** is a raise trigger within 3 seconds of a double-tap mark.
   - A **false trigger** is a raise trigger with no double-tap mark within 10 seconds.
   - A **miss** is a double-tap mark with no raise trigger.
   - Count all three per hour of recording, separately for meetings, lectures and walking.
4. **The bar to switch it on**: at most 1 false trigger per hour across all kinds, and at least 8 hits in 10 marks. Below that it stays shadow-only.
5. **Even when on, a raise trigger makes a "suggested Margin"** that the phone lists apart from Margins the listener marked, until the owner has used it for a week and said it's right.
6. **Cost if it works: Raise 1, nothing else.** That is the dream: lift the wrist, speak, lower it.

### 2.10 The headphone case

The owner's rule: recording from the Watch uses the Watch's microphone; with no call, the Watch could try the listener's headphones.

1. **During a call**, the Watch uses its own microphone. It probably cannot use the AirPods (1.1, point 3).
2. **With no call, the Watch still uses its own microphone by default.** My reading of the platform (1.1, point 4, unconfirmed) is that taking the AirPods for the Watch would pull them away from the phone and stop the Audible or YouTube audio the listener is hearing. That would be worse than a slightly quieter Watch recording.
3. **The headphone microphone is used only when the headphones are already the Watch's own**: connected to the Watch, playing the Watch's audio. That is rare today, so it is a late slice.
4. **For headphones on the phone, the phone side records** (a headphone double-press adds a Margin, owner's standing call). That's `SITUATIONS.md`'s territory.
5. **Every Margin records which microphone made it** (Watch, headphones), and the export says so. If quality complaints come in, the evidence is there.
6. **The device check in 1.1 decides this.** If it shows the Watch can use phone-connected AirPods without moving the audio, decision 2 flips.

### 2.11 The Watch out of range

1. **Everything works on the Watch alone.** Recording, marks, starting and ending a session.
2. Each Margin shows "Saved on Watch", then "Waiting for iPhone". The tally on Home shows how many wait.
3. **The Watch's estimate of position keeps running** from the last state it had ("about 12:40"), and says "about" as always.
4. **When the phone is back**, the queue drains in order. Each Margin carries its session's id, so it files into that session **even if the session has ended since**. Filing goes by id, not by whether the time falls inside a session's span.
5. **If the phone ended the session while the Watch was away, and the Watch kept recording after that end**, the late Margins still file into it, marked "after the session ended". Nothing is moved into a different session by guesswork.
6. **Cost: none extra.** The listener does nothing.

### 2.12 Consent for continuous room recording

1. **Margins themselves need no consent**: they are the listener's own voice.
2. **Continuous recording records the room.** The first time it's turned on in a session, one screen says:
   - "This records everyone your Watch can hear, until you end the session."
   - "Only turn it on where everyone has agreed. Some places, like Illinois, require that."
   - Buttons: **Everyone agreed, record** and **Margins only**.
   - **Cost: Tap 1, once per session.**
3. **For an audiobook or other solo listening**, the screen is shorter: "This records what your Watch hears, for lining up your Margins." No agreement wording, because nobody else is in the recording.
4. **No default recording of a room.** The switch is off for every kind, every time. Standing call: default on only when it costs the listener nothing; recording others can cost them a lot.
5. **The recording stays on the listener's devices.** It is never put into a shared `.spokenmargins` packet. Only the listener's own Margins are shared, as today. Standing call: keep no data that could identify someone unless the feature needs it.
6. **The Watch shows it's recording the room** whenever the screen is on: the level meter and the word "Recording the room" on Home. Nobody near can be shown a screen that hides it.

### 2.13 The end of a session, and its end position

1. **Ending from the Watch.** Raise, open the app, tap **End**.
   - **Meeting, lecture or other**: it ends. No question. The owner: "a meeting, it's less important."
   - **Audiobook**: one more screen: "Where did you stop?" with the crown, starting at the start position plus the elapsed time. Tap **Done**. The phone keeps both the estimate and the answer, as evidence.
   - **Cost: Raise 1 · Taps 2 · Crown 0 or 1.**
2. **Ending from the phone** is the same on the phone side. The Watch's Home changes to "No session" on its next update.
3. **After ending, the Watch shows a summary** for 10 seconds: "Budget meeting ended. 5 Margins filed. 1 waiting." Waiting ones finish on their own.
4. **A continuous recording ends with the session.** Its last piece is closed and queued like any other.
5. **A session nobody ends** closes itself after 30 minutes with no Margin and no continuous recording, with its end marked "closed automatically". A session with continuous recording ends only when the listener ends it or the Watch runs out of battery or storage; each ending is stated.

### 2.14 Every job with its cost

| Job | Today (build dbaa231) | Excellent |
| --- | --- | --- |
| See that a phone session is running | Open app; title shows if sent. Raise 1, Taps 1 | Raise 1, Glance 1 (Smart Stack) |
| Start a session on the Watch | Not possible | Raise 1, Taps 3, Crown 0 to 2 |
| Join the phone's session | Not possible to see | 0 (automatic) |
| Record a Margin, app closed | Raise 1, Taps 3 | Raise 1, Taps 1, Double-taps 1 (complication) |
| Record a Margin, continuous recording | Not possible | Raise 1, Double-taps 2, one hand |
| Know a Margin is filed | Not possible; says "sent" | Glance 1 |
| Record with no session | Hidden inbox; not visible | Same cost as with one; files into a new session |
| Resume after a call interrupts | Not applicable | Raise 1, Taps 1 |
| End a meeting session | Not possible | Raise 1, Taps 2 |
| End an audiobook session with its end position | Not possible | Raise 1, Taps 2, Crown 1 |

Every Watch job has **Phone: no**. None asks the listener to leave the call or the book.

---

## 3. The Watch–phone contract

### 3.1 Who owns what

1. **A session is owned by the device that started it.** The owner device decides its start, its end and its kind. The other device mirrors it and may *ask* to end it.
2. **The phone is where every Margin ends up.** The Library, transcripts, line-up and export all live there.
3. **The Watch owns its audio until the phone says filed.** It deletes a recording only after a "filed" or "duplicate" answer for that exact id.
4. **Every id is made by the device that creates the thing**: a random UUID, lower case. Session ids, Margin ids, mark ids and piece ids never clash, so neither device has to ask the other for one.
5. **One running session at a time.** If both devices try to start one in the same second, the phone keeps the one whose start time is earlier, and tells the Watch to treat the other as its own and file into the survivor. This should be rare; it is written down so it is handled, not guessed.

### 3.2 Two lanes

1. **The sure lane**: `transferUserInfo` for small messages and `transferFile` for audio. Queued, ordered, survives suspension. Every message goes here.
2. **The fast lane**: `sendMessage` with a reply, used as well whenever the Watch app is in front and the phone is reachable. It wakes the phone app. A reply on the fast lane counts as the acknowledgement; the copy on the sure lane is then a duplicate the phone ignores by id.
3. **The state board**: application context, holding only the phone's latest view of the session. Either device can read it on launch.

### 3.3 Messages from the Watch

Each carries `v` (contract version), `sentAt` (Watch wall time) and `seq` (a counter that only goes up, per Watch install).

1. **hello**: sent when the Watch app opens. Carries the Watch app's version and the ids of everything it still holds. The phone answers with **state**, and with **ack** for any id it already filed. This alone clears a stuck "waiting" list.
2. **sessionStart**: session id, kind, optional title, optional start position, start wall time, owner `watch`, and whether continuous recording is on.
3. **sessionEnd** (or a request to end, when the phone owns it): session id, end wall time, optional end position.
4. **margin** (a file plus its details): Margin id, session id (always present; see 2.7), wall start, length, the hint text shown, microphone used, clock offset at the time (3.5), and attempt number.
5. **mark**: mark id, session id, wall time, what made it (double-tap, raise trigger, Live Activity button), and the span's start and end within the continuous recording when there is one.
6. **piece** (a file): session id, piece number, wall start, length, a checksum, and any gap before it with its reason ("call", "Siri", "app ended").

### 3.4 Messages from the phone

1. **state** (the state board, and on the fast lane in reply to hello): the running session's id, title, kind, owner device, start wall time, start position, whether the Watch is recording the room, count of Margins filed, the phone's wall time now, and `seq`.
2. **ack**: the id it answers, and one result.
   - `filed`: with the session id it went into, the session's title, and the position estimate ("about 12:40") so the Watch can say where it went.
   - `duplicate`: already filed earlier. Treated as filed.
   - `rejected`: with a reason in plain words, for example "the file was empty". The Watch keeps the audio and shows the reason. A rejected Margin is never deleted by the Watch on its own; the phone side lists it too.
3. Acks go back on the fast lane when the Watch asked on it, and always on the sure lane as well.

### 3.5 Clock skew

1. Every fast-lane round trip measures it. The Watch notes when it sent, the phone puts its own time in the reply, the Watch notes when the reply came. The offset is the phone's time minus the midpoint of send and receive.
2. The Watch keeps the latest offset and its age, and stamps both on every Margin, mark and piece.
3. The phone corrects the Watch's times by that offset when it files them. The evidence keeps both the raw and the corrected time.
4. If no measurement exists, or the last one is over a day old, the phone uses the Watch's time as is and says "Watch clock, not checked" in the evidence.
5. An offset over 2 seconds is shown in the evidence. Over 30 seconds, the phone also tells the listener once, because placing hints will be off.
6. Device check: log offsets for a week. My expectation is under half a second; if it is, the correction stays quiet forever.

### 3.6 Idempotency, retries, and never lost or orphaned

1. **Filing is idempotent by id.** The phone files a given Margin, mark or piece id once. A second copy gets `duplicate`. This makes every retry safe.
2. **The phone stores the file before it answers.** It moves the received file into its own container and writes the details, then files, then acks. If storing fails, it answers `rejected` with the reason, so the Watch keeps its copy.
3. **The Watch retries** any item with no ack after 10 minutes that is not still in WatchConnectivity's own outgoing queue. It retries at most every 10 minutes while the phone is reachable, and immediately after a **hello** that doesn't list it as filed.
4. **The phone never holds a Margin out of sight.** Today's inbox waits for a session whose time span fits (`LiveSessionFileWorker.fileWatchInbox`), which is how the owner's Margin vanished. Under this contract every Margin names its session. A Margin with a session id the phone has never heard of makes that session (the Watch started it out of range). An old Margin from before this contract, with no session id, files into a "Watch Margins" session for its day.
5. **Every Margin is visible in exactly one place on each device**: on the Watch in the tally until filed, and on the phone in its session from the moment it is filed.
6. **Packets and the database.** None of this changes the `.spokenmargins` packet. Live sessions are stored in their own files today; new fields are additions, so the last shipped build still reads them. Standing call: keep packets and databases backward compatible.

---

## 4. Slices, in the order I'd build them

Each slice is usable alone. Each owner check takes about five minutes and needs the iPhone and the Watch on his wrist.

### Slice 1: Know the session, and say filed

Fixes exactly what failed: no way to start or link a session, no check for one, "sent" when nothing showed on the phone.

1. Home shows the three states (2.2) from the phone's state board.
2. **Start session** on the Watch (kind and position), and **End**.
3. Every Margin carries a session id. With no session, Record starts a "Watch Margins" session (2.7).
4. The ack (3.4), the four confirmation states (2.6), and the tally.
5. The Watch keeps the audio until filed. The phone stores before it answers.
6. The phone's hidden inbox goes; anything left in it files into a dated "Watch Margins" session.
7. The fast lane for the Watch in front, the sure lane always, and **hello** on open.

**Owner check (5 minutes):**
1. With nothing running on the phone, open Spoken Margins on the Watch. It says "No session".
2. Tap Record, say "Testing, no session", tap Stop. Within a few seconds it says "Filed in a new session". On the phone, the Library shows "Watch Margins" with that Margin.
3. On the Watch, tap Start session, pick Meeting, leave 0:00, tap Start. On the phone, a live session is running.
4. Join a Teams call on the phone. On the Watch, record "Johnny was talking about the budget". The Watch says "Filed in Meeting, about 1:10" or similar.
5. Turn Bluetooth off on the phone. Record one more. The Watch says "Waiting for iPhone". Turn Bluetooth on. Within a minute it says "Filed".
6. Tap End on the Watch. On the phone the session has ended with three Margins.

### Slice 2: One raise to a Margin

1. A complication that opens straight into recording (2.5, point 2).
2. The phone's Live Activity, on the Watch, opens our app; its one button is **Mark** (1.5).
3. Double-tap is Stop on the Recording screen, and Record on Home.
4. The hint changes with the session kind (2.5, point 4).
5. The Live Activity button device check from 1.5 is run in this slice.

**Owner check:** add the complication to the watch face. Start a session on the phone. With the wrist down, raise, tap the complication, speak, double-tap. It says filed. Raise again: the Smart Stack shows the session; tap Mark. On the phone, one Margin and one mark. Under five minutes.

### Slice 3: Continuous recording with marks

1. The switch and consent screen (2.12).
2. One-minute pieces, sent and kept until acknowledged (2.8, point 5).
3. Double-tap spans (2.8, point 3).
4. Interruption: close, haptic, notification, one-tap resume, gap recorded (2.8, point 6).
5. The phone joins pieces, transcribes Margin spans first, and shows gaps.
6. The battery and storage checks in 1.2 run in this slice.

**Owner check:** start a Lecture session on the Watch with whole-session recording on. Play a YouTube talk on the phone's speaker for three minutes. Double-tap twice to mark one Margin. Have someone call the phone; decline it. The Watch buzzes three times; tap the notification to resume. End the session. On the phone: one recording with a marked gap "call", one Margin with its transcript.

### Slice 4: Siri on the Watch

1. An App Shortcut, "Add a Margin in Spoken Margins", that opens the app into recording (1.6).
2. The device check in 1.6 times it during a call.

**Owner check:** accept the Siri prompt once. During a session, raise and say the phrase. Speak; stop; it says filed.

### Slice 5: Raise-to-mouth, shadow mode

1. Logging only, as in 2.9. A small page on the phone shows hits, false triggers and misses per hour.

**Owner check:** after any session with continuous recording, open the page and read three numbers. Two weeks later, decide with the numbers.

### Slice 6: The headphone experiment

1. Only after the 1.1 device check. If headphones connected to the Watch can be the microphone without stopping the phone's audio, offer it when no call runs.

**Owner check:** depends on the device check's result; written then.

---

## 5. Open decisions

1. **Record with no session makes a session for it.**
   - My pick: make it, call it "Watch Margins, date and time", file at once.
   - Alternative: ask "Start a session?" first, with kind and position. Cost: 2 to 3 more taps at the moment the listener wants to speak.
   - What would show me wrong: after two weeks, more than half of his "Watch Margins" sessions get moved by hand into another session. Then a one-tap "Add to the last session" offer at Stop would be better.
2. **The Watch uses its own microphone even when headphones are connected to the phone and no call runs.**
   - My pick: Watch microphone, always, until slice 6's device check.
   - Alternative: the owner's suggestion, try the headphones when no call runs. Cost: if my reading is right, it pulls the AirPods off the phone and stops what he is listening to.
   - What would show me wrong: the device check in 1.1 shows the Watch can take the AirPods' microphone while the phone keeps playing in them.
3. **Continuous recording is off by default and needs one consent tap per session.**
   - My pick: off; one tap per session; shorter wording for solo listening.
   - Alternative: remember the choice per kind ("always record my lectures"). Cost: a meeting recorded without a fresh thought about who's in the room.
   - What would show me wrong: he turns it on for nearly every session and the tap annoys him. Then remembering it for audiobook and lecture kinds only is the next step; never for meetings.
4. **Double-tap in continuous recording marks a span (start and stop), not a single point.**
   - My pick: a span, with a 10-second-quiet auto-close.
   - Alternative: one double-tap drops a point; the phone guesses the span from speech. Cost: one double-tap fewer, but guessed spans pick up other people's speech.
   - What would show me wrong: in the shadow-mode logs, he often forgets the second double-tap (more than 1 in 4 spans auto-close). Then a single-point mark is more honest.
5. **The session belongs to the device that started it.**
   - My pick: the starter owns it; the phone is where Margins end up.
   - Alternative: the phone always owns sessions; the Watch only asks. Cost: a session can't start with the phone out of reach, which is a lecture with the phone in a bag in another room.
   - What would show me wrong: two sessions running at once in practice, more than once a month.
6. **Background recording uses the audio background mode, explained in the Notes for Review.**
   - My pick: the audio mode, which Apple engineers say lets a recording the listener started carry on.
   - Alternative: record only while our app stays in front. Cost: recording stops when the screen turns off or he leaves the app. Continuous recording would then be limited to sessions where he keeps returning to our app.
   - What would show me wrong: App Review rejects the build under guideline 2.5.4. Then the alternative is the fallback, and I would raise it with Apple through developer support before resubmitting.
7. **Raise-to-mouth switches on only at 1 false trigger an hour or fewer, and 8 hits in 10.**
   - My pick: those two numbers, after two weeks in shadow mode.
   - Alternative: switch it on now and let him delete false Margins. Cost: noise in his Margins, and his trust in them.
   - What would show me wrong: the shadow numbers clear the bar easily in the first week. Then the second week is waste and we switch it on.

---

## Sources

1. Apple, Background execution (watchOS): https://developer.apple.com/documentation/watchkit/background-execution
2. Apple, Using extended runtime sessions: https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions
3. Apple, Playing Background Audio (watchOS): https://developer.apple.com/documentation/watchkit/playing-background-audio
4. Apple Developer Forums 751866, recording must begin in the foreground: https://developer.apple.com/forums/thread/751866
5. Apple Developer Forums 750432, no resume after an interruption in the background: https://developer.apple.com/forums/thread/750432
6. Apple Developer Forums 776949, background recording and App Review: https://developer.apple.com/forums/thread/776949
7. Apple Developer Forums 775151, sessions that keep an app frontmost and on Always On: https://developer.apple.com/forums/thread/775151
8. Apple Developer Forums 762327, background-recording Watch app can't reach the phone with messages: https://developer.apple.com/forums/thread/762327
9. Apple, Enabling the double-tap gesture on Apple Watch: https://developer.apple.com/documentation/watchos-apps/enabling-double-tap
10. Apple, `handGestureShortcut(_:isEnabled:)`: https://developer.apple.com/documentation/swiftui/view/handgestureshortcut(_:isenabled:)
11. Apple Support, If double tap isn't working on your Apple Watch: https://support.apple.com/108413
12. Apple, WWDC24 "Bring your Live Activity to Apple Watch": https://developer.apple.com/videos/play/wwdc2024/10205/
13. Apple, WWDC24 "Design Live Activities for Apple Watch": https://developer.apple.com/videos/play/wwdc2024/10098/
14. Apple, `AVAudioSession.CategoryOptions.allowBluetoothHFP`: https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetoothhfp
15. Apple, `WCSession.transferUserInfo(_:)`: https://developer.apple.com/documentation/watchconnectivity/wcsession/transferuserinfo(_:)
16. Apple, `WCSession.transferFile(_:metadata:)`: https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile(_:metadata:)
17. Apple, `WCSession.sendMessage(_:replyHandler:errorHandler:)`: https://developer.apple.com/documentation/watchconnectivity/wcsession/sendmessage(_:replyhandler:errorhandler:)
18. Apple, `SpeechAnalyzer` (platform list): https://developer.apple.com/documentation/speech/speechanalyzer
19. Apple, `SFSpeechRecognizer` (platform list): https://developer.apple.com/documentation/speech/sfspeechrecognizer
20. Matthew Cassinelli, Apple Watch apps can provide App Shortcuts: https://matthewcassinelli.com/apple-watch-apps-can-provide-app-shortcuts-watchos-10/
21. Apple Developer Forums 840647, App Shortcuts Siri opt-in on watchOS: https://developer.apple.com/forums/thread/840647
22. MacRumors, watchOS 26 features (Controls, wrist flick): https://www.macrumors.com/guide/watchos-26-new-features/
23. Just Press Record on the App Store (complication starts a recording): https://apps.apple.com/app/id1033342465
24. Code read: `App/SpokenMarginsWatchApp/Sources/WatchMarginRecorder.swift`, `App/SpokenMarginsApp/Sources/SpokenMarginsApp/WatchMarginReceiver.swift`, `Packages/SessionKit/Sources/SessionKit/LiveSessionFileWorker.swift` (`fileWatchInbox`).
