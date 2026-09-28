# C3 · live-activity: clean up after ourselves

**Outcome.** The Lock Screen and Dynamic Island never show a Spoken Margins Live Activity for long after Spoken Margins has stopped playing. That includes when the listener moves to Spotify or music, when the app is killed in the background, and when playback just sits paused. A phone call in the middle of listening doesn't remove it, so the listener can resume afterwards.

**Why now.** Several testers thought the app was broken because the Live Activity stayed on screen and they didn't know how to dismiss it.

**Where.** Mac. Small, and independent of other streams. Good first Wave 0 task.

## Starting points

- `Gate2CompactControlController.swift`: `Gate2LiveActivityPolicy.shouldMaintain` keeps the activity while playing, recording, or paused on an "adopted" session. It always publishes `ActivityContent(state:, staleDate: nil)`, so there is no stale date and no timeout.
- The app ends the activity on session change, finish or abandon, close, shared-Margin playback, and `willTerminate`. A background kill (jetsam) skips `willTerminate`, so the activity is orphaned.
- The widget is `SpokenMarginsGate2Widget/Sources/Gate2LiveActivityWidget.swift`. Its intents queue commands through app-group defaults.
- Tests are in `SpokenMarginsAppTests/Gate2CompactControlTests.swift`.

## Milestones

**M1: Self-cleaning** (target: Build 30).
- Done when:
  - While paused, the activity carries a stale date and ends itself after a documented idle period. The owner suggested 30 minutes; the agent may argue for another number.
  - When another app takes the audio session and the interruption says not to resume, the activity ends. During an ordinary interruption such as a phone call, it stays.
  - An orphaned activity from a killed process is ended on the next launch.
  - The stale state looks intentional ("Paused — tap to resume") rather than frozen.
  - Host/app tests cover each rule with injected clocks and interruption events. T3 is green.
  - (owner) The owner confirms the Spotify and phone-call cases on the phone (T6). An agent can't produce those interruptions in the simulator.

## Must not break

Lock Screen controls while playing. Recording indicators. Live Activity updates while playing (no extra update traffic).

## Out of scope

Redesigning the Live Activity (D5 may, later).
