# Spoken Margins Native

This repository is the production kickoff workspace for Spoken Margins.

The current Tauri/React app remains the prototype lab. This repo starts from the production artifacts only: architecture notes, contracts, schemas, fixtures, traces, and selected prototype reference exports.

## Current Purpose

Build an Apple-first native implementation around SessionKit, not a line-for-line port of the prototype.

Initial development should prove:

- runtime capability profiles
- SessionKit command/state behavior
- trace replay
- durable local storage shape
- offline prepared playback and watch sync
- interaction-loop parity for source playback, interjections, summaries, addenda, and AI discussion

## Repository Map

- `docs/`: architecture, contracts, kickoff plan, prototype lessons, and validation priorities
- `schemas/`: portable JSON contracts
- `fixtures/`: golden data fixtures
- `traces/`: behavior traces the native implementation should replay
- `references/prototype-exports/`: real prototype exports kept as product references, not yet production fixtures

Key planning documents:

- `docs/native-kickoff-plan.md`: first engineering implementation plan
- `docs/parity-test-plan.md`: verification strategy through schemas, fixtures, and traces
- `docs/product-validation-plan.md`: product-owner validation gates for interface-level acceptance
- `docs/prototype-lessons.md`: prototype lessons to preserve, abstract, or leave behind

## First Engineering Move

Create a Swift package named `SessionKit` and a trace replay test target.

The first implementation should load JSON fixtures and pass:

- `traces/watch-offline-prerendered-session.json`
- `traces/watch-sync-interjections-after-reconnect.json`
- `traces/semantic-navigation-and-rollback.json`
- `traces/tts-link-normalization.json`

Do not start by recreating the prototype UI.
