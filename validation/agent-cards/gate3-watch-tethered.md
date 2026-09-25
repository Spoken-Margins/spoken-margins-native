# Gate 3 Agent Card: Watch Tethered

## Role

Advance the Gate 3 Watch Tethered surface contract without changing shared SessionKit implementation or Xcode project files.

## Allowed Files

- `validation/surface-contracts/gate3-watch-tethered.json`
- `validation/agent-cards/gate3-watch-tethered.md`
- Gate 3-specific notes under `docs/` if needed

Gate 3 must also follow `docs/archive/parallel-track-coordination.md`, `docs/surface-contract-governance.md`, and the steward packet for the active branch.

## Forbidden Files

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

## Deliverables

- Watch tethered surface contract deltas.
- Trace or fixture gaps for `traces/watch-chapter-navigation.json`.
- Backend requests for compact snapshot and delegated command behavior.
- Final handoff with changed files, contract deltas, backend requests, tests run, tests not run, and open risks.

## Contract-First Limits

- Use only command ids already listed in `validation/contracts/command-matrix.json`.
- Use only snapshot fields already listed in `validation/contracts/snapshot-fields.json`.
- Use only delegation modes already listed in `validation/contracts/delegation-modes.json`.
- Do not add new fixture families unless the steward packet says they are schema-validated.
- Do not change replayed traces unless every new command, event, and expectation key is already supported by the SessionKit trace harness.
- If Gate 3 needs a new snapshot field, command payload, trace expectation, schema, validator, or runtime behavior, record a backend request instead of changing shared vocabulary.
- Validator success is not runtime or trace-replay proof.

## Steward Verification

These commands require explicit steward/build authority and are not part of ordinary gate-agent scope:

```bash
swift test
python3 scripts/validate-contracts.py
python3 scripts/validate-surface-contracts.py
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsAppDevice -destination 'generic/platform=iOS' build | xcbeautify
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsWatch -destination 'generic/platform=watchOS' build | xcbeautify
```

## Device User Testing

Run this on a paired iPhone and Apple Watch after the device app installs cleanly:

- Start a spoken session on iPhone and confirm the Watch shows the current title, brief chapter/target label, progress, and playback state instead of the fallback "Open on iPhone" state.
- Tap play/pause on Watch and verify the phone-owned session toggles without starting independent Watch playback.
- Tap skip forward and skip back on Watch and verify the phone advances across the expected chapter boundary or idempotently stays at the boundary without crashing.
- Use chapter navigation on Watch, if visible, and verify the phone jumps to the selected chapter and returns an updated compact snapshot.
- Tap interject, verify the Watch enters recording/interjection state, then finish and confirm the phone saves the interjection and the Watch leaves recording state.
- Tap AI summary/discuss controls, if visible for the current state, and verify unsupported or unavailable actions are hidden or disabled and available actions delegate to the phone session.
- Background and foreground the Watch app, then confirm it refreshes to the current phone session instead of stale or placeholder state.
- Stop the phone session and confirm the Watch returns to a clear inactive/open-phone state.

## Out Of Scope

- Watch app implementation.
- Xcode target/project edits.
- SessionKit command or snapshot implementation.
- Watch-owned playback, recording, persistence, transcription, or AI.
