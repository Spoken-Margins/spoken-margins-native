# Listening session reliability and clarity validation handoff

Status: `verified` for the automated evidence below. Product flows are not
`human_validated` until the product owner completes the checklist.

Build under test: Spoken Margins 0.1 (6), branch `codex/supertonic-tts`, based
on commit `3e9cb0f` plus this feature working tree.

## Supported validation environment

- Deployment target: iOS 18.0 or later on iPhone and iPad.
- Automated UI device: iPhone 17 Pro Max simulator, iOS 26.5 (build 23F77).
- Requested product-owner device: iPhone 17 Pro Max, iOS 26.5.2.
- A generic unsigned iOS device build and generic iOS Simulator build passed.
  No TestFlight build was uploaded by this implementation pass.

## In scope

- Timestamp migration, recency ordering, paused cold-launch restoration, and
  save/dismiss semantics for unfinished sessions.
- Continue Listening versus explicit Start New Session.
- Missing-key Summary preflight and playback-position checkpointing.
- Session/interjection identity, expanded mini-player controls, session-selected
  export, offline Help, and Spotify episode-versus-show guidance.

## Out of scope

- Guessing between ambiguous third-party podcast matches.
- Human listening-quality evaluation, production OpenAI responses, and App
  Store/TestFlight distribution.
- Physical-device background audio, interruption, thermal, and memory testing.

## Automated verification summary

- Contract and surface-contract validators passed.
- SessionKit build-with-tests passed; all 116 package and trace tests passed.
- 53 focused app-model and source-link tests passed before the final UI-only
  accessibility adjustment. They cover missing-key immutability, paused cold
  restoration, Continue/Start New counts, timestamp migration, Spotify link
  classification, and failed-share quarantine.
- The dedicated 25-minute media regression passed, covering pause, interjection,
  save/dismiss, persisted media time, paused restoration, and resume.
- Focused UI routes passed for the expanded mini-player and two-session export
  isolation on the iPhone 17 Pro Max simulator.
- XcodeGen generation, generic iOS Simulator build, and generic iOS device build
  passed.

## Reset and diagnostics

- Reset: Settings > Storage & Testing > Reset Library and Load Sample, then
  confirm Reset Library. This permanently deletes the local test library.
- Seeded item after reset: `Welcome to Spoken Margins`.
- Diagnostics: Settings > Diagnostics > Refresh Diagnostics. Use Copy
  Privacy-Safe Diagnostics to export the redacted report.
- Failed shares: Settings > Import Inbox. The entry retains the actionable
  failure reason and can be retried or removed.

## Product-owner checklist

Record Pass or Fail and brief notes for each item.

- [ ] With no OpenAI API key, pause around 25 minutes, record an interjection,
  tap Summarize Notes, and confirm the AI Setup Needed alert appears without a
  freeze, navigation change, new AI turn, or position/session change.
- [ ] Background and terminate the app, relaunch it, and confirm the newest
  unfinished session appears paused at the saved position without autoplay.
- [ ] From Home, tap Continue and confirm the existing session resumes without
  adding a session row. Use Start New Session and confirm exactly one row is
  added after confirmation.
- [ ] On Home, Settings, Item, and Export, confirm the mini-player exposes X,
  Interject, and Play/Pause. While recording, confirm Done and Cancel replace
  those controls.
- [ ] Tap X, confirm audio stops and the mini-player disappears, then Continue
  and confirm the saved position and interjections remain.
- [ ] Confirm each session row shows a useful date/time, progress, status,
  interjection count, and Current/Most Recent marker; open two sessions and
  verify their notes do not mix.
- [ ] Open Share Session, change the selected session, and confirm the preview
  updates automatically. Verify Share Session and Copy are immediately usable
  and the export excludes other sessions' interjections.
- [ ] Open Help from Home, Playback, and Settings and verify the explanations
  match the implemented behavior.
- [ ] Share a Spotify show page and confirm the Import Inbox explains how to
  share a specific episode. Share a Spotify episode link and confirm normal
  resolution proceeds. For an ambiguous match, confirm the app refuses to
  guess and suggests an Apple Podcasts episode or RSS link.

Product-owner result: Pending.

Product-owner notes: Pending.
