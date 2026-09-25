# Second-edition execution packet

Status: approved by the product owner on September 10, 2026, together with `second-edition-release-decision.md`. Monitor only milestone evidence and material issues; the owner authorizes approach adjustments to limit supervision cost, with a 20% usage floor. This packet names the steward, gate agents, allowed files, forbidden files and integration order required by `AGENTS.md`. It is a bounded exception for this work, not reactivation of the historical Gate 3/Gate 5 workflow.

## People and model assignments

| Name | Model and role | Authority |
| --- | --- | --- |
| `design_steward` | This current parent task; design intent, architecture, shared integration and final judgment | Owns release-plan updates after approval, shared runtime, test integration, all Xcode/simulator execution and accepted milestone handoff |
| `ui_implementer` | `gpt-5.6-terra`, medium reasoning; one bounded code-writing packet at a time | Only the exact files listed for its current packet; RT-2/3 is the explicitly leased runtime exception |
| `evidence_reviewer` | `gpt-5.6-terra`, medium reasoning; independent review of a frozen candidate | Read-only source review, counterexamples and evidence review; writes only its assigned report under `artifacts/reviews/second-edition/` |

The steward must not modify a file leased to the implementer until that packet is returned or explicitly suspended. The evidence reviewer must receive a frozen patch and source hash; do not review a moving target. All agents share a checkout, so do not assume spawning creates worktree isolation. Use at most these three agents. No recursive delegation, separate user-owned tasks, new branches, pushes or commits by workers.

## File ownership

Every path below is relative to `App/SpokenMarginsApp/Sources/SpokenMarginsApp/` unless it begins with another repository directory. Only the steward may enlarge an implementation packet within the approved scope, and must record the revised file list before the worker edits.

| Packet | Implementer may edit | Outcome / dependencies |
| --- | --- | --- |
| UI-1A | `ExperienceLibraryScreen.swift` | Item-first Library using current query/readiness/actions; starts after shared visual decisions are frozen |
| UI-1B | `ExperienceRecordingScreen.swift`, `ExperienceMarginsScreen.swift`, `ExperienceMarginDetailView.swift` | Compact existing recording/review loop; starts after UI-1A review |
| UI-2 | `ExperienceMarginsScreen.swift`, `ExperienceMarginDetailView.swift`, `ExperienceTimelineRailScreen.swift` | Search/filter/detail UI and explicit-return controls; only after steward supplies real session-qualified interfaces |
| UI-3 | `ExperienceRecordingScreen.swift`, new `ExperienceWrittenMarginScreen.swift` | Written composer and recovery presentation; only after steward freezes written-capture behavior and provides working app interfaces |
| UI-4A | `ExperienceAddSourceFlow.swift`, `ExperienceItemDetailScreen.swift`, `ExperienceSourcesScreen.swift` | Compact intake/detail/Following with existing import and preparation semantics |
| UI-4B | `Build23SenderSharingExperience.swift`, `Build23SenderSharingComponents.swift`, `Build23RecipientSharingExperience.swift`, `ExperienceStorageScreen.swift`, `ExperienceAudioPreparationQueueScreen.swift` | Sharing/storage composition, preserving all real review and recovery gates |

Forbidden to worker edits except for the explicitly enumerated RT-2/3 lease below: `Gate1RootView.swift`, `Gate1AppModel.swift`, `ExperienceModels.swift`, `ExperienceRootViews.swift`, `ExperienceCanonicalNavigationTree.swift`, `ExperienceDesignSystem.swift`, `ExperienceColorContrast.swift`, `SharingExperience.swift`, `Build23SharingSeams.swift`; all `Packages/`, `Contracts/`, `schemas/`, `validation/`, `TestPlans/`, `scripts/`, project/signing/entitlements files, `docs/`, `AGENTS.md`, `.codex/`, `.openai/`, and `Design/UXProposal20260909/`. Also forbidden: every file not in the current packet. The worker may read these paths as necessary.

The steward owns changes to shared files and corresponding existing tests, but only for approved milestones. In M3, explicitly enumerate any SessionKit model/store/export/contract file changes before coding; coherent schema and compatibility coverage are mandatory. Permission to integrate the design does not authorize unrelated audio engines, package formats, Watch features or runtime rewrites.

## Integration order and operating loop

Integration means accepting a returned patch into the current lane; no automatic branch merge or publication is implied.

1. Steward records the approved release revision, baseline and visual/behavior contract.
2. UI-1A, then UI-1B. Meanwhile the steward can work on its exclusively owned player, navigation and test seams. No verification runner while either is editing.
3. Steward freezes the combined M1 diff and runs checks. Evidence reviewer inspects that exact diff and artifacts; steward independently reviews real screenshots against the reference and the owner's correction.
4. Steward resolves findings and records usage calibration. Proceed to UI-2 after shared identity/search interfaces, then UI-3 after the written-capture transaction.
5. UI-4A, then UI-4B; steward handles settings and Skim/shared-player surfaces in `Gate1RootView.swift`.
6. Freeze all code for M5. One verification runner at a time. Reviewer examines evidence omissions and capability drift; steward produces the owner handoff.

A failing task-usefulness check blocks acceptance even when code compiles. A worker reports an unavailable capability as a backend request; it must not invent a model property, show simulated success or alter tests to fit the new picture. Report first failure and repair evidence separately. After two unsuccessful repairs, the steward diagnoses the underlying issue before another worker pass.

## Copyable implementer prompt

    Implement packet <PACKET> from docs/second-edition-work-packets.md in the shared checkout on codex/provisional-next. The owner has approved the recorded release amendment; verify that record before editing.
    Read AGENTS.md, docs/release-lanes.md, docs/second-edition-implementation-plan.md, the exact current packet, and Design/UXProposal20260909/research/second-edition.md. Inspect the supplied reference screenshot and current native source. The steward will include the exact allowed file list and relevant native interfaces here; do not begin from an unspecified placeholder packet.
    The design correction is binding: actual items/notes and primary actions appear before decorative explanation. Match hierarchy, typography and state clarity while using native accessibility and real app behavior. Do not shrink text or replace working capabilities with demo state.
    Edit only your packet files. The steward owns player/model/schema/project/tests/builds. Do not commit, push, switch branches, run Xcode, drive the simulator, spawn another agent or change the reference. A missing backend interface is a request to the steward, not permission to fake it.
    Return the changed files, implemented user outcomes, reused app actions, unresolved backend requests, checks actually run, checks not run, and any design deviations. Include concrete adversarial cases for the reviewer. Do not claim human validation.

The steward fills the packet and embeds the accepted interface details when dispatching. Do not send the worker this template with unresolved placeholders.

## Copyable reviewer prompt

    Review the supplied frozen patch and input hash for packet <PACKET>. Read the approved implementation plan and second-edition design correction. You did not author this change; attempt to falsify its claims.
    Inspect whether useful content appears before explanation, critical controls stay available, text can grow, selected item/session identity is correct, and actions preserve readiness, recording, import and disclosure boundaries. Look for hard-coded sample behavior, lost existing actions and tests that merely mirror the implementation.
    You may read source and supplied logs/screenshots. Do not edit runtime/tests, run Xcode, mutate simulator state, or delegate. Write only <REPORT_PATH> under artifacts/reviews/second-edition/ if a report is requested.
    Return actionable defects with file locations, reproduction/counterexample, evidence quality and blocking status. Distinguish observed failure, code-supported risk and untested assumption. A screenshot is not audible playback evidence; a passing build is not user acceptance. If no defect is found, state what was examined and what remains unproven.

## Handoff record for every packet

Record source/input hash, allowed versus changed files, actual user-visible outcomes, command and test evidence, screenshots reviewed, findings and repairs, unresolved concerns, design deviations, usage observation and next dependency. The steward keeps the plan current so resumed work can proceed from files without reconstructing conversation history.

## RT-2/3 lease amendment · September 10

The steward is assigning the bounded M2/M3 runtime implementation to `ui_implementer` (Terra) under the owner's approved approach-adjustment authority. This replaces steward-only runtime authorship for this packet, reducing repeated supervision and context reconstruction. The steward retains architecture acceptance, integration and all verification. It does not authorize general runtime refactoring.

Exact allowed files:

- `Packages/SessionKit/Sources/SessionKit/Models.swift`
- `Packages/SessionKit/Sources/SessionKit/SessionEngine.swift`
- `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift`
- `App/SpokenMarginsApp/Sources/SpokenMarginsApp/ExperienceModels.swift`
- `Packages/SessionKit/Tests/SessionKitTests/SessionKitCoreTests.swift`
- `Packages/SessionKit/Tests/SessionKitTests/PriorBuildPersistenceTests.swift`
- `App/SpokenMarginsAppTests/Gate1AppModelWorkflowTests.swift`
- `App/SpokenMarginsAppTests/ExperiencePresentationTests.swift`
- `Contracts/schemas/interjection.schema.json`
- new `Contracts/fixtures/interjections/written-interjection.json`

All other files remain forbidden, including UI surfaces and store implementations. Ask the steward to enlarge the list if evidence requires a coherent additional contract change. Existing fixture family and automatic test inventory discovery must be retained.

Required interfaces/outcomes:

1. Session-qualified global star mutation and note audio identity. Keep existing sharing helpers compatible. No browsing or curation may change source playback. A source moment is an explicit action only.
2. Read-only preflight before stopping/rebinding the current source: resolve the authoritative session, item, interjection and original text/media/generated target and bounds. `inspectSession` is a mutation, not a preflight. An unavailable or mismatched anchor must leave the old source intact. Play only after setting the exact target/anchor; no play-at-zero then seek. Handle or roll back a later bridge/setup failure.
3. One canonical engine-owned written transaction, not recorder reuse: immutable capture ID, item/session/target/anchor and prior transport state; pause at begin; reject navigation/voice capture until save/cancel; retain pending capture after save failure; commit once; restore playing only if previously playing. A stale save/cancel may not touch a newer session. Preserve the user's exact text, trimming only for the emptiness check. No recorder, microphone permission, transcriber, or acoustic evidence calls.
4. Optional persisted capture kind, legacy absence retains audio/missing-recording semantics. Written notes have no missing-audio/retry-transcription state. Match the existing schema and reconstruction tests in the same change; keep old fixture bytes intact.
5. Observable app draft (capture ID, entered text, locked context, prior state) and app actions for begin/save/cancel. Include the draft in navigation exclusion. Async voice permission completion must not start recording after cancellation or a written-capture switch. Denial offers writing through real app state.
6. Presentation models for deterministic local private-note/title search, Starred/attention filtering, and separately identified imported Shared rows with provenance. Do not search full source transcripts. Source context returned for detail must be bounded and tied to the addressed target; generated notes never show unrelated source text. Preserve all original recovery actions.

Meaningful tests must address colliding IDs across sessions, a 50-note search collection, passive browsing while another item plays, invalid anchors preserving the old source, original media/text/generated anchor playback, active/pre-paused written restoration, exact text and old-store reconstruction, cancellation, store failure/retry/double save, zero recorder/transcriber use and generated-target capture. Tests may be authored in this packet; only the steward runs them.

Execution state: allowlist recorded while UI verification is frozen. The implementer may edit only after the steward explicitly releases the freeze. Return final interface signatures and unresolved risks with the patch. No build, tests, simulator, commits, branch changes, or delegation.

RT-2/3 bounded M4 addition (same file allowlist): natural source completion must preserve passive Item/Margins/Export navigation and retain a useful finished-player review/replay path. Pilot video proves the short fixture completes during item browsing or shortly after cancellation, and the old `closeCompletedSessionIfReady` forces Library and clears session identity. Preserve canonical finished persistence and add a focused completion-while-browsing regression; do not redesign unrelated lifecycle policy.

### RT packet split after partial returns

The combined runtime packet produced two incomplete returns without its required tests. The steward is narrowing ownership by behavior rather than asking for another broad retry. The partial RT-2/3 lease is now returned. `ui_implementer` next owns RT-W only: `SessionEngine.swift`, `Models.swift`, `SessionKitCoreTests.swift`, `PriorBuildPersistenceTests.swift`, and the already-listed Interjection schema/written fixture. All paths retain the prefixes in the RT-2/3 list. Outcome: finish and test the written transaction, including persistence failure/retry, transport-restore failure after a successful commit, pre-paused state, exact heard/generated anchor and stale requests. A successful note commit must never leave a retryable composer that creates a duplicate because resuming audio failed. Begin failure may not strand playback without a capture. No app-model or UI edits in RT-W. The steward takes back app model/presentation models/app tests and completes retrieval/transport integration on those disjoint files. The engine's explicit-anchor method will receive a separate RT-P correctness/test pass after RT-W returns.

RT-W narrow testability addition: `Packages/SessionKit/Sources/SessionKit/InMemoryRepository.swift` may be changed only to permit a test subclass overriding persistence writes (remove `final`; no production failure switches). The test target supplies deterministic failures. Steward-owned M2 addition: `Packages/SessionKit/Sources/SessionKitPersistence/SQLiteSessionStore.swift` gains a read-only all-imported-layers overload so Shared results include unresolved layers without a source item. Existing record kind/schema is unchanged.

### RT-P lease

RT-W has returned with tests authored, not executed. Next `ui_implementer` owns only `Packages/SessionKit/Sources/SessionKit/SessionEngine.swift` and `Packages/SessionKit/Tests/SessionKitTests/SessionKitCoreTests.swift`. Finish canonical explicit anchor playback and session-qualified async Margin updates with tests. `playInterjectionAnchor` must preflight the authoritative stored note/session/item/target without mutating playback, then perform the session switch itself; the app must not call `inspectSession` first. Reject negative/missing/out-of-range anchors and inactive/deleted/wrong generated targets. Original media, original text, prepared text and generated targets must start at the saved anchor with no audible zero-start. On persistence/adapter failure restore old engine identity/position/target and prior play/pause state; if old audio also fails, retain old identity in a truthful paused error state. Preserve the foreign target session's stored position when an attempted action fails. The app handles transport URL registration before this engine transaction and restores download-coordinator selection on failure.

Add optional `sessionId: String? = nil` immediately after `interjectionId` on transcription completion/failure, source-window context pending/completed/unavailable and podcast-evidence completion/failure methods. When supplied, resolve exactly that session and never fall back to the active session or mapless fixture. Existing callers without a session parameter keep compatibility. Parent updates app callers and tests; worker edits only the two engine files. Required engine tests: exact text/media/generated/prepared anchors; foreign session switch; invalid target preserves old audio/state; persistence/adapter failure rollback; same note ID across sessions does not cross-mutate when explicitly addressed. No builds/tests/simulator/commits/delegation.

### RT-E review repair

The returned runtime review identifies export capture-kind loss and ID-only destructive endpoints. The steward assigns a final bounded runtime lease to `ui_implementer`: `Packages/SessionKit/Sources/SessionKit/SessionEngine.swift`, `Packages/SessionKit/Sources/SessionKit/SessionExport.swift`, `Packages/SessionKit/Tests/SessionKitTests/ExportIsolationRegressionTests.swift`, `Packages/SessionKit/Tests/SessionKitTests/SessionKitCoreTests.swift`, `Contracts/schemas/session-export.schema.json`, and a new `Contracts/fixtures/exports/written-session-export.json` in the existing export fixture family. Add optional export capture kind with legacy absence preserved; carry exact written text into JSON/Markdown. Scope cleanup/representation deletion/note deletion by optional sessionId for compatibility, and test same-ID foreign mutations. The steward owns app callers/tests and compile repairs on disjoint files. No verification runner while this lease is active.

### UI-4C visual repair

Phone screenshots falsified UI-4A/4B task-first acceptance: Item repeated readiness three times, stacked three large actions and decorative type art before Shared provenance. The steward grants `ui_implementer` only `App/SpokenMarginsApp/Sources/SpokenMarginsApp/ExperienceItemDetailScreen.swift` and `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Build23ImportedMarginPresentation.swift` for this repair. Remove redundant readiness prose/duplicate status and decorative item cover; lead with full title and one primary listening action, compact secondary session/review actions, real download recovery, and immediate shared provenance. Compact the imported-layers editorial header and put actual Margins before optional management controls while retaining all integrity/source/consent/reveal/mute facts/actions. All other implementation files are steward-owned. No runner while either writer is active.
