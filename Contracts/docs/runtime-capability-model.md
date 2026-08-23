# Runtime Capability Model

## Purpose

Spoken Margins clients should be described by capabilities, not by device assumptions.

A phone is not always a full runtime: without network it cannot use remote AI. A browser extension may own playback for page text or only observe a video. A watch may be a remote control when tethered or an offline prepared runtime when untethered.

The production architecture should therefore constrain every interface through a runtime capability profile.

## Core Rule

Every interface declares what it can do in its current mode.

Modes can change at runtime because of:

- network availability
- phone/watch reachability
- downloaded package availability
- media ownership
- battery/power policy
- permissions
- active route, such as AirPods, car, watch speaker, or browser tab

The UI must only expose commands supported by the active profile.

## Capability Categories

### Playback

Playback capabilities describe who owns audio and which target types can be played.

Capabilities:

- `realtime_tts`
- `prerendered_audio`
- `native_media`
- `browser_owned_media`
- `remote_stream`
- `assistant_turn_tts`
- `summary_turn_tts`

### Timeline

Timeline capabilities describe what kind of source position can be tracked.

Capabilities:

- `text_char_offsets`
- `transcript_segments`
- `media_time`
- `chapter_timing`
- `playback_rate_observation`

### Interjection

Interjection capabilities describe how the client captures spoken notes.

Capabilities:

- `record_audio`
- `capture_text_anchor`
- `capture_transcript_anchor`
- `capture_media_anchor`
- `capture_turn_anchor`
- `queue_offline_interjections`
- `delegate_interjection_to_canonical_runtime`

### AI

AI capabilities describe what can be done from this client in this mode.

Capabilities:

- `provider_diagnostics`
- `generate_listening_map`
- `summarize_interjections`
- `cleanup_transcript`
- `continue_discussion`
- `defer_ai_jobs`

No profile should assume remote AI when network is unavailable. Offline phone/tablet profiles may still support local-only cleanup or deferred jobs.

### Sync

Sync capabilities describe persistence authority.

Capabilities:

- `canonical_persistence`
- `queue_offline_events`
- `import_offline_events`
- `transfer_prepared_packages`
- `receive_prepared_packages`
- `browser_session_handoff`

### Remote Control

Remote control capabilities describe command surfaces that do not own the runtime.

Capabilities:

- `display_snapshot`
- `send_transport_commands`
- `send_chapter_jump`
- `send_interjection_commands`
- `send_ai_commands`

## Standard Profiles

### Phone/Tablet Online

The canonical full runtime.

Expected capabilities:

- app-owned playback for TTS, pre-rendered audio, native media, summaries, and AI turns
- transcript timeline and chapter timing
- audio recording and anchor capture
- remote AI provider access
- canonical persistence
- package preparation and sync reconciliation

### Phone/Tablet Offline

The canonical local runtime without remote AI.

Expected capabilities:

- app-owned playback for downloaded/prepared assets and real-time local TTS when allowed
- audio recording and anchor capture
- local persistence
- queue deferred AI jobs
- no remote provider calls
- no required map generation

### Tethered Watch

Remote control surface for phone/tablet runtime.

Expected capabilities:

- display snapshot
- send transport, chapter, and interjection commands
- optionally send AI commands when canonical runtime reports availability
- no local playback ownership
- no local AI
- no local transcription

### Untethered Watch

Offline prepared runtime.

Expected capabilities:

- play prepared audio packages
- navigate packaged chapters
- record interjection audio
- capture transcript/media anchors
- queue offline sync events
- no TTS generation
- no transcription
- no AI
- no map generation

### Browser Text Runtime

Browser extension handles text sessions.

Possible capabilities:

- capture page/selection text
- use browser or delegated TTS
- record interjections when browser permissions allow
- package anchors and session events for handoff
- delegate AI and canonical persistence unless standalone browser mode is explicitly supported

### Browser Media Runtime

Browser extension observes or controls page-owned media.

Expected capabilities:

- observe media time and playback rate
- capture captions/transcript when available
- record or delegate interjections
- anchor to source media time and transcript spans
- package session handoff to canonical runtime

### Lock Screen / Widget

Compact remote control surface.

Expected capabilities:

- display snapshot
- send transport commands
- display media time and send seek or playback-rate changes when the canonical target publishes a duration
- send interjection commands when allowed
- no playback ownership
- no local recording
- no AI
- no persistence

### Basic Car Controls

Transport-only remote control surface.

Expected capabilities:

- play/pause
- skip back
- skip forward
- no chapter display
- no local recording
- interjection only through a preconfigured safe command strategy

### CarPlay

Expanded remote control surface.

Expected capabilities:

- display now-playing/session metadata
- transport controls
- chapter list/jump where allowed by platform UI
- interjection controls where safe and approved
- no AI-heavy editing flows

## Command Availability

Each command must declare required capabilities.

Examples:

- `play`: requires one playback capability for the current target.
- `jumpToChapter`: requires `chapter_timing`.
- `beginInterjection`: requires `record_audio` or `delegate_interjection_to_canonical_runtime`.
- `finishInterjection`: requires active recording or delegated active recording.
- `generateInterjectionSummary`: requires `summarize_interjections` or `defer_ai_jobs`.
- `submitFollowup`: requires `continue_discussion` or `defer_ai_jobs`.
- Reviewed sharing on phone/tablet requires `preserve_timed_interjection_transcript`, `deterministic_share_cleanup`, and `export_interjection_package`.
- Package intake requires `import_interjection_package`; article source creation additionally requires online `visible_article_acquisition`.
- A local recording targeted to an imported margin requires `reply_to_imported_interjection`.

If a command is unavailable, the client should not show it as active. If invoked anyway, SessionKit returns `invalid_command_for_capability`.

Imported-commentary Listen/Return actions are a typed application-command layer over the canonical source runtime. They are advertised only with a pending imported commentary ID, do not transfer Now Playing ownership, and must preserve an exactly-once source-resume invariant. They are intentionally not accepted by SessionKit trace replay because SessionKit does not own imported attachment audio; app tests cover the queue/Live Activity command matrix and SessionKit traces continue to cover source transport.

## Connectivity Transitions

Profiles can change during a session.

Required transitions:

- phone/tablet online to offline: continue local playback, queue AI jobs, keep recording available.
- phone/tablet offline to online: retry/defer AI jobs when user requests or policy allows.
- tethered watch to untethered watch: continue only if a prepared package for the active session exists.
- untethered watch to tethered watch: upload queued events and promote phone/tablet to canonical runtime.
- browser media to app handoff: preserve transcript/media anchors and playback rate observations.

## Testing Rule

Every trace should declare either:

- the required runtime profile, or
- the required capabilities.

The test harness must reject a trace if the active profile lacks required capabilities.
