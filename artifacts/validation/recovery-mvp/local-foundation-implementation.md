# Recovery MVP Local Foundation Implementation

- Date: 2026-08-03
- Branch: `codex/mvp-local-foundation-models`
- State: `verified`; not `human_validated`

## In scope

- Issues #45 and #47 playback regressions.
- Issue #46 public podcast-link matching and ambiguity selection.
- Issue #42 default-off remote-provider boundary, local interjection summary, and bounded Listening Map spike evaluation.
- Issue #43 termination cleanup for generated-turn Now Playing ownership.
- Publisher chapter ingestion for native-audio podcast items, with mapless fallback in the default release.
- Preservation of copy/export and pasted-assistant-response import.

## Architecture evidence

- `SMRemoteProviderExperienceEnabled` is the single release switch and defaults to `false`.
- Remote-only UI, capabilities, retries, probes, and transport entry points are gated independently so one missed UI condition cannot enable a network request.
- Local model availability comes from `SystemLanguageModel.default.availability` and is refreshed when the app becomes active.
- The on-device map spike retained deterministic offsets/timestamps, but product-owner testing found unacceptable latency and a media-outside-timeline failure. The default release no longer exposes or invokes this path.
- Native-audio transcripts remain internal. Session export already suppresses native-audio full text/transcripts, and playback exposes source text only for `item_text_tts` targets.
- Publisher chapter precedence is Podcasting 2.0 JSON, inline Podlove Simple Chapters, embedded ID3/MP4 metadata, then timestamped episode descriptions. Publisher maps retain only chapter metadata and timing; they do not make a native-audio transcript user-visible or exportable.

## Automated verification

- `scripts/validate-contracts.py`: passed; 22 Supertonic files validated.
- `scripts/validate-surface-contracts.py`: passed.
- `swift build --build-tests --package-path Packages/SessionKit`: passed.
- `swift test --package-path Packages/SessionKit`: 131 tests passed with 0 failures.
- Focused `SpokenMarginsAppTests` suite: 15 tests passed with 0 failures, covering the release flag, local summary and map paths, link resolution and candidate review, playback-rate persistence, and explicit termination cleanup.
- Interrupted-summary eligibility regression: 1 test passed with 0 failures.
- Generic iOS device build for `SpokenMarginsApp`: passed.
- Publisher chapter parser and resolver tests: 38 `SourceLinkImportTests` passed with 0 failures, including Podcasting 2.0 JSON, alternate-prefix Podlove XML, timestamped descriptions, and Apple canonical-feed recovery.
- Publisher chapter engine tests passed for precedence, persistence, later transcript attachment, and timestamp navigation without transcript segments.
- After product-owner device feedback, focused coverage increased to 40 `SourceLinkImportTests` plus 7 `LocalFoundationModelsTests`, all passing. The fixtures cover the No Agenda legacy Podcasting namespace, structured publisher episode pages, deterministic disfluency cleanup, guided summary bounds, hierarchical partial reduction, and rejection of source-anchor copying.
- On-device map retirement coverage: 4 focused app tests passed with 0 failures, proving that default-release podcasts do not expose or invoke AI map generation or full-source transcription, deterministic native-text maps remain available, and local interjection summaries still complete without an API key.
- Final-audio closeout coverage passes with a completion-aware app regression. It distinguishes completion from external pause, closes after the final queued audio, returns Home, and persists a finished session despite normalized text-offset rounding.
- After the first repaired summary failed safely on device, summary generation was narrowed to one guided rewrite per interjection with an automatic note-only retry after an Apple safety rejection or local output-validation rejection.

## Pending human and device evidence

- Representative real-feed checks plus physical-device ID3/MP4 embedded-chapter extraction after download.
- Product-owner revalidation of the per-interjection structured summary with note-only safety fallback after installing a build containing the latest follow-up.
- Device/build identity and diagnostics for the final release candidate.

Only the product owner can advance the flows to `human_validated`.
