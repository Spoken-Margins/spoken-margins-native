# Spoken Margins Native

This repository contains the native iPhone implementation of Spoken Margins.

## Current Purpose

Ship a dependable personal listening environment: import an article or podcast, listen with native media or an installed iOS voice, interrupt with a contextual note, optionally summarize notes with Apple's on-device model when available, navigate with a Listening Map, and export the session to another chatbot. Responses created in another chatbot can be pasted back into Spoken Margins for playback and further interjection.

The active recovery boundary is:

- iPhone/iPad on iOS 18+
- article, podcast, Safari/share-sheet, plain-text/Markdown, Obsidian, and text-based PDF intake
- installed system voices through `AVSpeechSynthesizer`, plus the bundled James and Lily on-device voices after terms acceptance
- native lock-screen transport through Now Playing for podcasts, prepared audio, and immediate live speech
- a Live Activity control surface while listening, including live-fallback speech
- Apple Foundation Models for scoped on-device interjection summaries when supported by the device
- deterministic native-text Listening Maps, publisher podcast chapters, and AI-handoff export
- pasted-assistant-response import, playback, and interjection without an embedded third-party AI provider

OpenAI and other third-party AI providers, API-key settings, remote Discuss, AI-generated Listening Maps, new Watch playback/sync work, standalone Home Screen widgets, bundled Piper, and dedicated car behavior are not part of the active release. Supertonic is the supported local neural TTS runtime; legacy Kokoro/MLX runtime code is no longer shipped. The WidgetKit extension remains only because ActivityKit requires it to host the listening Live Activity.

The former iOS 16.7 compatibility app was retired by product-owner decision on 2026-08-10. The repository now has one supported iOS app and one release boundary: iOS 18+. See [the legacy retirement record](docs/legacy-ios16-target.md).

## Repository Map

- `Contracts/`: canonical schemas, fixtures, traces, and current product documentation bundled by the app
- `docs/`, `schemas/`, `fixtures/`, `traces/`: legacy mirrors retained while references migrate to `Contracts/`
- `Packages/SessionKit/`: canonical session, persistence, audio, and AI-domain behavior
- `App/`: iPhone app plus Safari and share extensions
- `references/prototype-exports/`: real prototype exports kept as product references, not yet production fixtures

The active product boundary and stopping rules are in `Contracts/docs/recovery-mvp.md`. Older gate documents describe project history rather than current priorities.

## Development Setup

Bootstrap the repository-local Python environment before running the contract validators:

```bash
./scripts/bootstrap-python-tools.sh
.venv/bin/python scripts/validate-contracts.py
.venv/bin/python scripts/validate-surface-contracts.py
```

The bootstrap installs the pinned development dependencies from `requirements-dev.txt`. The Python tools validate repository contracts only and are not included in the iOS app.

If Finder drag-and-drop or **Share > Simulator** fails to place a test file in
the iOS Files app, use the documented
[Simulator file-import workaround](docs/simulator-file-import-workaround.md).
The workaround bypasses Apple's host transfer path and does not replace
physical-device validation.

## First Engineering Move

Preserve the existing playback spine. Changes must pass contract validation, SessionKit tests, an iOS build-for-testing, and the bounded product-owner checks defined in the recovery document. Automated verification is not human validation.
