# Build 22 Private-Experience Overhaul Handoff

Status: `implemented` and locally `verified`; not `human_validated`. Product-owner use on physical devices is still required before this gate can be accepted.

## Candidate

- Version/build: Spoken Margins 0.1 (22)
- Branch: `codex/experience-overhaul`
- Implementation SHA: `93c9ced93acec8d7a2f18491010bdf6b3a3236d2`
- Governance SHA: `aec0928`
- Based on and merges only into: `codex/quality-of-life-next`
- Supported deployment: iPhone and iPad on iOS/iPadOS 18.0 or later
- Automated layout coverage: iPhone 16 Pro and iPad Pro 11-inch (M4), iOS/iPadOS 18.6
- Final app-unit coverage: iPhone 16e, iOS 18.6
- Physical-device validation: pending

## In scope

- Adaptive Library, Sources, and Margins roots with persistent playback context
- Continue-card priority and list deduplication; metadata-only search, filters, and stable sorting
- Typed intake for link/podcast, pasted text, document/book, audiobook, and Quick Folder
- Explicit follow, import, download, and preparation boundaries
- Factual item detail with nested canonical navigation and preparation/download state
- Focused Now Playing, separate mini-player open and play/pause actions, truthful partial-audio progress, speed, sleep, offline state, and Interject
- Explicit Timeline with source, My Margin, user-turn, and assistant-response provenance
- Exclusive recording presentation and model guards against navigation or session replacement
- Local Margins aggregation, Needs attention, retry, recording playback, copy, detail, and Timeline access
- App-facing offline-storage ledger with protected/reproducible/reserved/category accounting and safe-clear confirmation
- Two starter choices, Skip, replay, deletion tombstones, and seeded-item ownership classification
- Warm native semantic styling with light/dark, accessibility contrast, Dynamic Type, Reduce Motion, VoiceOver labels, and 44-point targets

## Out of scope

- Sharing package creation, imported people, recipient preview, replies, and issue #68's broader sharing acceptance criteria
- Watch implementation, Watch builds, and dormant Watch package behavior
- Scenes, Skim, issue #88-#90 commands, disabled future controls, or new SessionKit command/schema/snapshot fields
- Publisher artwork, profiles/accounts, analytics, remote execution, deployment, and App Store/TestFlight submission
- Product-owner acceptance

## Architecture and boundary audit

- New navigation, Margin, Timeline provenance, storage, and recording types are app-presentation models only.
- `Gate1AppModel` and the existing SessionKit runtime were extended incrementally; SessionKit packages, commands, snapshots, schemas, and fixtures are unchanged.
- The final diff contains no Watch, sharing, SessionKit, contract-schema, or generated-command changes.
- Trust fixes from issues #83-#85 are preserved: canonical playback position, drag ownership, partial-audio honesty, native/system playback continuity, and recording escape prevention.
- Issue #68 is used only for local provenance distinctions here; imported-person behavior remains in the sharing lane.
- Issues #88-#90 informed transport composition only. No future-facing UI or command identifier was added.

## Automated verification

| Evidence | Result |
| --- | --- |
| Contract validator | Pass |
| Surface-contract validator | Pass |
| SessionKit build/test suite | 184 passed, 0 failed |
| App unit suite on final tree | 284 passed, 0 failed |
| Supertonic timing falsification rerun | 26 passed, 0 failed |
| iPhone broad UI routes | 15 passed, 0 failed |
| iPad broad UI routes | 15 passed, 0 failed |
| Generated-project generic iOS Simulator build | Pass |
| Generated-project generic iOS device build | Pass |
| `git diff --check` | Pass |
| Sharing/Watch/SessionKit/schema omission audit | Pass; no changed files |

Final result bundles:

- App units: `/Users/colemiller/Library/Developer/Xcode/DerivedData/SpokenMarginsNative-frwvcspidefdamboxsgsdxxaxbwj/Logs/Test/Test-SpokenMarginsApp-2026.08.28_11-23-51--0500.xcresult`
- iPhone UI: `/Users/colemiller/Library/Developer/Xcode/DerivedData/SpokenMarginsNative-frwvcspidefdamboxsgsdxxaxbwj/Logs/Test/Test-SpokenMarginsApp-2026.08.28_10-49-45--0500.xcresult`
- iPad UI: `/Users/colemiller/Library/Developer/Xcode/DerivedData/SpokenMarginsNative-frwvcspidefdamboxsgsdxxaxbwj/Logs/Test/Test-SpokenMarginsApp-2026.08.28_10-58-10--0500.xcresult`

One final-tree unit attempt on an unhealthy simulator produced four timing assertions in unchanged Supertonic tests, then the simulator service died during the first isolation attempt. A clean iOS 18.6 simulator passed the entire 26-test class and the complete 284-test suite. The clean full-suite rerun is the stopping evidence; the transient is retained here so later failures can be compared rather than hidden.

## Experience audit

These checks establish implementation evidence, not product-fit acceptance or human timing claims.

| Criterion | Implemented/verified evidence | Product-owner measurement |
| --- | --- | --- |
| Time to resume | One prominent Continue action; active unfinished session wins; the same item is removed from the compact list | Record cold and warm stopwatch times |
| Time to add each source type | Every supported type has a named route and reuses its existing importer | Record time and confusion points for all five routes |
| Destructive-action exposure | Library deletion is in context/accessibility actions, followed by confirmation and recoverable undo/recently-deleted handling | Confirm discoverability without accidental activation |
| Provenance comprehension | Timeline uses explicit labels, distinct symbols/shapes/surfaces, color, and combined VoiceOver labels | Ask the tester to identify each event without coaching |
| Consent independence | Follow never imports; background intake never replaces active playback; download/preparation remain separate; storage clear excludes protected work | Exercise each pair of choices and record surprises |

## Omission checks

Supported-source coverage is present for link/podcast, pasted text, Markdown/PDF, DRM-free EPUB, audiobook, and Quick Folder. Candidate review, duplicate/unsupported input, active-playback preservation, and file-based onboarding evidence have focused regression coverage.

The UI contains explicit paths for loading/progress, empty Library/Sources/Margins, offline source snapshots, stale source content, failed/Needs attention work, partial preparation, and completed/resumable items. The final automated gate exercised representative empty, offline, failed, partial, recording, storage, and completed paths. Product-owner validation must still use real files, feeds, connectivity changes, microphone interruptions, and low-space conditions.

No automated gate observed any integration stop condition: recording escape, session replacement during recording, playback-position drift, full scrubbing for starter-only audio, follow-triggered import, feed/source identity collapse, protected-data clearing, intake replacing active playback, fabricated metadata, future placeholder UI, or sharing/Watch diff.

## Known issues and limits

- Three pre-existing AVFoundation chapter-loading deprecation warnings remain in `LocalSourceImporters.swift`; builds succeed and the import paths have focused coverage.
- Physical-device microphone permission, interruption/relaunch recovery, security-scoped document picking, audio-route behavior, and storage pressure remain product-owner checks.
- The guided starter has a bundled playable fallback. Deployment and availability of the optional remote onboarding manifest were not changed or revalidated by this branch.
- Intermittent `DebuggerLLDB.DebuggerVersionStore` host warnings appeared during simulator work and did not fail the final gate.
- No functional issue discovered in the private-experience scope is being knowingly waived.

## Reset, starter items, and diagnostics

- Clean-install reset: delete Spoken Margins and reinstall Build 22.
- Debug build reset: Settings > Developer > Developer tools > Reset Library and Load Sample, then confirm Reset Library.
- Starter choices: **What Spoken Margins is for** (`Welcome to Spoken Margins`) and **Practice a Margin** (`Guided Tour: Add and Prepare Sources`). Both enter the normal item/player paths and are excluded from user-added onboarding evidence.
- Replay: Help > Guided Tour > Start or Resume/Replay Guided Tour. Use **Show Progress on Home** to restore the dismissed starter/progress card.
- Delete/tombstone: move a starter to Recently Deleted from its Library context action; deleting the guided item records its tombstone so it is not silently reseeded.
- Privacy-safe diagnostics: Settings > Support & Privacy > Copy Privacy-Safe Diagnostics.
- Debug diagnostics and raw Listening Map JSON: Settings > Developer.
- Session export: Now Playing or Timeline > Export; multi-session export is available from Library.

## Product-owner checklist

Record PASS or FAIL, elapsed time where requested, and a short note. Store accepted evidence beside this file.

- [ ] Clean install on one supported iPhone and one iPad; record device, OS, install source, and Build 22.
- [ ] Try both starter choices, Skip, replay, card restoration, deletion, and relaunch; confirm neither starter counts as a user-added source.
- [ ] Resume an active and a recent unfinished item; record cold/warm time to resume and confirm the Continue item is not duplicated.
- [ ] Add a link/podcast, pasted text, Markdown/PDF, EPUB, audiobook, and Quick Folder candidate; record time, errors, duplicate behavior, and whether active playback remains unchanged.
- [ ] Follow, refresh, dismiss, add, mute, and unfollow a real source while online/offline/stale; confirm follow alone never imports, downloads, or prepares.
- [ ] Open factual item detail for nested and mapless sources; verify authored hierarchy, preparation/download truth, sessions, Margins, and developer-only raw JSON.
- [ ] Exercise Now Playing, separate mini-player actions, skips, speed, sleep, partial/full preparation, offline playback, app backgrounding, and system playback controls; note any position drift.
- [ ] Start recording from Library, Sources, and Margins; try tabs, edge swipe, mini-player, item/session replacement, interruption, denied permission, Finish, Cancel, and relaunch recovery.
- [ ] Create successful, failed, and incomplete Margins; verify Needs attention, recording playback, retry, copy, detail, chronological grouping, immutable anchors, and Timeline focus.
- [ ] Identify source, My Margin, user response, and assistant response events using sight and VoiceOver without coaching; confirm no provider is claimed without stored provenance.
- [ ] Lower the storage budget, create reservations/overage, and clear reproducible audio; confirm protected imports, recordings, transcripts, and Margins survive.
- [ ] Check light/dark mode, Increased Contrast, largest supported Dynamic Type sizes, Reduce Motion, VoiceOver order/labels, and portrait/landscape layouts on iPhone/iPad.
- [ ] Export one session and a batch; confirm no cross-session note leakage and inspect privacy-safe diagnostics after one induced failure.
- [ ] Confirm sharing, imported people, recipient preview, Watch, Scenes, and Skim are absent from this branch's product surface and diff.

Product-owner result: Pending.

Product-owner notes: Pending.
