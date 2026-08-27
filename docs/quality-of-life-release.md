# Non-Watch Quality-of-Life Release

## Scope and Architecture

Build 22 on `codex/quality-of-life-next` implements issues #34, #64, #61, #69, #72–#74, #76–#77, #79, #86, and #87. Issue #75 and all new Watch playback, transfer, render, connectivity, and synchronization work remain excluded.

The release is deliberately layered:

1. Canonical source records preserve authored EPUB/PDF/text/article structure and stable source locators.
2. Prepared-audio records preserve render identity, committed chunks, durable work, and complete AAC/M4A artifacts.
3. The unified offline ledger owns capacity, reservations, protections, adoption, and deterministic eviction.
4. Feed/source records own discovery evidence, explicit subscriptions, inbox state, refresh state, and prompt decisions.
5. Presentation records own library query, sleep timer, and a closed onboarding-route vocabulary.

These layers are persisted through focused repository protocols implemented by both SQLite and the in-memory test store. SQLite schema version 5 adopts older stores idempotently.

## Product Behavior

- Supertonic prepared chunks survive relaunch, are checksum-validated before reuse, and begin playback only after two committed chunks. Partial media never advertises a fabricated complete duration. A complete AAC/M4A artifact is attached through the canonical media route only at a safe playback boundary.
- Render identity includes the Supertonic model revision, model assets, voice style, synthesis parameters, normalization/chunking versions, and manifest version. Playback speed is intentionally absent. Legacy Kokoro selections migrate to James without changing an active session.
- Offline Storage defaults to 5 GB with 1/2/5/10/20 GB choices. Every implemented writer reserves capacity, and imported audiobooks, recordings, interjections, Recently Deleted items, active work, and dormant Watch transfers are protected from automatic eviction.
- EPUB import uses ZIPFoundation 0.9.20 and rejects protected/encrypted, malformed, traversing, excessive, or empty packages before publication. Authored nested navigation remains separate from Listening Maps and prepared audio.
- Audiobook import accepts MP3, M4A, M4B, and audio-bearing MP4, validates AVFoundation playability/duration/protection, fingerprints duplicates, preserves embedded chapters, and publishes item/media/storage ownership atomically.
- Charging preparation is opt-in (`Off` by default; `While Charging` only), uses one registered `BGProcessingTaskRequest`, disables networking, reconstructs durable jobs, and commits at most the next safe chunk before reevaluating power, thermal, identity, deletion, and space.
- Guided onboarding accepts only HTTPS data from the production host, enforces manifest/audio bounds and checksums, exposes only compiled route IDs, caches last-known-good content, and retains a bundled playable text fallback.
- Followed sources support bounded RSS, Atom, and JSON Feed parsing, conditional refresh, HTML alternate-feed discovery, four same-origin heuristics, a chooser for multiple feeds, explicit inbox import, mute/unfollow semantics, and durable suggestion suppression. Following never imports, downloads, or prepares entries.
- Article inbox imports use an app-owned nonpersistent WebKit data store and the pinned bundled Defuddle capture script. Remote scripts and subresources are blocked.
- Library search is metadata-only and case/diacritic insensitive. Typed content/listening/offline filters and deterministic sort choices persist; the query does not.
- Sleep timers support 15/30/45/60 minutes and End of Chapter, display a countdown, extend/cancel, use wall-clock deadlines, remain armed through manual pause/backgrounding, defer expiry through recording, and cancel on item/session replacement or process termination.

## Audit and Falsification

The release must stop if any of these checks fail:

- a partial manifest exposes complete duration/scrubbing;
- a writer can commit more bytes than it reserved;
- valid committed chunks are rerendered after reconstruction;
- source locator/media time mappings are non-monotonic;
- EPUB nested navigation is flattened or unsafe content publishes partially;
- foreground/background preparation differs for the same render signature;
- a follow action imports or downloads content without another explicit user action;
- remote onboarding introduces a route outside `OnboardingRoute`;
- any Watch runtime file enters the release diff.

Automated evidence is `verified`, never `human_validated`. Physical-device playback, lock-screen timing, background scheduling, picker/security-scope behavior, and the full product flow remain product-owner validation.

## Residual Kokoro/MLX Classification

Repository scans after implementation must produce no matches in app/package runtime source or generated project configuration. Remaining matches are allowed only in:

- `docs/staged-github-issues.md`: historical issue specification;
- Gate 1 and Gate 4 closeout/inventory documents: explicitly labeled historical evidence;
- `docs/release-lanes.md` and this document: removal scope and audit result;
- `README.md` and current verification guidance: explicit statements that the runtime is retired.

No legacy model assets, package dependency, compilation flag, scheme, setting, test, or selectable voice remains.
