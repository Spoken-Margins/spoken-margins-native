# Agent Coordination Rules

## Current Phase

Phase: `surface-contract-scaffold`

The steward owns shared contracts, shared runtime code, Xcode project changes, and full app build authority. Gate agents work contract-first and produce backend requests instead of directly changing shared runtime implementation.

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

## Build Policy

- Gate agents may run contract validators only.
- Gate agents must not run full app or Xcode builds.
- Only the steward runs `xcodebuild`.
- If a gate needs shared runtime, snapshot, command, or Xcode changes, record a backend request in the surface contract or final handoff.

Allowed gate-agent commands:

```bash
python3 scripts/validate-contracts.py
python3 scripts/validate-surface-contracts.py
```

## Required Agent Output

Every gate handoff must include:

- changed files
- contract deltas
- backend requests
- tests run
- tests not run
- open risks

## Parallel Gate Rules

- Gate 3 owns Watch Tethered contract work.
- Gate 5 owns Browser Text contract and handoff-shape work.
- Gate agents may not mutate shared command, snapshot, delegation, schema, or validator files after kickoff without steward approval.
- Gate agents may not edit Xcode project files or shared SessionKit implementation files.
