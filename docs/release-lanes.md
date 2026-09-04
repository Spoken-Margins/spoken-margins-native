# Release Lanes

This document is the authoritative routing plan for implementation work in Spoken Margins. Branches represent release lanes, not individual issues or every dependency between issues.

The purpose of this plan is to reduce three risks:

- **Human routing error:** a reasonable request is accidentally sent to the wrong release line.
- **Agent routing error:** an agent infers a new branch or combines scopes differently from prior work.
- **Technical integration risk:** dependent work is developed against incompatible playback, contract, persistence, or project state.

If a GitHub label, issue comment, local branch name, older planning document, or agent instruction conflicts with this file, stop and reconcile the conflict before implementation. An explicit product-owner direction may change the plan, but this file must be updated first.

## Released Baseline

- Largest distributed audience: external TestFlight Build 19, version 0.1 (19).
- External TestFlight source commit: `738c743e202f5e700f4d6975adee52862f63c69f`, preserved by tag `testflight/0.1-build-19`.
- Upload evidence: `artifacts/validation/testflight-external/build-19/build-19-testflight-upload.md`.
- Accepted integration baseline: `main` at `b6ea36b0e08ebe457c9feb7d207694f8fca2224e` contains the released runtime plus product-owner-accepted integration and repository-governance changes. It is not an assertion that every later commit has reached the external audience; exact distributed binaries are identified by immutable TestFlight tags and upload evidence.
- Current internal baseline: version 0.1 (25) at `3294438ffba790fa281509bc1fa7b51e379a6c71`, preserved by tag `testflight/0.1-build-25`, was uploaded successfully on 2026-09-02, completed App Store Connect processing, and is available to the internal `Margins` group with six testers. The product owner reconfirmed that assignment on 2026-09-04. See `artifacts/validation/testflight-external/build-25/build-25-testflight-upload.md`. It was not added to `External Beta` or submitted for Beta App Review. Builds 20, 21, 23, and 24 are superseded internal candidates; do not submit them externally.
- Build 25 validation boundary: the product owner has `human_validated` the bounded sender share, recipient import, provisional-to-matched alignment, reconstruction, and listening flow using the Ajeya Cotra episode identified in the Build 25 handoff. Overnight preparation, physical-device resource profiling, local scene generation, and Skim remain pending internal testing. This decision does not clear issue #14 or authorize external sharing or distribution.
- Build 24 boundary: its bounded delta is `.spokenmargins` document ownership and outgoing type metadata for direct Messages/AirDrop opening, an exact-byte Share-extension handoff fallback, recipient import staging, and import controls that remain available without scrolling. This internal-only distribution does not clear issue #14, authorize external distribution, or establish `human_validated` behavior.
- Build 22 is an unshipped historical candidate preserved by tag `candidate/0.1-build-22`; its #84 media-seek fix is already in the ancestry of Build 25. It is not a current release lane or distribution target.
- Current provisional work lives on `codex/provisional-next`, descends from the exact Build 25 source, and contains feature improvements that are not yet fully product-owner validated or distributed. It remains versioned as build 25 until a new internal upload candidate is deliberately cut; the next available upload number is Build 26.
- `main` represents the released runtime plus explicitly accepted release-integration changes. Governance- or evidence-only commits may follow the released source commit; runtime changes may enter `main` only through a recorded product-owner release decision.
- When a later build reaches the largest distributed audience, update this section in the same change that advances the release lanes.

## Active Branches

Only these branches are active development lanes:

| Branch | Role | Current authorized scope | Merge target |
| --- | --- | --- | --- |
| `main` | Released and accepted integration runtime plus repository governance | Exact externally distributed source identified by TestFlight tags; product-owner-accepted integration; governance and validation evidence | N/A |
| `codex/testflight-triage` | Current internal TestFlight baseline and bounded stabilization lane | Exact Build 25 source initially; reproducible regressions in the current internal binary and narrowly scoped fixes only | `main` only when the exact candidate is product-owner accepted, accepted by Apple for external TestFlight, and available to the external group; exact fixes may also enter `codex/provisional-next` |
| `codex/provisional-next` | Feature-development lane pending product-owner validation | Post-Build-25 feature improvements authorized below; no claim of internal distribution, external distribution, or complete human validation | Cut to `codex/testflight-triage` only as an exact, tagged internal upload candidate; later promote the externally accepted exact source to `main` |

The source lanes are now frozen ancestry, not implementation targets:

| Frozen source | Integrated through | Build 23 merge evidence |
| --- | --- | --- |
| `codex/quality-of-life-next` | `9118c11` after absorbing the temporary overhaul | First parent of the Build 23 line before sharing |
| `codex/experience-overhaul` | `b118e01`, merged into quality-of-life at `9118c11` | Temporary lane complete; historical after integration |
| `codex/sharing-next` | `de887f6` | Merged once at `7d47876`; no Build 23 work returns to this lane |
| `codex/build-23-release` | `e0c12f3` before governance realignment | Historical integration lineage through Builds 23, 24, and 25; continued as `codex/provisional-next` without rewriting history |

All other local and remote branches are historical and read-only. Their commits may be inspected or deliberately extracted, but work must not resume directly on them without a product-owner plan change. In particular, `codex/sharingV1` is historical source material already reconciled into `codex/sharing-next`; it is not an active integration branch.

Product-owner revision, 2026-09-03 (PDF import, navigation, and generated-speech continuity): the active provisional lane is authorized to reopen #78 and address the observed GPT-6 Astra system-card flow end to end. Browser-shared PDFs must enter the document-import path instead of podcast-link resolution; the document picker must expose one direct document action for supported text, PDF, and DRM-free EPUB files; and the listening Timeline must project useful authored sections without duplicating cover, contents, outline, or nested visual headings near the beginning. When generated speech cannot satisfy the current playhead promptly, fallback playback must use the user's configured system voice, cancel or reprioritize obsolete generation after seeks, and avoid continuing background inference that can worsen resource or thermal pressure while fallback is audible. Automated evidence may establish `verified`; only the product owner can establish `human_validated` behavior on a physical device.

Product-owner revision, 2026-09-03 (private native PDF understanding): PDF extraction on the active provisional lane must remain serverless. On iOS 26 and later, Spoken Margins may use Apple's on-device Vision document-recognition API to recover page structure, especially tables, while retaining PDFKit embedded text and authored outlines as canonical evidence. Devices on iOS 18 through 25 must retain a PDFKit-only path. Analysis must run in the main app rather than the Share extension, be bounded for memory and thermal safety, and preserve structured table/source information separately from the later decision to narrate or skip it. This authorization does not introduce cloud extraction, document upload, or an Apple Intelligence device requirement.

Product-owner revision, 2026-09-04 (native-text startup preparation): on the active provisional lane, every newly added native-text item must enter the Library before playback and immediately prepare its first two durable audio chunks without requiring the user to open a session or enable charging-only full-item preparation. Import and metadata completion remain distinct from startup-audio readiness: the Library row must expose a truthful localized preparing state in place of its play affordance until the two-chunk startup window is committed, then become playable. Resource-intensive synthesis must remain serial, run outside SwiftUI rendering and animation work, respect cancellation, storage, thermal, and Low Power Mode safeguards, and yield to active playback demand. Failure or inability to prepare must not trap the user in a loading screen or make the source unavailable; the row must expose a retry or supported live-speech fallback. Full-item and overnight preparation remain separate policies governed by #73 and #74.

Product-owner revision, 2026-09-04 (optional per-session simultaneous audio): the active provisional lane may add a default-off setting that exposes a per-listening-session **Mix with Other Audio** control. Every newly opened listening session must begin in the existing exclusive playback mode with Spoken Margins owning Now Playing and remote transport controls. A deliberate session opt-in may switch app-owned speech or media playback to the system's pure `mixWithOthers` policy, expose an in-app Spoken Margins volume control, and relinquish Spoken Margins Now Playing metadata and remote-command ownership so another audio app may remain the system media owner. The app must not attempt to control the other app's volume, and this feature must not use continuous `duckOthers` as a substitute for mixing. Recording an interjection must temporarily use an exclusive recording configuration to avoid capturing concurrently playing speaker audio, then restore the session's selected playback policy. Automated checks may establish `verified`; only the product owner can establish `human_validated` simultaneous playback, route behavior, recording restoration, or Lock Screen behavior on a physical device.

Product-owner revision, 2026-09-04 (native-text social embeds): the active provisional lane may improve deterministic listening projections for readable-page items, especially social-media posts embedded in followed-source articles. The authored post body and useful attribution must remain audible while raw HTML/media elements, avatar scaffolding, destination URLs, timestamps, dates, engagement counts, and other social-card interface metadata are omitted. Every readable-page intake route must apply the same sanitation boundary, and system speech, generated live speech, prepared audio, and Watch rendering must share an equivalent source-offset-preserving projection so existing imported items also benefit. This work must remain local and deterministic, with no Apple Intelligence or server-AI dependency. Removal heuristics must be scoped to evidenced embed structure and must not erase matching dates, counts, or words in ordinary article prose. Automated checks may establish `verified`; only the product owner can establish `human_validated` listening quality.

## Merge Direction

Permitted flow:

```text
main ──────────────────────────────────► codex/provisional-next  (accepted ancestry only)

codex/testflight-triage ───────────────► codex/provisional-next  (exact verified stabilization fixes)

codex/provisional-next ────────────────► codex/testflight-triage
                                          only when an exact tagged commit is uploaded internally

codex/testflight-triage ───────────────► main
                                          only at the exact externally accepted source
```

Rules:

- The historical source merges are complete: experience entered quality-of-life at `9118c11`, the verified Build 22 patch entered the integrated lineage at `81a7c11`, and sharing entered it at `7d47876`. Do not repeat or reverse those merges.
- The recorded conflict resolution preserves the experience overhaul's navigation and presentation composition, sharing's package/import/playback contracts, and the additive persistence union. Project and package-resolution artifacts were regenerated from the resolved source rather than hand-blended.
- Build 25 is the current internal baseline. Do not move unreleased feature work into triage merely to make it ship sooner; advance triage only to the exact source of a successfully uploaded internal build.
- A triage fix may rejoin `codex/provisional-next` only as the exact verified patch. A provisional candidate may advance triage only after the matching archive has been uploaded and its identity verified.
- Promotion to `main` requires the exact source commit distributed externally, product-owner acceptance, and Apple external TestFlight acceptance. A successful build or internal upload alone is insufficient.
- Dependency ordering inside a lane is represented by issue state, commits, tests, and feature flags—not additional persistent branches.

## TestFlight Triage Lane

`codex/testflight-triage` accepts a change only when all of the following are true:

1. The behavior exists in the current internal TestFlight baseline.
2. The defect is reproducible or supported by specific tester/device evidence.
3. The fix is bounded and does not introduce a new product feature, schema family, or architecture.
4. Focused regression evidence can be added without claiming product-owner validation.
5. The change can be described in the next TestFlight handoff with exact in-scope and out-of-scope behavior.

Issue #84 was explicitly readmitted by the product owner on 2026-08-30 after the scrubber again dislocated from audible playback on current private branches. The bounded outcome is one acknowledged media-seek transaction in the shared playback spine, with combined regression evidence proving both historical failure modes in one sequence: periodic playback updates cannot fight an active drag, and after release the accepted player time, app timeline, persisted position, elapsed/remaining labels, and Now Playing state reconverge and continue advancing. The implementation at `22caa72` is `verified` and versioned as candidate 0.1 (22) at `df9e1b4`; generic simulator/device builds passed after project regeneration. It is not uploaded, accepted into `main`, distributed, or `human_validated`.

The accepted post-Build-19 fixes through `22788cb` include the earlier playback, recording-continuity, scrubbing, transport, PDF, and podcast-resolution corrections tracked through issues #56, #71, #78, #83, #84, and #85. The renewed #84 evidence proves that the earlier isolated scrubbing checks were insufficient; the issue remains open until Build 22 is exercised and accepted by the product owner.

For each TestFlight cycle:

1. Point triage at the exact tagged source of the newest internal TestFlight build.
2. Add only admitted regression fixes.
3. Run proportional automated verification, cut a new build number if the binary changes, and prepare the product-owner handoff.
4. Upload the exact candidate internally and update the internal tag, evidence, and triage pointer together.
5. After product-owner acceptance and Apple external TestFlight acceptance, fast-forward `main` to the exact externally available source and record the distribution evidence.
6. Leave triage at that exact distributed source until a newer internal build is uploaded.

## Sharing Lane

`codex/sharing-next` is frozen source history for the one-way sharing foundation, not a current implementation branch. Its one integration at `7d47876` is complete; all authorized follow-up sharing work belongs only on `codex/provisional-next` under the frozen seams below.

### Phase 1: Foundation

- #14: direct-share rights and provenance policy for referenced versus embedded items.
- #17: reviewed interjection packages and sender preview.
- #18: recipient import and distinct commentary layers.
- #67: deterministic cleanup and bounded anchor context for reviewed representations.
- #68: accessible provenance-aware Timeline presentation.
- #81: reconcile the existing `codex/sharingV1` implementation with current source and record implementation versus verification status.

These issues form one end-to-end boundary: prepare, preview, export, import, and distinguish shared commentary. Rights and provenance decisions from #14 gate external enablement even when implementation remains disabled behind a feature flag.

Product-owner revision, 2026-08-29: package terminology and transport must distinguish a reusable **source** (for example an RSS feed, newsletter, blog, or social feed) from the discrete **item** being listened to. URL-backed items share source/item references and never redistribute the item payload by default. A linkless native-text or document-derived item may be embedded only after the sender explicitly confirms that the share is private and that they have the right to share the item. Declining that confirmation must not block Margin export; the package instead declares that the recipient must supply the same item. App-authored sample text may be embedded without a user rights assertion because its provenance is known. Missing canonical URLs must never be represented by invented public URLs or reported as persistence failures.

Product-owner revision, 2026-08-29 (playback validation): sender review must use one compact, readable inline transcript in which words and bracketed pause markers can be tapped to remove or restore them; it must not duplicate the same edits as a vertical toggle list. Imported-item presentation must show one Listening Map generation request and a play/resume action without requiring a long scroll. Companion playback must sound a cue and expose **Listen** and **Dismiss** on the playback screen and Live Activity when a shared Margin is reached. The playback screen must also expose an auto-play control that selects automatic versus opt-in shared-Margin playback without creating a second persistence model.

Product-owner revision, 2026-08-30 (bulk review and listening rate): sender review must offer one explicit bulk action that prepares every included, eligible Margin for filler removal and pause tightening with bounded work, visible progress, cancellation, and per-Margin fallback to Original voice or Text when preparation is unavailable. Bulk preparation must not mutate private originals or prevent later per-Margin review and Undo/Redo. When a private or received Margin voice is played during an item session, it inherits the item's current playback rate; the notification cue remains at normal speed and source playback resumes at its existing rate.

Product-owner revision, 2026-08-30 (default cleanup consent): the first sender share must ask whether included Margins should be cleaned automatically. Accepting remembers an enabled `Clean selected` preference for later shares and immediately prepares the current included, eligible Margins. Declining leaves it disabled but available. Turning the preference off must undo cleanup applied automatically to the current share without mutating private originals or preventing explicit per-Margin cleanup, review, Undo, or Redo.

Product-owner revision, 2026-08-30 (share-later curation and review density): the listening Timeline must let the user visibly star a private Margin for later sharing, and Margin detail may retain a bounded private sharing note. This curation must persist locally, remain private rather than entering a `.spokenmargins` package, and drive a Starred filter plus safe default selection in sender review without replacing the per-export Include control. If any Margins are starred, sender review initially includes and shows only those starred Margins; if none are starred, the existing all-included default remains. Long sender-review transcripts must default to a readable preview of no more than 10 lines and expose an explicit expansion control; short transcripts must not gain unnecessary disclosure chrome.

Product-owner revision, 2026-08-30 (speech-aware gaps and lock-screen navigation): cleanup must use aligned speech timing and acoustic evidence as complementary signals, so sustained background noise inside a recognized non-speaking gap does not preserve that gap merely because it is louder than room tone. Every proposed removal remains sender-reviewed, reversible, and prohibited from overlapping aligned speech. While receiving Shared Margins, the Lock Screen Live Activity must expose actionable **Listen** and **Dismiss** controls whenever a Companion prompt is pending, including compact supplemental presentation, using app-process Live Activity intents rather than a widget-only URL handoff. Its next-navigation affordance must merge publisher chapters and verified upcoming Shared Margins in source order; a Shared Margin remains a distinct commentary event rather than being written into the publisher's chapter data. Selecting an upcoming Shared Margin moves to its verified local anchor and applies that layer's cue and reveal behavior. Locked-device interaction remains subject to iOS authentication.

### Phase 1A: Testable podcast-sharing MVP

The product owner expanded the sharing foundation on 2026-08-29 so it can reach a trusted-tester MVP instead of stopping at package-only infrastructure.

- #27 is authorized first as the cross-edition benchmark and then as the production evidence/resolver gate. Automatic verified placement requires zero false-confident placements in the held-out benchmark and p95 error no greater than 1.5 seconds. The implementation must retain ambiguous, absent, unresolved, and wrong-source outcomes instead of forcing placement.
- A sender timestamp remains a hint. A silent timestamp fallback is authorized only when strong episode identity and a benchmark-approved duration guard hold, transcript and acoustic evidence are genuinely unavailable, and no evidence contradicts the placement. It is never eligible after ambiguity, absence, digest mismatch, or wrong-source detection.
- #88 remains the portable scene-map proposal schema, validation, deterministic `.spokenmargins` transport, and proposal-persistence dependency. The Build 25 expansion below additionally authorizes private offline podcast map generation and local recipient projection without creating a public episode-map catalog.
- After a recipient confirms an integrity-checked import, the existing podcast download coordinator may treat that explicit import as a user-initiated download. It must show progress/cancel/retry and must not autoplay.
- Add a same-device "Create recipient test session" route that exercises the real archive, verification, import, persistence, resolver, and commentary-playback path in a distinct local imported layer.
- Sharing is exposed without a tester-facing Settings toggle in the first dedicated sharing TestFlight build, but incomplete routes remain unregistered until the complete end-to-end path is verified. #14 still gates sharing with other people outside the product owner's own-device validation.

Product-owner revision, 2026-08-30 (stream-efficient sender evidence): podcast evidence capture must not require a continuous rolling buffer or a complete sender-side download. After a podcast Margin finishes, arm one bounded decoded-playback sample for the next approximately 12 seconds, discard all decoded PCM after generating non-playable acoustic evidence, and share no podcast audio. Closely spaced Margins may share the short-lived playback tap while keeping distinct evidence records. If the active stream cannot expose enough decoded audio, or playback seeks or changes items before capture completes, decline acoustic evidence and use the conservative transcript/identity fallback; do not silently promote a timestamp. A separately downloaded dynamic-ad episode is not proof of the edition the sender actually heard.

Product-owner revision, 2026-09-01 (redundant recipient anchor recovery): importing a podcast session must actively attempt multiple independent placement methods rather than treating acoustic evidence as a reason to skip transcript evidence. The sender must attempt bounded source-window transcription whenever source audio is available, including when acoustic signatures are ready, and transport bounded transcript context with each reviewed Margin. When an imported podcast download is ready and any Margin remains unresolved, absent, or ambiguous, the recipient must generate or reuse a timed local transcript for anchor recovery, run ASR-tolerant fuzzy transcript matching, fuse transcript and acoustic candidates, and retain per-Margin evidence outcomes. Verified Margins in a partially resolved layer remain playable. Interpolation may promote a position only when verified anchors safely bracket the sender timestamp and preserve monotonic order; extrapolation and raw timestamp or duration scaling remain visible proposals requiring recipient confirmation. The import UI must permit direct listening to an imported voice even when its automatic source position is unresolved. This Build 25 internal follow-up remains under #27's zero-false-confident-placement and p95 error gates; automated evidence is `verified`, not `human_validated`.

Product-owner revision, 2026-09-02 (Build 25 private episode maps and Skim): the active release lane now includes the bounded portions of #27, #88, #89, and #90 needed for a private-first redundant podcast alignment pipeline. It may retain a memory-only 20-second decoded-audio ring during active playback, generate exact pre-Margin and stable post-resume signatures, collect sparse approximately five-minute playback landmarks, prepare downloaded episodes while explicitly requested or under a separate default-off charging preference, generate transient timed transcripts and privacy-reduced phrase sketches, create on-device scene proposals on supported iOS 26 devices, resolve imported maps against recipient editions, and expose distinct Skim Forward/Backward controls in the app and Live Activity. Phrase sketches are not cryptographic protection against dictionary attacks and must never be described as anonymous or irreversible. Decoded PCM, complete transcripts, and rendered summary audio must not enter a share package and must be deleted after the committed derivative artifacts no longer require them. A user-initiated Margin share automatically includes the best committed private map without blocking if preparation is incomplete. This expansion does not authorize server AI, public episode catalogs, contribution credits, automatic ad classification, headphones/CarPlay/Watch Skim remapping, or external sharing before #14 is accepted. The prior stream-efficient restriction is narrowed only for the bounded memory ring; it continues to prohibit unbounded recording, persistent playback PCM, and a sender-side full download solely for Margin evidence.

Product-owner clarification, 2026-09-01 (partial acoustic evidence and edition-step maps): a unique, high-confidence acoustic flank is direct placement evidence even when its sibling flank is absent from a dynamic edition; the missing sibling must reduce confidence and remain visible in diagnostics rather than discarding the matched position. When two or more direct anchors bracket an unmatched Margin, recovery must model podcast-edition changes as piecewise timing offsets and use the nearest verified offset, bounded by the bracketing recipient positions and followed by a monotonic-order check. This may recover an acoustic `absent` result inside the verified interval, but it must not overwrite conflicting ambiguous candidates or extrapolate outside the verified interval.

The `.spokenmargins` package is still unpublished. This lane is authorized to replace its pre-release v1 schema and fixtures in place, without a legacy decoder, before any external user relies on it.

### Later release: Co-op Replies

- #19 begins only after the Build 23 one-way foundation is implemented, verified, and product-owner accepted.
- Co-op replies require a later release-lane decision; they are not Build 23 work.
- #26 AI synthesis is not authorized by this lane plan.

## Quality-of-Life Lane

`codex/quality-of-life-next` supplied the complete non-Watch quality-of-life program and integrated private experience overhaul to Build 23. That source lane is frozen after `9118c11`; do not resume work or create issue-specific persistent branches from it.

Earlier Build 21 and Build 22 references on the branch describe local automated evidence only and are superseded: Build 21 is the current internal hotfix line, Build 22 is the renewed #84 triage candidate, and the unified candidate is Build 23.

### Authorized ordered program

1. **Prepared core — #34 and #64.** Remove reachable Kokoro/MLX runtime and configuration, establish exact Supertonic render identity, durable prepared-audio manifests and chunks, typed recovery/cancellation state, source-to-media mapping, complete offline media, and truthful Lock Screen duration/scrubbing.
2. **Offline lifecycle — #72 and #73.** Establish one storage ledger and budget, reservations, protections, deterministic eviction, adoption, and an injected power/thermal/storage-aware preparation horizon.
3. **Books and local audio — #61 and #79.** Add canonical DRM-free EPUB ingestion and app-owned audiobook import without conflating authored source structure, playable media, or offline ownership.
4. **Charging preparation — #74.** Add opt-in charging-only `BGProcessingTask` execution using the same durable jobs, manifests, storage reservations, and renderer as foreground work.
5. **Guided onboarding and followed sources — #69, #76, and #77.** Add bounded remotely configurable onboarding, shared feed parsing/discovery, explicit subscriptions and inbox state, readable-page import, and suggestion decisions. Issue #69 includes the EPUB and audiobook routes shipped in this release.
6. **Library comfort and sleep timer — #86 and #87.** Add metadata-only search, typed filters/sorts, and session-scoped timed/end-of-chapter sleep modes.
7. **Single-release integration.** Keep unfinished paths unexposed, deploy and validate the production onboarding manifest/audio, update specifications/evidence/legal/diagnostics, and prepare the product-owner handoff only after the complete non-Watch program is implemented and verified.

Each phase may begin only when its dependency invariants have focused automated evidence. Background preparation must remain disabled until durable manifests and the storage ledger are verified. The release stops if partial audio advertises a complete scrubber, rendering can exceed reservations, EPUB structure is flattened, foreground/background output diverges, following imports automatically, remote onboarding introduces executable routes, or Watch runtime work appears in the diff.

### Explicitly out of scope

- #75: untethered Apple Watch playback and interjection sync.
- Any new Watch playback, transfer, rendering, connectivity, or synchronization work.

Existing dormant Watch artifacts may be counted by the storage ledger, but this authorization does not permit changing or enabling Watch runtime code. Issue #75 remains queued for a later product-owner release decision.

## Temporary Experience Overhaul Lane

The product owner authorized `codex/experience-overhaul` on 2026-08-28 as a bounded temporary integration branch from `codex/quality-of-life-next`. Its purpose is to recompose the already implemented private quality-of-life capabilities into a scalable native experience without importing the sharing lane or changing SessionKit contracts.

Authorized scope:

- adaptive Library, Sources, and local Margins destinations;
- app-layer navigation and presentation models;
- typed intake routing over existing import handlers;
- item detail, Now Playing, guarded recording, local Timeline provenance, onboarding, and offline-storage presentation;
- semantic design tokens, accessibility behavior, focused regressions, validation evidence, and the product/spec updates required by this direction.

Explicitly excluded:

- reviewed sharing packages, imported people, recipient preview, co-op replies, or any other `codex/sharing-next` runtime;
- Watch, new SessionKit commands or snapshot/schema fields, publisher-artwork dependencies, account/profile concepts, remote execution, and speculative disabled controls;
- distribution or a claim of `human_validated` status without a separate product-owner decision and hands-on validation.

The branch merged only into `codex/quality-of-life-next` at `9118c11` and is now historical. Sharing was composed only after quality-of-life reached `codex/build-23-release`, where the design overhaul owns navigation and screen composition and sharing owns its reviewed-package, import, provenance, and playback semantics.

## Historical Build 23 Unified Release Lane

This section preserves the Build 23 integration contract and evidence. The branch name is historical; its integrated ancestry continues on `codex/provisional-next`, and this section does not override the current routing table above.

`codex/build-23-release` is the only branch where the quality-of-life/experience source and sharing source may be composed. It exists to complete a coherent release, not to preserve both branches' duplicate screens.

Automated candidate status (2026-08-30): Spoken Margins 0.1 (23) at runtime
SHA `10f7fd192f59f1fc8dc024d6defda2c2f41b7693` is `implemented` and
`verified`. It is not `human_validated`. Build 22 remains a separate pending
product-owner gate, and issue #14 continues to block externally enabled
sharing, so Build 23 is not authorized for distribution. See
[`automated-verification.md`](../artifacts/validation/build-23/automated-verification.md)
and
[`product-owner-handoff.md`](../artifacts/validation/build-23/product-owner-handoff.md).

### Product contract

The sender experience is a four-stage state machine:

1. **Select:** choose the final set of Margins and confirm the item and rights context. Starred Margins may be preselected, but the final set is explicit.
2. **Review:** inspect a compact list, edit one Margin in detail at a time, choose its representation, and batch-prepare eligible representations without losing per-Margin review status.
3. **Recipient preview:** render what the other person will receive from the successfully round-tripped, verified archive. Any package-affecting mutation invalidates this preview and requires regeneration.
4. **Share:** invoke the system share surface with the exact verified `.spokenmargins` file represented by the preview.

The recipient experience is preview, import, then an explicit behavior choice. Imported Margins remain a distinct provenance-aware layer, default to Companion voice, and never autoplay. When recipient-supplied source material is missing, the import route must enter Add Source and return to the pending import rather than require the user to reopen the file.

### Frozen ownership boundary

- Experience-overhaul composition owns navigation, semantic design tokens, adaptive screen structure, sheets, toolbars, and persistent-player placement.
- Sharing owns reviewed-package schemas, archive signing/verification, bounded anchors, representation preparation, imported-layer semantics, and shared-Margin playback behavior.
- Session and persistence integration is an additive union; neither source lane may discard the other lane's durable fields or migrations.
- `Package.swift` contains each target and ZIP dependency once. `Package.resolved` files and the Xcode project are regenerated after source conflicts are resolved.
- Root composition, app-model integration, shared SessionKit models/protocols/engine, project generation, contract validators, and release evidence are steward-owned seams during parallel work.
- The executable adapter and canonical action/projection vocabulary are frozen in `Build23SharingSeams.swift` at `fca95cb`. Gate work may consume but not edit that file. Exact archive round-trip, stale-preview invalidation, and recipient-supplied Add Source reconciliation have focused regression coverage in `Build23SharingSeamsTests.swift`.

### Release gates and stopping rules

Build 23 may be called `implemented` when all in-scope paths exist, and `verified` only after contract validators, the complete SessionKit suite, focused app tests, generic simulator/device builds, and the scoped route checklist pass. It remains not `human_validated` until the product owner completes its handoff.

Stop distribution or acceptance if:

- Build 22's seek behavior is rejected or remains undecided;
- #14 rights/provenance policy is unresolved for any externally enabled sharing path;
- recipient preview is derived from draft UI state rather than the exact verified archive;
- editing after preview can share stale bytes;
- imported and local Margins are distinguishable only by color, imported audio autoplays, or import silently changes source ownership;
- a merge drops storage, playback, anchor, provenance, or migration behavior from either source line;
- Watch runtime, co-op replies, accounts, hosted storage, or AI synthesis enters the diff;
- generated project/package files are hand-merged without a clean regeneration check.

## Work-In-Progress And Branch Creation Rules

- The repository remains single-agent by default.
- The historical Ultra packet in `docs/work-packets/build-23-ultra-handoff.md` is closed and does not authorize new parallel work.
- Keep one active implementation target at a time unless the product owner explicitly changes the workflow.
- Do not create branches for individual issues inside an active lane.
- Temporary recovery or experiment branches require explicit product-owner approval and must name their merge target and deletion condition.
- Keep each issue or tightly complementary issue group identifiable as a commit series even when it shares a release branch.
- Incomplete runtime paths must remain disabled through an existing, documented capability or feature flag. Do not invent a new flag without updating its contract, runtime, validator, and tests together.

## Agent Start Checklist

Before editing implementation code, report:

1. Current branch and base SHA.
2. Issue or issue group being addressed.
3. Why that work belongs to the branch under this document.
4. Expected files or runtime surfaces.
5. Verification evidence planned.
6. Any dirty or historical work that must be preserved.

Stop before implementation when:

- the issue is not authorized for the current lane;
- the request would merge feature lanes together;
- a triage fix expands into a new contract or product feature;
- required work exists only on a historical branch and has not been deliberately reconciled;
- a new branch appears necessary but the product owner has not changed this plan.

## Status And Validation

Use repository status terms exactly:

- `implemented`: a runtime or user path exists.
- `verified`: automated checks or developer evidence support it.
- `human_validated`: the product owner exercised and accepted it.

Every release-lane handoff must name the build number and commit SHA, supported devices and OS versions, in-scope and out-of-scope flows, known issues, reset and sample-data instructions, diagnostics location, automated verification, and the product-owner pass/fail checklist.

## Changing This Plan

This plan is intentionally small. A product-owner decision may add, remove, rename, or repurpose a lane. Make that change here first, then update branch refs, GitHub labels or milestones, and implementation work. Do not maintain a second competing branch plan elsewhere in the repository.
