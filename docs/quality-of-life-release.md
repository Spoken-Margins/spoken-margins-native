# Non-Watch Quality-of-Life Release

## Scope and Architecture

Build 22 on `codex/quality-of-life-next` implements issues #34, #64, #61, #69, #72–#74, #76–#77, #79, #86, and #87. Issue #75 and all new Watch playback, transfer, render, connectivity, and synchronization work remain excluded.

The release is deliberately layered:

1. Canonical source records preserve authored EPUB/PDF/text/article structure and stable source locators.
2. Prepared-audio records preserve render identity, committed chunks, durable work, and complete AAC/M4A artifacts.
3. The unified offline ledger owns capacity, reservations, protections, adoption, and deterministic eviction.
4. Feed/source records own discovery evidence, explicit subscriptions, inbox state, refresh state, and prompt decisions.
5. Presentation records own library query, sleep timer, and a closed onboarding-route vocabulary.

These layers are persisted through focused repository protocols implemented by both SQLite and the in-memory test store. SQLite schema version 5 adopts older stores idempotently.

## Product Behavior

- Supertonic prepared chunks survive relaunch, are checksum-validated before reuse, and begin playback only after two committed chunks. Partial media never advertises a fabricated complete duration. A complete AAC/M4A artifact is attached through the canonical media route only at a safe playback boundary.
- Every eligible native-text import immediately enters a bounded two-chunk opening-audio job, independent of the opt-in full-item charging policy. The Library replaces that item's play affordance with a stable, accessible progress indicator until the opening horizon is committed; one-chunk sources become ready after their only chunk. Compatible chunks are reused at playback, while failure or resource pressure restores a supported live-voice path instead of trapping the listener on a loading screen. Supertonic inference remains serial on its dedicated render queue, and render-signature hashing plus long-text chunk planning run off the main actor so Library scrolling and animations do not share that work.
- Render identity includes the Supertonic model revision, model assets, voice style, synthesis parameters, normalization/chunking versions, and manifest version. Playback speed is intentionally absent. Legacy Kokoro selections migrate to James without changing an active session.
- Offline Storage defaults to a decimal 5 GB with 1/2/5/10/20 GB choices. Every implemented writer reserves capacity. Lowering the budget immediately evicts reproducible assets, while imported audiobooks, recordings, interjections, Recently Deleted items, active work, and dormant Watch transfers remain protected and any irreducible overage is shown explicitly.
- EPUB import uses ZIPFoundation 0.9.20 and rejects protected/encrypted, malformed, traversing, excessive, or empty packages before publication. Authored nested navigation remains canonical; a derived leaf-chapter Listening Map exposes that structure in item detail without replacing the authored package model.
- Audiobook import accepts MP3, M4A, M4B, and audio-bearing MP4, validates AVFoundation playability/duration/protection, fingerprints duplicates, preserves embedded chapters, and publishes item/media/storage ownership atomically.
- Charging preparation is opt-in (`Off` by default; `While Charging` only), uses one registered `BGProcessingTaskRequest`, disables networking, reconstructs durable jobs at launch and foreground/background transitions, and commits at most the next safe chunk before reevaluating power, thermal, identity, deletion, and space. A granted processing window continues through serial passes while each pass makes durable progress; a pass that cannot advance stops the window and leaves work eligible for a later request. The Library exposes the ordered durable queue, committed-chunk progress, user reordering within a priority tier, the active-playback pin, and the ten most recently verified artifacts. An explicit per-item offline request overrides the automatic 90%-complete cutoff as a distinct higher-priority job and does not silently enable the global charging policy. The first foreground activation after a new verified artifact presents its item title in a transient completion banner; this is completion evidence, not a promise that iOS will run the queue overnight.
- Guided onboarding accepts only HTTPS data from the production host, enforces manifest/audio bounds and checksums, exposes only compiled route IDs, caches last-known-good content, and retains a bundled playable text fallback. Starting the tour always opens the guided-onboarding item and seeds its chapter timeline when needed.
- Quick Add combines bounded RSS, Atom, and JSON Feed entries with eligible Markdown, plain-text, and text-based PDF files from the user-selected Quick Folder. The Sources header accepts an RSS/feed URL directly and keeps general item import in the Library intake flow. Feed responses allow up to 16 MiB; the parser inspects at most 200 entries, while Quick Add retains only the newest 25 actionable suggestions per followed feed. Podcast entries preserve their playable audio enclosure separately from the canonical episode page, including lazy recovery for entries persisted before that field existed. Older unseen or seen suggestions are pruned, while imported and dismissed suppression tombstones remain so completed or rejected episodes cannot reappear. XML-depth limits, disabled external entities, HTTPS-only redirects, and request timeouts remain in force. Quick Add shows three candidates until expanded, limits candidate titles to three lines, excludes imported episodes by canonical URL or source/title identity, and remembers dismissed file revisions. Each row consolidates intake method, source, and relative time into one provenance line and shows a directional swipe affordance. Tapping a title imports and opens; swiping right imports in place; swiping left dismisses. Feed refresh and foreground activation rescan both sources. Followed sources retain conditional refresh, HTML alternate-feed discovery, four same-origin heuristics, a chooser for multiple feeds, mute/unfollow semantics, and durable suggestion suppression; following or selecting a folder never imports, downloads, or prepares entries by itself.
- Article inbox imports use an app-owned nonpersistent WebKit data store and the pinned bundled Defuddle capture script. Remote scripts and subresources are blocked.
- Library search is metadata-only and case/diacritic insensitive. Typed content/listening/offline filters and deterministic sort choices persist; the query does not. The controls expose their active filter and sort labels at a stable intrinsic width, legacy items use storage recency when an import timestamp is absent, and new imports always receive a creation timestamp. Compact rows keep title and combined source/state metadata in a dense two-line stack; their filled play symbol denotes verified offline audio rather than merely an existing continuation session. Continue Listening excludes items at 99% or higher without rewriting persisted progress. A leading full swipe persists completion through the existing session model. Trailing actions prioritize offline preparation or move the item to recoverable Recently Deleted; completion does not rewrite an earlier listening position as “incomplete.” Now Playing keeps the item title primary and resolves the current authored chapter—or a private Listening Map scene when no publisher chapter exists—as the subtitle even while a newly attached map is reconciling its playback snapshot.
- Sleep timers support 15/30/45/60 minutes and End of Chapter, display a countdown, extend/cancel, use wall-clock deadlines, remain armed through manual pause/backgrounding, defer expiry through recording, and cancel on item/session replacement or process termination. The Settings playback-control style chooses labeled or compact actions; compact mode keeps the current playback speed visible as text while other optional labels become icons. The listening screen does not spend control space on that preference. Playback speed cycles by tapping through 0.5x, 0.75x, 1x, 1.25x, 1.5x, 1.75x, and 2x; 0.25x is not offered.

## Audit and Falsification

The release must stop if any of these checks fail:

- a partial manifest exposes complete duration/scrubbing;
- a writer can commit more bytes than it reserved;
- valid committed chunks are rerendered after reconstruction;
- source locator/media time mappings are non-monotonic;
- EPUB nested navigation is flattened or unsafe content publishes partially;
- an imported or previously listened-to episode reappears in Quick Add;
- Recently Added places a newly imported item below older content;
- an evictable asset remains above a lowered storage budget without an explicit residual-overage explanation;
- foreground/background preparation differs for the same render signature;
- the visible queue order differs from the next-job selector, an active playback job is displaced by opportunistic work, or a completed artifact is announced before its verified manifest is durable;
- a follow action imports or downloads content without another explicit user action;
- remote onboarding introduces a route outside `OnboardingRoute`;
- any Watch runtime file enters the release diff.

Automated evidence is `verified`, never `human_validated`. Physical-device playback, lock-screen timing, background scheduling, picker/security-scope behavior, and the full product flow remain product-owner validation.

## Residual Kokoro/MLX Classification

Repository scans after implementation must produce no matches in app/package runtime source or generated project configuration. Remaining matches are allowed only in:

- `docs/staged-github-issues.md`: historical issue specification;
- Gate 1 and Gate 4 closeout/inventory documents: explicitly labeled historical evidence;
- `docs/archive/release-lanes.md` and this document: removal scope and audit result;
- `README.md` and current verification guidance: explicit statements that the runtime is retired.

No legacy model assets, package dependency, compilation flag, scheme, setting, test, or selectable voice remains.

Follow suggestions use final response URLs when feeds omit self links, show one candidate per source identity/normalized feed URL, and recheck current subscriptions after discovery. Items with an already-followed canonical source suppress the prompt; accepting a suggestion persists that source on the item. Distinct feed URLs are not merged by display title.
