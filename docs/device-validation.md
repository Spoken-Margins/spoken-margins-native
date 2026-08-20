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
- Confirm James and Lily use bundled Supertonic output, system fallback uses the selected iOS voice, and both routes work through the speaker and AirPods.
- Measure Supertonic cold first audio (target ≤3 s), warm first audio (target ≤1 s), and sustained real-time factor (target ≤0.5).
- During a long native-text session, confirm the playback card distinguishes active generation from a ready next section. Tap Stop and confirm playback continues with the iOS system voice, no later Supertonic chunk is scheduled, and device temperature begins recovering after the already-running inference call finishes.
- Run 100 chunks and 30 minutes of foreground/background narration; record resident-memory trend, memory warnings/jetsam, render gaps, and thermal state.
- From the phone, test play/pause, back, forward, interject, done, cancel, summarize, discuss, and addendum.
- Confirm source interjections keep nearby anchors and item percent.
- Confirm AI-response interjections keep AI-local percent labels.
- Export the session and confirm it includes the source, source interjections, AI response, AI-response interjections, and full item text when enabled.

## Goal 3: Lock Screen And Watch Controls

Current device-ready control paths:

- Native media and native live speech share the canonical compact-control command contract.
- The active audio route owns `MPRemoteCommandCenter`; inactive media handlers are removed while live speech is active.
- Live speech publishes `MPNowPlayingInfoCenter` state and handlers for play, pause, toggle, back, forward, previous, next, stop, and playback rate.
- Media playback retains position seeking and playback-rate commands through its native player route.
- Live speech maintains an interpolated presentation offset for UI/progress and a conservative chunk-start recovery offset for fallback and route loss.

Device checks:

- Start playback on iPhone.
- Change native-text speed repeatedly while speaking. Confirm audio changes rate immediately, pitch remains acceptable, the buffering indicator does not restart, and diagnostics do not record new renders for the active chunk.
- Lock the phone and confirm iOS exposes the native Now Playing controls for Supertonic speech.
- Test play/pause, back, forward, stop, and each advertised playback rate from the Lock Screen or Apple Watch Now Playing surface.
- Confirm exactly one command is applied per gesture and media playback does not start underneath live speech.
- After each command, unlock and confirm the app's play state, displayed progress, and resumed spoken text agree. Repeating pause/resume must not drift backward beyond the current sentence.
- While speech is playing, unplug headphones and reconnect them. Confirm playback pauses safely and an explicit resume continues from a valid text anchor.
- Repeat after backgrounding, locking, an incoming audio interruption, and a simulated or natural audio-route reset. Capture diagnostics for both `streamingPresentationOffset` and `streamingRecoveryOffset` when testing streamed assistant speech.

Remaining native extension work:

- Product-owner physical-device acceptance of the native Lock Screen path above.
- Watch package rendering remains out of scope; a future Watch app or Smart Stack surface should dispatch the same compact-control commands instead of creating a second transport.

## Goal 4: Offline AI Deferral

- Configure the phone to point at the laptop local AI endpoint.
- Turn off the laptop server or leave the network.
- Try summarize and discussion commands.
- Confirm pending AI tasks appear instead of losing the request.
- Keep listening and recording interjections.
- Restore laptop/server reachability.
- Retry pending tasks from Settings.
- Confirm the generated summaries/discussions complete and attach to the session.
