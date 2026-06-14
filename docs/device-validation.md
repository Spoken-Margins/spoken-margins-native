# Device Validation Checklist

Use this when installing the iOS build on a real phone and testing against the local Gemma server on the laptop.

## Goal 1: Local Gemma Provider

- Start the app on desktop.
- Open Settings.
- Select `Ollama / Local Gemma`.
- Start Local Gemma or start your local server separately on `http://localhost:11434/v1`.
- Discover models and select the Gemma GGUF model.
- Leave the OpenAI API key empty.
- Probe the provider.
- Generate a Listening Map.
- Record at least one item interjection and summarize it.
- Continue a discussion from the summary.
- Confirm the laptop local server logs the requests and no OpenAI key is needed.

## Goal 2: iPhone Walking Loop

- Install the iOS app on the phone.
- Allow microphone and local-network permissions when prompted.
- Create or import an item.
- Start playback.
- Confirm speech uses iOS speech output and routes to AirPods.
- From the phone, test play/pause, back, forward, interject, done, cancel, summarize, discuss, and addendum.
- Confirm source interjections keep nearby anchors and item percent.
- Confirm AI-response interjections keep AI-local percent labels.
- Export the session and confirm it includes the source, source interjections, AI response, AI-response interjections, and full item text when enabled.

## Goal 3: Lock Screen And Watch Controls

Current device-ready control paths:

- The web app exposes `window.SpokenMarginsRemote.snapshot`.
- The web app exposes `window.SpokenMarginsRemote.dispatch({ type })`.
- Supported command types are:
  - `queue.open`
  - `playback.playPause`
  - `playback.seekBack`
  - `playback.seekForward`
  - `playback.done`
  - `interjection.start`
  - `interjection.finish`
  - `interjection.cancel`
  - `interjection.summarize`
  - `discussion.start`
  - `discussion.addendum`
- The app registers Media Session handlers for play, pause, seek backward, seek forward, previous, next, and stop.

Device checks:

- Start playback on iPhone.
- Lock the phone and check whether iOS exposes the Media Session controls.
- Test play/pause, back, forward, and stop/done from the Lock Screen or Apple Watch Now Playing surface.
- Confirm the app updates playback state and progress after each command.

Remaining native extension work:

- A true ActivityKit Live Activity.
- A WidgetKit/App Intents action surface for custom interject, summarize, addendum, and discuss buttons.
- A Watch app or Smart Stack widget using the same command contract.

## Goal 4: Offline AI Deferral

- Configure the phone to point at the laptop local AI endpoint.
- Turn off the laptop server or leave the network.
- Try summarize and discussion commands.
- Confirm pending AI tasks appear instead of losing the request.
- Keep listening and recording interjections.
- Restore laptop/server reachability.
- Retry pending tasks from Settings.
- Confirm the generated summaries/discussions complete and attach to the session.
