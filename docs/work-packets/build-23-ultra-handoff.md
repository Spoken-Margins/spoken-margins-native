# Build 23 Ultra implementation packet

Status: frozen and ready for an Ultra implementation thread after the
`build-23-ultra-seam-freeze` tag exists. This packet is the explicit,
one-release exception to the repository's single-agent default.

## Start state

- Target branch: `codex/build-23-release`
- Implementation seam SHA: `fca95cb75b4ef6a1a10091c25433ed12615cf5eb`
- Frozen start ref: `build-23-ultra-seam-freeze` (the steward must verify this
  tag and `HEAD` identify the same commit before dispatch)
- Build: Spoken Margins 0.1 (23)
- Deployment: iPhone and iPad, iOS/iPadOS 18.0 or later
- Build 22 dependency: the exact #84 patch is present through merge `81a7c11`,
  but Build 22 remains not uploaded, not accepted, and not `human_validated`
- Source ancestry: quality-of-life plus overhaul through `9118c11`; sharing
  through `de887f6`, merged once at `7d47876`
- Current status: integrated runtime and frozen seams are `implemented` and
  have automated verification; the completed Build 23 experience is not yet
  `verified` or `human_validated`

At kickoff, the steward must run:

```bash
git switch codex/build-23-release
git status --short --branch
git rev-parse HEAD
git rev-parse build-23-ultra-seam-freeze^{commit}
```

Stop if the worktree is dirty, the two SHAs differ, the tag is missing, or a
source lane has advanced. Do not reset or discard the unexpected state.

## Why Ultra is appropriate now

XHigh was used for the integration phase because the work had shared ancestry,
conflict resolution, release-number decisions, and app-model/root ownership.
Those seams are now resolved and executable. The remaining work separates into
three clean file sets with one steward-only integration step. This is the point
at which multi-agent Ultra should reduce wall time without multiplying merge
risk. OpenAI's current model guidance describes multi-agent work as most useful
for clean independent streams and notes that higher reasoning effort should be
reserved for the work that benefits from it:
<https://developers.openai.com/api/docs/guides/latest-model>.

Do not use Ultra to let several agents redesign the same flow. Use it to execute
the three packets below against the frozen contract.

## Challenge model

### Constraints

- Build 22 remains a distinct human-validation gate. Build 23 distribution is
  blocked until its #84 result is recorded.
- Issue #14 blocks externally enabled sharing until the product owner accepts
  the rights/provenance policy. Own-device validation may continue.
- Only the product owner can mark a product flow `human_validated`.
- The one-way sharing release excludes Watch runtime, co-op replies (#19), AI
  synthesis (#26), accounts, hosted storage, and remote revoke.
- Recipient preview must come from the exact verified archive, never draft UI
  state. A package-affecting edit must invalidate the preview and share URL.
- Imported Margins are a separate provenance layer, default to Companion,
  never autoplay, and must be distinguishable by label, symbol/shape, and
  accessibility text rather than color alone.
- Recipient-supplied items must enter Add Source and return to the pending
  verified import; users must not be told to reopen the package.
- Agents share one worktree. They may not switch branches, commit, rebase,
  reset, regenerate the project, or modify another packet's files.

### Resources

- `Build23SharingSeams.swift` contains the canonical stage, action, projection,
  exact-preview, stale-invalidation, Add Source reconciliation, and imported
  layer adapter.
- `Build23SharingSeamsTests.swift` proves archive round-trip and invalidation.
- `SharingExperience.swift` is the old dense sender/recipient surface and a
  behavioral reference, not the Build 23 composition target.
- `ExperienceDesignSystem.swift` supplies the semantic visual language.
- `Design/SpokenMarginsOverhaul/app/page.tsx` contains the earlier three-step
  recipient-preview concept; use it as design reference, not runtime code.
- `artifacts/validation/sharing-next/product-owner-handoff.md` records verified
  sharing behavior and the product-owner checklist.
- `artifacts/validation/gate-1/experience-overhaul/` contains the visual source
  evidence and known rough edges.

### Mechanisms

- Sender state machine: Select → Review → Recipient Preview → Share.
- Recipient state machine: Preview → Import or Add Source → Resume Pending
  Import → Choose Layer Behavior; no autoplay.
- Package mechanism: prepare → write `.spokenmargins` → read and verify the
  written archive → project recipient preview → share that same file URL.
- Integration mechanism: gate-local new Swift files first; steward-owned root
  wiring and generated project updates after gate review.

### Actors

- Build 23 Integration Steward: owns the branch, shared seams, merge order,
  root/model wiring, generation, full tests/builds, status language, and final
  product-owner handoff.
- Sender Experience Gate: owns the new four-stage sender surface only.
- Recipient Experience Gate: owns package-preview/import and imported-layer
  presentation components only.
- Experience Polish Gate: owns three already-observed layout/presentation
  rough edges only.
- Product owner: resolves #14, validates Build 22, and validates Build 23 on
  physical devices.

### Prior failure modes this packet is designed to catch

- Porting the old sharing sheet wholesale and preserving its oversized,
  all-at-once review structure.
- Rendering a friendly preview before bytes exist, then sharing different or
  stale bytes.
- Using color as the only provenance cue.
- Letting import imply playback, source ownership, or Listening Map activation.
- Asking the recipient to reopen a verified package after adding a source.
- Having several agents edit `Gate1AppModel`, `Gate1RootView`, models,
  protocols, the project file, or validation vocabulary concurrently.
- Treating validator or simulator success as product-owner acceptance.

### Evidence paths and decision criteria

- Gate-local unit/presentation tests prove projections and actions are rendered
  and dispatched as specified.
- `Build23SharingSeamsTests` protects exact archive preview and invalidation.
- SessionKit sharing tests protect archive, anchor, persistence, and playback
  semantics.
- Contract validators protect serialized/reference vocabulary only.
- Generic iOS simulator/device builds prove app and package integration.
- Focused UI routes prove stage navigation, system sharing, Add Source return,
  no-autoplay, and non-color provenance.
- Product-owner device evidence is required for microphone, real podcast
  editions, Live Activity, system share targets, import files, and product fit.

Build 23 is ready for a product-owner handoff only when all required automated
evidence passes, no stop condition below is present, and the handoff names the
candidate SHA. It remains not `human_validated` until the owner records results.

## Frozen product contract

### Sender

1. **Select** shows the listened-to item, rights/transport consequence, the
   private starred shortlist, and explicit Include state. Stars are a default,
   not the final decision.
2. **Review** shows a compact list and one detailed Margin editor at a time.
   The editor supports inline word/pause toggles, Undo/Redo, Original/Cleaned/
   Text selection, bounded anchor context, and audio preview where available.
   Batch preparation is one bounded, cancelable action with visible progress
   and per-Margin fallback.
3. **Recipient Preview** is populated only by
   `Build23VerifiedRecipientPreview`, which is produced by round-tripping the
   actual archive. It explains what is included and excluded. Any relevant edit
   returns the flow to Review and removes the share URL.
4. **Share** uses only `coordinator.verifiedShareFileURL` with the native system
   share surface. It must not rebuild or substitute the package.

### Recipient

1. Preview the integrity-checked, unsigned sender label, item, transport, Margin
   count, included asset categories, and no-autoplay promise.
2. If the same item is missing, dispatch `.requestMissingSource`, route through
   existing Add Source UI, then dispatch `.resumeAfterAddingSource`. Keep the
   verified package staged throughout.
3. Import only on explicit confirmation. Importing may start a user-initiated
   podcast download but never playback.
4. Present the imported layer separately with integrity/resolution state,
   sender label, distinct symbol/shape, enabled/muted controls, and reveal mode.
   Default unresolved behavior is Companion/opt-in.

## Frozen executable seam

Steward-only file:

`App/SpokenMarginsApp/Sources/SpokenMarginsApp/Build23SharingSeams.swift`

Canonical sender stages:

```text
select, review, recipient_preview, share
```

Canonical sender actions:

```text
begin
setFilter
setSenderDisplayLabel
setIncludesAcousticEvidence
setPrivateSharingRightsConfirmed
setIncluded
selectMargin
setRepresentation
setAnchorBefore
setAnchorAfter
prepareCleanup
setCleanupDecision
toggleTranscriptWord
undo
redo
restoreOriginal
prepareAllIncluded
cancelPreparation
returnToSelect
advanceToReview
buildRecipientPreview
presentSystemShare
returnFromSystemShare
cancel
```

Canonical recipient actions:

```text
requestMissingSource
dismissSourceRequest
resumeAfterAddingSource
confirmImport
cancelImport
setLayerEnabled
setLayerMuted
setLayerRevealMode
```

Canonical projections consumed by gate UI:

```text
Build23SharingSnapshot
Build23SharingMarginSnapshot
Build23SharingReviewTokenSnapshot
Build23VerifiedRecipientPreview
Build23RecipientImportSnapshot
Build23RecipientSourceRequest
Build23ImportedLayerSnapshot
Build23ImportedMarginSnapshot
```

If a gate cannot implement its surface using these values/actions, it records a
backend request. It does not edit the seam or reach into `Gate1AppModel`.

## Execution topology and file ownership

There are four concurrency slots: the steward plus exactly three gate agents.
All agents work in the same worktree. Gates do not use git commands.

### Steward: `build23_integration_steward`

The root Ultra agent is the steward. It owns all files not explicitly granted
below and is the only actor allowed to edit:

- `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Build23SharingSeams.swift`
- `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift`
- `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1RootView.swift`
- `App/SpokenMarginsApp/Sources/SpokenMarginsApp/SharingExperience.swift`
- `Packages/SessionKit/Sources/SessionKit/Models.swift`
- `Packages/SessionKit/Sources/SessionKit/Protocols.swift`
- `Packages/SessionKit/Sources/SessionKit/SessionEngine.swift`
- `Packages/SessionKit/Sources/SessionKitPersistence/SQLiteSessionStore.swift`
- `Packages/SessionKit/Package.swift` and both `Package.resolved` files
- `project.yml` and `SpokenMarginsNative.xcodeproj/project.pbxproj`
- contracts, schemas, fixtures, traces, validation vocabulary, validators
- release/spec/handoff documentation and validation artifacts

The steward does no gate implementation while gates run. It audits current
state, answers backend requests, and waits. After all three handoffs, it reviews
and integrates in the merge order below.

### Gate A: `build23_sender_experience`

Objective: implement the complete four-stage sender experience using only the
frozen coordinator.

Allowed files, created by this gate:

- `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Build23SenderSharingExperience.swift`
- `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Build23SenderSharingComponents.swift`
- `App/SpokenMarginsAppTests/Build23SenderSharingExperienceTests.swift`
- `docs/backend-requests/build-23-sender-experience.md` only if blocked

Required outcomes:

- adaptive Select/Review/Recipient Preview/Share composition;
- compact selection rows and exactly one expanded detailed editor;
- starred-default explanation without conflating star and Include;
- visible rights/transport consequence;
- inline word and bracketed-pause editing through canonical actions;
- batch progress/cancel/fallback presentation;
- recipient preview using only the verified projection;
- native share invocation using only the verified file URL;
- accessibility identifiers, labels, Dynamic Type, and non-color status cues;
- focused tests for stage gating, one-editor behavior, stale preview, and share
  URL absence before verification.

Forbidden: environment access to `Gate1AppModel`, direct mutation of
`InterjectionSharingState`, old-view edits, root wiring, archive/model changes,
new commands/snapshot fields, project generation, `xcodebuild`, and git.

### Gate B: `build23_recipient_experience`

Objective: implement package preview/import, Add Source handoff/return, and
distinct imported-layer presentation using only frozen recipient projections.

Allowed files, created by this gate:

- `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Build23RecipientSharingExperience.swift`
- `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Build23ImportedMarginPresentation.swift`
- `App/SpokenMarginsAppTests/Build23RecipientSharingExperienceTests.swift`
- `docs/backend-requests/build-23-recipient-experience.md` only if blocked

Required outcomes:

- preview before import with integrity-but-unsigned language;
- explicit import and cancel; no autoplay language and behavior;
- missing-source request that can be presented by the steward's existing Add
  Source route and resumed without reopening the package;
- imported layer card/rail components with sender, integrity, resolution,
  enabled, muted, reveal mode, proposal count, and Margin placement;
- provenance conveyed by label plus symbol/shape/surface and VoiceOver, not
  color alone;
- Companion as the displayed default when no mode is stored;
- focused tests for missing-source return, disabled import while missing,
  default Companion, and non-color provenance labels.

Forbidden: direct model/store/archive access, root/Add Source implementation
edits, playback/autoplay changes, schema/fixture changes, project generation,
`xcodebuild`, and git.

### Gate C: `build23_experience_polish`

Objective: fix only the three observed overhaul rough edges while the sharing
gates build new files.

Allowed files:

- `App/SpokenMarginsApp/Sources/SpokenMarginsApp/ExperienceLibraryScreen.swift`
- `App/SpokenMarginsApp/Sources/SpokenMarginsApp/ExperienceAddSourceFlow.swift`
- `App/SpokenMarginsApp/Sources/SpokenMarginsApp/ExperienceRootViews.swift`
- `App/SpokenMarginsAppTests/Build23ExperiencePolishTests.swift` (new)
- `docs/backend-requests/build-23-experience-polish.md` only if blocked

Required outcomes:

- Library hero/search/filter controls remain readable and operable without
  horizontal clipping at supported compact widths and large Dynamic Type;
- Add Source cards and final actions have bottom clearance and are not cut off
  by sheet height, keyboard, or safe-area behavior;
- root content receives truthful bottom clearance for the persistent
  mini-player rather than allowing it to obscure Timeline/list content;
- no new visual system, route, feature, or speculative control;
- focused layout/presentation tests for the three regressions.

Forbidden: sharing files, `Gate1RootView`, `Gate1AppModel`, Timeline data
semantics, design-token changes, SessionKit, project generation, broad UI
automation, `xcodebuild`, and git.

## Shared vocabulary freeze

Gate agents may not add or change shared surface vocabulary. The accepted
command ids are:

```text
startSession, play, pause, resumePlayback, togglePlayPause, stopPlayback,
skipForward, skipBack, seekToMediaTime, setPlaybackRate, jumpToChapter,
beginInterjection, finishInterjection, cancelInterjection,
generateInterjectionSummary, playTurn, submitFollowup,
importAssistantResponse, endSession, playSourceFromBeginning,
jumpToTurnChapter, importBrowserText, importSourceLink,
attachTranscriptTimeline, loadWatchPackage, importWatchSyncEvent,
attachBrowserMedia
```

`play` remains `contract_only`; `attachBrowserMedia` remains a
`backend_request`. Gates must not promote either status.

Accepted snapshot field ids:

```text
sessionId, itemId, targetType, targetId, status, phase, title, chapterTitle,
progressPercent, sourceProgressPercent, currentPlaybackProgressPercent,
currentMediaTimeMs, currentPlaybackDurationMs, currentTranscriptSegmentId,
currentAnchorConfidence, playbackRate, isRecording, activeInterjectionCount,
pendingAiJobCount, lastInterjectionAnchorType, lastInterjectionTargetType,
recordingTargetId, pendingAiJobKind, pendingAiJobStatus, providerCallStarted,
turnStatus, lastUserTurnType, spokenUnits, lastFailure, availableCommands,
timeline, linkResolutionStatus, linkResolutionFailureReason,
preparedTextAudioStatus, sourceTranscriptStatus
```

Accepted delegation modes:

```text
local, delegated_to_canonical_runtime, queued_offline, unsupported
```

Executable trace commands, events, and expectation keys authorized for gate
changes: none. Gate agents must not edit `Contracts/traces/`, `traces/`, trace
schemas, or replay code.

Fixture families authorized for gate additions: none. Existing sharing fixtures
may be read but not edited. A new fixture/schema need is a backend request.

## Commands and evidence policy

Gate agents may run only:

```bash
.venv/bin/python scripts/validate-contracts.py
.venv/bin/python scripts/validate-surface-contracts.py
git diff --check
```

The steward alone runs package tests, app tests, route tests, `xcodegen`, and
`xcodebuild`. Validator success proves structure/reference validity only.

Every gate handoff must report:

- changed files;
- contract deltas (`none` is expected);
- backend requests;
- tests/checks run;
- tests/builds not run;
- open risks;
- any missing shared vocabulary;
- whether executable traces changed (`no` is required);
- a self-audit that only allowed files changed.

## Merge and integration order

Because gates share one worktree, “merge” means steward review and one bounded
commit per gate; gates themselves do not commit.

1. Duplicate/ownership audit across all handoffs.
2. Sender Experience Gate review and commit.
3. Recipient Experience Gate review and commit.
4. Experience Polish Gate review and commit.
5. Steward-only integration: instantiate one coordinator, replace old sender
   and recipient sheet composition in `Gate1RootView`, wire the Add Source
   request/return through the existing experience route, and wire imported
   layer components into the existing detail/Timeline composition without
   changing package semantics.
6. Regenerate the Xcode project exactly once.
7. Run verification and repair only within steward-owned files unless a gate is
   explicitly reactivated with its original file ownership.
8. Update Build 23 evidence and product-owner handoff.

If two gates touch the same file, a gate edits a forbidden file, or a gate needs
new shared vocabulary, stop integration. Do not resolve it by silently blending
the implementations.

## Steward verification ladder

Fast gate:

```bash
./scripts/bootstrap-python-tools.sh
.venv/bin/python scripts/validate-contracts.py
.venv/bin/python scripts/validate-surface-contracts.py
swift test --package-path Packages/SessionKit
```

Focused app gate on an available simulator:

```bash
xcodegen generate
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:SpokenMarginsAppTests/Build23SharingSeamsTests \
  -only-testing:SpokenMarginsAppTests/Build23SenderSharingExperienceTests \
  -only-testing:SpokenMarginsAppTests/Build23RecipientSharingExperienceTests \
  -only-testing:SpokenMarginsAppTests/Build23ExperiencePolishTests test | xcbeautify
```

Integration build gate:

```bash
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp \
  -destination 'generic/platform=iOS Simulator' build | xcbeautify
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp \
  -destination 'generic/platform=iOS' build | xcbeautify
```

Run focused UI routes for the four sender stages, stale-preview return, system
share, recipient missing-source return, no-autoplay, imported-layer provenance,
and the three layout regressions. Broad UI automation remains a late release
gate, not an agent-local command.

## Audit and falsification

### Alternatives considered

- **Port the old sharing sheet into the new design system:** rejected because it
  preserves the all-at-once information architecture and draft-derived preview.
- **Continue entirely serial on XHigh:** correct before the freeze, but slower
  now that the work has three non-overlapping file sets.
- **Let Ultra agents share root/model files:** rejected because conflict count is
  not the real risk; competing state semantics and unreviewable generated-file
  changes are.
- **Selected:** three gate-local implementations plus one Ultra steward.

### Omission checks

Before handoff, explicitly confirm coverage for link-backed items, app-authored
text, rights-confirmed embedded text, recipient-supplied text/PDF/EPUB, podcast
reference/download, starred and unstarred Margins, voice and text-only Margins,
bulk cancellation/fallback, ambiguous/unresolved anchors, duplicate packages,
large Dynamic Type, VoiceOver, compact iPhone, iPad, dark/light, and no network.

### Falsification tests

- Change sender label, Include, transcript token, representation, anchor,
  evidence, or rights after preview; the verified preview and share URL must
  disappear.
- Alter a written archive byte; recipient preview/import must fail integrity
  verification.
- Enter Share without a ready preview; no share URL or native share surface may
  appear.
- Import a recipient-supplied package, add a nonmatching item, and return; import
  must remain blocked without losing the staged package.
- Import matching content; the pending review must resume without reopening.
- Enable an imported layer; no audio may start until explicit Listen or an
  explicitly chosen autoplay mode permits it.
- Remove color; local and imported provenance must still be distinguishable.
- Use largest supported Dynamic Type and compact height; no primary action may
  be clipped or covered by the mini-player.

## Stop conditions

Stop and return a precise blocker if any of the following occurs:

- Build 22 is rejected or its patch is changed rather than inherited exactly;
- issue #14 is treated as resolved without product-owner evidence;
- exact archive preview or stale invalidation fails;
- recipient import autoplays or silently changes source ownership;
- imported provenance depends on color alone;
- Add Source cannot return to the same verified import;
- a gate needs a steward-only file or unregistered shared vocabulary;
- Watch, co-op replies, accounts, hosted storage, remote revoke, or AI synthesis
  enters the diff;
- the project/package locks cannot be cleanly regenerated;
- a full test/build failure shows that the frozen seam is wrong. In that case,
  stop the gates and let only the steward amend and re-freeze the seam.

## Copy/paste kickoff prompt for the new Ultra thread

```text
Use Ultra mode as the Build 23 Integration Steward for the current repository.
Read AGENTS.md, docs/release-lanes.md, and
docs/work-packets/build-23-ultra-handoff.md completely before acting. Verify a
clean codex/build-23-release worktree and verify HEAD equals
build-23-ultra-seam-freeze^{commit}. If not, stop without resetting anything.

Then spawn exactly three subagents named build23_sender_experience,
build23_recipient_experience, and build23_experience_polish. Give each agent its
verbatim objective, allowed files, forbidden files, required outcomes, command
limits, and handoff shape from the packet. All agents share this worktree: they
must not use git, edit outside their ownership, generate the project, or run
xcodebuild. Do not do gate implementation in the steward while they run.

After all three handoffs, audit ownership and backend requests, integrate in the
recorded order, perform only the steward-owned root/model wiring, regenerate
once, run the full verification ladder and scoped UI routes, update Build 23
evidence, and prepare the product-owner validation handoff. Preserve the status
boundary: automated work may become verified, but only the product owner can
mark a flow human_validated. Stop on every recorded stop condition.
```
