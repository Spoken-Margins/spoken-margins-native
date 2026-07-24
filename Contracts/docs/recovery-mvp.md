# Recovery MVP

## Product Promise

Spoken Margins is a personal conversational listening app. A complete daily-driver loop imports an article or podcast, plays it with native audio or the user's installed iOS voice, preserves play/pause/back/forward behavior, captures an anchored interjection, streams a contextual OpenAI response into local speech, supports a manually generated Listening Map, and exports the complete exchange for another chatbot.

The phone app is library-first. Source intake lives behind Add Source and continues to support pasted text, links, files, and a configured quick folder without occupying the primary library surface. A new production library contains one clearly identified Welcome to Spoken Margins item that doubles as a replayable guided tour; it is not treated as user-owned content.

## Onboarding

Onboarding teaches the product's core loop before asking the user to explore intake breadth: listen, save an interjection, open that interjection from the Timeline, and successfully copy or share the session export. The welcome item provides the practice context. The tour is skippable, resumable, and replayable from Help.

Core progress is shown in a dismissible Home card rather than a global safe-area banner, because transient errors, import state, undo, and playback feedback retain priority. The card opens the Help onboarding hub. Help also documents optional source exploration through Safari, Files, and podcast links; those source types do not block completion of core onboarding.

Checklist completion comes from evidence rather than self-reported taps. A saved active interjection, an explicit Timeline interjection open, and a successful clipboard/share completion satisfy the three core steps. The app reconciles interjection and typed item provenance from local persistence after relaunch. The seeded welcome item never satisfies "add one source of your own." Browser-page captures, file imports, and playable podcast resolution record distinct optional intake evidence.

The AI explanation appears after the user has reviewed an interjection. It distinguishes Summarize Notes from Discuss and states that both require the user's OpenAI API key, network access, and separate content-sharing permission. The explanation must also state that playback, interjections, Timeline review, and export work without AI.

## Active Boundary

Keep the iPhone/iPad app, Safari extension, share extension, Obsidian import, native Now Playing controls, the listening Live Activity, Speech.framework transcription, installed `AVSpeechSynthesizer` voices, OpenAI with a user-supplied key, three editable model identifiers, AI response playback, interjections, manual AI Listening Maps, deterministic maps from captured Markdown structure, and JSON/AI-handoff Markdown export. Native media owns Now Playing during podcasts and prepared audio; the live-speech coordinator owns it only during immediate `AVSpeechSynthesizer` playback so the two command paths do not replace each other. AVPlayer's observed transport state is authoritative after route changes or system pauses.

Share intake is typed before resolution: podcast/RSS/audio URLs go to source-link resolution, while web pages, Markdown files, and text files go to text import. Browser article extraction uses the pinned, locally bundled Defuddle build with network fallback disabled and preserves Markdown headings. Pending shares import into the library without replacing the active session or screen. The Share extension confirms and dismisses after saving a handoff; it does not claim it can launch the containing app from an extension point where iOS does not support that transition. A failed share is quarantined once in Settings > Import Inbox for retry or deletion; it is not retried on every foreground activation. Spotify episode links use Spotify oEmbed metadata to search Apple Podcasts, but normalize only when exactly one title match exposes public audio; ambiguous or missing matches remain unresolved.

Leaving the full listening screen does not stop playback. An active or paused session remains available in a persistent Now Playing bar that reopens the full player and exposes play/pause state. Transcript-backed media exposes a linear, scrubbable timeline with elapsed and remaining time plus independently configurable back/forward transport controls; both default to 15 seconds and support 10, 15, 30, 45, or 60 seconds. Text-to-speech playback retains semantic sentence, paragraph, or section navigation rather than pretending it has a media-time seek position.

Files intake accepts UTF-8 plain text, Markdown/Obsidian clips, and text-based PDFs. PDF text extraction runs off the UI actor and creates the same local text-item path; scanned/image-only PDFs remain unsupported until an explicit OCR path is added.

The listening screen supports the standard left-edge swipe back to the library without stopping audio. Transient status, error, undo, and import banners must not cover or intercept playback transport. File reads, Markdown parsing, quick-folder enumeration, audio rendering, transcription, and provider work run without monopolizing the UI actor; any operation that can outlast an immediate tap exposes visible progress while navigation and playback controls remain usable. Prepared text narration is cache-backed, so a missing generated-audio file falls back to immediate live speech and schedules regeneration instead of leaving an old text source unplayable.

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
