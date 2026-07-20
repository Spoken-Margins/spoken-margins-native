# Gate 4 Agent Card: Watch Untethered

## Mission

Close the Gate 4 Watch Untethered surface as steward-owned work, including shared SessionKit runtime, Watch app UI, phone broker wiring, project generation, and contract status updates.

Gate 4 proves that the Watch can be a prepared local playback and recording runtime, not only a tethered remote control.

## Owned Files

- `validation/surface-contracts/gate4-watch-untethered.json`
- `docs/gate4-watch-untethered-foundations.md`
- `docs/gate4-watch-untethered-closeout.md`
- `validation/agent-cards/gate4-watch-untethered.md`

Gate 4 work must also follow `docs/parallel-track-coordination.md`, `docs/surface-contract-governance.md`, and the steward packet for the active branch.

## Steward-Only Files

Do not edit these files without explicit steward assignment:

- `SpokenMarginsNative.xcodeproj/project.pbxproj`
- `Packages/SessionKit/Sources/SessionKit/SessionEngine.swift`
- `Packages/SessionKit/Sources/SessionKit/Models.swift`
- `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift`
- `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1RootView.swift`
- `validation/contracts/command-matrix.json`
- `validation/contracts/snapshot-fields.json`
- `validation/contracts/delegation-modes.json`
- `schemas/surface-contract.schema.json`
- `scripts/validate-surface-contracts.py`

## Allowed Commands

```bash
python3 scripts/validate-contracts.py
python3 scripts/validate-surface-contracts.py
```

Gate agents must not run full app or Xcode builds. Steward closeout must run the contract validators plus iOS and watchOS builds.

## Target Contract

- Runtime profile: `watch-untethered`
- Primary trace: `traces/watch-offline-prerendered-session.json`
- Companion steward trace: `traces/watch-sync-interjections-after-reconnect.json`

## Required Gate 4 Shape

- Watch shows a package library with loaded, queued-for-transfer, and needs-prerender states.
- Phone publishes package library rows and persists package request events.
- Phone transfers package manifests and any matching local package audio assets.
- Watch activates a prepared package locally.
- Watch plays local prepared audio and tracks source media time.
- Watch chapter navigation uses packaged chapter timings.
- Watch records interjection audio locally.
- Watch queues durable sync events with package id, session id, item id, audio file name, source media time, chapter id, transcript segment id, and playback rate.
- Phone/tablet imports queued events idempotently after reconnect, then owns transcription, cleanup, summary, discussion, and canonical persistence.

## Required Handoff Output

Every Gate 4 handoff must include:

- changed files
- contract deltas
- backend requests
- tests run
- tests not run
- open risks
- shared vocabulary needed but missing from the steward packet
- whether executable traces changed

## Contract-First Limits

- Use only command ids already listed in `validation/contracts/command-matrix.json`.
- Use only snapshot fields already listed in `validation/contracts/snapshot-fields.json`.
- Use only delegation modes already listed in `validation/contracts/delegation-modes.json`.
- Do not add new fixture families unless the steward packet says they are schema-validated.
- Do not change replayed traces unless every new command, event, and expectation key is already supported by the SessionKit trace harness.
- If Gate 4 needs a new package status field, sync event shape, command payload, trace expectation, schema, validator, or runtime behavior, record a backend request instead of changing shared vocabulary.
- Validator success is not runtime or trace-replay proof.

## Out Of Scope

- Watch-owned transcription, cleanup, AI, Listening Map generation, or provider calls.
- Watch-owned canonical persistence beyond queued package events.
- Xcode target wiring.
- Shared SessionKit command implementation.
- Shared schema or validator changes.
- iCloud implementation. Gate 4 may define the package manifest and sync direction, but steward owns implementation.
  Gate 4 closeout preserves the manifest shape for future iCloud/laptop rendering but does not implement direct iCloud discovery.
