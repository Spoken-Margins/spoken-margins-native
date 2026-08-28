# Overhaul proposal and audit plan

## Outcome

The redesign makes one product promise legible: **bring something worth hearing, listen with control, capture what it makes you think, and decide what to keep or share.**

It replaces the current screen-by-screen accumulation of controls with a stable information architecture, a provenance system, and explicit high-risk modes.

## What the current app already gets right

- The dark listening card makes playback feel like a distinct mode.
- Interject is visually prominent and brand-defining.
- The Timeline joins source structure, interjections, and AI turns around one session.
- Item and session identity are preserved through export rather than collapsed into a generic note.
- The app consistently uses large touch targets and exposes accessibility identifiers in code.
- The product is unusually serious about offline behavior, anchored context, state transitions, and evidence.

The overhaul preserves those strengths.

## Current UX pressure points

### The Library behaves like a test harness as it grows

Build 19 presents repeated outlined cards with prominent play and trash buttons. Every row allocates attention to a destructive action, while content type, author/show, duration, offline state, progress, and preparation are compressed into status text. Issue #86 confirms the need for a scalable organization layer.

Proposal: one Continue hero, compact metadata-rich rows, metadata search, typed filter chips, stable sort, contextual overflow for destructive actions, and a persistent mini-player.

### Add Source mixes mental models

The current sheet combines podcast URL, pasted text, file import, and Quick Folder management. It asks the user to understand implementation routes before choosing the object they possess.

Proposal: choose **Web or podcast**, **Paste text**, **Document or book**, or **Audiobook file**, then reveal the relevant control. Share-sheet intake lands in the same review path. This expands cleanly for EPUB and local audio without an even denser form.

### Item Detail elevates developer tools

The current Listening Map section makes paste/generate JSON part of the primary item hierarchy. It competes with the user jobs of continue, chapter navigation, sessions, offline preparation, and margins.

Proposal: authored/canonical chapters are primary. Map repair, diagnostics, and raw JSON move behind an advanced diagnostic route. Preparation is a separate state and action, never presented as source structure.

### The Timeline lacks provenance

The current Timeline uses a shared card pattern for source structure, local interjections, and turns. Tester feedback in [#68](https://github.com/uncomposed/spoken-margins-native/issues/68) directly identifies the scanning failure.

Proposal: a provenance grammar with four coordinated signals:

| Provenance | Color | Marker | Label | Surface |
| --- | --- | --- | --- | --- |
| Source | evergreen | circle | `SOURCE` / `CHAPTER` | warm white |
| My margin | coral | diamond | `MY MARGIN` | coral tint |
| Another person | indigo | avatar/circle | person's display label | indigo tint |
| AI | plum | outlined ring/star | `ON-DEVICE SUMMARY` or explicit provider | dashed plum tint |

Color is never the only signal. VoiceOver begins with provenance, then position, title, state, and action.

### Recording needs modal authority

Issue [#85](https://github.com/uncomposed/spoken-margins-native/issues/85) demonstrates that ordinary timeline navigation can destroy recording continuity and reset playback. This is both an architecture and human-factors failure.

Proposal: recording becomes a full guarded mode. The source anchor is visible and immutable. All unrelated destinations disappear or become inert. Only Finish and Cancel cause state transitions. The screen describes what will happen on Finish: save, reorient, resume.

### Playback status is information, not decoration

Issues [#84](https://github.com/uncomposed/spoken-margins-native/issues/84), [#83](https://github.com/uncomposed/spoken-margins-native/issues/83), #64, #73, and #74 show one underlying trust problem: audible playback, scrub gesture, canonical position, preparation, buffering, remote commands, and fallback runtime can drift or be presented ambiguously.

Proposal: the player exposes three separate layers:

1. **Canonical source/media position** — the user-facing time or source location.
2. **Direct manipulation state** — while dragging, the finger owns the thumb and periodic updates do not.
3. **Readiness state** — buffered, preparing, seeking, thermally paused, or ready offline; never a competing timeline.

The UI must not advertise a complete duration/scrubber when only partial generated audio has valid mappings.

### Sharing is currently an export configurator

Build 19's Share Session surface is powerful but technical: session selector, AI handoff/JSON, scope segments, representation toggles, and a byte preview. The sharing issues require a much narrower consent boundary.

Proposal: `Select → Represent → Recipient preview`. The final preview shows the actual source context and margin as the recipient will see them, plus a manifest of included and excluded fields. Audio is off by default. Cleanup provenance is visible. The private capture remains untouched.

## Proposed information architecture

### Primary destinations

**Library**

- Deliberately imported items only.
- Continue listening, search, filters, sort, item detail.
- Persistent Now Playing context.

**Sources**

- Explicitly followed feeds and new-entry inbox.
- Seen, dismissed, and imported states.
- No automatic library adoption, download, or preparation.

**Margins**

- The listener's own captured thoughts across sessions.
- Imported person-specific layers remain visibly distinct.
- Review, cleanup, select, summarize, and share.

### Task routes

- Now Playing
- Recording
- Timeline
- Add Source
- Item Detail
- Recipient Preview
- Settings / Offline & Preparation
- Onboarding

Now Playing remains a persistent overlay/context because it is a running session, not a library category.

## Naming proposal

Keep `Interjection` in the domain contract and keep **Interject** as the distinctive capture action. Test **Margin** as the human-facing noun for the saved result:

- Button: `Interject`
- Recording: `Your margin`
- Timeline: `My margin`
- Collection: `Margins`
- Sharing: `Reviewed margin`

This is an assumption, not a settled product fact. It should be tested against comprehension, VoiceOver brevity, and existing-user recognition before implementation. If it fails, preserve the provenance system while reverting the noun.

## Visual and interaction system

### Direction

The prototype uses a warm editorial palette rather than generic productivity chrome:

- bone paper for reading/listening context;
- evergreen ink for canonical source and primary control;
- ochre for active listening and interjection action;
- coral for personal voice and recording;
- indigo for another person;
- plum for AI-generated material.

Serif titles provide source/editorial character; system sans remains the control and metadata face. Artwork can later use publisher/source art. The interface does not require decorative AI imagery.

### Motion

- Transport changes are immediate and restrained.
- Recording uses a clear mode transition and live waveform, with reduced-motion support.
- Timeline transitions preserve source position rather than scrolling unpredictably.
- Preparation animation must never imply guaranteed completion.

### Accessibility

- Minimum 44-point interactive targets in production.
- Provenance is encoded by label, icon/shape, surface, and color.
- Dynamic Type reflows metadata before truncating titles.
- Increased contrast replaces tinted surfaces with stronger borders and labels.
- VoiceOver announces the active playback target and speaker/layer before actions.
- Recording mode announces that navigation is locked and exposes only Finish/Cancel.
- Scrubber announces current, total/known, and readiness state separately.
- Reduce Motion removes decorative transitions without hiding state change.

## Alternatives considered

| Alternative | Benefit | Why it was not selected |
| --- | --- | --- |
| Keep Home as one long route | Minimal navigation change | Does not scale to followed sources and cross-session margins; continues mixing acquisition, playback, and maintenance |
| Four tabs including Now Playing | Always-visible player destination | Treats transient session state as a content silo and duplicates the persistent mini-player |
| Combine Library and Source inbox | Fewer tabs | Conflates follow consent with import/download and weakens the local-first boundary |
| Separate Downloads tab | Storage is easy to find | Makes offline readiness a place instead of a property of each item; a unified budget still belongs in Settings |
| Social activity feed | Makes sharing visible | Explicitly outside #17–#19; would introduce accounts, ranking, and influence before the portable layer is validated |
| Color-only Timeline update | Fast | Fails accessibility and cannot carry authorship, verification, reveal policy, or AI provenance |

The selected three-place architecture is the smallest topology that can represent the active quality-of-life lane and future sharing lane without mixing consent boundaries.

## Implementation sequence

### Stage 0 — trust repair

1. Canonical scrub/direct-manipulation contract (#84).
2. Guarded recording mode (#85).
3. Remote-resume and partial-preparation truth (#83/#64).
4. Provenance grammar (#68).

These are prerequisites because an overhaul that looks polished while losing position or recordings would amplify distrust.

### Stage 1 — scalable private library

1. Library query/filter/sort (#86).
2. Add Source router for existing intake plus EPUB/audiobook (#61/#79).
3. Item Detail hierarchy for canonical chapters, sessions, margins, and preparation.
4. Unified offline storage and preparation surfaces (#64/#72/#73/#74).
5. Sleep timer (#87).
6. Two-item guided onboarding with production hotlinks (#69).

### Stage 2 — consent-based return loop

1. Verified source identity and follow suggestion (#77).
2. Sources inbox, refresh, mute, and unfollow (#76).
3. Clear distinction between following, importing, downloading, and preparing.

### Stage 3 — portable social margins

1. Resolve the implementation-evidence discrepancy (#81).
2. Reviewed package and Recipient Preview (#17/#67).
3. Import, resolution, provenance, and recipient reveal policy (#18).
4. Reply lineage and layer playback (#19).

The release lanes remain separate. This sequence is a UX dependency model, not authorization to merge branches or ship sharing in the quality-of-life lane.

## Verification and human-validation plan

### Automated and developer evidence

- Snapshot/route tests for Library, Add Source, Recording, Timeline provenance, Sources, Share Preview, and Storage states.
- State-machine tests proving generic navigation cannot exit recording.
- Timeline tests separating drag state, buffering/readiness, and canonical media time.
- Package manifest-versus-preview diff tests.
- Accessibility label snapshots that begin with provenance.
- Dynamic Type, dark mode, increased contrast, color-vision, reduce-motion, and VoiceOver audit.
- Offline, malformed, duplicate, corrupt, low-space, Low Power Mode, thermal, background expiration, and relaunch fixtures.

### Product-owner validation tasks

The product owner—not an automated agent—should exercise these flows on the supported devices:

1. Find and resume an item in under ten seconds without using search.
2. Add one link, one EPUB, and one audiobook and correctly predict what happens next.
3. Drag a podcast scrubber, interject, finish, and verify the resumed moment.
4. Attempt repeated Timeline taps while recording and confirm nothing moves or cancels.
5. Distinguish source, own margin, another person, and AI without opening a row or relying only on color.
6. Follow a source and confirm no item, download, or preparation appears until explicit Add.
7. Share one cleaned text margin and confirm the recipient preview matches the outgoing package.
8. Lower the offline budget and confirm protected work is explained rather than silently deleted.
9. Use VoiceOver for Add Source, Interject, Finish, Timeline, and Recipient Preview.

### Decision criteria

- **Comprehension:** at least 4 of 5 representative users can explain Library, Sources, and Margins after a five-second view.
- **Continuity:** no tested route loses or duplicates the active session, item, source position, rate, or recording anchor.
- **Consent:** users can correctly predict whether Follow, Add, Prepare, and Share cause network, storage, or disclosure effects.
- **Provenance:** every tested user can identify source versus author of a Timeline entry without opening it.
- **Recovery:** cancellation, backgrounding, offline state, and malformed inputs leave a clear next action and preserve prior valid state.
- **Accessibility:** the same distinctions and actions remain available with VoiceOver, increased contrast, and color removed.

## Audit and falsification

### Comparison baseline

Compare the redesign against the current Build 19 screenshots and flows on:

- time to resume;
- time to add each source type;
- accidental destructive-action exposure;
- correct provenance identification;
- correct prediction of offline/preparation state;
- correct prediction of what leaves during sharing.

### Omission tests

- Run every primary flow for each source type and representation type.
- Replace chapters with a chapterless/mapless source.
- Replace complete audio with partial prepared audio.
- Replace local margin with imported, unresolved, failed-transcription, and AI entries.
- Remove network, storage, model availability, feed validity, and package trust one at a time.
- Apply maximum supported Dynamic Type and VoiceOver before accepting the hierarchy.

### Falsification tests

- If users interpret Sources as already-downloaded Library content, the tab model has failed.
- If users cannot name who said a Timeline entry without color, the provenance system has failed.
- If a recording can end from any control other than Finish/Cancel, guarded mode has failed.
- If the scrubber thumb fights playback updates, direct manipulation has failed.
- If Recipient Preview omits an outgoing field or attachment, the share flow has failed.
- If storage clearing can select irreplaceable or active assets, the trust model has failed.
- If preparation wording implies a guaranteed overnight result, background-state communication has failed.

### Stopping rules

Do not ask the product owner to validate the visual overhaul until canonical time, recording guards, and provenance are verified by developer evidence. Do not expose Sources until following is provably separate from import. Do not expose sharing until #81 is reconciled and the package-to-preview audit is exact. Do not call any flow human validated until the product owner records pass/fail evidence.

## Repository governance observation

`docs/release-lanes.md` calls `codex/testflight-triage` idle with no active issue in the Active Branches table, but its TestFlight section calls #83 the current active triage item, followed by #85 and #84. This design study treats those issues as current reliability evidence only. Before implementation is routed there, the product owner should reconcile that internal wording in the authoritative lane document.
