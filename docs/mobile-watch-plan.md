# Mobile and Watch Control Plan

This app now has a Tauri iOS scaffold and shared web UI. The next native layer should keep the walking workflow thin: the phone owns playback, recording, transcripts, AI requests, and persistence; the Watch and Lock Screen send compact control intents and display active state.

## Control Contract

The native layer should expose these intents to the web app and to widgets:

- `queue.open`: show selectable queue items with title, status, and listening progress.
- `playback.playPause`: start or pause the active item.
- `playback.seekBack` and `playback.seekForward`: use the configured movement unit.
- `interjection.start` and `interjection.finish`: capture a voice note anchored to the current item or AI response segment.
- `interjection.summarize`: summarize active scoped interjections.
- `discussion.start`: start a discussion for the current item, current AI response, or current scoped interjections.
- `discussion.addendum`: add a follow-up voice note after playback is finished.

Each intent should return a state snapshot containing `itemId`, `title`, `playbackMode`, `status`, `progressPercent`, `chapterTitle`, `turnId`, `turnTitle`, `segmentIndex`, `pendingInterjectionCount`, and `pendingAiTaskCount`.

## Current Bridge

The web app currently exposes the command contract at `window.SpokenMarginsRemote`:

- `window.SpokenMarginsRemote.snapshot` returns the latest control snapshot.
- `window.SpokenMarginsRemote.dispatch({ type })` runs one of the intents above.
- The app emits `spokenmargins:state` browser events with the latest snapshot.

The app also registers Media Session handlers for standard transport actions where iOS exposes them: play, pause, seek backward, seek forward, previous, next, and stop. This gives the phone/watch a first device-validation path while a full ActivityKit/WidgetKit/WatchConnectivity layer is added.

## iPhone Acceptance Checks

- Build and run the iOS app in the simulator.
- Create or import a queue item on iPhone.
- Start playback, pause, resume, seek backward, and seek forward from the phone UI.
- Record an interjection during source playback and confirm the saved interjection keeps item percent and surrounding anchors.
- Play an AI response, record an interjection during it, and confirm the interjection is labeled with local AI response percent.
- Simulate provider failure and confirm a pending AI task can be retried after the provider returns.

## Live Activity Acceptance Checks

- Start item playback and see a Lock Screen Live Activity with title, chapter/segment, progress, play/pause, seek back, seek forward, and interject controls.
- Use the Live Activity interject control, speak an interjection, finish it, and confirm the phone app receives the anchored note.
- Finish playback and see summarize, discuss, and add addendum controls replace the transport controls.

## Apple Watch Acceptance Checks

- Launch the Watch app or Smart Stack widget and see queue items with progress.
- Start an item from the Watch.
- Pause/resume and seek while the phone stays locked.
- Start and finish an interjection from the Watch.
- Summarize scoped interjections from the Watch.
- Start a discussion or add an addendum from the Watch after playback.
- Confirm all Watch-created actions appear in the phone timeline with the same anchors and percent labels as phone-created actions.

## Portability Note

Keep these intents platform-neutral. iOS can implement them with ActivityKit, WidgetKit, WatchConnectivity, and App Intents. Android can map the same names to a foreground media session, notification actions, tiles, and Wear OS complications without changing the web app's domain model.
