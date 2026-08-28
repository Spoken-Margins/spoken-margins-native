# Use cases and user flows

## Scope and evidence boundary

This model was derived from:

- the current Build 19 iPhone screenshots under `artifacts/testflight/screenshots/build-19-app-store-connect-1284x2778/`;
- the current SwiftUI surface in `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1RootView.swift` and navigation/state in `Gate1AppModel.swift`;
- the product thesis and runtime boundaries in `docs/production-architecture.md`, `docs/sessionkit-contract.md`, and `docs/prototype-lessons.md`;
- the active routing plan in `docs/release-lanes.md`;
- open GitHub issues in the quality-of-life, sharing, and TestFlight reliability programs as inspected on 2026-08-27.

Observed repository facts and GitHub requirements are treated as evidence. Design conclusions are proposals. Any behavior not supported by the repository or an issue is marked as an assumption.

At the research snapshot, the checkout was `codex/quality-of-life-next` at `e25017c`, with another agent's uncommitted work across SessionKit and app integration. That work was inspected read-only and is not classified here as implemented, verified, or human validated.

## Challenge model

### Actors

| Actor | Primary need | Risk to prevent |
| --- | --- | --- |
| New listener | Understand the loop by hearing it | Mistaking generated speech, native audio, imports, and AI as one opaque system |
| Returning listener | Resume with minimal visual attention | Losing the active session, chapter, rate, or canonical position |
| Deep listener | Capture a thought without losing context | A tap cancelling recording or moving the source anchor |
| Library keeper | Find and prepare a growing collection | Destructive controls, unbounded storage, or confusing preparation state |
| Source follower | Notice new work without adopting a full RSS client | Following silently importing, downloading, or profiling behavior |
| Margin author | Review and deliberately represent a private capture | Raw audio or unapproved text leaving the device |
| Margin recipient | Hear another person's layer on their own terms | Commentary biasing first exposure or seizing playback |
| Product owner | Update onboarding and validate product flows | Binary-only tutorial content or automated checks being called validation |

Future classroom, browser, Watch, Android, semantic-map, and public-social actors exist in issues, but they do not drive the proposed primary phone navigation.

### Typed resources

These resources must remain distinct in data and presentation:

1. **Canonical source** — article text, PDF structure, EPUB spine/navigation, podcast episode, or audiobook media.
2. **Playable representation** — remote stream, local audiobook, live speech, prepared generated audio, or imported audio.
3. **Session state** — item, target, canonical position, rate, active chapter, and completion.
4. **Private capture** — raw recording, raw transcript, cleaned transcript, approved display text, and anchors.
5. **Reviewed share revision** — the exact selected representation, bounded context, attribution, rights metadata, and provenance.
6. **Imported commentary layer** — immutable package evidence plus recipient-local source resolution, reveal policy, mute, and delete state.
7. **Offline asset** — bytes, ownership, reproducibility, protection, reservation, and eviction state.
8. **Feed subscription and entry** — a followed source and inbox metadata, not a library item until explicit import.

### Execution topology

| Surface or runtime | Owns | Must not pretend to own |
| --- | --- | --- |
| Phone/tablet canonical runtime | Playback, recording, persistence, preparation, local AI when available | Guaranteed background execution |
| Lock Screen / Control Center / Live Activity | Delegated transport and truthful snapshot | A second playback timeline |
| Share extension | Intake handoff | Publishing a ready library item without review |
| Files import | Temporary access and validation | Durable access to a provider URL after import |
| Feed network path | Direct source/feed retrieval | Remote behavioral recommendation or automatic import consent |
| Package exchange | Transport-neutral immutable file/share | Global identity, server order, or mutable shared document |

### Work types

- Acquire: resolve, validate, copy, parse, and publish an item.
- Prepare: render or download a bounded playable representation.
- Listen: start, resume, seek, navigate, pause, sleep, and finish.
- Capture: lock the source anchor, record, save, transcribe, clean, and resume.
- Reflect: review margins, summarize selected scope, and revisit sessions.
- Follow: discover a verified source, request consent, refresh, and show entries.
- Share: select, revise, preview, package, deliver, and cancel safely.
- Receive: verify, resolve, choose reveal policy, enable, mute, or remove a layer.
- Maintain: search, filter, sort, account for storage, evict safely, delete, restore, and diagnose.

### Recurring failure modes

- Multiple owners of media time, playback state, or remote transport state.
- UI updates fighting direct manipulation during a scrub gesture.
- Incidental navigation terminating a high-priority recording mode.
- Source, personal margin, imported person, and AI shown with one visual grammar.
- Technical lifecycle strings presented as the primary information hierarchy.
- Following, importing, downloading, and preparing conflated into one action.
- Prepared or buffered state presented as if a whole item is complete and seekable.
- Raw and reviewed representations conflated at export time.
- A large library rendered as repeated oversized cards with destructive actions in every row.
- Automation promising background completion that iOS does not guarantee.

## Core use cases

### Find and acquire

| ID | Use case | Trigger | Successful outcome | Important branch |
| --- | --- | --- | --- | --- |
| F1 | Learn the core loop | Clean install | Listener chooses the native-audio tour or native-text welcome item | Dismissal is respected; remote tour update does not duplicate or resurrect it |
| F2 | Add a public link | Plus button, paste, Return, blur, or share sheet | Resolver shows one reviewable candidate, then creates the correct item | Needs-review, unsupported, offline, redirect, and duplicate states remain explicit |
| F3 | Paste native text | Add Source | Text becomes a canonical item and can begin bounded preparation | Empty content, extremely long text, and mapless structure remain useful |
| F4 | Import a document | Files or share sheet | PDF, Markdown, or EPUB preserves its authored/canonical structure | DRM, malformed structure, copy interruption, and low space fail without a partial ready item |
| F5 | Import an audiobook | Files | One app-owned DRM-free media file becomes a native-audio item | Protected, zero-duration, corrupt, duplicate, and transient-provider cases leave no orphan |
| F6 | Search a large library | Library search | Metadata-only results combine with typed filters and stable sort | Empty library, no results, and unavailable-offline are visibly different |

### Listen and navigate

| ID | Use case | Trigger | Successful outcome | Important branch |
| --- | --- | --- | --- | --- |
| L1 | Resume | Continue card, item detail, mini-player, or system control | Same item, session, representation, chapter, rate, and canonical position resume | App relaunch never autoplays |
| L2 | Seek native audio | Drag scrubber | Thumb follows the gesture; one accepted target becomes canonical media time | Unbuffered target shows seeking/buffering without clamping to loaded ranges |
| L3 | Navigate source structure | Timeline or chapter list | The authored chapter/section and source location become current | Mapless/chapterless items remain playable |
| L4 | Cross an unprepared boundary | Playback reaches missing generated audio | UI shows preparing/buffering and continues when valid audio is committed | Runtime never silently changes voice, rate, or claims complete duration |
| L5 | Use a sleep timer | Player option | Timer pauses at deadline or canonical end-of-chapter and preserves position | Manual pause does not disarm; recording defers expiry; process/session replacement clears it |
| L6 | Continue from system controls | AirPod, Lock Screen, Control Center, Live Activity | Delegated controls match the canonical in-app state | Partial preparation and Stop Generating cannot orphan remote resume |

### Capture and reflect

| ID | Use case | Trigger | Successful outcome | Important branch |
| --- | --- | --- | --- | --- |
| M1 | Begin a spoken margin | Interject | Playback pauses, source anchor locks, and recording begins | Permission or audio failure preserves the session |
| M2 | Record without accidental loss | Active recording | Only explicit Finish or Cancel can leave the guarded state | Timeline/source taps are inert and cannot seek or reset playback |
| M3 | Finish and reorient | Finish | Durable recording/capture is saved; playback resumes once from nearby context | Save/transcription failure never discards viable audio or ends the session |
| M4 | Review representations | Timeline or Margins | User can inspect raw audio, raw transcript, cleaned transcript, and approved text separately | Deleting/replacing one representation does not silently delete others |
| M5 | Summarize selected margins | Player or Margins | On-device summary clearly states its selected scope and source | Unsupported device, malformed output, retry, or offline state preserves user work |
| M6 | Revisit thinking across items | Margins tab | Listener sees personal contributions grouped by item/session and provenance | Imported layers and AI turns never masquerade as the listener's own words |

### Follow and return

| ID | Use case | Trigger | Successful outcome | Important branch |
| --- | --- | --- | --- | --- |
| R1 | Follow after meaningful engagement | Inline offer at a safe transition | Listener follows the exact verified source shown | Not now, never suggest, multiple candidates, and already-followed are respected |
| R2 | Review new entries | Sources tab | Inbox works from the last valid snapshot and shows unseen/seen/dismissed/imported | Refresh failure does not erase prior entries |
| R3 | Add an inbox entry | Entry action | Existing intake path imports the chosen entry | Follow itself never imports, downloads, renders, or prepares the entry |
| R4 | Mute or unfollow | Source management | Refresh/presentation behavior changes without deleting library items | Historical inbox retention follows an explicit policy |

### Share and receive

| ID | Use case | Trigger | Successful outcome | Important branch |
| --- | --- | --- | --- | --- |
| S1 | Create a reviewed share revision | Margin review | User chooses raw, rerecorded, approved text, disclosed TTS, or private/omitted | Private capture remains immutable |
| S2 | Reduce fillers/context | Review step | Deterministic cleanup and bounded anchors are inspectable | Meaning-changing edits require explicit approval/provenance |
| S3 | Preview as recipient | Final share step | Preview enumerates every field and attachment leaving the device | Audio, full source, diagnostics, unrelated sessions, and unselected forms stay excluded by default |
| S4 | Import a layer | Files/share sheet | Digest verifies and layer is stored separately without replacing active playback | Invalid, duplicate, wrong-source, unresolved, and context-only states are explicit |
| S5 | Choose reveal policy | Imported layer | Recipient chooses Fresh, Companion, or Guided behavior | Sender suggestion never overrides recipient choice |
| S6 | Reply asynchronously | A received margin | Reply creates lineage in a new immutable package | Ordering cannot depend only on arrival time; source resumes exactly once |

### Maintain trust

| ID | Use case | Trigger | Successful outcome | Important branch |
| --- | --- | --- | --- | --- |
| T1 | Prepare offline audio | Explicit request or eligible demand | Current position and bounded look-ahead prepare first | Battery, heat, low power, low space, stop, or chapter jump reprioritize safely |
| T2 | Opt into charging work | Settings | Durable jobs may run while charging when iOS grants time | UI says best effort; opt-out cancels future automatic chunks |
| T3 | Inspect one storage budget | Settings | Total app-owned bytes, reservations, protected assets, and categories reconcile | Phone/Watch copies count separately; remote URLs do not count |
| T4 | Clear safe media | Settings or item | Reproducible media is evicted without deleting source items or recordings | Active playback, commits, transfers, interjections, and recordings remain protected |
| T5 | Delete and recover | Item/library/settings | Recently Deleted, undo, restore, and permanent cleanup are explicit | Sibling actions cannot cross-fire; permanent deletion cleans owned assets only |

## Proposed end-to-end flows

### Flow A — first meaningful session

1. Fresh Library shows exactly two starter items, identified as **native audio** and **on-device voice**.
2. The listener chooses the audio tour.
3. Now Playing teaches transport through the real player.
4. A bounded hotlink opens the production Add Source router, not a tutorial-only form.
5. The listener returns and taps Interject.
6. Recording visibly locks the source anchor.
7. Finish saves the margin and resumes once with context.
8. Timeline distinguishes source, my margin, another person, and AI by more than color.
9. The listener may review the margin or leave; onboarding progress reflects the action without blocking normal use.

Recovery: offline tour configuration uses last-known-good or bundled fallback; a deleted tour stays deleted.

### Flow B — add a long EPUB and listen before full preparation

1. Library plus → **Document or book** → Files.
2. Validate/copy/parse into a canonical source package before publishing a ready item.
3. Item Detail exposes authored chapters separately from preparation state.
4. Start Chapter 1 once the bounded demand window is ready.
5. Player shows chapter identity and only truthful prepared/seekable state.
6. A jump to Chapter 8 reprioritizes that chapter; committed compatible audio stays reusable.
7. On power, eligible work may extend; on battery it stops after the bounded horizon.
8. Relaunch reconstructs source location and preparation from durable state.

Stopping rule: do not ship if EPUB structure is flattened or full-book synthesis blocks first playback.

### Flow C — capture safely during a podcast

1. Now Playing derives elapsed time, remaining time, Now Playing, persistence, and anchor from one canonical media-time source.
2. During scrub, periodic updates stop writing the thumb position.
3. Accepted seek becomes canonical; buffering remains an orthogonal status.
4. Interject captures that exact media time and enters a guarded recording mode.
5. All timeline/source navigation is inert until explicit Finish or Cancel.
6. Finish saves the recording and resumes exactly once from the configured reorientation point.
7. Timeline review proves the margin is at the expected source time.

Falsification: repeat `drag → play → interject → finish → resume` ten times and require no cumulative drift.

### Flow D — follow without surrendering attention or storage

1. Meaningful progress makes a verified source eligible for a non-modal follow offer.
2. Offer names the exact feed/source and provides Follow, Not now, and Never suggest.
3. Follow creates a local subscription only.
4. Sources inbox refreshes directly from the feed and preserves the last valid snapshot offline.
5. Listener explicitly adds one entry to the Library.
6. Only then may ordinary download or preparation choices apply.

Stopping rule: automatic follow, silent multi-feed choice, or automatic entry import is a failure.

### Flow E — share one margin without leaking a session

1. Margins or Timeline → select one or more margins.
2. Choose representation; private capture remains unchanged.
3. Optionally apply deterministic filler cleanup and shorten bounded source context.
4. Review provenance and rights/source warnings.
5. **Preview as recipient** renders the exact outgoing representation and lists exclusions.
6. Share a transport-neutral package plus optional human-readable rendering.
7. Cancel or destination failure leaves the local session unchanged.

Falsification: diff the package manifest, attachments, and preview inventory; any unlisted field is a blocker.

### Flow F — receive another person's layer without biasing first exposure

1. Import verifies digest and source identity without replacing the active item/session/screen.
2. Exact, adjusted, context-only, unresolved, or invalid resolution is shown.
3. Recipient selects Fresh, Companion, or Guided.
4. Imported entries retain a distinct person/layer label and local mute/delete controls.
5. Commentary returns to the source once at the recipient-local resolved position.
6. A reply produces a new immutable package linked to its parent.

Stopping rule: never auto-place an ambiguous margin or let commentary seize canonical Now Playing ownership unexpectedly.

## Omission check

The proposed navigation was checked against:

- text, PDF, EPUB, article, podcast, and audiobook sources;
- chaptered and mapless/chapterless items;
- online stream, downloaded audio, live speech, partial prepared audio, and complete prepared media;
- foreground, background, Lock Screen, route change, interruption, and relaunch;
- local margin, AI turn, imported layer, unresolved layer, and reply lineage;
- search/filter/sort, Recently Deleted, storage, diagnostics, onboarding, and accessibility;
- offline, malformed, duplicate, corrupt, low-storage, thermal, Low Power Mode, and cancellation states.

Explicitly not represented as primary navigation: Watch, browser extension, classroom, Android, public social feed, ActivityPub, semantic maps, PKM export, typed margins, external-content microphone buffering, and biometric signing. Their future presence should not destabilize the phone information architecture.
