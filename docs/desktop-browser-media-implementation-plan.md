# Desktop browser and media implementation plan

Prepared September 24, 2026 for GPT-6 Sol, High reasoning. Planning only; this document does not authorize implementation, commits, merges, distribution, or a new branch.

## Inspected baseline and scope

The desktop worktree is `/Users/colemiller/.codex/worktrees/spoken-margins-desktop/spoken-margins-native`, branch `codex/desktop`, base `82e61bcec35e309dd9ad38eb64f824ae5e45766b`. Desktop implementation is largely untracked, with additional tracked changes in the renderer and release-lane document. Do not reconstruct the candidate from its commit alone. A desktop process was running from this worktree during inspection; its loaded build was not established. The build script and latest handoff identify candidate 0.1 (4).

The main checkout is on `codex/co-op` with substantial separate ongoing changes. Do not implement there or merge that dirty work as a prerequisite. Desktop lane merges toward `codex/provisional-next` only after owner review.

Interpretation of “remaining features”: finish the documented desktop companion follow-ups plus Safari page listening, browser-media Margins, and an optional general-audio mode. This is not a request for all iOS/Watch/backlog parity. Synchronization and Book Club delivery remain separate projects.

Evidence inspected:

- `docs/desktop-companion.md`, `docs/desktop-voice-path.md`, `docs/release-lanes.md`.
- `artifacts/validation/desktop/2026-09-23/build-4-ui-repair.md`: reports 15 desktop tests, fast plan, and build/signature checks passed; owner checks remain pending. These checks were not rerun for this plan.
- `App/SpokenMarginsDesktop/Sources/DesktopCore/DesktopSessionStore.swift`: persistent text sessions, Margins, maps, export; text-session creation can overwrite an explicitly reused item's text. Browser imports must not use that behavior to mutate an edition with existing anchors.
- `App/SpokenMarginsDesktop/Sources/SpokenMarginsDesktop/Stores/DesktopModel.swift`: text-centric transport, capture, recovery, and neural speech. Browser media cannot be added merely by filling `mediaTimeMs` on its existing text path.
- `Tools/BrowserExtraction/`, `App/SpokenMarginsBrowserTextExtension/`, `docs/gate5-browser-text-handoff.md`: existing local readable-page extraction and durable native handoff for iOS. Popup currently auto-runs capture, uses an iOS native identity, and opens the handoff URL through the active tab.
- `Packages/SessionKit/Sources/SessionKit/{Models,Protocols,SessionEngine}.swift`: existing browser-owned media targets, media-time anchors, and seek acknowledgement concepts. Browser fixtures demonstrate intended contracts, not a functioning Safari media adapter.

## Decision model

| Layer | Available resource / constraint | Consequence |
| --- | --- | --- |
| Product | Compact menu-bar utility, two-click start, durable personal Margins | Keep primary actions small; do not rebuild an iOS Library |
| Execution | One Sol High implementation agent, existing dirty desktop lane | Serial reviewable slices; no parallel agents or new branches |
| Source | Article text, browser media, app-owned audio, unstructured system sound | Preserve separate identity and position semantics |
| Transport | Native TTS versus page-owned player versus uncontrolled app | Capabilities must be observed per source, not assumed from platform |
| Evidence | DOM/media events, native recordings, timestamps, optional captions | Store provenance and uncertainty; never infer media time from elapsed listening time |
| Resources | Local inference can consume memory and stall playback | Reuse bounded voice workers; captions/transcription cannot block saving a Margin |
| Acceptance | Builds/tests establish implementation evidence only | Owner accepts audible behavior, usefulness, and interaction count |

Preferred order: establish a real Safari-to-desktop handoff, ship readable-page listening, introduce typed external-media sessions, then browser-media capture. General system audio follows only after a bounded feasibility probe. Browser integration gives identity and transport evidence that audio capture alone lacks.

Alternatives considered: clipboard-only is cheaper but misses the requested page experience; browser-only TTS duplicates native voice/recording/persistence work; a local HTTP server adds authentication and lifecycle burden before native messaging has been disproved; a universal audio recorder maximizes coverage but cannot promise accurate source return. Keep native messaging and the existing native playback path first.

## Product contract

After extension enablement, site access, and any first-use OS permissions:

1. Click the Safari toolbar extension.
2. Click **Listen to Page**. Extract the current readable page, durably import it, create/resume its session, and start native speech. No copy/paste or extra Play step.

Show **Make Margins on Media** alongside page listening when a candidate player exists. This attaches to the existing player; it does not narrate the surrounding YouTube webpage. If multiple players are plausible, show a target choice rather than controlling the wrong one. The two-click promise applies to the unambiguous configured path; onboarding and ambiguity are measured separately.

For attached media, Interject obtains a fresh source position, pauses when supported, records the user's voice in the desktop app, saves durably, then resumes only if the app successfully paused a previously playing source and the same source is still attached. A rejected resume shows a direct browser action; never show Playing before acknowledgement. If pause is unavailable, disclose that and offer a written Margin or explicit record-while-playing mode. Keep the independent Finish control and five-minute recording limit.

Changing source during capture queues the incoming source without interrupting the recording. Switching during playback checkpoints the previous session and stops only the transport this app owns or explicitly attached to. Duplicate deliveries must not create duplicate sessions or start playback twice.

## Capability and anchor contract

| Source | Playback owner | Durable anchor | Return guarantee |
| --- | --- | --- | --- |
| Readable article/selection | Desktop speech | Immutable text edition + source offsets + URL | Saved text remains available even if webpage changes |
| Browser VOD / podcast player | Browser | Source identity + observed media milliseconds + optional timed transcript | Seek only when the same supported source can be reattached |
| Local DRM-free audio / supported direct podcast | Desktop | Media edition + media milliseconds | App can control transport while media remains available |
| Live stream | Browser or other app | Observed live/DVR coordinates when available, otherwise capture timeline | No durable seek promise without retained source |
| General system sound | External app | Capture-session-relative time + app label + optional context evidence | Not an episode/video timestamp; source return unavailable unless an adapter supplies it |

Keep source identity, playback ownership, position, capture evidence, and control capabilities separate. An app/process label does not identify a podcast episode. A blob URL is not a durable source ID. A transcript of the user's Margin is not a transcript of the source. Unknown/ad/ambiguous positions remain explicit. Do not relabel elapsed capture time as `mediaTimeMs` in existing contracts.

Browser bridge messages need versioning, request deduplication, attachment identity (tab/frame/document/player generation), sequence/freshness, operation acknowledgement, and source identity. These are proposed semantics, not permission to invent uncoordinated schema fields. Update canonical schemas, mirrored fixtures, validators, runtime, and tests together when introducing them. Restrict bridge payloads to expected operations and bounded data; validate payload identifiers, source URLs, origin/session binding, and paths. Never accept page-supplied file paths or shell commands.

## Ordered work packets

### P0 — Baseline and Safari packaging proof (small, uncertainty gate)

Before code, obtain owner adoption of this plan and record the expanded scope in `docs/release-lanes.md`; the current lane explicitly excludes browser/system-audio implementation. Stay on `codex/desktop`. Capture dirty status and a source-file hash manifest, including untracked desktop files. Preserve the live app and data.

Prove a minimal macOS Safari extension can send a native request, durably hand it to the desktop app, wake a closed app, and receive an acknowledgement. Add a dedicated macOS Xcode host/extension packaging configuration while retaining reusable Swift packages and the existing desktop identity/storage. Use a desktop-specific URL scheme and App Group inbox to avoid routing into iOS or opening its database. Treat extension native handler and containing app as separate processes; native messaging does not itself guarantee app launch.

The current build script assembles an ad hoc signed SwiftPM app and has no extension target or URL registration. Verify signing/provisioning/App Group access on the actual local development setup before building the full UI. Inspect compatibility with the Chatterbox child process; do not silently sandbox away existing behavior. If packaging cannot preserve it, produce a concrete host/helper alternative and owner decision. Do not download credentials or change distribution policy.

Exit evidence: signed local host/extension packaging, Safari enablement, real round trip with app open and closed, desktop database isolation, and iOS route untouched. If this fails, stop browser feature expansion and resolve this boundary.

### P1 — Two-click Safari page listening (medium, first shippable slice)

Reuse `Tools/BrowserExtraction` and the existing handoff contract. Parameterize desktop versus iOS native IDs and popup behavior without regressing iOS. Add desktop URL handling, a validated atomic inbox/failed-inbox path, durable import acknowledgement, and import-to-play coordination. Do not put full page content into a URL or replace the viewed page during handoff. Preserve Markdown headings and source metadata. Selected-text capture is an additional explicit action; it must not silently replace Listen to Page semantics.

Use content-edition identity: unchanged capture may reuse the existing edition/session; changed text creates a new edition and leaves prior anchors intact. Preserve unicode offset conventions already used by SessionKit. Queue handoff during recording; retain failed payloads with retry/delete controls. Do not steal current transport on failed extraction/import.

Likely files: desktop App entry point, `DesktopModel`, `DesktopSessionStore`, new desktop inbox/import coordinator, browser popup/build configuration and packaging files. Reuse iOS parsing semantics through a shared pure component where practical; do not copy the iOS app model.

Exit evidence: article with headings, selection, emoji, repeated paragraph, changed article, inaccessible page, huge/invalid payload, duplicate request, cold app, active recording, failed import, and restart recovery. In real Safari count actions and record click-to-audible latency with configured voice; report cold neural startup separately. Proposed UX target: visible acknowledgement under one second, warm system-voice playback within two seconds on the owner Mac; these are targets to measure, not established promises.

### P2 — External-media session boundary (medium)

Introduce source-aware desktop transport/coordinator and persistence operations instead of adding browser cases throughout text-only UI code. Reuse SessionKit's browser target and acknowledgement semantics, but audit the synchronous/default adapter implementations: a default success response must not stand in for an asynchronous browser acknowledgement. Keep text offsets out of media progress calculations. Make map generation conditional on suitable source material.

Persist source identity, media position evidence and attachment status separately from ephemeral tab IDs. Recover external sessions detached; never reconnect to a coincidentally reused tab or start unrelated media. Preserve existing text sessions/recordings with migration and recovery coverage.

Exit evidence: native text and fake browser transport exercise the same capture/save/recovery lifecycle; out-of-order responses, timeouts, stale player generations, seeks and pause/resume failures cannot corrupt anchors or restart a different source.

### P3 — Browser media MVP: YouTube VOD and HTML audio (large, core requested outcome)

Implement a content-script media observer and native bridge using a generic HTMLMediaElement adapter first, then a bounded YouTube watch-page adapter. Detect player replacement, navigation, rate changes, buffering, seeks, tab closure, and extension/background suspension. Prefer media events plus a low-frequency checkpoint; request a fresh snapshot at Interject. A timeout produces an explicit uncertain/unpositioned Margin path, not an invented exact anchor.

Store source media milliseconds independently of playback rate: 1.75× changes traversal speed, not the underlying media coordinate. Obtain an acknowledged pause position for the Margin; retain observation timing/latency evidence. Mark known advertisements and unresolved source transitions as uncertain; do not claim universal ad detection. Captions are optional enrichment with timing/provenance and their absence must not prevent Margins. Do not require scraping inaccessible transcripts, downloading video, or capturing source audio for this milestone.

The official YouTube iframe API is useful for owned embeds, not proof of control over arbitrary youtube.com pages. Verify the actual watch-page adapter in Safari. Cross-origin players require appropriate frame permissions and their own capability checks; do not promise access from the top-level DOM. Do not assume Chrome's tabCapture API exists in Safari.

Exit evidence: ordinary YouTube VOD and HTML podcast/audio page at 1× and 1.75×, no captions, manual seek during capture, multiple tabs/players, autoplay rejection, iframe permission denial, video replacement/ad transition, backgrounding, browser/app restart, and network loss. Use deterministic fixtures for race/anchor assertions and real Safari for integration evidence. Record observed pause position and saved anchor, with a proposed 250 ms tolerance on a controlled fixture; do not promise tighter accuracy than the browser exposes. Save/play/edit/export a Margin and return to its supported source time.

### P4 — Finish companion follow-ups (medium, independently ordered after P1)

- Add configurable global shortcuts for opening the panel and starting/finishing a Margin, including conflict detection and a visible alternative. Prefer a supported hotkey path without broad Accessibility access; selected text from arbitrary apps is a separate, permission-dependent capability. Safari selection is already covered by P1.
- Add recent-session recovery and a written-Margin fallback in the compact panel; avoid a full Library redesign. Export source URLs/timestamps and explicitly label approximate/unsupported source return.
- Add narrated Skim using saved maps/summaries and a reversible return position. Opt-in summaries remain off by default. No model/caption dependency for basic listening or capture; no invented chapters for media without evidence.
- Add app-owned local DRM-free audio and bounded direct podcast intake if desired after browser MVP. This offers reliable transport when browser control is absent. Reuse existing import/audio abstractions and security-scoped access where required; do not automatically download arbitrary website media.
- Complete the already documented voice/recording owner checks before claiming the whole companion ready. Preserve Chatterbox resource limits; additional voice-engine work is not a prerequisite for Safari delivery.

### P5 — Optional general system-audio feasibility probe (small probe; productization unestimated)

Use Core Audio process taps first; compare ScreenCaptureKit only if tap behavior cannot satisfy the actual target configuration. Prove permission handling, nonzero audio, process selection, route changes, and shutdown on the supported macOS baseline. Prefer selected-app capture over the whole mix. Safari process audio may combine tabs; the browser bridge, not process identity, selects the source. Exclude the companion's narration and Margin playback to avoid feedback; keep microphone and source channels separate.

Prototype a bounded in-memory context ring (proposed 30 seconds); persist source snippets only under a clear user-selected retention mode. Default to recording only the user's Margin. Stop capture on explicit stop/quit and disclose permission revocation, protected/silent output, mixed sources, and unsupported capture. Do not attempt protection bypasses. Continuous transcription is not required for the probe.

Measure one 10-minute bounded session for memory slope, CPU, buffer growth, dropped audio, route switching, and mic coexistence. Abort on unbounded growth, permission confusion, feedback, or silent capture misreported as success. Native capture can supply context; it does not grant universal pause, seek, episode identity, or later source return. Productize as an explicitly approximate “Margin on what I’m hearing” mode unless a per-app adapter supplies better evidence. No “any audio with exact anchors” promise.

## Verification and handoff

Use one implementation writer and one packet at a time. After each packet, record changed boundaries, meaningful regression evidence, unresolved limitations, and the next dependency. Avoid repeated unchanged test runs or management polling. No new Codex task is created by this plan.

Run `swift test --package-path App/SpokenMarginsDesktop`, relevant browser tests through the existing build/test workflow, repository fast plan, and `./script/build_and_run.sh --build` as applicable. Extend verification to cover the new signed Safari target. `--verify` refuses while the app is running; never force-stop a recording. Desktop changes need native macOS runtime evidence; existing iOS app/adapters/speech-canary plans are not substitutes. If shared changes affect iOS, follow repository policy and the current simulator incident restrictions, recording any blocked required checks honestly.

Omission check before handoff: all source modes have identity, clock, capability loss, save/recovery, export, and return behavior; every new message has schema/validator/runtime/tests; private browsing/site access and permission denial have explicit behavior; no changed content overwrites anchored editions; active recordings survive intake and panel dismissal; native messages cannot operate on a different source after navigation.

Each owner handoff includes build number, base SHA plus dirty-source hash manifest, macOS/Safari/device matrix, exact supported sites/modes, known issues, non-destructive reset instructions, seeded sample text/media fixtures, diagnostics/export paths, verification summary, and pass/fail owner checklist. Report implemented, verified, and human_validated separately. No release handoff until all applicable gates pass or explicitly documented blockers are resolved.

## Platform sources and confidence

- [Apple: Safari web extensions](https://developer.apple.com/documentation/safariservices/safari-web-extensions): packaging and native extension platform. Actual local signing/host integration remains P0 evidence.
- [Apple: native messaging](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension): native/browser bridge. Delivery lifecycle and durable application routing remain implementation responsibilities.
- [MDN: media currentTime](https://developer.mozilla.org/en-US/docs/Web/API/HTMLMediaElement/currentTime) and [play](https://developer.mozilla.org/en-US/docs/Web/API/HTMLMediaElement/play): media coordinate and asynchronous playback rejection. Site-specific accessibility remains an empirical question.
- [Google: YouTube iframe player API](https://developers.google.com/youtube/iframe_api_reference): embedded-player timing/control; no assumption that it attaches to arbitrary watch-page players.
- [Apple: Core Audio process taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) and [protected-resource permission keys](https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos): process/group audio capture and audio-capture permission. These establish feasibility of capture, not universal source metadata/control.
- [Apple: ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit): alternative system capture framework. Validate exact SDK availability and permissions against macOS 15+ before selecting APIs.

Confidence: high in reuse of text extraction/native storage; moderate in Safari packaging until P0; moderate in browser VOD support pending real site tests; high in the distinction between system capture and source control, but device-specific capture compatibility is unverified. Size labels are comparative engineering estimates, not elapsed-time or model-token guarantees.

## Sol High handoff prompt

> Work single-agent in the existing `codex/desktop` worktree. Read AGENTS.md, docs/release-lanes.md, docs/desktop-companion.md, and this plan. This plan alone is not implementation authorization: once the owner explicitly adopts it, record the lane expansion before code. Preserve every pre-existing dirty/untracked file, active playback, recordings, and local data. Execute P0, P1, P2, and P3 in order, closing evidence-backed slices; report a failed dependency instead of broadening scope. P4 is the subsequent companion backlog; P5 is an optional bounded feasibility probe, not a universal-audio commitment. Reuse existing contracts and extraction code, keep browser-owned media separate from text TTS, and never manufacture source identity/time from system audio. Run applicable checks, prepare a precise owner handoff, and do not commit, merge, distribute, reboot simulators, or force-stop the live app.
