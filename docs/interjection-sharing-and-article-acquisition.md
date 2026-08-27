# Interjection Sharing Foundation

Status: the contract/package core for issues #17, #18, and #67 is implemented on `codex/sharing-next`. Automated contract and package checks can establish `verified`; only the product owner can establish `human_validated`. Ordinary users have no sharing UI or enabled external behavior from this slice.

## Implemented boundary

The foundation creates a `.spokenmargins` archive from one or more sender-approved share revisions. A share revision is a value snapshot derived from a private capture, so cleanup and sender editing never rewrite raw audio, raw transcript, or the local `Interjection`. Packaging accepts only explicitly selected revisions and either:

- the sender-approved transcript as text only; or
- that transcript plus the selected deterministic-cleanup audio file.

The manifest carries source identity, a package-scoped ID, bounded anchor evidence, the selected representation and its provenance, and an explicit redaction record. Archive audio names are generated package-relative paths. Complete source material, raw or unselected capture representations, diagnostics, API data, device paths, unrelated turns, and app state have no manifest fields.

The package digest is deterministic across identical manifest, generated preview, and audio inputs. It detects modification but does not authenticate the sender. Import rejects malformed containers and JSON, unsafe entries, non-HTTPS source references, unsupported schema versions, missing privacy assertions, attachment mismatches, unreadable audio, and digest or preview mismatches before creating recipient data. A verified package cannot be constructed by a caller; only the checked archive reader can mint the value accepted by import. Export and extraction stage replacements so a failure preserves the prior destination.

Imported commentary uses recipient-local primary keys in separate `ImportedCommentaryLayer` and `ImportedCommentaryInterjection` record kinds. Package IDs remain provenance. The verified package digest makes a second import a stable duplicate instead of creating another layer. A sender reveal-mode suggestion is stored separately from recipient policy; imports are disabled and have no active reveal mode until the recipient chooses one. Anchor outcomes are persisted per note and the layer result is derived from them. SQLite stores the additions as append-only typed records in the existing record table, so no destructive schema migration or flattening into local sessions/interjections is required. A share-revision ID is immutable: an identical save is idempotent and a conflicting save fails explicitly.

## Cleanup and anchor policy

`cleanup.v1` proposes only bounded, reproducible edits over aligned transcript segments:

- case-insensitive removal of `um`, `uhm`, `uh`, `ah`, `ahh`, `er`, and `erm` as whole aligned tokens;
- removal of “you know” only when timing or punctuation isolates the phrase;
- reduction of pauses longer than 750 ms while retaining 250 ms;
- individually restorable, stable decision IDs.

Substring replacement is not used, so words such as “umbrella” remain intact. Package anchor evidence normalizes whitespace and retains at most the nearest 500 characters before and after, plus at most 1,000 characters of exact text.

If every spoken segment would be removed as filler, `cleanup.v1` retains the original transcript and marks those speech-removal decisions unaccepted. Text and accepted audio-removal decisions therefore cannot disagree about deleting all speech. Text normalization uses a fixed POSIX locale rather than device locale.

Article resolution accepts raw offsets only when an exact-edition SHA-256 over the unmodified UTF-8 source matches and any supplied exact quote matches the range. A normalized-content match is useful source evidence but never authorizes raw offsets. The resolver then tries a unique exact quote and a unique normalized-token quote, using bounded context only to break a clear tie. Repeated material without a clear winner stays ambiguous. A different source stays wrong-source, and a matching source without locally resolvable text stays context-only.

## Deferred boundary

This slice does not implement the sender preview UI, share sheet, recipient UI, cueing or commentary playback, Timeline provenance presentation (#68), exact app return-to-source behavior, co-op replies (#19), AI synthesis (#26), accounts, hosted storage, or public distribution. The one-way v1 manifest deliberately omits conversation and parent-package fields so the later #19 reply model is not frozen by this foundation.

External enablement remains blocked on the separate rights/provenance decision and product-owner validation. Automated tests in this slice are developer evidence only.

## Audit method

The regression target is broader historical code from `codex/sharingV1` accidentally importing app, playback, reply, article-acquisition, project, or site behavior. The lane audit compares every historical path with this bounded implementation and fails the packet if a forbidden path changes.

The falsification suite covers deterministic archive bytes and digest, preview tampering, malformed archive/JSON, unsupported versions, private-path rejection, invalid audio, destination rollback, default data minimization, unselected-audio omission, immutable revision IDs, cleanup substring and all-filler safety, context bounds, normalized-hash offset collisions, recipient-controlled activation, recipient-local ID mapping, per-note resolution, duplicate import, SQLite preservation, and resolved/ambiguous/wrong-source/context-only outcomes. The stopping rule is any confidently wrong resolution, undisclosed outgoing field, nondeterministic duplicate, forbidden-surface dependency, or need for an unapproved trust/rights/transport decision.
