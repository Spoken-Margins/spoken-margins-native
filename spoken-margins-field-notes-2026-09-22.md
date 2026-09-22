# A small museum of not losing your place

Field notes from Spoken Margins on September 22 2026

The most interesting thing I found in this project is how much engineering hides inside the ordinary phrase **“where was I?”** A listener means a passage, a thought, a voice, a session, and sometimes another person's interpretation of the same work. The app has to preserve those distinctions while making interruption feel effortless.

My reading of the issue history is that Spoken Margins is gradually discovering the full cost of that promise. The source contains unusually concrete examples of what it takes to keep it.

This is an exploratory essay, not a release assessment or a new plan. I read the supplied Word document's full extracted body, counted its issue entries, and followed selected claims into local documentation, implementation, and tests. The checkout was `codex/provisional-next` at `82e61bcec35e309dd9ad38eb64f824ae5e45766b`. No builds, tests, simulators, network lookups, or app interactions were run. Test descriptions below are observations about test code, not fresh passing results. The Word document was read for content, not audited for page layout.

## The atlas has several kinds of geography

The supplied [issue history](spoken_margins_issue_history_2026-09-22.docx) reports 125 issues, of which 71 were open and 54 closed at its snapshot. I independently counted the entries in its open-issue atlas: **71 entries, 71 distinct issue numbers**.

| Atlas territory | Open entries |
|---|---:|
| Sharing, rights, collaboration, and trust | 17 |
| Maps, anchors, chapters, and document semantics | 14 |
| Native-text audio, offline preparation, and resources | 11 |
| UI, Library, and performance | 12 |
| Hands-free capture and remote controls | 6 |
| Sources, onboarding, release QA, and automation | 7 |
| Platform and product expansion | 3 |
| Administrative residue | 1 |
| **Total** | **71** |

These are counts of the document's categories, not estimates of effort or severity. The largest category contains both concrete sharing work and distant concepts such as classroom exchange and federation. One memory termination can matter more to today's listener than that entire future landscape.

There is another useful arithmetic detail: the seven named closure waves sum to 47, leaving seven of the reported 54 closures outside those highlighted waves. The history offers representative episodes rather than an exhaustive chronology. Its biggest wave, September 12, accounts for 14 of 54 closures, about 26%. That is consistent with a concentrated acceptance/reconciliation event; it does not establish when the underlying engineering happened.

To make sense of this terrain, I kept five layers separate:

| Layer | What belongs here |
|---|---|
| Resources | Device memory, storage, battery, compute, owner attention, engineering time |
| Execution | Session engine, speech and media adapters, background work, UI surfaces |
| Objects | Sources, editions, sessions, generated turns, Margins, maps, packages |
| Work | Repair, implementation, research, measurement, acceptance, release preparation |
| Evidence | Source code, test assertions, recorded runs, device observations, owner acceptance |

This prevents an attractive shortcut: interpreting every open issue as missing implementation and every existing implementation as an accepted product capability.

## Exhibit one is an unhelpful looking function

In [PodcastAnchorEvidence.swift](Packages/SessionKit/Sources/SessionKitAudio/PodcastAnchorEvidence.swift), `timestampFallback` accepts sender duration, recipient duration, and identity evidence, then returns an unresolved anchor. Its comment explains why: the held-out corpus defeated duration-only guards.

Here is a paper experiment that makes the failure obvious. Imagine two editions of an hour-long episode. Edition B inserts a 30-second ad before a passage and removes 30 seconds after it. Both editions last an hour. The passage has nevertheless moved by 30 seconds.

Equal duration is compatible with unequal local position.

The interesting design choice is preserving uncertainty rather than turning a familiar-looking timestamp into a confident placement. The surrounding implementation distinguishes ambiguous and unresolved evidence, combines acoustic and transcript evidence, and has explicit handling for partial flanks. This is source evidence of an attempted solution; it is not proof that the broader corpus problem in #27 is solved.

**My interpretation:** a shared Margin needs something like a citation, not merely a bookmark. Its address must survive a change of edition, or admit that it cannot.

## Exhibit two is a tiny translation dictionary

[SpeechTextNormalizer.swift](Packages/SessionKit/Sources/SessionKit/SpeechTextNormalizer.swift) carries `sourceOffsets` alongside normalized speech. It can resolve a spoken character back to the source and find the first retained spoken character at or after a source offset.

That bookkeeping makes a surprisingly large promise possible: speech can become easier to hear without silently rewriting the thing being cited.

The current code labels bracketed numeric references as citations or footnotes. It pronounces defanged domains with explicit separators. Newly inserted spoken characters still receive source offsets. Meanwhile, [CanonicalSourceModels.swift](Packages/SessionKit/Sources/SessionKit/CanonicalSourceModels.swift) represents canonical locators with UTF-8 offsets and supplies an adapter for the legacy character-offset model.

Those are different coordinate systems. The test suite makes the distinction visible with the modest sentence `A café ☕️ closes late.` Its Unicode locator test sits beside prepared-audio mapping tests in [QualityOfLifeModelsTests.swift](Packages/SessionKit/Tests/SessionKitTests/QualityOfLifeModelsTests.swift).

The September 21 [handoff](artifacts/validation/gate-1/qol-2026-09-21/handoff.md) also preserves a useful limit: ordinary parenthetical numbers such as `(17)` remain unchanged because punctuation alone does not establish citation intent. Issue #138 is explicitly partial.

**My interpretation:** narration is a translation with an address book. Losing the address book would make cleaner speech surprisingly destructive.

## Exhibit three preserves room around a thought

The default context window in [SourceAnchorContext.swift](Packages/SessionKit/Sources/SessionKit/SourceAnchorContext.swift) extends 90 seconds before and 120 seconds after a native-audio interjection. The code distinguishes this human-readable context from the durable machine anchor.

I like this distinction. A machine may need enough evidence to locate a passage; a person returning tomorrow needs enough surrounding argument to remember why they cared.

The resolver also refuses false word-level precision. When the interjection falls within a short timed transcript segment, it keeps that segment intact before the marker. Longer segments can be proportionally sliced, with word-boundary adjustments. These are approximate reconstructions, not evidence of exact forced alignment.

The [product contract](Contracts/docs/recovery-mvp.md) describes overlapping session-export windows being merged around chronologically embedded interjections. That makes the intended exported object richer than a pile of isolated quotes: it is a recoverable listening experience.

**My interpretation:** the Margin's useful unit is a thought with enough surroundings to re-enter it.

## Exhibit four is two equally long secrets

[ExportIsolationRegressionTests.swift](Packages/SessionKit/Tests/SessionKitTests/ExportIsolationRegressionTests.swift) contains a particularly good specimen: `testEqualLengthNotesFromAnotherSessionCannotSubstituteForExportContent`.

The test creates two sessions on the same item and gives them different private notes with equal UTF-8 lengths. It then checks that each export contains the selected session's note and excludes the other.

This deliberately defeats a weak proxy. Checking that an export exists, has content, or has the expected size would not establish that it contains the right person's listening moment.

It echoes the podcast example beautifully:

| Tempting proxy | What it fails to establish |
|---|---|
| Same episode duration | Same passage at the same timestamp |
| Same exported note length | Same note or correct session |
| Same apparent character position | Same UTF-8 location |
| Same issue number | Same remaining scope or accepted candidate |

The last row belongs to the project's records rather than its runtime. It leads to the most useful surprise in this exploration.

## Exhibit five is the history disagreeing with its subject

The Word document explicitly says it is an issue history, not a code audit. Looking around the repository demonstrates why that qualification matters.

| Topic | Word snapshot | Local evidence and bounded conclusion |
|---|---|---|
| #125 sharing | Describes a share control on each Margin row | The latest release-lane direction and September 21 handoff specify item-group sharing through the existing item export screen, explicitly excluding individual-Margin sharing. The report's feature description conflicts with the recorded owner correction. |
| #109 workspace | Retains detail-action feedback and context recovery as pending owner retry | The September 21 owner-acceptance note accepts the remaining behavior and singles out export relocation as incomplete. The issue-history description appears behind that local acceptance record. |
| #61 EPUB | Presents source-format expansion requirements | The QoL evidence matrix records a verified EPUB implementation, and canonical source models and EPUB safety tests exist. An open issue does not establish absence of code; acceptance and broader scope remain separate. |
| #74 charging preparation | Calls it a future capability | The QoL matrix records implementation evidence. The background controller requests external power and retains durable-job recovery semantics. This establishes concrete code, not successful overnight execution on a physical device. |
| #138 citation speech | Describes the requested normalization | Source and the September 21 handoff show a bounded implementation with explicit exclusions. It is neither wholly absent nor complete. |

Sources: [release lanes](docs/release-lanes.md), [owner acceptance](artifacts/validation/gate-1/qol-2026-09-21/owner-acceptance.md), [QoL handoff](artifacts/validation/gate-1/qol-2026-09-21/handoff.md), [QoL evidence matrix](docs/quality-of-life-issue-evidence.md), and [background controller](App/SpokenMarginsApp/Sources/SpokenMarginsApp/AudioPreparationBackgroundController.swift).

Even the owner-acceptance note retains older “row-level sharing” wording for #125; the explicit correction and more specific handoff resolve its meaning. No single file is an oracle for every kind of question.

An issue timeline answers whether an issue was closed at a particular snapshot. Owner direction determines intended scope. Source establishes that code exists. A run establishes something about particular inputs and a particular candidate. Owner acceptance establishes the exercised experience. Each record has its own coordinates.

The current commit subject is `untested QoL UI/UX imporvements`. I would not infer the exact verification state from that subject, but I would also not promote older run summaries into evidence for this HEAD. Candidate identity matters just as much as episode identity.

## The larger pattern I would keep watching

My strongest hypothesis is that **preserving context across transformations is the project's organizing problem**. A source becomes speech; speech is interrupted; an interruption becomes text; text becomes an export; an export becomes someone else's commentary layer. Every transformation risks losing identity, position, ownership, or uncertainty.

There are credible competing explanations. This could primarily be a playback-reliability project: headset behavior, background work, memory pressure, and lock-screen transport remain consequential. It could primarily be an interaction-design project: Add Text, completion notices, chapter orientation, and Following controls all affect daily usefulness. The context hypothesis earns its place because it connects several otherwise separate implementation details; it does not make resource or interface problems secondary by decree.

Three questions would distinguish these interpretations in future evidence:

1. When navigation feels wrong, is the underlying position wrong, or is a correct position poorly communicated?
2. When a shared Margin fails, is evidence missing, contradictory, or simply hidden from the recipient?
3. When playback feels unreliable, is session ownership confused, or is a correct state machine starved of memory, compute, or OS execution time?

These are questions to investigate, not newly reproduced defects or requests to expand the release lane.

For an audit of this essay, the source links identify each specimen, the atlas count is reproducible by counting numbered issue headings within Part III, and the paper counterexample can be checked without executing the app. I sampled mechanisms rather than attempting full coverage. I stopped once each central interpretation had a concrete source example and a stated limit; broader device performance, rights research, platform expansion, and live GitHub reconciliation remain outside this excursion.

What stayed with me is a symmetry: **the app must remember where a thought came from, and the project must remember where a claim came from.** The strongest little pieces of this repository do both with care.
