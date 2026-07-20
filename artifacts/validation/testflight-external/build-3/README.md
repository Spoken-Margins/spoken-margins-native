# Spoken Margins external TestFlight handoff

## Build identity

- Marketing version: `0.1`
- Build number: `3`
- Branch: `codex/playback-spine-refactor`
- Base commit: `bc11345325615d04cd9f77163cc8e9ca5948e709`
- Source state: implementation changes are currently uncommitted; record the final commit SHA here before human validation or upload.
- Minimum OS: iOS/iPadOS 18.0
- Supported families: iPhone and iPad
- Shipping extensions: Widget/Live Activity, Share extension, Safari Web Extension

## Validation state

- `implemented`: yes — the repository contains the external-beta closure work described below.
- `verified`: yes — automated evidence is listed below.
- `human_validated`: no — only the product owner can set this after completing the physical-device checklist.

## What changed

- Live OpenAI requests require a one-time, revocable disclosure at the first live AI action.
- Requests use the fixed HTTPS Responses endpoint, set `store` to `false`, and omit local paths, audio, and internal database identifiers.
- The API key uses Keychain accessibility `WhenUnlockedThisDeviceOnly`, reports save/delete failures, and can be explicitly deleted in Settings.
- Review Demo runs deterministic AI locally, shows a persistent simulated-AI banner, requires the review code below, and seeds the bundled sample on an empty install.
- SQLite schema v2 adds transactional map replacement and corrupt-record quarantine. A v1 beta database is archived before the app starts with a fresh library.
- Privacy manifests ship in the app and each extension. Version/build, encryption, device family, and orientation declarations are aligned.
- Developer tools are compiled out of Release.
- Safari no longer requests all-site host access or injects a persistent content script; capture is injected after an explicit action.
- Share activation is limited to web URLs/pages, text, and one file; the runtime accepts text-conforming files.
- Network source imports accept HTTPS only.
- Public privacy/support pages are under `Site/` and are published at the dedicated VPS host `spokenmargins.proximitytoprogress.com`.
- The production app icon is in the app asset catalog.
- Listening Map responses now stream, use a longer inactivity timeout, present concise timeout copy, and attach to the active session so newly shown chapters are immediately navigable.
- Native-text playback has a seek slider, keeps one selected system voice, and reads long sources as bounded utterances with source-accurate progress. Full-file background speech rendering no longer competes with immediate playback.
- Lock-screen media scrubbing and playback-rate changes now pass through the compact capability gate to the canonical media session; live text still keeps those time-based commands disabled.
- PDF imports infer Markdown-style headings from PDF outlines and typography, allowing structured PDFs to receive deterministic Listening Maps without an AI request.
- The Share extension accepts PDF, Markdown, and plain-text files and routes PDF/text content through the same import handoff as in-app file imports.

## Automated verification

- `python3 scripts/validate-contracts.py` — passed.
- `python3 scripts/validate-surface-contracts.py` — passed.
- `swift test --package-path Packages/SessionKit` — 103 tests passed, including active-map reconciliation, bounded native-text speech, source-offset mapping, streamed-turn completion, and delegated lock-screen media seeking.
- `SpokenMarginsAppTests` on iPhone 16 Pro / iOS 18.6 simulator — 74 tests passed, including heading-aware PDF import, generated-turn autoplay policy, the bundled overview sample, and the source-link lock-screen seek/rate route.
- Broad UI routes — all 5 passed across the initial run and focused reruns: playback/export/settings, manual map import, generated-turn timeline, active-session export isolation, compact controls.
- Debug simulator build — passed.
- Release simulator build — passed; developer-tool strings absent from the executable.
- Generic iOS Release build without signing — passed.
- Signed generic iOS Release build — passed for the app and all three extensions.
- The previous Release `.xcarchive` at `/tmp/SpokenMarginsBuild3-final.xcarchive` passed, but it predates the current uncommitted fixes and is superseded. Create and inspect a fresh archive before upload.
- App Store Connect export — pending a fresh archive and confirmation that the renewed paid team and App Store profiles are visible to Xcode; details below.
- Production website — verified July 20, 2026: home, privacy, support, and stylesheet return HTTP 200 over HTTPS; the hostname has a valid Let's Encrypt certificate.

## Review notes

Spoken Margins is a local-first reading and listening app. It has no account requirement, advertising, analytics, or tracking. Users import or share text and podcast links, listen with native playback, pause to record/transcribe interjections, generate summaries or follow-ups, and export a session.

AI is optional. To review AI without an API key or network dependency:

1. Launch the app and open Settings.
2. Under Review Demo, enter `MARGINS-BETA-01`.
3. Tap Unlock Review Demo.
4. On an empty install, the app adds the bundled sample automatically.
5. Open the sample, start listening, and generate a Listening Map, summary, or discussion response.
6. The centered banner “Review Demo · on-device AI” remains visible while this mode is active; its accessibility label includes the full no-content-leaves-device disclosure.

Review Demo is deterministic and entirely on-device. For live OpenAI testing, enter a reviewer-owned OpenAI API key. At the first live AI action, the app explains the text categories sent and requires explicit permission. Permission can be revoked and the key deleted in Settings.

The Share extension accepts an explicitly shared web page/URL, text, PDF, Markdown, or plain-text file. The Safari extension reads the current page only after the reviewer invokes its action; it has no blanket host permission or persistent content script.

## Reset and diagnostics

- Fresh beta reset: delete the TestFlight app, reinstall, then use Settings → Delete API Key if the key should also be removed from Keychain.
- Upgrade reset: a schema-v1 private-beta database is moved into `Application Support/LegacyLibraryBackup/<timestamp>` and a notice is shown. It is not silently deleted.
- Review sample: unlocking Review Demo on an empty library seeds “Welcome to Spoken Margins,” a guided overview of the app's core listening workflow.
- Diagnostics: Settings → Support & Privacy → Copy Privacy-Safe Diagnostics. The export omits source text, transcripts, API keys, local paths, URLs, folder names, and user-facing status/error copy.

## Product-owner physical-device checklist

Record pass/fail and notes for every line before marking this build `human_validated`.

- [x] Fresh install launches on an iPhone running iOS 18 or later.
- [x] Fresh install launches and lays out correctly on an iPad in all four declared orientations.
- [x] Review Demo unlocks with the supplied code, adds the sample on an empty library, shows the banner, and produces maps/responses without a key.
- [x] A live AI action presents the disclosure before transmission; decline sends nothing; allow completes; revoke prompts again.
- [x] API key survives relaunch and Delete API Key removes it.
- [x] Text/Markdown import starts playback promptly; after the Listening Map overview, playback continues into the source instead of jumping to the end. Play/pause, skip, chapter jump, background audio, lock-screen controls, and relaunch resume behave correctly.
- [x] Generate a Listening Map for a long PDF; confirm its overview continues into source playback without jumping to the end. If the request fails or is retried, any map that appears can jump chapters immediately without ending and restarting the session.
- [x] During native-text playback, scrub both backward and forward and confirm playback resumes near the selected position.
- [x] Listen to native text with the preferred app voice for at least two minutes and confirm it never alternates with the accessibility/default voice.
- [x] Import a PDF with visible section headings and confirm a heading-derived Listening Map appears without an AI request.
- [x] From Files or another app, share one PDF and one plain-text file to Spoken Margins and confirm both arrive in the library with readable titles and content.
- [x] Microphone permission, interjection recording, transcription, summary, follow-up, and export behave correctly.
- [x] Recently Deleted restore and permanent deletion behave correctly.
- [x] Widget/Live Activity shows current playback and delegates supported controls.
- [ ] On a physical device with native media playing, scrub backward and forward from the lock screen and change playback rate; confirm the session moves without an `invalid_command_for_capability` error.
- [x] Share extension imports an HTTPS page/link and text file, and rejects unsupported content cleanly.
- [x] Safari extension captures selected/readable text only after an explicit action and opens the app handoff.
- [x] Dynamic Type, VoiceOver labels, reduced motion, light/dark appearance, and offline behavior are acceptable on the supported devices.
- [x] Privacy and Support links open public HTTPS pages and their statements match observed behavior.
- [x] Privacy-safe diagnostics are reviewed manually and contain no source, transcript, key, URL, path, or personal folder/title content.

## Completed external prerequisites

- `Site/` was published to `/srv/www/spokenmargins/` with `./scripts/deploy-spoken-margins-site.sh`.
- `https://spokenmargins.proximitytoprogress.com/privacy/` and `https://spokenmargins.proximitytoprogress.com/support/` independently returned HTTP 200 on July 20, 2026.
- The live certificate covers `spokenmargins.proximitytoprogress.com` and is currently valid through October 18, 2026; Caddy manages renewal.

## Remaining external submission blockers and actions

1. Apple Developer Program membership was renewed by the product owner. Open Xcode → Settings → Apple Accounts and confirm the paid team now appears, then refresh signing assets.
2. Select the paid Apple Developer Program team in Signing & Capabilities and refresh/create App Store distribution profiles for:
   - `com.spokenmargins.native`
   - `com.spokenmargins.native.gate2widget`
   - `com.spokenmargins.native.share`
   - `com.spokenmargins.native.browsertext`
3. Commit the current fixes, record the final SHA above, create a fresh Release archive, and export it with `Config/ExportOptions-TestFlight.plist`. If export still reports missing profiles, capture the new error after the paid-team refresh rather than relying on the pre-renewal exit-70 result.
4. In App Store Connect, set the Support URL, Privacy Policy URL, review notes, and review code exactly as above.
5. Complete App Privacy consistently with the manifest: no tracking; Other User Content, linked, used for App Functionality; no developer analytics/advertising collection.
6. Answer export compliance as no non-exempt encryption; the bundle sets `ITSAppUsesNonExemptEncryption` to false.
7. Complete age rating, content-rights, tester contact, and beta description fields; upload the exported build; add the external tester group; submit for Beta App Review.

## Stop conditions

Do not submit this build for external Beta App Review until all of the following are true:

- archive export produces a distribution-signed IPA without profile errors;
- the final commit SHA is recorded;
- privacy/support URLs are public and match the binary behavior;
- App Store Connect privacy answers match the privacy manifest and policy;
- the product owner completes the physical-device checklist and marks the build `human_validated`.
