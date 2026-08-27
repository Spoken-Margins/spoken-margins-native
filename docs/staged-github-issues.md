# Staged GitHub feature requests and issue edits

> Historical issue specifications: completed issue descriptions intentionally retain the problem statements and removal criteria that led to the current implementation. They do not advertise retired runtimes as available product features.

Status: **published to GitHub and verified**  
Target repository: `uncomposed/spoken-margins-native`  
Prepared: 2026-08-24
Published and verified: 2026-08-24

This file began as the handoff for GitHub writes that could not be completed because
the connected integration rejected approval-gated writes. Its eleven issue creations
and five existing-issue edits have now been published. It is retained as an audit
record rather than a product specification.

## Publishing order and placeholders

Create the issues in this order and replace each placeholder everywhere in this
file with the resulting issue number before editing the existing issues:

1. `#72` — unified offline-storage budget.
2. `#73` — power-aware demand-window TTS preparation.
3. `#74` — charging-only background preparation.
4. `#75` — untethered Watch playback and interjection sync.
5. `#76` — local subscriptions and source inbox.
6. `#77` — engagement-based follow suggestions.
7. `#78` — canonical PDF chapters and front matter.
8. `#79` — DRM-free local audiobook intake.
9. `#80` — app-observed listening and reading coverage.
10. `#81` — reconcile claimed sharing implementation with source.
11. `#82` — transport-neutral classroom assignment and return packets.

Use the titles and Markdown bodies below verbatim unless the repository has changed
enough that a stated current-state claim is no longer true. Title prefixes encode
the intended classification. Add an existing repository label only if one is
confirmed to exist.

After creation, apply the edits to #64, #34, #61, #69, and #70, then re-read all
sixteen affected issues and run the verification checklist at the end of this file.

---

## Create `#72`

**Status:** Created as [#72 — Unified offline-storage budget for podcasts,
prepared text, and Watch packages](https://github.com/uncomposed/spoken-margins-native/issues/72)
through the GitHub connector on 2026-08-24.

### Title

```text
[Post-MVP] Unified offline-storage budget for podcasts, prepared text, and Watch packages
```

### Body

```markdown
## Outcome

Give users one truthful, enforceable **Offline Storage** budget covering every app-owned media representation that can grow automatically or remain available offline.

The initial implementation may expose category usage and optional category reservations, but the top-level number must bound the total bytes Spoken Margins controls for offline playback.

## Current repository state

Storage is currently split across independent mechanisms:

- podcast downloads have a 1/2/5/10/20 GB LRU cap;
- rendered Supertonic chunks have a separate 128/256/512 MB/1 GB LRU cap;
- completed prepared native-text audio is stored outside the rendered-chunk cache;
- Watch package audio is stored in a separate application-support directory;
- Recently Deleted and item deletion have separate lifecycle behavior.

As a result, lowering one visible cache setting does not currently bound all offline audio owned by the app. Charging-only preparation and restored Watch support must not ship on the assumption that the existing 5 GB podcast default is a global cap.

## Typed storage model

Keep these concepts distinct:

### Storage budget

- user-selected total byte limit;
- current accounted bytes;
- reserved/in-flight bytes;
- device free-space safety floor;
- policy/schema version.

### Owned asset

- stable asset ID and owning item/package;
- category: podcast, prepared native text, render chunk, Watch package, interjection, or another explicitly modeled class;
- canonical file URL/path token, byte count, checksum when applicable, and creation/access timestamps;
- lifecycle: partial, pinned, evictable, transferring, ready, stale, corrupt, or deleted;
- regeneration/recovery capability.

### Protection reason

- active playback;
- active render or atomic commit;
- queued/in-progress Watch transfer;
- unsynced Watch interjection;
- user-pinned offline item;
- temporary deletion/undo window.

### Eviction decision

- bytes required;
- candidates considered;
- protected candidates omitted with reason;
- ordered assets selected;
- post-eviction expected usage;
- explicit failure when sufficient safe eviction is impossible.

## Required policy

- Count committed partial chunks and complete prepared assets, not only cache-directory WAV files.
- Count phone and Watch copies separately when both physically exist.
- Never count remote URLs as local bytes.
- Prefer deleting reproducible intermediate chunks after a complete canonical artifact exists unless they are deliberately retained for resumability.
- Evict least-recently-used reproducible assets before irreplaceable user recordings or unsynced interjections.
- Never evict an asset being played, rendered, committed, or transferred.
- Lowering the total budget immediately plans safe eviction and reports any protected overage honestly.
- Deleting an item removes all owned prepared manifests/assets after the product's undo/Recently Deleted policy permits permanent cleanup.
- Cache eviction must leave the source item usable and able to download or render again.
- Low-device-space handling may impose a stricter emergency floor than the user-selected app budget, with a visible diagnostic reason.
- Automatic work must reserve expected output space before starting a new chunk or download.

## User experience

Settings should show:

- one total Offline Storage limit;
- total current use;
- category breakdown for podcasts, prepared articles/text, Watch copies, and protected user recordings;
- a clear explanation of what is reproducible versus irreplaceable;
- safe clear actions that do not delete source items or unsynced interjections.

Do not imply that a byte limit is consent to follow, download, import, or prepare arbitrary content. Content-selection and auto-preparation policies remain separate user choices.

## Migration

- Inventory and adopt existing podcast files, rendered chunks, prepared Supertonic files, and Watch assets into the ledger without duplicating bytes.
- Reconcile missing files, orphan files, stale records, and incorrect recorded sizes.
- Preserve currently playable items whenever a safe source/reference still exists.
- Migration must be restartable and idempotent.

## Acceptance criteria

- [ ] The sum of all ledger-owned local assets matches on-disk bytes within documented filesystem-allocation tolerance.
- [ ] Completed prepared audio and Watch audio count toward the same top-level limit as podcast downloads.
- [ ] Partial render chunks reserve/count bytes and cannot silently exceed the limit.
- [ ] Active playback, atomic render commits, in-progress transfers, and unsynced recordings are protected from eviction.
- [ ] Lowering the budget evicts eligible assets in deterministic order and reports protected overage.
- [ ] Evicting prepared audio leaves the source item playable through a supported fallback and eligible to render again.
- [ ] Item permanent deletion removes all owned reproducible assets and ledger records without deleting unrelated files.
- [ ] Migration adopts existing assets idempotently and quarantines or removes orphans according to a documented rule.
- [ ] Diagnostics report budget, category usage, reserved bytes, protected bytes, last eviction decision, and reconciliation failures without private content.
- [ ] Persistence migration tests, storage-policy tests, contract validators, SessionKit tests, and relevant iOS/Watch builds pass.
- [ ] The product owner human-validates the Settings, budget reduction, protected-overage, and re-download/re-render flows.

## Audit and falsification checks

- Compare ledger totals with a direct filesystem inventory before and after downloads, partial renders, completed assembly, Watch transfer, eviction, deletion, and relaunch.
- Interrupt migration and every asset-state transition, then rerun reconciliation and require the same final ledger.
- Attempt to exceed the budget using simultaneous download/render/transfer reservations and prove no untracked committed output appears.
- Corrupt, rename, and externally remove representative files and verify explicit recovery states.
- Treat deletion of an active or irreplaceable asset, unbounded unmetered growth, double-counting, or silent protected overage as a failure.

## Dependencies and related work

- #64 provides the durable prepared-audio manifest and ownership information this ledger must account for.
- #74 and #75 should depend on this issue before enabling automatic growth.

## Non-goals

- Cloud storage quotas.
- Treating the storage limit as permission to subscribe to feeds or automatically prepare every discovered item.
- Deleting raw/unsynced interjection recordings as ordinary cache.
- Guaranteeing exact filesystem allocated size across all filesystems; the policy should document the accounting basis.
```

---

## Create `#74`

**Status:** Created as [#74 — [Post-MVP] Charging-only background preparation for native-text audio](https://github.com/uncomposed/spoken-margins-native/issues/74) through
the GitHub connector on 2026-08-24.

### Title

```text
[Post-MVP] Charging-only background preparation for native-text audio
```

### Body

```markdown
## Outcome

Allow eligible native-text items to be prepared with the local Supertonic runtime while the iPhone is idle and connected to power, so daytime listening can use already-rendered audio with lower foreground latency and compute demand.

This is a best-effort iOS background capability. It must not promise that work will start at a particular time, run whenever the screen is locked, or continue while the phone is powered off.

## Current repository state

- #64 defines durable, resumable prepared native-text audio but currently limits automatic work to the active/newly imported item.
- The app declares background audio capability, not a `BGProcessingTask` identifier and launch handler.
- The current render path can persist chunk audio and assemble a complete prepared file, but it does not have a durable OS-scheduled job queue.
- Existing podcast, rendered-chunk, completed prepared-audio, and Watch-package bytes do not yet share one global storage budget; that work is tracked by #72.

## Product policy

Expose an explicit setting such as **Automatic Audio Preparation** with at least:

- Off;
- While Charging.

The setting chooses whether work may be scheduled; it does not choose which arbitrary content the app may import or follow. Initial automatic eligibility should be deliberately narrow:

- the source item already exists in the user's library;
- its normalized source and selected voice are locally available;
- no listening session for the item is substantially complete (initial threshold: 90%);
- its render signature is current and the manifest is incomplete;
- the user has not stopped or excluded the item;
- required output space can be reserved under #72;
- device thermal and low-space policy permit another chunk.

An explicit **Prepare Audio** action may override the substantially-complete rule but not storage, integrity, or device-safety rules.

## Execution topology

Keep these layers separate:

### Durable preparation job

- stable job and item IDs;
- render signature and manifest revision;
- priority/reason: explicit request, newly imported eligible item, or automatic retry;
- state: queued, running, thermally paused, storage blocked, expired, stopped, failed, or complete;
- attempt metadata and retry eligibility;
- no dependence on an in-memory task surviving process termination.

### OS scheduling request

- register a permitted `BGProcessingTask` identifier during app launch;
- submit a `BGProcessingTaskRequest` with `requiresExternalPower = true`;
- set `requiresNetworkConnectivity = false` for locally available source/model work;
- use an earliest-begin date only as a hint;
- keep at most one meaningful pending request and resubmit only while eligible jobs remain.

### Render transaction

- load/verify the #64 manifest;
- render at most one chunk at a time;
- write to a temporary file and atomically commit audio plus mapping/integrity metadata;
- check expiration, cancellation, thermal state, and reserved space before starting the next chunk;
- release the model runtime at completion, cancellation, or expiration.

### Prepared artifact

- remains owned by #64 and the storage ledger;
- must be usable regardless of whether it was produced in the foreground or a background task;
- must not create a second background-only playback representation.

## Expiration, interruption, and recovery

- Install the background task expiration handler before starting work.
- On expiration, prevent another chunk from starting and cancel cooperative work where safe.
- Never expose a temporary or partially committed chunk as playable.
- Preserve every previously committed valid chunk and resume from the first incomplete chunk in a later eligible task.
- Mark the OS task successful only when its bounded work completed without an integrity failure; distinguish normal expiration from corrupt output.
- Disabling automatic preparation cancels pending scheduler requests and prevents future automatic chunks. It may preserve committed reusable chunks under the storage policy.
- Force-quit, reboot, scheduler denial, unplugging power, serious/critical thermal state, and low-space conditions must converge to an explicit resumable state.

## User experience and diagnostics

- Show item-level preparation state and durable progress from #64.
- Explain that charging preparation is scheduled by iOS and is not guaranteed to complete overnight.
- Provide Stop/Resume or Prepare Audio controls without presenting background execution as real-time.
- Diagnostics should include job state, eligibility decision, scheduler submission result, last launch/expiration reason, completed chunk count, thermal pauses, reserved/committed bytes, and redacted failure codes.

## Acceptance criteria

- [ ] The app registers its processing-task identifier and permitted identifier configuration before submitting requests.
- [ ] Automatic requests require external power and do not require networking for local synthesis.
- [ ] Disabling the setting prevents new automatic work and cancels any pending processing request.
- [ ] The background handler selects only policy-eligible library items and never sweeps every incomplete item merely because the app launched.
- [ ] Maximum whole-item render concurrency remains one and chunks render serially.
- [ ] Expiration at every representative chunk boundary preserves earlier commits and restarts only the incomplete chunk.
- [ ] Relaunch/reboot reconstructs jobs from durable state rather than an in-memory task.
- [ ] Thermal, low-space, stale-signature, deletion, and Stop transitions prevent the next chunk without corrupting committed output.
- [ ] Storage is reserved and committed through #72; complete packages cannot grow outside the selected budget.
- [ ] Foreground and background rendering produce the same manifest signature, mappings, checksums, and canonical prepared-media behavior.
- [ ] Contract validators, SessionKit tests, background-task tests, and iOS device builds pass.
- [ ] The product owner human-validates opt-in, Stop, charging behavior, overnight progress, and prepared playback on supported physical devices.

## Audit and falsification checks

- Record physical-device evidence for unplugged, plugged-in/locked, Low Power Mode, serious/critical thermal state, low storage, task expiration, reboot, and force-quit scenarios.
- Count synthesis invocations and compare manifests to prove committed chunks are not regenerated after interruption.
- Compare foreground and background outputs for the same render signature and require identical source-to-media mappings within documented encoding tolerance.
- Attempt simultaneous foreground preparation and background launch; require one owner and no duplicate chunks.
- Treat an unbounded library sweep, work after opt-out, output outside the storage ledger, a false completion claim, or a corrupted partial commit as a failure.

## Dependencies and related work

- Depends on #64 for durable render manifests and atomic chunk commits.
- Depends on #72 before automatic preparation can be enabled.
- #75 consumes the completed artifact but should not own the phone renderer.

## Non-goals

- Rendering while the iPhone is powered off.
- Guaranteed start or completion times from `BGTaskScheduler`.
- Running Supertonic on Apple Watch.
- Following feeds, importing unseen items, or preparing every new feed entry automatically.
- Using continuous background-audio playback as a loophole to keep synthesis running.
```

---

## Create `#75`

**Status:** Created as [#75 — [Post-MVP] Restore untethered Apple Watch playback and interjection sync](https://github.com/uncomposed/spoken-margins-native/issues/75) through
the GitHub connector on 2026-08-24.

### Title

```text
[Post-MVP] Restore untethered Apple Watch playback and interjection sync
```

### Body

```markdown
## Outcome

Restore an installable Apple Watch app that can receive phone-prepared native-text audio, play it without the iPhone or a network connection, capture interjections during a run, and reconcile those interjections into the canonical phone session when connectivity returns.

The phone should render once. Watch delivery must package the same verified prepared representation from #64 rather than introducing a separate Watch TTS pipeline.

## Current repository state

- The repository contains prior Watch connectivity, package-rendering, playback, and closeout documentation.
- The current generated project configuration does not expose an active Watch app target and excludes key Watch connectivity/package coordinator sources from the iOS target.
- Existing package work can inform the implementation, but target wiring, signing, current runtime integration, and end-to-end transfer behavior must be re-audited rather than assumed complete.
- Watch package files are not currently governed by the same top-level storage budget as phone downloads and prepared text; that dependency is #72.

## Execution topology

Keep these responsibilities distinct:

### Phone preparation

- #64 owns source normalization, Supertonic synthesis, the durable manifest, exact duration, and source-to-media mapping.
- #74 may schedule that work while charging.
- No Watch-specific synthesis output is generated until a complete compatible manifest exists.

### Watch package assembly

Create a versioned package containing at least:

- stable package ID, item ID, source revision, and package schema version;
- complete render signature: source hash, voice ID, engine/model version, and synthesis parameters;
- encoded audio derived from the canonical prepared artifact;
- whole-item duration and source-to-media mapping needed to place interjections;
- byte counts and checksums for every transferred component;
- minimal title/source metadata needed for an offline library and Now Playing surface.

Package assembly must be atomic and idempotent. A changed source, voice, model, schema, or mapping invalidates the incompatible package.

### Transfer state

- Use durable phone-side states such as awaiting preparation, packaging, queued, transferring, awaiting acknowledgement, installed, stale, failed, and removed.
- Use an appropriate `WCSession` background transfer API for file payloads; do not require both apps to be simultaneously foregrounded.
- The Watch verifies checksums and atomically installs a package before acknowledging the exact package revision.
- Retrying the same package/revision is idempotent.
- Phone storage protection remains in effect until acknowledgement or an explicit cancellation policy releases it.

### Watch playback

- Play package audio locally in airplane mode with canonical play/pause, interval skip, scrub, playback-rate, elapsed, and duration behavior supported by the package.
- Persist item/session position on Watch and reconcile monotonically with phone state using explicit conflict rules.
- Never fabricate duration or source position when package metadata is missing or corrupt.

### Interjection outbox

- Capture each Watch interjection as a durable event with a stable event ID, package/item revision, Watch media time, mapped source position, creation time, and optional audio recording.
- Persist the event and recording before showing it as saved.
- Transfer events/recordings through a retryable outbox that survives Watch app termination, reboot, intermittent connectivity, and duplicate delivery.
- The phone imports each event ID exactly once, preserves the raw recording until durable acknowledgement, and associates it with the canonical session/item.
- Package eviction or replacement must not delete unsynced interjections.

## Target and lifecycle work

- Restore the Watch app/extension target, schemes, source membership, entitlements, deployment targets, assets, signing relationships, and generated-project configuration.
- Reconcile dormant Watch code with the current SessionKit contracts instead of reviving obsolete snapshot or command IDs.
- Define phone deletion, Watch removal, stale package, reinstall, version-skew, and paired-device replacement behavior.
- Count phone packages and Watch-installed copies separately through #72 while protecting in-flight transfers and unsynced recordings.

## Acceptance criteria

- [ ] The repository generates and builds an active Watch target for supported generic watchOS and paired iOS destinations.
- [ ] One phone render manifest produces one versioned Watch package without rerunning TTS for Watch.
- [ ] Package and component checksums are verified before atomic Watch installation.
- [ ] Transfer survives phone/Watch backgrounding, intermittent reachability, duplicate delivery, relaunch, and reboot.
- [ ] The Watch can browse installed items and play, pause, skip, scrub, change rate, and resume in airplane mode.
- [ ] Watch position and interjections map back to the intended source revision and never silently attach to a stale item.
- [ ] Every interjection event is imported exactly once despite duplicate transport delivery.
- [ ] Unsynced interjection audio survives package eviction, app relaunch, reboot, and transfer retry.
- [ ] Storage accounting includes phone and Watch copies and protects active/in-flight/unsynced assets.
- [ ] Deleting or replacing an item follows a documented two-device lifecycle and never removes unrelated packages.
- [ ] Contract validators, SessionKit tests, iOS builds, Watch builds, and focused device traces pass.
- [ ] The product owner human-validates the untethered run: transfer, airplane-mode playback, multiple interjections, reconnection, and phone-side reconciliation.

## Audit and falsification checks

- Interrupt package assembly and transfer at each state transition; require a valid prior package or an explicit incomplete state, never a half-installed package.
- Replay every transfer message and acknowledgement to prove idempotency.
- Create interjections immediately before seek, pause, app termination, reboot, and package replacement; verify exact-once phone import and source mapping.
- Compare manifest, package, installed bytes, and ledger records before and after retry, eviction, deletion, and reinstall.
- Test incompatible phone/Watch package schema versions and require a clear blocked/reprepare path.
- Treat Watch-side TTS rerendering, loss of an unsynced recording, attachment to the wrong source revision, or a false installed acknowledgement as a failure.

## Dependencies and related work

- Depends on #64 for the canonical prepared representation and source-to-media mapping.
- Depends on #72 for bounded phone and Watch storage.
- May consume output scheduled by #74, but manual phone preparation must also work.
- Preserve the canonical playback-state corrections tracked by #59 and #71.

## Non-goals

- Running the neural TTS model on Watch.
- Streaming phone audio to Watch during an untethered run.
- Cloud storage or server-side interjection processing.
- Claiming human validation from builds or automated traces; only the product owner validates the end-to-end product flow.
```

---

## Create `#76`

**Status:** Created as [#76 — [Post-MVP] Local feed subscriptions and “New from Sources” inbox](https://github.com/uncomposed/spoken-margins-native/issues/76) through
the GitHub connector on 2026-08-24.

### Title

```text
[Post-MVP] Local feed subscriptions and “New from Sources” inbox
```

### Body

```markdown
## Outcome

Add a local, privacy-preserving feed layer that lets a user explicitly follow podcast or article sources and see new entries in a lightweight **New from Sources** inbox without configuring a traditional RSS client.

Following a source must not automatically import every entry into the listening library, download media, or prepare TTS. The inbox is discovery state; the library remains deliberate listening state.

## Current repository state

- #46 established podcast URL resolution and feed parsing foundations.
- `PublicPodcastLinkResolver` can identify canonical podcast feeds, but the canonical feed identity is not consistently retained as first-class source metadata after import.
- Browser/native-text source records retain article URL/title/author/date but do not persist validated feed candidates or subscription identity.
- Existing feed parsing is podcast-oriented and expects audio enclosures; article RSS/Atom entries need a separate general entry model.
- #49 can later enrich browser handoff with canonical/feed metadata, but subscriptions must work without requiring the extension.

## Typed data model

Keep these concepts separate:

### Feed subscription

- stable local subscription ID;
- normalized feed URL and site/source URL;
- kind: podcast, article, or explicitly modeled mixed feed;
- display title/icon metadata;
- user state: following, muted, or unfollowed;
- refresh policy and last successful/attempted refresh;
- HTTP validator state such as ETag and Last-Modified;
- parser/schema version and latest error state.

### Feed entry

- stable subscription-scoped entry identity;
- GUID/Atom ID when present plus normalized canonical link;
- title, author/source, publication/update date, and bounded summary metadata;
- optional podcast enclosure URL/type/length;
- entry kind and importability state;
- first-seen time, read/dismissed state, and link to a library item only after import.

### Refresh result

- request/response status and redirect result;
- entries inserted, updated, ignored, or rejected;
- cursor/validator changes committed atomically with entry changes;
- next eligible refresh and safe diagnostic error code.

## Refresh and parsing policy

- Start with explicit follow/unfollow, manual refresh, refresh on an appropriate foreground opportunity, and bounded staleness. Background refresh can be a later policy decision.
- Use conditional HTTP requests and accept standards-compliant redirects under a documented canonicalization rule.
- Enforce response byte, decompression, XML nesting, entry count, text length, and redirect limits.
- Parse RSS and Atom article entries without requiring an audio enclosure; retain podcast enclosure handling where present.
- Never execute embedded markup or remote script. Sanitize/strip feed HTML before display.
- Resolve relative links against the feed/base URL and reject unsupported or unsafe URL schemes.
- Dedupe deterministically using feed identity plus GUID/Atom ID where reliable, then canonical link/enclosure evidence, then a documented fallback fingerprint.
- Entry updates must not duplicate an already imported library item.
- Refresh failure keeps the last valid subscription snapshot and reports a retryable or terminal reason.

## Product behavior

- A user can follow from a validated suggestion, a known podcast feed, or a manually supplied feed URL if that surface is later exposed.
- The source inbox groups or identifies entries by followed source and distinguishes new, seen, dismissed, and imported states.
- Opening an entry previews its metadata; importing it uses the existing podcast or browser/native-text intake path.
- Unfollowing stops refresh and removes or retains historical inbox entries according to an explicit product rule; it does not delete already imported library items.
- Muting suppresses new-entry presentation without losing the subscription identity.
- Feed state, refresh history, and reading/listening decisions remain on device. Network requests go only to the source/feed hosts and necessary redirect/CDN hosts.

## Acceptance criteria

- [ ] Podcast and article subscriptions persist locally with normalized feed identity and HTTP validators.
- [ ] RSS and Atom article feeds parse without an audio enclosure; podcast enclosures still retain playable media metadata.
- [ ] Conditional refresh handles 200, 304, redirects, transient failure, malformed content, and oversized responses without losing the last valid state.
- [ ] Repeated and reordered refreshes do not duplicate entries or imported library items.
- [ ] The inbox distinguishes unseen, seen, dismissed, and imported entries and remains usable offline with the last valid snapshot.
- [ ] Following does not automatically download, import, render, or prepare entries.
- [ ] Unfollow/mute behavior is explicit and does not delete existing library items or interjections.
- [ ] Parser/resource limits and safe URL/markup handling have focused adversarial tests.
- [ ] Persistence migrations, contract validators, SessionKit tests, and relevant iOS builds pass.
- [ ] Diagnostics expose feed URL hashes/host-safe metadata, validator state, counts, and error categories without logging private article content.
- [ ] The product owner human-validates follow, refresh, inbox, import, mute, unfollow, and offline-last-snapshot flows.

## Audit and falsification checks

- Refresh fixed RSS and Atom fixtures with reordered entries, reused GUIDs, changed links, missing dates, duplicate enclosures, redirects, and 304 responses.
- Feed oversized, deeply nested, compressed, malformed, and hostile-markup fixtures to the parser and prove bounded failure.
- Interrupt persistence between entry and cursor updates and require idempotent reconciliation on the next refresh.
- Compare network hosts contacted with the chosen feed/redirect chain; unexpected analytics or search hosts are a failure.
- Treat automatic library import, automatic TTS preparation, duplicate entries, lost prior state after refresh failure, or deletion of imported items on unfollow as a failure.

## Dependencies and related work

- Reuse the podcast feed-resolution and parsing foundations from #46.
- #77 depends on this issue for the actual follow action and inbox.
- #49 may pass richer article/feed evidence from a desktop browser but is not required for the local subscription core.

## Non-goals

- A cloud account or cross-device subscription sync.
- Server-side recommendation or behavioral profiling.
- Full parity with specialist RSS clients, including folders, rules, OPML, and every feed extension.
- Automatically downloading, importing, rendering, or deleting listening-library items.
```

---

## Create `#77`

**Status:** Created as [#77 — [Post-MVP] Engagement-based feed suggestions for podcast and article items](https://github.com/uncomposed/spoken-margins-native/issues/77) through
the GitHub connector on 2026-08-24.

### Title

```text
[Post-MVP] Engagement-based feed suggestions for podcast and article items
```

### Body

```markdown
## Outcome

When a user is meaningfully engaged with a podcast episode or article, offer a low-friction, local suggestion to follow its source. Accepting the suggestion creates the subscription defined by #76; dismissing it is remembered and frequency-capped.

Interjections are a strong engagement signal, but the system may also use a documented listening-progress threshold so a user does not have to create an interjection merely to see a relevant follow option.

## Product boundary

- The suggestion is an offer, not an automatic subscription.
- Engagement decides **when** to offer; verified source evidence decides **what** source can be offered.
- Storage allowance is not subscription consent.
- The feature remains local except for direct retrieval of the original page/feed candidates needed to validate source identity.
- Do not send listening history, interjections, article URLs, or behavioral profiles to a recommendation/search service.

## Current repository state

- Podcast resolution can discover a canonical feed, but that identity may be discarded when SessionKit persists the imported item.
- Article/browser sources retain the page URL but not validated RSS/Atom candidates or discovery evidence.
- #46 provides reusable podcast resolution foundations.
- #49 is a natural place for a browser extension to include canonical URL and feed-link evidence in handoff, but phone-side discovery must also handle ordinary article imports.

## Evidence model

Persist source evidence independently from the user decision:

### Candidate

- normalized feed URL and source/site URL;
- feed kind and display metadata;
- discovery method;
- confidence and validation result;
- redirect/canonicalization chain within bounded limits;
- entry evidence linking the current item to the candidate feed;
- discovery/parser version and last validation time.

### Decision

- item/source/subscription identity;
- accepted, dismissed, never suggest this source, or superseded;
- trigger type and timestamp;
- prompt-frequency state;
- no raw interjection content.

## Candidate discovery and ranking

Use deterministic evidence in descending order:

1. A canonical podcast feed URL already verified by the podcast resolver/import path.
2. An HTML `<link rel="alternate">` advertising RSS, Atom, or JSON Feed on the canonical article page.
3. A validated candidate whose feed contains an entry matching the article's canonical URL.
4. A bounded same-origin heuristic candidate only when it can be fetched and validated as a feed.

Rules:

- Preserve canonical podcast feed identity as first-class metadata when resolving/importing an episode.
- Preserve the article's canonical page URL and any validated feed links supplied by native import or #49.
- Validate content and feed structure; do not trust a URL extension or MIME type alone.
- Prefer candidates that contain an entry matching the current canonical page/enclosure.
- Never silently choose between materially different high-confidence feeds; show a compact chooser or defer the suggestion.
- Do not prompt for low-confidence candidates that cannot be tied to the consumed item.
- Bound redirects, response size, parse work, candidate count, and same-origin heuristic paths.
- Cache successful and negative discovery results with an expiry so playback does not repeatedly fetch a page.

## Engagement and presentation policy

An item becomes prompt-eligible only when all are true:

- it has a validated candidate not already followed;
- the user has created an interjection or crossed a documented meaningful-progress threshold;
- no prior dismissal/suppression applies;
- the same source has not been prompted within the frequency-cap window;
- playback is at a safe UI transition rather than being interrupted by a modal.

Present an inline card or compact post-engagement affordance containing the source name and a clear **Follow** action. Provide **Not now** and a durable **Don't suggest this source** path. Do not obscure transport controls or interrupt spoken audio.

Accepting follows the exact displayed feed through #76. It does not import, download, or prepare unseen entries.

## Acceptance criteria

- [ ] Canonical podcast feed identity survives resolution, import, persistence, and relaunch.
- [ ] Article sources can persist canonical page URL plus validated feed candidates and evidence.
- [ ] A verified podcast feed produces one correctly named suggestion after engagement.
- [ ] An article with a valid advertised feed and matching entry produces one correctly named suggestion.
- [ ] Multiple credible feeds cause an explicit chooser/defer path rather than a silent arbitrary subscription.
- [ ] Missing, malformed, unrelated, oversized, cross-origin-abusive, or low-confidence candidates do not produce a misleading prompt.
- [ ] Suggestions are frequency-capped and respect Not now, Don't suggest this source, existing subscription, deletion, and source-change state.
- [ ] The prompt does not interrupt playback or require an interjection when the progress threshold is otherwise satisfied.
- [ ] Follow subscribes to the displayed normalized feed and does not import, download, or prepare entries automatically.
- [ ] No listening progress, interjection content, or behavioral profile is transmitted to a search/recommendation service.
- [ ] Persistence/discovery tests, contract validators, SessionKit tests, and relevant iOS builds pass.
- [ ] The product owner human-validates podcast, article, multiple-candidate, dismissal, suppression, and follow-to-inbox flows.

## Audit and falsification checks

- Test canonical links, relative feed links, redirect loops, spoofed MIME types, feeds without the article, multiple feeds, reused URLs, and maliciously large pages/feeds.
- Record every host contacted during discovery and require it to match the source/validated redirect policy.
- Recreate the same engagement and relaunch repeatedly; require at most one prompt under the frequency policy.
- Change the persisted item/source revision and prove stale evidence cannot subscribe the new item to the old source.
- Treat automatic follow, silent multi-feed selection, prompts for unrelated feeds, playback interruption, or export of engagement data as a failure.

## Dependencies and related work

- Depends on #76 for subscription persistence, refresh, and inbox behavior.
- Reuses #46 for podcast feed resolution.
- #49 may supply canonical/feed-link evidence for browser-originated articles.

## Non-goals

- Automatic subscriptions based solely on listening behavior.
- Server-side recommendation, search, or engagement analytics.
- Automatically importing, downloading, or preparing entries after follow.
- Building a general web crawler or guessing unvalidated feeds across unrelated hosts.
```

---

## Create `#73`

**Status:** Created as [#73 — [Post-MVP] Power-aware demand-window TTS preparation for long-form text and EPUBs](https://github.com/uncomposed/spoken-margins-native/issues/73) through
the GitHub connector on 2026-08-24.

### Title

```text
[Post-MVP] Power-aware demand-window TTS preparation for long-form text and EPUBs
```

### Body

```markdown
## Outcome

Prepare enough synthesized audio to keep long-form text and EPUB playback continuous without unnecessarily draining the reader's battery or holding the TTS model hot for hours. Extend preparation opportunistically when the phone is plugged in and conditions are safe.

## Separation of concerns

- **Canonical source structure:** PDF/Markdown/EPUB chapter and source locations exist independently of rendered audio.
- **Durable preparation:** #64 owns chunk manifests, atomic commits, invalidation, media-time mapping, and completed prepared media.
- **Eligibility and horizon:** this issue decides which chunks should render next based on listening demand and device conditions.
- **Execution topology:** #74 owns opt-in `BGProcessingTask` scheduling and OS expiration/relaunch behavior; this issue's horizon policy also governs foreground work.
- **Playback:** the active session consumes valid prepared audio when available and exposes an honest buffering/preparing state at an unprepared boundary; it must not silently change voice/runtime.

## Scheduling policy

- Always prioritize the active playback position, then the remainder of the current chapter, then a bounded look-ahead normally covering the next canonical chapter.
- Bound the look-ahead by both canonical chapters and a configurable estimated-duration/storage limit so one enormous chapter cannot create unbounded work.
- On battery, stop scheduling once the demand window is satisfied.
- When connected to external power, Low Power Mode is off, thermal state is eligible, storage is available, and the item remains eligible, continue serial preparation beyond the demand window and potentially through the remaining item.
- Serious/critical thermal state, Low Power Mode, explicit Stop, low storage, item deletion, source/voice invalidation, or loss of eligibility prevents the next chunk from starting while preserving valid committed work.
- A chapter jump immediately reprioritizes the selected location; obsolete uncommitted work may be cancelled, but committed compatible chunks are reused.
- Background work is best effort and must respect the OS-provided execution window. Never claim that iOS guarantees completion of a whole book in the background.
- Only one resource-intensive item render job runs at a time. Playback-critical demand outranks opportunistic preparation for another item.
- An explicit **Prepare Audio** action may request a longer horizon, but it does not override thermal, Low Power Mode, storage, or OS execution safety constraints.
- Persist enough reason/state to explain whether preparation is demand-satisfied, plugged-in continuing, thermally paused, low-power paused, stopped, failed, or ready.

## Acceptance criteria

- [ ] On battery, a long book prepares the current chapter plus the bounded next-chapter window and then stops scheduling additional chunks.
- [ ] Plugging in under eligible conditions resumes at the first useful incomplete chunk and can continue toward full preparation without rerendering valid chunks.
- [ ] Enabling Low Power Mode or entering serious/critical thermal state prevents the next chunk from starting and preserves committed output.
- [ ] Returning to eligible conditions resumes according to current listening demand, not a stale pre-jump queue.
- [ ] Jumping to a distant chapter reprioritizes it ahead of prior speculative work.
- [ ] An oversized chapter remains bounded by the duration/storage horizon.
- [ ] Foreground/background transitions, expiration of background time, termination, and relaunch preserve a coherent durable state.
- [ ] The UI exposes useful preparation progress/reason without promising background completion.
- [ ] Power-aware scheduling changes neither canonical source anchors nor the selected voice/runtime.

## Verification and stopping rules

Use an injected scheduler clock and synthetic battery, charging, Low Power Mode, thermal, storage, background-time, playback-position, and chapter-jump signals for deterministic transition tests. On physical devices, compare battery use, peak thermal state, time-to-first-audio, render gaps, and completed-audio horizon for battery versus plugged-in runs on representative article and book lengths.

Do not ship an “always render everything” policy under a power-aware name. Stop or narrow opportunistic work if it materially delays active playback, causes repeated serious thermal pressure, violates the bounded battery horizon, or cannot recover deterministically after interruption.

## Dependencies and related work

- #64 owns durable prepared media.
- #61 owns EPUB structure and source-location correctness.
- #74 owns optional background execution topology.
- #72 owns byte accounting, reservations, and eviction policy.

## Non-goals

- Guaranteeing completion during an iOS background window.
- Replacing canonical chapters with rendered-media chunks.
- Allowing speculative work to outrank active playback.
```

---

## Create `#78`

**Status:** Created as [#78 — Preserve canonical PDF chapters and distinguish table of contents/front matter](https://github.com/uncomposed/spoken-margins-native/issues/78) through
the GitHub connector on 2026-08-24.

### Title

```text
Preserve canonical PDF chapters and distinguish table of contents/front matter
```

### Body

```markdown
## Problem

Text-based PDF imports can expose a real chapter title in both the table of contents and at the chapter's destination. The extractor previously matched outline titles globally, so the contents-page occurrence could consume the heading and make the chapter begin at the title/author/contents pages. Separately, deterministic maps merged canonical PDF headings down to a hard maximum of 12 chapters even when the document contained more.

A representative regression is an anthology such as G. K. Chesterton's *Tremendous Trifles*: selecting “A Piece of Chalk” should start at that story, not at the book title or contents, and all later stories should remain available.

## Failure model

- **Extraction:** PDF encodings and line geometry vary; outline destinations are stronger evidence than title text alone.
- **Canonical structure:** authored PDF outline/heading boundaries must not be treated like optional listening-length suggestions.
- **Listening structure:** title, authors, summary, and contents may be useful but must not be silently folded into the first story.
- **Verification:** generated fixtures and a representative real-world corpus are needed because one PDF shape cannot falsify the heuristics.

## Required behavior

- Match an outline title only at its destination page/position rather than the first same-title occurrence in the document.
- Treat an explicit Contents/Table of Contents label, repeated off-destination outline-title matches, dot leaders, and trailing page numbers as contents evidence rather than chapter starts.
- Preserve nonempty material before the first canonical chapter as a separate `Front Matter` entry.
- Preserve every detected canonical PDF heading without a fixed 12-chapter ceiling.
- Keep ranges ordered, contiguous, and anchored to the real chapter text.
- Retain adaptive merge/split behavior for ordinary Markdown; this bug concerns canonical PDF structure.

## Acceptance criteria

- [ ] A generated PDF with title/author material, a contents page, and 20 destination-backed stories produces exactly `Front Matter` plus all 20 story chapters.
- [ ] Clicking the first story begins at its actual destination, not character zero.
- [ ] Contents entries do not appear as duplicate chapters.
- [ ] Numbered headings on an ordinary content page are not suppressed without additional contents evidence.
- [ ] Duplicate/similar titles remain associated with their own destinations.
- [ ] PDFs without usable outlines continue to use conservative visual-heading fallback.
- [ ] Scanned/image-only PDFs continue to fail clearly unless OCR has already supplied text.

## Audit / stopping rule

Evaluate a small corpus spanning publisher outlines, visual headings only, contents with and without page numbers, duplicate titles, nested outlines, multi-page contents, and malformed/no-outline PDFs. Compare chapter precision/recall and anchor-page accuracy against the prior implementation. Stop or narrow any heuristic that increases false chapter suppression on ordinary content pages. Product-owner use is required before marking the flow human-validated.

## Implementation status

Implemented on the main working tree with focused package coverage and a generated 20-story PDF regression fixture. Keep this issue open until the product owner validates the flow on a representative PDF.
```

---

## Create `#79`

**Status:** Created as [#79 — [Post-MVP] Import DRM-free local audiobooks as native audio](https://github.com/uncomposed/spoken-margins-native/issues/79) through
the GitHub connector on 2026-08-24.

### Title

```text
[Post-MVP] Import DRM-free local audiobooks as native audio
```

### Body

```markdown
## Outcome

Allow a user to import a DRM-free audiobook file from Files and listen through Spoken Margins' canonical native-audio path, preserving embedded chapters when present and retaining ordinary resume and interjection behavior.

## Product boundary

This is local media intake, not TTS:

- The imported audio remains the playback source; do not synthesize the audiobook again.
- Full-source transcription is not required for initial playback.
- DRM-protected files are explicitly out of scope and must be rejected clearly.
- Start with one audio file per imported item. Multi-file folders/disc sets can be a later issue once ordering, duplicate metadata, and shared-book progress have an explicit contract.

## Intake and ownership

- Accept common AVFoundation-readable audiobook/audio containers such as MP3, M4A, M4B, and audio-bearing MP4 when they are not protected.
- Acquire the document-picker/security-scoped URL only long enough to validate and copy the source into app-owned storage.
- Inspect playability, duration, protection state, metadata, artwork when safely available, and embedded chapter metadata before publishing a ready library item.
- Persist the owned file as a native-media representation so playback works offline and after relaunch without depending on the original Files-provider URL.
- Use stable item/media identity and collision-safe storage paths.
- An import failure must not leave a ready item, orphaned media, or a half-copied file.
- Deleting the item removes its owned audio and derived data through the existing cleanup policy.

## Chapters and playback

- Prefer embedded AVFoundation chapter metadata as canonical authored structure.
- Preserve every valid embedded chapter in order; do not impose the adaptive native-text chapter cap.
- A chapterless file remains fully playable as one item rather than requiring generated chapters.
- Use media-time anchors for resume, seeking, skip, interjections, Lock Screen state, and export references.
- Importing in the background must not replace or restart an already active session.
- Reuse the existing native-audio player, duration authority, chapter timing, and interjection context paths rather than introducing an audiobook-only transport.

## Acceptance criteria

- [ ] A DRM-free MP3 imports, copies into app-owned storage, plays offline, and resumes after relaunch.
- [ ] DRM-free M4A/M4B fixtures with embedded chapters expose all chapter titles and navigate to the correct media times.
- [ ] A chapterless file is playable and seekable without a fabricated Listening Map.
- [ ] A protected/DRM fixture is rejected with a useful message and leaves no playable or orphaned item.
- [ ] Malformed, unsupported, zero-duration, interrupted-copy, duplicate-import, low-space, and deleted-source cases fail or recover deterministically.
- [ ] Importing while another item is playing preserves the active session.
- [ ] Interjections remain anchored to the correct audiobook media time before and after pause/resume and relaunch.
- [ ] Deleting an imported audiobook removes the app-owned file without affecting unrelated media.

## Audit / falsification checks

Exercise fixtures across supported containers, metadata encodings, embedded/no chapters, long duration, variable bit rate, protection, corrupted tails, and Files/iCloud providers. Compare app-reported duration and chapter starts against AVFoundation observations. Treat a dependency on the transient picker URL, a silent DRM failure, a lost chapter, a changed active session, an orphaned file, or a resume-time drift as a failure.

## Dependencies and related work

- #46, #55, and #66 cover direct audio URLs or native-audio defects, but not durable local-file intake.
- #72 owns global offline byte accounting and eviction policy.

## Non-goals

- DRM circumvention.
- Multi-file books or disc sets in the initial version.
- Full-source transcription as a playback prerequisite.
```

---

## Create `#80`

**Status:** Created as [#80 — [Post-MVP] Record app-observed source coverage for listening and in-app reading](https://github.com/uncomposed/spoken-margins-native/issues/80) through
the GitHub connector on 2026-08-24.

### Title

```text
[Post-MVP] Record app-observed source coverage for listening and in-app reading
```

### Body

```markdown
## Outcome

Record a privacy-preserving local observation ledger from which Spoken Margins can deterministically derive how much of a specific source revision the app presented through listening or its own reading surface. The ledger may later supply an optional classroom participation receipt, but it must never be described as proof that a person paid attention, understood, or completed work.

## Current repository gap

- A session retains a latest playback position and completion percentage, not the path used to reach it.
- Seeking can move the latest position without establishing that the skipped interval was presented.
- Replays, interruption boundaries, and mixed reading/listening coverage are not modeled as durable observations.
- The native-text reading sheet is not an instrumented reading surface.
- Interjection chronology needs a real, injectable wall/monotonic clock rather than sequence-derived epoch timestamps before it can support trustworthy ordering evidence.

## Typed boundaries

Keep these layers separate:

### Source binding

- stable item ID;
- source and edition/revision identity;
- canonical coordinate space and mapping version;
- optional content digest that excludes private annotations.

### Observation event

- stable event ID and schema version;
- mode: listening or in-app reading;
- canonical start/end coordinates;
- real wall timestamp for display plus monotonic duration for interval calculation;
- device/session ID suitable for local deduplication;
- reason for opening/closing the interval, such as pause, seek, route change, interruption, background transition, viewport change, or end of item.

### Coverage projection

- normalized non-overlapping canonical intervals by mode;
- union coverage across modes;
- replay/revisit counts kept separate from first coverage;
- explicit unknown/unobserved regions;
- deterministic algorithm and version.

### Receipt/export

- assignment/source binding;
- coverage summary and optional bounded event evidence;
- creation time, schema/algorithm versions, and integrity digest;
- explicit language that the data is app-observed presentation, not attention or comprehension.

## Listening semantics

- Count only intervals for which playback progress was actually confirmed by the canonical session/player spine.
- A forward seek does not cover the skipped interval; a backward seek does not erase prior coverage.
- Playback rate changes elapsed time but not canonical source coverage.
- Commentary/interjection playback does not count as source coverage.
- Pause, interruption, route loss, failed preparation, and unconfirmed background playback close the active interval at the last confirmed position.
- Replays may contribute engagement/revisit statistics but cannot increase union coverage beyond 100 percent.

## In-app reading semantics

- Count reading evidence only from an explicit Spoken Margins reading surface with stable source-coordinate mapping.
- A document open, navigation jump, or rapid scroll to the end does not mark skipped text as covered.
- Visible-range and bounded dwell evidence means only that the app presented that range; it is not eye tracking or proof of attention.
- External reading remains `self_attested` or `unobserved`; do not silently convert it into app-observed coverage.
- Mixed read/listen sessions merge in canonical source coordinates while preserving per-mode evidence.

## Privacy and control

- Keep the detailed ledger local by default.
- Export only after an explicit, previewable user action and minimize event detail to the stated purpose.
- Never collect microphone content, private interjection audio/text, unrelated library history, or background activity merely to compute coverage.
- Let the participant inspect what will be shared, omit optional interjections, and cancel without changing their local work.
- Define retention, deletion, and re-export behavior before adding any relay or server storage.

## Acceptance criteria

- [ ] Versioned schemas/fixtures cover source bindings, observation events, projections, receipts, migrations, and unknown fields.
- [ ] A real injectable clock supplies display timestamps and monotonic interval durations.
- [ ] Forward/backward seeks, playback-rate changes, replay, interruptions, route loss, preparation gaps, termination, and relaunch produce deterministic listening coverage.
- [ ] Open-without-reading, bounded dwell, rapid scrolling, navigation jumps, relaunch, and revision changes produce conservative reading coverage.
- [ ] Mixed reading/listening unions never exceed 100 percent and retain mode-specific intervals.
- [ ] A changed source revision cannot inherit coverage without an explicit compatible mapping.
- [ ] Duplicate/out-of-order events merge idempotently or fail explicitly.
- [ ] Receipt previews distinguish observed, self-attested, and unobserved evidence and never claim attention or comprehension.
- [ ] Local deletion removes the ledger and future exports without rewriting a package the user already shared.
- [ ] Contract validators, focused SessionKit tests, migration tests, and relevant app builds pass.
- [ ] The product owner human-validates the reading/listening disclosures and receipt preview before the flow is described as validated.

## Audit and falsification checks

Replay identical event fixtures through clean install, relaunch, and migration paths and require byte-stable normalized projections where ordering is semantically equivalent. Compare a linear listen, skip-to-end, repeated short loop, rapid scroll, long stationary viewport, mixed-mode coverage, and changed-edition import. Treat seek/scroll inflation, coverage over 100 percent, cross-edition leakage, commentary counted as source, or language implying verified attention as failure.

## Dependencies and related work

- #70 consumes optional participation receipts but does not define the observation ledger.
- #17 defines reviewed interjection packages.
- #27 defines cross-edition anchor behavior.
- #22 may later provide package signing; a digest alone is not identity or non-repudiation.

## Non-goals

- Proving attention, comprehension, authorship, or academic integrity.
- Tracking reading in arbitrary third-party apps or browsers.
- Requiring detailed telemetry sharing to listen, read, or create local interjections.
- Building instructor dashboards or a server relay in this issue.
```

---

## Create `#81`

**Status:** Created as [#81 — [Audit] Reconcile claimed interjection-sharing implementation with source](https://github.com/uncomposed/spoken-margins-native/issues/81) through
the GitHub connector on 2026-08-24.

### Title

```text
[Audit] Reconcile claimed interjection-sharing implementation with source
```

### Body

```markdown
## Problem

Comments added on 2026-08-22 to #17, #18, and #19 describe interjection sharing as implemented behind a gate, including a `.spokenmargins` package, `sharingExperienceEnabled`, imported layers, `conversationId`, and `docs/interjection-sharing-and-article-acquisition.md`.

A repository/default-branch audit on 2026-08-24 could not find those symbols, that document, the claimed imported-layer runtime, or a related branch. Until the implementation is located and reproduced, downstream classroom or asynchronous-conversation planning must treat those comments as unverified implementation claims rather than available infrastructure.

## Outcome

Resolve the discrepancy with one evidence-backed result:

1. locate the exact commit, branch, pull request, or recoverable artifact containing the implementation and reconcile it into the repository; or
2. correct the issue comments/status to say the work is design-approved or planned, not implemented.

## Evidence required if implementation exists

- canonical commit SHA and branch/PR ancestry;
- complete file inventory including the referenced design document;
- schema/version definitions for exported packages and imported layers;
- gate definition, default state, and route for enabling it;
- automated test/build evidence at that SHA;
- migration, privacy, tamper, and malformed-package behavior;
- explicit distinction between implemented, verified, and product-owner human-validated state.

## Required reconciliation if implementation does not exist

- Amend #17, #18, and #19 so their comments do not assert unavailable runtime behavior.
- Preserve useful design decisions as proposed contracts rather than deleting history.
- Make #17 the first implementation dependency for any package-based classroom pilot.
- Remove or repair any documentation, plan, or issue dependency that assumes imported layers already ship.

## Audit checklist

- [ ] Search all local and remote refs, pull requests, tags, stashes/artifacts available to the owner, and repository history for the claimed symbols and file.
- [ ] Confirm whether any located commit descends from or can apply cleanly to the current default branch.
- [ ] Run the contract validators, focused SessionKit tests, and relevant app build at the located/reconciled source.
- [ ] Exercise export/import with valid, malformed, unsupported-version, wrong-source, duplicate, and tampered fixtures.
- [ ] Record what is implemented, what is merely verified by automation, and what still requires product-owner validation.
- [ ] Update downstream dependencies in #70 and #82 to match the result.

## Audit and stopping rule

Search results or prose comments are not implementation evidence. Stop treating the sharing layer as implemented unless a buildable source revision, schema fixtures, and reproducible tests can be identified. If no artifact is found after all owner-accessible refs and histories are checked, close this audit by correcting the claims and reopening implementation planning under #17–#19.

## Non-goals

- Reimplementing sharing inside the audit issue.
- Publishing a server protocol or classroom backend.
- Calling the flow human-validated based on automated checks.

Related: #17, #18, #19, and #70.
```

---

## Create `#82`

**Status:** Created as [#82 — [Post-MVP] Validate transport-neutral classroom assignment and return packets](https://github.com/uncomposed/spoken-margins-native/issues/82) through
the GitHub connector on 2026-08-24.

### Title

```text
[Post-MVP] Validate transport-neutral classroom assignment and return packets
```

### Body

```markdown
## Outcome

Validate the smallest useful classroom workflow from #70 without first committing to accounts, a hosted roster, or a telemetry backend. An instructor creates an assignment manifest, students acquire the referenced source through ordinary Spoken Margins intake, work locally, preview a return packet, and explicitly share it back. The instructor imports one or more packets for source-aligned review.

This is a package-only product pilot and contract boundary, not the final classroom service.

## Actors and authority

- **Instructor/creator:** authors an assignment and one or more return destinations; may name co-instructors for display/review but package exchange alone does not grant server authority.
- **Participant/student:** imports the assignment, resolves the source, listens or reads, records interjections, reviews what will be returned, and explicitly exports it.
- **Reviewer:** imports returned packets and views each participant layer against the bound source.
- **Transport:** Files, share sheet, AirDrop, mail, learning-management upload, or another user-chosen carrier; transport is not identity, authorization, or durable delivery confirmation.

## Package boundaries

### Assignment package

- stable assignment ID, schema version, title, instructions, due date when supplied, and instructor display metadata;
- canonical public/source URL plus source identity/revision/digest expectations;
- acquisition guidance that routes through existing import flows;
- requested evidence policy, clearly distinguishing optional interjections from app-observed or self-attested participation;
- return destination hints without embedded credentials or executable routes.

The package must not redistribute copyrighted source content by default. Bundled content is permitted only when the exporting user has rights and the package contract explicitly supports it.

### Local work binding

- importing an assignment creates a durable binding between the assignment and a locally acquired item/source revision;
- assignment state must not overload or mutate the canonical `Session` playback model;
- mismatched, redirected, changed-edition, unavailable, or paywalled sources remain visible and recoverable rather than silently binding to the wrong item;
- ordinary unassigned library use remains unchanged.

### Return packet

- assignment and source binding;
- participant-chosen display identity appropriate to a package-only pilot;
- selected interjections with durable source anchors and required media assets;
- optional participation receipt from #80;
- package/schema versions, creation time, and integrity digest;
- no unrelated library history, raw event ledger, or unselected private interjections.

## Instructor review

- Import multiple participant packets without overwriting the instructor's own layer or another participant.
- Show source mismatch, unsupported version, missing media, duplicate packet, and integrity warnings before import.
- Provide per-participant and source-position views, with explicit observed/self-attested/unobserved evidence labels.
- Permit local export of a review summary while retaining links back to the underlying anchored interjections.
- Treat AI grouping/synthesis as later work under #26; the pilot must be useful without generated summaries.

## Acceptance criteria

- [ ] An instructor can create and preview an assignment package containing a source link and instructions without redistributing the source itself.
- [ ] A participant can import the assignment, acquire/bind the correct source through existing intake, and recover from unavailable or mismatched editions.
- [ ] Listening, in-app reading, external/self-attested reading, and no-evidence states remain distinct.
- [ ] A participant can preview, include/exclude optional interjections and evidence, cancel, and explicitly share a return packet.
- [ ] An instructor can import at least two participant packets for the same assignment and review their layers without collision.
- [ ] Wrong-source, malformed, unsupported-version, missing-asset, duplicate, oversized, and tampered fixtures fail or warn deterministically.
- [ ] Export/import is idempotent and does not replace the active playback session.
- [ ] Package exchange works through at least Files and the system share sheet without a Spoken Margins server.
- [ ] Schemas, validators, fixture families, runtime paths, and focused tests land together.
- [ ] The product owner human-validates the end-to-end instructor and participant flows before the pilot is described as validated.

## Dependencies and related work

- Epic: #70.
- Blocked by #81 and the verified implementation state of #17.
- #18 supplies the imported-participant-layer model; #19 extends it into recursive asynchronous conversation.
- #14 defines source/content rights boundaries; #27 defines cross-edition anchors.
- Optional receipts consume #80 but do not block validating assignment and interjection exchange without telemetry.
- #22 may add signing later; a package digest does not prove participant identity.
- #26 and #68 cover synthesis and provenance-aware presentation after the one-way exchange works.

## Non-goals

- Hosted classrooms, roster provisioning, accounts, roles, invitations, or an instructor dashboard.
- Guaranteed delivery, revocation, remote deletion, or live synchronization.
- Proving that a student paid attention, understood the source, or authored an interjection.
- Recursive replies, notifications, or AI synthesis in the first package pilot.

## Audit and stopping rule

Run the same assignment across link-only public content, a changed edition, an unavailable/paywalled source, mixed read/listen evidence, two participant returns, duplicate import, and tampered packages. Compare the package-only workflow with two alternatives: ordinary manual sharing and a minimal hosted relay. Do not begin roster/backend work unless the pilot shows repeat use, source-resolution success, and materially better review than manual exchange. Stop calling the pilot privacy-preserving if participants cannot preview and minimize the return packet.
```

---

## Edit existing issue #64

**Status:** Applied all seven staged edit groups through the GitHub connector on
2026-08-24; resulting issue update timestamp `2026-08-25T04:04:06Z`.

Issue: [#64 — Durable prepared native-text audio and Lock Screen scrubbing](https://github.com/uncomposed/spoken-margins-native/issues/64)

Apply these exact edits while preserving the rest of the issue body.

### 1. Replace the storage-cap bullet

Replace:

```markdown
- Count partial chunks and finished packages against the existing user-selected rendered-speech storage cap. Lowering the cap evicts through the defined cache policy without making the source item unplayable.
```

With:

```markdown
- Count every committed chunk, completed artifact, and retained Watch derivative through the unified offline-storage ledger in #72. Until that ledger exists, automatic preparation must use a conservative temporary quota that accounts for completed packages as well as chunks; it must not assume podcast download settings bound prepared audio. Lowering a limit must not make the source item unplayable.
```

### 2. Insert a scheduling and consumer boundary

Insert this section immediately before `### Thermal scheduling acceptance checks`:

```markdown
### Scheduling and consumer boundary

This issue owns the durable render representation, resumability, foreground/on-demand preparation behavior, and promotion into canonical prepared playback.

- #74 owns opt-in `BGProcessingTask` scheduling while connected to power, durable preparation jobs, expiration handling, and best-effort overnight execution.
- #73 owns the eligible-chunk horizon, battery/charging policy, and chapter-jump reprioritization in foreground and background execution.
- #75 consumes the same completed representation and source-to-media mapping; it must not create a second Watch-specific TTS renderer.
- #72 owns total byte accounting, reservations, protection reasons, and cross-category eviction.

Completion of this issue alone must not be read as permission to sweep the library in the background, exceed a truthful global storage limit, or transfer packages to Watch.
```

### 3. Replace the storage acceptance criterion

Replace:

```markdown
- [ ] Storage limits, cache eviction, deletion, corrupt-file recovery, and low-space failure are covered.
```

With:

```markdown
- [ ] Every manifest-owned chunk and complete artifact has stable ownership/byte metadata consumable by #72; eviction, deletion, corrupt-file recovery, and low-space failure leave the source item recoverable.
```

### 4. Replace the final related line

Replace:

```markdown
Related: #62. Existing prepared-media and rendered-chunk infrastructure should be reused rather than introducing a new source category.
```

With:

```markdown
Related: #61, #62, #72, #73, #74, and #75. Existing prepared-media and rendered-chunk infrastructure should be reused rather than introducing a new source category.
```

### 5. Replace the incomplete-playback prioritization bullet

Replace:

```markdown
Prioritize enough initial audio for prompt playback, then continue serially with bounded resource use.
```

With:

```markdown
Prioritize enough initial audio for prompt playback. Further serial preparation follows #73: normally current plus bounded next-chapter demand on battery, with longer opportunistic preparation only while device conditions permit.
```

### 6. Rename and reframe the thermal scheduling section

Rename `### Thermal-safe scheduling policy` to `### Durable-render execution constraints`, then replace its opening sentence.

Replace:

```markdown
The renderer should keep Supertonic warm and continue through the eligible item at the fastest thermally safe rate, rather than stopping after one prefetched chunk.
```

With:

```markdown
This issue defines how eligible chunks are rendered and committed durably. It does not require unconditional full-item rendering. Eligibility, preparation horizon, battery/charging behavior, Low Power Mode, and jump reprioritization belong to #73.
```

Reconcile the remaining bullets without weakening these constraints:

- At most one resource-intensive item render job runs at a time.
- The runtime may remain warm only while another currently eligible chunk is ready to start.
- Thermal checks, Stop, atomic commits, manifest-derived progress, completion-skip behavior, explicit Prepare Audio, storage caps, cancellation, and model release remain required.
- “Active/newly imported eligible item” does not imply “render the entire item on battery”; #73 defines the eligible horizon.

### 7. Add demand-horizon acceptance criteria

Add these checklist items to `## Acceptance criteria`:

```markdown
- [ ] Durable rendering accepts a changing eligible-chunk horizon without corrupting, deleting, or rerendering compatible committed chunks.
- [ ] Completion of a durable whole-item representation is optional progress, not a prerequisite for bounded long-form playback.
- [ ] Tests prove execution obeys the scheduling decision supplied by #73 rather than independently scheduling every remaining chunk.
```

---

## Edit existing issue #34

**Status:** Applied through the GitHub connector on 2026-08-24; resulting issue
update timestamp `2026-08-25T04:03:13Z`.

Issue: [#34 — Remove Kokoro/MLX and evaluate Supertonic as the local TTS path](https://github.com/uncomposed/spoken-margins-native/issues/34)

The current issue is stale because Supertonic is already the active local neural TTS
path. Replace its title and body with the following.

### Replacement title

```text
[Post-MVP] Remove residual Kokoro/MLX code and formalize Supertonic render identity
```

### Replacement body

```markdown
## Outcome

Remove the residual Kokoro/MLX implementation surface and formalize Supertonic as the supported local neural TTS runtime, including a stable render identity that durable prepared audio can use for invalidation and recovery.

This supersedes the original framing of Supertonic as a candidate to evaluate: the released beta already uses Supertonic. The remaining work is cleanup, migration safety, build simplification, and explicit runtime/version contracts.

## Current repository state

- Supertonic is the active local neural rendering path.
- Legacy Kokoro/MLX source, optional build configuration, documentation, tests, assets, settings, or migration values may still remain.
- #64 needs an exact engine/model/voice signature so prepared audio is reused when compatible and invalidated when synthesis output could change.

## Required work

### Residual inventory and removal

- Inventory Kokoro/MLX references across app and package source, dependencies, model assets, build settings, schemes, generated-project configuration, documentation, fixtures, tests, persisted settings, and diagnostics.
- Remove runtime adapters, models, dependencies, feature flags, dead settings, and obsolete build paths that are not deliberately retained for migration.
- Reassess the optional Kokoro/MLX device scheme and Metal-toolchain guidance; delete or rename obsolete configuration without breaking the active Supertonic device build.
- Historical documents may retain clearly labeled historical evidence, but must not imply Kokoro is an available product runtime.

### Persisted-value migration

- Identify persisted engine/voice/settings values that can refer to Kokoro/MLX.
- Map them deterministically to a supported Supertonic or installed-system-voice state, or surface an explicit recoverable selection requirement.
- Migration must be idempotent and must not silently change an active session's voice mid-playback.

### Supertonic render identity

Define one canonical signature containing every input that can change rendered samples or source-to-media mapping, including:

- engine identifier;
- model/version or bundled-asset revision;
- voice identifier and voice-asset revision;
- synthesis parameters that affect output;
- text normalization/chunking version where it affects samples or mapping;
- prepared-manifest/schema version.

Playback rate is a playback concern and must not invalidate rendered audio. The signature format must be deterministic, persistable, comparable across relaunch, and safe to include in diagnostics without private source text.

### Packaging, licensing, and diagnostics

- Document model/voice asset origin, license obligations, bundled size, supported devices/OS versions, and update strategy.
- Fail explicitly when required assets are missing, corrupt, or incompatible; retain the installed-system-voice fallback without claiming neural output.
- Diagnostics should identify the engine/model/voice revisions and fallback reason without logging source content.

## Acceptance criteria

- [ ] No Kokoro/MLX runtime code, dependencies, bundled model assets, feature flags, or user-facing settings remain unless an explicit migration exception is documented.
- [ ] Persisted Kokoro/MLX values migrate idempotently to a supported, visible state without changing voice mid-session.
- [ ] The active Supertonic device build has one documented scheme/configuration and no obsolete Kokoro-specific prerequisites.
- [ ] One canonical render-signature implementation is used by Supertonic output and the durable manifest in #64.
- [ ] Changing any sample-affecting engine/model/voice/parameter revision invalidates incompatible prepared output.
- [ ] Playback-rate changes do not invalidate or rerender prepared audio.
- [ ] Missing/corrupt assets produce an explicit recoverable state and supported fallback.
- [ ] Licensing, asset provenance, bundled size, device/OS support, and update policy are documented.
- [ ] Contract validators, SessionKit tests, relevant migration tests, and iOS simulator/device builds pass.
- [ ] The product owner human-validates voice selection, migrated settings, Supertonic playback, and fallback behavior on supported devices.

## Audit and falsification checks

- Run a repository-wide residual-reference inventory and classify every surviving Kokoro/MLX match as removed, migration-only, or clearly historical.
- Generate signatures while changing one input at a time; require changes only for output-affecting inputs and stability across relaunch/builds with identical assets.
- Launch from representative persisted Kokoro settings repeatedly and require the same migrated result.
- Remove/corrupt representative model and voice assets and verify explicit fallback/recovery rather than a crash or falsely identified neural session.
- Treat two signature implementations, unversioned model replacement, silent voice change, or obsolete runtime code reachable from production as a failure.

## Dependencies and related work

- #64 consumes the canonical Supertonic render identity for durable prepared audio.
- #74 must use the same identity in foreground and background jobs.

## Non-goals

- Replacing the canonical playback/session spine.
- Removing installed-system voices as a supported fallback.
- Re-evaluating whether Supertonic is the chosen beta runtime without new contrary product direction.
```

---

## Edit existing issue #61

**Status:** Applied through the GitHub connector on 2026-08-24; resulting issue
update timestamp `2026-08-25T04:03:14Z`.

Issue: [#61 — Support DRM-free EPUBs with canonical chapter playback and interjections](https://github.com/uncomposed/spoken-margins-native/issues/61)

The title and body below were re-fetched unchanged on 2026-08-24. Preserve the
existing title, body, and metadata, then append the following sections if equivalent
language is not already present.

### Sections to append

```markdown
## Rendering and preparation policy

Keep EPUB ingestion, canonical structure, and audio preparation as separate layers:

- Parse and persist the package, spine, navigation hierarchy, stable source locations, and normalized speakable text for the whole EPUB at import time.
- Do not require hours of synthesized audio before the book becomes playable.
- Initial playback should prepare the current canonical chapter and a bounded look-ahead that normally reaches through the next chapter.
- Chapter jumps reprioritize the selected chapter immediately and discard only obsolete uncommitted work; valid committed audio remains reusable.
- When external power, Low Power Mode, thermal state, and background execution conditions permit, preparation may extend beyond the normal look-ahead toward the remainder of the book.
- On battery or under constrained power/thermal conditions, return to the bounded demand window rather than eagerly rendering the entire EPUB.
- Scheduling policy belongs to #73; EPUB structure and interjection correctness must not depend on full-book preparation completing.

## Additional acceptance criteria

- [ ] A long EPUB becomes playable after bounded initial preparation rather than waiting for full-book synthesis.
- [ ] On-battery preparation does not run unboundedly through the entire book by default.
- [ ] The current and next chapter can be prepared without losing canonical chapter/source identities.
- [ ] Jumping to an unprepared chapter reprioritizes that chapter and resumes at the requested logical EPUB position once ready.
- [ ] Plugging in can extend preparation when Low Power Mode and thermal state allow, without changing playback position or duplicating committed audio.
- [ ] Relaunch reconstructs preparation state from durable manifests and never confuses prepared-media time with canonical EPUB source location.

Related: #64 and #73.
```

---

## Edit existing issue #69

Issue: [#69 — Onboarding Hotlinks](https://github.com/uncomposed/spoken-margins-native/issues/69)

**Status:** Applied through the GitHub connector on 2026-08-24. The resulting
issue update timestamp is `2026-08-25T03:54:08Z`; do not reapply this staged
replacement unless the live issue is first re-fetched and found to have diverged.

The current title/body and `enhancement` label were re-fetched unchanged on
2026-08-24. Replace the title and body below while preserving the label and other
metadata.

### Replacement title

```text
Onboarding: remotely configurable guided podcast and import hotlinks
```

### Replacement body

```markdown
## Outcome

Give new users two starter items:

1. the existing native-text “Welcome to Spoken Margins” item; and
2. a podcast-format guided tour that explains and links users into the ways they can add their own content.

The guided podcast must be product-owner configurable after release so its audio, metadata, and instructions can be updated without shipping a new App Store build.

## Why

The current onboarding can ask a user to add a podcast, but it does not provide an audio-first walkthrough of the available import paths. If the app’s workflows change, an onboarding tutorial bundled entirely in the binary becomes stale until the next app release.

## Experience requirements

- A fresh install/library seed contains a second starter item whose source type and playback behavior are genuinely podcast/audio, not native text rendered as speech.
- The item is clearly identified as a Spoken Margins guided tour and can be played with the normal podcast listening experience.
- The tour walks through all currently supported content-ingestion paths:
  - import/upload a PDF;
  - paste native text;
  - add a webpage through the supported browser integration/share flow;
  - paste a podcast or episode link;
  - share a podcast or episode into Spoken Margins through the share sheet.
- Actionable prompts or “hotlinks” in the tour/onboarding open the relevant in-app destination. For example, tapping the prompt to add a podcast opens the same add-item sheet available from the library “plus” button.
- Links use existing routes/actions rather than creating onboarding-only versions of import flows.
- VoiceOver labels explain the destination and do not rely on the question-mark icon alone.

## Content and delivery contract

Keep these layers separate:

- **Bundled seed definition:** establishes that the starter item exists on first launch and provides a safe fallback.
- **Remote product-owner configuration:** controls the current tutorial audio/source URL and user-facing metadata (at minimum title, description, artwork if supported, and content version).
- **App routing:** maps tutorial actions to supported import destinations.
- **User library state:** tracks whether the starter item was created, dismissed/deleted, played, and how updates affect progress.

The remote mechanism may be a small versioned manifest or an equivalent service-backed configuration, but it must:

- allow the product owner to publish a revised tutorial without an app release;
- use authenticated HTTPS and validate the response before applying it;
- define stable item identity separately from content version so refreshes do not create duplicates;
- define whether an update preserves or resets playback progress, and surface that behavior consistently;
- respect a user deletion/dismissal decision rather than silently re-adding the item on every launch;
- retain the last-known-good configuration or bundled fallback when the network or remote configuration is unavailable;
- document the product-owner publishing/rollback workflow.

Changing the remote tutorial may update onboarding content and metadata, but must not remotely introduce new executable routes or bypass the app’s supported import and security boundaries.

## Original observation

During onboarding, the question-mark prompt asks the user to add a podcast. Make that prompt tappable so it opens the same “plus” add-item sheet.

## Acceptance criteria

- [ ] A clean install shows exactly the intended two starter items: the existing native-text welcome item and one guided podcast item.
- [ ] The guided item plays through the normal podcast/audio path.
- [ ] The tutorial accurately covers PDF, pasted text, browser/web sharing, pasted podcast links, and podcast share-sheet ingestion.
- [ ] Each actionable onboarding prompt opens the correct existing import UI, including the add-item sheet from the podcast prompt.
- [ ] Publishing a new tutorial content version updates the guided item on a test install without rebuilding or reinstalling the app.
- [ ] Refreshing the same version does not duplicate the starter item.
- [ ] Offline, malformed-response, removed-audio, and rollback cases use a defined last-known-good or bundled fallback.
- [ ] Deleting/dismissing the starter podcast is respected across launches and remote refreshes.
- [ ] Playback-progress behavior across a tutorial update is specified and verified.
- [ ] Routes and prompts are accessible with VoiceOver.
- [ ] The product-owner update and rollback steps are documented and exercised against a non-production test configuration.

## Verification evidence

- clean-install seed test showing the two distinct source types;
- route-level tests for every hotlink/import destination;
- configuration-version tests for first fetch, unchanged refresh, update, rollback, malformed data, and offline launch;
- persistence tests for duplicate prevention, deletion/dismissal, and playback progress;
- developer evidence that an updated remote tutorial appears without a new binary;
- product-owner validation of the actual onboarding and publishing workflow before closure.

## Stopping rules

Do not close this issue if the tutorial is still binary-only, if remote refresh can duplicate or resurrect a deleted starter item, or if automated checks are the only evidence for the user-facing onboarding flow.
```

---

## Edit existing issue #70

**Status:** Applied all nine staged edit groups through the GitHub connector on
2026-08-24; resulting issue update timestamp `2026-08-25T04:03:30Z`.

Issue: [#70 — Classroom assignments, interjection returns, and verifiable listening receipts](https://github.com/uncomposed/spoken-margins-native/issues/70)

The title and body below were re-fetched unchanged on 2026-08-24. Apply these exact
edits while preserving the remainder of the issue body and metadata.

### 1. Replace the title

Replace:

```text
[Post-MVP] Classroom assignments, interjection returns, and verifiable listening receipts
```

With:

```text
[Post-MVP] Classroom assignments, interjection returns, and app-observed participation receipts
```

### 2. Replace the two Outcome paragraphs

Replace:

```markdown
Add a **Classroom** experience in which one or more teachers can distribute a listening assignment to one or more students, students can interject while listening, and teachers can receive a reviewable return packet containing the student's selected interjections and their source anchors.

An optional higher-trust mode can also return a **verifiable listening-participation receipt**: an append-only account of supported playback and interjection events, with policy-selected user-presence authorization at each interjection. This is evidence about app-observed participation and payload integrity—not proof of attention, comprehension, legal identity, or academic honesty.
```

With:

```markdown
Add a **Classroom** experience in which one or more teachers can distribute a source assignment to one or more students. Students may listen in Spoken Margins, read through an instrumented Spoken Margins reading surface, or use a clearly labeled external/self-attested route; they can interject while working and return a reviewable packet containing their selected interjections and source anchors.

An optional higher-trust mode can also return an **app-observed participation receipt** derived from #80: a conservative account of supported playback, in-app presentation, and interjection events, with policy-selected user-presence authorization at each interjection. This is evidence about app-observed presentation and payload integrity—not proof of attention, comprehension, legal identity, authorship, or academic honesty.
```

### 3. Replace Core workflow step 3

Replace:

```markdown
3. A student accepts or declines the assignment, acquires the source through a lawful supported path, and listens in Spoken Margins.
```

With:

```markdown
3. A student accepts or declines the assignment, acquires the source through a lawful supported path, and chooses to listen in Spoken Margins, read through its instrumented reading surface, or declare an external/self-attested route. The selected mode must not change the source/edition binding.
```

### 4. Replace the Participation evidence subsection

Replace:

```markdown
### Participation evidence

- source-relative playback events that the app actually observed
- session boundaries, seek/pause/rate changes, interruptions, and declared offline gaps
- interjection capture time plus source position/anchor
- assignment/source/revision binding and canonical event ordering
- event or packet digests, signing metadata, and verifier result
- explicit states for observed, inferred, unavailable, interrupted, unsigned, invalid, and unsupported evidence
```

With:

```markdown
### Participation evidence

- versioned source-relative listening and in-app reading observations supplied by #80
- listening boundaries including seek/pause/rate changes, replay, interruptions, and declared offline gaps
- conservative in-app reading presentation intervals; open, navigation, or rapid scroll alone does not establish coverage
- explicit external/self-attested and unobserved states rather than fabricated reading telemetry
- interjection capture time plus source position/anchor
- assignment/source/revision binding, per-mode canonical intervals, and deterministic union coverage
- event or packet digests, signing metadata, and verifier result
- explicit states for observed, self-attested, unavailable, interrupted, unsigned, invalid, and unsupported evidence
```

### 5. Replace the opening Trust model paragraph

Replace:

```markdown
The receipt can make tampering and silent bulk submission harder and can show that a supported client observed a sequence of playback/interjection events. It cannot prove that the student:
```

With:

```markdown
The receipt can make tampering and silent bulk submission harder and can show that a supported client recorded a sequence of source-presentation/interjection events under a declared algorithm. Reading evidence means only that an in-app surface presented bounded source ranges; it is not eye tracking. The receipt cannot prove that the student:
```

### 6. Replace the Phase 1 paragraph

Replace:

```markdown
Extend the portable package boundary from #17 with assignment, recipient, submission, and attempt lineage. Validate distribution and return through a bounded transport such as Files/share sheet or a fake service before building a classroom backend.
```

With:

```markdown
Implement #82 by extending the verified portable-package boundary from #17 with assignment, source binding, recipient, submission, and attempt lineage. Validate link-based source acquisition and explicit return through Files/share sheet before building a classroom backend. Do not assume #17 is implemented until #81 resolves the current source/evidence discrepancy.
```

### 7. Replace the Phase 3 paragraph

Replace:

```markdown
Build on the signing spike in #22. Compare packet-only signing with per-interjection authorization and append-only signed journey events. Select the least intrusive mechanism that meets the declared classroom policy.
```

With:

```markdown
Build on the conservative observation ledger in #80 and the signing spike in #22. Compare an unsigned/minimized receipt, packet-only signing, per-interjection authorization, and append-only signed journey events. Select the least intrusive mechanism that meets the declared classroom policy; a digest or device signature alone must not be presented as student identity.
```

### 8. Replace two acceptance criteria

Replace:

```markdown
- [ ] A student can accept the assignment, listen, create multiple anchored interjections, preview the outbound data, and submit a packet without mutating the local session.
```

With:

```markdown
- [ ] A student can accept the assignment, listen or read through a supported evidence mode, create multiple anchored interjections, preview the outbound data, and submit a packet without mutating the local session.
```

Replace:

```markdown
- [ ] Fixtures cover seeking, replay, playback-rate changes, pause/resume, interruptions, backgrounding, offline gaps, source changes, late submission, resubmission, and assignment revision during work.
```

With:

```markdown
- [ ] Fixtures cover seeking, replay, playback-rate changes, pause/resume, interruptions, backgrounding, offline gaps, bounded in-app reading dwell, rapid scrolling, external/self-attested reading, mixed modes, source changes, late submission, resubmission, and assignment revision during work.
```

### 9. Replace Dependencies and sequencing

Replace:

```markdown
## Dependencies and sequencing

- #17 for reviewed, portable interjection packages.
- #22 for device-key signing and the limits of biometric user-presence authorization.
- #14 for source excerpts, attribution, sharing, and retention policy.
- #19 may later support teacher feedback and layered classroom discussion, but should not block one-way assignment and return.
```

With:

```markdown
## Dependencies and sequencing

- #81 must reconcile whether the #17–#19 sharing layer actually exists in source.
- #82 validates assignment/return value before accounts or a hosted classroom service.
- #17 owns reviewed portable interjection packages; #18 owns imported participant layers.
- #80 owns listening/in-app-reading observation semantics and optional receipts.
- #22 owns device-key signing and the limits of biometric user-presence authorization.
- #14 owns source excerpts, attribution, sharing, and retention policy; #27 owns cross-edition anchor behavior.
- #19 may later support teacher feedback and layered classroom discussion; #26 may synthesize cross-participant patterns. Neither should block one-way assignment and return.
```

---

## Publication verification checklist

- [x] Search open and closed issues for each proposed title immediately before creation; do not create a duplicate if a materially equivalent issue appeared after this file was staged.
- [x] Re-fetch #34, #61, #64, #69, and #70; if any exact-match precondition changed, reconcile the staged edit instead of overwriting newer work.
- [x] Create all eleven issues in the declared order and record their canonical numbers/URLs.
- [x] Replace every `{{...}}` placeholder in the GitHub bodies with a `#123` issue reference.
- [x] Apply all seven numbered patches to #64 without removing unrelated issue history or acceptance criteria.
- [x] Replace #34's stale title and body while leaving the issue open.
- [x] Append the staged policy/acceptance sections to #61 without replacing its EPUB structure requirements.
- [x] Replace #69's title/body while preserving its `enhancement` label and metadata.
- [x] Apply all nine numbered patches to #70 without weakening its privacy, authorization, alternatives, or stopping-rule language.
- [x] Re-read all sixteen affected issues from GitHub and verify title, state, complete Markdown body, links, and dependency direction.
- [x] Confirm #64 owns the durable prepared representation, #73 owns eligible horizon, #74 owns optional background execution, #72 owns byte policy, and #75 consumes the prepared representation.
- [x] Confirm #76 owns explicit subscriptions/inbox and #77 owns discovery, engagement policy, and prompting.
- [x] Confirm #78 remains `implemented`, not `human_validated`, until the product owner accepts the representative PDF flow.
- [x] Confirm #81 is resolved with source evidence or corrected issue claims before #82 treats #17 as implemented.
- [x] Confirm #80 and #70 say app-observed presentation/participation rather than proof of attention, comprehension, identity, authorship, or academic integrity.
- [x] Confirm the classroom pilot is link/package based, excludes a hosted roster/backend, and allows participants to preview and minimize returned data.
- [x] Confirm none of the issues equates storage allowance with consent to follow, import, download, or prepare content.
- [x] Confirm no issue claims iOS can render while powered off or guarantees an overnight `BGTaskScheduler` launch.
- [x] Confirm every implementation issue distinguishes automated verification from product-owner human validation.
- [x] Add repository labels only after confirming the labels exist; do not fail issue creation because of an assumed label name.

## Staging completion rule

The eleven new issues and five edits were published and verified against GitHub.
Retain this file as the publication audit trail unless the product owner chooses to
remove it later.
