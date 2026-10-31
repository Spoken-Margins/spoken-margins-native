# Live sessions and the Watch: design brief

Written 2026-10-23 by the lead session, as the hand-off for the design agents. The owner asked for "an actual design" after the first Watch prototype failed on his own wrist. This brief is everything the agents need. Quotes are the owner's words from the conversation on 2026-10-22 and 2026-10-23.

## The goal

Spoken Margins lets a listener record spoken or written Margins anchored to what they hear. Today that only works for items the app plays itself. The goal is Margins on **anything listened to elsewhere**: a Teams or Zoom meeting, an Audible book, a lecture, a YouTube video, a paper book. The Apple Watch acts as:

1. a **recorder of its own** for blind sessions, and
2. a **paired remote** for sessions the iPhone runs.

The owner's request for the Watch: "I'd be curious to understand what an excellent version of the watch would be, and to really kind of think it through."

Where it started: a friend asked to take Margins during Teams meetings, on his **phone**. "He already could type notes; speaking them is kinda the value add." Meetings are the main use case ("meetings are actually a productivity improvement"). YouTube is secondary.

## What the owner's device tests proved (2026-10-22, iPhone 17 Pro, Apple Watch Series 9)

1. iOS Screen Recording, which uses the ReplayKit app-audio feed, **captured YouTube audio but not Teams call audio**. iOS keeps call audio out of a broadcast. We do not capture other apps' audio at all ("I don't want to toe the line").
2. **During a Teams call on the iPhone, even muted, the phone's microphone is unavailable to other apps.** A spoken Margin in Spoken Margins failed, and so did Voice Memos.
3. **During the same call, Voice Memos on the Watch recorded fine.** The Watch's microphone is the way to speak Margins during a phone call.
4. Unconfirmed: whether our app can start the iPhone microphone while another app is in front and no call is running (YouTube, Audible). This needs a device check. Starting the microphone with the phone locked is also unconfirmed; see `docs/design/hands-free-margins.md` section 7.

## The owner's rules for this feature (don't relitigate)

- **Nothing source-specific.** "nothing should work only with Teams and not with Zoom."
- **Start and end positions.** A session starts by asking where you are in the source: 0:00 at the start of an audiobook, "2:00" if the meeting clock shows two minutes in. For audiobooks it also asks where you stopped, because pauses and playback speed make wall time overestimate. "Whereas a meeting, it's less important."
- **Placing hints are spoken, not a separate step.** "This isn't a pop-up prompt. This is just a prompt that is shown while the margin is recording." For example "say something that helps place this, like 'Johnny was just talking about the budget'" or "I think this is chapter 5".
- **The listener may nudge a Margin's time, optionally.** It's never required.
- **Keep every piece of evidence and report it.** "Our transcript matches 90% and the user reported XYZ. There's no reason that we have to fit into a strict data type. This is just going to be a markdown export." A transcript match may override the estimate, and all of the evidence is shown.
- **Line up afterwards from the meeting's own recording or transcript** (Teams, Zoom, Meet, Webex and Otter exports: VTT, SRT, docx, txt). The owner likes this flow: "recording the call on teams and lining up everything afterwards."
- **On the Watch, the microphone follows the device you recorded from.** "if someone decides to record from the watch, the microphone should be on the watch. And if they're not on a call, then the watch could try to grab the headphones." The fact that the Watch's mic is independent of the phone is an advantage: "we're using that to our advantage right now, which is awesome."
- **Hands-free is the dream.** "start a session on the watch and it was just recording, transcribing everything, and then when you raised your watch to your mouth like Dick Tracy, it would start a margin... worst case scenario, it doesn't lose your recording... any third-party thing like a lecture." The order agreed so far: tap to record, then continuous recording with double-tap marks, then raise-to-mouth as an experiment.
- **Dynamic Island snapshot Margins** (#1508, comment on #2481): long-pressing the island expands it, and the expanded view offers Record and Stop buttons, so the listener can add a Margin without leaving YouTube, Audible or Zoom. A long press can't be our own gesture, and during a call there's no phone microphone.
- Standing calls in `AGENTS.md` that apply here:
  - Default on only when it costs the listener nothing.
  - Keep no user data that could identify someone unless the feature needs it.
  - A headphone double-press adds a Margin.
  - CarPlay is not a priority, but Siri is ("add a Margin" with no setup, even while another app plays).
  - Watch and widgets are "allowed, not scheduled", and the owner has now scheduled the Watch.
  - Simulator permissions are always allowed.
  - No Apple Intelligence dependency (memory: many testers lack the hardware).
- **Consent.** Recording or transcribing other people needs their consent. Illinois requires every party to consent. Apple's two precedents: Phone-app call recording plays an audible announcement to everyone, and Siri Recap on the Watch is opt-in with no notice to bystanders, which critics have pointed out. Margins themselves (the listener's own voice) raise no consent issue. Continuous recording of a room does.

## What failed in the first Watch build (the reason for this brief)

The owner tried build `dbaa231`. In his words: "There was no way of starting or linking to a system or a session, and it didn't ask me what session I was doing it for or check if there was a session. It just had a record button, and it said it was sent to the phone, but when I look at the phone, I don't see it."

What the code does:
- The Watch records and calls `transferFile`. "Sent" means only that the hand-off was queued.
- The phone files the Margin only into an open live session (by time span). Otherwise it waits in a hidden inbox until the next session starts.
- The Watch never knows whether a session exists.

Lessons the design must answer:
- **No silent orphans.** Every Margin is visible somewhere.
- **The Watch knows the session state.**
- **Confirmation means filed, not sent.**
- **Starting a session is possible from either device.**

## What exists in code now (on `main`)

- A live session on the phone: Library, then +, then Live Session. Kind is meeting, audiobook, paper or other. Start position, a running clock, written Margins with the hint as placeholder text, and a ±5 s / ±1 min nudge. A Lock Screen Mark button (Live Activity). An end position. Line Up with a Transcript (parsers for VTT, SRT, docx and txt; fuzzy hint matching; evidence kept). Saved as an ordinary item, with a Markdown export.
- `LiveSessionFileWorker` (SessionKit actor) does all live-session disk work.
- The Watch app (`App/SpokenMarginsWatchApp/`): Record and Stop, AAC, `transferFile`, and an "about 12:40" label from the phone's application context. `WatchMarginReceiver` is on the phone.
- Issues: #1989 (the parent design: Margins on things played or read outside the app, honest about position), #2481 (live session), #2487 (Watch), #1508 (Live Activity as a control surface), #117 (Lock Screen bookmarks), #126 (Siri), and `docs/design/hands-free-margins.md`.

## How to work

- Read `AGENTS.md` and `docs/decisions.md` (Current focus and the owner's standing calls), `Design/brief.md` (the design rules: taps, disclosure, colour-blind safety), `docs/areas.md`, `docs/design/hands-free-margins.md`, issue #1989, and this brief.
- Use the project's own method: **jobs measured in taps and actions**. See `Design/flow-map/` (the map of today's app), `Design/proposals/README.md` (how proposals are written as edits to the map, with jobs) and `Design/proposals/compute-taps.py` (the cost rules). Add Watch-specific costs: a wrist raise, a Watch tap, a double-tap gesture, a crown turn, a glance with no touch. Add "eyes off the call": did the listener have to leave the other app? State the cost rules you add.
- Design from **situations, not screens**. For each situation, say who it is, where both hands and eyes are, which devices are present, what the listener does second by second, and what they expect afterwards.
- Say what is unconfirmed on watchOS or iOS, and what device check would settle it. Don't present an unverified platform capability as fact. Prefer Apple documentation; mark inferences.
- Bring decisions, not option lists. Where a choice is the owner's taste, give your pick, the alternative, and what would show the pick wrong.
- Plain words. The owner is dyslexic and listens to documents: short sentences, numbered points, no walls of symbols. He is red-green colourblind, so never let colour alone carry meaning in any mock-up.
- Write only your own files under `docs/design/live-sessions/`. Don't edit app code, issues or PRs.
