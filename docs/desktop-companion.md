# Desktop companion

## Build 5 browser candidate

The desktop branch now has a separate macOS host project (`desktop-project.yml`) and a Safari Web Extension candidate. Its popup offers **Listen to Page**; a desktop-only native handoff imports the captured page as an immutable text edition, opens or resumes a session, and starts native speech. The compact panel also offers written Margins and a recent-session list. Build the extension-bearing bundle with `./script/build_desktop_browser.sh`; the earlier `./script/build_and_run.sh` still assembles the SwiftPM-only companion without the extension.

The Mac is registered with developer team `J8SWC6J3VY`; build 5 now receives development profiles, and the extension is installed from `~/Applications/SpokenMarginsDesktop-5.app`. Safari Settings > Extensions lists **Spoken Margins for Safari**. The owner has since reached playback; the browser handoff still needs focused automated evidence and owner validation. Enabling the extension requests access to the current tab's webpage contents when invoked. See `artifacts/validation/desktop/2026-09-24/build-5-browser-status.md`. Browser-media Margins and general system-audio capture remain future packets in `docs/desktop-browser-media-implementation-plan.md`.

The menu bar control is now a narrow icon without the “Margins” text. It shows a speech icon during playback and a recording icon during capture. This reduces its width in a crowded menu bar; the menu panel still contains Play/Pause. Keep only one desktop app instance running.

The desktop companion is a separate macOS application target in the existing repository, on `codex/desktop`. Its first scope is issue #139: paste text, listen, record a Margin at the source position, edit its transcript, and copy Markdown output. The companion has its own Application Support directory and does not open the iPhone app's database.

## Architecture decision

The scarce resources are implementation/review usage and the owner's attention. The product requirement is quick access to one listening session, with durable comments and accurate context. The desktop UI owns presentation and permission requests; shared SessionKit code owns reusable source, Margin, speech and export semantics. The user chooses the source and starts microphone capture explicitly. Closing the panel must not end playback or lose a saved session.

A separate app target in this repository is the current choice. It provides independent UI, app identity, storage and packaging while retaining source-level shared dependencies and coordinated changes to contracts. A new repository would require versioned package distribution or duplicated models before providing additional user value. A full iOS UI port would bring navigation, library and sharing scope into a compact utility. Reconsider repository separation only when independent ownership/release requirements outweigh coordinated shared-core changes.

Reusable implementation includes `SystemSpeechPlaybackClient`, `SessionKitSupertonic`, `SystemRecordingClient`, `SystemSpeechTranscriptionClient`, SessionKit data models, persistence, and Markdown rendering. macOS requires its own microphone permission request because the shared helper currently handles only iOS/watchOS. Chatterbox uses a separately installed Python runtime and model through a bounded child process. The bundled Supertonic assets make the desktop app materially larger than the original system-voice-only companion.

## First slice

The companion uses a compact menu-bar panel. With text already copied, click Margins in the menu bar and then Paste & Listen to start playback. The panel shows a source-position scrubber and sentence skip controls during a session; Margins and manual text entry are collapsed until requested. During capture, a small floating Finish & Save control remains visible even if a permission prompt dismisses the menu-bar panel or macOS hides its status item. Recording automatically finishes after five minutes as a fail-safe. There is no full Library navigation. System speech is the initial voice; transcription uses the shared on-device path where the OS, locale and installed models support it. Failure must retain the recording and allow a retry or manual edit. Copy Output is an export of the listener's contributions and source context, not an AI-generated answer. No hosted model or account is required by the new UI.

Global hotkeys, automatic selected-text extraction, Safari/Chrome packaging, native-app synchronization, full iOS Supertonic parity and third-party system audio remain follow-ups. Local audio imported into the companion is a more bounded next audio step because the companion can own transport and observe its position. System audio capture alone cannot establish source identity, media position, or control of another application's playback.

## Chapters and optional summaries

The Chapters disclosure uses SessionKit's local deterministic Listening Map generation, the same path used by the iOS native-text flow. Chapter rows jump by saved source-character offsets, and maps survive session recovery. Its expanded list has an explicit bounded height so rows remain visible in the auto-sized menu-bar panel. The Settings control activates and raises the settings window. Settings offers both 1.25× and 1.75× playback speed.

On-device chapter summaries are off by default. After opting in, the owner can explicitly generate short summaries with Apple's local Foundation Models on an eligible macOS 26+ Mac. They remain local derived files keyed to the source text and are hidden when the option is off. This prepares chapter summaries for a later narrated Skim bridge; the desktop panel currently offers chapter jumps and readable summaries.

## Run and reopen

The desktop app lives in the separate `codex/desktop` worktree. From a terminal:

```bash
open ~/Applications/SpokenMarginsDesktop-5.app
```

After Quit, launch that same app again. The `.app` path is a bundle directory, so entering it as a shell command will not launch it. Click the small speech/quote icon in the menu bar to open the panel. The gear opens a separate Settings window for language-filtered Mac voices, Supertonic, Chatterbox Nano/Turbo, speed, saved files and Quit. Each third-party engine requires the owner to review its terms and explicitly accept before testing or activating it. The panel borrows the iOS app's serif editorial headings, bone background and evergreen action while keeping desktop controls. New Text archives the current output and opens the composer in one action; Paste & Listen replaces the current session directly. The user must grant macOS microphone and speech-recognition permissions when prompted for spoken Margins; denial leaves the audio or session state available for recovery.

`./script/build_and_run.sh --build` refreshes the bundle without stopping a running app. The normal run mode reuses an existing instance; `--verify` and `--debug` refuse to proceed while one is running, so they cannot truncate an active recording by force-stopping it. Save and finish any recording before quitting or relaunching.

Supertonic playback and a local Chatterbox helper are implemented but await owner listening and resource checks. The compact panel reserves a single status line, shows Chatterbox render progress, and truncates long titles and messages. Audio completion callbacks advance promptly when prefetched audio is ready; slow rendering can still create a wait, with an available fallback suggested. The helper never installs Python or models automatically. The owner's Turbo starter is detected as a path only; Nano needs a separate checkpoint and Nano-compatible Python runtime, so its test stays disabled while either prerequisite is missing or incompatible. The resource policy, comparison criteria and stopping rules are in [desktop-voice-path.md](desktop-voice-path.md).

## Verification and stopping rules

Run `swift test --package-path App/SpokenMarginsDesktop` for desktop core regressions and `./script/build_and_run.sh --verify` for the macOS build/bundle/process check. Run the repository fast plan for shared-package and contract regressions. The existing `app`, `adapters` and `speech-canary` plans target iOS simulators, not this Mac executable; no simulator boot belongs to this slice. A successful compile or process launch is not product acceptance or proof of microphone/TTS functionality.

Check recovery, source anchors with emoji/non-ASCII text, sentence navigation, voice acceptance revisions, Chatterbox resource thresholds, multiple Margins, transcript editing, export boundaries and error propagation automatically. Owner checks cover the two-click copied-text path, visible recording Finish control, Mac/Supertonic/Chatterbox audible speech, realtime continuity and memory, scrub/skip, pause/capture/resume, transcript quality, denied permissions, panel dismissal, quit/relaunch, and pasting output into another app. Do not add bonus integrations until the first loop passes; preserve evidence and fix a failed boundary before expanding scope. Unsupported speech locales/models remain explicit limitations rather than silently substituting cloud transcription.
