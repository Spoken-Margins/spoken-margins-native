# Recovery MVP

## Product Promise

Spoken Margins is a personal conversational listening app. A complete daily-driver loop imports an article or podcast, plays it with native audio or the user's installed iOS voice, preserves play/pause/back/forward behavior, captures an anchored interjection, streams a contextual OpenAI response into local speech, supports a manually generated Listening Map, and exports the complete exchange for another chatbot.

## Active Boundary

Keep the iPhone/iPad app, Safari extension, share extension, Obsidian import, native Now Playing controls, Speech.framework transcription, installed `AVSpeechSynthesizer` voices, OpenAI with a user-supplied key, three editable model identifiers, AI response playback, interjections, manual AI Listening Maps, and JSON/AI-handoff Markdown export.

Do not add Watch, widgets, Live Activities, Kokoro/MLX, arbitrary providers, dedicated car UI, automatic map generation, or an embedded Piper runtime. Bundled Piper is a separate post-MVP investigation behind the existing speech client.

## Evidence Gates

Every core flow has three distinct states: `implemented`, `verified`, and `human_validated`. Tests and builds can establish only `verified`.

The preservation check covers installed-Piper selection, article and podcast playback, foreground controls, background continuity, and lock-screen play/pause/back/forward. The final daily-driver check adds Safari/share/Obsidian intake without autoplay, podcast context around a timestamp, interjection during AI streaming, Listening Map generation/navigation, and AI-handoff export.

Before requesting either check, provide a build number and SHA, supported device/OS, exact in/out scope, known issues, reset instructions, seeded items, privacy-safe diagnostics, automated evidence, and a pass/fail checklist.

## Stopping Rules

Do not advance with a crash or data-loss defect, wrong-source context, wrong audio, duplicated import/turn/spoken sentence, or regression in preserved playback. Do not add another target, provider, voice runtime, or automatic AI workflow until the daily-driver loop is verified and then human-validated.

When a human check fails, reproduce it from diagnostics, add focused regression evidence, and return only the failed bounded flow for validation. The product owner should not be used as the exploratory test harness.
