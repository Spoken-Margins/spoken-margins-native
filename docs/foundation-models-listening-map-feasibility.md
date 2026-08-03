# On-Device Foundation Models Feasibility

## Decision

The Recovery MVP can remove third-party model traffic and API-key setup without removing the conversational workflow. Keep export/copy and pasted-assistant-response import, hide Discuss and bring-your-own-provider UI behind one disabled-by-default release flag, and offer local interjection summaries only when Apple Foundation Models is available.

The on-device Listening Map spike demonstrated technical feasibility but failed the MVP stopping rule. On 2026-08-03, product-owner device testing found podcast generation unacceptably slow and observed a `media data outside timeline` failure. The Recovery MVP therefore ships publisher podcast chapters, deterministic native-text maps, and mapless podcast fallback; AI-generated Listening Maps move to a future server-hosted path behind the remote-provider feature flag.

## Implementation Status

The bounded spike is now `implemented` on `codex/mvp-local-foundation-models`; product-owner validation has not occurred. The release Info.plist key `SMRemoteProviderExperienceEnabled` defaults to `false`. With that value, the app filters remote-only capabilities, blocks provider transports and probes, fails restored remote jobs instead of retrying them, hides Discuss/follow-up/API-key UI, and retains copy/export plus pasted-response import.

The evaluated spike used `NLEmbedding` adjacent-window distance with a lexical fallback, deterministic minimum/maximum character and media-duration bounds, stable character offsets and transcript segment/time anchors, one Foundation Models label request per bounded section, and a final overview request over labels only. Each label prompt was capped at 6,000 characters; title, description, overview, position, quotation, and ordering constraints were checked in app code before persistence. This code is retained as research evidence but is not reachable from the default MVP product path.

Publisher podcast chapters are the only podcast map path in the default MVP: [Podcasting 2.0 chapter JSON](https://github.com/Podcastindex-org/podcast-namespace/blob/main/docs/tags/chapters.md), [Podlove Simple Chapters](https://podlove.org/simple-chapters/), embedded timed chapter groups loaded through [AVFoundation](https://developer.apple.com/documentation/avfoundation/avasset/loadchaptermetadatagroups(bestmatchingpreferredlanguages:)), and conservative timestamped-description parsing, in that order. The embedded path uses the platform metadata abstraction for formats such as ID3 `CHAP`/`CTOC` and MP4 rather than maintaining a custom binary parser; the underlying ID3 timing and title semantics are documented in the [ID3 Chapter Frame Addendum](https://id3.org/id3v2-chapters-1.0). Podcasts without publisher chapters remain mapless.

## Challenge Model

### Product constraints

- The default release must make no third-party model request, including restored jobs, retries, capability delegation, or fallback.
- Devices without an available local model retain playback, interjections, export/import, deterministic native-text maps, and mapless listening. They do not show unsupported summary or generated-map actions.
- A valid publisher map or adequate deterministic map is never silently replaced.
- A generated native-audio transcript is internal derived data. It is not a transcript-reader, search, clipboard, share, export, portable-package, or diagnostics surface.
- User-visible native-audio derivatives are limited to attribution, map overview, chapter titles/descriptions, timestamps or resolved positions, and bounded before/after context for a saved interjection.
- The app does not generate or publish a claims list in the Recovery MVP.

### Platform resources

- Apple Foundation Models supplies a private on-device language model, guided generation, availability reporting, and streaming responses on eligible systems.
- The model context is finite. Apple documents a 4,096-token session context and a `contextSizeExceeded` error. Instructions, prompts, generated-content schemas, and responses all consume that window.
- Apple explicitly assigns long-input partitioning to the app: split the work into separate sessions, summarize each part, and combine the summaries in another bounded pass.
- Natural Language supplies local sentence embeddings through `NLEmbedding`, allowing similarity and distance calculations without spending Foundation Models context.
- The existing app already has deterministic article structure and on-device Speech transcription paths that can produce stable text or timestamped transcript segments.

### Failure modes

- Context overflow, truncation, or excessive multi-pass latency on long items.
- Chapters that are well worded but point to the wrong timestamp.
- Over-segmentation around speaker turns, ads, transcript errors, or short digressions.
- Under-segmentation when a topic returns after a long interval.
- Loss of negation, attribution, contrast, or causal structure after aggressive word filtering.
- Model or OS updates changing labels and summaries for the same source.
- Thermal, memory, battery, language, or availability failures on eligible-looking devices.
- Full transcript text escaping through prompts logged to diagnostics, generated output, export, crash reporting, or debug UI.

## Apple Context Handling

Apple has documented a good hierarchical summarization recipe, but the framework does not invisibly chunk long input. Each app request must stay inside the session context. A robust pipeline therefore needs its own token budget, stable source segments, independent sessions, cancellation, progress, and deterministic merge logic.

This is useful rather than merely limiting: separate sessions prevent the full transcript plus accumulated generations from filling one context, and stable segment IDs let app code resolve positions without trusting model-estimated percentages.

Sources:

- [Apple: Managing the context window](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window)
- [Apple Technical Note TN3193: Managing the on-device foundation model's context window](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window)
- [Apple: Foundation Models](https://developer.apple.com/documentation/foundationmodels)
- [Apple: NLEmbedding](https://developer.apple.com/documentation/naturallanguage/nlembedding)
- [Apple: Finding similarities between pieces of text](https://developer.apple.com/documentation/naturallanguage/finding-similarities-between-pieces-of-text)

## Candidate Approaches

### Deterministic structure only

Use publisher chapters, Markdown headings, and other explicit structure. This is cheap, repeatable, and fully explainable, but heading-free articles and most raw podcast transcripts remain mapless.

### Hierarchical Foundation Models only

Split the full item, summarize every chunk, and repeatedly summarize the summaries. This follows Apple's long-input recipe, but it spends model work across the whole item before knowing where topic boundaries matter. It also risks producing evenly sized summaries rather than navigational chapters.

### Lexical cohesion

TextTiling-style algorithms compare the vocabulary of adjacent windows and place boundaries at cohesion valleys. They are inexpensive and established, but synonymy and transcript noise can weaken a surface-word signal. Hearst's original TextTiling paper is the baseline reference: [TextTiling: Segmenting Text into Multi-paragraph Subtopic Passages](https://aclanthology.org/J97-1003/).

### Sentence-embedding change points

Create local sentence vectors, compare smoothed windows before and after each candidate point, and propose boundaries at large semantic-distance peaks. This sees paraphrases that lexical overlap misses and can inspect the entire transcript without consuming language-model tokens. `NLEmbedding` is the first implementation candidate; TextTiling is the fallback and comparison baseline.

Spoken segmentation research supports treating a boundary as low information continuity between adjacent regions, while also showing that transcript segmentation is a distinct evaluation problem rather than ordinary summarization: [Topic Segmentation of Spoken Narratives](https://aclanthology.org/2022.emnlp-main.457/) and [Text Segmentation as a Supervised Learning Task](https://aclanthology.org/N18-2075/).

## Recommended Spike Pipeline

1. Prefer a valid publisher map or adequate deterministic map. Start model work only when neither satisfies the map contract. Whether the eligible action begins automatically after intake or from an explicit user action remains a product decision; the pipeline must support cancellation and must not block playback either way.
2. Normalize the source into ordered, stable segments. Retain character positions for text and segment IDs plus start/end media times for native audio. Treat headings and publisher chapter markers as hard evidence.
3. Propose soft boundaries over the complete item without Foundation Models. Compute sentence embeddings locally, smooth adjacent-window distance, add transcript-gap and explicit-structure evidence, then enforce minimum and maximum chapter duration. Use lexical cohesion when embeddings are unavailable for the language.
4. Consolidate candidates deterministically. Reject clusters of near-duplicate cuts, preserve strong hard boundaries, and retain the confidence and evidence for every proposed boundary.
5. Give Foundation Models one bounded candidate segment at a time. Request only a short navigation title, a short description, and the stable segment IDs covered. When a candidate is itself too large, produce compact internal chunk cards in independent sessions before generating its label.
6. Build the global map from compact cards, not the full transcript. A final bounded pass may improve titles, remove duplicates, and write a short overview while retaining candidate IDs.
7. Resolve chapter timestamps, order, coverage, and percentages in app code. Reject any model output with unknown IDs, non-monotonic positions, excessive source quotation, invalid structure, or insufficient coverage.
8. Replace nothing until the complete map validates. Cancellation, resource pressure, model unavailability, or any failed stage leaves the prior map and playback state unchanged.

## Assessment Of The Proposed Compression Ideas

Chunk summaries or bullet cards are useful after the app has retained stable source IDs. They reduce the material needed for a global coherence pass. They are a poor primary boundary detector because a summary can omit short but navigationally important transitions and makes it difficult to recover exact source positions.

Reducing a transcript to nouns and verbs should not be the input to Foundation Models. It removes negation, discourse markers, questions, speaker attribution, modality, and pronoun relationships—the very signals that distinguish “the author supports X” from “the guest rejects X.” Stop-word removal and lemmatization are reasonable inside a lexical-cohesion baseline, where the original transcript and offsets remain authoritative. They should not replace the original bounded text used for labels.

## Evaluation And Audit

Use the same representative corpus for all alternatives: heading-rich and heading-free articles; short and long podcasts; interviews and monologues; noisy transcripts; ads; repeated topics; and topics that return after a long gap.

Compare at least:

- current deterministic map or mapless baseline
- TextTiling-style lexical boundary proposals
- local sentence-embedding proposals plus bounded Foundation Models labels
- pure hierarchical Foundation Models on a smaller evaluation subset

Record:

- accepted boundary precision/recall or distance from a reference boundary
- chapter coverage, duplicate rate, and unresolved-anchor rate
- omission checks for openings, closings, minority topics, negation, proper nouns, and topic returns
- latency, cancellation responsiveness, peak memory, thermal state, and energy impact
- model availability and unsupported/failure rate by device and language
- bytes or fields capable of leaving the internal transcript boundary
- product-owner usefulness judgments, kept distinct from automated verification

Falsification tests include adversarial transcript text requesting disclosure, invalid segment IDs, source quotation in generated fields, repeated headings, long sponsor segments, interrupted generation, process restoration with a previously pending remote job, and an unavailable local model. A single remote request or transcript leak is a release-stopping failure.

The generated-map MVP path was stopped on 2026-08-03 because physical-device podcast latency was unacceptable and a generated media map failed timeline validation. Ship local interjection summary plus publisher/deterministic/mapless listening, and retain the map work as post-MVP server-hosted research. Reconsider only with a bounded server prototype that beats the mapless baseline, produces fully resolvable timestamps, preserves the transcript-disclosure boundary, and has an explicit cost/privacy policy.

## Legal And Fairness Boundary

This design deliberately exposes less than Apple Podcasts' transcript feature. Apple Podcasts permits copying up to 200 transcript words with attribution; Spoken Margins should not use that allowance as its product target. The Recovery MVP exposes navigation derivatives and bounded interjection context only. This is a conservative product rule, not a legal conclusion; excerpt rights and jurisdiction-specific questions remain subject to the separate rights-policy work and qualified legal review.

Apple references:

- [Apple Podcasts for Creators: Transcripts on Apple Podcasts](https://podcasters.apple.com/support/5316-transcripts-on-apple-podcasts)
- [Apple Podcasts User Guide: View a podcast transcript](https://support.apple.com/guide/podcasts/view-a-podcast-transcript-pod96aaf8353/mac)
