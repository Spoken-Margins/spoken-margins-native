# Gate 3 Agent Card: Watch Tethered

## Role

Advance the Gate 3 Watch Tethered surface contract without changing shared SessionKit implementation or Xcode project files.

## Allowed Files

- `validation/surface-contracts/gate3-watch-tethered.json`
- `validation/agent-cards/gate3-watch-tethered.md`
- Gate 3-specific notes under `docs/` if needed

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

## Out Of Scope

- Watch app implementation.
- Xcode target/project edits.
- SessionKit command or snapshot implementation.
- Watch-owned playback, recording, persistence, transcription, or AI.
