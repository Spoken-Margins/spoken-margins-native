# Archived Parallel Agent Workflow

This file preserves the prior steward/parallel-gate operating model for reference only. It is no longer the default workflow for this repository.

Use these rules only when the product owner explicitly asks for parallel agent work with a named steward, named gate agents, a frozen packet, and a merge order.

## Prior Coordination Rules

Phase: `surface-contract-scaffold`

The steward owns shared contracts, shared runtime code, Xcode project changes, and full app build authority. Gate agents work contract-first and produce backend requests instead of directly changing shared runtime implementation.

All parallel work must follow `docs/parallel-track-coordination.md` and `docs/surface-contract-governance.md`. The steward must publish a frozen steward packet before kickoff, including allowed files, forbidden files, canonical command ids, canonical snapshot field ids, allowed trace language, schema-validated fixture families, and merge order.

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

## Prior Build Policy

- Gate agents may run contract validators only.
- Gate agents must not run full app or Xcode builds.
- Only the steward runs `xcodebuild`.
- If a gate needs shared runtime, snapshot, command, or Xcode changes, record a backend request in the surface contract or final handoff.

Allowed gate-agent commands:

```bash
python3 scripts/validate-contracts.py
python3 scripts/validate-surface-contracts.py
```

Steward/local verification commands:

```bash
xcodegen generate
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsAppDevice -destination 'generic/platform=iOS' build | xcbeautify
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -destination 'generic/platform=iOS Simulator' build | xcbeautify
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsWatch -destination 'generic/platform=watchOS' build | xcbeautify
```

## Prior Handoff Shape

Every gate handoff included:

- changed files
- contract deltas
- backend requests
- tests run
- tests not run
- open risks
- shared vocabulary needed but missing from the steward packet
- whether the PR changes executable traces

## Prior Parallel Gate Rules

- Gate 3 owns Watch Tethered contract work.
- Gate 5 owns Browser Text contract and handoff-shape work.
- Gate agents may not mutate shared command, snapshot, delegation, schema, or validator files after kickoff without steward approval.
- Gate agents may not edit Xcode project files or shared SessionKit implementation files.
- Gate agents may not add command ids outside `validation/contracts/command-matrix.json`.
- Gate agents may not add snapshot field ids outside `validation/contracts/snapshot-fields.json`.
- Gate agents may not add delegation modes outside `validation/contracts/delegation-modes.json`.
- Gate agents may not add new fixture families unless the steward packet confirms schema and validator coverage.
- Gate agents may not add executable trace expectations for fields, events, payloads, or result keys that the trace harness does not already support.
- If a gate needs missing shared vocabulary, trace language, schema, validator, or runtime support, record a backend request instead of inventing it locally.
- Passing `scripts/validate-contracts.py` and `scripts/validate-surface-contracts.py` proves JSON/schema/reference validity only; it does not prove trace replay, runtime behavior, or build readiness.
