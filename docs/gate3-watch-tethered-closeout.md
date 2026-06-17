# Gate 3 Watch Tethered Closeout

Gate 3 is closed as a tethered Watch remote-control surface for the canonical phone/tablet runtime.

The Watch app is not a local runtime in this gate. It displays the compact snapshot from the phone, delegates safe commands to the phone, and hides commands that are not safe or not currently available. Watch-owned playback, recording, transcription, AI, persistence, and sync remain Gate 4 work.

## Closed Scope

- Watch target builds and embeds in the device app.
- Watch displays current item, target/chapter label, playback status, progress, and compact timeline rows.
- Watch delegates play/pause, skip back, skip forward, chapter jump, Summary when eligible, and Discuss to the phone/tablet runtime.
- Phone publishes filtered `availableCommands` to the Watch so the Watch does not infer command availability from raw capabilities.
- Watch-started interjection is hidden and rejected because real-device testing showed delegated phone recording can complete the current item when the phone is locked.
- `traces/watch-chapter-navigation.json` replays through a `watch-tethered` compact dispatcher backed by the canonical `phone-tablet-online` runtime.

## Contract Deltas

- `watch-tethered` owns only `remote_control_ui` and `compact_snapshot_display`.
- `beginInterjection` and `finishInterjection` are now unsupported for Gate 3.
- `fixtures/capabilities/watch-tethered.json` no longer grants `send_interjection_commands`.
- `validation/surface-contracts/gate3-watch-tethered.json` keeps a Gate 4 backend request for Watch-owned or background-safe interjection capture.
- `traces/watch-chapter-navigation.json` covers play/pause, chapter jump, chapter skip, boundary idempotence, and Discuss.

## Lessons Learned

### WatchConnectivity Reachability Is Not Enough

`WCSession.isReachable` can still allow a Watch command to arrive while the phone is locked or not in a usable foreground recording state. Treat reachability as transport information, not as proof that the phone can safely perform microphone or UI-sensitive work.

Gate 4 should not rely on a delegated phone `beginInterjection` unless it has real-device proof that the phone can start recording while locked without mutating playback incorrectly.

### Never Queue Ephemeral Playback Commands From Watch

Transport controls and recording commands are stateful and time-sensitive. Queuing them through `transferUserInfo` can deliver stale commands against the wrong playback position or target.

Gate 4 should separate durable sync events from ephemeral remote-control intents:

- Durable: watch-recorded interjection event, audio file reference, source/package anchor, created time.
- Ephemeral: play/pause/skip/jump commands that only make sense against the current live session.

### The Watch Needs Its Own Recording Path For The Walking Loop

The core product loop is "phone in pocket or absent, user records from wrist." Gate 3 showed that delegating Watch recording to the phone is not reliable enough. Gate 4 should prefer Watch-owned capture:

- record audio on Watch
- anchor against the prepared package timeline or chapter/offset
- queue a sync event locally
- upload audio and anchors when reconnected
- let phone/tablet transcribe, clean up, summarize, and persist after sync

This matches the existing `watch-untethered` direction better than trying to make the Watch a remote microphone button for the phone.

### Command Availability Must Be State-Aware

The Watch should render from `availableCommands`, not from static capability profile flags. Static profile capabilities say what the surface could theoretically do; `availableCommands` says what the current session state should allow now.

Specific cases found during Gate 3:

- Summary should only appear when unsummarized interjections exist for the current target.
- Interject should not appear until there is a safe capture path.
- Play should not claim it can resume a backgrounded phone session if the user really needs to open the phone app.

### System Surfaces Compete With The Custom Watch App

The "Spoken Margins / percent complete / Open on iPhone" card on Watch appears to be a system Live Activity or Now Playing surface mirrored from the phone, not the custom Watch app. It can cover controls and expand while the user is trying to dismiss it.

Gate 4 should treat system surfaces as separate products:

- custom Watch app
- Watch Now Playing
- mirrored Live Activity / Smart Stack
- iPhone Lock Screen widget

If the custom Watch app is the intended control surface, consider disabling or making opt-in the Live Activity while Watch testing is active.

### Skip Semantics Need Real Content Coverage

Paragraph and chapter skip behavior depends heavily on whether the item has a listening map and clean text boundaries. Gate 3 added chapter-unit coverage, but user testing still matters on mapless items and generated turns.

Gate 4 packages should carry explicit navigation data so the Watch can skip deterministically without asking the phone to reinterpret text.

## Gate 4 Recommendations

Start Gate 4 from `watch-untethered`, not from `watch-tethered` plus more delegated commands.

Minimum Gate 4 slice:

1. Prepare one package on phone/tablet with audio, chapter timeline, source/item ids, and anchor metadata.
2. Transfer the package to Watch.
3. Play package audio locally on Watch with AirPods.
4. Navigate packaged chapters locally.
5. Record a short Watch-owned interjection.
6. Save a local sync event with audio reference and package anchor.
7. Reconnect and import the event into the phone/tablet session.
8. Let phone/tablet schedule transcription and AI work.

Gate 4 pass criteria should require at least one real-device walk test with the phone locked or absent.

## Verification Run

- `swift test` in `Packages/SessionKit`: passed.
- `python3.13` contract validators from a temporary venv: passed.
- `xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsWatch -destination 'generic/platform=watchOS' build | xcbeautify`: passed.
- `xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsAppDevice -destination 'generic/platform=iOS' build | xcbeautify`: passed.
- Focused `SpokenMarginsAppTests/Gate1AppModelWorkflowTests` and `SpokenMarginsAppTests/Gate2CompactControlTests`: passed.

## Open Risks

- The mirrored Watch Live Activity / Now Playing card still needs product policy.
- Watch Summary and Discuss still depend on the phone being able to submit provider work.
- Gate 3 does not prove Watch recording, package sync, or offline playback.
- Real-device testing remains the only reliable source of truth for lock-state behavior.
