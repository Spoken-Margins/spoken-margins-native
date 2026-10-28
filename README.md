# Spoken Margins Native

This repository contains the native iPhone implementation of Spoken Margins.

## What it is

Spoken Margins is a native listening app for iPhone and iPad (iOS/iPadOS 26 or later). You listen to articles, PDFs and podcasts. When you have something to say, you record a spoken or written **Margin** anchored to the exact place in the source. A Margin can be shared as a `.spokenmargins` packet, and another listener can import it and hear it at the right place in their own copy.

The app is in private testing on TestFlight. There is no public App Store release yet.

## What works today

- **Getting things in:** web articles (share sheet, Safari extension, pasted links), text-based PDFs, EPUB, plain text and Markdown (including Obsidian clips), podcast links, and followed podcast feeds and sites. Readwise Reader and Raindrop.io can be connected to bring saved items in.
- **Listening:** installed iOS voices, plus voices that run on the phone. Kitten, the fallback voice, is bundled. Supertonic (the James and Lily voices) is an optional download from Settings › Voices. Podcasts play from the publisher's audio. Lock Screen controls and a Live Activity work while listening. Podcast chapters and deterministic Listening Maps built on the phone help you move around.
- **Margins:** record or type a Margin while listening, find it again from a timeline, and, where the phone supports it, summarize notes with Apple's on-device model.
- **Sharing:** export a session or share Margins as packets (files) with another listener.

## What it doesn't do yet

- No Android, Mac or Windows app. The Watch app is not part of the current release.
- No public App Store release.
- Share links (a web link that opens a shared Margin) are not turned on. The phone can seal and open them with end-to-end encryption, but creating and hosting them for the public waits for a legal review.
- Community Listening Maps are off by default and not open to the public yet. When a listener opts in, the app sends an episode's transcript to the owner's server, which has it summarized by a third-party AI service (Anthropic's API) to make the map. The same legal review applies.
- No third-party AI service is used from the phone. The app ships with its OpenAI provider code switched off. (The server-side maps above are the one place an outside AI service is involved.)
- Cloud voices and any payment are not built.

## What needs the owner's server

The app talks to one small server that the owner runs. The server is needed only for:

- the introductory tour (fetched at launch until you delete it) and updates to the starter podcast list (a first list is bundled in the app and works offline);
- the optional community Listening Maps lookup and contribution, which are off until you switch them on in Settings;
- share links, once they ship.

Everything else the app fetches comes from the sources you choose (feeds, article sites, audio hosts), from the services you connect (Readwise Reader, Raindrop.io), from Apple (for example the on-device speech model, and podcast name search), and from Spotify when you paste a Spotify link (to find the episode's title). The full list is in the [privacy policy draft](docs/legal/privacy-policy-draft.md); it is a working draft, and the live policy is published on the project's site.

## What works offline

With the item already in your Library, listening with Kitten, a downloaded Supertonic voice or an installed voice, recording and replaying Margins, speech recognition (it runs on the phone), and importing or exporting packet files all work without a connection. Adding a new source, refreshing a feed, streaming an episode that isn't downloaded, and anything in the previous section need a connection.

_Checked against `next` on 2026-10-17. When this list and the app disagree, the app is right; please open an issue._

## Technical boundary

The active recovery boundary is:

- iPhone/iPad on iOS/iPadOS 26+
- article, podcast, Safari/share-sheet, plain-text/Markdown, Obsidian, and text-based PDF intake
- installed system voices through `AVSpeechSynthesizer`, plus the Supertonic voices, downloaded after terms acceptance and the bundled Kitten fallback voice
- native lock-screen transport through Now Playing for podcasts, prepared audio, and immediate live speech
- a Live Activity control surface while listening, including live-fallback speech
- Apple Foundation Models for scoped on-device interjection summaries when supported by the device
- deterministic native-text Listening Maps, publisher podcast chapters, and AI-handoff export
- pasted-assistant-response import, playback, and interjection without an embedded third-party AI provider

OpenAI and other third-party AI providers, API-key settings, remote Discuss, AI-generated Listening Maps, new Watch playback/sync work, standalone Home Screen widgets, bundled Piper, and dedicated car behavior are not part of the active release. Supertonic is the supported local neural TTS runtime; legacy Kokoro/MLX runtime code is no longer shipped. The WidgetKit extension remains only because ActivityKit requires it to host the listening Live Activity.

The former iOS 16.7 compatibility app was retired by product-owner decision on 2026-08-10. The repository now has one supported iOS app and one release boundary: iOS/iPadOS 26+. The current verification matrix covers iOS/iPadOS 26 and 27 using Xcode 27; device-dependent local intelligence remains optional. See [the legacy retirement record](docs/legacy-ios16-target.md).

## Repository Map

- `Contracts/`: canonical schemas, fixtures, traces, and current product documentation bundled by the app. It is also the home of the portable formats (packets, Listening Maps, session exports) and their reference validator: [Contracts/README.md](Contracts/README.md)
- `schemas/`: only the developer-recording, link-resolution and surface-contract schemas, which have no copy in `Contracts/`
- `docs/`, `fixtures/`, `traces/`: `docs/` holds durable notes; root `fixtures/` and `traces/` are legacy mirrors retained while references migrate to `Contracts/`
- `Packages/SessionKit/`: canonical session, persistence, audio, and AI-domain behavior
- `App/`: iPhone app plus Safari and share extensions

For readers new to the project: [how it is built](docs/overview/architecture.md), [what stays compatible](docs/overview/compatibility.md), and [what works offline and what leaves the phone](docs/overview/offline-and-privacy.md).

The active product boundary and stopping rules are in `Contracts/docs/recovery-mvp.md`. Older gate documents describe project history rather than current priorities.

## Development Setup

Starting from a fresh clone? [BUILDING.md](BUILDING.md) has the tool versions, the Git LFS step, the host tests and the simulator build. In short:

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

## Licence

Copyright (C) 2026 Proximity to Progress LLC.

Spoken Margins is licensed under the [GNU Affero General Public License, version 3 only](LICENSE) (`AGPL-3.0-only`), with an [additional permission for Apple App Store distribution](COPYING.iOS). The permission's wording is adapted from the [Nextcloud iOS app's App Store exception](https://github.com/nextcloud/ios/blob/master/COPYING.iOS).

- Source files don't carry per-file licence headers. [NOTICE](NOTICE) is the single statement that covers them. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists every third-party component, model and data set with its licence, and says which ones are downloaded and not distributed here.
- To report a security problem privately, follow [SECURITY.md](SECURITY.md).
- For now, only collaborators open pull requests. Contributions are accepted only under the terms in [CONTRIBUTING.md](CONTRIBUTING.md), which keep a later move to the Mozilla Public License 2.0 possible.

_Apple and the Apple logo are trademarks of Apple Inc., registered in the U.S. and other countries. App Store is a service mark of Apple Inc., registered in the U.S. and other countries._
