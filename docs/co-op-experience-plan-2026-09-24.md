# A complete, economical co-op listening experience

September 24 owner correction: the proposed manual “mark my 22 Margins familiar”
step is rejected. The originating installation already knows which Margins it
created, and Skim New must exclude those automatically while retaining exact
parents as reply context. A verified Margin Skim advances the podcast bookmark to
the Margin location and continues there afterward. Keep the podcast scrubber,
provide Margin progress and skip-to-end, and replace the oversized “Continue
Source” control. Separate cue-triggered auto-play preference from explicit Skim.
Do not claim the exported cleaned recordings removed all pauses or fillers until
the 22 selected audio assets have been audited. The prior engineering-day
estimate is withdrawn; scope and checkpoints are expressed in account-usage
percentage points. Current observations and remaining gaps are in
`docs/co-op-listening.md` and the failed-device incident handoff.

Implementation status: paused at the owner-requested September 24 stopping point; see `artifacts/validation/gate-1/co-op-owner-test-2026-09-24/implementation-stop-2026-09-24.md`. The plan is not yet complete.

Planning proposal, September 24, 2026. This document does not authorize implementation, installation, distribution or a release-lane change. Proposed implementation belongs on the existing `codex/co-op` lane after the owner accepts the scope; record that decision in docs/release-lanes.md before code changes. Preserve the current dirty candidate and existing Library. Single-agent workflow.

## Outcome and model of the problem

Cole shares podcast Margins; Alex and Blair each respond; Casey responds to both; Cole hears the exchange with useful context, records his own reply to one or several contributions, and sends it back. The receiving installation reconstructs the same conversation. Importing overlapping packets never multiplies it. The owner can do this without reasoning about archives, IDs or revisions.

Assumption carried from the prior handoff: the simulated group is three AI recipients plus Cole. This exercises the same relationships as a smaller group with one participant speaking twice. AI voices are test fixtures, not an in-app AI feature or an authenticated human group.

Keep these layers separate:

| Layer | Responsibility | Main failure to prevent |
| --- | --- | --- |
| Contributions | Author, immutable revision, exact reply targets | Reply silently points to another version/person |
| Source attachment | Original capture anchor and independently resolved recipient position | Conversation context becomes a fabricated podcast seek |
| Listening | Selected reply, optional ancestors/context, explicit return | Repeated shared ancestors, unwanted detours, lost position |
| Exchange | Reviewed packet contents, additive import, retained recordings | Missing context hidden, duplicates, destructive merge |
| Evidence | Contract tests, runtime checks, owner acceptance | Passing tests mistaken for a complete or pleasant experience |
| Resources | Model usage, machine runtime, owner attention | Broad retries and handoffs consume budget without changing the decision |

Observed: MarginConversation currently has one optional parent; the packet schema and ancestor traversal agree. Existing recursive replies are chains with branching siblings, not replies to several contributions. The supplied legacy packet contains 22 Margins, with recorded speech, transcripts and reference-only podcast transport. Preliminary ZIP/asset integrity passed; native import of the proposed new packets has not happened. Prior verification is useful historical evidence, not proof of this missing behavior.

## The owner experience to build

1. Open a returned packet. See who contributed, what is new and whether source context is ready. Existing episode/Margins remain intact. Open directly into the new contributions for that episode.
2. Choose Alex's response. The screen identifies Alex and the Margin being answered. Play immediately, with context available through the existing context controls. Keep original-episode and Margin playback visibly distinct.
3. Choose Casey. Display “Replying to Alex and Blair.” Offer “Play reply” and “Play with context”; the selected-context queue shows what will play. Do not force all ancestors on every listen.
4. With context, play shared ancestors once, then Alex and Blair in the recorded target order, then Casey. Preserve complete exact parent versions for this slice. Provide explicit skip-to-Casey and return-to-episode controls. Text-only or missing ancestors do not silently vanish or block listening to Casey.
5. Tap Reply. Default to the selected Margin; optionally add other Margins from this episode. Show selected names and short excerpts before recording and before saving. Cancellation preserves prior audio and clears pending selections. The transcript and recording remain associated with the same targets after restart.
6. Review the item share. Show whose contributions/audio will be forwarded; preserve explicit consent for including referenced Margins. Missing parents remain visibly missing when the sender omits them. The receiver can import packets in any order and reimport without duplication.
7. After a verified Skim destination, resume the episode at the Margin's source location. An explicit return-to-previous-position action may remain available, but completion and skip-to-end do not silently rewind to the pre-Skim position. A manual seek cancels an obsolete conversation queue. Uncertain podcast alignment stays explicit and still permits direct reply playback without a guessed source seek.

These are proposed acceptance behaviors, not claims about current UI. New controls should extend the existing Timeline, Reply and Response & Context surfaces rather than introduce a separate group-management subsystem.

## Delivery sequence and exit criteria

### 1. Freeze the smallest complete example before implementation

Use one original Margin C, Alex A replying to C, Blair B replying to C, Casey D replying to A and B, and an owner-recorded E replying to D and optionally B. List required behavior against the actual model, schema, archive reader/writer, store, recording, playback planner and UI. Mark each implemented, missing or unverified. Include the successful original-packet import and stable legacy-identity conversion.

Exit: every arrow has a specified representation, every user action has a named existing or proposed surface, and every requirement has an observable test. No Nano download or broad suites yet. This is the omission check that was absent from the earlier readiness call.

### 2. Implement multiple reply targets through the whole round trip

Proposed contract: an ordered, duplicate-free bounded list of exact contribution/revision references. Target order is intentional context order; it must survive export/import. Choose and document an explicit supported limit during contract review; do not leave traversals or packet size unbounded. Require same-item targets in this slice; reject cycles, self-reference and contradictory immutable revisions. Unknown ancestors remain representable and may arrive later.

Introduce a versioned capability/schema for the new semantics. Preserve v1 decoding: zero or one parent maps losslessly to the internal list. Never silently truncate a multi-target reply for an old client. Preserve legacy identity derivation and existing revision bytes/hash semantics; old records must not acquire new identities just because they were read by a newer app. Do not encode two competing authoritative parent fields.

Update models, schemas, validators, archive handling, persistence, export closure, recording state and graph traversal together. Trace every single-parent assumption, including any source-position fallback; do not choose the first parent as a replacement capture anchor. Inspect the actual persistence representation before deciding whether a database migration is necessary.

Build a deterministic context planner: stable target order, ancestors before descendants, each exact revision once, visible missing/text-only entries, cancellation, return bookmark. Shared ancestors must not multiply audio duration. Multi-target edits create new revisions and retain versions referenced by old replies.

Exit: a tiny non-TTS fixture passes the real writer → reader → temporary store → reload → context-plan round trip, including two parents. Only then connect the UI selector, recording and listening controls and verify their state boundaries. A data-only success does not close this milestone.

### 3. Generate the actual owner exercise

Amend the prior Sol handoff to use the implemented contract; retire its stale readiness statements. GPT-6 Sol/high works single-agent. Download official Chatterbox Nano into an isolated environment; verify Nano model identity. Smoke-test one sentence, then generate only three grounded responses of roughly 35–60 seconds using clearly labeled fictional voices. Preserve the supplied owner's audio and text; do not impersonate the podcast speakers.

Deliver three importable packets, standalone audio previews, scripts and a reproducible fixture generator. Casey's packet includes the reviewed exact parent closure so it works when received first. Run the packets through the production importer and inspect decoded audio/durations. Distinguish waveform/decode checks from perceptual listening; do not claim the latter without doing it.

Exit: normal arrival, Casey-first arrival and duplicate import all produce the same contributions, references and intended context order. This is artifact verification, not human validation.

### 4. One candidate, one focused owner session

Run mandatory repository gates for the changed surfaces: fast and app; adapters/speech-canary when audio or playback changes; scoped UI for the changed interaction. Reuse results only for unchanged inputs and applicable coverage. Preserve XCTest startup and simulator-crash boundaries: no unchanged reruns, device switching to evade incidents, or reboot loops. Diagnose once, make a bounded evidence-backed recovery attempt when permitted, then report any blocked gates accurately. A blocked automated gate need not erase useful owner observations, but it prevents a blanket verified/release-ready claim.

Prepare an identifiable development candidate: version/build, HEAD plus dirty-input fingerprint, device/OS, exact supported test scope, known limitations, seeded items, diagnostics and non-destructive reset guidance. Build 27 alone is insufficient. Installation is a separate authorized step under the release lane; do not assume it from this plan.

Owner exercise: import Alex/Blair; hear one alone; select Casey and hear both parents exactly once; skip context; return to the episode; record a real reply to two selected Margins; export; reimport into an isolated recipient store; restart; repeat import. The synthetic fixture cannot substitute for this real recording/export path.

Exit: owner records pass/fail for the complete exchange. Fix concrete failures and rerun affected checks; after code changes, complete applicable gates on the final input. Preserve the distinction between implemented, verified and human_validated. Release/distribution remains a separate decision.

## Checks that can disprove readiness

| Claim | Required counterexample/check |
| --- | --- |
| Both targets are real | Delete one reference in a negative fixture; linkage acceptance must fail |
| Playback is coherent | Diamond graph plays C once, A/B once, then D; target order survives restart |
| Data is safe | Conflicting revision rejects atomically; original recordings/anchors unchanged |
| Arrival order is harmless | D first, parents later, duplicate/reversed imports converge |
| Versions are exact | Edit A after D exists; D still refers to the old A |
| Old packets still work | Import supplied legacy packet repeatedly and reference the same stable Margin |
| Failure is understandable | Missing parent, missing audio, unresolved source and canceled recording have explicit outcomes |
| Real exchange works | Owner-created two-target reply survives export and independent reimport |

Do not close a gate by dropping a failed case, replacing links with transcript mentions, or counting compilation as execution.

## Usage and scope controls

Use one GPT-6 Sol/high implementation task, a short acceptance checklist and durable checkpoints. No parallel agents or repeated full-context audits. Separate machine wait time from model reasoning: let tools wait, avoid re-reading unchanged logs, and inspect only evidence that could change the next action.

Before execution, record current usage and retain the standing account floor unless the owner changes it. Proposed additional control: stop at a 3-percentage-point increase in weekly account usage for a checkpoint with concrete artifacts, remaining scope and a revised estimate. This is a proposed stop threshold, not a promise that completion costs 3%; account usage can include other tasks. Never burn through a checkpoint silently. Check at milestone boundaries rather than polling continuously.

First checkpoint must deliver the contract map and a working minimal two-target archive round trip. If it cannot, stop expansion and identify the exact obstacle. Later checkpoints close UI/runtime and fixture/handoff respectively. Do not hide unimplemented pieces behind a test-count summary.

Compare alternatives: a single-parent approximation is cheaper but cannot satisfy the requested relationship; full hosted group infrastructure adds substantial unrelated work. Recommend the complete local packet loop above. Defer accounts, servers, automatic delivery, whole-episode smart reels, AI context selection and unrelated cleanup. Preserve required checks while avoiding broad repetition on unchanged code.

Success is a short, intelligible exchange the owner accepts, with durable exact relationships and a reproducible packet round trip—not merely a larger passing suite.

## Evidence consulted

- docs/co-op-listening.md
- docs/release-lanes.md
- Packages/SessionKit/Sources/SessionKit/MarginConversation.swift
- Contracts/schemas/shared-commentary-layer.schema.json
- artifacts/validation/gate-1/co-op-owner-test-2026-09-24/two-parent-blocker.md
- artifacts/validation/gate-1/podcast-anchor-reliability-2026-09-23/full-verification-2026-09-24.md

Planning-only verification: checked referenced repository paths, compared proposal with the known single-parent contract and current release boundaries, and checked the document for whitespace errors. No app checks or simulator runs are warranted by this document-only addition.
