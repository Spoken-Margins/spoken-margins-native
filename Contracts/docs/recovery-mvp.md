# Recovery MVP

## Product Promise

Spoken Margins is a personal conversational listening app. A complete daily-driver loop imports an article or podcast, plays it with native audio or the user's installed iOS voice, preserves play/pause/back/forward behavior, captures an anchored interjection, streams a contextual OpenAI response into local speech, supports a manually generated Listening Map, and exports the complete exchange for another chatbot.

The phone app is library-first. Source intake lives behind Add Source and continues to support pasted text, links, files, and a configured quick folder without occupying the primary library surface. A new production library starts empty; sample data is an explicit user or developer action.

## Active Boundary

Keep the iPhone/iPad app, Safari extension, share extension, Obsidian import, native Now Playing controls, the listening Live Activity, Speech.framework transcription, installed `AVSpeechSynthesizer` voices, OpenAI with a user-supplied key, three editable model identifiers, AI response playback, interjections, manual AI Listening Maps, deterministic maps from captured Markdown structure, and JSON/AI-handoff Markdown export. Native media owns Now Playing during podcasts and prepared audio; the live-speech coordinator owns it only during immediate `AVSpeechSynthesizer` playback so the two command paths do not replace each other. AVPlayer's observed transport state is authoritative after route changes or system pauses.

Share intake is typed before resolution: podcast/RSS/audio URLs go to source-link resolution, while web pages, Markdown files, and text files go to text import. Browser article extraction uses the pinned, locally bundled Defuddle build with network fallback disabled and preserves Markdown headings. Pending shares import into the library without replacing the active session or screen. A failed share is quarantined once in Settings > Import Inbox for retry or deletion; it is not retried on every foreground activation.

Leaving the full listening screen does not stop playback. An active or paused session remains available in a persistent Now Playing bar that reopens the full player and exposes play/pause state. Transcript-backed media exposes a linear, scrubbable timeline with elapsed and remaining time plus explicit 15-second transport controls. Text-to-speech playback retains semantic sentence, paragraph, or section navigation rather than pretending it has a media-time seek position.

Item deletion is recoverable: the user confirms moving an item to Recently Deleted, receives an Undo action, and can restore it from Settings. Moving an item preserves all item-scoped sessions, maps, transcripts, turns, and interjections. Nothing is purged automatically. Permanent deletion is available only from Recently Deleted and requires a second confirmation that names the related data that will be removed. Whole-library reset remains a confirmed developer tool, not a Home action.

An interjection detail view provides a one-action copy of that single interjection's transcript and before/after anchors. This applies equally to notes attached to the source, an interjection summary, or an AI response; target-wide export remains available for multi-note handoff.

Do not add Watch, standalone Home Screen widgets, Kokoro/MLX, arbitrary providers, dedicated car UI, automatic AI map generation, or an embedded Piper runtime. Deterministic maps derived locally from source headings are intake normalization, not an AI workflow. The WidgetKit target exists only as the required ActivityKit host. Bundled Piper is a separate post-MVP investigation behind the existing speech client.

## Evidence Gates

Every core flow has three distinct states: `implemented`, `verified`, and `human_validated`. Tests and builds can establish only `verified`.

The preservation check covers installed-Piper selection, article and podcast playback, AirPod removal/reinsertion, foreground controls, background continuity, and lock-screen play/pause/back/forward. The final daily-driver check adds podcast-link, Safari-page, Files Markdown, Safari-extension, and Obsidian intake without autoplay or session replacement; library-first Add Source intake; playback continuity through Home, Item, Settings, and Export; podcast scrubbing; Now Playing restoration; recoverable deletion and permanent-delete confirmation; deterministic and AI Listening Map navigation; podcast context around a timestamp; interjection during AI streaming; single AI-response interjection copy; Import Inbox retry/delete; and AI-handoff export.

Before requesting either check, provide a build number and SHA, supported device/OS, exact in/out scope, known issues, reset instructions, seeded items, privacy-safe diagnostics, automated evidence, and a pass/fail checklist.

## Stopping Rules

Do not advance with a crash or data-loss defect, wrong-source context, wrong audio, duplicated import/turn/spoken sentence, or regression in preserved playback. Do not add another product surface, provider, voice runtime, or automatic AI workflow until the daily-driver loop is verified and then human-validated.

When a human check fails, reproduce it from diagnostics, add focused regression evidence, and return only the failed bounded flow for validation. The product owner should not be used as the exploratory test harness.
