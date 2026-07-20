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

## Automated verification

- `python3 scripts/validate-contracts.py` — passed.
- `python3 scripts/validate-surface-contracts.py` — passed.
- `swift test --package-path Packages/SessionKit` — 95 tests passed, including schema and quarantine coverage.
- `SpokenMarginsAppTests` on iPhone 16 Pro / iOS 18.6 simulator — 65 tests passed across the full run plus focused HTTPS and Keychain regressions.
- Broad UI routes — all 5 passed across the initial run and focused reruns: playback/export/settings, manual map import, generated-turn timeline, active-session export isolation, compact controls.
- Debug simulator build — passed.
- Release simulator build — passed; developer-tool strings absent from the executable.
- Generic iOS Release build without signing — passed.
- Signed generic iOS Release build — passed for the app and all three extensions.
- Release `.xcarchive` at `/tmp/SpokenMarginsBuild3-final.xcarchive` — passed; arm64, version `0.1` build `3`, four privacy manifests, all extension build numbers `3`.
- App Store Connect export — blocked because Xcode currently exposes only the free Personal Team and has no App Store distribution profiles; details below.
- Production website — verified July 20, 2026: home, privacy, support, and stylesheet return HTTP 200 over HTTPS; the hostname has a valid Let's Encrypt certificate.

## Review notes

Spoken Margins is a local-first reading and listening app. It has no account requirement, advertising, analytics, or tracking. Users import or share text and podcast links, listen with native playback, pause to record/transcribe interjections, generate summaries or follow-ups, and export a session.

AI is optional. To review AI without an API key or network dependency:

1. Launch the app and open Settings.
2. Under Review Demo, enter `MARGINS-BETA-01`.
3. Tap Unlock Review Demo.
4. On an empty install, the app adds the bundled sample automatically.
5. Open the sample, start listening, and generate a Listening Map, summary, or discussion response.
6. The banner “Review Demo · simulated AI · no content leaves this device” remains visible while this mode is active.

Review Demo is deterministic and entirely on-device. For live OpenAI testing, enter a reviewer-owned OpenAI API key. At the first live AI action, the app explains the text categories sent and requires explicit permission. Permission can be revoked and the key deleted in Settings.

The Share extension accepts an explicitly shared web page/URL, text, Markdown, or plain-text file. The Safari extension reads the current page only after the reviewer invokes its action; it has no blanket host permission or persistent content script.

## Reset and diagnostics

- Fresh beta reset: delete the TestFlight app, reinstall, then use Settings → Delete API Key if the key should also be removed from Keychain.
- Upgrade reset: a schema-v1 private-beta database is moved into `Application Support/LegacyLibraryBackup/<timestamp>` and a notice is shown. It is not silently deleted.
- Review sample: unlocking Review Demo on an empty library seeds “You Can't Inspect the Pill.”
- Diagnostics: Settings → Support & Privacy → Copy Privacy-Safe Diagnostics. The export omits source text, transcripts, API keys, local paths, URLs, folder names, and user-facing status/error copy.

## Product-owner physical-device checklist

Record pass/fail and notes for every line before marking this build `human_validated`.

- [ ] Fresh install launches on an iPhone running iOS 18 or later.
- [ ] Fresh install launches and lays out correctly on an iPad in all four declared orientations.
- [ ] Review Demo unlocks with the supplied code, adds the sample on an empty library, shows the banner, and produces maps/responses without a key.
- [ ] A live AI action presents the disclosure before transmission; decline sends nothing; allow completes; revoke prompts again.
- [ ] API key survives relaunch and Delete API Key removes it.
- [ ] Text/Markdown import, source listening, play/pause, skip, chapter jump, background audio, lock-screen controls, and relaunch resume behave correctly.
- [ ] Microphone permission, interjection recording, transcription, summary, follow-up, and export behave correctly.
- [ ] Recently Deleted restore and permanent deletion behave correctly.
- [ ] Widget/Live Activity shows current playback and delegates supported controls.
- [ ] Share extension imports an HTTPS page/link and text file, and rejects unsupported content cleanly.
- [ ] Safari extension captures selected/readable text only after an explicit action and opens the app handoff.
- [ ] Dynamic Type, VoiceOver labels, reduced motion, light/dark appearance, and offline behavior are acceptable on the supported devices.
- [ ] Privacy and Support links open public HTTPS pages and their statements match observed behavior.
- [ ] Privacy-safe diagnostics are reviewed manually and contain no source, transcript, key, URL, path, or personal folder/title content.

## Completed external prerequisites

- `Site/` was published to `/srv/www/spokenmargins/` with `./scripts/deploy-spoken-margins-site.sh`.
- `https://spokenmargins.proximitytoprogress.com/privacy/` and `https://spokenmargins.proximitytoprogress.com/support/` independently returned HTTP 200 on July 20, 2026.
- The live certificate covers `spokenmargins.proximitytoprogress.com` and is currently valid through October 18, 2026; Caddy manages renewal.

## Remaining external submission blockers and actions

1. Complete or confirm Apple Developer Program enrollment for `cmlax7@gmail.com`, then open Xcode → Settings → Apple Accounts. Xcode currently shows that account but only the free `Personal Team`, which cannot distribute through TestFlight.
2. Select the paid Apple Developer Program team in Signing & Capabilities, then refresh/create App Store distribution profiles for:
   - `com.spokenmargins.native`
   - `com.spokenmargins.native.gate2widget`
   - `com.spokenmargins.native.share`
   - `com.spokenmargins.native.browsertext`
3. Re-run archive export with `Config/ExportOptions-TestFlight.plist`. Current failure: exit 70, no App Store profiles for the four bundle IDs.
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
