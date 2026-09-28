# E1 · structure: turn spoken Margins into something you can navigate

**Outcome.** Every Margin gets a small structured form next to the natural-language original:
- what kind of statement it is (claim, question, reaction, to-do, quote);
- what exactly in the source it's about;
- which people, places and topics it mentions;
- which other Margins, scenes, or (with permission) notes in the listener's vault it relates to.

The listener can then browse by those dimensions ("my open questions this month", "everything I said about this person"). Weekly reviews and group clustering are built on them.

This all happens on the device, with no server call, ever. Without on-device AI, a deterministic method still produces a useful, lower-confidence version.

**Why.** Turning one-dimensional word-by-word listening into a multi-dimensional graph of the content and the listener's thinking, navigable mostly by lookups rather than AI.

**Where.** The evaluation set and deterministic baseline can start in the cloud. On-device producers, and anything using Apple's NaturalLanguage or Foundation Models frameworks, are host-testable on the Mac.

**Seams.** Owns **I7** (structured Margin record, published in M2) and the entity fields of **I8**. M4 uses I12 read access, which D4 publishes in its M2.

## Starting points

- Margins (`Interjection` in `SessionKit/Models.swift`) already carry `transcript`, `cleanedTranscript`, an `anchor` (text offsets or media time, plus before/after context) and word-aligned transcripts. The context window is 90 s before and 120 s after (`docs/media-transcript-model.md`, `SourceAnchorContext.swift`).
- There's no typing, tagging or categorization today. `LocalInterjectionClaimInventory` (in `LocalFoundationModels.swift`) is an internal claim inventory used only for summary validation; see whether it's a head start.
- On-device Foundation Models calls already exist for listening maps (`AppleFoundationModelClient`), with an output validator.
- Apple's NaturalLanguage framework offers deterministic, on-device named-entity recognition and lemmatization. It's a candidate for the no-AI path.
- The owner's constraint on vaults: **no AI over the vault, ever, not even on-device.** Only the listener's own Margins are processed, and matching against notes is by synonyms and patterns.

**Research in the cloud with spaCy (M1).** The owner suggested spaCy, and it works in the cloud environment. `pip install spacy` succeeds, and the English model installs from Hugging Face (`pip install https://huggingface.co/spacy/en_core_web_sm/resolve/main/en_core_web_sm-any-py3-none-any.whl`), since GitHub downloads may be blocked. It's the right tool for designing the taxonomy, labeling quickly and scoring. But spaCy can't ship in the iOS app, so score two baselines:
- **Upper bound:** anything spaCy can do.
- **Portable:** only what the phone can reproduce deterministically: Apple NaturalLanguage's entity types (person, place, organization), lemmas and parts of speech, plus word lists and regular expressions.

The gap between them tells M2 whether the no-AI path is good enough or needs a small bundled model.

**The owner's own Margins.** The owner can export their Margins and attach the files when starting this stream's session. Either works:
- Margins tab → Export Sessions: one Markdown file per session, with source context around each Margin.
- The notes folder, if Margin Output is set up: one `Margin-<id>.md` per Margin, with context before and after.

In Files, long-press the folder → Compress, then attach the zip. Keep the raw export out of git: it's the owner's personal thinking plus publishers' text. Commit only labels keyed by Margin ID, plus scores. A later session needs the zip re-attached.

## Milestones

**M1: What "good" means** (cloud).
- Done when:
  - A small taxonomy (statement kinds, referent, entities, link types) is written on the tracking issue.
  - A labeled evaluation set of at least 150 Margins with their source context exists, built from Margins written against public podcasts and articles and committed under `research/E1/`.
  - Both baselines (spaCy upper bound, portable) are scored on it, with per-category results.
  - (owner) If the owner attaches their own export, it's labeled as a second set and both baselines are scored on it too. Only its labels and scores are committed.

**M2: On-device producers.**
- Done when both producers (Foundation Models where available, deterministic otherwise) fill I7 for every new Margin, and on the evaluation set:
  - Foundation Models: at least 80% statement-kind accuracy and 85% referent accuracy (the right sentence or moment).
  - Deterministic: at least 65% and 75%.
- Each record names its producer and confidence. Records are rebuildable, and deleting them loses nothing. Processing runs only for new or edited Margins.
- Processing one Margin costs under 2 s in a Mac host measurement, scaled by a stated Mac-to-phone ratio.
- (owner) Confirm it's under 2 s on the owner's phone.

**M3: Navigate it.**
- Done when:
  - Scenes in listening maps carry people, places and topics (I8).
  - The Margins screen can filter by statement kind and by entity.
  - Two Margins that share an entity or referent are linked.
  - Lane T4 walks those filters on a seeded library.

**M4: Related notes from the vault (opt-in).**
- Done when:
  - With read access granted to a notes folder, the app suggests related notes for a Margin using only lexical and synonym matching.
  - Precision is at least 70% on an owner-labeled sample of 50 Margins.
  - Indexing is incremental. Its cost on 5,000 synthetic notes is measured on the Mac host, and it runs only while charging if the projected cost exceeds a stated budget.
  - (owner) The owner checks the suggestions against their own vault and accepts the battery budget.
  - No note content leaves the device or goes through a model.

## Must not break

Packets: structured records stay out of them unless the owner decides otherwise, after an I10 compatibility check. Margin capture and playback latency.

## Out of scope

Cross-user knowledge graphs. Embedding-based semantic search (#48). Consider it after M3 if lookups fall short.
