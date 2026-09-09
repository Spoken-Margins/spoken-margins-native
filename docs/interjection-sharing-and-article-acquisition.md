# Interjection Sharing Foundation

Status: the one-way sharing MVP for issues #14, #17, #18, and #67 is implemented on `codex/sharing-next`. Automated contract, package, app-state, and build checks can establish `verified`; only the product owner can establish `human_validated`.

## Local-audio guided sessions (2026-09-08)

The provisional lane additionally supports recipient-supplied audiobooks with exact-byte identity. The archive carries `itemType: other`, the source audio SHA-256 and duration, bounded media anchors, an optional portable map, and an explicitly labeled commentary layer. Narration remains a separately imported audio file. Local source matching uses the owned audiobook checksum; confirmation rehashes the actual file off the main actor before accepting the import. A matching digest does not authorize out-of-range anchors or overlapping map scenes. Imported maps retain scene provenance and are persisted separately from publisher chapters. Eligible text-only summaries use the existing local Skim bridge route. For exact local-audio packages, explicitly supplied summary-voice assets are integrity-checked and adopted into the offline ledger under a voice-stable identity. They play at their supplied rate, survive device voice preference changes, and are never replaced with system TTS. Reopening retries incomplete local preparation; reimporting restores supplied assets. The owner requested Chatterbox or Kokoro for this authored session.

An AI professor layer can contain authorized synthetic TTS Margins with `sender_approved_tts` provenance and a clearly synthetic sender label. These are prepared commentary, not live AI answers or a recording of a named academic. Guided playback supplies the cue and plays each intervention; Companion waits for Listen or Dismiss. Import itself never starts playback. Skim Forward summarizes the current scene and lands at the next; Skim Backward recaps the previous scene and lands at the current scene start. Product-owner use is still required to establish listening quality.


## Implemented boundary

The foundation creates a `.spokenmargins` archive from one or more sender-approved share revisions. A share revision is a value snapshot derived from a private capture, so cleanup and sender editing never rewrite raw audio, raw transcript, or the local `Interjection`. Packaging accepts only explicitly selected revisions and either:

- the sender-approved transcript as text only; or
- that transcript plus the selected deterministic-cleanup audio file.

The manifest keeps source identity distinct from item identity. A source is a reusable feed or publisher surface; an item is the discrete episode, article, post, native text, or document-derived text being listened to. Every package declares one item transport:

- `reference`: the URL-backed item is reconstructed by the recipient and no item payload is sent;
- `embedded_text`: the exact listened-to text is a digest-covered artifact, permitted only for app-authored content or after the sender confirms a private share within their rights; or
- `recipient_supplied`: the item is omitted, Margin export remains available, and the recipient must provide a matching item.

The manifest carries item identity, optional source identity, transport and rights disclosure, a package-scoped ID, bounded anchor evidence, the selected representation and its provenance, and an explicit redaction record. Archive audio names are generated package-relative paths. Podcast media, raw or unselected capture representations, diagnostics, API data, device paths, unrelated turns, and app state have no manifest fields. Full item text appears only in the explicitly disclosed `embedded_text` artifact.

The package digest is deterministic across identical manifest, generated preview, item artifacts, and audio inputs. It detects modification but does not authenticate the sender. Import rejects malformed containers and JSON, unsafe entries, invalid declared references, unsupported schema versions, missing privacy or embedded-item rights assertions, attachment mismatches, unreadable audio, and digest or preview mismatches before creating recipient data. A verified package cannot be constructed by a caller; only the checked archive reader can mint the value accepted by import. Export and extraction stage replacements so a failure preserves the prior destination.

Imported commentary uses recipient-local primary keys in separate `ImportedCommentaryLayer` and `ImportedCommentaryInterjection` record kinds. Package IDs remain provenance. The verified package digest makes a second import a stable duplicate instead of creating another layer. Recipient-confirmed imports are enabled in Companion mode by default, but import itself never starts playback. A sender reveal-mode suggestion is stored separately from recipient policy. The recipient can select Fresh, Companion, or Guided per layer, and the playback-level auto-play switch maps the enabled layers onto the existing Guided versus Companion modes rather than adding another setting model. Anchor outcomes are persisted per note and the layer result is derived from them. SQLite stores the additions as append-only typed records in the existing record table, so no destructive schema migration or flattening into local sessions/interjections is required. A share-revision ID is immutable: an identical save is idempotent and a conflicting save fails explicitly.

## Cleanup and anchor policy

`cleanup.v1` proposes bounded, reproducible edits over aligned transcript segments and the immutable original recording:

- case-insensitive removal of `um`, `uhm`, `uh`, `ah`, `ahh`, `er`, and `erm` as whole aligned tokens;
- removal of “you know” only when timing or punctuation isolates the phrase;
- aligned-speech detection of internal non-speaking intervals of at least 750 ms even when sustained background sound makes the interval acoustically loud, retaining 140 ms of natural spacing and never entering an aligned word range;
- acoustic detection of additional leading, trailing, and internal quiet runs of at least 360 ms, retaining 80 ms at recording edges and 140 ms internally while protecting recognized speech with a 50 ms flank;
- sender-selected removal of an aligned word from both reviewed text and cleaned voice, with no route for inserting text that cannot exist in the recording;
- individually restorable, stable decision IDs.

The sender reviews one compact inline transcript. Tapping a word or bracketed pause removes or restores it in place; accepted edits are crossed out, and no duplicate vertical toggle list or text-insertion route is present. A transcript that actually exceeds 10 rendered lines defaults to a 10-line preview with an explicit expansion control; shorter transcripts retain the direct editor without unnecessary disclosure UI. Undo and Redo cover word and automatic-cleanup choices. The private capture is never rewritten; only a reviewed derivative is rendered with 15 ms crossfades. Substring replacement is not used, so words such as “umbrella” remain intact. Package anchor evidence normalizes whitespace and retains at most the nearest 500 characters before and after, plus at most 1,000 characters of exact text.

Private Timeline curation is distinct from outgoing selection. A visible star and optional 500-character private note persist on the local Interjection only. When at least one active item Margin is starred, sender review initially shows and includes only starred Margins; without stars it preserves the all-included default. The All/Starred filter changes what is visible, while **Include this Margin** remains the final per-export choice. Stars and notes never enter share revisions, session exports, packages, imported layers, or recipient UI.

If every spoken segment would be removed as filler, `cleanup.v1` retains the original transcript and marks those speech-removal decisions unaccepted. Text and accepted audio-removal decisions therefore cannot disagree about deleting all speech. Text normalization uses a fixed POSIX locale rather than device locale.

Article resolution accepts raw offsets only when an exact-edition SHA-256 over the unmodified UTF-8 source matches and any supplied exact quote matches the range. A normalized-content match is useful source evidence but never authorizes raw offsets. The resolver then tries a unique exact quote and a unique normalized-token quote, using bounded context only to break a clear tie. Repeated material without a clear winner stays ambiguous. A different source stays wrong-source, and a matching source without locally resolvable text stays context-only.

## Deferred boundary

The app exposes sender review from the listening Share screen, the system share sheet for the resulting file, recipient disclosure/import, same-device recipient testing, distinct Shared Margins controls, cueing/playback, and Timeline provenance. Item actions are shown before optional Listening Map tools, and the item screen presents only one map-generation route. At an evidence-backed text or podcast anchor, Companion playback pauses the source, sounds a cue, and exposes Listen and Dismiss in the app and every actionable Lock Screen Live Activity presentation; either choice returns to source playback. Those controls use shared `LiveActivityIntent`/`AudioPlaybackIntent` definitions so iOS executes their handoff in the app process, while the canonical app model remains the sole audio owner. iOS still requires device authentication before a locked-device button performs its action.

The Live Activity's next-navigation entry is an ordered projection rather than a mutation of source structure. It compares the next publisher chapter with verified upcoming Shared Margins and presents whichever occurs first. With no chapters it can therefore show the next Shared Margin; with chapters, Margins appear between them at their resolved source positions. Selecting a Margin moves to its verified local anchor and explicitly reveals it: Guided begins it after the cue, while Fresh or Companion waits for Listen or Dismiss. Shared Margins are never persisted as publisher chapters, and ambiguous or unresolved anchors are never made navigable. Guided mode sounds the same cue and begins the Margin after it. The playback-level auto-play switch chooses Guided or Companion for enabled layers. It does not implement co-op replies (#19), AI synthesis (#26), accounts, hosted storage, public distribution, offline Listening Map generation, proposal activation, or summary/Skim playback. The one-way v1 manifest deliberately omits conversation and parent-package fields so the later #19 reply model is not frozen by this MVP.

## Experience Overhaul action model

The later Experience Overhaul should preserve the actions and state transitions below without treating today's screen hierarchy or controls as a design constraint.

Sender actions:

1. Capture a Margin and continue listening without losing source position.
2. Mark a Margin for later sharing and optionally retain a private reminder about why it matters.
3. Enter sharing from the item or active listening context.
4. Choose the outgoing Margins, using the prior shortlist as a starting point rather than a binding selection.
5. Prepare and review each outgoing representation: transcript deletions, filler/non-speaking-gap proposals, Original/Cleaned/Text choice, preview, Undo, and Redo.
6. Review item transport and make the required rights choice for linkless items.
7. Confirm the exact package contents, share the file, and retain a recoverable local record of what was approved.

Recipient actions:

1. Inspect who or what the package claims to come from, its unsigned-integrity status, the referenced item, and whether local item acquisition is required.
2. Import without autoplay, resolve anchors conservatively, and explicitly enable or disable the resulting commentary layer.
3. Choose a reveal policy for that layer and optionally mute its cue.
4. While listening, understand the ordered upcoming source events—publisher chapters and verified Shared Margins—without conflating their provenance.
5. At a Companion cue, choose Listen or Dismiss from the active playback surface or authenticated Lock Screen; in Guided mode, hear the Margin after the cue.
6. Navigate directly to a verified upcoming Margin, return to the source afterward, and revisit received Margins from item history.

The overhaul can combine, split, reorder, or visually redesign the surfaces, but it should preserve three decision boundaries: no outgoing representation without sender review, no embedded linkless item without the displayed rights basis, and no recipient interruption or navigation for an unresolved anchor.

The explicit item-transport and rights policy is now implemented. External use remains pending product-owner validation; automated tests are developer evidence only.

## Audit method

The regression target is broader historical code from `codex/sharingV1` accidentally importing app, playback, reply, article-acquisition, project, or site behavior. The lane audit compares every historical path with this bounded implementation and fails the packet if a forbidden path changes.

The falsification suite covers deterministic archive bytes and digest, preview tampering, malformed archive/JSON, unsupported versions, private-path rejection, invalid audio, destination rollback, transport/rights mismatches, linkless embedding without an assertion, recipient-supplied items, data minimization, unselected-audio omission, immutable revision IDs, cleanup substring and all-filler safety, manual-word undo, acoustic edge-silence detection, sustained-noise non-speaking-gap detection without aligned-speech overlap, context bounds, normalized-hash offset collisions, recipient-controlled activation, recipient-local ID mapping, per-note resolution, duplicate import, SQLite preservation, ordered chapter/Margin navigation, and resolved/ambiguous/wrong-source/context-only outcomes. The stopping rule is any confidently wrong resolution, undisclosed outgoing field, nondeterministic duplicate, private-original mutation, transport that contradicts the sender disclosure, navigation to an unresolved Margin, or need for an unapproved trust decision.
