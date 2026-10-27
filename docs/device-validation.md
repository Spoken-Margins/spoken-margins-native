# Device Validation Checklist

For the Solid Ground evidence session after #1101 releases the phone, use the
[combined validation protocol](solid-ground-phone-validation.md). It maps each
remaining issue to the required observations and separates owner-phone checks
from controlled fault-injection tests.

## The rolling phone build (#384)

The newest `main` build waits on the Mac, ready for the owner's iPhone. No TestFlight, no Xcode window.

- **Install:** plug the iPhone in with a cable, unlock it, and double-click **Install Spoken Margins on iPhone** on the Desktop (a copy of `scripts/install-phone-build.command`). It installs over the app, so the Library stays, and it never uninstalls. Then it opens that build's `test-plan.md`: about ten minutes of checks for what changed since the last install. If the phone already has the newest build, it says so and changes nothing (type R to reinstall anyway), and says whether a newer build is being made. Before installing, it says how far behind `main` the build is and why (from `trunk.json`, which `scripts/phone-build` writes), and afterwards the commit the phone should now show. The Desktop copy runs `~/SpokenMargins-phone/install-phone-build.command`, which `scripts/phone-build` keeps equal to `main`'s, so an old Desktop copy can't hold the phone back (#2782).
- **Knowing a build is ready:** each new build posts a Mac notification ("Spoken Margins: new phone build") with its commit and how many things to try. A signing failure posts "phone build needs you", and so does a hosted build that stops arriving (gh failing twice in a row, or no hosted build of a `main` tip for 36 hours), with the reason.
- **Name the build in issues:** Settings > Version reads `0.1 (29) · 1a2b3c4`; the last part is the commit. Label phone-found issues `found-on-phone`.
- **Where builds live:** `~/SpokenMargins-phone/`, one folder per build (`<date-time>-<sha7>`), a `latest` link, and `installed.txt` (the commit on the phone). The three newest builds are kept.
- **Making builds:** `scripts/phone-build` builds `origin/main` (or `--commit <sha>`); `--if-changed` builds only when main moved. The trigger is `scripts/com.spokenmargins.phone-build.plist`, a LaunchAgent that runs it every 10 minutes. It skips while memory pressure isn't normal or free disk is under 10 GB plus 4 GB per running build, and it doesn't retry a commit that failed. A commit the lane runner didn't test itself gets host tests and a simulator build first.
- **Built on GitHub instead (#2357):** `.github/workflows/phone-build.yml` builds and signs the same app on a GitHub-hosted Mac twice a day, before the 8:00 and 17:00 Central plans, from `main` only. With the word `hosted` in `~/SpokenMargins-phone/source` (or `--source hosted`), the same LaunchAgent downloads that build instead of building, checks it as it checks its own, and writes the same folder and test plan, so the installer is unchanged. Delete the file to build on the Mac again.
- **If signing fails:** the build prints what to click (keychain "Always Allow", Xcode > Settings > Accounts) and leaves `~/SpokenMargins-phone/last-failure.log`.

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
- Import a text-based anthology PDF with a title/author page, a table of contents, and more than 12 destination-backed chapters. Confirm the Timeline contains one `Front Matter` entry followed by every chapter exactly once, and that selecting the first story starts at its body rather than at the title or contents pages.
- Start playback.
- Confirm James and Lily use bundled Supertonic output, system fallback uses the selected iOS voice, and both routes work through the speaker and AirPods.
- Measure Supertonic cold first audio (target ≤3 s), warm first audio (target ≤1 s), and sustained real-time factor (target ≤0.5).
- During a long native-text session, confirm playback starts after two Supertonic chunks, the text scrubber advances during buffered startup and after seeking, generation reports completed/total chunk progress, and a render taking more than 45 seconds is identified as delayed. Confirm generation continues through the full item while playing or paused and a temporary render gap waits without changing voices. When generation finishes, confirm the item becomes ordinary seekable generated media for restart and scrubbing, and its generated chapters appear as tappable Timeline rows. Tap Stop before completion and confirm playback continues with the iOS system voice, no later Supertonic chunk is scheduled, and device temperature begins recovering after the already-running inference call finishes.
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
