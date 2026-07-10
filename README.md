# Spoken Margins Native

This repository contains the native iPhone implementation of Spoken Margins.

## Current Purpose

Ship a dependable personal listening environment: import an article or podcast, listen with native media or an installed iOS voice such as Piper, interrupt with a contextual note, hear an OpenAI response as it streams, navigate with a Listening Map, and export the session to another chatbot.

The active recovery boundary is:

- iPhone/iPad on iOS 18+
- article, podcast, Safari/share-sheet, and Obsidian intake
- installed system voices through `AVSpeechSynthesizer`
- native lock-screen transport through Now Playing
- OpenAI Responses API with a user-supplied key and three model settings
- manual AI Listening Maps and AI-handoff export

Watch, Live Activities/widgets, Kokoro/MLX, bundled Piper, arbitrary AI providers, and dedicated car behavior are not part of the active release.

## Repository Map

- `Contracts/`: canonical schemas, fixtures, traces, and current product documentation bundled by the app
- `docs/`, `schemas/`, `fixtures/`, `traces/`: legacy mirrors retained while references migrate to `Contracts/`
- `Packages/SessionKit/`: canonical session, persistence, audio, and AI-domain behavior
- `App/`: iPhone app plus Safari and share extensions
- `references/prototype-exports/`: real prototype exports kept as product references, not yet production fixtures

The active product boundary and stopping rules are in `Contracts/docs/recovery-mvp.md`. Older gate documents describe project history rather than current priorities.

## First Engineering Move

Preserve the existing playback spine. Changes must pass contract validation, SessionKit tests, an iOS build-for-testing, and the bounded product-owner checks defined in the recovery document. Automated verification is not human validation.
